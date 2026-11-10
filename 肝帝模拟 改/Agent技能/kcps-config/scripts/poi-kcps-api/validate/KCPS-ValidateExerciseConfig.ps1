#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

$resolved = Resolve-Path -LiteralPath $Path
if ((Get-Item -LiteralPath $resolved).PSIsContainer) {
    throw 'Validate one exercise .conf.json file at a time.'
}

$config = Read-KcpsJson -Path ([string]$resolved)
$reports = @()
$totalProblems = 0
$rankRuleLastVerifiedJst = [datetimeoffset]'2026-07-20T09:00:00+09:00'
$rankRuleRefreshAfterDays = 90
$nowJst = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetimeoffset]::Now, 'Tokyo Standard Time')
$rankRuleAgeDays = [math]::Floor(($nowJst - $rankRuleLastVerifiedJst).TotalDays)
$freshnessWarnings = @()
if ($rankRuleAgeDays -gt $rankRuleRefreshAfterDays) {
    $freshnessWarnings += [ordered]@{
        Id = 'kcps-exercise-battle-rank-comparison'
        LastVerifiedJst = $rankRuleLastVerifiedJst.ToString('yyyy-MM-dd')
        AgeDays = $rankRuleAgeDays
        RefreshAfterDays = $rankRuleRefreshAfterDays
        Warning = 'Re-check RelationalExerciseWorkflow battle-rank comparison and BattleRank enum before relying on this rule.'
    }
}

function Get-ExerciseBattleMemoLanguageProblem {
    param([string]$Memo)
    if ([string]::IsNullOrWhiteSpace($Memo)) { return $null }
    $reasons = @()
    if ($Memo -match '[ぁ-ゟ゠-ヿ]|単縦|単横|複縦|輪形|空襲|航空戦|対潜|潜水|水上|針路|選択|能動|無戦闘|到達|経由|発煙|一斉射|旗艦|特殊攻撃|輸送|レ級') {
        $reasons += '含日文假名或日式战斗术语'
    }
    $latinWords = @([regex]::Matches($Memo, '[A-Za-z]+') | ForEach-Object { $_.Value })
    $englishProse = @($latinWords | Where-Object { $_.Length -gt 1 -and $_.ToUpperInvariant() -notin @('PT', 'SS') })
    if ($englishProse.Count -gt 0) { $reasons += "含英文叙述词或未中文化舰名: $($englishProse -join ', ')" }
    if ($reasons.Count -eq 0) { return $null }
    return "战斗策略备注必须只用中文（必要游戏标识除外）：$($reasons -join '；')。"
}

foreach ($group in Get-KcpsGroups -Config $config) {
    $problems = @()
    $list = @($group['List'])
    $name = [string]$group['Name']

    if ($list.Count -eq 0) {
        $problems += '配置不包含执行单元。'
    } elseif ([string]$list[0]['Name'] -ne '说明') {
        $problems += '说明执行单元必须位于配置最前面。'
    }

    $exerciseControllers = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'RelationalExerciseWorkflow' })
    $sortieWorkflows = @($list | Where-Object {
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'RelationalSortieWorkflow') -or
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleSortieWorkflow')
    })
    if ($exerciseControllers.Count -ne 1) {
        $problems += "每个演习配置必须且只能有一个 RelationalExerciseWorkflow，当前为 $($exerciseControllers.Count)。"
    }
    if ($sortieWorkflows.Count -gt 0) {
        $problems += '演习配置包含出击 workflow；不得套用出击配置结构。'
    }

    foreach ($requiredName in @('说明', '总控', '接任务', '编成', '改装', '补给')) {
        if (@($list | Where-Object { [string]$_['Name'] -eq $requiredName }).Count -ne 1) {
            $problems += "必须且只能有一个名为 '$requiredName' 的执行单元。"
        }
    }

    foreach ($workflow in $list) {
        if ([bool]$workflow['EnableOnLoad']) {
            $problems += "执行单元 '$($workflow['Name'])' 不得载入时启用。"
        }
        if ([bool]$workflow['TriggerOnEnabled']) {
            $problems += "执行单元 '$($workflow['Name'])' 不得启用时立即触发。"
        }
    }

    foreach ($controller in $exerciseControllers) {
        $defaultMemoProblem = Get-ExerciseBattleMemoLanguageProblem -Memo ([string]$controller['DefaultStrategy']['Memo'])
        if ($defaultMemoProblem) { $problems += "默认演习策略：$defaultMemoProblem" }
        if ([bool]$controller['StopIfBattleRankHigherOrEqualThanFlag']) {
            $problems += '当前 KCPS 评级比较方向错误，必须关闭 StopIfBattleRankHigherOrEqualThanFlag。'
        }
        if (-not [bool]$controller['StopIfExecuteCountLargerOrEqualThanFlag'] -or [int]$controller['StopIfExecuteCountLargerOrEqualThanValue'] -le 0) {
            $problems += '必须设置正数的演习执行次数上限。'
        }
        if ($controller['DefaultStrategy'] -isnot [System.Collections.IDictionary]) {
            $problems += 'DefaultStrategy 必须是 JSON 对象。'
        }
        foreach ($strategy in @($controller['ConditionalStrategies'])) {
            $conditionalMemoProblem = Get-ExerciseBattleMemoLanguageProblem -Memo ([string]$strategy['Memo'])
            if ($conditionalMemoProblem) { $problems += "演习条件策略 '$($strategy['Name'])'：$conditionalMemoProblem" }
            if ([int]$strategy['Type'] -eq 5) {
                if ([int]$strategy['Formation'] -ne 5) {
                    $problems += "潜水比例条件策略 '$($strategy['Name'])' 应使用单横阵；若有特殊理由需先更新校验规则。"
                }
                if ([int]$strategy['Midnight'] -ne 1) {
                    $problems += "潜水比例条件策略 '$($strategy['Name'])' 不应进入夜战。"
                }
                $ratio = 0
                if (-not [int]::TryParse([string]$strategy['Value'], [ref]$ratio) -or $ratio -lt 1 -or $ratio -gt 100) {
                    $problems += "潜水比例条件策略 '$($strategy['Name'])' 的 Value 必须为 1..100。"
                }
            }
        }
    }

    $accepts = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicAcceptQuestWorkflow' })
    foreach ($accept in $accepts) {
        foreach ($quest in @($accept['Quests'])) {
            if (-not [bool]$quest['FailIfNotExist']) {
                $problems += "接任务 ID $($quest['SelectValue']) 必须设置任务不存在算失败。"
            }
            if ([bool]$quest['FailIfAccepted']) {
                $problems += "接任务 ID $($quest['SelectValue']) 已接受时不应算失败。"
            }
        }
    }

    $organizers = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow' })
    foreach ($organizer in $organizers) {
        if (@($organizer['Positions']).Count -ne 6) {
            $problems += "编成 '$($organizer['Name'])' 应明确设置六个舰队位置。"
        }
    }

    $refits = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicRefitEquipmentWorkflow' })
    foreach ($refit in $refits) {
        $positions = @($refit['Ships'] | ForEach-Object { [int]$_['SelectValue'] })
        $actual = @($positions | Sort-Object)
        if (($actual -join ',') -ne '1,2,3,4,5,6') {
            $problems += "改装 '$($refit['Name'])' 必须恰好覆盖舰队位置 1..6，当前为 $($actual -join ',')。"
        }
        foreach ($ship in @($refit['Ships'])) {
            if (@($ship['Slots'] | Where-Object { [int]$_['Slot'] -eq 6 }).Count -ne 1) {
                $problems += "改装 '$($refit['Name'])' 的位置 $($ship['SelectValue']) 必须包含一个补强增设 slot6 策略。"
            }
        }
    }

    $totalProblems += $problems.Count
    $reports += [ordered]@{
        Config = $name
        ExerciseControllerCount = $exerciseControllers.Count
        SortieWorkflowCount = $sortieWorkflows.Count
        ProblemCount = $problems.Count
        Problems = @($problems)
    }
}

[ordered]@{
    Path = [string]$resolved
    ConfigCount = @($reports).Count
    ProblemCount = $totalProblems
    RankRuleLastVerifiedJst = $rankRuleLastVerifiedJst.ToString('yyyy-MM-dd')
    HardcodedRuleFreshnessWarningCount = $freshnessWarnings.Count
    HardcodedRuleFreshnessWarnings = @($freshnessWarnings)
    Configs = @($reports)
} | ConvertTo-Json -Depth 10
