#requires -Version 7.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

$masters = @{
    '10' = @{ api_name = 'ThreeSlot'; api_slot_num = 3; api_maxeq = @(0, 0, 0, 0, 0) }
    '20' = @{ api_name = 'FourSlot'; api_slot_num = 4 }
    '30' = @{ api_name = 'FiveSlot'; api_slot_num = 5 }
}
$ships = @{
    '1' = @{ api_ship_id = 10; api_slotnum = 3; api_slot_ex = 0; api_slot = @(-1, -1, -1, -1, -1) }
    '2' = @{ api_ship_id = 20; api_slotnum = 4; api_slot_ex = -1 }
    '3' = @{ api_ship_id = 30; api_slotnum = 5; api_slot_ex = 900 }
}
function New-Refit($id, $number, $optional = $false, $method = 3, $guid = 'refit') {
    return @{
        Type = 'KancollePlayerSimulatorKai.BasicRefitEquipmentWorkflow, KancollePlayerSimulatorKai'
        Name = 'Refit'; Guid = $guid
        Ships = @(@{ Fleet = 1; SelectMethod = $method; SelectValue = [string]$id
            Slots = @(@{ Slot = $number; IgnoreSlotNotAvailable = $optional }) })
    }
}
function New-Organize($ids, $guid = 'organize') {
    return @{
        Type = 'KancollePlayerSimulatorKai.BasicOrganizeFleetWorkflow, KancollePlayerSimulatorKai'
        Guid = $guid; Fleet = 1
        Positions = @(@{ Selections = @($ids | ForEach-Object { @{ Type = 0; Value = [string]$_ } }) })
    }
}
$script:passed = 0
function Assert-Problems($label, $workflows, $expected, $category = '', $strict = $true) {
    $result = @(Get-KcpsRefitSlotExistenceProblems -Workflows @($workflows) -OwnedShips $ships -MasterShips $masters -RejectOptionalFixedSlots:$strict)
    if ($result.Count -ne $expected) { throw "${label}: expected $expected, got $($result.Count): $($result | ConvertTo-Json -Depth 5 -Compress)" }
    if ($category -and @($result | Where-Object { $_.Category -ne $category }).Count) { throw "${label}: wrong category" }
    $script:passed++
}

# 三槽船的API数组可补齐到五项，不能据此生成第四槽。
Assert-Problems 'padded array is not slot count' (New-Refit 1 4) 1 'NonexistentNormalSlot'
Assert-Problems 'real third slot' (New-Refit 1 3) 0
Assert-Problems 'real fourth slot' (New-Refit 2 4) 0
Assert-Problems 'real fifth slot' (New-Refit 3 5) 0
Assert-Problems 'fixed event cannot hide phantom slot' (New-Refit 1 4 $true) 1 'NonexistentNormalSlot'
Assert-Problems 'optional template slot' (New-Refit 1 4 $true) 0 '' $false
Assert-Problems 'closed expansion required' (New-Refit 1 6) 1 'UnavailableExtraSlot'
Assert-Problems 'closed expansion optional' (New-Refit 1 6 $true) 0
Assert-Problems 'open empty expansion' (New-Refit 2 6) 0
Assert-Problems 'open equipped expansion' (New-Refit 3 6) 0
Assert-Problems 'zero slot invalid' (New-Refit 1 0) 1 'InvalidSlot'
Assert-Problems 'seventh slot invalid' (New-Refit 1 7) 1 'InvalidSlot'
Assert-Problems 'missing owned ship' (New-Refit 99 1) 1 'UnknownSlotData'
$ships['1']['api_slot_ex'] = $null
Assert-Problems 'unknown expansion' (New-Refit 1 6) 1 'UnknownExtraSlot'
$ships['1']['api_slot_ex'] = 0
$ships['1'].Remove('api_slotnum')
Assert-Problems 'master count fallback' (New-Refit 1 4) 1 'NonexistentNormalSlot'
$masters['10'].Remove('api_slot_num')
Assert-Problems 'padded arrays cannot replace missing count' (New-Refit 1 1) 1 'UnknownSlotData'
$masters['10']['api_slot_num'] = 3
$ships['1']['api_slotnum'] = 4
Assert-Problems 'remodel cache disagreement' (New-Refit 1 4) 1 'UnknownSlotData'
$ships['1']['api_slotnum'] = 3

# 通用支援候选混用三槽、四槽船时，额外槽必须允许跳过。
$organize = New-Organize @(1, 2)
Assert-Problems 'rotation optional fourth slot' @($organize, (New-Refit 1 4 $true 0)) 0
Assert-Problems 'rotation required fourth slot' @($organize, (New-Refit 1 4 $false 0)) 1 'NonexistentNormalSlot'
Assert-Problems 'position fixed three slot' @((New-Organize @(1)), (New-Refit 1 4 $false 0)) 1 'NonexistentNormalSlot'

# 演习各分支按总控关联配对，不能用另一分支的船套用槽数。
$contexts = @(
    @{ OrganizeBeforeWorkflows = @(@{ Guid = 'four'; Enabled = $true }); RefitEquipmentBeforeWorkflows = @(@{ Guid = 'four-refit'; Enabled = $true }) },
    @{ Enabled = $true; OrganizeBeforeWorkflows = @(@{ Guid = 'three'; Enabled = $true }); RefitEquipmentBeforeWorkflows = @(@{ Guid = 'three-refit'; Enabled = $true }) }
)
$branches = @(
    (New-Organize @(2) 'four'), (New-Organize @(1) 'three'),
    (New-Refit 1 4 $false 0 'four-refit'), (New-Refit 1 3 $false 0 'three-refit'),
    @{ Type = 'Exercise'; DefaultStrategy = $contexts[0]; ConditionalStrategies = @($contexts[1]) }
)
Assert-Problems 'branch refit matches its own organize' $branches 0
$branches[3]['Ships'][0]['Slots'][0]['Slot'] = 4
Assert-Problems 'branch real phantom slot still fails' $branches 1 'NonexistentNormalSlot'
Assert-Problems 'empty workflow list' @() 0

function Assert-Continuity($label, $values, $expected, $slots = @(1..$values.Count), $method = 3, $declare = $true) {
    $row = @{ Fleet=1; SelectMethod=$method; SelectValue='1'; Slots=@(); Memo='' }
    $empty = @()
    for ($i=0; $i -lt $values.Count; $i++) {
        $selectors = @($values[$i] | ForEach-Object { @{SelectMethod=0;SelectValue=$_} })
        $row.Slots += @{Slot=$slots[$i];Equipments=$selectors;IgnoreNoEquipmentMatched=$false;IgnoreSlotNotAvailable=$false}
        if (@($values[$i]).Count -eq 1 -and [string]$values[$i] -eq '') { $empty += $slots[$i] }
    }
    if ($declare -and $empty.Count) { $row.Memo="KCPS_ALLOW_EMPTY_SLOTS=$($empty -join ','); REASON=练级主动卸装" }
    $refit = New-Refit 1 1
    $refit.Ships = @($row)
    $result = @(Get-KcpsRefitSlotContinuityProblems -Workflows @($refit))
    if ($result.Count -ne $expected) { throw "${label}: expected $expected, got $($result.Count)" }
    $script:passed++
}
# 对照报错配装，空槽声明不能绕过原生改装限制。
Assert-Continuity 'Bearn isolated third slot' @('', '', 'Saiun') 1
Assert-Continuity 'Ranger isolated fourth slot' @('', '', '', 'Saiun') 1
Assert-Continuity 'move Saiun to first slot' @('Saiun', '', '') 0
Assert-Continuity 'all slots intentionally empty' @('', '', '') 0
Assert-Continuity 'middle gap is rejected' @('Sonar', '', 'Bomb') 1
Assert-Continuity 'each later equipped slot reported' @('', 'Sonar', 'Bomb') 2
Assert-Continuity 'expansion is independent' @('', '', 'Lookout') 0 @(1,2,6)
Assert-Continuity 'dynamic position has same restriction' @('', 'Saiun') 1 @(1,2) 0
Assert-Continuity 'row order cannot bypass gap' @('Saiun', '', '') 1 @(3,2,1)
Assert-Continuity 'undeclared unload is also rejected' @('', 'Saiun') 1 @(1,2) 3 $false
Assert-Continuity 'unload fallback before later equipment' @(@('Sonar', ''), 'Bomb') 1
Assert-Continuity 'equipment after first unload is unreachable' @(@('', 'Sonar'), '') 0
"Passed $script:passed refit slot regression tests."
