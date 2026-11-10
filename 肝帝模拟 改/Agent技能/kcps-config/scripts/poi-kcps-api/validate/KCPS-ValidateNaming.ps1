#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

$knownFrequencyPattern = '(?:单次|日常|月常|周常|季常|年常(?:[1-9]|1[0-2])月)'
$frequencyPattern = "(?:$knownFrequencyPattern(?:（不确定）)?|频次不明（不确定）)"
$typePattern = '(?:出击|编成|演习|工厂|远征|改装|补给／入渠)'
$filePattern = "^(?<Date>\d{8}) (?<Frequency>$frequencyPattern) (?<Kind>$typePattern) (?<Title>.+)\.conf\.json$"
$groupPattern = "^(?<Frequency>$frequencyPattern) (?<Kind>$typePattern) (?<Title>.+)$"

function Get-InputFiles {
    param([string]$InputPath)
    $resolved = Resolve-Path -LiteralPath $InputPath
    $item = Get-Item -LiteralPath $resolved
    if ($item.PSIsContainer) {
        return @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Filter '*.conf.json' | Where-Object { Test-KcpsConfigScanPath -Path $_.FullName -ScanRoot $item.FullName })
    }
    return @($item)
}

$files = @()
foreach ($inputPath in $Path) { $files += @(Get-InputFiles -InputPath $inputPath) }
$files = @($files | Sort-Object FullName -Unique)
$reports = @()
$problemCount = 0

foreach ($file in $files) {
    $problems = @()
    $config = Read-KcpsJson -Path $file.FullName
    $groups = @(Get-KcpsGroups -Config $config)
    # 活动类型来自实际出击字段，不能由用户目录中的年份、季节或任务标题推断。
    $isEventConfig = @(
        foreach ($group in $groups) {
            foreach ($workflow in @($group['List'])) {
                if ($null -ne $workflow -and (Test-KcpsWorkflowType $workflow 'SimpleSortieWorkflow') -and
                    $workflow.ContainsKey('Sea') -and [int]$workflow['Sea'] -eq 0 -and [int]$workflow['Area'] -gt 0) {
                    $workflow
                }
            }
        }
    ).Count -gt 0
    if ($isEventConfig) {
        # 捞船可以跨海域装入同一容器，必须由当前私人路线规格明确声明其用途。
        $allFarming = $false
        $routeDataPath = Join-Path $PSScriptRoot '..\data\KCPS-RouteSpecs.json'
        if ($file.Name -match '捞船.*\.conf\.json$' -and (Test-Path -LiteralPath $routeDataPath -PathType Leaf)) {
            $routeData = Read-KcpsJson -Path $routeDataPath
            $farmingCount = 0
            foreach ($group in $groups) {
                $matchedRoutes = @($routeData['Routes'] | Where-Object { Test-KcpsRouteSpecGroupName -RouteSpec $_ -GroupName ([string]$group['Name']) })
                if ($matchedRoutes.Count -eq 1 -and $null -ne $matchedRoutes[0]['StageDesign'] -and
                    [string]$matchedRoutes[0]['StageDesign']['Phase'] -eq 'Farming') { $farmingCount++ }
            }
            $allFarming = $groups.Count -gt 0 -and $farmingCount -eq $groups.Count
        }
        if ($allFarming) {
            foreach ($group in $groups) {
                if ([string]$group['Name'] -notmatch '^E\d+\s') { $problems += '捞船内部配置名须标明实际活动区域。' }
            }
            $problemCount += $problems.Count
            $reports += [ordered]@{ File=$file.FullName; ProblemCount=$problems.Count; Problems=@($problems) }
            continue
        }
        $levelingFile = [regex]::Match($file.Name, '^(?<sea>E\d+) 舰船练级 (?<points>[A-Z0-9]+(?: [A-Z0-9]+)*) 固定编成\.conf\.json$')
        if ($levelingFile.Success) {
            $points = @($levelingFile.Groups['points'].Value.Split(' '))
            $actual = @()
            foreach ($group in $groups) {
                $m = [regex]::Match([string]$group['Name'], '^(?<sea>E\d+) 舰船练级 (?<point>[A-Z0-9]+)点 固定编成 (?:单舰队|游击部队|空母机动|水上打击|输送护卫) \d+次 [1-4][A-Z0-9]+$')
                if (-not $m.Success -or $m.Groups['sea'].Value -ne $levelingFile.Groups['sea'].Value) {
                    $problems += '练级容器与内部配置名称不一致。'
                } else { $actual += $m.Groups['point'].Value }
            }
            if (($points -join ',') -cne ($actual -join ',')) { $problems += '练级容器的点顺序与内部配置不一致。' }
            $problemCount += $problems.Count
            $reports += [ordered]@{File=$file.FullName;ProblemCount=$problems.Count;Problems=@($problems)}
            continue
        }
        $eventFileMatch = [regex]::Match(
            $file.Name,
            '^(?<stage>E\d+\s+P\d+)\s+(?:开路(?:\s+第(?:[0-9]+|[一二三四五六七八九十]+)阶段)?|攻略)\.conf\.json$'
        )
        if (-not $eventFileMatch.Success) {
            $problems += '活动配置文件名必须为 E# P# 开路[ 第#阶段].conf.json 或 E# P# 攻略.conf.json；单个目标、舰队形式、陆航/支援和路线码只保留在内部配置名。'
        } else {
            foreach ($group in $groups) {
                $groupStageMatch = [regex]::Match([string]$group['Name'], '^(?<stage>E\d+\s+P\d+)\b')
                if (-not $groupStageMatch.Success -or
                    $groupStageMatch.Groups['stage'].Value -ne $eventFileMatch.Groups['stage'].Value) {
                    $problems += "配置 '$([string]$group['Name'])' 与容器文件的 E# P# 阶段不一致。"
                }
            }
        }
        $problemCount += $problems.Count
        $reports += [ordered]@{
            File = $file.FullName
            ProblemCount = $problems.Count
            Problems = @($problems)
        }
        continue
    }

    $match = [regex]::Match($file.Name, $filePattern)
    if (-not $match.Success) {
        $problems += '文件名必须为 JST日期 频次 中文种类 标题.conf.json；已确认频次只允许单次/日常/月常/周常/季常/年常X月，不确定时追加（不确定）或使用频次不明（不确定）；种类只允许出击/编成/演习/工厂/远征/改装/补给／入渠。'
    }

    $frequency = if ($match.Success) { $match.Groups['Frequency'].Value } else { '' }
    $title = if ($match.Success) { $match.Groups['Title'].Value } else { '' }
    $memos = @(
        foreach ($group in Get-KcpsGroups -Config $config) {
            foreach ($workflow in @($group['List'])) {
                if ($null -ne $workflow -and $workflow.ContainsKey('Memo')) { [string]$workflow['Memo'] }
            }
        }
    )
    $frequencyEvidence = @($memos | Where-Object { $_ -match '【频次依据】' })
    $needsFrequencyEvidence = $frequency -match '（不确定）$' -or $title -match '期間限定|限定任務'
    if ($needsFrequencyEvidence -and $frequencyEvidence.Count -eq 0) {
        $problems += '期间限定任务或频次含（不确定）时，说明执行单元必须记录【频次依据】、来源 URL、查证日期和不确定原因。'
    }
    if ($frequencyEvidence.Count -gt 0) {
        $evidenceText = $frequencyEvidence -join "`n"
        if ($evidenceText -notmatch 'https?://') {
            $problems += '【频次依据】必须包含可复查的来源 URL。'
        }
        if ($evidenceText -notmatch '20\d{2}-\d{2}-\d{2}') {
            $problems += '【频次依据】必须包含 YYYY-MM-DD 格式的 JST 查证日期。'
        }
        $frequencyBase = $frequency -replace '（不确定）$', ''
        if ($frequencyBase -ne '频次不明' -and $evidenceText -notmatch [regex]::Escape($frequencyBase)) {
            $problems += "【频次依据】必须明确写出与文件名一致的频次 '$frequencyBase'。"
        }
        if ($frequency -match '（不确定）$' -and $evidenceText -notmatch '不确定|検証中|暫定|推定|冲突|不明') {
            $problems += '频次标有（不确定），但【频次依据】没有写明不确定原因。'
        }
        if ($frequency -notmatch '（不确定）$' -and $evidenceText -match '検証中|暫定|推定|不确定|冲突|不明') {
            $problems += '【频次依据】仍含不确定信息，文件名和配置名的频次必须追加（不确定）。'
        }
    }
    foreach ($group in Get-KcpsGroups -Config $config) {
        $groupName = [string]$group['Name']
        $groupMatch = [regex]::Match($groupName, $groupPattern)
        if (-not $groupMatch.Success) {
            $problems += "配置名 '$groupName' 必须以频率和中文种类开头，且不得以任务编号替代。"
            continue
        }
        if ($match.Success) {
            if ($groupMatch.Groups['Frequency'].Value -ne $match.Groups['Frequency'].Value) {
                $problems += "配置名 '$groupName' 的频率与文件名不一致。"
            }
            if ($groupMatch.Groups['Kind'].Value -ne $match.Groups['Kind'].Value) {
                $problems += "配置名 '$groupName' 的种类与文件名不一致。"
            }
        }
    }

    $problemCount += $problems.Count
    $reports += [ordered]@{
        File = $file.FullName
        ProblemCount = $problems.Count
        Problems = @($problems)
    }
}

[ordered]@{
    FileCount = $files.Count
    ProblemCount = $problemCount
    Files = @($reports)
} | ConvertTo-Json -Depth 8
