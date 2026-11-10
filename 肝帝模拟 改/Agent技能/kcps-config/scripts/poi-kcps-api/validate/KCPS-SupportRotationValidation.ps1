function Get-KcpsDynamicAswSupportProblems {
    param($Plan, $Workflows, $MasterEquipByName, $Memo)
    $issues = @()
    $fleet = [int]$Plan['Fleet']
    $orgs = @($Workflows | Where-Object {
        (Test-KcpsWorkflowType $_ 'BasicOrganizeFleetWorkflow') -and [int]$_['Fleet'] -eq $fleet
    })
    if ($orgs.Count -ne 1) { return @('动态反潜支援缺少唯一编成执行单元。') }
    $org = $orgs[0]
    $roleKeys = @($Plan['PositionRoles'])
    $roles = $Plan['Roles']
    if ($roleKeys.Count -ne 6 -or @($org['Positions']).Count -ne 6 -or
        -not ($roles -is [System.Collections.IDictionary])) {
        return @('动态反潜支援必须声明六个位置及通用候选角色。')
    }
    $scriptLines = ([string]$org['Script']) -split '\r?\n', 2
    if (-not [bool]$org['EnableScript'] -or $scriptLines.Count -ne 2 -or
        $scriptLines[0] -notmatch '^SUPPORT_ROLES = (.+)$') {
        return @('动态反潜支援没有嵌入通用候选脚本。')
    }
    try { $runtime = $Matches[1] | ConvertFrom-Json -AsHashtable } catch {
        return @('动态反潜支援候选角色不是有效 JSON。')
    }
    $canonical = Get-Content -LiteralPath "$PSScriptRoot\..\enable\support_rotation.py" -Raw
    if ($scriptLines[1].Trim() -ne $canonical.Trim()) {
        $issues += '动态反潜支援脚本与通用版本不一致，请重新生成。'
    }
    $refitRows = @(
        foreach ($w in $Workflows | Where-Object { Test-KcpsWorkflowType $_ 'BasicRefitEquipmentWorkflow' }) {
            $w['Ships'] | Where-Object { [int]$_['Fleet'] -eq $fleet }
        }
    )
    $air = 0; $attacks = 0; $lightCarriers = 0; $destroyers = 0; $carriers = 0
    for ($i = 0; $i -lt 6; $i++) {
        $key = [string]$roleKeys[$i]
        if (-not $roles.Contains($key) -or -not $runtime.Contains($key)) {
            $issues += "支援第 $($i + 1) 位角色 $key 缺失。"; continue
        }
        $role = $roles[$key]; $rr = $runtime[$key]
        $position = $org['Positions'][$i]
        $sel = @($position['Selections'])
        if ($sel.Count -ne 1 -or [int]$sel[0]['Type'] -ne 8 -or [string]$sel[0]['Value'] -ne $key) {
            $issues += "支援第 $($i + 1) 位没有使用已校验的通用角色 $key。"
        }
        foreach ($field in @('ShipTypes','MinimumLevel','MinimumSlots','MinimumTotalCapacity','MinimumAircraftPerSlot','MinimumAirPower','OptionalSlots')) {
            if (($role[$field] -join ',') -ne ($rr[$field] -join ',')) { $issues += "支援角色 $key 的 $field 与编成脚本不一致。" }
        }
        if (-not $position['SkipShipsInOtherFleets'] -or $position['IgnoreSkipShipsInOtherFleetsIfInitial'] -or
            -not $position['SkipRepairingShips'] -or -not $position['SkipExpeditioningShips']) {
            $issues += "支援第 $($i + 1) 位没有排除其他舰队、入渠或远征占用。"
        }
        if (@($Plan['MoraleExclusionMax']).Count -ne 6) { $issues += '动态支援须逐位置声明 MoraleExclusionMax。'; continue }
        $limit = [int]$Plan['MoraleExclusionMax'][$i]
        foreach ($prefix in @('ChangeIfMoraleInRange','SkipMoraleInRange')) {
            if (-not $position[$prefix + 'Flag'] -or [int]$position[$prefix + 'ValueMin'] -ne 0 -or
                [int]$position[$prefix + 'ValueMax'] -ne $limit) {
                $issues += "支援第 $($i + 1) 位的士气轮换应排除 0..$limit。"
            }
        }
        if ([bool]$role['RequireRemodeled'] -ne [bool]$rr['RequireRemodeled'] -or [bool]$role['RequireRemodeled'] -ne [bool]$position['SkipNotRemodeled']) { $issues += "支援角色 $key 的改造形态要求不一致。" }
        $types = @($role['ShipTypes'])
        if (($types -join ',') -eq '2') { $destroyers++ }
        if (($types -join ',') -eq '7') { $lightCarriers++ }
        $rows = @($refitRows | Where-Object { [int]$_['SelectMethod'] -eq 0 -and [int]$_['SelectValue'] -eq ($i + 1) })
        if ($rows.Count -ne 1) { $issues += "支援第 $($i + 1) 位没有唯一的按位置改装。"; continue }
        $ids = @(); $aa = @()
        for ($n = 0; $n -lt @($role['EquipmentNames']).Count; $n++) {
            $name = [string]$role['EquipmentNames'][$n]
            if (-not $MasterEquipByName.ContainsKey($name)) { $issues += "支援装备缺少主数据：$name"; continue }
            $eq = $MasterEquipByName[$name]
            $ids += [int]$eq['api_id']; $aa += [int]$eq['api_tyku']
            $optional = ($n + 1) -in @($role['OptionalSlots'])
            if (-not $optional -and [int]$role['MinimumAircraftPerSlot'] -gt 0 -and ($types -join ',') -ne '2' -and [int]$eq['api_tais'] -ge 1 -and [int]$eq['api_type'][2] -in 7,8,25,26) { $attacks++ }
            $slots = @($rows[0]['Slots'] | Where-Object { [int]$_['Slot'] -eq ($n + 1) })
            if ($slots.Count -ne 1) { $issues += "支援第 $($i + 1) 位缺少第 $($n + 1) 槽。"; continue }
            $equipment = @($slots[0]['Equipments'])
            if ($equipment.Count -ne 1 -or [int]$equipment[0]['SelectMethod'] -ne 0 -or
                [string]$equipment[0]['SelectValue'] -ne $name -or [bool]$slots[0]['IgnoreSlotNotAvailable'] -ne $optional -or
                $slots[0]['IgnoreNoEquipmentMatched']) { $issues += "支援第 $($i + 1) 位第 $($n + 1) 槽与候选能力校验不一致。" }
        }
        if (($ids -join ',') -ne ($rr['EquipmentIds'] -join ',') -or ($aa -join ',') -ne ($rr['AntiAir'] -join ',')) {
            $issues += "支援角色 $key 的装备或对空参数与实时主数据不一致。"
        }
        $expansionName = [string]$role['ExpansionEquipmentName']
        $expansionSlots = @($rows[0]['Slots'] | Where-Object { [int]$_['Slot'] -eq 6 })
        if ($expansionName) {
            if (-not $MasterEquipByName.ContainsKey($expansionName) -or [int]$rr['ExpansionEquipmentId'] -ne [int]$MasterEquipByName[$expansionName]['api_id']) {
                $issues += "支援角色 $key 的补强装备与候选兼容性检查不一致。"
            }
            if ($expansionSlots.Count -ne 1 -or -not [bool]$expansionSlots[0]['IgnoreSlotNotAvailable'] -or
                @($expansionSlots[0]['Equipments']).Count -ne 1 -or [string]$expansionSlots[0]['Equipments'][0]['SelectValue'] -ne $expansionName) {
                $issues += "支援角色 $key 的补强槽与明示方案不一致。"
            }
        } elseif ($expansionSlots.Count -gt 0 -or [int]$rr['ExpansionEquipmentId'] -ne 0) {
            $issues += "支援角色 $key 残留未声明的补强装备。"
        }
        $air += [int]$role['MinimumAirPower']

    }
    if ($destroyers -lt 2 -or $lightCarriers -lt 2) { $issues += '航空反潜支援的声明角色至少须保证2驱逐和2轻母。' }
    if ($attacks -lt [int]$Plan['MinimumAviationAswSlots']) { $issues += "动态反潜支援仅保证 $attacks 个攻击槽。" }
    if ($air -lt [int]$Plan['MinimumSupportAirPower'] -or ($Plan['RequireAirSuperiority'] -and 2 * $air -lt 3 * [int]$Plan['EnemyAirPower'])) {
        $issues += "动态反潜支援制空下限 $air 不足以达到声明的制空目标。"
    }

    return $issues
}
