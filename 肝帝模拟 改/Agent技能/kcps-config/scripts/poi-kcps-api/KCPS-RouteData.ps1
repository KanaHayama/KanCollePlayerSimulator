#requires -Version 7.0
. "$PSScriptRoot\KCPS-Connection.ps1"

function Merge-KcpsRouteValue {
    param([System.Collections.IDictionary]$Target, [System.Collections.IDictionary]$Overlay)
    foreach ($key in $Overlay.Keys) {
        if ($Target.Contains($key) -and $Target[$key] -is [System.Collections.IDictionary] -and $Overlay[$key] -is [System.Collections.IDictionary]) {
            Merge-KcpsRouteValue -Target $Target[$key] -Overlay $Overlay[$key]
        } else {
            $Target[$key] = $Overlay[$key]
        }
    }
}

function Get-KcpsRouteOverridesDocument {
    param([string]$OverridesPath)
    if (-not $OverridesPath) { $OverridesPath = $env:KCPS_ROUTE_OVERRIDES }
    if (-not $OverridesPath) {
        $settings = Get-KcpsLocalSettings
        if ($settings.Contains('RouteOverridesPath')) { $OverridesPath = [string]$settings['RouteOverridesPath'] }
        if (-not $OverridesPath) {
            $workspace = $env:KCPS_WORKSPACE
            if (-not $workspace -and $settings.Contains('WorkspaceRoot')) { $workspace = [string]$settings['WorkspaceRoot'] }
            if ($workspace) {
                $candidate = Join-Path $workspace '.work\route-overrides.json'
                Assert-KcpsPrivateOutputPath -Path $candidate
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $OverridesPath = $candidate }
            }
        }
    }
    if (-not $OverridesPath) { return $null }
    Assert-KcpsPrivateOutputPath -Path $OverridesPath
    if (-not (Test-Path -LiteralPath $OverridesPath -PathType Leaf)) { throw 'The configured private route-evidence file does not exist.' }
    $overlay = Get-Content -LiteralPath $OverridesPath -Raw | ConvertFrom-Json -AsHashtable
    if ($overlay -isnot [System.Collections.IDictionary]) { throw 'Private route evidence must be a JSON object.' }
    foreach ($key in @('Routes', 'EventBossStages', 'RouteBranchRules')) {
        if ($overlay.Contains($key) -and $overlay[$key] -isnot [System.Collections.IList]) { throw "$key in private route evidence must be an array." }
    }
    return $overlay
}

function Import-KcpsLandBaseRadiusEvidence {
    param([Parameter(Mandatory)][string]$Path, [string]$OverridesPath, [switch]$PublicOnly)
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($document -isnot [System.Collections.IDictionary] -or $document['Routes'] -isnot [System.Collections.IDictionary]) {
        throw 'Land-base radius evidence must contain a Routes object.'
    }
    if (-not $PublicOnly) {
        $overlay = Get-KcpsRouteOverridesDocument -OverridesPath $OverridesPath
        if ($overlay -and $overlay.Contains('LandBasedAirCorpsTargetRadii')) {
            $private = $overlay['LandBasedAirCorpsTargetRadii']
            if ($private -isnot [System.Collections.IDictionary] -or $private['Routes'] -isnot [System.Collections.IDictionary]) {
                throw 'LandBasedAirCorpsTargetRadii must contain a Routes object.'
            }
            foreach ($id in $private['Routes'].Keys) { $document['Routes'][$id] = $private['Routes'][$id] }
        }
    }
    return $document
}

function Import-KcpsRouteDatabase {
    param([Parameter(Mandatory)][string]$Path, [string]$OverridesPath, [switch]$PublicOnly)
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($document -isnot [System.Collections.IDictionary]) { throw 'Route data must be an object.' }
    $routes = [Collections.Generic.List[object]]::new()
    if ($document.Contains('Routes')) { foreach ($route in @($document['Routes'])) { $routes.Add($route) } }
    $byId = @{}
    foreach ($route in $routes) {
        $id = [string]$route['Id']
        if (-not $id -or $byId.ContainsKey($id)) { throw 'Public route IDs must be nonempty and unique.' }
        $byId[$id] = $route
    }
    if (-not $PublicOnly) {
        $overlay = Get-KcpsRouteOverridesDocument -OverridesPath $OverridesPath
        if ($null -ne $overlay) {
            foreach ($key in @('EventBossStages', 'RouteBranchRules')) {
                if ($overlay.Contains($key)) { $document[$key] = @($overlay[$key]) }
            }
            $seen = @{}
            foreach ($route in @($overlay['Routes'] | Where-Object { $null -ne $_ })) {
                $id = [string]$route['Id']
                if (-not $id -or $seen.ContainsKey($id)) { throw 'Private route IDs must be nonempty and unique.' }
                $seen[$id] = $true
                if ($byId.ContainsKey($id)) { Merge-KcpsRouteValue -Target $byId[$id] -Overlay $route }
                else { $byId[$id] = $route; $routes.Add($route) }
            }
            if ($overlay.Contains('DisabledRouteIds')) {
                foreach ($id in @($overlay['DisabledRouteIds'])) {
                    if ($byId.ContainsKey([string]$id)) { [void]$routes.Remove($byId[[string]$id]) }
                }
            }
        }
    }
    $document['Routes'] = @($routes.ToArray())
    return $document
}

function Resolve-KcpsRouteOverridesPath {
    param([string]$Path)
    if (-not $Path) { $Path = $env:KCPS_ROUTE_OVERRIDES }
    if (-not $Path) {
        $settings = Get-KcpsLocalSettings
        if ($settings.Contains('RouteOverridesPath')) { $Path = [string]$settings['RouteOverridesPath'] }
    }
    if (-not $Path) { $Path = Get-KcpsPrivatePath 'route-overrides.json' }
    Assert-KcpsPrivateOutputPath -Path $Path
    return [IO.Path]::GetFullPath($Path)
}

function Save-KcpsPrivateRoutePlans {
    param([Parameter(Mandatory)][object[]]$Routes, [string[]]$RemoveRouteIds = @(), [string]$Path)
    $Path = Resolve-KcpsRouteOverridesPath -Path $Path
    $document = if (Test-Path -LiteralPath $Path) {
        Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    } else { @{ SchemaVersion = 1; Routes = @() } }
    $updates = @{}
    foreach ($route in $Routes) {
        $copy = ConvertTo-Json -InputObject $route -Depth 100 | ConvertFrom-Json -AsHashtable
        $id = [string]$copy['Id']
        if (-not $id -or $updates.ContainsKey($id)) { throw 'Private route update IDs must be nonempty and unique.' }
        $updates[$id] = $copy
    }
    $result = [Collections.Generic.List[object]]::new()
    foreach ($route in @($document['Routes'] | Where-Object { $null -ne $_ })) {
        $id = [string]$route['Id']
        if ($updates.ContainsKey($id)) { $result.Add($updates[$id]); $updates.Remove($id) }
        elseif ($id -notin $RemoveRouteIds) { $result.Add($route) }
    }
    foreach ($route in $Routes) {
        if ($updates.ContainsKey([string]$route['Id'])) { $result.Add($updates[[string]$route['Id']]) }
    }
    $document['Routes'] = @($result.ToArray())
    $activeIds = @($Routes | ForEach-Object { [string]$_['Id'] })
    $disabled = if ($document.Contains('DisabledRouteIds')) { @($document['DisabledRouteIds']) } else { @() }
    $document['DisabledRouteIds'] = @(($disabled + $RemoveRouteIds) | Where-Object { $_ -notin $activeIds } | Sort-Object -Unique)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    ConvertTo-Json -InputObject $document -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8
    return $Path
}
