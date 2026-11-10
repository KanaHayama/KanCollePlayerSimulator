#requires -Version 7.0
Set-StrictMode -Version Latest
. "$PSScriptRoot\..\poi-kcps-api\KCPS-Connection.ps1"

function Read-KcpsExpeditionJson {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
}

function Read-KcpsExpeditionPlan {
    param([Parameter(Mandatory)][string]$Path)
    $json = Get-Content -LiteralPath $Path -Raw
    if (-not (Test-Json -Json $json -SchemaFile "$PSScriptRoot\data\expedition-plan.schema.json" -ErrorAction SilentlyContinue)) {
        throw '远征计划缺少必要字段或字段格式错误，请对照通用计划结构。'
    }
    $plan = ConvertFrom-Json -InputObject $json -AsHashtable
    if ([string]::IsNullOrWhiteSpace($plan.name) -or [string]::IsNullOrWhiteSpace($plan.memo)) { throw '计划名称和说明不能为空白。' }
    $missionIds = @{}
    foreach ($mission in $plan.missions) {
        if ([string]::IsNullOrWhiteSpace($mission.name)) { throw '远征名称不能为空白。' }
        $id = [string]$mission.id
        if ($missionIds.ContainsKey($id)) { throw '远征计划包含重复的远征 ID。' }
        $missionIds[$id] = $true
    }
    $questIds = @{}
    foreach ($task in $plan.tasks) {
        if ([string]::IsNullOrWhiteSpace($task.title)) { throw '任务标题不能为空白。' }
        $id = [string]$task.questNo
        if ($questIds.ContainsKey($id)) { throw '远征计划包含重复的任务 ID。' }
        $questIds[$id] = $true
        $taskMissions = @{}
        foreach ($requirement in $task.requirements) {
            $missionId = [string]$requirement.missionId
            if (-not $missionIds.ContainsKey($missionId)) { throw '任务要求引用了未声明的远征。' }
            if ($taskMissions.ContainsKey($missionId)) { throw '同一任务包含重复的远征要求。' }
            $taskMissions[$missionId] = $true
        }
    }
    $fleetIds = @{}
    foreach ($chain in $plan.chains) {
        $id = [string]$chain.fleet
        if ($fleetIds.ContainsKey($id)) { throw '同一舰队必须将步骤写在一条远征链内。' }
        $fleetIds[$id] = $true
        foreach ($step in $chain.steps) {
            if ([string]::IsNullOrWhiteSpace($step.templateName)) { throw '每个步骤必须指定模板配置名。' }
            if (-not $missionIds.ContainsKey([string]$step.missionId)) { throw '远征步骤引用了未声明的远征。' }
        }
    }
    return $plan
}

function Write-KcpsExpeditionJson {
    param([Parameter(Mandatory)][object]$Value, [Parameter(Mandatory)][string]$Path)
    Assert-KcpsPrivateOutputPath -Path $Path
    $fullPath = Resolve-KcpsFileSystemPath -Path $Path
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $fullPath))
    [IO.File]::WriteAllText($fullPath, (ConvertTo-Json -InputObject $Value -Depth 100), [Text.UTF8Encoding]::new($false))
}

function Assert-KcpsExpeditionSnapshot {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot, [int]$MaxAgeMinutes = 15)
    foreach ($key in @('Timestamp', 'Fleets', 'TargetMissions', 'Quests')) {
        if (-not $Snapshot.Contains($key)) { throw '远征快照不完整，请重新查询。' }
    }
    $captured = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Snapshot.Timestamp, [ref]$captured)) { throw '远征快照缺少有效采集时间。' }
    $age = ([DateTimeOffset]::UtcNow - $captured).TotalMinutes
    if ($age -lt -1 -or $age -gt $MaxAgeMinutes) { throw '远征快照已过期或采集时间不合理，请重新查询。' }
    foreach ($key in @('Fleets', 'TargetMissions', 'Quests')) {
        if ($Snapshot[$key] -isnot [array]) { throw '远征快照的列表字段必须是数组。' }
    }
    foreach ($fleet in $Snapshot.Fleets) {
        if ($fleet -isnot [System.Collections.IDictionary] -or
            -not $fleet.Contains('Fleet') -or -not $fleet.Contains('IsExpeditioning') -or
            ($fleet.Fleet -isnot [long] -and $fleet.Fleet -isnot [int]) -or
            $fleet.IsExpeditioning -isnot [bool]) { throw '舰队编号和远征状态必须明确，不能由字符串或缺失字段推断。' }
    }
    foreach ($mission in $Snapshot.TargetMissions) {
        if ($mission -isnot [System.Collections.IDictionary] -or
            -not $mission.Contains('Id') -or -not $mission.Contains('IsOpen') -or -not $mission.Contains('UnlockState') -or
            ($mission.Id -isnot [long] -and $mission.Id -isnot [int]) -or
            $mission.IsOpen -isnot [bool]) { throw '目标远征编号和开放状态必须明确。' }
    }
}

function Get-KcpsExpeditionType {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Workflow)
    return (([string]$Workflow.Type -split ',')[0] -split '\.')[-1]
}

function Copy-KcpsExpeditionObject {
    param([Parameter(Mandatory)][object]$Value)
    return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 100) -AsHashtable -NoEnumerate
}

function New-KcpsExpeditionReference {
    param([Parameter(Mandatory)][string]$Guid)
    return @{ Guid = $Guid; Enabled = $true; IgnoreTriggerFailure = $false }
}
