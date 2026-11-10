#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,

    [string]$RouteSpecPath = (Join-Path $PSScriptRoot '..\data\KCPS-RouteSpecs.json'),

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

function Get-ConfigFiles {
    param([string[]]$InputPaths)

    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($inputPath in $InputPaths) {
        $resolved = Resolve-Path -LiteralPath $inputPath
        $item = Get-Item -LiteralPath $resolved
        if ($item.PSIsContainer) {
            foreach ($file in (Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Filter '*.conf.json' | Where-Object { Test-KcpsConfigScanPath -Path $_.FullName -ScanRoot $item.FullName })) {
                $files.Add($file.FullName)
            }
        } else {
            $files.Add($item.FullName)
        }
    }
    return @($files | Sort-Object -Unique)
}

function Update-StringTree {
    param(
        [object]$Node,
        [string]$OldName,
        [string]$NewName,
        [string]$TargetPrefixPattern,
        [string]$TargetPrefixReplacement
    )

    if ($Node -is [string]) {
        $updated = $Node.Replace($OldName, $NewName)
        return [regex]::Replace($updated, $TargetPrefixPattern, $TargetPrefixReplacement)
    }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in @($Node.Keys)) {
            $Node[$key] = Update-StringTree `
                -Node $Node[$key] `
                -OldName $OldName `
                -NewName $NewName `
                -TargetPrefixPattern $TargetPrefixPattern `
                -TargetPrefixReplacement $TargetPrefixReplacement
        }
        return $Node
    }
    if ($Node -is [System.Collections.IList]) {
        for ($index = 0; $index -lt $Node.Count; $index++) {
            $Node[$index] = Update-StringTree `
                -Node $Node[$index] `
                -OldName $OldName `
                -NewName $NewName `
                -TargetPrefixPattern $TargetPrefixPattern `
                -TargetPrefixReplacement $TargetPrefixReplacement
        }
        return $Node
    }
    return $Node
}

$routeSpecDocument = Read-KcpsJson -Path $RouteSpecPath
$routeSpecs = @($routeSpecDocument['Routes'])
$reports = @()

foreach ($file in Get-ConfigFiles -InputPaths $Path) {
    $config = Read-KcpsJson -Path $file
    $fileChanges = @()
    $fileProblems = @()

    foreach ($group in Get-KcpsGroups -Config $config) {
        $oldName = [string]$group['Name']
        $sortie = @($group['List'] | Where-Object {
            Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleSortieWorkflow'
        } | Select-Object -First 1)[0]
        if ($null -eq $sortie) { continue }

        $matchingSpecs = @($routeSpecs | Where-Object {
            [int]$_['Sea'] -eq [int]$sortie['Sea'] -and
            [int]$_['Area'] -eq [int]$sortie['Area'] -and
            (Test-KcpsRouteSpecGroupName -GroupName $oldName -RouteSpec $_)
        })
        if ($matchingSpecs.Count -ne 1) { continue }

        $expectation = Get-KcpsHistoricalBossStageExpectation `
            -GroupName $oldName `
            -RouteSpec $matchingSpecs[0] `
            -RouteSpecDocument $routeSpecDocument
        if ($null -eq $expectation) { continue }
        if ([int]$expectation['MappingCount'] -ne 1) {
            $fileProblems += "$oldName：缺少唯一的活动 Boss 阶段资料，未自动改名。"
            continue
        }

        $point = [string]$expectation['Point']
        $expectedLabel = [string]$expectation['ExpectedLabel']
        $actualLabel = [string]$expectation['ActualLabel']
        if ($actualLabel -ceq $expectedLabel) { continue }

        $expectedPointToken = if ([string]::IsNullOrWhiteSpace($expectedLabel)) {
            "${point}点"
        } else {
            "${point}点($expectedLabel)"
        }
        $namePattern = '^(?<prefix>E\d+\s+P\d+\s+(?:削甲|破甲)\s+)' +
            [regex]::Escape("${point}点") + '(?:\(P\d+\))?'
        $newName = [regex]::Replace($oldName, $namePattern, ('${prefix}' + $expectedPointToken))
        if ($newName -ceq $oldName) {
            $fileProblems += "$oldName：无法定位目标点名称，未自动改名。"
            continue
        }

        $area = [int]$expectation['Area']
        $currentPhase = [int]$expectation['CurrentPhase']
        $targetPrefixPattern = '(?<prefix>E' + $area + '\s+P' + $currentPhase +
            '\s+(?:削甲|破甲)\s+)' + [regex]::Escape("${point}点") + '(?:\(P\d+\))?'
        $targetPrefixReplacement = '${prefix}' + $expectedPointToken
        if (-not $CheckOnly) {
            $null = Update-StringTree `
                -Node $group `
                -OldName $oldName `
                -NewName $newName `
                -TargetPrefixPattern $targetPrefixPattern `
                -TargetPrefixReplacement $targetPrefixReplacement
        }
        $fileChanges += [ordered]@{
            OldName = $oldName
            NewName = $newName
            RouteSpec = [string]$matchingSpecs[0]['Id']
        }
    }

    if ($fileChanges.Count -gt 0 -and -not $CheckOnly) {
        Write-KcpsJson -Value $config | Set-Content -LiteralPath $file -Encoding UTF8
    }

    $reports += [ordered]@{
        Path = $file
        Changed = [bool]($fileChanges.Count -gt 0 -and -not $CheckOnly)
        WouldChange = [bool]($fileChanges.Count -gt 0)
        Changes = @($fileChanges)
        Problems = @($fileProblems)
    }
}

$reports | ConvertTo-Json -Depth 12
