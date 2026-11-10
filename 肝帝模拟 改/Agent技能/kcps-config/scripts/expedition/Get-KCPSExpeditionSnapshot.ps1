#requires -Version 7.0
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanPath,
    [string]$SourcePath,
    [string]$BaseUrl = '',
    [string]$OutputPath,
    [switch]$AsJson
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\KCPS-ExpeditionCommon.ps1"
$plan = Read-KcpsExpeditionPlan -Path $PlanPath
if ($SourcePath) {
    $raw = Read-KcpsExpeditionJson -Path $SourcePath
    foreach ($key in @('CapturedAt', 'Fleets', 'QuestList', 'MissionList')) {
        if (-not $raw.Contains($key)) { throw '离线原始快照缺少采集时间、舰队、任务或远征开放数据。' }
    }
} else {
    $raw = @{
        Fleets = Invoke-KcpsPoiRequest -Path '/data?type=fleets' -BaseUrl $BaseUrl -AsHashtable
        QuestList = Invoke-KcpsPoiRequest -Path ('/response?type=' + [uri]::EscapeDataString('/kcsapi/api_get_member/questlist')) -BaseUrl $BaseUrl -AsHashtable
        MissionList = Invoke-KcpsPoiRequest -Path ('/response?type=' + [uri]::EscapeDataString('/kcsapi/api_get_member/mission')) -BaseUrl $BaseUrl -AsHashtable
        CapturedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
}
if ($raw.Fleets -isnot [array] -or -not $raw.QuestList.Contains('api_list') -or -not $raw.MissionList.Contains('api_list_items')) {
    throw '当前缓存没有完整的舰队、任务页或远征页数据，请刷新相应游戏页面。'
}
$unlock = @{}
foreach ($entry in $raw.MissionList.api_list_items) { $unlock[[string]$entry.api_mission_id] = [int]$entry.api_state }
$missionSummary = @(
    foreach ($mission in $plan.missions) {
        $state = if ($unlock.ContainsKey([string]$mission.id)) { $unlock[[string]$mission.id] } else { $null }
        @{ Id = [int]$mission.id; Name = $mission.name; Minutes = $mission.minutes; UnlockState = $state; IsOpen = ($null -ne $state -and $state -eq $mission.unlockStateRequired) }
    }
)
$fleetSummary = @(
    foreach ($fleet in $raw.Fleets) {
        if ($fleet.api_mission -isnot [array] -or $fleet.api_mission.Count -lt 3) { throw '舰队远征状态不完整。' }
        $missionId = [int]$fleet.api_mission[1]
        $returnTime = [long]$fleet.api_mission[2]
        @{
            Fleet = [int]$fleet.api_id
            Name = [string]$fleet.api_name
            IsExpeditioning = ([int]$fleet.api_mission[0] -ne 0 -and $missionId -gt 0)
            MissionId = $missionId
            ReturnAt = $(if ($returnTime -gt 0) { [DateTimeOffset]::FromUnixTimeMilliseconds($returnTime).ToString('o') } else { $null })
            Ships = @($fleet.api_ship | Where-Object { [int]$_ -gt 0 })
        }
    }
)
$questIds = @($plan.tasks | ForEach-Object { [int]$_.questNo })
$questSummary = @(
    foreach ($quest in $raw.QuestList.api_list) {
        if ($quest -is [System.Collections.IDictionary] -and $questIds -contains [int]$quest.api_no) {
            @{ No = [int]$quest.api_no; State = [int]$quest.api_state; Progress = [int]$quest.api_progress_flag; Title = [string]$quest.api_title }
        }
    }
)
$result = @{ Timestamp = $raw.CapturedAt; Fleets = $fleetSummary; TargetMissions = $missionSummary; Quests = $questSummary }
if ($OutputPath) { Write-KcpsExpeditionJson -Value $result -Path $OutputPath }
if ($AsJson) { ConvertTo-Json -InputObject $result -Depth 40 } else { $result }
