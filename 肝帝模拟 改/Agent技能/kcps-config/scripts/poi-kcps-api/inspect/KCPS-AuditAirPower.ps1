#requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [hashtable]$Targets = @{},

    [string]$BaseUrl = '',

    [string]$SnapshotPath = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

$config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
$snapshot = if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
    $null
} else {
    Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json -AsHashtable
}

$const = if ($null -eq $snapshot) { Get-PoiData -BaseUrl $BaseUrl -Type 'const' } else { $snapshot['const'] }
$ships = Get-KcpsConstShips -Const $const
$equips = Get-KcpsConstEquips -Const $const
$memberShips = if ($null -eq $snapshot) { Get-PoiData -BaseUrl $BaseUrl -Type 'ships' } else { $snapshot['ships'] }
$memberEquips = if ($null -eq $snapshot) { Get-PoiData -BaseUrl $BaseUrl -Type 'equips' } else { $snapshot['equips'] }

$equipByName = @{}
foreach ($entry in $equips.GetEnumerator()) {
    $equip = $entry.Value
    $name = [string]$equip['api_name']
    if (-not $equipByName.ContainsKey($name)) {
        $equipByName[$name] = $equip
    }
}

$improvementLevelsByName = @{}
foreach ($memberEquip in @($memberEquips.Values)) {
    $masterId = [string]$memberEquip['api_slotitem_id']
    if (-not $equips.ContainsKey($masterId)) { continue }
    $name = [string]$equips[$masterId]['api_name']
    if (-not $improvementLevelsByName.ContainsKey($name)) {
        $improvementLevelsByName[$name] = @()
    }
    $improvementLevelsByName[$name] = @($improvementLevelsByName[$name]) + [int]$memberEquip['api_level']
}

function Get-MemberShipFromRefitShip {
    param([hashtable]$Ship)

    $memo = [string]$Ship['Memo']
    if ($memo -match '(?:#|\()\s*(?<id>\d+)\)?') {
        $memberShipId = [string]$Matches['id']
        if ($memberShips.ContainsKey($memberShipId)) {
            return $memberShips[$memberShipId]
        }
    }
    return $null
}

function Test-AirPowerEquipment {
    param([hashtable]$Equip)

    if ($null -eq $Equip) { return $false }
    if ([int]$Equip['api_tyku'] -le 0) { return $false }
    $typeId = [int]$Equip['api_type'][2]
    $airPowerTypeIds = @(
        6,  # 艦上戦闘機
        7,  # 艦上爆撃機
        8,  # 艦上攻撃機
        9,  # 艦上偵察機
        10, # 水上偵察機
        11, # 水上爆撃機
        25, # オートジャイロ
        26, # 対潜哨戒機
        41, # 大型飛行艇
        43, # 水上戦闘機
        45, # 夜間戦闘機
        57  # 噴式戦闘爆撃機
    )
    return $airPowerTypeIds -contains $typeId
}

function Get-BaseAirPower {
    param(
        [int]$SlotSize,
        [hashtable]$Equip
    )

    if ($SlotSize -le 0 -or -not (Test-AirPowerEquipment -Equip $Equip)) { return 0 }
    return [math]::Floor([math]::Sqrt($SlotSize) * [int]$Equip['api_tyku'])
}

function Get-ImprovedAirPower {
    param(
        [int]$SlotSize,
        [hashtable]$Equip,
        [int]$ImprovementLevel
    )

    if ($SlotSize -le 0 -or -not (Test-AirPowerEquipment -Equip $Equip)) { return 0 }
    $typeId = [int]$Equip['api_type'][2]
    $coefficient = switch ($typeId) {
        { $_ -in 6, 43, 45 } { 0.2; break } # 艦戦・水戦・夜戦
        7 { 0.25; break }                    # 爆戦系
        default { 0.0 }
    }
    return [math]::Floor(([int]$Equip['api_tyku'] + $coefficient * $ImprovementLevel) * [math]::Sqrt($SlotSize))
}

function Get-MaxProficiencyAirPowerBonus {
    param([hashtable]$Equip)

    if (-not (Test-AirPowerEquipment -Equip $Equip)) { return 0 }
    $typeId = [int]$Equip['api_type'][2]

    switch ($typeId) {
        6  { return 25 } # 艦上戦闘機
        43 { return 25 } # 水上戦闘機
        45 { return 25 } # 夜間戦闘機
        7  { return 3 }  # 艦上爆撃機
        8  { return 3 }  # 艦上攻撃機
        11 { return 9 }  # 水上爆撃機
        57 { return 3 }  # 噴式戦闘爆撃機
        default { return 0 }
    }
}

function Test-FighterAirPowerEquipment {
    param([hashtable]$Equip)

    if (-not (Test-AirPowerEquipment -Equip $Equip)) { return $false }
    $typeId = [int]$Equip['api_type'][2]
    return $typeId -in 6, 43, 45
}

function Get-FighterMaxProficiencyAirPowerBonus {
    param([hashtable]$Equip)

    if (Test-FighterAirPowerEquipment -Equip $Equip) {
        return Get-MaxProficiencyAirPowerBonus -Equip $Equip
    }
    return 0
}

$rows = foreach ($cfg in @($config)) {
    $refit = @($cfg['List'] | Where-Object { [string]$_['Type'] -like '*BasicRefitEquipmentWorkflow*' } | Select-Object -First 1)
    if ($refit.Count -eq 0) { continue }

    $contributors = @()
    $total = 0
    $fighterMaxOnlyTotal = 0
    $allMaxProficiencyTotal = 0
    $conservativeImprovedTotal = 0
    $conservativeImprovedFighterMaxOnlyTotal = 0
    $conservativeImprovedAllMaxTotal = 0
    $optimisticImprovedTotal = 0
    $optimisticImprovedFighterMaxOnlyTotal = 0
    $optimisticImprovedAllMaxTotal = 0
    foreach ($ship in @($refit[0]['Ships'])) {
        $memberShip = Get-MemberShipFromRefitShip -Ship $ship
        if ($null -eq $memberShip) { continue }
        $shipConstId = [int]$memberShip['api_ship_id']
        if (-not $ships.ContainsKey([string]$shipConstId)) { continue }
        $shipConst = $ships[[string]$shipConstId]
        $shipName = [string]$shipConst['api_name']
        # 格纳库增设过的舰个体带 api_onslot_max（各格实际上限，可大于 master api_maxeq）；没扩张过的舰没有此字段
        $maxeq = if ($memberShip.ContainsKey('api_onslot_max')) { @($memberShip['api_onslot_max']) } else { @($shipConst['api_maxeq']) }

        foreach ($slot in @($ship['Slots'])) {
            $slotNo = [int]$slot['Slot']
            if ($slotNo -eq 6 -or $slotNo -le 0 -or $slotNo -gt $maxeq.Count) { continue }
            $equipSelector = @($slot['Equipments'] | Select-Object -First 1)
            if ($equipSelector.Count -eq 0) { continue }
            $equipName = [string]$equipSelector[0]['SelectValue']
            if (-not $equipByName.ContainsKey($equipName)) { continue }
            $equip = $equipByName[$equipName]
            $slotSize = [int]$maxeq[$slotNo - 1]
            $airPower = Get-BaseAirPower -SlotSize $slotSize -Equip $equip
            if ($airPower -gt 0) {
                $levels = if ($improvementLevelsByName.ContainsKey($equipName)) {
                    @($improvementLevelsByName[$equipName])
                } else {
                    @(0)
                }
                $minLevel = [int](($levels | Measure-Object -Minimum).Minimum)
                $maxLevel = [int](($levels | Measure-Object -Maximum).Maximum)
                $conservativeImprovedAirPower = Get-ImprovedAirPower -SlotSize $slotSize -Equip $equip -ImprovementLevel $minLevel
                $optimisticImprovedAirPower = Get-ImprovedAirPower -SlotSize $slotSize -Equip $equip -ImprovementLevel $maxLevel
                $fighterMaxOnlyBonus = Get-FighterMaxProficiencyAirPowerBonus -Equip $equip
                $allMaxProficiencyBonus = Get-MaxProficiencyAirPowerBonus -Equip $equip
                $total += $airPower
                $fighterMaxOnlyTotal += $airPower + $fighterMaxOnlyBonus
                $allMaxProficiencyTotal += $airPower + $allMaxProficiencyBonus
                $conservativeImprovedTotal += $conservativeImprovedAirPower
                $conservativeImprovedFighterMaxOnlyTotal += $conservativeImprovedAirPower + $fighterMaxOnlyBonus
                $conservativeImprovedAllMaxTotal += $conservativeImprovedAirPower + $allMaxProficiencyBonus
                $optimisticImprovedTotal += $optimisticImprovedAirPower
                $optimisticImprovedFighterMaxOnlyTotal += $optimisticImprovedAirPower + $fighterMaxOnlyBonus
                $optimisticImprovedAllMaxTotal += $optimisticImprovedAirPower + $allMaxProficiencyBonus
                $contributors += [pscustomobject]@{
                    Ship = $shipName
                    Slot = $slotNo
                    Size = $slotSize
                    Equipment = $equipName
                    TypeId = [int]$equip['api_type'][2]
                    AntiAir = [int]$equip['api_tyku']
                    BaseAirPower = $airPower
                    ConservativeImprovementLevel = $minLevel
                    ConservativeImprovedBaseAirPower = $conservativeImprovedAirPower
                    OptimisticImprovementLevel = $maxLevel
                    OptimisticImprovedBaseAirPower = $optimisticImprovedAirPower
                    FighterMaxOnlyBonus = $fighterMaxOnlyBonus
                    FighterMaxOnlyAirPowerEstimate = $airPower + $fighterMaxOnlyBonus
                    AllMaxProficiencyBonus = $allMaxProficiencyBonus
                    AllMaxProficiencyAirPowerEstimate = $airPower + $allMaxProficiencyBonus
                }
            }
        }
    }

    $target = $null
    if ($Targets.ContainsKey($cfg['Name'])) {
        $target = [int]$Targets[$cfg['Name']]
    }

    [pscustomobject]@{
        Config = $cfg['Name']
        BaseAirPower = $total
        FighterMaxOnlyAirPowerEstimate = $fighterMaxOnlyTotal
        AllMaxProficiencyAirPowerEstimate = $allMaxProficiencyTotal
        ConservativeImprovedBaseAirPowerEstimate = $conservativeImprovedTotal
        ConservativeImprovedFighterMaxOnlyAirPowerEstimate = $conservativeImprovedFighterMaxOnlyTotal
        ConservativeImprovedAllMaxProficiencyAirPowerEstimate = $conservativeImprovedAllMaxTotal
        OptimisticImprovedBaseAirPowerEstimate = $optimisticImprovedTotal
        OptimisticImprovedFighterMaxOnlyAirPowerEstimate = $optimisticImprovedFighterMaxOnlyTotal
        OptimisticImprovedAllMaxProficiencyAirPowerEstimate = $optimisticImprovedAllMaxTotal
        Target = $target
        Margin = $(if ($null -ne $target) { $total - $target } else { $null })
        Ratio = $(if ($null -ne $target -and $target -gt 0) { [math]::Round($total / $target, 2) } else { $null })
        FighterMaxOnlyMarginEstimate = $(if ($null -ne $target) { $fighterMaxOnlyTotal - $target } else { $null })
        FighterMaxOnlyRatioEstimate = $(if ($null -ne $target -and $target -gt 0) { [math]::Round($fighterMaxOnlyTotal / $target, 2) } else { $null })
        AllMaxProficiencyMarginEstimate = $(if ($null -ne $target) { $allMaxProficiencyTotal - $target } else { $null })
        AllMaxProficiencyRatioEstimate = $(if ($null -ne $target -and $target -gt 0) { [math]::Round($allMaxProficiencyTotal / $target, 2) } else { $null })
        Contributors = @($contributors)
    }
}

$rows | ConvertTo-Json -Depth 20
