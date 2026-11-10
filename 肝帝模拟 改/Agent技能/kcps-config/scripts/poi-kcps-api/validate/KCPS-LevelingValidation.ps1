function Get-KcpsLevelingRouteProblems {
    param($RouteSpec, [object[]]$Members)
    $checks = @($RouteSpec['StageDesign']['RouteCompositionRules'] | Where-Object { $null -ne $_ })
    if ($checks.Count -eq 0) { '练级缺少当前路线的 RouteCompositionRules，不能套用旧地图带路。'; return }
    foreach ($check in $checks) {
        if ($check -isnot [System.Collections.IDictionary] -or
            (-not $check.Contains('MinCount') -and -not $check.Contains('MaxCount')) -or
            -not $check['Source'] -or -not $check['LastVerifiedJst']) {
            '练级带路规则须提供计数范围、Source 和 LastVerifiedJst。'; continue
        }
        $matching = @($Members)
        if ($check.Contains('Fleet')) { $matching = @($matching | Where-Object { [int]$_.Fleet -eq [int]$check['Fleet'] }) }
        if ($check['ShipTypes']) { $matching = @($matching | Where-Object { [int]$_.Type -in @($check['ShipTypes']) }) }
        if ($check['NameRegex']) { $matching = @($matching | Where-Object { [string]$_.Name -match [string]$check['NameRegex'] }) }
        if ($check.Contains('MaximumSpeed')) { $matching = @($matching | Where-Object { [int]$_.Speed -le [int]$check['MaximumSpeed'] }) }
        if ($check.Contains('MinimumSpeed')) { $matching = @($matching | Where-Object { [int]$_.Speed -ge [int]$check['MinimumSpeed'] }) }
        $min = if ($check.Contains('MinCount')) { [int]$check['MinCount'] } else { 0 }
        $max = if ($check.Contains('MaxCount')) { [int]$check['MaxCount'] } else { [int]::MaxValue }
        if ($min -lt 0 -or $max -lt $min -or $matching.Count -lt $min -or $matching.Count -gt $max) {
            "当前编成不满足带路计数规则 $($check['Name'])：实际$($matching.Count)，范围$min 至 $max。"
        }
    }
}

function Get-KcpsLevelingSelectionProblems {
    param($Stage, [object[]]$Audit)
    $rules = $Stage['SelectionPolicy']
    if ($rules -and $rules -isnot [System.Collections.IDictionary]) { 'SelectionPolicy 必须是按角色分组的对象。'; return }
    foreach ($a in $Audit) {
        if (-not $rules -or -not $rules.Contains([string]$a['Role'])) { continue }
        $rule = $rules[[string]$a['Role']]
        if ($rule['AllowedCopyNumbers'] -and [int]$a['CopyNo'] -notin @($rule['AllowedCopyNumbers'])) { "选船$($a['Name'])的多号机编号不符合当前角色策略。" }
        if ($rule.Contains('MaximumLevelExclusive') -and [int]$a['Level'] -ge [int]$rule['MaximumLevelExclusive']) { "选船$($a['Name'])的等级不符合当前角色策略。" }
    }
}

function Get-KcpsLevelingPreparationProblems {
    param($RouteSpec, $Controller, $Sortie, $Workflows, $Ships, $Const)
    if ($null -eq $RouteSpec -or
        $RouteSpec['StageDesign'] -isnot [System.Collections.IDictionary] -or
        [string]$RouteSpec['StageDesign']['Phase'] -ne 'Leveling') { return }
    $stage = $RouteSpec['StageDesign']
    $vacancy = $stage['VacancyPolicy']
    if ($vacancy -and $vacancy['Mode'] -eq 'GameMinimum') {
        foreach ($kind in 'Ship','Equipment') {
            $minimum = [int]$vacancy["${kind}Minimum"]
            if ($minimum -le 0 -or -not $Controller["StopIf${kind}VacancyLessOrEqualThanFlag"] -or
                [int]$Controller["StopIf${kind}VacancyLessOrEqualThanValue"] -ne ($minimum - 1)) {
                "${kind}空位停止边界错误：原生条件为小于等于，必须填最低可出击空位减1。"
            }
        }
    }
    foreach ($n in 1..3) {
        $checks = $stage['LandBaseFatigueChecks']
        if (-not $checks -or -not $checks.Contains([string]$n) -or $checks[[string]$n] -isnot [bool]) {
            "练级规格缺少第${n}队陆航疲劳策略。"; continue
        }
        $expected = $checks[[string]$n]
        if ([bool]$Sortie["LandBasedAirCorps${n}CheckFatigue"] -ne $expected) { "第${n}队陆航疲劳检查与声明策略不符。" }
        foreach ($w in @($Workflows | Where-Object { (Test-KcpsWorkflowType $_ 'BasicOutfitLandBasedAirCorpWorkflow') -and [int]$_.Corps -eq $n })) {
            if (-not $expected -and $w['LandBasedAirCorps1CheckFatigue']) { "第${n}队陆航休息单元仍开启疲劳检查。" }
        }
    }
    if (-not $stage['FillAllUsableSlots']) { return }
    if (-not $Const -or -not $Ships) { '满配练级缺少舰船及装备主数据。'; return }
    $masters = Get-KcpsConstShips $Const
    $equipment = @{}
    foreach ($m in (Get-KcpsConstEquips $Const).Values) { $equipment[[string]$m.api_name] = $m }
    foreach ($row in @($Workflows | Where-Object { Test-KcpsWorkflowType $_ 'BasicRefitEquipmentWorkflow' } | ForEach-Object { $_.Ships })) {
        $ship = $Ships[[string]$row.SelectValue]
        if (-not $ship) { continue }
        $master = $masters[[string]$ship.api_ship_id]
        $numbers = @(1..[int]$master.api_slot_num)
        if ([int]$ship.api_slot_ex -ne 0) { $numbers += 6 }
        foreach ($n in $numbers) {
            $slots = @($row.Slots | Where-Object { [int]$_.Slot -eq $n })
            $label = "$($master.api_name)($($row.SelectValue))第${n}槽"
            if ($slots.Count -ne 1 -or @($slots[0].Equipments).Count -ne 1 -or
                [string]::IsNullOrWhiteSpace([string]$slots[0].Equipments[0].SelectValue)) {
                "$label 未满配；红疲劳防护方案不得统一卸空可用槽。"; continue
            }
            $eq = $equipment[[string]$slots[0].Equipments[0].SelectValue]
            if (-not $eq) { "$label 无法解析装备。"; continue }
            $type = [string]$eq.api_type[2]; $id = [string]$eq.api_id
            # 单舰装备表覆盖舰种表；补强许可不能绕过舰种许可。
            $override = $Const['$equipShip'][[string]$ship.api_ship_id]
            if ($override) {
                $allowed = $override.api_equip_type.Contains($type) -and
                    ($null -eq $override.api_equip_type[$type] -or [int]$id -in @($override.api_equip_type[$type]))
            } else { $allowed = [bool]$Const['$shipTypes'][[string]$master.api_stype].api_equip_type[$type] }
            if ($n -eq 6) {
                $extraAllowed = [int]$type -in @($Const['$exslotEquips'])
                $rule = $Const['$exslotEquipShips'][$id]
                if ($rule) {
                    $extraAllowed = ($rule.api_ship_ids -and $rule.api_ship_ids.Contains([string]$ship.api_ship_id)) -or
                        ($rule.api_stypes -and ($rule.api_stypes.Contains('99') -or $rule.api_stypes.Contains([string]$master.api_stype))) -or
                        ($rule.api_ctypes -and $rule.api_ctypes.Contains([string]$master.api_ctype))
                }
                $allowed = $allowed -and $extraAllowed
            }
            if (-not $allowed) { "$label 不可装备$($eq.api_name)，不能把其他舰种或补强槽规则直接套用。" }
        }
    }
}

function Get-KcpsLevelingProblems {
    param($RouteSpec, $Controller, $Sortie, $Maps, $Workflows, $Ships, $MasterShips, $Equips, $MasterEquips, $Groups, $Routes, $Const)
    if ($null -eq $RouteSpec -or [string]$RouteSpec['StageDesign']['Phase'] -ne 'Leveling') { return }
    $stage = $RouteSpec['StageDesign']
    if ($null -eq $Controller -or $null -eq $Sortie) { '练级缺少总控或出击。'; return }
    Get-KcpsLevelingPreparationProblems -RouteSpec $RouteSpec -Controller $Controller -Sortie $Sortie -Workflows $Workflows -Ships $Ships -Const $Const
    Get-KcpsRefitSlotContinuityProblems -Workflows $Workflows | ForEach-Object { $_.Problem }
    if ($null -eq $Controller -or $null -eq $Sortie) { '练级缺少总控或出击。'; return }
    if ([string]$stage['SelectionMode'] -ne 'FixedInstances') { '练级校验须明确 SelectionMode=FixedInstances；动态候选尚不能由此检查器验证。'; return }
    if ([string]$stage['FatigueMode'] -notin @('RedFatigue','Recover')) { '练级须明确声明 FatigueMode 为 RedFatigue 或 Recover。' }
    $openingAsw = $stage['OpeningAsw']
    if ($openingAsw -and ($openingAsw -isnot [System.Collections.IDictionary] -or
        -not $openingAsw.Contains('Fleet') -or -not $openingAsw.Contains('MinimumCount'))) { 'OpeningAsw 须明确提供 Fleet 和 MinimumCount。'; return }
    if (-not $Controller['StopIfLoopCountLargerOrEqualThanFlag'] -or
        [int]$Controller['StopIfLoopCountLargerOrEqualThanValue'] -ne [int]$stage['LoopLimit'] -or
        [int]$stage['LoopLimit'] -lt 1) { '练级原生循环次数与规格不符。' }
    $allowedStops = @('StopIfLoopCountLargerOrEqualThanFlag','StopIfShipVacancyLessOrEqualThanFlag','StopIfEquipmentVacancyLessOrEqualThanFlag') + @($stage['AllowedStopFlags'])
    foreach ($k in $Controller.Keys) {
        if ($k -match '^StopIf.*Flag$' -and $Controller[$k] -and $k -notin $allowedStops) { "练级残留任务停止条件：$k。" }
    }
    if (-not $stage['AllowControllerScript'] -and ($Controller['EnableScript'] -or $Controller['Script'])) { '练级总控脚本未在当前策略中声明。' }
    if (-not $stage['AllowMapGaugeGate'] -and $Sortie['MapHpInRangeFlag']) { '练级血条门禁未在当前策略中声明。' }
    if (-not $stage['AllowSupport'] -and ($Sortie['NormalSupportExpedition'] -or $Sortie['BossSupportExpedition'])) { '练级支援未在当前策略中声明。' }
    $redFatigue = [string]$stage['FatigueMode'] -eq 'RedFatigue'
    if ($redFatigue) {
        if ($Controller['SleepUntilMoraleRecoveredFlag'] -or $Controller['SleepUntilFlagShipMoraleRecoveredFlag']) { '红疲劳练级仍开启舰船疲劳等待。' }
        if ($Sortie['FlagShipMoraleLargerOrEqualThanFlag'] -or $Sortie['EscortShipMoraleLargerOrEqualThanFlag']) { '红疲劳练级仍开启出击士气检查。' }
    } elseif (-not $Controller['SleepUntilMoraleRecoveredFlag'] -or
        [int]$Controller['SleepUntilMoraleRecoveredValueMorale'] -ne [int]$stage['MoraleMinimum']) { '固定练级疲劳等待与规格不符。' }
    $supplyPolicy = $stage['SupplyPolicy']
    if ($supplyPolicy -and [string]$supplyPolicy['Mode'] -eq 'BeforeOnlyConditional') {
        if ($Sortie['FlagShipFullySupplied'] -or $Sortie['EscortShipFullySupplied']) { '条件补给练级仍要求舰船油弹全满。' }
        $supplyById = @{}
        foreach ($w in @($Workflows | Where-Object { Test-KcpsWorkflowType $_ 'BasicSupplyFleetWorkflow' })) { $supplyById[[string]$w.Guid] = $w }
        $before = @($Controller['SupplyBeforeWorkflows'] | Where-Object { $_.Enabled -and $supplyById.ContainsKey([string]$_.Guid) } | ForEach-Object { $supplyById[[string]$_.Guid] })
        $fleets = @($supplyPolicy['Fleets'])
        if ($before.Count -ne $fleets.Count -or @(Compare-Object @($before.Fleet | Sort-Object) @($fleets | Sort-Object)).Count) { '条件补给关联的舰队集合与练级规格不符。' }
        foreach ($w in $before) {
            if (-not $w['SkipIfAllResourcePercentHigherThanFlag'] -or
                [int]$w['SkipIfAllResourcePercentHigherThanValue'] -ne [int]$supplyPolicy['ThresholdPercent'] -or
                [long]$w['Setting'] -ne [long]$supplyPolicy['Setting']) { "第$($w.Fleet)舰队条件补给阈值或资源范围与规格不符。" }
        }
        if (@($Controller['SupplyAfterWorkflows'] | Where-Object { $_.Enabled -and $supplyById.ContainsKey([string]$_.Guid) }).Count) { '条件补给练级在战后仍重复关联舰船补给。' }
        # 原生跳过补给也计完成；陆航休息不产生舰队补给完成事件。
        if ([int]$Controller['SupplyBeforeFinishedEventThreshold'] -ne $fleets.Count -or
            [int]$Controller['SupplyAfterFinishedEventThreshold'] -ne 0) { '条件补给完成事件阈值错误，可能跳过准备或卡住循环。' }
    }
    foreach ($map in @($stage['PostClearRequiredMaps'])) {
        if (-not $Maps.Contains([string]$map) -or [int]$Maps[[string]$map]['api_cleared'] -ne 1) { "地图${map}未确认通关，不能采用通关后带路。" }
    }
    foreach ($n in 1..3) {
        $actions = $stage['LandBaseActions']
        if ($null -eq $actions -or -not $actions.Contains([string]$n)) { "练级规格缺少第${n}陆航动作依据。"; continue }
        $action = [int]$actions[[string]$n]
        if ([int]$Sortie["LandBasedAirCorps${n}Action"] -ne $action) { "第${n}陆航动作与练级规格不符。" }
        $active = $action -in 1,2
        if ([int]$Sortie["LandBasedAirCorps${n}Resupply"] -ne $(if ($active) { 15 } else { 0 })) { "第${n}陆航补给与使用状态不符。" }
        if ($active) {
            $proficiency = $stage['LandBaseProficiencyChecks']
            if (-not $proficiency -or -not $proficiency.Contains([string]$n) -or $proficiency[[string]$n] -isnot [bool]) { "练级须明示第${n}陆航熟练度检查策略。" }
            elseif ([bool]$Sortie["LandBasedAirCorps${n}CheckAnyProficiencyNotFull"] -ne $proficiency[[string]$n]) { "第${n}陆航熟练度检查与当前策略不符。" }
        }
    }
    $strategies = @($Sortie['Strategies'])
    $expectedStrategies = @($stage['TargetStrategies'] | Where-Object { $null -ne $_ })
    if ($expectedStrategies.Count -eq 0) { '练级缺少 TargetStrategies，不能假定潜艇点、阵型或撤退方式。' }
    if ($strategies.Count -ne $expectedStrategies.Count) { '练级地图点策略数量与当前目标声明不一致。' }
    foreach ($expected in $expectedStrategies) {
        $required = @('ConditionValue','Formation','Advance','Midnight','WayPoint')
        if ($expected -isnot [System.Collections.IDictionary] -or @($required | Where-Object { -not $expected.Contains($_) }).Count) { 'TargetStrategies 须完整声明节点、阵型、进退、夜战及能动路线。'; continue }
        $rows = @($strategies | Where-Object { [int]$_['Condition']['Type'] -eq 1 -and [int]$_['Condition']['Value'] -eq [int]$expected['ConditionValue'] })
        if ($rows.Count -ne 1) { '练级目标点策略缺失或重复。'; continue }
        $actual = $rows[0]['Strategy']
        if ([int]$actual['DefaultFormation'] -ne [int]$expected['Formation'] -or
            [int]$actual['DefaultAdvance'] -ne [int]$expected['Advance'] -or
            [int]$actual['DefaultMidnight'] -ne [int]$expected['Midnight'] -or
            $actual['DefaultWayPoint'] -ne $expected['WayPoint']) { '练级目标点阵型、进退或夜战与当前策略不符。' }
    }
    $members = @(); $selected = @(); $oasw = 0
    $masterByName = @{}
    foreach ($m in $MasterEquips.Values) { $masterByName[[string]$m.api_name] = $m }
    foreach ($org in @($Workflows | Where-Object { Test-KcpsWorkflowType $_ 'BasicOrganizeFleetWorkflow' })) {
        foreach ($p in @($org['Positions'])) {
            if (@($p.Selections).Count -ne 1 -or [int]$p.Selections[0].Type -ne 0) { '固定练级不允许动态或多候选选船。'; continue }
            $id = [string]$p.Selections[0].Value
            $selected += [int]$id
            if (-not $Ships.Contains($id)) { "练级实例${id}不存在。"; continue }
            $ship = $Ships[$id]; $m = $MasterShips[[string]$ship.api_ship_id]
            $members += @{Id=$id;Name=$m.api_name;Type=[int]$m.api_stype;Speed=[int]$m.api_soku;Fleet=[int]$org.Fleet}
            $refits = @($Workflows | Where-Object { Test-KcpsWorkflowType $_ 'BasicRefitEquipmentWorkflow' } | ForEach-Object { $_.Ships } | Where-Object { [int]$_.SelectMethod -eq 3 -and [string]$_.SelectValue -eq $id })
            if ($refits.Count -ne 1) { "反潜实例${id}改装不唯一。"; continue }
            if ([int]$refits[0].Fleet -ne [int]$org.Fleet) { "$($m.api_name)编成与改装舰队编号不一致。" }
            if (-not $openingAsw -or [int]$org.Fleet -ne [int]$openingAsw['Fleet']) { continue }
            $base = [int]$ship.api_taisen[0]
            foreach ($eqId in @($ship.api_slot) + @($ship.api_slot_ex)) {
                if ([int]$eqId -gt 0 -and $Equips.Contains([string]$eqId)) { $base -= [int]$MasterEquips[[string]$Equips[[string]$eqId].api_slotitem_id].api_tais }
            }
            $equippedAsw = 0; $sonar = $false; $smallSonarCount = 0
            foreach ($slot in @($refits[0].Slots)) {
                if (Test-KcpsDeclaredEmptyRefitSlot $refits[0] $slot) { continue }
                if (@($slot.Equipments).Count -ne 1) { continue }
                $eq = $masterByName[[string]$slot.Equipments[0].SelectValue]
                if ($null -eq $eq) { continue }
                $equippedAsw += [int]$eq.api_tais
                if ([int]$eq.api_type[2] -eq 14) {
                    $sonar = $true; $smallSonarCount++
                    if ($redFatigue -and ($slot.Equipments[0].PrioritizeCurrentEquipptedEquipments -or
                        -not $slot.Equipments[0].Reorder -or [int]$slot.Equipments[0].LevelPriority -ne 0)) { "$($m.api_name)红疲劳声呐未优先高改修。" }
                }
            }
            if ($redFatigue) {
                $sonarMinimum = [int]$stage['MinimumSmallSonarCount']
                $exception = if ($stage['SmallSonarExceptions']) { $stage['SmallSonarExceptions'][$id] } else { $null }
                if ($exception -and -not [string]::IsNullOrWhiteSpace([string]$exception['Reason'])) { $sonarMinimum = [int]$exception['Count'] }
                if ($sonarMinimum -lt 0 -or $smallSonarCount -lt $sonarMinimum) { "$($m.api_name)红疲劳小型声呐不足：$smallSonarCount，设计要求$sonarMinimum。" }
            }
            $minimum = if ([int]$m.api_stype -eq 1) { 60 } else { 100 }
            # 无条件先反只按已核实的具体形态放行，不推广到同舰种。
            $unconditional = [int]$ship.api_ship_id -in 1062,1067 -and [string]$m.api_name -match '^Visby(改)?$'
            $coastalBattleship = [string]$m.api_name -match '^(Norge|Eidsvold|Thonburi)(改)?$'
            # しまね丸改采用声呐+100对潜；未改造形态不能套用。
            $canDepthCharge = -not $coastalBattleship -and ([int]$m.api_stype -in 1,2,3,4,21 -or
                ([int]$m.api_stype -eq 22 -and [string]$m.api_name -eq 'しまね丸改'))
            if ($unconditional -or ($canDepthCharge -and $sonar -and $base + $equippedAsw -ge $minimum)) { $oasw++ }
            else { "$($m.api_name)未通过基础先制反潜门槛：现有对潜扣除旧装备后$base，计划装备$equippedAsw，门槛$minimum。" }
        }
    }
    if ($openingAsw -and $oasw -lt [int]$openingAsw['MinimumCount']) { "第$($openingAsw['Fleet'])队只验证到${oasw}艘先制反潜，要求$($openingAsw['MinimumCount'])艘。" }
    if (@($selected | Group-Object | Where-Object Count -gt 1).Count) { '练级编成内存在重复实例。' }
    $audit = @($stage.SelectionAudit)
    if (@($audit).Count -ne $selected.Count -or @(Compare-Object @($selected | Sort-Object) @($audit.Id | Sort-Object)).Count) { '选船审计和最终编成实例不一致。' }
    Get-KcpsLevelingSelectionProblems -Stage $stage -Audit $audit
    foreach ($a in $audit) {
        if ($stage['RemodelPolicy']) {
            $ship = $Ships[[string]$a.Id]
            if (-not $ship -or [int]$a['MasterId'] -ne [int]$ship.api_ship_id -or
                [int]$a['SlotCount'] -ne [int]$MasterShips[[string]$ship.api_ship_id].api_slot_num) {
                "$($a.Name)改造形态或槽数已变化，须按实际形态重新编排，不能沿用旧计划。"
            }
        }
    }
    if ($stage['FlagshipTraining'] -and $stage['FlagshipTraining']['Required']) {
        foreach ($fleet in @($stage['FlagshipTraining']['ExpectedIds'].Keys)) {
            $orgs = @($Workflows | Where-Object { (Test-KcpsWorkflowType $_ 'BasicOrganizeFleetWorkflow') -and [int]$_.Fleet -eq $fleet })
            $flag = if ($orgs.Count -eq 1) { [int]$orgs[0].Positions[0].Selections[0].Value } else { 0 }
            $row = @($audit | Where-Object { [int]$_.Id -eq $flag -and [int]$_.Fleet -eq $fleet })
            if ($flag -ne [int]$stage.FlagshipTraining.ExpectedIds[[string]$fleet] -or
                $row.Count -ne 1 -or [string]$row[0].Role -ne '待练') {
                "第${fleet}舰队旗舰没有按当前练级方案分配给待练舰。"
            }
        }
    }
    if ($stage['RefitFleetPriority']) {
        $refitRows = @($Workflows | Where-Object { Test-KcpsWorkflowType $_ 'BasicRefitEquipmentWorkflow' } | ForEach-Object { $_.Ships })
        $expectedOrder = @($stage['RefitFleetPriority'] | ForEach-Object { $f = $_; $refitRows | Where-Object { [int]$_.Fleet -eq [int]$f } })
        if (($refitRows.SelectValue -join ',') -ne ($expectedOrder.SelectValue -join ',') -or
            ($stage['RefitFirstShipId'] -and [int]$refitRows[0].SelectValue -ne [int]$stage['RefitFirstShipId'])) {
            '练级改装顺序与 RefitFleetPriority 或 RefitFirstShipId 声明不一致。'
        }
    }
    $milestones = if ($stage['RemodelPolicy']) { @($stage['RemodelPolicy']['Milestones']) } else { @() }
    foreach ($milestone in $milestones) {
        if ($null -eq $milestone) { continue }
        $row = @($audit | Where-Object { [int]$_.Id -eq [int]$milestone.Id })
        if ($row.Count -ne 1 -or [int]$row[0].CopyNo -ne [int]$milestone.CopyNo) {
            '到级改造规划的实例或多号机编号与选船审计不一致。'
            continue
        }
        $master = $MasterShips[[string]$row[0]['MasterId']]
        if ($null -eq $master) { continue }
        if ([int]$milestone.Level -ne [int]$master.api_afterlv -or
            [int]$milestone.NextMasterId -ne [int]$master.api_aftershipid -or
            [int]$milestone.NextSlotCount -ne [int]$MasterShips[[string]$milestone.NextMasterId].api_slot_num) {
            "$($row[0].Name)下一改造等级、形态或槽数与主数据不符。"
        }
    }
    foreach ($other in @($Groups | Where-Object { $stage['DisjointSet'] })) {
        if ([string]$other.Name -match [string]$RouteSpec.GroupNameRegex) { continue }
        $otherSpec = @($Routes | Where-Object { [string]$other.Name -match [string]$_.GroupNameRegex -and $_.Contains('StageDesign') -and $_.StageDesign -and $_.StageDesign.DisjointSet -eq $stage.DisjointSet })
        if (-not $otherSpec.Count) { continue }
        $otherIds = @($other.List | Where-Object { Test-KcpsWorkflowType $_ 'BasicOrganizeFleetWorkflow' } | ForEach-Object { $_.Positions } | ForEach-Object { $_.Selections } | ForEach-Object { [int]$_.Value })
        foreach ($id in @($selected | Where-Object { $_ -in $otherIds })) { "同一互斥集合的练级配置使用了相同实例$id。" }
    }
    Get-KcpsLevelingRouteProblems -RouteSpec $RouteSpec -Members $members
}
