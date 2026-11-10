#requires -Version 7.0

Set-StrictMode -Version Latest
. "$PSScriptRoot\KCPS-Connection.ps1"
. "$PSScriptRoot\KCPS-RouteData.ps1"
. "$PSScriptRoot\KCPS-RefitSlots.ps1"
. "$PSScriptRoot\KCPS-CombinedFleet.ps1"
. "$PSScriptRoot\KCPS-WorkflowReferences.ps1"
. "$PSScriptRoot\KCPS-StagePolicies.ps1"

function Read-KcpsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([IO.Path]::GetFileName($Path) -eq 'KCPS-RouteSpecs.json') {
        return Import-KcpsRouteDatabase -Path $Path
    }
    if ([IO.Path]::GetFileName($Path) -eq 'KCPS-LandBasedAirCorpsTargetRadii.json') {
        return Import-KcpsLandBaseRadiusEvidence -Path $Path
    }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
}

$script:KcpsRelatedWorkflowCollectionKeys = @(
    'OrganizeBeforeWorkflows',
    'OrganizeAfterWorkflows',
    'SubroutineBeforeWorkflows',
    'SubroutineAfterWorkflows',
    'RefitBeforeOrganizeWorkflows',
    'RefitAfterOrganizeWorkflows',
    'RefitEquipmentBeforeWorkflows',
    'RefitEquipmentAfterWorkflows',
    'ScrapShipBeforeWorkflows',
    'ScrapShipAfterWorkflows',
    'QuestBeforeWorkflows',
    'QuestAfterWorkflows',
    'DockingBeforeWorkflows',
    'DockingAfterWorkflows',
    'SupplyBeforeWorkflows',
    'SupplyAfterWorkflows',
    'ResupplyBeforeWorkflows',
    'ResupplyAfterWorkflows',
    'BeforeLoopsEnableWorkflows',
    'BeforeLoopsDisableWorkflows',
    'BeforeLoopsTriggerWorkflows',
    'AfterLoopsEnableWorkflows',
    'AfterLoopsDisableWorkflows',
    'AfterLoopsTriggerWorkflows',
    'AutoStoppedEnableWorkflows',
    'AutoStoppedDisableWorkflows',
    'AutoStoppedTriggerWorkflows',
    'AutoStoppedDisableWhenDisabled',
    'AutoStoppedDisableWhenStopped',
    'AutoStoppedTriggerWhenDisabled',
    'AutoStoppedTriggerWhenStopped'
)

$script:KcpsJsonCollectionKeys = @(
    $script:KcpsRelatedWorkflowCollectionKeys
    'ConditionalStrategies',
    'Positions',
    'Selections',
    'SelectShipArgs',
    'Ships',
    'Slots',
    'Equipments',
    'Quests',
    'Strategies',
    'AreaClearBonusSelections'
)

function Test-KcpsArrayLike {
    param([object]$Value)

    return ($Value -is [System.Collections.IEnumerable] -and
        -not ($Value -is [string]) -and
        -not ($Value -is [System.Collections.IDictionary]))
}

function Normalize-KcpsJsonCollections {
    param([object]$Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $child = $Value[$key]
            if ($script:KcpsJsonCollectionKeys -contains [string]$key) {
                if ($null -eq $child) {
                    $Value[$key] = @()
                } elseif (Test-KcpsArrayLike -Value $child) {
                    $Value[$key] = @($child | ForEach-Object { Normalize-KcpsJsonCollections -Value $_ })
                } else {
                    $Value[$key] = @(Normalize-KcpsJsonCollections -Value $child)
                }
            } else {
                $Value[$key] = Normalize-KcpsJsonCollections -Value $child
            }
        }
        return $Value
    }

    if (Test-KcpsArrayLike -Value $Value) {
        return @($Value | ForEach-Object { Normalize-KcpsJsonCollections -Value $_ })
    }

    return $Value
}

function Normalize-KcpsRelatedWorkflowCollections {
    param([object]$Value)

    Normalize-KcpsJsonCollections -Value $Value
}

function Write-KcpsJson {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $normalized = Normalize-KcpsJsonCollections -Value $Value
    ConvertTo-Json -InputObject $normalized -Depth 100
}

# ---- 配置形状助手（统一下沉自各脚本，原各处本地副本已移除）----

function Test-MapKey {
    param(
        [object]$Map,
        [string]$Key
    )

    if ($null -eq $Map) { return $false }
    if ($Map -is [System.Collections.IDictionary]) { return $Map.Contains($Key) }
    return $false
}

function Test-KcpsWayPointEmpty {
    param([object]$WayPoint)

    if ($null -eq $WayPoint -or -not ($WayPoint -is [System.Collections.IDictionary])) {
        return $false
    }

    return [string]::IsNullOrWhiteSpace([string]$WayPoint['Name']) -and
        [string]::IsNullOrWhiteSpace([string]$WayPoint['Memo']) -and
        [math]::Abs([double]$WayPoint['Left']) -lt 0.000000001 -and
        [math]::Abs([double]$WayPoint['Top']) -lt 0.000000001 -and
        [math]::Abs([double]$WayPoint['Width']) -lt 0.000000001 -and
        [math]::Abs([double]$WayPoint['Height']) -lt 0.000000001
}

function Test-KcpsWayPointValid {
    param([object]$WayPoint)

    if ($null -eq $WayPoint -or -not ($WayPoint -is [System.Collections.IDictionary])) {
        return $false
    }

    $left = [double]$WayPoint['Left']
    $top = [double]$WayPoint['Top']
    $width = [double]$WayPoint['Width']
    $height = [double]$WayPoint['Height']
    return -not [string]::IsNullOrWhiteSpace([string]$WayPoint['Name']) -and
        $left -ge 0.0 -and $top -ge 0.0 -and
        $width -gt 0.0 -and $height -gt 0.0 -and
        ($left + $width) -le 1.0 -and
        ($top + $height) -le 1.0
}

function Test-KcpsWorkflowType {
    param(
        [System.Collections.IDictionary]$Workflow,
        [string]$TypeName
    )

    return (($Workflow['Type'] -as [string]) -like "*$TypeName*")
}

function Get-KcpsGroups {
    param([object]$Config)

    if ($Config -is [array]) { return @($Config) }
    if (($Config -is [System.Collections.IDictionary]) -and (Test-MapKey -Map $Config -Key 'List')) { return @($Config) }
    throw "Unsupported KCPS config shape: expected one workflow group or an array of workflow groups."
}

function Remove-KcpsHistoricalBossStageLabel {
    param([string]$GroupName)

    if ([string]::IsNullOrWhiteSpace($GroupName)) { return $GroupName }
    return [regex]::Replace(
        $GroupName,
        '(?<point>[A-Z][A-Z0-9]*点)\(P\d+\)',
        '${point}'
    )
}

function Test-KcpsRouteSpecGroupName {
    param(
        [string]$GroupName,
        [System.Collections.IDictionary]$RouteSpec
    )

    if ($null -eq $RouteSpec) { return $false }
    $pattern = [string]$RouteSpec['GroupNameRegex']
    if ([string]::IsNullOrWhiteSpace($pattern)) { return $false }

    if ($GroupName -match $pattern) { return $true }
    $canonicalName = Remove-KcpsHistoricalBossStageLabel -GroupName $GroupName
    return $canonicalName -ne $GroupName -and $canonicalName -match $pattern
}

function Get-KcpsHistoricalBossStageExpectation {
    param(
        [string]$GroupName,
        [System.Collections.IDictionary]$RouteSpec,
        [System.Collections.IDictionary]$RouteSpecDocument
    )

    $nameMatch = [regex]::Match(
        $GroupName,
        '^E(?<area>\d+)\s+P(?<current>\d+)\s+(?:削甲|破甲)\s+(?<point>[A-Z][A-Z0-9]*)点(?:\(P(?<label>\d+)\))?'
    )
    if (-not $nameMatch.Success) { return $null }

    $routeSpecId = if ($null -eq $RouteSpec) { '' } else { [string]$RouteSpec['Id'] }
    $area = [int]$nameMatch.Groups['area'].Value
    $currentPhase = [int]$nameMatch.Groups['current'].Value
    $point = [string]$nameMatch.Groups['point'].Value
    $actualLabel = if ($nameMatch.Groups['label'].Success) {
        'P' + [string]$nameMatch.Groups['label'].Value
    } else {
        $null
    }

    $mappingRows = if ($null -ne $RouteSpecDocument -and (Test-MapKey -Map $RouteSpecDocument -Key 'EventBossStages')) {
        @($RouteSpecDocument['EventBossStages'])
    } else {
        @()
    }
    $matchingMappings = @($mappingRows | Where-Object {
        $row = $_
        [int]$row['Area'] -eq $area -and
        -not [string]::IsNullOrWhiteSpace([string]$row['RouteSpecIdRegex']) -and
        $routeSpecId -match [string]$row['RouteSpecIdRegex']
    })

    $historicalBossPhase = $null
    $expectedLabel = $null
    $source = $null
    if ($matchingMappings.Count -eq 1) {
        $bossPoints = $matchingMappings[0]['BossPoints']
        if ($bossPoints -is [System.Collections.IDictionary] -and $bossPoints.Contains($point)) {
            $historicalBossPhase = [int]$bossPoints[$point]
            if ($historicalBossPhase -gt 0 -and $historicalBossPhase -lt $currentPhase) {
                $expectedLabel = "P$historicalBossPhase"
            }
        }
        $source = [string]$matchingMappings[0]['Source']
    }

    return [ordered]@{
        Area = $area
        CurrentPhase = $currentPhase
        Point = $point
        ActualLabel = $actualLabel
        ExpectedLabel = $expectedLabel
        HistoricalBossPhase = $historicalBossPhase
        MappingCount = $matchingMappings.Count
        RouteSpecId = $routeSpecId
        Source = $source
    }
}

function Get-PoiJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$BaseUrl = ''
    )

    Invoke-KcpsPoiRequest -Path $Path -BaseUrl $BaseUrl -AsHashtable
}

function Get-PoiData {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type,

        [string]$BaseUrl = ''
    )

    Get-PoiJson -BaseUrl $BaseUrl -Path "/data?type=$Type"
}

function Get-KcpsLiveMapGaugeInfo {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Maps,

        [Parameter(Mandatory = $true)]
        [int]$Sea,

        [Parameter(Mandatory = $true)]
        [int]$Area
    )

    $map = $null
    if ($Sea -eq 0) {
        $eventMaps = @($Maps.Values | Where-Object {
            $_ -is [hashtable] -and
            $_.ContainsKey('api_eventmap') -and
            $_.ContainsKey('api_id') -and
            ([int]$_['api_id'] % 10) -eq $Area
        })
        if ($eventMaps.Count -eq 1) {
            $map = $eventMaps[0]
        }
    } else {
        $mapId = ($Sea * 10) + $Area
        if ($Maps.ContainsKey([string]$mapId)) {
            $map = $Maps[[string]$mapId]
        }
    }

    if ($null -eq $map -or -not $map.ContainsKey('api_gauge_type')) {
        return $null
    }

    $apiGaugeType = [int]$map['api_gauge_type']
    $name = switch ($apiGaugeType) {
        1 { 'Finished' }
        2 { 'HP' }
        3 { 'TP' }
        default { 'NotAvailable' }
    }
    $selectableValue = switch ($apiGaugeType) {
        2 { 0 }
        3 { 1 }
        default { $null }
    }

    [pscustomobject]@{
        MapId = [int]$map['api_id']
        ApiGaugeType = $apiGaugeType
        Name = $name
        SelectableValue = $selectableValue
        GaugeNumber = if ($map.ContainsKey('api_gauge_num') -and $null -ne $map['api_gauge_num']) {
            [int]$map['api_gauge_num']
        } else {
            $null
        }
    }
}

function Get-PoiQuestList {
    param(
        [string]$BaseUrl = ''
    )

    Get-PoiJson -BaseUrl $BaseUrl -Path '/response?type=/kcsapi/api_get_member/questlist'
}

function Get-KcpsConstShips {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Const
    )

    $Const['$ships']
}

function Get-KcpsConstEquips {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Const
    )

    $Const['$equips']
}

function Get-KcpsConstShipName {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Const,

        [Parameter(Mandatory = $true)]
        [int]$ShipConstId
    )

    $ships = Get-KcpsConstShips -Const $Const
    $key = [string]$ShipConstId
    if ($ships -and $ships.ContainsKey($key)) {
        $ship = $ships[$key]
        foreach ($nameKey in @('api_name', 'name')) {
            if ($ship.ContainsKey($nameKey) -and $ship[$nameKey]) {
                return $ship[$nameKey]
            }
        }
    }
    return "#$ShipConstId"
}

function Get-KcpsConstEquipName {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Const,

        [Parameter(Mandatory = $true)]
        [int]$EquipConstId
    )

    $equips = Get-KcpsConstEquips -Const $Const
    $key = [string]$EquipConstId
    if ($equips -and $equips.ContainsKey($key)) {
        $equip = $equips[$key]
        foreach ($nameKey in @('api_name', 'name')) {
            if ($equip.ContainsKey($nameKey) -and $equip[$nameKey]) {
                return $equip[$nameKey]
            }
        }
    }
    return "#$EquipConstId"
}

function Get-KcpsLandBasedAirCorpsRadius {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Const,

        [Parameter(Mandatory = $true)]
        [int[]]$EquipConstIds
    )

    if ($EquipConstIds.Count -eq 0) {
        throw 'Cannot calculate land-based air corps radius without airplanes.'
    }

    $equipMasters = Get-KcpsConstEquips -Const $Const
    $reconTypeIds = @(9, 10, 41, 49)
    $planes = @(
        foreach ($equipConstId in $EquipConstIds) {
            $key = [string]$equipConstId
            if ($null -eq $equipMasters -or -not $equipMasters.Contains($key)) {
                throw "Unknown equipment master ID in land-based air corps: $equipConstId"
            }

            $master = $equipMasters[$key]
            $distance = [int]$master['api_distance']
            if ($distance -le 0) {
                throw "Equipment has no usable combat radius: $(Get-KcpsConstEquipName -Const $Const -EquipConstId $equipConstId)"
            }

            $typeIds = @($master['api_type'])
            $typeId = if ($typeIds.Count -gt 2) { [int]$typeIds[2] } else { 0 }
            [pscustomobject]@{
                Id = $equipConstId
                Name = Get-KcpsConstEquipName -Const $Const -EquipConstId $equipConstId
                Distance = $distance
                TypeId = $typeId
                CanExtend = $typeId -in $reconTypeIds
            }
        }
    )

    $minimumRadius = [int](($planes | Measure-Object -Property Distance -Minimum).Minimum)
    $reconPlanes = @($planes | Where-Object { $_.CanExtend })
    $maxReconRadius = if ($reconPlanes.Count -gt 0) {
        [int](($reconPlanes | Measure-Object -Property Distance -Maximum).Maximum)
    } else {
        0
    }

    $extension = 0
    if ($maxReconRadius -gt $minimumRadius) {
        $extension = [int][Math]::Round(
            [Math]::Sqrt($maxReconRadius - $minimumRadius),
            0,
            [MidpointRounding]::AwayFromZero
        )
        $extension = [Math]::Min(3, $extension)
    }

    [pscustomobject]@{
        EffectiveRadius = $minimumRadius + $extension
        MinimumRadius = $minimumRadius
        MaximumReconRadius = $maxReconRadius
        Extension = $extension
        Planes = $planes
    }
}

function Normalize-KcpsEquipmentDisplayName {
    param(
        [AllowEmptyString()]
        [string]$Name
    )

    $normalized = $Name.Trim()
    $normalized = $normalized -replace '\s*巛\d+\s*$', ''
    $normalized = $normalized -replace '\s*★(?:\+\d+|\d+|max)\s*$', ''
    return $normalized.Trim()
}

function Normalize-KcpsLandBaseMemoEquipmentName {
    param(
        [AllowEmptyString()]
        [string]$Name
    )

    $normalized = Normalize-KcpsEquipmentDisplayName -Name $Name
    $replacements = [ordered]@{
        '陸' = '陆'; '偵' = '侦'; '機' = '机'; '飛' = '飞'; '龍' = '龙'
        '練' = '练'; '銀' = '银'; '隊' = '队'; '戦' = '战'; '誘' = '诱'
        '導' = '导'; '弾' = '弹'; '試' = '试'; '製' = '制'; '電' = '电'
        '闘' = '斗'; '東' = '东'; '艦' = '舰'; '號' = '号'; 'イ号' = '一号'
        '伊号' = '一号'
    }
    foreach ($entry in $replacements.GetEnumerator()) {
        $normalized = $normalized.Replace($entry.Key, $entry.Value)
    }
    $normalized = $normalized -replace '[\s（）()]', ''
    $normalized = $normalized.Replace('一号一型甲诱导弹', '一号诱导弹')
    return $normalized.Trim()
}

function Get-KcpsFleetShipMap {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Fleets
    )

    $map = @{}
    foreach ($fleet in $Fleets) {
        $fleetId = [int]$fleet['api_id']
        foreach ($shipId in $fleet['api_ship']) {
            if ([int]$shipId -gt 0) {
                $map[[string]$shipId] = $fleetId
            }
        }
    }
    $map
}

function Get-KcpsEquipmentHolderMap {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Ships,

        [Parameter(Mandatory = $true)]
        [hashtable]$Const
    )

    $map = @{}
    foreach ($entry in $Ships.GetEnumerator()) {
        $ship = $entry.Value
        $shipId = [int]$ship['api_id']
        $shipName = Get-KcpsConstShipName -Const $Const -ShipConstId ([int]$ship['api_ship_id'])
        $slotIndex = 0
        foreach ($equipId in $ship['api_slot']) {
            $slotIndex++
            if ([int]$equipId -gt 0) {
                $map[[string]$equipId] = [pscustomobject]@{
                    ShipId = $shipId
                    ShipName = $shipName
                    Slot = $slotIndex
                    ExtraSlot = $false
                }
            }
        }
        $extra = [int]$ship['api_slot_ex']
        if ($extra -gt 0) {
            $map[[string]$extra] = [pscustomobject]@{
                ShipId = $shipId
                ShipName = $shipName
                Slot = 6
                ExtraSlot = $true
            }
        }
    }
    $map
}

function Test-KcpsDeclaredEmptyRefitSlot {
    param([System.Collections.IDictionary]$Ship, [System.Collections.IDictionary]$Slot)
    $match = [regex]::Match([string]$Ship['Memo'], '(?m)^KCPS_ALLOW_EMPTY_SLOTS=(?<Slots>\d+(?:,\d+)*);\s*REASON=(?<Reason>\S[^\r\n]*)$')
    $selectors = @($Slot['Equipments'])
    # 必须显式声明理由，并使用原生单个空字符串选择器卸装。
    return $match.Success -and [int]$Slot['Slot'] -in @($match.Groups['Slots'].Value.Split(',') | ForEach-Object { [int]$_ }) -and
        $selectors.Count -eq 1 -and $selectors[0].Contains('SelectValue') -and
        [int]$selectors[0]['SelectMethod'] -eq 0 -and $null -ne $selectors[0]['SelectValue'] -and
        [string]$selectors[0]['SelectValue'] -ceq '' -and
        -not [bool]$Slot['IgnoreNoEquipmentMatched'] -and
        ([int]$Slot['Slot'] -eq 6 -or -not [bool]$Slot['IgnoreSlotNotAvailable'])
}

function Get-KcpsRefitEquipmentCapacityProblems {
    <#
    .SYNOPSIS
        按 KCPS 的贪心选取顺序审计一个改装流程的装备实例是否足够。
    .DESCRIPTION
        每个装备实例只能占用一个最终槽位。动态选船的支援舰队也会实际消耗装备，
        因此不能因为编成使用脚本候选就跳过数量检查。只有明确声明的卸装槽可以不占库存。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$RefitWorkflows,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$OwnedEquipmentCountsByName
    )

    $problems = @()
    foreach ($refit in @($RefitWorkflows)) {
        $remaining = @{}
        foreach ($name in @($OwnedEquipmentCountsByName.Keys)) {
            $remaining[[string]$name] = [int]$OwnedEquipmentCountsByName[$name]
        }

        $singleExactRequests = @{}
        $singleExactDetails = @{}
        foreach ($ship in @($refit['Ships'])) {
            foreach ($slot in @($ship['Slots'])) {
                if (Test-KcpsDeclaredEmptyRefitSlot -Ship $ship -Slot $slot) { continue }
                $exactCandidates = @()
                $hasNonExactSelector = $false
                foreach ($equipment in @($slot['Equipments'])) {
                    if ([int]$equipment['SelectMethod'] -ne 0) {
                        $hasNonExactSelector = $true
                        continue
                    }

                    $name = [string]$equipment['SelectValue']
                    if (-not [string]::IsNullOrWhiteSpace($name)) {
                        $exactCandidates += $name
                    }
                }

                if (-not $hasNonExactSelector -and $exactCandidates.Count -eq 1 -and -not [bool]$slot['IgnoreNoEquipmentMatched']) {
                    $name = $exactCandidates[0]
                    if (-not $singleExactRequests.ContainsKey($name)) {
                        $singleExactRequests[$name] = 0
                        $singleExactDetails[$name] = @()
                    }
                    $singleExactRequests[$name]++
                    $singleExactDetails[$name] += "fleet$($ship['Fleet']) position$($ship['SelectValue']) slot$($slot['Slot'])"
                }

                $selected = $null
                foreach ($name in $exactCandidates) {
                    if ($remaining.ContainsKey($name) -and [int]$remaining[$name] -gt 0) {
                        $remaining[$name]--
                        $selected = $name
                        break
                    }
                }

                if ($null -eq $selected -and -not $hasNonExactSelector -and -not [bool]$slot['IgnoreNoEquipmentMatched']) {
                    $summary = if ($exactCandidates.Count -gt 0) { $exactCandidates -join ' | ' } else { '<无有效候选>' }
                    $problems += [pscustomobject]@{
                        Category = 'GreedyExhaustion'
                        Workflow = [string]$refit['Name']
                        Fleet = [int]$ship['Fleet']
                        Position = [string]$ship['SelectValue']
                        Ship = [string]$ship['Memo']
                        Slot = [int]$slot['Slot']
                        Equipment = $summary
                        Required = $null
                        Owned = $null
                        Problem = "按改装顺序执行到 fleet$($ship['Fleet']) position$($ship['SelectValue']) slot$($slot['Slot']) 时，候选装备已耗尽：$summary。"
                    }
                }
            }
        }

        foreach ($name in @($singleExactRequests.Keys)) {
            $required = [int]$singleExactRequests[$name]
            $owned = if ($OwnedEquipmentCountsByName.Contains($name)) { [int]$OwnedEquipmentCountsByName[$name] } else { 0 }
            if ($required -le $owned) { continue }

            $problems += [pscustomobject]@{
                Category = 'ExactCapacityShortage'
                Workflow = [string]$refit['Name']
                Fleet = $null
                Position = $null
                Ship = ''
                Slot = $null
                Equipment = $name
                Required = $required
                Owned = $owned
                Problem = "同一改装流程需要 $required 个 '$name'，账号仅有 $owned 个；后续槽位必然失败。请求顺序：$($singleExactDetails[$name] -join ' -> ')。"
            }
        }
    }

    return @($problems)
}

function ConvertTo-KcpsJsonOutput {
    param(
        [Parameter(ValueFromPipeline = $true)]
        [object]$InputObject,

        [int]$Depth = 20
    )

    begin {
        $items = @()
    }

    process {
        $items += $InputObject
    }

    end {
        if ($items.Count -eq 1) {
            $items[0] | ConvertTo-Json -Depth $Depth
        } else {
            $items | ConvertTo-Json -Depth $Depth
        }
    }
}

# ---- 活动海域多号机审计 ----

function Get-KcpsShipRemodelFamilyMap {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Const
    )

    $masters = Get-KcpsConstShips -Const $Const
    $neighbors = @{}
    foreach ($entry in $masters.GetEnumerator()) {
        $id = [int]$entry.Key
        if (-not $neighbors.ContainsKey([string]$id)) {
            $neighbors[[string]$id] = [System.Collections.Generic.HashSet[int]]::new()
        }

        $after = 0
        if ($entry.Value.ContainsKey('api_aftershipid')) {
            [void][int]::TryParse([string]$entry.Value['api_aftershipid'], [ref]$after)
        }
        if ($after -le 0 -or -not $masters.ContainsKey([string]$after)) { continue }

        if (-not $neighbors.ContainsKey([string]$after)) {
            $neighbors[[string]$after] = [System.Collections.Generic.HashSet[int]]::new()
        }
        [void]$neighbors[[string]$id].Add($after)
        [void]$neighbors[[string]$after].Add($id)
    }

    $familyMap = @{}
    $visited = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($startKey in @($neighbors.Keys)) {
        $start = [int]$startKey
        if ($visited.Contains($start)) { continue }

        $queue = [System.Collections.Generic.Queue[int]]::new()
        $component = [System.Collections.Generic.List[int]]::new()
        $queue.Enqueue($start)
        [void]$visited.Add($start)
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            $component.Add($current)
            foreach ($next in $neighbors[[string]$current]) {
                if ($visited.Add($next)) { $queue.Enqueue($next) }
            }
        }

        $familyKey = ($component | Measure-Object -Minimum).Minimum
        foreach ($masterId in $component) {
            $familyMap[[string]$masterId] = [int]$familyKey
        }
    }
    $familyMap
}

function Get-KcpsOwnedShipCopyAudit {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Const,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Ships,

        [Parameter(Mandatory = $true)]
        [object[]]$Fleets
    )

    $familyMap = Get-KcpsShipRemodelFamilyMap -Const $Const
    $fleetMap = Get-KcpsFleetShipMap -Fleets $Fleets
    $fleetById = @{}
    foreach ($fleet in $Fleets) { $fleetById[[string]$fleet['api_id']] = $fleet }

    $ownedByFamily = @{}
    foreach ($entry in $Ships.GetEnumerator()) {
        $ship = $entry.Value
        $masterId = [int]$ship['api_ship_id']
        $familyKey = if ($familyMap.ContainsKey([string]$masterId)) {
            [int]$familyMap[[string]$masterId]
        } else {
            $masterId
        }
        if (-not $ownedByFamily.ContainsKey([string]$familyKey)) {
            $ownedByFamily[[string]$familyKey] = [System.Collections.Generic.List[object]]::new()
        }
        $ownedByFamily[[string]$familyKey].Add($ship)
    }

    $result = @()
    foreach ($familyEntry in $ownedByFamily.GetEnumerator()) {
        $familyKey = [int]$familyEntry.Key
        $owned = @($familyEntry.Value | Sort-Object { [int]$_['api_id'] })
        $locked = @($owned | Where-Object { [int]$_['api_locked'] -eq 1 })
        $lockedOrdinal = @{}
        for ($index = 0; $index -lt $locked.Count; $index++) {
            $lockedOrdinal[[string]$locked[$index]['api_id']] = $index + 1
        }

        $familyNames = @($owned | ForEach-Object {
            Get-KcpsConstShipName -Const $Const -ShipConstId ([int]$_['api_ship_id'])
        } | Select-Object -Unique)

        for ($index = 0; $index -lt $owned.Count; $index++) {
            $ship = $owned[$index]
            $shipId = [int]$ship['api_id']
            $fleetId = if ($fleetMap.ContainsKey([string]$shipId)) { [int]$fleetMap[[string]$shipId] } else { 0 }
            $mission = $null
            if ($fleetId -gt 0 -and $fleetById.ContainsKey([string]$fleetId)) {
                $mission = @($fleetById[[string]$fleetId]['api_mission']) -join ','
            }
            $isLocked = ([int]$ship['api_locked'] -eq 1)

            $result += [pscustomobject]@{
                Id = $shipId
                Name = Get-KcpsConstShipName -Const $Const -ShipConstId ([int]$ship['api_ship_id'])
                MasterId = [int]$ship['api_ship_id']
                FamilyKey = $familyKey
                FamilyNames = $familyNames -join ' / '
                AllOwnedOrder = $index + 1
                CopyNo = if ($isLocked) { [int]$lockedOrdinal[[string]$shipId] } else { $null }
                Numbered = $isLocked
                Classification = if ($isLocked) { 'LockedRetainedCopy' } else { 'UnlockedUnclassified' }
                Locked = $isLocked
                SallyArea = if ($ship.ContainsKey('api_sally_area')) { [int]$ship['api_sally_area'] } else { 0 }
                Level = [int]$ship['api_lv']
                Cond = [int]$ship['api_cond']
                Hp = "{0}/{1}" -f $ship['api_nowhp'], $ship['api_maxhp']
                ExtraSlotAvailable = ($ship.ContainsKey('api_slot_ex') -and [int]$ship['api_slot_ex'] -ne 0)
                Fleet = $fleetId
                Mission = $mission
            }
        }
    }
    @($result | Sort-Object FamilyKey, AllOwnedOrder)
}

function Get-KcpsSortieRequiredMorale {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$SortieWorkflows
    )

    $thresholds = @()
    foreach ($sortie in @($SortieWorkflows)) {
        if ($null -eq $sortie) { continue }
        if ($sortie.ContainsKey('FlagShipMoraleLargerOrEqualThanFlag') -and
            [bool]$sortie['FlagShipMoraleLargerOrEqualThanFlag']) {
            $thresholds += [int]$sortie['FlagShipMoraleLargerOrEqualThanValue']
        }
        if ($sortie.ContainsKey('EscortShipMoraleLargerOrEqualThanFlag') -and
            [bool]$sortie['EscortShipMoraleLargerOrEqualThanFlag']) {
            $thresholds += [int]$sortie['EscortShipMoraleLargerOrEqualThanValue']
        }
    }

    if ($thresholds.Count -eq 0) { return $null }
    return [int](@($thresholds | Measure-Object -Maximum).Maximum)
}

function Get-KcpsHighMoraleSingleLoopProblems {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$SortieWorkflows,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$RelationalWorkflows
    )

    $requiredMorale = Get-KcpsSortieRequiredMorale -SortieWorkflows $SortieWorkflows
    if ($null -eq $requiredMorale -or $requiredMorale -le 49) { return @() }

    $problems = @()
    foreach ($controller in @($RelationalWorkflows)) {
        if ($null -eq $controller) { continue }
        $name = [string]$controller['Name']

        if ([bool]$controller['SleepUntilMoraleRecoveredFlag'] -or
            [bool]$controller['SleepUntilFlagShipMoraleRecoveredFlag']) {
            $problems += [pscustomobject]@{
                Workflow = $name
                RequiredMorale = $requiredMorale
                Problem = 'Morale requirements above 49 cannot use KCPS natural-recovery waiting; both morale wait flags must be false.'
            }
        }

    }

    return @($problems)
}

function Get-KcpsMemoSection {
    param(
        [string]$Memo,
        [string]$Name
    )

    $pattern = '(?ms)' + [regex]::Escape("【$Name】") + '\s*(?<text>.*?)(?=^【|\z)'
    $match = [regex]::Match($Memo, $pattern)
    if (-not $match.Success) { return '' }
    return $match.Groups['text'].Value.Trim()
}

function Get-KcpsMemoLayoutBlockKey {
    param(
        [string]$Section,
        [string]$Line
    )

    if ($Section -eq '陆航') {
        $match = [regex]::Match($Line, '^第\s*(?<number>[123一二三])\s*(?:基地航空队|队)\s*[：:｜|]')
        if ($match.Success) {
            $number = switch ($match.Groups['number'].Value) {
                '一' { 1 }
                '二' { 2 }
                '三' { 3 }
                default { [int]$match.Groups['number'].Value }
            }
            return "基地航空队:$number"
        }
    }

    if ($Section -in @('选船结论', '配装对照')) {
        $match = [regex]::Match($Line, '^第\s*(?<number>[1234一二三四])\s*舰队')
        if ($match.Success) {
            $number = switch ($match.Groups['number'].Value) {
                '一' { 1 }
                '二' { 2 }
                '三' { 3 }
                '四' { 4 }
                default { [int]$match.Groups['number'].Value }
            }
            return "舰队:$number"
        }
    }

    return ''
}

function Get-KcpsMemoBlockSpacingProblems {
    param([AllowEmptyString()][string]$Memo)

    if ([string]::IsNullOrEmpty($Memo)) { return @() }

    $lines = @((($Memo -replace "`r`n?", "`n") -split "`n"))
    $problems = @()
    $section = ''
    $lastBlockKey = ''

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index].TrimEnd()
        $sectionMatch = [regex]::Match($line, '^【(?<name>[^】]+)】\s*$')
        if ($sectionMatch.Success) {
            $section = $sectionMatch.Groups['name'].Value
            $lastBlockKey = ''
            continue
        }

        $blockKey = Get-KcpsMemoLayoutBlockKey -Section $section -Line $line
        if ([string]::IsNullOrWhiteSpace($blockKey)) { continue }

        if (-not [string]::IsNullOrWhiteSpace($lastBlockKey) -and $blockKey -ne $lastBlockKey) {
            $blankCount = 0
            for ($previous = $index - 1; $previous -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$previous]); $previous--) {
                $blankCount++
            }
            if ($blankCount -ne 1) {
                $suffix = if ($section -eq '陆航') { '基地航空队' } else { '舰队' }
                $previousNumber = ($lastBlockKey -split ':')[-1]
                $currentNumber = ($blockKey -split ':')[-1]
                $problems += ('【{0}】第{1}{2}与第{3}{2}之间必须恰好保留一个空行；当前为 {4} 个。' -f
                    $section, $previousNumber, $suffix, $currentNumber, $blankCount)
            }
        }
        $lastBlockKey = $blockKey
    }

    return @($problems)
}

function Get-KcpsSortieIdentityCheckerSpec {
    param([System.Collections.IDictionary]$Sortie)

    if ($null -eq $Sortie) { return $null }
    $metadataMatch = [regex]::Match(
        [string]$Sortie['Script'],
        '(?m)^# KCPS_SORTIE_IDENTITY_CHECKER_SPEC (?<json>\{.*\})\s*$'
    )
    if (-not $metadataMatch.Success) { return $null }
    try {
        return ($metadataMatch.Groups['json'].Value | ConvertFrom-Json -AsHashtable)
    } catch {
        return $null
    }
}

function Get-KcpsMemoLandBasePlan {
    param([string]$Memo)

    $section = Get-KcpsMemoSection -Memo $Memo -Name '陆航'
    $result = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($section)) { return $result }

    $corps = 0
    $result['0'] = [ordered]@{ Action = -1; Slots = @(); TargetPoints = @(); RequiredRadius = $null }
    foreach ($line in @($section -split "`r?`n")) {
        $header = [regex]::Match(
            $line,
            '^第\s*(?<corps>[123一二三])\s*(?:基地航空队|队)\s*[：:｜|]\s*(?<rest>.*)$'
        )
        if ($header.Success) {
            $corps = switch ($header.Groups['corps'].Value) {
                '一' { 1 }
                '二' { 2 }
                '三' { 3 }
                default { [int]$header.Groups['corps'].Value }
            }
            $rest = $header.Groups['rest'].Value
            $actionMatch = [regex]::Match($rest, '(?<action>出击|防空|待机|不使用)')
            $action = switch ($(if ($actionMatch.Success) { $actionMatch.Groups['action'].Value } else { '' })) {
                '出击' { 1 }
                '防空' { 2 }
                '待机' { 0 }
                '不使用' { 0 }
                default { -1 }
            }
            $targetPoints = @()
            if ($action -eq 1) {
                foreach ($match in @([regex]::Matches($rest, '(?<point>[A-Z]+[0-9]*)点'))) {
                    $targetPoints += $match.Groups['point'].Value
                }
                foreach ($match in @([regex]::Matches($rest, '(?:集中|第一波|第二波)\s*(?<point>[A-Z]+[0-9]*)'))) {
                    $targetPoints += $match.Groups['point'].Value
                }
                $targetPoints = @($targetPoints | Select-Object -Unique)
            }
            $radiusMatch = [regex]::Match(
                $rest,
                '(?:所需航程|航程要求|需要航程|目标点(?:所需)?半径|所需半径|航程)[^0-9]{0,12}(?<radius>\d+)'
            )
            $requiredRadius = if ($radiusMatch.Success) {
                [int]$radiusMatch.Groups['radius'].Value
            } else {
                $null
            }
            $result[[string]$corps] = [ordered]@{
                Action = $action
                Slots = @()
                TargetPoints = $targetPoints
                RequiredRadius = $requiredRadius
            }
            continue
        }

        $slot = [regex]::Match($line, '^第\s*(?<slot>[1-4])\s*槽[：:]\s*(?<name>[^｜|\r\n]+)')
        if ($slot.Success) {
            $targetKey = if ($corps -gt 0 -and $result.Contains([string]$corps)) { [string]$corps } else { '0' }
            $result[$targetKey]['Slots'] += [ordered]@{
                Slot = [int]$slot.Groups['slot'].Value
                Name = (Normalize-KcpsEquipmentDisplayName -Name $slot.Groups['name'].Value.Trim())
            }
        }
    }
    if (@($result['0']['Slots']).Count -eq 0) { $null = $result.Remove('0') }
    return $result
}

function Get-KcpsLandBasePlanConsistencyProblems {
    param(
        [System.Collections.IDictionary]$Sortie,
        [AllowNull()][System.Collections.IDictionary]$CheckerSpec,
        [AllowNull()][System.Collections.IDictionary]$RouteSpec,
        [string]$Memo
    )

    $problems = @()
    if ($null -eq $Sortie) { return $problems }
    $memoPlan = Get-KcpsMemoLandBasePlan -Memo $Memo
    $checkerPlan = if ($null -ne $CheckerSpec -and
        $CheckerSpec['LandBases'] -is [System.Collections.IDictionary]) {
        $CheckerSpec['LandBases']
    } else {
        [ordered]@{}
    }
    $routePlan = if ($null -ne $RouteSpec -and
        $RouteSpec.Contains('ExpectedLandBasedAirCorps') -and
        $RouteSpec['ExpectedLandBasedAirCorps'] -is [System.Collections.IDictionary]) {
        $RouteSpec['ExpectedLandBasedAirCorps']
    } else {
        [ordered]@{}
    }

    $activeCorps = @(1..3 | Where-Object {
        [int]$Sortie["LandBasedAirCorps$($_)Action"] -in @(1, 2)
    })
    foreach ($corps in 1..3) {
        $key = [string]$corps
        $actualAction = [int]$Sortie["LandBasedAirCorps${corps}Action"]
        $memoEntry = if ($memoPlan.Contains($key)) { $memoPlan[$key] } else { $null }
        if ($null -eq $memoEntry -and $activeCorps.Count -eq 1 -and $memoPlan.Contains('0')) {
            $memoEntry = $memoPlan['0']
        }
        if ($actualAction -in @(1, 2)) {
            if ($null -eq $memoEntry) {
                $problems += "第 $corps 基地航空队已用于出击或防空，但【陆航】没有对应的动作与逐槽说明。"
            } elseif ([int]$memoEntry['Action'] -ge 0 -and [int]$memoEntry['Action'] -ne $actualAction) {
                $problems += "第 $corps 基地航空队动作不一致：出击执行单元为 $actualAction，备注为 $($memoEntry['Action'])。"
            }
        } elseif ($null -ne $memoEntry -and [int]$memoEntry['Action'] -in @(1, 2)) {
            $problems += "第 $corps 基地航空队备注声明为出击或防空，但出击执行单元设为待机。"
        }

        $expectedRows = @(if ($routePlan.Contains($key)) { @($routePlan[$key]) })
        $checkerRows = @(if ($checkerPlan.Contains($key)) { @($checkerPlan[$key]) })
        $memoRows = @(if ($null -ne $memoEntry) { @($memoEntry['Slots'] | Sort-Object Slot) })
        if ($actualAction -notin @(1, 2)) { continue }

        if ($checkerRows.Count -ne 4) {
            $problems += "第 $corps 基地航空队已用于出击或防空，但身份检查器没有声明4个槽位。"
        }
        if ($memoRows.Count -ne 4) {
            $problems += "第 $corps 基地航空队【陆航】必须逐槽写满4架飞机，当前解析到 $($memoRows.Count) 架。"
        }
        if ($checkerRows.Count -eq 4 -and $memoRows.Count -eq 4) {
            foreach ($slotIndex in 0..3) {
                $checkerName = Normalize-KcpsLandBaseMemoEquipmentName -Name ([string]$checkerRows[$slotIndex]['Name'])
                $memoName = Normalize-KcpsLandBaseMemoEquipmentName -Name ([string]$memoRows[$slotIndex]['Name'])
                if ($checkerName -cne $memoName) {
                    $problems += "第 $corps 基地航空队第 $($slotIndex + 1) 槽备注与身份检查不一致：备注为 $memoName，检查器为 $checkerName。"
                }
            }
        }
        if ($expectedRows.Count -eq 4 -and $memoRows.Count -eq 4) {
            foreach ($slotIndex in 0..3) {
                $expectedName = Normalize-KcpsLandBaseMemoEquipmentName -Name ([string]$expectedRows[$slotIndex]['Name'])
                $memoName = Normalize-KcpsLandBaseMemoEquipmentName -Name ([string]$memoRows[$slotIndex]['Name'])
                if ($expectedName -cne $memoName) {
                    $problems += "第 $corps 基地航空队第 $($slotIndex + 1) 槽备注偏离路线规格：应为 $expectedName，备注为 $memoName。"
                }
            }
        }
    }
    return @($problems)
}

function Get-KcpsLandBaseEquipmentCapacityProblems {
    <#
    .SYNOPSIS
        检查一个出击配置同时使用的基地航空队飞机数量是否超过账号总库存。
    .DESCRIPTION
        身份检查器只核对每个槽的装备主数据 ID，无法发现同一主数据 ID 被重复声明得
        比账号实际持有量更多。本检查按出击或防空中的航空队汇总四槽需求；待机队不计入。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Sortie,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$CheckerSpec,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Equips,

        [AllowNull()]
        [System.Collections.IDictionary]$Const
    )

    $problems = @()
    if (-not ($CheckerSpec['LandBases'] -is [System.Collections.IDictionary])) {
        return @($problems)
    }

    $ownedCounts = @{}
    foreach ($entry in $Equips.GetEnumerator()) {
        $equipmentId = [int]$entry.Value['api_slotitem_id']
        if ($equipmentId -le 0) { continue }
        if (-not $ownedCounts.ContainsKey($equipmentId)) { $ownedCounts[$equipmentId] = 0 }
        $ownedCounts[$equipmentId]++
    }

    $required = @{}
    foreach ($corpsKey in @($CheckerSpec['LandBases'].Keys)) {
        $corps = [int]$corpsKey
        if ($corps -lt 1 -or $corps -gt 3) { continue }
        if ([int]$Sortie["LandBasedAirCorps${corps}Action"] -notin @(1, 2)) { continue }

        $slot = 0
        foreach ($row in @($CheckerSpec['LandBases'][[string]$corps])) {
            $slot++
            $equipmentId = [int]$row['Id']
            if ($equipmentId -le 0) { continue }
            if (-not $required.ContainsKey($equipmentId)) {
                $name = [string]$row['Name']
                if ($null -ne $Const) {
                    $constName = Get-KcpsConstEquipName -Const $Const -EquipConstId $equipmentId
                    if (-not [string]::IsNullOrWhiteSpace($constName)) { $name = $constName }
                }
                $required[$equipmentId] = [ordered]@{
                    Count = 0
                    Name = $name
                    Slots = @()
                }
            }
            $required[$equipmentId]['Count']++
            $required[$equipmentId]['Slots'] += "第${corps}队第${slot}槽"
        }
    }

    foreach ($equipmentId in @($required.Keys)) {
        $need = [int]$required[$equipmentId]['Count']
        $owned = if ($ownedCounts.ContainsKey([int]$equipmentId)) {
            [int]$ownedCounts[[int]$equipmentId]
        } else {
            0
        }
        if ($need -le $owned) { continue }

        $name = [string]$required[$equipmentId]['Name']
        $locations = @($required[$equipmentId]['Slots']) -join '、'
        $problems += [pscustomobject]@{
            Category = 'LandBaseExactCapacityShortage'
            EquipmentId = [int]$equipmentId
            Equipment = $name
            Required = $need
            Owned = $owned
            Slots = $locations
            Problem = "基地航空队同时需要 $need 架 '$name'（主数据ID $equipmentId），账号仅有 $owned 架；涉及 $locations。"
        }
    }

    return @($problems)
}

function Get-KcpsSortieIdentityCheckerProblems {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Group,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Sortie,

        [AllowNull()]
        [System.Collections.IDictionary]$Const,

        [switch]$RequireEnabled
    )

    $problems = @()
    $workflowName = [string]$Sortie['Name']
    $enabled = [bool]$Sortie['EnableScriptSortieChecker']
    if (-not $enabled) {
        if ($RequireEnabled) {
            $problems += [pscustomobject]@{
                Workflow = $workflowName
                Problem = '活动出击必须启用额外出击前检查函数，核对实际出击舰队和使用中的基地航空队配装。'
            }
        }
        return @($problems)
    }

    $script = [string]$Sortie['Script']
    $functionName = [string]$Sortie['SoriteCheckerFunctionName']
    if ($functionName -ne 'OnCheckSortieFleetAndLandBases') {
        $problems += [pscustomobject]@{
            Workflow = $workflowName
            Problem = '额外出击前检查函数名必须为 OnCheckSortieFleetAndLandBases。'
        }
    }
    if ($script -notmatch '(?m)^# KCPS_SORTIE_IDENTITY_CHECKER_BEGIN\s*$' -or
        $script -notmatch '(?m)^# KCPS_SORTIE_IDENTITY_CHECKER_END\s*$') {
        $problems += [pscustomobject]@{
            Workflow = $workflowName
            Problem = '额外出击前检查缺少受管标记，无法可靠校验或更新。'
        }
        return @($problems)
    }

    $metadataMatch = [regex]::Match(
        $script,
        '(?m)^# KCPS_SORTIE_IDENTITY_CHECKER_SPEC (?<json>\{.*\})\s*$'
    )
    if (-not $metadataMatch.Success) {
        $problems += [pscustomobject]@{
            Workflow = $workflowName
            Problem = '额外出击前检查缺少可解析的舰队与陆航声明。'
        }
        return @($problems)
    }

    try {
        $spec = $metadataMatch.Groups['json'].Value | ConvertFrom-Json -AsHashtable
    } catch {
        $problems += [pscustomobject]@{
            Workflow = $workflowName
            Problem = "额外出击前检查声明不是有效 JSON：$($_.Exception.Message)"
        }
        return @($problems)
    }

    if (-not $spec.ContainsKey('Version') -or [int]$spec['Version'] -lt 3) {
        $problems += [pscustomobject]@{
            Workflow = $workflowName
            Problem = '额外出击前检查器版本过旧；旧版不能安全处理空槽或正在配置转换的陆航飞机。'
        }
    }

    $mode = [string]$spec['FleetMode']
    if ($mode -notin @('Single', 'Combined')) {
        $problems += [pscustomobject]@{
            Workflow = $workflowName
            Problem = "FleetMode 必须为 Single 或 Combined，当前为 '$mode'。"
        }
        return @($problems)
    }

    $hasCombinedFleetWorkflow = @($Group['List'] | Where-Object {
        Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicCombinedFleetWorkflow'
    }).Count -gt 0
    $expectedMode = if ($hasCombinedFleetWorkflow) { 'Combined' } else { 'Single' }
    if ($mode -ne $expectedMode) {
        $problems += [pscustomobject]@{
            Workflow = $workflowName
            Problem = "舰队模式声明错误：配置结构为 $expectedMode，检查器声明为 $mode。"
        }
    }

    $expectedFleetNumbers = if ($expectedMode -eq 'Combined') {
        @(1, 2)
    } else {
        @([int]$Sortie['Fleet'])
    }
    $declaredFleets = $spec['Fleets']
    if ($declaredFleets -isnot [System.Collections.IDictionary]) {
        $problems += [pscustomobject]@{
            Workflow = $workflowName
            Problem = '额外出击前检查的 Fleets 必须是按舰队编号声明的对象。'
        }
        return @($problems)
    }
    $declaredFleetNumbers = @($declaredFleets.Keys | ForEach-Object { [int]$_ } | Sort-Object)
    if (($declaredFleetNumbers -join ',') -ne (($expectedFleetNumbers | Sort-Object) -join ',')) {
        $problems += [pscustomobject]@{
            Workflow = $workflowName
            Problem = "舰队检查范围错误：$expectedMode 应检查 [$($expectedFleetNumbers -join ',')]，声明为 [$($declaredFleetNumbers -join ',')]。"
        }
    }

    foreach ($fleet in $expectedFleetNumbers) {
        $organize = @($Group['List'] | Where-Object {
            (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') -and
            [int]$_['Fleet'] -eq $fleet
        })
        if ($organize.Count -ne 1) {
            $problems += [pscustomobject]@{
                Workflow = $workflowName
                Problem = "被检查的第 $fleet 舰队必须有且只有一个固定编成执行单元，当前为 $($organize.Count) 个。"
            }
            continue
        }

        $configuredIds = @()
        $position = 0
        foreach ($row in @($organize[0]['Positions'])) {
            $position++
            $selections = @($row['Selections'])
            if ($selections.Count -ne 1 -or [int]$selections[0]['Type'] -ne 0) {
                $problems += [pscustomobject]@{
                    Workflow = $workflowName
                    Problem = "第 $fleet 舰队位置 $position 不是单一舰船实例候选，无法进行精确身份检查。"
                }
                continue
            }
            $configuredIds += [int]$selections[0]['Value']
        }

        $declaredRows = if ($declaredFleets.Contains([string]$fleet)) {
            @($declaredFleets[[string]$fleet])
        } else {
            @()
        }
        $declaredIds = @($declaredRows | ForEach-Object { [int]$_['Id'] })
        if (($configuredIds -join ',') -ne ($declaredIds -join ',')) {
            $problems += [pscustomobject]@{
                Workflow = $workflowName
                Problem = "第 $fleet 舰队检查声明与编成位置不一致：编成 [$($configuredIds -join ',')]，声明 [$($declaredIds -join ',')]。"
            }
        }
    }

    $usedLandBases = @()
    foreach ($corps in 1..3) {
        if ([int]$Sortie["LandBasedAirCorps${corps}Action"] -in @(1, 2)) {
            $usedLandBases += $corps
        }
    }
    $declaredLandBases = $spec['LandBases']
    if ($declaredLandBases -isnot [System.Collections.IDictionary]) {
        $problems += [pscustomobject]@{
            Workflow = $workflowName
            Problem = '额外出击前检查的 LandBases 必须是按基地航空队编号声明的对象。'
        }
        return @($problems)
    }
    $declaredLandBaseNumbers = @($declaredLandBases.Keys | ForEach-Object { [int]$_ } | Sort-Object)
    if (($declaredLandBaseNumbers -join ',') -ne (($usedLandBases | Sort-Object) -join ',')) {
        $problems += [pscustomobject]@{
            Workflow = $workflowName
            Problem = "陆航检查范围错误：出击或防空队为 [$($usedLandBases -join ',')]，声明为 [$($declaredLandBaseNumbers -join ',')]。"
        }
    }
    foreach ($corps in $usedLandBases) {
        # 外层数组包装不可省略；PowerShell 会把 if 分支中的单项集合退化为标量。
        $rows = @(if ($declaredLandBases.Contains([string]$corps)) {
            @($declaredLandBases[[string]$corps])
        })
        if ($rows.Count -ne 4 -or @($rows | Where-Object {
            [int]$_['Id'] -le 0 -or [string]::IsNullOrWhiteSpace([string]$_['Name'])
        }).Count -gt 0) {
            $problems += [pscustomobject]@{
                Workflow = $workflowName
                Problem = "第 $corps 基地航空队必须按槽位声明四个有效的飞机种类。"
            }
            continue
        }
        if ($null -ne $Const) {
            $slot = 0
            foreach ($row in $rows) {
                $slot++
                $id = [int]$row['Id']
                $declaredName = [string]$row['Name']
                $masterName = Get-KcpsConstEquipName -Const $Const -EquipConstId $id
                $normalizedName = Normalize-KcpsEquipmentDisplayName -Name $declaredName
                if ($masterName -eq "#$id") {
                    $problems += [pscustomobject]@{
                        Workflow = $workflowName
                        Problem = "第 $corps 基地航空队第 $slot 槽声明了当前主数据中不存在的装备 ID $id。"
                    }
                } elseif ($masterName -cne $normalizedName) {
                    $problems += [pscustomobject]@{
                        Workflow = $workflowName
                        Problem = "第 $corps 基地航空队第 $slot 槽的 ID/名称不一致：ID $id 实际为 [$masterName]，声明为 [$declaredName]。"
                    }
                }
            }
        }
    }

    foreach ($requiredText in @(
        'def OnCheckSortieFleetAndLandBases():',
        'FleetUtility.Ships(fleet_no)',
        'LandBasedAirCorpsUtility.Corps(LAND_BASE_SEA, LAND_BASE_NUMBERS[corps_no])',
        'instance_id is not None and instance_id > 0',
        'EquipmentUtility.ConstId(instance_id)'
    )) {
        if (-not $script.Contains($requiredText)) {
            $problems += [pscustomobject]@{
                Workflow = $workflowName
                Problem = "额外出击前检查缺少通用实现片段：$requiredText"
            }
        }
    }
    if ($script -match 'FleetUtility\.Ships\(\s*\d+\s*\)') {
        $problems += [pscustomobject]@{
            Workflow = $workflowName
            Problem = '舰队检查不得在 Python 中写死舰队编号；必须遍历配置声明。'
        }
    }

    return @($problems)
}
