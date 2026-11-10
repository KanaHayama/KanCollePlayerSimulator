#requires -Version 7.0
# Offline scan-boundary regression. All configurations and paths below are synthetic.
$ErrorActionPreference = 'Stop'
$script:checks = 0
function Assert-Scan([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw "Failed: $Label" }
    $script:checks++
}
function New-ScanFixture([string]$Path) {
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    $fixture = @{
        Name = '单次 出击 合成测试'
        List = @(@{
            Type = 'KancollePlayerSimulatorKai.MemoWorkflow, KancollePlayerSimulatorKai'
            Name = '说明'
            Memo = "合成测试`r`n"
        })
    }
    [IO.File]::WriteAllText($Path, ($fixture | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempParent ('kcps-config-scan-test-' + [guid]::NewGuid().ToString('N'))
$previousWorkspace = $env:KCPS_WORKSPACE
$previousSettings = $env:KCPS_SETTINGS_PATH
$previousRoutes = $env:KCPS_ROUTE_OVERRIDES
try {
    $workspace = Join-Path $testRoot 'private workspace'
    $skill = Join-Path $workspace 'renamed skill with spaces'
    $api = Join-Path $skill 'scripts\poi-kcps-api'
    $null = New-Item -ItemType Directory -Path (Join-Path $api 'normalize') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $api 'validate') -Force
    foreach ($name in @('KCPS-Common.ps1', 'KCPS-Connection.ps1', 'KCPS-RouteData.ps1', 'KCPS-RefitSlots.ps1', 'KCPS-CombinedFleet.ps1', 'KCPS-WorkflowReferences.ps1', 'KCPS-StagePolicies.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\$name") -Destination (Join-Path $api $name)
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\normalize\KCPS-NormalizeMemoParagraphs.ps1') -Destination (Join-Path $api 'normalize')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'KCPS-ValidateNaming.ps1') -Destination (Join-Path $api 'validate')
    $env:KCPS_WORKSPACE = $workspace
    $env:KCPS_SETTINGS_PATH = $null
    $env:KCPS_ROUTE_OVERRIDES = $null
    . (Join-Path $api 'KCPS-Connection.ps1')

    $fileName = '20260101 单次 出击 合成测试.conf.json'
    $userFiles = @(
        (Join-Path $workspace $fileName),
        (Join-Path $workspace "event folder\$fileName"),
        (Join-Path $workspace "renamed skill with spaces sibling\$fileName"),
        (Join-Path $workspace "tools\project\$fileName"),
        (Join-Path $workspace "templates\$fileName")
    )
    $excludedFiles = @(
        (Join-Path $skill $fileName),
        (Join-Path $skill "assets\templates\$fileName"),
        (Join-Path $skill "references\$fileName"),
        (Join-Path $skill "scripts\$fileName"),
        (Join-Path $workspace ".work\run\$fileName")
    )
    foreach ($path in @($userFiles) + @($excludedFiles)) { New-ScanFixture $path }
    $initialHashes = @{}
    foreach ($path in @($userFiles) + @($excludedFiles)) { $initialHashes[$path] = (Get-FileHash -LiteralPath $path).Hash }

    foreach ($path in $userFiles) {
        Assert-Scan (Test-KcpsConfigScanPath -Path $path -ScanRoot $workspace) 'Configuration selection does not depend on ordinary directory names'
    }
    foreach ($path in $excludedFiles) {
        Assert-Scan (-not (Test-KcpsConfigScanPath -Path $path -ScanRoot $workspace)) 'Skill resources and the workspace runtime directory are excluded'
    }
    Assert-Scan (-not (Test-KcpsConfigScanPath -Path $excludedFiles[1] -ScanRoot (Join-Path $skill 'assets'))) 'Scanning a Skill subdirectory still excludes Skill files'
    Assert-Scan (Test-KcpsConfigScanPath -Path $excludedFiles[4] -ScanRoot $workspace -IncludeWorkingFiles) 'Runtime-file opt-in is explicit'
    Assert-Scan (-not (Test-KcpsConfigScanPath -Path $excludedFiles[1] -ScanRoot $workspace -IncludeWorkingFiles)) 'Working-file opt-in never includes Skill templates'
    $unrelatedRoot = Join-Path $testRoot 'tools\unrelated workspace'
    Assert-Scan (Test-KcpsConfigScanPath -Path (Join-Path $unrelatedRoot $fileName) -ScanRoot $unrelatedRoot) 'An ancestor named tools does not exclude an unrelated workspace'
    foreach ($directoryName in @('tools', 'templates')) {
        $namedRoot = Join-Path $workspace $directoryName
        Assert-Scan (Test-KcpsConfigScanPath -Path (Join-Path $namedRoot $fileName) -ScanRoot $namedRoot) "A scan root named $directoryName is a valid user directory"
    }
    Assert-Scan (-not (Test-KcpsConfigScanPath -Path (Join-Path $testRoot $fileName) -ScanRoot $workspace)) 'Candidates outside the requested scan root are rejected'

    $naming = ( & (Join-Path $api 'validate\KCPS-ValidateNaming.ps1') -Path $workspace | Out-String ) | ConvertFrom-Json
    Assert-Scan ($naming.FileCount -eq $userFiles.Count) 'Naming scanner selects only user configurations'
    Assert-Scan ($naming.ProblemCount -eq 0) 'Synthetic user configurations pass naming checks'
    $normalizer = Join-Path $api 'normalize\KCPS-NormalizeMemoParagraphs.ps1'
    $preview = ( & $normalizer -Path $workspace -CheckOnly | Out-String ) | ConvertFrom-Json
    Assert-Scan ($preview.PathCount -eq $userFiles.Count -and $preview.Changes -eq $userFiles.Count) 'Normalization preview selects only user configurations'
    foreach ($path in @($userFiles) + @($excludedFiles)) {
        Assert-Scan ((Get-FileHash -LiteralPath $path).Hash -eq $initialHashes[$path]) 'Preview does not alter any configuration'
    }
    $result = ( & $normalizer -Path $workspace | Out-String ) | ConvertFrom-Json
    Assert-Scan ($result.PathCount -eq $userFiles.Count -and $result.Changes -eq $userFiles.Count) 'Normalization applies only to user configurations'
    foreach ($path in $userFiles) {
        Assert-Scan ((Get-FileHash -LiteralPath $path).Hash -ne $initialHashes[$path]) 'Selected user configuration is normalized'
    }
    foreach ($path in $excludedFiles) {
        Assert-Scan ((Get-FileHash -LiteralPath $path).Hash -eq $initialHashes[$path]) 'Skill resources and runtime files remain unchanged'
    }
    $explicit = ( & $normalizer -Path $excludedFiles[1] -CheckOnly | Out-String ) | ConvertFrom-Json
    Assert-Scan ($explicit.PathCount -eq 1) 'Explicit single-file inspection is preserved'
    $explicitPrivate = ( & (Join-Path $api 'validate\KCPS-ValidateNaming.ps1') -Path $excludedFiles[4] | Out-String ) | ConvertFrom-Json
    Assert-Scan ($explicitPrivate.FileCount -eq 1) 'An explicitly selected runtime file can be inspected'
    $dailyPath = Join-Path $workspace '20260101 日常 演习 合成每日任务.conf.json'
    $daily = @{ Name='日常 演习 合成每日任务'; List=@() }
    $daily | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $dailyPath -Encoding utf8
    $dailyReport = (& (Join-Path $api 'validate\KCPS-ValidateNaming.ps1') -Path $dailyPath | Out-String) | ConvertFrom-Json
    Assert-Scan ($dailyReport.ProblemCount -eq 0) 'Daily tasks are supported without a historical task list'
    $eventPath = Join-Path $workspace 'event folder\E8 P3 攻略.conf.json'
    $event = @{ Name='E8 P3 合成目标'; List=@(@{ Type='KancollePlayerSimulatorKai.SimpleSortieWorkflow, KancollePlayerSimulatorKai'; Sea=0; Area=8 }) }
    $event | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $eventPath -Encoding utf8
    $eventReport = (& (Join-Path $api 'validate\KCPS-ValidateNaming.ps1') -Path $eventPath | Out-String) | ConvertFrom-Json
    Assert-Scan ($eventReport.ProblemCount -eq 0) 'Event naming works in an arbitrary user directory'
    $event.List[0].Sea = 3
    $event | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $eventPath -Encoding utf8
    $normalReport = (& (Join-Path $api 'validate\KCPS-ValidateNaming.ps1') -Path $eventPath | Out-String) | ConvertFrom-Json
    Assert-Scan ($normalReport.ProblemCount -gt 0) 'An E-prefixed name alone cannot select event naming rules'
    $null = New-Item -ItemType Directory -Path (Join-Path $api 'data') -Force
    '{"Routes":[]}' | Set-Content -LiteralPath (Join-Path $api 'data\KCPS-RouteSpecs.json') -Encoding utf8
    $farmingPath = Join-Path $workspace 'event folder\合成跨海域捞船.conf.json'
    $farmingGroups = @(
        @{Name='E8 捞船 合成甲';List=@(@{Type='KancollePlayerSimulatorKai.SimpleSortieWorkflow, KancollePlayerSimulatorKai';Sea=0;Area=8})},
        @{Name='E9 捞船 合成乙';List=@(@{Type='KancollePlayerSimulatorKai.SimpleSortieWorkflow, KancollePlayerSimulatorKai';Sea=0;Area=9})}
    )
    $farmingGroups | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $farmingPath -Encoding utf8
    $farmingRoutes = @{Routes=@(
        @{Id='synthetic-farming-a';GroupNameRegex='^E8 捞船 合成甲$';StageDesign=@{Phase='Farming'}},
        @{Id='synthetic-farming-b';GroupNameRegex='^E9 捞船 合成乙$';StageDesign=@{Phase='Farming'}}
    )}
    $farmingRoutePath = Join-Path $workspace '.work\route-overrides.json'
    $farmingRoutes | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $farmingRoutePath -Encoding utf8
    $farmingReport = (& (Join-Path $api 'validate\KCPS-ValidateNaming.ps1') -Path $farmingPath | Out-String) | ConvertFrom-Json
    Assert-Scan ($farmingReport.ProblemCount -eq 0) 'Explicit farming plans permit a cross-map container'
    $farmingRoutes.Routes[1].StageDesign.Phase='Final'
    $farmingRoutes | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $farmingRoutePath -Encoding utf8
    $mixedReport = (& (Join-Path $api 'validate\KCPS-ValidateNaming.ps1') -Path $farmingPath | Out-String) | ConvertFrom-Json
    Assert-Scan ($mixedReport.ProblemCount -gt 0) 'A farming filename cannot bypass a declared non-farming phase'
    [pscustomobject]@{ Test = 'KCPS configuration scans (offline)'; Passed = $script:checks }
} finally {
    $env:KCPS_WORKSPACE = $previousWorkspace
    $env:KCPS_SETTINGS_PATH = $previousSettings
    $env:KCPS_ROUTE_OVERRIDES = $previousRoutes
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempParent = [IO.Path]::TrimEndingDirectorySeparator($tempParent)
    if (-not $resolvedTestRoot.StartsWith($resolvedTempParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedTestRoot) -notlike 'kcps-config-scan-test-*') {
        throw 'Refusing to remove a test directory outside the temporary directory.'
    }
    if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
}
