#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ShipPlanJson,

    [Parameter(Mandatory = $true)]
    [double]$Coefficient,

    [Parameter(Mandatory = $true)]
    [double]$Threshold,

    [int]$HeadquartersLevel = 0,

    [switch]$AuditSingleRetreat,

    [switch]$AuditPairRetreat,

    [string]$BaseUrl = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

function Get-EquipmentCoefficient {
    param([int]$TypeId)

    switch ($TypeId) {
        8 { return 0.8 }   # 舰攻
        9 { return 1.0 }   # 舰侦
        10 { return 1.2 }  # 水侦
        11 { return 1.1 }  # 水爆
        58 { return 0.8 }  # 喷气攻击机
        94 { return 1.0 }  # 舰侦II
        { $_ -in @(1, 2, 6, 7, 12, 13, 14, 22, 24, 25, 26, 29, 32, 34, 35, 39, 40, 41, 42, 45, 51, 56, 57, 91, 93, 95) } {
            return 0.6
        }
        default {
            throw "尚未登记装备类型 $TypeId 的33式装备系数，请先按最新日文Wiki更新工具。"
        }
    }
}

function Get-ImprovementCoefficient {
    param([int]$TypeId)

    switch ($TypeId) {
        { $_ -in @(9, 10, 94) } { return 1.2 }
        11 { return 1.15 }
        12 { return 1.25 }
        { $_ -in @(13, 93) } { return 1.4 }
        26 { return 1.0 }
        41 { return 1.2 }
        default { return 0.0 }
    }
}

function ConvertTo-PlanArray {
    param([object]$Value)

    if ($Value -is [System.Collections.IDictionary]) { return @($Value) }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return @($Value)
    }
    throw 'ShipPlanJson必须是对象数组。'
}

$plan = ConvertTo-PlanArray -Value ($ShipPlanJson | ConvertFrom-Json -AsHashtable)
if ($plan.Count -lt 1) {
    throw '舰队方案不能为空。'
}

$duplicateIds = @($plan | Group-Object { [string]$_['Id'] } | Where-Object Count -gt 1)
if ($duplicateIds.Count -gt 0) {
    throw "舰队方案含重复舰船ID：$($duplicateIds.Name -join ', ')"
}

$ships = Get-PoiData -Type ships -BaseUrl $BaseUrl
$ownedEquipments = Get-PoiData -Type equips -BaseUrl $BaseUrl
$const = Get-PoiData -Type const -BaseUrl $BaseUrl
if ($HeadquartersLevel -le 0) {
    $basic = Get-PoiData -Type basic -BaseUrl $BaseUrl
    $HeadquartersLevel = [int]$basic['api_level']
}

$equipmentMastersByName = @{}
foreach ($master in @($const['$equips'].Values)) {
    $name = [string]$master['api_name']
    if (-not $equipmentMastersByName.ContainsKey($name)) {
        $equipmentMastersByName[$name] = @()
    }
    $equipmentMastersByName[$name] += $master
}

$effectiveEquipmentNamesByShipId = @{}
foreach ($shipPlan in $plan) {
    $shipId = [string]$shipPlan['Id']
    if (-not $ships.ContainsKey($shipId)) {
        throw "账号中找不到舰船ID：$shipId"
    }
    $ship = $ships[$shipId]
    $names = @()
    if ($shipPlan.ContainsKey('Slots') -and $shipPlan['Slots'] -is [System.Collections.IDictionary]) {
        foreach ($slotKey in @($shipPlan['Slots'].Keys | Sort-Object { [int]$_ })) {
            if ([int]$slotKey -eq 6 -and [int]$ship['api_slot_ex'] -eq 0) {
                continue
            }
            $names += [string]$shipPlan['Slots'][$slotKey]
        }
    } else {
        $names = @($shipPlan['Equipments'] | ForEach-Object { [string]$_ })
    }
    $effectiveEquipmentNamesByShipId[$shipId] = @($names | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
}

$requestCounts = @{}
foreach ($shipPlan in $plan) {
    if (-not $shipPlan.ContainsKey('Id')) {
        throw '每个舰船方案都必须包含Id。'
    }
    foreach ($equipmentName in @($effectiveEquipmentNamesByShipId[[string]$shipPlan['Id']])) {
        $name = [string]$equipmentName
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if (-not $requestCounts.ContainsKey($name)) { $requestCounts[$name] = 0 }
        $requestCounts[$name]++
    }
}

$minimumLevelsByName = @{}
foreach ($entry in $requestCounts.GetEnumerator()) {
    $name = [string]$entry.Key
    if (-not $equipmentMastersByName.ContainsKey($name) -or @($equipmentMastersByName[$name]).Count -ne 1) {
        throw "装备名称无法唯一匹配：$name"
    }
    $master = @($equipmentMastersByName[$name])[0]
    $instances = @($ownedEquipments.Values | Where-Object {
        [int]$_['api_slotitem_id'] -eq [int]$master['api_id']
    })
    if ($instances.Count -lt [int]$entry.Value) {
        throw "装备数量不足：$name，需要$($entry.Value)，账号有$($instances.Count)。"
    }
    $minimumLevelsByName[$name] = [int](@($instances | Sort-Object { [int]$_['api_level'] })[0]['api_level'])
}

$shipRows = @()
foreach ($shipPlan in $plan) {
    $shipId = [string]$shipPlan['Id']
    if (-not $ships.ContainsKey($shipId)) {
        throw "账号中找不到舰船ID：$shipId"
    }
    $ship = $ships[$shipId]
    $shipMaster = $const['$ships'][[string]$ship['api_ship_id']]
    $rawLos = [double]$ship['api_sakuteki'][0]
    $equipmentContribution = 0.0
    $equipmentRows = @()

    foreach ($equipmentName in @($effectiveEquipmentNamesByShipId[$shipId])) {
        $name = [string]$equipmentName
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $master = @($equipmentMastersByName[$name])[0]
        $typeId = [int]$master['api_type'][2]
        $baseLos = [double]$master['api_saku']
        $level = [int]$minimumLevelsByName[$name]
        $improvementCoefficient = Get-ImprovementCoefficient -TypeId $typeId
        $equipmentCoefficient = if ($baseLos -eq 0 -and $improvementCoefficient -eq 0) {
            0.0
        } else {
            Get-EquipmentCoefficient -TypeId $typeId
        }
        $contribution = ($baseLos + $improvementCoefficient * [math]::Sqrt($level)) * $equipmentCoefficient
        $equipmentContribution += $contribution
        $equipmentRows += [ordered]@{
            Name = $name
            TypeId = $typeId
            BaseLos = $baseLos
            ConservativeLevel = $level
            ContributionBeforeBranchCoefficient = [math]::Round($contribution, 4)
        }
    }

    $shipRows += [ordered]@{
        Id = [int]$shipId
        Name = [string]$shipMaster['api_name']
        CanRetreat = if ($shipPlan.ContainsKey('CanRetreat')) { [bool]$shipPlan['CanRetreat'] } else { $true }
        RawLos = $rawLos
        ShipContribution = [math]::Sqrt($rawLos)
        EquipmentContributionBeforeBranchCoefficient = $equipmentContribution
        Equipments = @($equipmentRows)
    }
}

function Get-Los33Score {
    param([object[]]$Rows)

    $shipContribution = [double](($Rows | ForEach-Object {
        [double]$_['ShipContribution']
    } | Measure-Object -Sum).Sum)
    $equipmentContribution = [double](($Rows | ForEach-Object {
        [double]$_['EquipmentContributionBeforeBranchCoefficient']
    } | Measure-Object -Sum).Sum)
    $headquartersPenalty = [math]::Ceiling($HeadquartersLevel * 0.4)
    $shipCountCorrection = 2 * (6 - $Rows.Count)
    return $shipContribution + ($equipmentContribution * $Coefficient) - $headquartersPenalty + $shipCountCorrection
}

$fullScore = Get-Los33Score -Rows $shipRows
$retreatResults = @()
if ($AuditSingleRetreat) {
    foreach ($retreated in @($shipRows | Where-Object { [bool]$_['CanRetreat'] })) {
        $remaining = @($shipRows | Where-Object { [int]$_['Id'] -ne [int]$retreated['Id'] })
        $score = Get-Los33Score -Rows $remaining
        $retreatResults += [ordered]@{
            RetreatedShipId = [int]$retreated['Id']
            RetreatedShipName = [string]$retreated['Name']
            Score = [math]::Round($score, 4)
            Margin = [math]::Round($score - $Threshold, 4)
            Pass = ($score -ge $Threshold)
        }
    }
}

$pairRetreatResults = @()
if ($AuditPairRetreat) {
    $retreatableRows = @($shipRows | Where-Object { [bool]$_['CanRetreat'] })
    for ($firstIndex = 0; $firstIndex -lt $retreatableRows.Count - 1; $firstIndex++) {
        for ($secondIndex = $firstIndex + 1; $secondIndex -lt $retreatableRows.Count; $secondIndex++) {
            $first = $retreatableRows[$firstIndex]
            $second = $retreatableRows[$secondIndex]
            $remaining = @($shipRows | Where-Object {
                [int]$_['Id'] -notin @([int]$first['Id'], [int]$second['Id'])
            })
            $score = Get-Los33Score -Rows $remaining
            $pairRetreatResults += [ordered]@{
                RetreatedShipIds = @([int]$first['Id'], [int]$second['Id'])
                RetreatedShipNames = @([string]$first['Name'], [string]$second['Name'])
                Score = [math]::Round($score, 4)
                Margin = [math]::Round($score - $Threshold, 4)
                Pass = ($score -ge $Threshold)
            }
        }
    }
}

$auditedResults = @($retreatResults) + @($pairRetreatResults)
$minimumScore = if ($auditedResults.Count -gt 0) {
    [double](($auditedResults | ForEach-Object {
        [double]$_['Score']
    } | Measure-Object -Minimum).Minimum)
} else {
    $fullScore
}

[ordered]@{
    Formula = '33式'
    HeadquartersLevel = $HeadquartersLevel
    BranchCoefficient = $Coefficient
    Threshold = $Threshold
    FullFleetScore = [math]::Round($fullScore, 4)
    FullFleetMargin = [math]::Round($fullScore - $Threshold, 4)
    SingleRetreatAudited = [bool]$AuditSingleRetreat
    SingleRetreatResults = @($retreatResults)
    PairRetreatAudited = [bool]$AuditPairRetreat
    PairRetreatResults = @($pairRetreatResults)
    MinimumAuditedScore = [math]::Round($minimumScore, 4)
    MinimumMargin = [math]::Round($minimumScore - $Threshold, 4)
    Pass = ($fullScore -ge $Threshold -and $minimumScore -ge $Threshold)
    ConservativeAssumptions = @(
        '同名装备按账号中最低改修等级重复估算，避免因KCPS分配顺序高估索敌。',
        '舰船素索敌使用poi实时api_sakuteki[0]；装备使用方案中的名称，不读取生成后的配置。',
        '若方案使用Slots映射，则账号中未开放的补强增设槽不会计入索敌。'
    )
    Ships = @($shipRows)
} | ConvertTo-Json -Depth 12
