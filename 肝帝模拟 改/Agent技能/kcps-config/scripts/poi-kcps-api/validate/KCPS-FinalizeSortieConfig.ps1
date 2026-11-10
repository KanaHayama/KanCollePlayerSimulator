[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [string]$BaseUrl = '',
    [string]$SnapshotPath,
    [string]$SortieChainPolicyPath,
    [switch]$CheckOnly,
    [switch]$SkipQuestValidation,
    [switch]$AllowNotReady
)

$ErrorActionPreference = 'Stop'

function Invoke-JsonTool {
    param(
        [string]$Script,
        [hashtable]$Arguments
    )

    $raw = (& $Script @Arguments | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Tool returned no JSON: $Script"
    }
    try {
        return ($raw | ConvertFrom-Json -AsHashtable)
    } catch {
        throw "Tool returned invalid JSON: $Script`n$raw"
    }
}

function Get-IntegerValue {
    param(
        [hashtable]$Map,
        [string]$Key
    )

    if ($null -eq $Map -or -not $Map.ContainsKey($Key) -or $null -eq $Map[$Key]) { return 0 }
    return [int]$Map[$Key]
}

$resolved = Resolve-Path -LiteralPath $Path
if ((Get-Item -LiteralPath $resolved).PSIsContainer) {
    throw 'Finalize one .conf.json file at a time so task ID and route results remain unambiguous.'
}

$toolRoot = Split-Path -Parent $PSScriptRoot
$scripts = [ordered]@{
    Collections = Join-Path $toolRoot 'normalize\KCPS-NormalizeRelatedWorkflowCollections.ps1'
    MemoParagraphs = Join-Path $toolRoot 'normalize\KCPS-NormalizeMemoParagraphs.ps1'
    HistoricalBossNames = Join-Path $toolRoot 'normalize\KCPS-NormalizeEventHistoricalBossNames.ps1'
    WorkflowOrder = Join-Path $toolRoot 'normalize\KCPS-NormalizeWorkflowOrder.ps1'
    SortieStrategies = Join-Path $toolRoot 'normalize\KCPS-NormalizeSortieStrategyRules.ps1'
    SupportDestroyerRefit = Join-Path $toolRoot 'normalize\KCPS-NormalizeSupportDestroyerRefit.ps1'
    FixedEventRefitTargets = Join-Path $toolRoot 'normalize\KCPS-NormalizeFixedEventRefitTargets.ps1'
    ShipRotation = Join-Path $toolRoot 'enable\KCPS-EnableEquivalentShipRotation.ps1'
    BucketDocking = Join-Path $toolRoot 'enable\KCPS-EnablePostSortieBucketDocking.ps1'
    LandBaseRest = Join-Path $toolRoot 'enable\KCPS-EnablePostSortieLandBaseRest.ps1'
    ConfigValidation = Join-Path $PSScriptRoot 'KCPS-ValidateConfig.ps1'
    EventValidation = Join-Path $PSScriptRoot 'KCPS-ValidateEventSortieConfig.ps1'
    QuestValidation = Join-Path $PSScriptRoot 'KCPS-ValidateQuestIds.ps1'
    NamingValidation = Join-Path $PSScriptRoot 'KCPS-ValidateNaming.ps1'
}

foreach ($entry in $scripts.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
        throw "Required tool is missing: $($entry.Value)"
    }
}

$applySteps = @(
    @{ Script = $scripts.Collections; Arguments = @{ Path = [string]$resolved } },
    @{ Script = $scripts.MemoParagraphs; Arguments = @{ Path = [string]$resolved } },
    @{ Script = $scripts.HistoricalBossNames; Arguments = @{ Path = [string]$resolved } },
    @{ Script = $scripts.WorkflowOrder; Arguments = @{ Path = [string]$resolved } },
    @{ Script = $scripts.SortieStrategies; Arguments = @{ Path = [string]$resolved } },
    @{ Script = $scripts.SupportDestroyerRefit; Arguments = @{ Path = [string]$resolved } },
    @{ Script = $scripts.FixedEventRefitTargets; Arguments = @{ Path = [string]$resolved } },
    @{ Script = $scripts.ShipRotation; Arguments = @{ Path = [string]$resolved; BaseUrl = $BaseUrl; SnapshotPath = $SnapshotPath } },
    @{ Script = $scripts.LandBaseRest; Arguments = @{ Path = [string]$resolved } },
    @{ Script = $scripts.BucketDocking; Arguments = @{ Path = [string]$resolved } }
)

if (-not $CheckOnly) {
    foreach ($step in $applySteps) {
        $null = Invoke-JsonTool -Script $step.Script -Arguments $step.Arguments
    }
}

$collections = Invoke-JsonTool -Script $scripts.Collections -Arguments @{ Path = [string]$resolved; CheckOnly = $true }
$memoParagraphs = Invoke-JsonTool -Script $scripts.MemoParagraphs -Arguments @{ Path = [string]$resolved; CheckOnly = $true }
$historicalBossNames = @(Invoke-JsonTool -Script $scripts.HistoricalBossNames -Arguments @{ Path = [string]$resolved; CheckOnly = $true })
$workflowOrder = Invoke-JsonTool -Script $scripts.WorkflowOrder -Arguments @{ Path = [string]$resolved; CheckOnly = $true }
$sortieStrategies = Invoke-JsonTool -Script $scripts.SortieStrategies -Arguments @{ Path = [string]$resolved; CheckOnly = $true }
$supportDestroyerRefit = Invoke-JsonTool -Script $scripts.SupportDestroyerRefit -Arguments @{ Path = [string]$resolved; CheckOnly = $true }
$fixedEventRefitTargets = Invoke-JsonTool -Script $scripts.FixedEventRefitTargets -Arguments @{ Path = [string]$resolved; CheckOnly = $true }
$shipRotation = Invoke-JsonTool -Script $scripts.ShipRotation -Arguments @{ Path = [string]$resolved; BaseUrl = $BaseUrl; SnapshotPath = $SnapshotPath; CheckOnly = $true }
$bucketDocking = Invoke-JsonTool -Script $scripts.BucketDocking -Arguments @{ Path = [string]$resolved; CheckOnly = $true }
$landBaseRest = Invoke-JsonTool -Script $scripts.LandBaseRest -Arguments @{ Path = [string]$resolved; CheckOnly = $true }

$configValidationArgs = @{ Path = [string]$resolved; BaseUrl = $BaseUrl; SnapshotPath = $SnapshotPath; RequireRouteSpec = $true }
if (-not [string]::IsNullOrWhiteSpace($SortieChainPolicyPath)) {
    $configValidationArgs.SortieChainPolicyPath = $SortieChainPolicyPath
}
$configValidation = Invoke-JsonTool -Script $scripts.ConfigValidation -Arguments $configValidationArgs
$parsedConfig = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json -AsHashtable
$isEventSortie = @(
    foreach ($group in @($parsedConfig)) {
        foreach ($workflow in @($group['List'])) {
            if ([string]$workflow['Type'] -like '*SimpleSortieWorkflow*' -and [int]$workflow['Sea'] -eq 0) {
                $workflow
            }
        }
    }
).Count -gt 0
$hasQuestWorkflow = @(
    foreach ($group in @($parsedConfig)) {
        foreach ($workflow in @($group['List'])) {
            if ([string]$workflow['Type'] -like '*BasicAcceptQuestWorkflow*') {
                $workflow
            }
        }
    }
).Count -gt 0
$eventValidation = if ($isEventSortie) {
    @(Invoke-JsonTool -Script $scripts.EventValidation -Arguments @{
        Path = [string]$resolved
        BaseUrl = $BaseUrl
        SnapshotPath = $SnapshotPath
        NoThrow = $true
    })
} else {
    @()
}
$namingValidation = Invoke-JsonTool -Script $scripts.NamingValidation -Arguments @{ Path = @([string]$resolved) }
$questValidation = [ordered]@{ ProblemCount = 0; Problems = @(); Entries = @() }
if ($hasQuestWorkflow -and -not $SkipQuestValidation) {
    $questValidation = Invoke-JsonTool -Script $scripts.QuestValidation -Arguments @{ Path = @([string]$resolved); BaseUrl = $BaseUrl }
}

$strategyPending = if ($sortieStrategies.ContainsKey('WouldChange') -and [bool]$sortieStrategies['WouldChange']) {
    [math]::Max(1, @($sortieStrategies['Reports']).Count)
} else {
    0
}

$checks = @(
    [ordered]@{ Name = 'Collections'; PendingChanges = Get-IntegerValue $collections 'WouldFix' },
    [ordered]@{ Name = 'MemoParagraphs'; PendingChanges = Get-IntegerValue $memoParagraphs 'Changes' },
    [ordered]@{ Name = 'HistoricalBossNames'; PendingChanges = @($historicalBossNames | Where-Object { [bool]$_['WouldChange'] }).Count },
    [ordered]@{ Name = 'WorkflowOrder'; PendingChanges = Get-IntegerValue $workflowOrder 'Changes' },
    [ordered]@{ Name = 'SortieStrategies'; PendingChanges = $strategyPending },
    [ordered]@{ Name = 'SupportDestroyerRefit'; PendingChanges = Get-IntegerValue $supportDestroyerRefit 'Changes' },
    [ordered]@{ Name = 'FixedEventRefitTargets'; PendingChanges = Get-IntegerValue $fixedEventRefitTargets 'Changes' },
    [ordered]@{ Name = 'EquivalentShipRotation'; PendingChanges = Get-IntegerValue $shipRotation 'Updates' },
    [ordered]@{ Name = 'PostSortieBucketDocking'; PendingChanges = Get-IntegerValue $bucketDocking 'Changes' },
    [ordered]@{ Name = 'PostSortieLandBaseRest'; PendingChanges = Get-IntegerValue $landBaseRest 'Changes' }
)

$pendingChangeCount = 0
foreach ($check in $checks) {
    $pendingChangeCount += [int]$check['PendingChanges']
}
$configProblemCount = Get-IntegerValue $configValidation 'ProblemCount'
$eventProblemCount = @(
    foreach ($group in @($eventValidation)) {
        foreach ($problem in @($group['Problems'])) {
            if ($problem) { $problem }
        }
    }
).Count
$namingProblemCount = Get-IntegerValue $namingValidation 'ProblemCount'
$questProblemCount = if ($SkipQuestValidation) { 0 } else { Get-IntegerValue $questValidation 'ProblemCount' }
$questReady = if ($hasQuestWorkflow) {
    -not $SkipQuestValidation -and $questProblemCount -eq 0
} else {
    $true
}
$ready = $pendingChangeCount -eq 0 -and $configProblemCount -eq 0 -and $eventProblemCount -eq 0 -and $namingProblemCount -eq 0 -and $questReady

$configProblems = @(
    foreach ($problem in @($configValidation['FileProblems'])) {
        if ($problem) { [ordered]@{ Config = $null; Problem = [string]$problem } }
    }
    foreach ($group in @($configValidation['Groups'])) {
        foreach ($problem in @($group['Problems'])) {
            if ($problem) {
                [ordered]@{ Config = [string]$group['Name']; Problem = [string]$problem }
            }
        }
    }
)
$questProblems = if ($SkipQuestValidation) {
    @('Skipped by explicit request; do not use this mode for a new task config.')
} else {
    @($questValidation['Problems'])
}
$eventProblems = @(
    foreach ($group in @($eventValidation)) {
        foreach ($problem in @($group['Problems'])) {
            if ($problem) {
                [ordered]@{ Config = [string]$group['Group']; Problem = [string]$problem }
            }
        }
    }
)

$finalizeResult = [ordered]@{
    Path = [string]$resolved
    Mode = if ($CheckOnly) { 'CheckOnly' } else { 'ApplyThenCheck' }
    Ready = $ready
    PendingChangeCount = $pendingChangeCount
    ConfigProblemCount = $configProblemCount
    SortieChainProblemCount = @($configValidation['SortieChainProblems']).Count
    EventValidationApplied = $isEventSortie
    EventProblemCount = $eventProblemCount
    NamingProblemCount = $namingProblemCount
    QuestProblemCount = $questProblemCount
    QuestValidationApplied = ($hasQuestWorkflow -and -not $SkipQuestValidation)
    QuestValidationSkipped = [bool]$SkipQuestValidation
    HardcodedRuleFreshnessWarningCount = @($configValidation['HardcodedRuleFreshnessWarnings']).Count
    RouteSpecFreshnessWarningCount = @($configValidation['RouteSpecFreshnessWarnings']).Count
    Checks = $checks
    ConfigProblems = @($configProblems)
    SortieChainCheck = $configValidation['SortieChainCheck']
    EventProblems = @($eventProblems)
    NamingProblems = @($namingValidation['Files'] | ForEach-Object { $_['Problems'] } | Where-Object { $_ })
    QuestProblems = @($questProblems)
}

$finalizeResult | ConvertTo-Json -Depth 8

if (-not $ready -and -not $AllowNotReady) {
    throw "KCPS sortie finalization failed: PendingChanges=$pendingChangeCount; ConfigProblems=$configProblemCount; EventProblems=$eventProblemCount; NamingProblems=$namingProblemCount; QuestProblems=$questProblemCount; Path=$resolved"
}
