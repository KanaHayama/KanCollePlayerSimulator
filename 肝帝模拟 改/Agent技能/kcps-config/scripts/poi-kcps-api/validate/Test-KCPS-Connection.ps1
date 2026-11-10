#requires -Version 7.0
# Offline fixtures only: this test never reads existing account settings or calls an API.
$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\KCPS-Connection.ps1'))
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempParent ('kcps-connection-test-' + [guid]::NewGuid().ToString('N'))
$previousLocation = Get-Location
$previousSettings = $env:KCPS_SETTINGS_PATH
$previousWorkspace = $env:KCPS_WORKSPACE
$script:checks = 0

function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -ne $Expected) { throw "Failed: $Label" }
    $script:checks++
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Label) {
    $message = $null
    try { $null = & $Action } catch { $message = $_.Exception.Message }
    if (-not $message -or $message -notmatch $Pattern) { throw "Failed: $Label" }
    $script:checks++
}

function Write-FixtureSettings([string]$Path, [hashtable]$Settings) {
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    [IO.File]::WriteAllText($Path, ($Settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}

function Copy-FixtureSkill([string]$Workspace) {
    $skill = Join-Path $Workspace 'kcps-config'
    $scripts = Join-Path $skill 'scripts\poi-kcps-api'
    $null = New-Item -ItemType Directory -Path $scripts -Force
    Copy-Item -LiteralPath $source -Destination (Join-Path $scripts 'KCPS-Connection.ps1')
    [IO.File]::WriteAllText((Join-Path $skill 'SKILL.md'), "---`nname: fixture`n---`n")
    return $skill
}

try {
    $env:KCPS_SETTINGS_PATH = $null
    $env:KCPS_WORKSPACE = $null
    $workspaceA = Join-Path $testRoot 'workspace-a'
    $workspaceB = Join-Path $testRoot 'independent-install'
    $workspaceExplicit = Join-Path $testRoot 'explicit-workspace'
    $workspaceEmpty = Join-Path $testRoot 'empty-workspace'
    $skillA = Copy-FixtureSkill $workspaceA
    $skillB = Copy-FixtureSkill $workspaceB
    $fixtureSettings = Join-Path $workspaceA '.work\kcps.local.json'
    Write-FixtureSettings $fixtureSettings @{
        Marker = 'synthetic-selected'
        InstallationRoot = '..\installation'
        RuntimeConfigPath = 'runtime.json'
        DefaultConfigPath = '..\config.json'
        RouteOverridesPath = 'route-overrides.json'
    }
    Write-FixtureSettings (Join-Path $skillA '.work\kcps.local.json') @{ Marker = 'synthetic-forbidden' }
    Write-FixtureSettings (Join-Path $skillB '.work\kcps.local.json') @{ Marker = 'synthetic-forbidden' }
    $workspaceSettings = Join-Path $workspaceExplicit '.work\kcps.local.json'
    Write-FixtureSettings $workspaceSettings @{ Marker = 'synthetic-workspace'; WorkspaceRoot = '..' }
    $explicitSettings = Join-Path $testRoot 'explicit-settings\kcps.local.json'
    Write-FixtureSettings $explicitSettings @{ Marker = 'synthetic-explicit'; WorkspaceRoot = '..\explicit-data' }
    $null = New-Item -ItemType Directory -Path $workspaceEmpty -Force
    Set-Location -LiteralPath $workspaceEmpty

    . (Join-Path $skillA 'scripts\poi-kcps-api\KCPS-Connection.ps1')
    Assert-Equal $script:KcpsSkillRoot $skillA 'Skill root is based on the copied script location'
    Assert-Equal (Get-KcpsLocalSettings).Count 0 'Unselected neighboring settings are ignored'
    Assert-Throws { Get-KcpsPrivatePath 'analysis\snapshot.json' } 'Set KCPS_WORKSPACE' 'Unselected neighboring settings cannot supply an output workspace'
    $fixtureJson = Get-Content -LiteralPath $fixtureSettings -Raw
    [IO.File]::WriteAllText($fixtureSettings, 'INVALID SYNTHETIC JSON')
    Assert-Equal (Get-KcpsLocalSettings).Count 0 'Malformed neighboring bait is never read'
    Set-Location -LiteralPath $workspaceA
    Assert-Equal (Get-KcpsLocalSettings).Count 0 'Current-directory settings are not implicitly selected'
    [IO.File]::WriteAllText($fixtureSettings, $fixtureJson)
    $settings = Get-KcpsLocalSettings -SettingsPath $fixtureSettings
    Assert-Equal $settings.Marker 'synthetic-selected' 'An explicit path can select the same fixture'
    Assert-Equal $settings.InstallationRoot (Join-Path $workspaceA 'installation') 'Relative installation path is based on the selected settings file'
    Assert-Equal $settings.RuntimeConfigPath (Join-Path $workspaceA '.work\runtime.json') 'Relative runtime path is based on the selected settings file'
    Assert-Equal $settings.DefaultConfigPath (Join-Path $workspaceA 'config.json') 'Relative config path is based on the selected settings file'
    Assert-Equal $settings.RouteOverridesPath (Join-Path $workspaceA '.work\route-overrides.json') 'Relative route path is based on the selected settings file'
    $env:KCPS_SETTINGS_PATH = $fixtureSettings
    Assert-Throws { Get-KcpsPrivatePath 'snapshot.json' } 'Set KCPS_WORKSPACE' 'Selecting settings without WorkspaceRoot does not select its parent directory'
    $env:KCPS_SETTINGS_PATH = $null
    $env:KCPS_WORKSPACE = $workspaceA
    Assert-Equal (Get-KcpsLocalSettings).WorkspaceRoot $workspaceA 'An explicitly selected workspace supplies its own output root'
    Assert-Equal (Get-KcpsPrivatePath 'analysis\snapshot.json') (Join-Path $workspaceA '.work\analysis\snapshot.json') 'Selected workspace runtime convention controls output'
    $env:KCPS_WORKSPACE = $workspaceExplicit
    Assert-Equal (Get-KcpsLocalSettings).Marker 'synthetic-workspace' 'An explicit workspace selects only its own settings'
    $env:KCPS_SETTINGS_PATH = $explicitSettings
    Assert-Equal (Get-KcpsLocalSettings).Marker 'synthetic-explicit' 'Explicit settings win over the explicit workspace'
    Assert-Equal (Get-KcpsLocalSettings -SettingsPath $fixtureSettings).Marker 'synthetic-selected' 'Explicit settings argument wins over the environment'
    Assert-Equal (Get-KcpsPrivatePath 'snapshot.json') (Join-Path $workspaceExplicit '.work\snapshot.json') 'Explicit workspace controls output even with a separate settings file'

    $env:KCPS_SETTINGS_PATH = Join-Path $testRoot 'absent-settings.json'
    Assert-Throws { Get-KcpsLocalSettings } 'settings file does not exist' 'Missing explicit settings fail instead of using a fallback'
    $env:KCPS_SETTINGS_PATH = $null
    $env:KCPS_WORKSPACE = $workspaceEmpty
    Assert-Equal (Get-KcpsLocalSettings).Count 0 'A selected workspace without settings stays empty'
    Assert-Equal (Get-KcpsPrivatePath 'snapshot.json') (Join-Path $workspaceEmpty '.work\snapshot.json') 'An explicit empty workspace can still receive private output'

    $env:KCPS_WORKSPACE = $null
    foreach ($relative in @('', 'SKILL.md', '.work\snapshot.json', 'references\snapshot.json', 'assets\templates\snapshot.json', 'scripts\snapshot.json')) {
        $output = if ($relative) { Join-Path $skillA $relative } else { $skillA }
        Assert-Throws { Assert-KcpsPrivateOutputPath $output } 'outside the public skill directory' 'Every part of the Skill is protected'
    }
    Assert-Throws { Assert-KcpsPrivateOutputPath (Join-Path $workspaceA 'kcps-config\scripts\..\snapshot.json') } 'outside the public skill directory' 'Path normalization cannot bypass Skill protection'
    Assert-KcpsPrivateOutputPath (Join-Path $workspaceA '.work\snapshot.json')
    $script:checks++
    Assert-KcpsPrivateOutputPath (Join-Path ($skillA + '-sibling') 'snapshot.json')
    $script:checks++
    $env:KCPS_WORKSPACE = $workspaceExplicit
    Assert-Throws { Get-KcpsPrivatePath '..\escaped.json' } 'inside the workspace .work directory' 'Parent traversal outside private output is rejected'
    Assert-Throws { Get-KcpsPrivatePath '.' } 'inside the workspace .work directory' 'The private output directory itself is rejected'
    Assert-Throws { Get-KcpsPrivatePath (Join-Path $testRoot 'absolute.json') } 'relative path inside' 'Rooted paths cannot replace the private output root'

    Set-Location -LiteralPath $testRoot
    Assert-Throws { Assert-KcpsPrivateOutputPath 'workspace-a\kcps-config\assets\snapshot.json' } 'outside the public skill directory' 'Relative CLI output is checked against the current PowerShell directory'
    Assert-KcpsPrivateOutputPath 'workspace-a\.work\snapshot.json'
    $script:checks++
    $env:KCPS_SETTINGS_PATH = 'explicit-settings\kcps.local.json'
    Assert-Equal (Get-KcpsLocalSettings).Marker 'synthetic-explicit' 'Explicit relative settings retain CLI semantics'
    $env:KCPS_SETTINGS_PATH = Join-Path $skillA '.work\kcps.local.json'
    Assert-Throws { Get-KcpsLocalSettings } 'outside the public skill directory' 'Explicit settings cannot be loaded from inside the Skill'
    $env:KCPS_SETTINGS_PATH = $null
    $env:KCPS_WORKSPACE = $skillA
    Assert-Throws { Get-KcpsLocalSettings } 'outside the public skill directory' 'A Skill cannot serve as its own private workspace'

    $env:KCPS_WORKSPACE = $null
    . (Join-Path $skillB 'scripts\poi-kcps-api\KCPS-Connection.ps1')
    Assert-Equal $script:KcpsSkillRoot $skillB 'A second independent installation finds its own Skill root'
    Assert-Equal (Get-KcpsLocalSettings).Count 0 'An unconfigured installation does not load any neighboring or internal settings'
    Assert-Throws { Get-KcpsPrivatePath 'snapshot.json' } 'Set KCPS_WORKSPACE' 'A standalone Skill without a workspace cannot create account output'
    $env:KCPS_WORKSPACE = $workspaceExplicit
    Assert-Equal (Get-KcpsLocalSettings).Marker 'synthetic-workspace' 'An independent installation supports an explicit external workspace'
    Assert-Throws { Assert-KcpsPrivateOutputPath (Join-Path $skillB 'references\snapshot.json') } 'outside the public skill directory' 'An independently installed Skill remains fully protected'
    [pscustomobject]@{ Test = 'KCPS connection and private paths (offline)'; Passed = $script:checks }
} finally {
    $env:KCPS_SETTINGS_PATH = $previousSettings
    $env:KCPS_WORKSPACE = $previousWorkspace
    Set-Location -LiteralPath $previousLocation.Path
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempParent = [IO.Path]::TrimEndingDirectorySeparator($tempParent)
    if (-not $resolvedTestRoot.StartsWith($resolvedTempParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedTestRoot) -notlike 'kcps-connection-test-*') {
        throw 'Refusing to remove a test directory outside the temporary directory.'
    }
    if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
}
