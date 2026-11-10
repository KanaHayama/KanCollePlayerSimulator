#requires -Version 7.0

param(
    [int[]]$ShipId,

    [string[]]$Name,

    [string]$BaseUrl = '',

    [ValidateSet('Table', 'Json')]
    [string]$Format = 'Table'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

$const = Get-PoiData -Type const -BaseUrl $BaseUrl
$ships = Get-PoiData -Type ships -BaseUrl $BaseUrl
$fleets = @(Get-PoiData -Type fleets -BaseUrl $BaseUrl)
$rows = @(Get-KcpsOwnedShipCopyAudit -Const $const -Ships $ships -Fleets $fleets)

if ($ShipId) {
    $ids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($id in $ShipId) { [void]$ids.Add($id) }
    $rows = @($rows | Where-Object { $ids.Contains([int]$_.Id) })
}
if ($Name) {
    $patterns = @($Name)
    $rows = @($rows | Where-Object {
        $row = $_
        $patterns | Where-Object { $row.Name -like "*$_*" -or $row.FamilyNames -like "*$_*" } | Select-Object -First 1
    })
}

if ($Format -eq 'Json') {
    $rows | ConvertTo-KcpsJsonOutput -Depth 8
} else {
    $rows | Select-Object Id, Name, CopyNo, Classification, Level, Cond, Hp, ExtraSlotAvailable, SallyArea, Fleet, Mission, FamilyNames |
        Format-Table -AutoSize
}
