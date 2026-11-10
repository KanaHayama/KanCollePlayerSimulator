#requires -Version 7.0

param(
    [string[]]$ShipIds = @(),
    [string[]]$QuestIds = @(),
    [string[]]$EquipNames = @(),
    [string]$BaseUrl = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

function Convert-ToIntList {
    param([string[]]$Values)

    $result = @()
    foreach ($value in $Values) {
        foreach ($part in (($value -as [string]) -split ',')) {
            $trimmed = $part.Trim()
            if ($trimmed.Length -gt 0) {
                $result += [int]$trimmed
            }
        }
    }
    $result
}

$shipIdList = @(Convert-ToIntList -Values $ShipIds)
$questIdList = @(Convert-ToIntList -Values $QuestIds)

$const = Get-PoiData -BaseUrl $BaseUrl -Type 'const'
$ships = Get-PoiData -BaseUrl $BaseUrl -Type 'ships'
$fleets = Get-PoiData -BaseUrl $BaseUrl -Type 'fleets'
$equips = Get-PoiData -BaseUrl $BaseUrl -Type 'equips'
$quests = Get-PoiQuestList -BaseUrl $BaseUrl

$fleetShipMap = Get-KcpsFleetShipMap -Fleets $fleets
$holderMap = Get-KcpsEquipmentHolderMap -Ships $ships -Const $const
$constEquips = Get-KcpsConstEquips -Const $const

$fleetSummary = foreach ($fleet in $fleets) {
    $fleetShips = foreach ($shipId in $fleet['api_ship']) {
        if ([int]$shipId -gt 0 -and $ships.ContainsKey([string]$shipId)) {
            $ship = $ships[[string]$shipId]
            [pscustomobject]@{
                Id = [int]$shipId
                Name = Get-KcpsConstShipName -Const $const -ShipConstId ([int]$ship['api_ship_id'])
                Lv = [int]$ship['api_lv']
                Hp = "$($ship['api_nowhp'])/$($ship['api_maxhp'])"
                Cond = [int]$ship['api_cond']
            }
        }
    }
    [pscustomobject]@{
        Fleet = [int]$fleet['api_id']
        Name = $fleet['api_name']
        Mission = ($fleet['api_mission'] -join ',')
        Ships = @($fleetShips)
    }
}

if ($shipIdList.Count -eq 0) {
    $shipIdList = @($fleets[0]['api_ship'] | Where-Object { [int]$_ -gt 0 } | ForEach-Object { [int]$_ })
}

$shipSummary = foreach ($shipId in $shipIdList) {
    $key = [string]$shipId
    if (-not $ships.ContainsKey($key)) {
        [pscustomobject]@{ Id = $shipId; Found = $false }
        continue
    }
    $ship = $ships[$key]
    $slotNames = foreach ($equipId in $ship['api_slot']) {
        if ([int]$equipId -gt 0 -and $equips.ContainsKey([string]$equipId)) {
            $equip = $equips[[string]$equipId]
            Get-KcpsConstEquipName -Const $const -EquipConstId ([int]$equip['api_slotitem_id'])
        } elseif ([int]$equipId -eq -1) {
            '<empty>'
        } else {
            '<none>'
        }
    }
    $extraId = [int]$ship['api_slot_ex']
    $extraName = $null
    if ($extraId -gt 0 -and $equips.ContainsKey([string]$extraId)) {
        $extraName = Get-KcpsConstEquipName -Const $const -EquipConstId ([int]$equips[[string]$extraId]['api_slotitem_id'])
    }
    [pscustomobject]@{
        Id = [int]$ship['api_id']
        Found = $true
        ConstId = [int]$ship['api_ship_id']
        Name = Get-KcpsConstShipName -Const $const -ShipConstId ([int]$ship['api_ship_id'])
        Fleet = $(if ($fleetShipMap.ContainsKey($key)) { $fleetShipMap[$key] } else { 0 })
        Lv = [int]$ship['api_lv']
        Hp = "$($ship['api_nowhp'])/$($ship['api_maxhp'])"
        Cond = [int]$ship['api_cond']
        Asw = "$($ship['api_taisen'][0])/$($ship['api_taisen'][1])"
        SlotNum = [int]$ship['api_slotnum']
        DockTimeMs = [int64]$ship['api_ndock_time']
        Slots = @($slotNames)
        ExtraSlotId = $extraId
        ExtraSlot = $extraName
    }
}

$questSummary = foreach ($questId in $questIdList) {
    $match = @($quests['api_list'] | Where-Object { [int]$_['api_no'] -eq $questId })
    if ($match.Count -eq 0) {
        [pscustomobject]@{ No = $questId; Found = $false }
    } else {
        $q = $match[0]
        [pscustomobject]@{
            No = [int]$q['api_no']
            Found = $true
            State = [int]$q['api_state']
            Progress = [int]$q['api_progress_flag']
            Title = $q['api_title']
            Detail = $q['api_detail']
        }
    }
}

$equipSummary = foreach ($name in $EquipNames) {
    $items = foreach ($entry in $equips.GetEnumerator()) {
        $equip = $entry.Value
        $constEquip = $constEquips[[string]$equip['api_slotitem_id']]
        if ($null -eq $constEquip) { continue }
        $equipName = $constEquip['api_name']
        if ($equipName -ne $name) { continue }
        $holder = $null
        if ($holderMap.ContainsKey([string]$equip['api_id'])) {
            $holder = $holderMap[[string]$equip['api_id']]
        }
        [pscustomobject]@{
            Id = [int]$equip['api_id']
            ItemId = [int]$equip['api_slotitem_id']
            Name = $equipName
            Level = [int]$equip['api_level']
            Locked = [int]$equip['api_locked']
            HolderShipId = $(if ($holder) { $holder.ShipId } else { 0 })
            HolderShipName = $(if ($holder) { $holder.ShipName } else { $null })
            Slot = $(if ($holder) { $holder.Slot } else { 0 })
            ExtraSlot = $(if ($holder) { $holder.ExtraSlot } else { $false })
            Asw = $constEquip['api_tais']
            Type = ($constEquip['api_type'] -join ',')
        }
    }
    [pscustomobject]@{
        Name = $name
        Count = @($items).Count
        Items = @($items | Sort-Object HolderShipId, Level, Id)
    }
}

[pscustomobject]@{
    Timestamp = (Get-Date).ToString('s')
    Fleets = @($fleetSummary)
    Ships = @($shipSummary)
    Quests = @($questSummary)
    Equips = @($equipSummary)
} | ConvertTo-KcpsJsonOutput -Depth 40
