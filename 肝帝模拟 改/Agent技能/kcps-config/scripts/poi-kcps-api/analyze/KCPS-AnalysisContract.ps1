# Offline validation and state conversion for analysis contract version 2.
$script:KcpsAnalysisSchemaRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\data'))
function Assert-KcpsAnalysisRequest {
    param([System.Collections.IDictionary]$Request)
    if ([int]$Request['SchemaVersion'] -ne 2) { throw '分析请求必须使用 SchemaVersion=2，并显式声明 InitialState；不再代入满血、满补给或满熟练度。' }
    foreach ($key in $Request.Keys) {
        if ($key -notin @('SchemaVersion','Kind','Name','Map','Difficulty','RouteEdges','BattleNodes','Goal','Simulation','FleetSearch','BonusProfiles','ResearchSources')) { throw "当前分析请求不支持字段 $key；不能忽略后生成概率。" }
    }
    try {
        $valid = Test-Json -Json ($Request | ConvertTo-Json -Depth 100 -Compress) -SchemaFile (Join-Path $script:KcpsAnalysisSchemaRoot 'KCPS-EventSortieAnalysisRequest.schema.json') -ErrorAction Stop
        if (-not $valid) { throw 'invalid' }
    } catch { throw '分析请求缺少有效事实或包含尚不支持的字段/状态；请按版本2请求契约补齐，未生成概率。' }
    $simulation = $Request['Simulation']
    if ($simulation -isnot [System.Collections.IDictionary] -or [string]$simulation['ModelScope'] -ne 'SingleFleetFixedRoute') {
        throw '当前分析器仅支持 SingleFleetFixedRoute；其他舰队或路线模型尚不支持，未生成概率。'
    }
    foreach ($key in @('LandBases', 'SupportFleets', 'CombinedFleet', 'StateTransitions', 'RandomRouteBranches')) {
        if (($Request.Contains($key) -and $Request[$key]) -or ($simulation.Contains($key) -and $simulation[$key])) {
            throw "当前分析器不支持 $key，不能忽略该输入后生成概率。"
        }
    }
    if ([int]$simulation['NumSims'] -le 0 -or @($simulation['Seeds']).Count -eq 0 -or
        @($simulation['Seeds'] | Sort-Object -Unique).Count -ne @($simulation['Seeds']).Count) { throw '模拟次数必须为正，随机种子必须非空且不重复。' }
    $state = $simulation['InitialState']
    if ($state -isnot [System.Collections.IDictionary] -or $state['Kind'] -notin @('Actual', 'Baseline') -or
        [string]::IsNullOrWhiteSpace([string]$state['Source'])) { throw 'InitialState 必须声明 Actual/Baseline 和状态来源 Source。' }
    $modes = @{
        Supply = @('Snapshot', 'Explicit', 'Full')
        Hp = @('Snapshot', 'Explicit', 'Full')
        Morale = @('Snapshot', 'Explicit')
        AircraftCounts = @('Snapshot', 'Explicit', 'Full')
        ShipAircraftProficiency = @('SnapshotDisplay', 'ExplicitDisplay', 'MaxDisplay')
        LandBaseAircraftProficiency = @('NotApplicable')
    }
    foreach ($key in $modes.Keys) {
        $value = $state[$key]
        if ($value -isnot [System.Collections.IDictionary] -or $value['Mode'] -notin $modes[$key]) {
            throw "初始状态 $key 缺失或不支持其 Mode；未生成概率。"
        }
        if ($state['Kind'] -eq 'Actual' -and $value['Mode'] -in @('Full', 'MaxDisplay')) {
            throw 'Actual 状态不能被满补给、满血、满载或满熟练基线替换；请提供快照/显式实测值，或另建 Baseline 请求。'
        }
        if ($value.Contains('Internal') -or $value.Contains('InternalValues')) { throw '当前引擎适配器仅支持显示熟练度模型，不能精确输入内部熟练度；未生成概率。' }
    }
    if ([string]::IsNullOrWhiteSpace([string]$state['LandBaseAircraftProficiency']['Reason'])) { throw '陆航未纳入模型时必须在 NotApplicable.Reason 说明本场景不使用陆航。' }
    $goal = $Request['Goal']
    if ($goal['Type'] -ne 'RankAtNode' -or $goal['MinimumRank'] -notin @('S', 'A', 'B') -or
        [int]$goal['RequiredSuccesses'] -lt 1 -or -not $goal.Contains('IndependentRepeatedSuccesses')) {
        throw '当前目标仅支持 RankAtNode，并须显式声明胜利等级、所需次数及是否独立重复；其他目标尚无可靠估计。'
    }
    if (@($Request['BattleNodes']).Count -eq 0 -or
        @($Request['BattleNodes'] | Where-Object { $_['Label'] -eq $goal['TargetNode'] }).Count -ne 1) { throw '目标点必须在 BattleNodes 中唯一存在。' }
    foreach ($node in $Request['BattleNodes']) {
        foreach ($key in $node.Keys) {
            if ($key -notin @('Label','Formation','SubOnly','AirRaid','AirOnly','NightBattle')) { throw "当前战斗节点不支持 $key；未生成概率。" }
        }
    }
    $search = $Request['FleetSearch']
    $variableCount = @($search['VariablePositions']).Count
    if (@($search['VariableShipInstanceIds']).Count -ne $variableCount -or @($search['LoadoutSets']).Count -ne $variableCount) { throw '可变舰船、位置与配装集合的长度必须一致。' }
    $positions = @($search['FixedPositions'] | ForEach-Object { [int]$_['Position'] }) + @($search['VariablePositions'])
    $shipIds = @($search['FixedPositions'] | ForEach-Object { [int]$_['ShipInstanceId'] }) + @($search['VariableShipInstanceIds'])
    if ($positions.Count -lt 1 -or $positions.Count -gt 6 -or @($positions | Sort-Object -Unique).Count -ne $positions.Count -or
        (($positions | Sort-Object) -join ',') -ne ((1..$positions.Count) -join ',') -or
        (@($search['EquipmentResolutionPositionOrder'] | Sort-Object) -join ',') -ne (($positions | Sort-Object) -join ',') -or
        @($shipIds | Sort-Object -Unique).Count -ne $shipIds.Count) { throw '单舰队候选位置、舰船实例或装备解析顺序不完整/重复。' }
    $names = @{}
    $primaryCount = 0
    foreach ($profile in @($Request['BonusProfiles'])) {
        if ($profile -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string]$profile['Name']) -or $names.ContainsKey([string]$profile['Name'])) { throw '增伤方案名称必须非空且唯一。' }
        $names[[string]$profile['Name']] = $true
        foreach ($key in $profile.Keys) {
            if ($key -notin @('Name','Role','Applicability','Verified','Source','LastVerifiedJst','Multiplier','Model','ShipBonuses')) { throw "当前增伤模型不支持 $key；未生成概率。" }
        }
        if ($profile['Role'] -notin @('Primary', 'Sensitivity')) { throw '增伤方案必须声明 Primary 或 Sensitivity，不能按方案名称猜测主模型。' }
        if ($profile['Role'] -eq 'Primary') { $primaryCount++ }
        if ($profile['Verified'] -ne $true -or [string]::IsNullOrWhiteSpace([string]$profile['Source']) -or
            [string]$profile['LastVerifiedJst'] -notmatch '^\d{4}-\d{2}-\d{2}$') { throw '活动增伤状态未经核实或缺少来源/核对日期；未生成概率。' }
        if ($profile['Applicability'] -eq 'NotApplicable') {
            if (-not $profile.Contains('Multiplier') -or [double]$profile['Multiplier'] -ne 1 -or
                ($profile.Contains('ShipBonuses') -and $profile['ShipBonuses'].Count -gt 0)) { throw '已核实无适用活动增伤必须显式填写 NotApplicable、Multiplier=1，且不能同时声明舰船增伤。' }
        } elseif ($profile['Applicability'] -eq 'Applicable') {
            if ($profile['Model'] -ne 'DamageMultiplier' -or $profile['ShipBonuses'] -isnot [System.Collections.IDictionary]) { throw '当前适配器仅支持已核实的 DamageMultiplier；其他增伤机制尚不支持。' }
            foreach ($bonus in $profile['ShipBonuses'].Values) {
                foreach ($key in $bonus.Keys) { if ($key -notin @('DefaultDamage','ByNode')) { throw "当前舰船增伤不支持 $key；未生成概率。" } }
                if ($bonus.Contains('ByNode')) {
                    foreach ($label in $bonus['ByNode'].Keys) { if ($label -notin @($Request['BattleNodes'] | ForEach-Object { $_['Label'] })) { throw '节点增伤引用了本次路线以外的未知节点。' } }
                }
            }
        } else { throw '活动增伤适用状态未知；须核实 Applicable 或 NotApplicable，不能按无增伤处理。' }
    }
    if ($primaryCount -ne 1) { throw '必须且只能有一个有证据的 Primary 增伤方案；无增伤时可显式使用 NotApplicable。' }
}

function Get-KcpsBoundedAnalysisNumber {
    param($Value, [double]$Minimum, [double]$Maximum, [string]$Label)
    if ($null -eq $Value -or $Value -is [bool]) { throw "缺少有效的 $Label。" }
    $number = 0.0
    if (-not [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
        [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt $Minimum -or $number -gt $Maximum) { throw "$Label 超出支持范围。" }
    return $number
}

function Get-KcpsAnalysisShipState {
    param([int]$ShipId, $Ship, $Master, $InitialState)
    $key = [string]$ShipId
    $supply = $InitialState['Supply']
    if ($supply['Mode'] -eq 'Full') { $fuel = 1; $ammo = 1 }
    elseif ($supply['Mode'] -eq 'Snapshot') {
        $fuelMax = Get-KcpsBoundedAnalysisNumber $Master['api_fuel_max'] 1 100000 '舰船燃料容量'
        $ammoMax = Get-KcpsBoundedAnalysisNumber $Master['api_bull_max'] 1 100000 '舰船弹药容量'
        $fuel = (Get-KcpsBoundedAnalysisNumber $Ship['api_fuel'] 0 $fuelMax '当前燃料') / $fuelMax
        $ammo = (Get-KcpsBoundedAnalysisNumber $Ship['api_bull'] 0 $ammoMax '当前弹药') / $ammoMax
    } else {
        $entry = $supply['Ships'][$key]
        if ($null -eq $entry) { throw '显式补给状态缺少所选舰船。' }
        $fuel = Get-KcpsBoundedAnalysisNumber $entry['FuelFraction'] 0 1 '燃料比例'
        $ammo = Get-KcpsBoundedAnalysisNumber $entry['AmmoFraction'] 0 1 '弹药比例'
    }
    $hpMax = Get-KcpsBoundedAnalysisNumber $Ship['api_maxhp'] 1 100000 '最大耐久'
    $hpSpec = $InitialState['Hp']
    $hp = switch ($hpSpec['Mode']) { 'Full' { $hpMax }; 'Snapshot' { $Ship['api_nowhp'] }; 'Explicit' { $hpSpec['Ships'][$key] } }
    $hp = Get-KcpsBoundedAnalysisNumber $hp 1 $hpMax '起始耐久'
    $moraleSpec = $InitialState['Morale']
    $morale = if ($moraleSpec['Mode'] -eq 'Snapshot') { $Ship['api_cond'] } else { $moraleSpec['Ships'][$key] }
    $morale = Get-KcpsBoundedAnalysisNumber $morale 0 100 '起始士气'
    if ($hp -ne [math]::Floor($hp) -or $morale -ne [math]::Floor($morale)) { throw '起始耐久与士气必须为整数，不能截断输入。' }
    $capacity = @($Master['api_maxeq'])
    $countsSpec = $InitialState['AircraftCounts']
    $counts = switch ($countsSpec['Mode']) { 'Full' { ,$capacity }; 'Snapshot' { ,@($Ship['api_onslot']) }; 'Explicit' { ,@($countsSpec['Ships'][$key]) } }
    if ($counts.Count -lt $capacity.Count) { throw '起始载机数量缺失，不能默认满载。' }
    for ($i=0; $i -lt $capacity.Count; $i++) {
        $count = Get-KcpsBoundedAnalysisNumber $counts[$i] 0 $capacity[$i] '起始载机数量'
        if ($count -ne $capacity[$i]) { throw '当前适配器尚不能独立传递飞机当前数量和槽位容量；非满载场景暂不支持，未生成概率。' }
    }
    return [ordered]@{ ShipInstanceId=$ShipId; Hp=[int]$hp; MaxHp=[int]$hpMax; Morale=[int]$morale; FuelFraction=[double]$fuel; AmmoFraction=[double]$ammo; AircraftCounts=@($counts) }
}

function Get-KcpsAnalysisProficiency {
    param($Equipment, $InitialState, [bool]$IsAircraft)
    if (-not $IsAircraft) { return 0 }
    $spec = $InitialState['ShipAircraftProficiency']
    $value = switch ($spec['Mode']) {
        'MaxDisplay' { 7 }
        'SnapshotDisplay' { $Equipment['api_alv'] }
        'ExplicitDisplay' { $spec['Equipment'][[string]$Equipment['api_id']] }
    }
    $value = Get-KcpsBoundedAnalysisNumber $value 0 7 '飞机显示熟练度'
    if ($value -ne [math]::Floor($value)) { throw '飞机显示熟练度必须为 0..7 的整数。' }
    return [int]$value
}

function Assert-KcpsAnalysisAssumptions {
    param($Assumptions)
    if ($Assumptions -isnot [System.Collections.IDictionary] -or $Assumptions['StateKind'] -notin @('Actual', 'Baseline') -or
        [string]::IsNullOrWhiteSpace([string]$Assumptions['Source']) -or @($Assumptions['ResolvedShips']).Count -eq 0) { throw '分析结果缺少可追溯的起始状态。' }
    foreach ($ship in $Assumptions['ResolvedShips']) {
        $null = Get-KcpsBoundedAnalysisNumber $ship['FuelFraction'] 0 1 '结果燃料比例'
        $null = Get-KcpsBoundedAnalysisNumber $ship['AmmoFraction'] 0 1 '结果弹药比例'
        $null = Get-KcpsBoundedAnalysisNumber $ship['Hp'] 1 $ship['MaxHp'] '结果耐久'
        $null = Get-KcpsBoundedAnalysisNumber $ship['Morale'] 0 100 '结果士气'
    }
    $fullSupply = @($Assumptions['ResolvedShips'] | Where-Object { $_['FuelFraction'] -ne 1 -or $_['AmmoFraction'] -ne 1 }).Count -eq 0
    if ($Assumptions['FullSupply'] -isnot [bool] -or $Assumptions['FullSupply'] -ne $fullSupply) { throw '结果 FullSupply 与逐舰实际油弹状态不一致。' }
    if ($Assumptions['ShipAircraftProficiency']['InternalPolicy'] -ne 'NotModeled' -or
        $Assumptions['LandBaseAircraftProficiency']['Mode'] -ne 'NotApplicable') { throw '结果包含当前适配器不支持的内部熟练度或陆航假设。' }
    foreach ($equipment in $Assumptions['ShipAircraftProficiency']['Equipment']) {
        $null = Get-KcpsBoundedAnalysisNumber $equipment['DisplayRank'] 0 7 '结果显示熟练度'
    }
    foreach ($key in @('SupplyPolicy', 'StartingHpPolicy', 'MoralePolicy', 'EventBonusPolicy')) {
        if ([string]::IsNullOrWhiteSpace([string]$Assumptions[$key])) { throw "分析结果缺少 $key。" }
    }
}
