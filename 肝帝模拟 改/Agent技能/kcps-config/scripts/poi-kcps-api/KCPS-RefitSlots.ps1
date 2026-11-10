function Get-KcpsRefitSlotContinuityProblems {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Workflows)
    foreach ($refit in @($Workflows | Where-Object { Test-KcpsWorkflowType $_ 'BasicRefitEquipmentWorkflow' })) {
        foreach ($row in @($refit['Ships'])) {
            $emptySlots = @(); $equippedSlots = @()
            foreach ($slot in @($row['Slots'])) {
                $number = [int]$slot['Slot']
                if ($number -notin 1..5) { continue }
                # 普通槽的卸装会阻止后槽装入；补强槽独立，不参与连续性判断。
                $selectors = @($slot['Equipments'] | Where-Object { $null -ne $_ })
                $mayEquip = $false; $mayUnload = $false
                foreach ($selector in $selectors) {
                    if ([string]::IsNullOrWhiteSpace([string]$selector['SelectValue'])) { $mayUnload = $true; break }
                    $mayEquip = $true
                }
                if ($mayUnload) { $emptySlots += $number }
                if ($mayEquip) { $equippedSlots += $number }
            }
            foreach ($number in @($equippedSlots | Sort-Object -Unique)) {
                $before = @($emptySlots | Where-Object { $_ -lt $number } | Sort-Object -Unique)
                if ($before.Count -eq 0) { continue }
                [pscustomobject]@{
                    Category = 'EmptyPrecedingNormalSlot'; Workflow = [string]$refit['Name']
                    Fleet = [int]$row['Fleet']; SelectMethod = [int]$row['SelectMethod']
                    SelectValue = [string]$row['SelectValue']; Slot = $number; EmptyPrecedingSlots = $before
                    Problem = "$($refit['Name'])：舰船选择$($row['SelectValue'])第$number 槽计划装入装备，但前置普通槽$($before -join ',')包含卸空方案；KCPS无法执行。普通装备须从第1槽连续配置，空槽只能留在末尾。"
                }
            }
        }
    }
}

function Get-KcpsRefitSlotExistenceProblems {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Workflows,
        [Parameter(Mandatory)][System.Collections.IDictionary]$OwnedShips,
        [Parameter(Mandatory)][System.Collections.IDictionary]$MasterShips,
        [switch]$RejectOptionalFixedSlots
    )
    $problems = @()
    $organizes = @($Workflows | Where-Object { Test-KcpsWorkflowType $_ 'BasicOrganizeFleetWorkflow' })
    foreach ($refit in @($Workflows | Where-Object { Test-KcpsWorkflowType $_ 'BasicRefitEquipmentWorkflow' })) {
        $linkedOrganizeIds = @()
        foreach ($workflow in $Workflows) {
            $contexts = @($workflow)
            if ($workflow['DefaultStrategy'] -is [System.Collections.IDictionary]) { $contexts += $workflow['DefaultStrategy'] }
            $contexts += @($workflow['ConditionalStrategies'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['Enabled'] })
            foreach ($context in $contexts) {
                $refitRefs = @($context['RefitEquipmentBeforeWorkflows']) + @($context['RefitEquipmentAfterWorkflows'])
                if (@($refitRefs | Where-Object { $_ -and $_['Enabled'] -and $_['Guid'] -eq $refit['Guid'] }).Count -eq 0) { continue }
                $organizeRefs = @($context['OrganizeBeforeWorkflows']) + @($context['OrganizeAfterWorkflows'])
                $linkedOrganizeIds += @($organizeRefs | Where-Object { $_ -and $_['Enabled'] } | ForEach-Object { [string]$_['Guid'] })
            }
        }
        $rowIndex = -1
        foreach ($row in @($refit['Ships'])) {
            $rowIndex++
            $ids = @()
            $fixed = [int]$row['SelectMethod'] -eq 3
            if ($fixed -and [string]$row['SelectValue'] -match '^\d+$') {
                $ids = @([string]$row['SelectValue'])
            } elseif ([int]$row['SelectMethod'] -eq 0) {
                # 按位置改装只解析编成中的明确候选，不读取当前舰队猜测未来选船。
                $position = [int]$row['SelectValue']
                $rowOrganizes = @($organizes | Where-Object { [int]$_['Fleet'] -eq [int]$row['Fleet'] })
                if ($linkedOrganizeIds.Count -gt 0) { $rowOrganizes = @($rowOrganizes | Where-Object { $_['Guid'] -in $linkedOrganizeIds }) }
                # 不把演习的水面和潜水两套分支交叉配对。
                if ($linkedOrganizeIds.Count -eq 0 -and $rowOrganizes.Count -gt 1) { continue }
                foreach ($organize in $rowOrganizes) {
                    if ($position -lt 1 -or $position -gt @($organize['Positions']).Count) { continue }
                    foreach ($selection in @($organize['Positions'][$position - 1]['Selections'])) {
                        if ([int]$selection['Type'] -eq 0 -and [string]$selection['Value'] -match '^\d+$') { $ids += [string]$selection['Value'] }
                    }
                }
                $ids = @($ids | Select-Object -Unique)
            }
            foreach ($id in $ids) {
                $ship = $null; $master = $null; $slotCount = $null; $name = "舰船ID $id"
                $dataProblem = ''
                if (-not $OwnedShips.Contains($id)) { $dataProblem = '不在当前账号数据中，不能验证槽位。' }
                else {
                    $ship = $OwnedShips[$id]
                    $masterId = [string]$ship['api_ship_id']
                    if ($MasterShips.Contains($masterId)) { $master = $MasterShips[$masterId]; $name = [string]$master['api_name'] }
                    # api_slot/api_maxeq可能补齐到五项，数组长度不是实际槽数。
                    $liveCount = if ($ship.Contains('api_slotnum')) { $ship['api_slotnum'] } else { $null }
                    $masterCount = if ($null -ne $master) { $master['api_slot_num'] } else { $null }
                    if ($null -ne $liveCount) { $slotCount = [int]$liveCount }
                    elseif ($null -ne $masterCount) { $slotCount = [int]$masterCount }
                    if ($null -eq $slotCount -or $slotCount -lt 1 -or $slotCount -gt 5) { $dataProblem = '缺少有效的实际主装备槽数，不能验证槽位。' }
                    elseif ($null -ne $masterCount -and [int]$masterCount -ne $slotCount) { $dataProblem = "实时主槽数 $slotCount 与主数据 $masterCount 不一致，请刷新改造数据。" }
                }
                $slots = @($row['Slots'])
                $indices = if ($dataProblem) { @(-1) } else { @(0..($slots.Count - 1) | Where-Object { $_ -ge 0 -and $_ -lt $slots.Count }) }
                foreach ($index in $indices) {
                    $category = ''; $reason = ''; $number = $null
                    if ($dataProblem) { $category = 'UnknownSlotData'; $reason = $dataProblem }
                    else {
                        $slot = $slots[$index]; $number = [int]$slot['Slot']
                        $optional = [bool]$slot['IgnoreSlotNotAvailable']
                        if ($number -lt 1 -or $number -gt 6) { $category = 'InvalidSlot'; $reason = "槽编号 $number 无效，应为1..5或补强槽6。" }
                        elseif ($number -le 5 -and $number -gt $slotCount -and
                            (-not $optional -or ($fixed -and $RejectOptionalFixedSlots))) {
                            $category = 'NonexistentNormalSlot'
                            $reason = "仅有 $slotCount 个主装备槽，却配置了第 $number 槽。"
                        } elseif ($number -eq 6 -and -not $optional) {
                            if (-not $ship.Contains('api_slot_ex') -or $null -eq $ship['api_slot_ex']) {
                                $category = 'UnknownExtraSlot'; $reason = '补强槽状态未知，不能要求必装。'
                            } elseif ([int]$ship['api_slot_ex'] -eq 0) {
                                $category = 'UnavailableExtraSlot'; $reason = '未开放补强增设，却要求第6槽必装。'
                            }
                        }
                    }
                    if (-not $category) { continue }
                    $problems += [pscustomobject]@{
                        Category = $category; Workflow = [string]$refit['Name']; WorkflowGuid = [string]$refit['Guid']
                        RowIndex = $rowIndex; SlotIndex = $index; Fleet = [int]$row['Fleet']
                        SelectMethod = [int]$row['SelectMethod']; SelectValue = [string]$row['SelectValue']
                        ShipId = $id; Ship = $name; Slot = $number; ActualNormalSlots = $slotCount
                        Problem = "$($refit['Name'])：$name($id)$reason"
                    }
                }
            }
        }
    }
    return $problems
}
