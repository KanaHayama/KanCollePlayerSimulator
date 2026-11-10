#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$GroupName,
    [Parameter(Mandatory)][string]$RouteId,
    [string]$BaseUrl = '',
    [string]$SnapshotPath
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"
$config = Read-KcpsJson -Path $Path
$groups = @(Get-KcpsGroups -Config $config)
$matched = @($groups | Where-Object { $_['Name'] -eq $GroupName })
if ($matched.Count -ne 1) { throw '目标配置必须唯一。' }
$group = $matched[0]
$routes = Read-KcpsJson -Path "$PSScriptRoot\..\data\KCPS-RouteSpecs.json"
$route = @($routes['Routes'] | Where-Object { $_['Id'] -eq $RouteId })
if ($route.Count -ne 1) { throw '路线规格必须唯一。' }
$plan = $route[0]['BossSupportPlan']
if ($plan['SelectionMode'] -ne 'DynamicRoles') { throw '路线规格缺少动态支援角色。' }
$fleet = [int]$plan['Fleet']
$organize = @($group['List'] | Where-Object {
    (Test-KcpsWorkflowType $_ 'BasicOrganizeFleetWorkflow') -and [int]$_['Fleet'] -eq $fleet
})
if ($organize.Count -ne 1) { throw '决战支援编成必须唯一。' }
$const = if ($SnapshotPath) { (Read-KcpsJson $SnapshotPath)['const'] } else { Get-PoiData -Type const -BaseUrl $BaseUrl }
$masters = Get-KcpsConstEquips -Const $const
$roles = $plan['Roles']
$runtimeRoles = [ordered]@{}
foreach ($key in $roles.Keys) {
    if ([string]$key -notmatch '^[A-Za-z][A-Za-z0-9_]*$' -or [string]$key -in @('OnCandidate','support_candidate_score','register_support_roles','math','keyword','SUPPORT_ROLES','int','str','list','iter','next','sum','any','enumerate','range','getattr','globals','ValueError','False','None','True','and','as','assert','async','await','break','class','continue','def','del','elif','else','except','finally','for','from','global','if','import','in','is','lambda','nonlocal','not','or','pass','raise','return','try','while','with','yield')) { throw "动态角色名称无效：$key" }
    $role = $roles[$key]
    foreach ($field in @('ShipTypes','MinimumLevel','MinimumSlots','MinimumTotalCapacity','MinimumAircraftPerSlot','MinimumAirPower','EquipmentNames')) { if (-not $role.Contains($field)) { throw "角色 $key 缺少显式字段 $field。" } }
    if (@($role['EquipmentNames']).Count -lt 1 -or @($role['EquipmentNames']).Count -gt 5) { throw 'EquipmentNames 须提供 1 至 5 个普通槽装备。' }
    if (@($role['OptionalSlots'] | Where-Object { $null -ne $_ -and ([int]$_ -lt 1 -or [int]$_ -gt @($role['EquipmentNames']).Count) }).Count) { throw 'OptionalSlots 必须属于已声明普通槽。' }
    $expansionId = 0
    if ($role['ExpansionEquipmentName']) {
        $expansionMatches = @($masters.Values | Where-Object { $_['api_name'] -eq $role['ExpansionEquipmentName'] })
        if ($expansionMatches.Count -ne 1) { throw 'ExpansionEquipmentName 缺少唯一装备主数据。' }
        $expansionId = [int]$expansionMatches[0]['api_id']
    }
    $ids = @(); $aa = @()
    foreach ($name in $role['EquipmentNames']) {
        $equipment = @($masters.Values | Where-Object { $_['api_name'] -eq $name })
        if ($equipment.Count -ne 1) { throw "装备主数据不唯一：$name" }
        $ids += [int]$equipment[0]['api_id']
        $aa += [int]$equipment[0]['api_tyku']
    }
    $runtimeRoles[$key] = [ordered]@{
        ShipTypes = @($role['ShipTypes'])
        MinimumLevel = [int]$role['MinimumLevel']
        MinimumSlots = [int]$role['MinimumSlots']
        MinimumTotalCapacity = [int]$role['MinimumTotalCapacity']
        MinimumAircraftPerSlot = [int]$role['MinimumAircraftPerSlot']
        MinimumAirPower = [int]$role['MinimumAirPower']
        OptionalSlots = @($role['OptionalSlots'] | Where-Object { $null -ne $_ })
        RequireRemodeled = [int][bool]$role['RequireRemodeled']
        ExpansionEquipmentId = $expansionId
        EquipmentIds = $ids
        AntiAir = $aa
    }
}
$organize[0]['EnableScript'] = $true
$organize[0]['Script'] = 'SUPPORT_ROLES = ' + ($runtimeRoles | ConvertTo-Json -Depth 20 -Compress) + "`n" +
    (Get-Content -LiteralPath "$PSScriptRoot\support_rotation.py" -Raw)
$keys = @($plan['PositionRoles'])
if ($keys.Count -ne 6 -or @($organize[0]['Positions']).Count -ne 6) { throw '当前动态支援生成器支持六个位置。' }
if (@($plan['MoraleExclusionMax']).Count -ne 6 -or @($plan['MoraleExclusionMax'] | Where-Object { [int]$_ -lt 0 -or [int]$_ -gt 99 }).Count) { throw 'BossSupportPlan.MoraleExclusionMax 须逐位置明示士气排除上限。' }
for ($i = 0; $i -lt 6; $i++) {
    if (-not $roles.Contains([string]$keys[$i])) { throw "PositionRoles 引用了不存在的角色：$($keys[$i])" }
    $position = $organize[0]['Positions'][$i]
    $position['Selections'] = @([ordered]@{ Type = 8; Value = $keys[$i]; Memo = '通用支援候选，按能力与士气轮换' })
    $position['ChangeIfInitial'] = $true
    $position['ChangeIfMoraleInRangeFlag'] = $true
    $position['ChangeIfMoraleInRangeValueMin'] = 0
    $position['ChangeIfMoraleInRangeValueMax'] = [int]$plan['MoraleExclusionMax'][$i]
    $position['SkipMoraleInRangeFlag'] = $true
    $position['SkipMoraleInRangeValueMin'] = 0
    $position['SkipMoraleInRangeValueMax'] = $position['ChangeIfMoraleInRangeValueMax']
    $position['SkipWrongShips'] = $true
    $position['SkipRepairingShips'] = $true
    $position['SkipExpeditioningShips'] = $true
    $position['SkipShipsInOtherFleets'] = $true
    $position['IgnoreSkipShipsInOtherFleetsIfInitial'] = $false
    $position['SkipNotRemodeled'] = [bool]$roles[$keys[$i]]['RequireRemodeled']
    $position['IncludeCurrentShip'] = $false
    $position['IncludeCurrentSelection'] = $true
    $position['SelectionSortingMethod'] = $(if ($i -eq 0) { 1 } else { 2 })
    $position['KeepIfAllSelectionsFailed'] = $false
    $position['KeepIfSelectionCollectionEmpty'] = $false
}
$refits = @($group['List'] | Where-Object { Test-KcpsWorkflowType $_ 'BasicRefitEquipmentWorkflow' })
if ($refits.Count -ne 1) { throw '需要唯一改装执行单元。' }
$refit = $refits[0]
$old = @($refit['Ships'] | Where-Object { [int]$_['Fleet'] -eq $fleet })
if ($old.Count -ne 6) { throw '支援改装必须有六行。' }
function Copy-Value($Value) { $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable }
$shipTemplate = Copy-Value $old[0]
$slotTemplate = Copy-Value $old[0]['Slots'][0]
function New-Slot([int]$Number, [string]$Name, [bool]$Optional) {
    $slot = Copy-Value $slotTemplate
    $slot['Slot'] = $Number
    $slot['IgnoreSlotNotAvailable'] = $Optional
    $slot['IgnoreNoEquipmentMatched'] = $false
    $eq = Copy-Value $slot['Equipments'][0]
    $eq['SelectMethod'] = 0; $eq['SelectValue'] = $Name; $eq['Deprive'] = 2
    $slot['Equipments'] = @($eq)
    return $slot
}
$rows = @()
for ($i = 0; $i -lt 6; $i++) {
    $row = Copy-Value $shipTemplate
    $row['Fleet'] = $fleet; $row['SelectMethod'] = 0; $row['SelectValue'] = [string]($i + 1)
    $row['Memo'] = "通用反潜决战支援第 $($i + 1) 位"
    $names = @($roles[$keys[$i]]['EquipmentNames'])
    if ($names.Count -lt 1 -or $names.Count -gt 5) { throw '角色 EquipmentNames 须明确提供 1 至 5 个普通槽装备。' }
    $optionalSlots = @($roles[$keys[$i]]['OptionalSlots'])
    $slots = @()
    for ($n = 0; $n -lt $names.Count; $n++) { $slots += New-Slot ($n + 1) $names[$n] (($n + 1) -in $optionalSlots) }
    $expansion = [string]$roles[$keys[$i]]['ExpansionEquipmentName']
    if ($expansion) { $slots += New-Slot 6 $expansion $true }
    $row['Slots'] = $slots
    $rows += $row
}
$refit['Ships'] = @($refit['Ships'] | Where-Object { [int]$_['Fleet'] -ne $fleet }) + $rows
$organize[0]['Memo'] = '按当前 BossSupportPlan 声明的舰种、角色和配装选择支援；旗舰无闪或随伴疲劳时自动换船，逐槽过滤装备兼容性及制空下限。'
[IO.File]::WriteAllText($Path, (Write-KcpsJson -Value $config) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ Group = $GroupName; Fleet = $fleet; Positions = $keys; MinimumAirPower = $plan['MinimumSupportAirPower'] }
