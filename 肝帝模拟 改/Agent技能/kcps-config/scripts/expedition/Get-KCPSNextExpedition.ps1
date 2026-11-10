#requires -Version 7.0
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StatePath,
    [Parameter(Mandatory)][ValidateRange(2, 4)][int]$Fleet,
    [string]$SnapshotPath,
    [string]$BaseUrl = '',
    [ValidateRange(1, 1440)][int]$MaxSnapshotAgeMinutes = 15,
    [switch]$AsJson
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\KCPS-ExpeditionCommon.ps1"
$plan = Read-KcpsExpeditionPlan -Path $PlanPath
$state = Read-KcpsExpeditionJson -Path $StatePath
if (-not $state.Contains('completed') -or $state.completed -isnot [System.Collections.IDictionary]) { throw '必须明确提供各任务已完成次数，不能从缺失记录推断为零。' }
$snapshot = if ($SnapshotPath) { Read-KcpsExpeditionJson -Path $SnapshotPath } else { & "$PSScriptRoot\Get-KCPSExpeditionSnapshot.ps1" -PlanPath $PlanPath -BaseUrl $BaseUrl }
Assert-KcpsExpeditionSnapshot -Snapshot $snapshot -MaxAgeMinutes $MaxSnapshotAgeMinutes
$fleetState = @($snapshot.Fleets | Where-Object { [int]$_.Fleet -eq $Fleet })
if ($fleetState.Count -ne 1) { throw '快照未包含唯一的指定舰队状态。' }
$rows = @(
    foreach ($task in $plan.tasks) {
        $key = [string]$task.questNo
        $quests = @($snapshot.Quests | Where-Object { [int]$_.No -eq $task.questNo -and $_.Title -eq $task.title -and $_.State -in @(1, 2) })
        if ($quests.Count -ne 1) { throw '计划中的任务 ID、标题或当前可接取状态无法从快照确认。' }
        foreach ($req in $task.requirements) {
            $missionKey = [string]$req.missionId
            if (-not $state.completed.Contains($key) -or -not $state.completed[$key].Contains($missionKey)) { throw '任务完成记录不完整，请明确填写已完成次数。' }
            $done = $state.completed[$key][$missionKey]
            if ($done -isnot [long] -and $done -isnot [int]) { throw '已完成次数必须是非负整数。' }
            if ($done -lt 0 -or $done -gt $req.count) { throw '已完成次数超出任务要求范围。' }
            if ($done -ge $req.count) { continue }
            $mission = @($plan.missions | Where-Object { $_.id -eq $req.missionId })[0]
            $current = @($snapshot.TargetMissions | Where-Object { $_.Id -eq $req.missionId })
            $open = ($current.Count -eq 1 -and $current[0].IsOpen -eq $true -and $current[0].UnlockState -eq $mission.unlockStateRequired)
            @{
                QuestNo = $task.questNo; TaskName = $task.title; Priority = $task.priority
                MissionId = $mission.id; MissionName = $mission.name; Minutes = $mission.minutes
                Remaining = $req.count - $done; IsOpen = $open
                InProgress = @($snapshot.Fleets | Where-Object { $_.IsExpeditioning -eq $true -and $_.MissionId -eq $mission.id }).Count
            }
        }
    }
)
$candidates = @($rows | Where-Object { $_.IsOpen } | Sort-Object @{Expression = { $_.Priority }; Descending = $true}, @{Expression = { $_.Minutes }; Descending = $true}, MissionId)
$busy = $fleetState[0].IsExpeditioning -eq $true
$best = if (-not $busy -and $candidates.Count -gt 0) { $candidates[0] } else { $null }
$result = @{
    Timestamp = [DateTimeOffset]::UtcNow.ToString('o'); Fleet = $Fleet
    Recommendation = $(if ($busy) { 'wait' } elseif ($best) { 'candidate' } elseif ($rows.Count) { 'blocked' } else { 'none' })
    Reason = $(if ($busy) { '舰队正在远征，先等待归还。' } elseif ($best) { '按输入优先级及远征时长给出候选；派遣前仍需核对舰队编成、配装和任务接取。' } elseif ($rows.Count) { '尚有未完成要求，但快照不能确认相应远征已开放。' } else { '输入的任务完成记录中没有剩余要求。' })
    Selected = $best; Candidates = $candidates; Outstanding = $rows
}
if ($AsJson) { ConvertTo-Json -InputObject $result -Depth 40 } else { $result }
