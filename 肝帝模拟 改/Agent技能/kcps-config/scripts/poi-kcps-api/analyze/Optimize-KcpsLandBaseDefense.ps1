#requires -Version 7.0

param(
    [string]$BaseUrl = '',

    [Parameter(Mandatory)]
    [ValidateSet('Normal', 'HighAltitude')]
    [string]$RaidType,

    [Parameter(Mandatory)]
    [ValidateSet('Max', 'Zero')]
    [string]$ProficiencyMode,

    [ValidateRange(1, 99)]
    [int]$SlotSize = 18,

    [ValidateRange(1, 100)]
    [int]$Top = 10,

    [ValidateRange(1, 3)]
    [int]$CorpsCount = 1,

    [int[]]$ExcludedInstanceIds = @(),

    [int[]]$ExcludedMasterIds = @(),

    [int]$EnemyAirPower = 0,

    [int]$TargetAirPower = 0,

    [int]$PreferredAreaId = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\..\KCPS-Common.ps1"
. "$PSScriptRoot\KCPS-FarmingAnalysis.ps1"

$ruleCheckedOn = '2026-08-29'
$ruleSource = 'https://wikiwiki.jp/kancolle/基地航空隊'
$rocketMasterIds = @(350, 351, 352) # Me163B, 試製 秋水, 秋水
$aircraftTypeIds = @(6, 7, 8, 9, 10, 11, 25, 26, 41, 43, 45, 47, 48, 49, 57)
$reconTypeIds = @(9, 10, 41, 49)

function Get-MapValue {
    param(
        [System.Collections.IDictionary]$Map,
        [string]$Key,
        [object]$Default = 0
    )

    if ($null -ne $Map -and $Map.Contains($Key) -and $null -ne $Map[$Key]) {
        return $Map[$Key]
    }
    return $Default
}

function Get-DefenseImprovementBonus {
    param(
        [int]$TypeId,
        [int]$Level
    )

    if ($Level -le 0) { return 0.0 }
    if ($TypeId -in 6, 43, 45, 48) { return 0.20 * $Level }
    if ($TypeId -eq 7) { return 0.25 * $Level }
    if ($TypeId -eq 47) { return 0.50 * [math]::Sqrt($Level) }
    return 0.0
}

function Get-MaxProficiencyBonus {
    param([int]$TypeId)

    # Internal proficiency 120 contributes sqrt(120/10). Fighters also receive
    # the category bonus of 22; keeping the fractional part is required before
    # the squadron-level floor operation.
    $internalBonus = [math]::Sqrt(120.0 / 10.0)
    if ($TypeId -in 6, 43, 45, 48) { return 22.0 + $internalBonus }
    if ($TypeId -in $script:reconTypeIds) { return $internalBonus }
    if ($TypeId -in 7, 8, 11, 47, 57) { return $internalBonus }
    return 0
}

function Get-ReconMultiplier {
    param(
        [int]$TypeId,
        [int]$Search
    )

    switch ($TypeId) {
        9 {
            if ($Search -ge 9) { return 1.30 }
            return 1.20
        }
        { $_ -in 10, 41 } {
            if ($Search -ge 9) { return 1.16 }
            if ($Search -eq 8) { return 1.13 }
            return 1.10
        }
        49 {
            if ($Search -ge 9) { return 1.23 }
            if ($Search -eq 8) { return 1.18 }
            return 1.00
        }
        default { return 1.00 }
    }
}

function Get-HighAltitudeMultiplier {
    param([int]$RocketCount)

    if ($RocketCount -le 0) { return 0.50 }
    if ($RocketCount -eq 1) { return 0.80 }
    if ($RocketCount -eq 2) { return 1.10 }
    return 1.20
}

function Get-DefenseStatus {
    param(
        [int]$AirPower,
        [int]$Enemy
    )

    if ($Enemy -le 0) { return '未指定敌制空' }
    if ($AirPower -ge (3 * $Enemy)) { return '制空权确保' }
    if ($AirPower -ge [math]::Ceiling(1.5 * $Enemy)) { return '航空优势' }
    if ($AirPower -gt ((2.0 / 3.0) * $Enemy)) { return '航空均衡' }
    if ($AirPower -gt ((1.0 / 3.0) * $Enemy)) { return '航空劣势' }
    return '制空权丧失'
}

$const = Get-PoiData -BaseUrl $BaseUrl -Type 'const'
$masterEquips = Get-KcpsConstEquips -Const $const
$masterShips = Get-KcpsConstShips -Const $const
$ownedEquips = Get-PoiData -BaseUrl $BaseUrl -Type 'equips'
$ownedShips = Get-PoiData -BaseUrl $BaseUrl -Type 'ships'
$landBases = @(Get-PoiData -BaseUrl $BaseUrl -Type 'landBasedAirCorps')

$locations = @{}
foreach ($ship in $ownedShips.Values) {
    $shipMasterId = [string](Get-MapValue -Map $ship -Key 'api_ship_id')
    $shipName = if ($masterShips.ContainsKey($shipMasterId)) {
        [string]$masterShips[$shipMasterId]['api_name']
    } else {
        "舰船#$shipMasterId"
    }

    $slotNo = 0
    foreach ($slotId in @(Get-MapValue -Map $ship -Key 'api_slot' -Default @())) {
        $slotNo++
        if ([int]$slotId -gt 0) {
            $locations[[string]$slotId] = "$shipName 主槽$slotNo"
        }
    }
    $extraSlotId = [int](Get-MapValue -Map $ship -Key 'api_slot_ex' -Default 0)
    if ($extraSlotId -gt 0) {
        $locations[[string]$extraSlotId] = "$shipName 补强增设"
    }
}

foreach ($base in $landBases) {
    $areaId = [int](Get-MapValue -Map $base -Key 'api_area_id')
    $baseName = [string](Get-MapValue -Map $base -Key 'api_name' -Default "基地航空队")
    foreach ($plane in @(Get-MapValue -Map $base -Key 'api_plane_info' -Default @())) {
        $slotId = [int](Get-MapValue -Map $plane -Key 'api_slotid')
        if ($slotId -gt 0) {
            $squadronId = [int](Get-MapValue -Map $plane -Key 'api_squadron_id')
            $locations[[string]$slotId] = "区域$areaId $baseName 第${squadronId}槽"
        }
    }
}

$planes = foreach ($instanceEntry in $ownedEquips.GetEnumerator()) {
    $instance = $instanceEntry.Value
    $masterId = [int](Get-MapValue -Map $instance -Key 'api_slotitem_id')
    if ($masterId -in $ExcludedMasterIds) { continue }
    $masterKey = [string]$masterId
    if (-not $masterEquips.ContainsKey($masterKey)) { continue }

    $master = $masterEquips[$masterKey]
    $type = @(Get-MapValue -Map $master -Key 'api_type' -Default @())
    if ($type.Count -lt 3) { continue }
    $typeId = [int]$type[2]
    if ($typeId -notin $aircraftTypeIds) { continue }

    $antiAir = [int](Get-MapValue -Map $master -Key 'api_tyku')
    $search = [int](Get-MapValue -Map $master -Key 'api_saku')
    $isRecon = $typeId -in $reconTypeIds
    if ($antiAir -le 0 -and -not $isRecon) { continue }

    $instanceId = [int](Get-MapValue -Map $instance -Key 'api_id')
    if ($instanceId -in $ExcludedInstanceIds) { continue }
    $level = [int](Get-MapValue -Map $instance -Key 'api_level')
    $interception = if ($typeId -in @(43, 48)) { [int](Get-MapValue -Map $master -Key 'api_houk') } else { 0 }
    $antiBomber = if ($typeId -in @(43, 48)) { [int](Get-MapValue -Map $master -Key 'api_houm') } else { 0 }
    $improvement = Get-DefenseImprovementBonus -TypeId $typeId -Level $level
    $proficiency = if ($ProficiencyMode -eq 'Max') {
        Get-MaxProficiencyBonus -TypeId $typeId
    } else {
        0
    }
    $equivalentAntiAir = $antiAir + $improvement + $interception + (2 * $antiBomber)
    $unitPower = Get-KcpsDefensePlaneAirPower -Master $master -AircraftCount $SlotSize -Improvement $improvement -ProficiencyBonus $proficiency
    $location = if ($locations.ContainsKey([string]$instanceId)) {
        [string]$locations[[string]$instanceId]
    } else {
        '仓库'
    }

    [pscustomobject]@{
        InstanceId = $instanceId
        MasterId = $masterId
        Name = [string](Get-MapValue -Map $master -Key 'api_name')
        Level = $level
        TypeId = $typeId
        AntiAir = $antiAir
        Interception = $interception
        AntiBomber = $antiBomber
        Search = $search
        Radius = [int](Get-MapValue -Map $master -Key 'api_distance')
        IsRocket = $masterId -in $rocketMasterIds
        IsRecon = $isRecon
        ReconMultiplier = Get-ReconMultiplier -TypeId $typeId -Search $search
        EquivalentAntiAir = [math]::Round($equivalentAntiAir, 2)
        UnitPower = $unitPower
        Location = $location
        PreferredLocation = ($PreferredAreaId -gt 0 -and $location -like "区域$PreferredAreaId *")
    }
}

function Select-BestPlanes {
    param(
        [object[]]$Pool,
        [int]$Count,
        [int[]]$ExcludedInstanceIds = @()
    )

    if ($Count -le 0) { return @() }
    return @($Pool |
        Where-Object { $_.InstanceId -notin $ExcludedInstanceIds } |
        Sort-Object `
            @{ Expression = 'UnitPower'; Descending = $true },
            @{ Expression = 'AntiBomber'; Descending = $true },
            @{ Expression = 'PreferredLocation'; Descending = $true },
            @{ Expression = { $_.Location -eq '仓库' }; Descending = $true },
            @{ Expression = 'Level'; Descending = $true },
            @{ Expression = 'InstanceId'; Descending = $false } |
        Select-Object -First $Count)
}

$fighters = @($planes | Where-Object { -not $_.IsRecon })
$rockets = @($fighters | Where-Object IsRocket)
$fighterPool = @($fighters |
    Sort-Object `
        @{ Expression = 'UnitPower'; Descending = $true },
        @{ Expression = 'AntiBomber'; Descending = $true },
        @{ Expression = 'InstanceId'; Descending = $false } |
    Select-Object -First 24)
$fighterPool = @($fighterPool + $rockets |
    Group-Object InstanceId |
    ForEach-Object { $_.Group[0] } |
    Sort-Object `
        @{ Expression = 'UnitPower'; Descending = $true },
        @{ Expression = 'AntiBomber'; Descending = $true },
        @{ Expression = 'InstanceId'; Descending = $false })
$reconCandidates = @($planes |
    Where-Object IsRecon |
    Group-Object ReconMultiplier |
    ForEach-Object {
        $_.Group |
            Sort-Object `
                @{ Expression = 'UnitPower'; Descending = $true },
                @{ Expression = 'PreferredLocation'; Descending = $true },
                @{ Expression = { $_.Location -eq '仓库' }; Descending = $true },
                @{ Expression = 'InstanceId'; Descending = $false } |
            Select-Object -First $CorpsCount
    })

function New-SquadCandidate {
    param(
        [Parameter(Mandatory)][object[]]$Selected,
        [object]$Recon
    )

    $rawPower = [int](($Selected | Measure-Object -Property UnitPower -Sum).Sum)
    $reconMultiplier = if ($null -eq $Recon) { 1.0 } else { [double]$Recon.ReconMultiplier }
    $afterRecon = [int][math]::Floor($rawPower * $reconMultiplier)
    $ordered = @($Selected |
        Sort-Object `
            @{ Expression = 'AntiBomber'; Descending = $true },
            @{ Expression = 'UnitPower'; Descending = $true },
            @{ Expression = 'InstanceId'; Descending = $false })
    return [pscustomobject]@{
        RawAirPower = $rawPower
        ReconMultiplier = $reconMultiplier
        AfterReconAirPower = $afterRecon
        RocketCount = @($Selected | Where-Object IsRocket).Count
        InstanceIds = @($Selected | ForEach-Object InstanceId)
        Slots = $ordered
    }
}

$candidates = [System.Collections.Generic.List[object]]::new()
$n = $fighterPool.Count
for ($a = 0; $a -lt $n - 3; $a++) {
    for ($b = $a + 1; $b -lt $n - 2; $b++) {
        for ($c = $b + 1; $c -lt $n - 1; $c++) {
            for ($e = $c + 1; $e -lt $n; $e++) {
                $candidates.Add((New-SquadCandidate -Selected @($fighterPool[$a], $fighterPool[$b], $fighterPool[$c], $fighterPool[$e]) -Recon $null))
            }
        }
    }
}
foreach ($recon in $reconCandidates) {
    for ($a = 0; $a -lt $n - 2; $a++) {
        for ($b = $a + 1; $b -lt $n - 1; $b++) {
            for ($c = $b + 1; $c -lt $n; $c++) {
                $candidates.Add((New-SquadCandidate -Selected @($recon, $fighterPool[$a], $fighterPool[$b], $fighterPool[$c]) -Recon $recon))
            }
        }
    }
}

$candidateLimitPerRocket = [math]::Max(350, $Top * 80)
$candidatePool = @($candidates |
    Group-Object { [math]::Min(3, [int]$_.RocketCount) } |
    ForEach-Object {
        $_.Group |
            Sort-Object `
                @{ Expression = 'AfterReconAirPower'; Descending = $true },
                @{ Expression = 'RawAirPower'; Descending = $true } |
            Select-Object -First $candidateLimitPerRocket
    })
for ($i = 0; $i -lt $candidatePool.Count; $i++) {
    Add-Member -InputObject $candidatePool[$i] -NotePropertyName CandidateIndex -NotePropertyValue $i
}

$states = @([pscustomobject]@{
    Corps = @()
    UsedInstanceIds = @()
    SumAfterRecon = 0
    TotalRawAirPower = 0
    TotalRocketCount = 0
    LastCandidateIndex = -1
})
$stateLimitPerRocket = [math]::Max(500, $Top * 100)
for ($corpsNo = 1; $corpsNo -le $CorpsCount; $corpsNo++) {
    $nextStates = [System.Collections.Generic.List[object]]::new()
    foreach ($state in $states) {
        foreach ($candidate in $candidatePool) {
            if ([int]$candidate.CandidateIndex -le [int]$state.LastCandidateIndex) { continue }
            if (@($candidate.InstanceIds | Where-Object { $_ -in $state.UsedInstanceIds }).Count -gt 0) { continue }
            $nextStates.Add([pscustomobject]@{
                Corps = @($state.Corps) + @($candidate)
                UsedInstanceIds = @($state.UsedInstanceIds) + @($candidate.InstanceIds)
                SumAfterRecon = [int]$state.SumAfterRecon + [int]$candidate.AfterReconAirPower
                TotalRawAirPower = [int]$state.TotalRawAirPower + [int]$candidate.RawAirPower
                TotalRocketCount = [int]$state.TotalRocketCount + [int]$candidate.RocketCount
                LastCandidateIndex = [int]$candidate.CandidateIndex
            })
        }
    }
    $states = @($nextStates |
        Group-Object { [math]::Min(3, [int]$_.TotalRocketCount) } |
        ForEach-Object {
            $_.Group |
                Sort-Object `
                    @{ Expression = 'SumAfterRecon'; Descending = $true },
                    @{ Expression = 'TotalRawAirPower'; Descending = $true },
                    @{ Expression = 'TotalRocketCount'; Descending = $false } |
                Select-Object -First $stateLimitPerRocket
        })
}

$plans = foreach ($state in $states) {
    $altitudeMultiplier = if ($RaidType -eq 'HighAltitude') {
        Get-HighAltitudeMultiplier -RocketCount ([int]$state.TotalRocketCount)
    } else {
        1.0
    }
    $finalPower = [int][math]::Floor([int]$state.SumAfterRecon * $altitudeMultiplier)
    $corpsOutput = @($state.Corps | ForEach-Object {
        $squad = $_
        [pscustomobject]@{
            RawAirPower = [int]$squad.RawAirPower
            ReconMultiplier = [double]$squad.ReconMultiplier
            AfterReconAirPower = [int]$squad.AfterReconAirPower
            RocketCount = [int]$squad.RocketCount
            Slots = @($squad.Slots | ForEach-Object {
                [pscustomobject]@{
                    InstanceId = $_.InstanceId
                    Name = $_.Name
                    Level = $_.Level
                    MasterId = $_.MasterId
                    AntiAir = $_.AntiAir
                    Interception = $_.Interception
                    AntiBomber = $_.AntiBomber
                    Search = $_.Search
                    Radius = $_.Radius
                    IsRocket = $_.IsRocket
                    IsRecon = $_.IsRecon
                    EquivalentAntiAir = $_.EquivalentAntiAir
                    UnitPower = $_.UnitPower
                }
            })
        }
    })
    [pscustomobject]@{
        RaidType = $RaidType
        CorpsCount = $CorpsCount
        FinalAirPower = $finalPower
        Status = Get-DefenseStatus -AirPower $finalPower -Enemy $EnemyAirPower
        TotalRawAirPower = [int]$state.TotalRawAirPower
        AfterReconAirPower = [int]$state.SumAfterRecon
        HighAltitudeMultiplier = $altitudeMultiplier
        TotalRocketCount = [int]$state.TotalRocketCount
        TargetAirPower = $TargetAirPower
        TargetMargin = if ($TargetAirPower -gt 0) { $finalPower - $TargetAirPower } else { $null }
        Corps = $corpsOutput
        RawAirPower = if ($CorpsCount -eq 1) { $corpsOutput[0].RawAirPower } else { $null }
        ReconMultiplier = if ($CorpsCount -eq 1) { $corpsOutput[0].ReconMultiplier } else { $null }
        RocketCount = if ($CorpsCount -eq 1) { $corpsOutput[0].RocketCount } else { [int]$state.TotalRocketCount }
        Slots = if ($CorpsCount -eq 1) { $corpsOutput[0].Slots } else { @() }
    }
}

$warnings = @()
if (((Get-Date).Date - [datetime]::ParseExact($ruleCheckedOn, 'yyyy-MM-dd', $null)).TotalDays -gt 30) {
    $warnings += "公式与火箭战斗机清单已超过30天未核对：$ruleCheckedOn。请先检查日文Wiki和游戏更新。"
}

[pscustomobject]@{
    GeneratedAt = (Get-Date).ToString('o')
    FormulaCheckedOn = $ruleCheckedOn
    FormulaSource = $ruleSource
    RaidType = $RaidType
    ProficiencyMode = $ProficiencyMode
    AssumptionKind = 'Baseline'
    ProficiencyNote = '按显式选择的零熟练或满熟练基线计算，不代表账号飞机当前的实际内部熟练度。'
    SlotSize = $SlotSize
    CorpsCount = $CorpsCount
    EnemyAirPower = $EnemyAirPower
    TargetAirPower = $TargetAirPower
    InventoryPolicy = '枚举账号全部装备实例；当前占用不影响候选选择；可按实例或装备主数据排除同一配置已占用的装备。'
    ExcludedInstanceIds = $ExcludedInstanceIds
    ExcludedMasterIds = $ExcludedMasterIds
    HardcodedRocketMasterIds = $rocketMasterIds
    Warnings = $warnings
    Plans = @($plans |
        Sort-Object `
            @{ Expression = 'FinalAirPower'; Descending = $true },
            @{ Expression = 'AfterReconAirPower'; Descending = $true },
            @{ Expression = 'TotalRocketCount'; Descending = $false } |
        Select-Object -First $Top)
} | ConvertTo-Json -Depth 12
