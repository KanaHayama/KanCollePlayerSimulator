#requires -Version 7.0

$script:KcpsSkillRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

function Resolve-KcpsFileSystemPath {
    param([Parameter(Mandatory)][string]$Path)
    # Explicit relative arguments retain normal CLI semantics.
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-KcpsConfigScanPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ScanRoot,
        [switch]$IncludeWorkingFiles
    )
    $full = Resolve-KcpsFileSystemPath -Path $Path
    $root = Resolve-KcpsFileSystemPath -Path $ScanRoot
    if ($full -eq $script:KcpsSkillRoot -or
        $full.StartsWith($script:KcpsSkillRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $relative = [IO.Path]::GetRelativePath($root, $full)
    if ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative -match '^\.\.[\\/]') { return $false }
    # The selected workspace's runtime directory is excluded unless requested.
    $directories = @((Split-Path -Leaf $root)) + @(([IO.Path]::GetDirectoryName($relative)) -split '[\\/]')
    if (-not $IncludeWorkingFiles -and '.work' -in $directories) { return $false }
    return $true
}

function Get-KcpsLocalSettings {
    param([string]$SettingsPath = $env:KCPS_SETTINGS_PATH)
    $selectedWorkspace = $null
    if (-not $SettingsPath) {
        if (-not $env:KCPS_WORKSPACE) { return @{} }
        $selectedWorkspace = Resolve-KcpsFileSystemPath -Path $env:KCPS_WORKSPACE
        $SettingsPath = Join-Path $selectedWorkspace '.work\kcps.local.json'
        Assert-KcpsPrivateOutputPath -Path $SettingsPath
        # An explicitly selected workspace never falls back to another workspace.
        if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) { return @{} }
    }
    $SettingsPath = Resolve-KcpsFileSystemPath -Path $SettingsPath
    Assert-KcpsPrivateOutputPath -Path $SettingsPath
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        throw 'KCPS local settings file does not exist. Check KCPS_SETTINGS_PATH or KCPS_WORKSPACE.'
    }
    $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json -AsHashtable
    if ($settings -isnot [System.Collections.IDictionary]) { throw 'KCPS local settings must be a JSON object.' }
    $parent = Split-Path -Parent $SettingsPath
    foreach ($key in @('WorkspaceRoot', 'InstallationRoot', 'RuntimeConfigPath', 'DefaultConfigPath', 'RouteOverridesPath')) {
        if ($settings.Contains($key) -and $settings[$key]) {
            $settings[$key] = [IO.Path]::GetFullPath([string]$settings[$key], $parent)
        }
    }
    if ($selectedWorkspace -and -not $settings['WorkspaceRoot']) {
        $settings['WorkspaceRoot'] = $selectedWorkspace
    }
    return $settings
}

function Get-KcpsConnection {
    param([string]$BaseUrl, [int]$Port = 0, [object]$Token = $null, [string]$RuntimeConfigPath)
    $settings = Get-KcpsLocalSettings
    $runtime = @{}
    if (-not $RuntimeConfigPath -and $settings.Contains('RuntimeConfigPath')) { $RuntimeConfigPath = $settings['RuntimeConfigPath'] }
    if ($RuntimeConfigPath) {
        $runtime = Get-Content -LiteralPath $RuntimeConfigPath -Raw | ConvertFrom-Json -AsHashtable
        if ($runtime -isnot [System.Collections.IDictionary]) { throw 'KCPS runtime config must be a JSON object.' }
    }
    if (-not $BaseUrl) { $BaseUrl = $env:KCPS_BASE_URL }
    if (-not $BaseUrl -and $settings.Contains('BaseUrl')) { $BaseUrl = [string]$settings['BaseUrl'] }
    if (-not $BaseUrl) {
        $runtimePort = if ($runtime.Contains('Port')) { [int]$runtime['Port'] } else { 5277 }
        $BaseUrl = "http://127.0.0.1:$runtimePort"
    }
    $uri = $null
    if (-not [uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') {
        throw 'KCPS BaseUrl must be an HTTP(S) origin without credentials, query, fragment or path.'
    }
    $builder = [UriBuilder]::new($uri)
    if ($Port -lt 0 -or $Port -gt 65535) { throw 'KCPS port must be between 1 and 65535, or 0 to use settings.' }
    if ($Port -gt 0) { $builder.Port = $Port }
    if ($null -eq $Token) {
        if ($env:KCPS_TOKEN) { $Token = $env:KCPS_TOKEN }
        elseif ($settings.Contains('Token')) { $Token = $settings['Token'] }
        elseif ($runtime.Contains('Token')) { $Token = $runtime['Token'] }
        else { $Token = '' }
    }
    return @{ BaseUrl = $builder.Uri.GetLeftPart([UriPartial]::Authority); Token = [string]$Token }
}

function Invoke-KcpsPoiRequest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$BaseUrl, [int]$Port = 0, [object]$Token = $null,
        [string]$RuntimeConfigPath, [switch]$AsHashtable,
        [int]$TimeoutSec = 30
    )
    if (-not $Path.StartsWith('/') -or $Path.StartsWith('//') -or $Path.Contains('\') -or $Path.Contains('#')) {
        throw 'KCPS API paths must be relative paths beginning with one slash.'
    }
    $connection = Get-KcpsConnection -BaseUrl $BaseUrl -Port $Port -Token $Token -RuntimeConfigPath $RuntimeConfigPath
    $builder = [UriBuilder]::new($connection.BaseUrl + $Path)
    if ($connection.Token) {
        $query = $builder.Query.TrimStart('?')
        if ($query) { $query += '&' }
        $builder.Query = $query + 'token=' + [uri]::EscapeDataString($connection.Token)
    }
    try {
        $response = Invoke-WebRequest -Uri $builder.Uri -TimeoutSec $TimeoutSec -ErrorAction Stop
    } catch {
        # Do not propagate exception URLs: older plugin versions authenticate in the query string.
        $responseProperty = $_.Exception.PSObject.Properties['Response']
        $status = if ($responseProperty -and $responseProperty.Value) { [int]$responseProperty.Value.StatusCode } else { 0 }
        throw "KCPS API request failed (HTTP status $status). Check connection settings and authentication."
    }
    return ConvertFrom-Json -InputObject $response.Content -AsHashtable:$AsHashtable -NoEnumerate
}

function Resolve-KcpsDefaultConfigPath {
    param([string]$Path)
    if ($Path) { return $Path }
    $settings = Get-KcpsLocalSettings
    if ($settings.Contains('DefaultConfigPath') -and $settings['DefaultConfigPath']) { return [string]$settings['DefaultConfigPath'] }
    if ($settings.Contains('InstallationRoot') -and $settings['InstallationRoot']) { return Join-Path $settings['InstallationRoot'] 'default.json' }
    throw 'Specify -DefaultPath, or set InstallationRoot/DefaultConfigPath in private KCPS settings.'
}

function Get-KcpsPrivatePath {
    param([Parameter(Mandatory)][string]$RelativePath)
    $settings = Get-KcpsLocalSettings
    $workspace = $env:KCPS_WORKSPACE
    if (-not $workspace -and $settings.Contains('WorkspaceRoot')) { $workspace = [string]$settings['WorkspaceRoot'] }
    if (-not $workspace) { throw 'Set KCPS_WORKSPACE or WorkspaceRoot in private settings before writing account data.' }
    $workspace = Resolve-KcpsFileSystemPath -Path $workspace
    $privateRoot = [IO.Path]::GetFullPath((Join-Path $workspace '.work'))
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw 'Private output must use a relative path inside the workspace .work directory.'
    }
    $path = [IO.Path]::GetFullPath($RelativePath, $privateRoot)
    if (-not $path.StartsWith($privateRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Private output must stay inside the workspace .work directory.'
    }
    Assert-KcpsPrivateOutputPath -Path $path
    return $path
}

function Assert-KcpsPrivateOutputPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = Resolve-KcpsFileSystemPath -Path $Path
    $root = $script:KcpsSkillRoot
    if ($full -eq $root -or $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Account settings and output must stay outside the public skill directory.'
    }
}
