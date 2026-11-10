[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [int]$Port = 0,
    [string]$RuntimeConfigPath = ''
)

. (Join-Path $PSScriptRoot 'KCPS-SortieAnalysisCommon.ps1')

if ($Port -le 0) {
    $Port = Get-KcpsPoiPort -RuntimeConfigPath $RuntimeConfigPath
}

$snapshot = [ordered]@{
    SchemaVersion = 1
    Kind = 'KcpsEventSortieAccountSnapshot'
    RetrievedAtJst = Get-KcpsJapanTimestamp
    PoiPort = $Port
    Ships = Get-KcpsPoiData -Type 'ships' -Port $Port -RuntimeConfigPath $RuntimeConfigPath
    Equips = Get-KcpsPoiData -Type 'equips' -Port $Port -RuntimeConfigPath $RuntimeConfigPath
    Fleets = Get-KcpsPoiData -Type 'fleets' -Port $Port -RuntimeConfigPath $RuntimeConfigPath
    Constants = Get-KcpsPoiData -Type 'const' -Port $Port -RuntimeConfigPath $RuntimeConfigPath
}

Write-KcpsJson -Value $snapshot -Path $OutputPath
[pscustomobject]@{
    OutputPath = $OutputPath
    RetrievedAtJst = $snapshot.RetrievedAtJst
    ShipCount = @($snapshot.Ships.PSObject.Properties).Count
    EquipmentCount = @($snapshot.Equips.PSObject.Properties).Count
}
