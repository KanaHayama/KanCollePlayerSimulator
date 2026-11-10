#requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,

    [string]$BaseUrl = '',

    [ValidateRange(-1, 7)][int]$FixedPrefixCount = -1,

    [string]$OrderPolicyPath
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

function Normalize-KcpsShipMemo {
    param([string]$Memo)

    if ($null -eq $Memo) { return '' }
    $value = $Memo.Trim()
    $value = $value -replace '^\[', '' -replace '\]$', ''
    $value = $value -replace '\s*\(\d+\)', ''
    $value = $value -replace '\s*#\d+', ''
    $value.Trim()
}

function Get-FixedPrefixHint {
    param([string]$GroupName, [int]$DefaultCount = -1, [System.Collections.IDictionary]$Policies = @{})
    $count = $DefaultCount
    if ($Policies.Contains($GroupName)) {
        $entry = $Policies[$GroupName]
        if ($entry -isnot [System.Collections.IDictionary] -or -not $entry.Contains('FixedPrefixCount')) {
            throw '舰队顺序策略必须显式提供 FixedPrefixCount。'
        }
        $count = [int]$entry['FixedPrefixCount']
    }
    if ($count -lt 0 -or $count -gt 7) {
        throw '缺少当前配置的固定前缀船数；请指定 FixedPrefixCount 或 OrderPolicyPath，不能从任务名称推断。'
    }
    return $count
}

function Test-NightWeakCarrier {
    param(
        [string]$ShipType,
        [string[]]$EquipmentNames
    )

    if ($ShipType -notin @('正規空母', '装甲空母', '軽空母')) { return $false }
    $equipmentText = ($EquipmentNames -join '|')
    if ($equipmentText -match '夜間作戦航空要員|F6F-3N|F6F-5N|TBM-3D|夜間航空|夜戦') {
        return $false
    }
    return $true
}

function Get-RangeName {
    param([object]$Range)

    switch ([int]$Range) {
        0 { 'なし' }
        1 { '短' }
        2 { '中' }
        3 { '長' }
        4 { '超長' }
        default { "Unknown($Range)" }
    }
}

function Get-RangeValueFromName {
    param([string]$RangeName)

    switch ($RangeName) {
        'なし' { 0 }
        '短' { 1 }
        '中' { 2 }
        '長' { 3 }
        '超長' { 4 }
        default { -1 }
    }
}

function Get-EffectiveRangeName {
    param(
        [string]$BaseRangeName,
        [string[]]$EquipmentNames,
        [hashtable]$EquipmentNameToRange
    )

    $range = Get-RangeValueFromName $BaseRangeName
    foreach ($name in @($EquipmentNames)) {
        if ($null -eq $name -or $name -eq '') { continue }
        if ($EquipmentNameToRange.ContainsKey($name)) {
            $range = [Math]::Max($range, [int]$EquipmentNameToRange[$name])
            continue
        }
        if ($name -match '熟練甲板要員\+航空整備員') {
            $range = [Math]::Max($range, 4)
        } elseif ($name -match '彗星二二型|熟練艦載機整備員') {
            $range = [Math]::Max($range, 3)
        }
    }

    return Get-RangeName $range
}

$orderPolicies = @{}
if ($OrderPolicyPath) {
    $policy = Read-KcpsJson -Path $OrderPolicyPath
    if ($policy -isnot [System.Collections.IDictionary] -or $policy['Groups'] -isnot [System.Collections.IDictionary]) {
        throw '舰队顺序策略文件必须包含以配置名称为键的 Groups 对象。'
    }
    $orderPolicies = $policy['Groups']
}
if ($FixedPrefixCount -lt 0 -and -not $OrderPolicyPath) {
    throw '请先指定 FixedPrefixCount 或 OrderPolicyPath；不会根据任务名推断固定船位。'
}

$start2 = Get-PoiJson -BaseUrl $BaseUrl -Path '/response?type=/kcsapi/api_start2/getData'
$shipTypes = @{}
foreach ($stype in @($start2['api_mst_stype'])) {
    $shipTypes[[string]$stype['api_id']] = [string]$stype['api_name']
}
$shipNameToType = @{}
$shipNameToRange = @{}
foreach ($ship in @($start2['api_mst_ship'])) {
    if (-not $shipNameToType.ContainsKey($ship['api_name'])) {
        $shipNameToType[$ship['api_name']] = $shipTypes[[string]$ship['api_stype']]
        $shipNameToRange[$ship['api_name']] = Get-RangeName $ship['api_leng']
    }
}
$equipmentNameToRange = @{}
foreach ($equipment in @($start2['api_mst_slotitem'])) {
    $name = [string]$equipment['api_name']
    if ($equipment.ContainsKey('api_leng') -and -not $equipmentNameToRange.ContainsKey($name)) {
        $equipmentNameToRange[$name] = [int]$equipment['api_leng']
    }
}
$smokeEquipmentNames = @('発煙装置(煙幕)', '発煙装置改(煙幕)')
$consumableEquipmentNames = @(
    '応急修理要員',
    '応急修理女神',
    '戦闘糧食',
    '戦闘糧食(特別なおにぎり)',
    '秋刀魚の缶詰',
    '洋上補給'
)

$results = @()
foreach ($target in $Path) {
    $resolved = Resolve-Path -LiteralPath $target
    foreach ($file in @($resolved)) {
        $cfg = Read-KcpsJson -Path $file.Path
        foreach ($group in Get-KcpsGroups -Config $cfg) {
            $list = @($group['List'])
            $organize = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow' } | Select-Object -First 1)
            $refit = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicRefitEquipmentWorkflow' } | Select-Object -First 1)
            $sortie = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleSortieWorkflow' } | Select-Object -First 1)
            $organize = $(if ($organize.Count -gt 0) { $organize[0] } else { $null })
            $refit = $(if ($refit.Count -gt 0) { $refit[0] } else { $null })
            $sortie = $(if ($sortie.Count -gt 0) { $sortie[0] } else { $null })
            if ($null -eq $organize -or $null -eq $sortie) { continue }

            $nightBattleExpected = $false
            if ($sortie['DefaultBossBattleStrategyFlag'] -and [int]$sortie['DefaultBossBattleStrategy']['DefaultMidnight'] -eq 2) {
                $nightBattleExpected = $true
            }
            foreach ($strategy in @($sortie['Strategies'])) {
                if ([int]$strategy['Strategy']['DefaultMidnight'] -eq 2) { $nightBattleExpected = $true }
            }

            $refitByName = @{}
            if ($refit) {
                foreach ($ship in @($refit['Ships'])) {
                    $shipName = Normalize-KcpsShipMemo $ship['Memo']
                    $refitByName[$shipName] = $ship
                }
            }

            $order = @()
            $index = 0
            foreach ($position in @($organize['Positions'])) {
                $index++
                $selection = @($position['Selections'] | Where-Object { $null -ne $_ } | Select-Object -First 1)
                if ($selection.Count -eq 0) { continue }
                $memo = [string]$selection[0]['Memo']
                $name = Normalize-KcpsShipMemo $memo
                $equipments = @()
                if ($refitByName.ContainsKey($name)) {
                    $equipments = @($refitByName[$name]['Slots'] | ForEach-Object { @($_['Equipments'])[0]['SelectValue'] })
                }
                $shipType = $(if ($shipNameToType.ContainsKey($name)) { $shipNameToType[$name] } else { '?' })
                $rangeName = $(if ($shipNameToRange.ContainsKey($name)) { $shipNameToRange[$name] } else { '?' })
                $effectiveRangeName = Get-EffectiveRangeName -BaseRangeName $rangeName -EquipmentNames $equipments -EquipmentNameToRange $equipmentNameToRange
                $order += [pscustomobject]@{
                    Position = $index
                    Ship = $name
                    ShipType = $shipType
                    BaseRange = $rangeName
                    EffectiveRange = $effectiveRangeName
                    NightWeak = Test-NightWeakCarrier -ShipType $shipType -EquipmentNames $equipments
                    Equipments = @($equipments)
                }
            }

            $fixedPrefix = Get-FixedPrefixHint -GroupName ([string]$group['Name']) -DefaultCount $FixedPrefixCount -Policies $orderPolicies
            $warnings = @()
            if ($nightBattleExpected) {
                $free = @($order | Where-Object { $_.Position -gt $fixedPrefix })
                $firstWeak = @($free | Where-Object { $_.NightWeak } | Select-Object -First 1)
                $lastNightCapable = @($free | Where-Object { -not $_.NightWeak } | Select-Object -Last 1)
                if ($firstWeak.Count -gt 0 -and $lastNightCapable.Count -gt 0 -and $firstWeak[0].Position -lt $lastNightCapable[0].Position) {
                    $warnings += "Night battle expected, but night-weak carrier $($firstWeak[0].Ship) at position $($firstWeak[0].Position) is before night-capable ships in free positions."
                }
                $finishersBehindWeak = @($free | Where-Object { -not $_.NightWeak } | Select-Object -Last 2 | ForEach-Object { "$($_.Position):$($_.Ship)" })
                if ($finishersBehindWeak.Count -gt 0) {
                    $warnings += "Verify night target roles: place stable cleaners before finishers, and keep boss/high-armor finishers late unless a threat must be killed early. Late candidates: $($finishersBehindWeak -join ', ')."
                }
            }

            $longRange = @($order | Where-Object { $_.EffectiveRange -in @('長', '超長') } | ForEach-Object { "$($_.Position):$($_.Ship)/base=$($_.BaseRange),effective=$($_.EffectiveRange)" })
            if ($longRange.Count -gt 0) {
                $warnings += "Day shelling order depends on effective range after equipment, not fleet order; verify range tuning and who should clean first: $($longRange -join ', ')."
            }

            $specialCandidates = @($order | Where-Object {
                $_.Ship -match 'Nelson|Rodney|長門改二|陸奥改二|大和改二|武蔵改二|Colorado|Maryland|金剛改二丙|比叡改二丙|榛名改二乙|榛名改二丙'
            } | ForEach-Object { "$($_.Position):$($_.Ship)" })
            if ($specialCandidates.Count -gt 0) {
                $warnings += "Special-attack-capable ships present; verify flagship/partner positions and formation against wiki: $($specialCandidates -join ', ')."
            }

            $carrierSprayUsers = @($order | Where-Object {
                $_.ShipType -in @('正規空母', '装甲空母', '軽空母') -and
                @($_.Equipments | Where-Object { $_ -eq '12cm30連装噴進砲改二' }).Count -gt 0
            } | ForEach-Object { "$($_.Position):$($_.Ship)" })
            $carrierWrenchUsers = @($order | Where-Object {
                $_.ShipType -in @('正規空母', '装甲空母', '軽空母') -and
                @($_.Equipments | Where-Object { $_ -eq '熟練甲板要員+航空整備員' }).Count -gt 0
            } | ForEach-Object { "$($_.Position):$($_.Ship)" })
            if ($specialCandidates.Count -eq 0 -and $carrierSprayUsers.Count -gt 0 -and $carrierWrenchUsers.Count -eq 0) {
                $warnings += "Carrier ex-slots use spray guns and no special-attack-capable ship is present; if boss day-shelling pressure is higher than air-phase survival pressure, consider 熟練甲板要員+航空整備員 on main carriers. Current spray carriers: $($carrierSprayUsers -join ', ')."
            }

            $saiunUsers = @($order | Where-Object {
                @($_.Equipments | Where-Object { $_ -like '彩雲*' }).Count -gt 0
            } | ForEach-Object {
                $saiun = @($_.Equipments | Where-Object { $_ -like '彩雲*' })
                "$($_.Position):$($_.Ship)/$($saiun -join '+')"
            })
            if ($saiunUsers.Count -gt 1) {
                $warnings += "Repeated 彩雲 family in one fleet; T-disadvantage prevention is fleet-level and does not stack. Keep one unless LOS/contact math justifies more: $($saiunUsers -join ', ')."
            }

            $smokeUsers = @($order | Where-Object {
                @($_.Equipments | Where-Object { $_ -in $smokeEquipmentNames }).Count -gt 0
            } | ForEach-Object { "$($_.Position):$($_.Ship)" })
            if ($smokeUsers.Count -gt 0) {
                $warnings += "Smoke equipment present; ensure the sortie strategy/notes specify the exact node to use smoke, enemy radar risk, hit-rate loss, and why smoke is better than normal combat: $($smokeUsers -join ', ')."
            }

            $consumableUsers = @($order | Where-Object {
                @($_.Equipments | Where-Object { $_ -in $consumableEquipmentNames }).Count -gt 0
            } | ForEach-Object { "$($_.Position):$($_.Ship)" })
            if ($consumableUsers.Count -gt 0) {
                $warnings += "Consumable equipment present; default configs must not use it unless the user explicitly approved the expected consumption: $($consumableUsers -join ', ')."
            }

            $results += [pscustomobject]@{
                File = Split-Path -Leaf $file.Path
                Group = $group['Name']
                NightBattleExpected = $nightBattleExpected
                FixedPrefixHint = $fixedPrefix
                Order = @($order)
                Warnings = @($warnings)
            }
        }
    }
}

[pscustomobject]@{
    Timestamp = (Get-Date).ToString('s')
    ResultCount = @($results).Count
    WarningCount = @($results | ForEach-Object { @($_.Warnings) } | Where-Object { $_ }).Count
    Results = @($results)
} | ConvertTo-KcpsJsonOutput -Depth 80
