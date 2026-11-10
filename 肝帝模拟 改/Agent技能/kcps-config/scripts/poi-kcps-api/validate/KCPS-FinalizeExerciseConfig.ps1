#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [string]$BaseUrl = '',
    [switch]$CheckOnly,
    [switch]$SkipQuestValidation
)

$ErrorActionPreference = 'Stop'

function Invoke-JsonTool {
    param([string]$Script, [hashtable]$Arguments)
    $raw = (& $Script @Arguments | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "Tool returned no JSON: $Script" }
    try { return ($raw | ConvertFrom-Json -AsHashtable) }
    catch { throw "Tool returned invalid JSON: $Script`n$raw" }
}

function Get-IntegerValue {
    param([hashtable]$Map, [string]$Key)
    if ($null -eq $Map -or -not $Map.ContainsKey($Key) -or $null -eq $Map[$Key]) { return 0 }
    return [int]$Map[$Key]
}

$resolved = Resolve-Path -LiteralPath $Path
if ((Get-Item -LiteralPath $resolved).PSIsContainer) {
    throw 'Finalize one exercise .conf.json file at a time.'
}

$toolRoot = Split-Path -Parent $PSScriptRoot
$scripts = [ordered]@{
    Collections = Join-Path $toolRoot 'normalize\KCPS-NormalizeRelatedWorkflowCollections.ps1'
    WorkflowOrder = Join-Path $toolRoot 'normalize\KCPS-NormalizeWorkflowOrder.ps1'
    ConfigValidation = Join-Path $PSScriptRoot 'KCPS-ValidateConfig.ps1'
    ExerciseValidation = Join-Path $PSScriptRoot 'KCPS-ValidateExerciseConfig.ps1'
    QuestValidation = Join-Path $PSScriptRoot 'KCPS-ValidateQuestIds.ps1'
    FitAudit = Join-Path $toolRoot 'inspect\KCPS-AuditFit.ps1'
    NamingValidation = Join-Path $PSScriptRoot 'KCPS-ValidateNaming.ps1'
}
foreach ($entry in $scripts.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
        throw "Required shared tool is missing: $($entry.Value)"
    }
}

if (-not $CheckOnly) {
    $null = Invoke-JsonTool -Script $scripts.Collections -Arguments @{ Path = @([string]$resolved) }
    $null = Invoke-JsonTool -Script $scripts.WorkflowOrder -Arguments @{ Path = [string]$resolved }
}

$collections = Invoke-JsonTool -Script $scripts.Collections -Arguments @{ Path = @([string]$resolved); CheckOnly = $true }
$workflowOrder = Invoke-JsonTool -Script $scripts.WorkflowOrder -Arguments @{ Path = [string]$resolved; CheckOnly = $true }
$configValidation = Invoke-JsonTool -Script $scripts.ConfigValidation -Arguments @{ Path = [string]$resolved; BaseUrl = $BaseUrl }
$exerciseValidation = Invoke-JsonTool -Script $scripts.ExerciseValidation -Arguments @{ Path = [string]$resolved }
$namingValidation = Invoke-JsonTool -Script $scripts.NamingValidation -Arguments @{ Path = @([string]$resolved) }
$fitAudit = Invoke-JsonTool -Script $scripts.FitAudit -Arguments @{ Path = [string]$resolved }
$questValidation = $null
if (-not $SkipQuestValidation) {
    $questValidation = Invoke-JsonTool -Script $scripts.QuestValidation -Arguments @{ Path = @([string]$resolved); BaseUrl = $BaseUrl }
}

$checks = @(
    [ordered]@{ Name = 'Collections'; PendingChanges = Get-IntegerValue $collections 'WouldFix' },
    [ordered]@{ Name = 'WorkflowOrder'; PendingChanges = Get-IntegerValue $workflowOrder 'Changes' }
)
$pendingChangeCount = 0
foreach ($check in $checks) { $pendingChangeCount += [int]$check['PendingChanges'] }

$configProblemCount = Get-IntegerValue $configValidation 'ProblemCount'
$exerciseProblemCount = Get-IntegerValue $exerciseValidation 'ProblemCount'
$namingProblemCount = Get-IntegerValue $namingValidation 'ProblemCount'
$fitIssueCount = Get-IntegerValue $fitAudit 'IssueCount'
$questProblemCount = if ($SkipQuestValidation) { 0 } else { Get-IntegerValue $questValidation 'ProblemCount' }
$ready = $pendingChangeCount -eq 0 -and $configProblemCount -eq 0 -and $exerciseProblemCount -eq 0 -and $namingProblemCount -eq 0 -and $fitIssueCount -eq 0 -and $questProblemCount -eq 0 -and -not $SkipQuestValidation

[ordered]@{
    Path = [string]$resolved
    Mode = if ($CheckOnly) { 'CheckOnly' } else { 'ApplyThenCheck' }
    Ready = $ready
    PendingChangeCount = $pendingChangeCount
    ConfigProblemCount = $configProblemCount
    ExerciseProblemCount = $exerciseProblemCount
    NamingProblemCount = $namingProblemCount
    FitIssueCount = $fitIssueCount
    QuestProblemCount = $questProblemCount
    HardcodedRuleFreshnessWarningCount = Get-IntegerValue $exerciseValidation 'HardcodedRuleFreshnessWarningCount'
    HardcodedRuleFreshnessWarnings = @($exerciseValidation['HardcodedRuleFreshnessWarnings'])
    QuestValidationSkipped = [bool]$SkipQuestValidation
    Checks = $checks
    ConfigProblems = @($configValidation['Groups'] | ForEach-Object { $_['Problems'] } | Where-Object { $_ })
    ExerciseProblems = @($exerciseValidation['Configs'] | ForEach-Object { $_['Problems'] } | Where-Object { $_ })
    NamingProblems = @($namingValidation['Files'] | ForEach-Object { $_['Problems'] } | Where-Object { $_ })
    FitIssues = @($fitAudit['Ships'] | ForEach-Object { $_['Issues'] } | Where-Object { $_ })
    QuestProblems = if ($SkipQuestValidation) { @('Skipped; new task configs must not be delivered in this mode.') } else { @($questValidation['Problems']) }
} | ConvertTo-Json -Depth 10
