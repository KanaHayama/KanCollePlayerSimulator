[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Map,
    [Parameter(Mandatory)][string[]]$Nodes,
    [Parameter(Mandatory)][int]$Difficulty,
    [string[]]$RouteEdges = @(),
    [Parameter(Mandatory)][string]$OutputDirectory
)

. (Join-Path $PSScriptRoot 'KCPS-SortieAnalysisCommon.ps1')

[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$requests = [System.Collections.Generic.List[object]]::new()
foreach ($node in $Nodes) {
    $requests.Add([ordered]@{
        Name = "$Map-$node-d$Difficulty-enemycomps"
        Url = "https://tsunkit.net/api/routing/maps/$Map/nodes/$node/enemycomps?difficulty=$Difficulty"
    })
}
if ($RouteEdges.Count -gt 0) {
    $edgeText = $RouteEdges -join ','
    $requests.Add([ordered]@{
        Name = "$Map-route-$($RouteEdges -join '-')"
        Url = "https://tsunkit.net/api/routing/maps/$Map/edges/$edgeText"
    })
    $requests.Add([ordered]@{
        Name = "$Map-route-$($RouteEdges -join '-')-comps-d$Difficulty"
        Url = "https://tsunkit.net/api/routing/maps/$Map/edges/$edgeText/comps?difficulty=$Difficulty"
    })
}

$manifest = [ordered]@{
    SchemaVersion = 1
    RetrievedAtJst = Get-KcpsJapanTimestamp
    Map = $Map
    Difficulty = $Difficulty
    Entries = [System.Collections.Generic.List[object]]::new()
}

foreach ($request in $requests) {
    $response = Invoke-RestMethod -Uri $request.Url
    $dataJson = $response | ConvertTo-Json -Depth 100 -Compress
    $snapshot = [ordered]@{
        SchemaVersion = 1
        Source = 'KCNav'
        Url = $request.Url
        RetrievedAtJst = Get-KcpsJapanTimestamp
        Sha256 = Get-KcpsSha256 -Text $dataJson
        Data = $response
    }
    $fileName = "$($request.Name).json"
    $filePath = Join-Path $OutputDirectory $fileName
    Write-KcpsJson -Value $snapshot -Path $filePath
    $manifest.Entries.Add([ordered]@{
        Name = $request.Name
        File = $fileName
        Url = $request.Url
        Sha256 = $snapshot.Sha256
    })
}

$manifestPath = Join-Path $OutputDirectory 'sources.manifest.json'
Write-KcpsJson -Value $manifest -Path $manifestPath
$manifest
