Set-StrictMode -Version Latest
. "$PSScriptRoot\..\KCPS-Connection.ps1"
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\KCPS-AnalysisContract.ps1"

function Read-KcpsJsonHashtable {
    param([Parameter(Mandatory)][string]$Path)

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
}

function Write-KcpsJson {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path,
        [int]$Depth = 100
    )

    Assert-KcpsPrivateOutputPath -Path $Path
    $parent = Split-Path -Parent $Path
    if ($parent) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth $Depth
    [System.IO.File]::WriteAllText(
        $Path,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-KcpsPoiPort {
    param([string]$RuntimeConfigPath)
    $connection = Get-KcpsConnection -RuntimeConfigPath $RuntimeConfigPath
    return ([uri]$connection.BaseUrl).Port
}

function Get-KcpsPoiData {
    param([Parameter(Mandatory)][string]$Type, [int]$Port = 0, [string]$RuntimeConfigPath)
    Invoke-KcpsPoiRequest -Path ("/data?type=" + [uri]::EscapeDataString($Type)) -Port $Port -RuntimeConfigPath $RuntimeConfigPath
}

function Get-KcpsJapanTimestamp {
    $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById('Tokyo Standard Time')
    $offset = $zone.GetUtcOffset([datetime]::UtcNow)
    return [datetimeoffset]::new(
        [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $zone),
        $offset
    ).ToString('yyyy-MM-ddTHH:mm:sszzz')
}

function Get-KcpsSha256 {
    param([Parameter(Mandatory)][string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [System.Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-KcpsPropertyValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Object -is [System.Collections.IDictionary]) {
        return $Object[$Name]
    }
    return $Object.PSObject.Properties[$Name].Value
}
