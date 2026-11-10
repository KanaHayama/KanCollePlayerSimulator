[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][string]$AccountSnapshotPath,
    [Parameter(Mandatory)][string]$SourcesDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory
)

. (Join-Path $PSScriptRoot 'KCPS-SortieAnalysisCommon.ps1')

function Get-Permutations {
    param([object[]]$Items)

    if ($Items.Count -le 1) {
        return ,@($Items)
    }
    $result = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Items.Count; $index++) {
        $head = $Items[$index]
        $tail = @()
        for ($tailIndex = 0; $tailIndex -lt $Items.Count; $tailIndex++) {
            if ($tailIndex -ne $index) {
                $tail += $Items[$tailIndex]
            }
        }
        foreach ($suffix in (Get-Permutations -Items $tail)) {
            $result.Add(@($head) + @($suffix))
        }
    }
    return $result.ToArray()
}

function Get-DictionaryEntry {
    param($Dictionary, [string]$Key)

    if ($Dictionary -is [System.Collections.IDictionary]) {
        return $Dictionary[$Key]
    }
    return $Dictionary.PSObject.Properties[$Key].Value
}

function Resolve-Equipment {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$ShipInstanceId,
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[int]]$UsedEquipmentIds
    )

    $masterEquips = $Snapshot['Constants']['$equips']
    $matchingMasterIds = @(
        foreach ($entry in $masterEquips.GetEnumerator()) {
            if ([string]$entry.Value['api_name'] -eq $Name) {
                [int]$entry.Key
            }
        }
    )
    if ($matchingMasterIds.Count -eq 0) {
        throw "Equipment master not found: $Name"
    }

    $ship = $Snapshot['Ships'][[string]$ShipInstanceId]
    $onShip = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($equipmentId in @($ship['api_slot']) + @($ship['api_slot_ex'])) {
        if ([int]$equipmentId -gt 0) {
            $onShip.Add([int]$equipmentId) | Out-Null
        }
    }

    $candidates = @(
        @(
            foreach ($entry in $Snapshot['Equips'].GetEnumerator()) {
                $equipment = $entry.Value
                $equipmentId = [int]$equipment['api_id']
                if (
                    $matchingMasterIds -contains [int]$equipment['api_slotitem_id'] -and
                    -not $UsedEquipmentIds.Contains($equipmentId)
                ) {
                    [pscustomobject]@{
                        Equipment = $equipment
                        IsOnTargetShip = $onShip.Contains($equipmentId)
                    }
                }
            }
        ) | Sort-Object `
            @{ Expression = 'IsOnTargetShip'; Descending = $true }, `
            @{ Expression = { [int]$_.Equipment['api_level'] }; Descending = $true }, `
            @{ Expression = { [int]$_.Equipment['api_alv'] }; Descending = $true }, `
            @{ Expression = { [int]$_.Equipment['api_id'] }; Descending = $false }
    )

    if ($candidates.Count -eq 0) {
        throw "No owned equipment is available for: $Name"
    }
    $selected = $candidates[0].Equipment
    $UsedEquipmentIds.Add([int]$selected['api_id']) | Out-Null
    return $selected
}

function Convert-PlayerShip {
    param(
        [Parameter(Mandatory)][int]$ShipInstanceId,
        [Parameter(Mandatory)]$Loadout,
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[int]]$UsedEquipmentIds,
        [Parameter(Mandatory)]$InitialState,
        $BonusProfile,
        [Parameter(Mandatory)]$BattleNodes
    )

    $ship = $Snapshot['Ships'][[string]$ShipInstanceId]
    if ($null -eq $ship) {
        throw "Ship instance not found: $ShipInstanceId"
    }
    $masterId = [int]$ship['api_ship_id']
    $masterShip = $Snapshot['Constants']['$ships'][[string]$masterId]
    if ($null -eq $masterShip) {
        throw "Ship master not found: $masterId"
    }
    $resolvedState = Get-KcpsAnalysisShipState -ShipId $ShipInstanceId -Ship $ship -Master $masterShip -InitialState $InitialState

    $equipmentInputs = [System.Collections.Generic.List[object]]::new()
    foreach ($name in @($Loadout['MainSlots'])) {
        $equipment = Resolve-Equipment `
            -Name ([string]$name) `
            -ShipInstanceId $ShipInstanceId `
            -Snapshot $Snapshot `
            -UsedEquipmentIds $UsedEquipmentIds
        $equipmentInputs.Add([ordered]@{
            masterId = [int]$equipment['api_slotitem_id']
            improve = [int]$equipment['api_level']
            proficiency = Get-KcpsAnalysisProficiency -Equipment $equipment -InitialState $InitialState -IsAircraft ([int]$Snapshot['Constants']['$equips'][[string]$equipment['api_slotitem_id']]['api_type'][2] -in @(6,7,8,9,10,11,25,26,41,43,45,47,48,53,57,58))
            instanceId = [int]$equipment['api_id']
        })
    }
    if (
        $Loadout.Contains('ExtraSlot') -and
        -not [string]::IsNullOrWhiteSpace([string]$Loadout['ExtraSlot']) -and
        [int]$ship['api_slot_ex'] -ne 0
    ) {
        $equipment = Resolve-Equipment `
            -Name ([string]$Loadout['ExtraSlot']) `
            -ShipInstanceId $ShipInstanceId `
            -Snapshot $Snapshot `
            -UsedEquipmentIds $UsedEquipmentIds
        $equipmentInputs.Add([ordered]@{
            masterId = [int]$equipment['api_slotitem_id']
            improve = [int]$equipment['api_level']
            proficiency = Get-KcpsAnalysisProficiency -Equipment $equipment -InitialState $InitialState -IsAircraft ([int]$Snapshot['Constants']['$equips'][[string]$equipment['api_slotitem_id']]['api_type'][2] -in @(6,7,8,9,10,11,25,26,41,43,45,47,48,53,57,58))
            instanceId = [int]$equipment['api_id']
        })
    }

    $input = [ordered]@{
        masterId = $masterId
        LVL = [int]$ship['api_lv']
        HPInit = $resolvedState['Hp']
        morale = $resolvedState['Morale']
        fuelInit = $resolvedState['FuelFraction']
        ammoInit = $resolvedState['AmmoFraction']
        stats = [ordered]@{
            HP = [int]$ship['api_maxhp']
            FP = [int]$ship['api_karyoku'][0]
            TP = [int]$ship['api_raisou'][0]
            AA = [int]$ship['api_taiku'][0]
            AR = [int]$ship['api_soukou'][0]
            LUK = [int]$ship['api_lucky'][0]
            EV = [int]$ship['api_kaihi'][0]
            ASW = [int]$ship['api_taisen'][0]
            LOS = [int]$ship['api_sakuteki'][0]
            RNG = [int]$ship['api_leng']
            SPD = [int]$ship['api_soku']
            SLOTS = @($masterShip['api_maxeq'])
            type = [int]$masterShip['api_stype']
        }
        equips = $equipmentInputs
        kcps = [ordered]@{
            shipInstanceId = $ShipInstanceId
            shipName = [string]$masterShip['api_name']
            loadoutName = [string]$Loadout['Name']
            resolvedInitialState = $resolvedState
        }
    }

    if ($BonusProfile['Applicability'] -eq 'Applicable') {
        $shipBonus = $BonusProfile['ShipBonuses'][[string]$ShipInstanceId]
        if ($null -eq $shipBonus -or -not $shipBonus.Contains('DefaultDamage')) { throw '所选舰船缺少已核实的 DefaultDamage；不能把未知增伤默认为1。' }
        if ($null -ne $shipBonus) {
            if ($shipBonus.Contains('DefaultDamage')) {
                $input.bonuses = [ordered]@{
                    bonusDmg = Get-KcpsBoundedAnalysisNumber $shipBonus['DefaultDamage'] 0.000001 100 '活动伤害倍率'
                }
            }
            if ($shipBonus.Contains('ByNode')) {
                $byNode = [ordered]@{}
                for ($nodeIndex = 0; $nodeIndex -lt $BattleNodes.Count; $nodeIndex++) {
                    $label = [string]$BattleNodes[$nodeIndex]['Label']
                    if ($shipBonus['ByNode'].Contains($label)) {
                        $byNode[[string]($nodeIndex + 1)] = [ordered]@{
                            bonusDmg = Get-KcpsBoundedAnalysisNumber $shipBonus['ByNode'][$label] 0.000001 100 '节点活动伤害倍率'
                        }
                    }
                }
                if ($byNode.Count -gt 0) {
                    $input.bonusesByNode = $byNode
                }
            }
        }
    }

    return $input
}

function Convert-EnemyFleet {
    param([Parameter(Mandatory)]$Entry)

    if ($Entry.Contains('escortFleet') -and @($Entry['escortFleet']).Count -gt 0) { throw '当前适配器尚不支持敌方联合舰队，不能只模拟主队后生成概率。' }
    if (@($Entry['mainFleet']).Count -eq 0) { throw '敌方主舰队数据缺失，未生成概率。' }

    $ships = [System.Collections.Generic.List[object]]::new()
    foreach ($enemy in @($Entry['mainFleet'])) {
        $equips = [System.Collections.Generic.List[object]]::new()
        foreach ($masterId in @($enemy['equips'])) {
            if ([int]$masterId -gt 0) {
                $equips.Add([ordered]@{
                    masterId = [int]$masterId
                    improve = 0
                    proficiency = 0
                })
            }
        }
        $ships.Add([ordered]@{
            masterId = [int]$enemy['id']
            LVL = [int]$enemy['lvl']
            HPInit = [int]$enemy['hp']
            stats = [ordered]@{
                HP = [int]$enemy['hp']
                TP = [int]$enemy['torp']
                AR = [int]$enemy['armor']
            }
            equips = $equips
        })
    }
    return [ordered]@{
        fleet = [ordered]@{
            ships = $ships
            formation = [int]$Entry['formation']
        }
        weight = [int]$Entry['count']
    }
}

$request = Read-KcpsJsonHashtable -Path $RequestPath
Assert-KcpsAnalysisRequest -Request $request
$snapshot = Read-KcpsJsonHashtable -Path $AccountSnapshotPath
Assert-KcpsPrivateOutputPath -Path $OutputDirectory
[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

$shipOrders = [System.Collections.Generic.List[object]]::new()
if ([bool]$request['FleetSearch']['PermuteShipOrder']) {
    foreach ($order in @(Get-Permutations -Items @($request['FleetSearch']['VariableShipInstanceIds']))) {
        $shipOrders.Add(@($order))
    }
} else {
    $shipOrders.Add(@($request['FleetSearch']['VariableShipInstanceIds']))
}
$loadoutOrders = [System.Collections.Generic.List[object]]::new()
if ([bool]$request['FleetSearch']['PermuteLoadoutAssignment']) {
    foreach ($order in @(Get-Permutations -Items @($request['FleetSearch']['LoadoutSets']))) {
        $loadoutOrders.Add(@($order))
    }
} else {
    $loadoutOrders.Add(@($request['FleetSearch']['LoadoutSets']))
}

$enemyByNode = [ordered]@{}
foreach ($node in $request['BattleNodes']) {
    $label = [string]$node['Label']
    $sourcePath = Join-Path $SourcesDirectory "$($request['Map'])-$label-d$($request['Difficulty'])-enemycomps.json"
    $source = Read-KcpsJsonHashtable -Path $sourcePath
    $enemyByNode[$label] = @($source['Data']['result']['entries'])
    if ($enemyByNode[$label].Count -eq 0 -or @($enemyByNode[$label] | Where-Object { [int]$_['count'] -le 0 }).Count -gt 0) { throw '敌方编成或观测权重缺失，未生成概率。' }
}

$manifest = [ordered]@{
    SchemaVersion = 2
    Kind = 'KcpsEventSortieCandidateManifest'
    RequestPath = $RequestPath
    AccountSnapshotPath = $AccountSnapshotPath
    RequestSha256 = Get-KcpsSha256 -Text ($request | ConvertTo-Json -Depth 100 -Compress)
    GeneratedAtJst = Get-KcpsJapanTimestamp
    Candidates = [System.Collections.Generic.List[object]]::new()
}
$scenarioIndex = 0

foreach ($shipOrder in $shipOrders) {
    foreach ($loadoutOrder in $loadoutOrders) {
        foreach ($profile in $request['BonusProfiles']) {
            $scenarioIndex++
            $positionSpecs = [ordered]@{}
            foreach ($fixed in $request['FleetSearch']['FixedPositions']) {
                $positionSpecs[[string]$fixed['Position']] = [ordered]@{
                    ShipInstanceId = [int]$fixed['ShipInstanceId']
                    Loadout = $fixed['Loadout']
                }
            }
            for ($index = 0; $index -lt $request['FleetSearch']['VariablePositions'].Count; $index++) {
                $position = [string]$request['FleetSearch']['VariablePositions'][$index]
                $positionSpecs[$position] = [ordered]@{
                    ShipInstanceId = [int]$shipOrder[$index]
                    Loadout = $loadoutOrder[$index]
                }
            }

            $usedEquipmentIds = [System.Collections.Generic.HashSet[int]]::new()
            $playerShipsByPosition = [ordered]@{}
            foreach ($position in $request['FleetSearch']['EquipmentResolutionPositionOrder']) {
                $positionKey = [string]$position
                $spec = $positionSpecs[$positionKey]
                $playerShipsByPosition[$positionKey] = Convert-PlayerShip `
                    -ShipInstanceId ([int]$spec['ShipInstanceId']) `
                    -Loadout $spec['Loadout'] `
                    -Snapshot $snapshot `
                    -UsedEquipmentIds $usedEquipmentIds `
                    -InitialState $request['Simulation']['InitialState'] `
                    -BonusProfile $profile `
                    -BattleNodes $request['BattleNodes']
            }

            $playerShips = [System.Collections.Generic.List[object]]::new()
            foreach ($position in 1..$positionSpecs.Count) {
                $playerShips.Add($playerShipsByPosition[[string]$position])
            }
            $resolvedShips = @($playerShips | ForEach-Object { $_['kcps']['resolvedInitialState'] })
            $initial = $request['Simulation']['InitialState']
            $assumptions = [ordered]@{
                StateKind = [string]$initial['Kind']
                Source = [string]$initial['Source']
                InputState = $initial
                ResolvedShips = $resolvedShips
                FullSupply = @($resolvedShips | Where-Object { $_['FuelFraction'] -ne 1 -or $_['AmmoFraction'] -ne 1 }).Count -eq 0
                SupplyPolicy = "按输入 $($initial['Supply']['Mode']) 逐舰解析燃料与弹药比例"
                StartingHpPolicy = "按输入 $($initial['Hp']['Mode']) 逐舰解析耐久，不自动修复"
                MoralePolicy = "按输入 $($initial['Morale']['Mode']) 逐舰解析士气"
                ShipAircraftProficiency = [ordered]@{
                    Mode = [string]$initial['ShipAircraftProficiency']['Mode']
                    InternalPolicy = 'NotModeled'
                    Equipment = @($playerShips | ForEach-Object { $_['equips'] } | Where-Object { [int]$snapshot['Constants']['$equips'][[string]$_['masterId']]['api_type'][2] -in @(6,7,8,9,10,11,25,26,41,43,45,47,48,53,57,58) } | ForEach-Object { [ordered]@{ InstanceId=$_['instanceId']; DisplayRank=$_['proficiency'] } })
                }
                LandBaseAircraftProficiency = $initial['LandBaseAircraftProficiency']
                BonusRole = [string]$profile['Role']
                EventBonusPolicy = if ($profile['Applicability'] -eq 'NotApplicable') { "已核实本场景无适用活动增伤，倍率1；来源：$($profile['Source'])，核对日期：$($profile['LastVerifiedJst'])" } else { "按已核实的逐舰/逐节点伤害倍率计算；来源：$($profile['Source'])，核对日期：$($profile['LastVerifiedJst'])" }
                DependencyPolicy = '单舰队固定路线的一次航次内按引擎传递状态；跨航次变化不在当前模型内'
            }
            Assert-KcpsAnalysisAssumptions -Assumptions $assumptions

            $nodes = [System.Collections.Generic.List[object]]::new()
            foreach ($node in $request['BattleNodes']) {
                $comps = [System.Collections.Generic.List[object]]::new()
                foreach ($entry in $enemyByNode[[string]$node['Label']]) {
                    $comps.Add((Convert-EnemyFleet -Entry $entry))
                }
                $nodes.Add([ordered]@{
                    label = [string]$node['Label']
                    formationOverride = [int]$node['Formation']
                    noAmmo = [bool]$node['SubOnly']
                    airRaid = if ($node.Contains('AirRaid')) {
                        [bool]$node['AirRaid']
                    } else {
                        $false
                    }
                    airOnly = if ($node.Contains('AirOnly')) {
                        [bool]$node['AirOnly']
                    } else {
                        $false
                    }
                    doNB = if ($node.Contains('NightBattle')) {
                        [bool]$node['NightBattle']
                    } else {
                        $false
                    }
                    fleetEComps = $comps
                })
            }

            $scenario = [ordered]@{
                numSims = [int]$request['Simulation']['NumSims']
                fleetF = [ordered]@{
                    ships = $playerShips
                    formation = [int]$request['BattleNodes'][0]['Formation']
                }
                nodes = $nodes
                continueOnTaiha = $false
                carryOverHP = $false
                carryOverMorale = $false
                allowAnyFormation = $true
                kcps = [ordered]@{
                    requestName = [string]$request['Name']
                    candidateIndex = $scenarioIndex
                    bonusProfile = [string]$profile['Name']
                    goal = $request['Goal']
                    routeEdges = $request['RouteEdges']
                    assumptions = $assumptions
                }
            }

            $fileName = ('candidate-{0:d4}-{1}.json' -f $scenarioIndex, ([string]$profile['Name'] -replace '[^A-Za-z0-9_-]', '_'))
            $scenarioPath = Join-Path $OutputDirectory $fileName
            Write-KcpsJson -Value $scenario -Path $scenarioPath
            $manifest.Candidates.Add([ordered]@{
                Index = $scenarioIndex
                File = $fileName
                FileSha256 = (Get-FileHash -LiteralPath $scenarioPath -Algorithm SHA256).Hash.ToLowerInvariant()
                BonusProfile = [string]$profile['Name']
                BonusRole = [string]$profile['Role']
                Assumptions = $assumptions
                ShipOrder = @($playerShips | ForEach-Object { $_['kcps']['shipInstanceId'] })
                LoadoutOrder = @($playerShips | ForEach-Object { $_['kcps']['loadoutName'] })
            })
        }
    }
}

$manifestPath = Join-Path $OutputDirectory 'candidates.manifest.json'
Write-KcpsJson -Value $manifest -Path $manifestPath
[pscustomobject]@{
    ManifestPath = $manifestPath
    CandidateCount = $manifest.Candidates.Count
}
