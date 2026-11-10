#requires -Version 7.0

<#
.SYNOPSIS
    查询账号库存：按名字正则匹配「拥有的舰船」和「拥有的装备」，给出数量、改修等级、空闲数和当前持有者。
.DESCRIPTION
    生成/审计配置前确认"某舰/某装备是否拥有、有几个、改修多少、被谁占用"的通用工具。
    数据来自 poi /data?type=（const/ships/equips/fleets），不改任何游戏状态。
    -EquipPatterns / -ShipPatterns 是 PowerShell 正则（-match）；可传多个，逐个汇总。
.EXAMPLE
    KCPS-Inventory.ps1 -EquipPatterns '噴式景雲改','発煙装置','甲標的' -ShipPatterns '飛龍改三','加賀改二','翔鶴改二'
#>
param(
    [string[]]$EquipPatterns = @(),
    [string[]]$ShipPatterns = @(),
    [string]$BaseUrl = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

$const  = Get-PoiData -BaseUrl $BaseUrl -Type 'const'
$ships  = Get-PoiData -BaseUrl $BaseUrl -Type 'ships'
$fleets = Get-PoiData -BaseUrl $BaseUrl -Type 'fleets'
$equips = Get-PoiData -BaseUrl $BaseUrl -Type 'equips'

$fleetShipMap = Get-KcpsFleetShipMap -Fleets $fleets
$holderMap    = Get-KcpsEquipmentHolderMap -Ships $ships -Const $const

# 预解析所有装备实例 -> 名称/改修/持有者
$equipResolved = foreach ($entry in $equips.GetEnumerator()) {
    $eq = $entry.Value
    $key = [string]$eq['api_id']
    $held = $holderMap.ContainsKey($key)
    [pscustomobject]@{
        Id     = [int]$eq['api_id']
        Name   = Get-KcpsConstEquipName -Const $const -EquipConstId ([int]$eq['api_slotitem_id'])
        Level  = [int]$eq['api_level']
        Held   = $held
        Holder = $(if ($held) { $holderMap[$key].ShipName } else { $null })
    }
}

$equipSummary = foreach ($pat in $EquipPatterns) {
    $matched = @($equipResolved | Where-Object { $_.Name -match $pat })
    [pscustomobject]@{
        Pattern = $pat
        Count   = $matched.Count
        Free    = @($matched | Where-Object { -not $_.Held }).Count
        Names   = (@($matched | Select-Object -ExpandProperty Name -Unique | Sort-Object) -join ' | ')
        Items   = @($matched | Sort-Object Name, @{ Expression = 'Level'; Descending = $true } | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Lv = "★$($_.Level)"; Holder = $(if ($_.Holder) { $_.Holder } else { '(空闲)' }) }
        })
    }
}

# 预解析所有舰船实例 -> 名称/等级/所在舰队
$shipResolved = foreach ($entry in $ships.GetEnumerator()) {
    $sh = $entry.Value
    $key = [string]$sh['api_id']
    [pscustomobject]@{
        Id    = [int]$sh['api_id']
        Name  = Get-KcpsConstShipName -Const $const -ShipConstId ([int]$sh['api_ship_id'])
        Lv    = [int]$sh['api_lv']
        Fleet = $(if ($fleetShipMap.ContainsKey($key)) { $fleetShipMap[$key] } else { 0 })
    }
}

$shipSummary = foreach ($pat in $ShipPatterns) {
    $matched = @($shipResolved | Where-Object { $_.Name -match $pat })
    [pscustomobject]@{
        Pattern = $pat
        Count   = $matched.Count
        Ships   = @($matched | Sort-Object Name, @{ Expression = 'Lv'; Descending = $true } | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Id = $_.Id; Lv = $_.Lv; Fleet = $_.Fleet }
        })
    }
}

[pscustomobject]@{
    Timestamp = (Get-Date).ToString('s')
    Equips    = @($equipSummary)
    Ships     = @($shipSummary)
} | ConvertTo-KcpsJsonOutput -Depth 40
