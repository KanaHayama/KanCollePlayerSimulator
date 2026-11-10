#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [switch]$RemoveSource
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

function Get-EventStageKey {
    param([string]$Name)

    $match = [regex]::Match($Name, '^(?<stage>E\d+\s+P\d+)\b')
    if (-not $match.Success) { return $null }
    return $match.Groups['stage'].Value
}

$sourceFiles = @(
    foreach ($inputPath in $Path) {
        $item = Get-Item -LiteralPath (Resolve-Path -LiteralPath $inputPath)
        if ($item.PSIsContainer) {
            throw "Source path must be a KCPS config file, not a directory: $($item.FullName)"
        }
        $item
    }
)

if ($sourceFiles.Count -eq 0) { throw 'At least one source config is required.' }

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputFileName = [System.IO.Path]::GetFileName($resolvedOutputPath)
$outputNameMatch = [regex]::Match(
    $outputFileName,
    '^(?<stage>E\d+\s+P\d+)\s+(?:开路(?:\s+第[一二三四五六七八九十]+阶段)?|攻略)\.conf\.json$'
)
if (-not $outputNameMatch.Success) {
    throw 'Event stage container name must be "E# P# 开路[ 第#阶段].conf.json" or "E# P# 攻略.conf.json".'
}

$groups = [System.Collections.Generic.List[object]]::new()
$sourceOrder = 0
foreach ($sourceFile in $sourceFiles) {
    if ([System.IO.Path]::GetFullPath($sourceFile.FullName) -eq $resolvedOutputPath) {
        throw "Output path must not also be a source path: $resolvedOutputPath"
    }
    $config = Read-KcpsJson -Path $sourceFile.FullName
    foreach ($group in @(Get-KcpsGroups -Config $config)) {
        if (-not $group.ContainsKey('Name') -or -not $group.ContainsKey('List')) {
            throw "Invalid KCPS config group in $($sourceFile.FullName)."
        }
        $groups.Add($group)
        $sourceOrder++
    }
}

if ($outputFileName -match '\s攻略\.conf\.json$') {
    $orderedGroups = @(
        for ($index = 0; $index -lt $groups.Count; $index++) {
            $group = $groups[$index]
            $name = [string]$group['Name']
            $priority = if ($name -match '\s磨血\s') {
                100
            } elseif ($name -match '\s削甲\s') {
                200
            } elseif ($name -match '\s半自动斩杀\s') {
                400
            } elseif ($name -match '\s(?:全自动斩杀|斩杀|击破)\s') {
                300
            } else {
                150
            }
            [pscustomobject]@{ Priority = $priority; Index = $index; Group = $group }
        }
    ) | Sort-Object Priority, Index | ForEach-Object Group
    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($group in $orderedGroups) { $groups.Add($group) }
}

$duplicateNames = @($groups | Group-Object { [string]$_['Name'] } | Where-Object Count -gt 1)
if ($duplicateNames.Count -gt 0) {
    throw "Duplicate config name(s): $(@($duplicateNames.Name) -join ' | ')"
}

$groupStages = @($groups | ForEach-Object { Get-EventStageKey -Name ([string]$_['Name']) } | Sort-Object -Unique)
if ($groupStages.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$groupStages[0])) {
    throw "All configs in one event stage file must belong to one E# P# stage; found: $($groupStages -join ', ')"
}
if ($groupStages[0] -ne $outputNameMatch.Groups['stage'].Value) {
    throw "Output stage $($outputNameMatch.Groups['stage'].Value) does not match config stage $($groupStages[0])."
}

$guidRows = @(
    foreach ($group in $groups) {
        foreach ($workflow in @($group['List'])) {
            if (-not $workflow.ContainsKey('Guid')) { continue }
            [pscustomobject]@{
                Guid = [string]$workflow['Guid']
                Group = [string]$group['Name']
                Workflow = [string]$workflow['Name']
            }
        }
    }
)
$duplicateGuids = @($guidRows | Group-Object Guid | Where-Object Count -gt 1)
if ($duplicateGuids.Count -gt 0) {
    $details = @($duplicateGuids | ForEach-Object {
        "Guid=$($_.Name): " + (@($_.Group | ForEach-Object { "$($_.Group)/$($_.Workflow)" }) -join ' | ')
    })
    throw "Duplicate workflow GUID(s) found. Regenerate the affected config instead of silently remapping references.`n$($details -join "`n")"
}

$outputDirectory = [System.IO.Path]::GetDirectoryName($resolvedOutputPath)
[System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
$temporaryPath = Join-Path $outputDirectory ('.' + [System.IO.Path]::GetFileNameWithoutExtension($resolvedOutputPath) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
    # 合并只改变顶层容器，不规范化或重写内部配置字段。
    $json = ConvertTo-Json -InputObject ([object[]]$groups.ToArray()) -Depth 100
    [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
    $roundTrip = Read-KcpsJson -Path $temporaryPath
    $roundTripGroups = @(Get-KcpsGroups -Config $roundTrip)
    if ($roundTripGroups.Count -ne $groups.Count) {
        throw "Round-trip group count mismatch: expected $($groups.Count), got $($roundTripGroups.Count)."
    }
    [System.IO.File]::Move($temporaryPath, $resolvedOutputPath, $true)
} finally {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
}

if ($RemoveSource) {
    foreach ($sourceFile in $sourceFiles) {
        Remove-Item -LiteralPath $sourceFile.FullName -Force
    }
}

[pscustomobject]@{
    OutputPath = $resolvedOutputPath
    SourceFileCount = $sourceFiles.Count
    ConfigCount = $groups.Count
    WorkflowCount = $guidRows.Count
    RemovedSource = [bool]$RemoveSource
    ConfigNames = @($groups | ForEach-Object { [string]$_['Name'] })
} | ConvertTo-KcpsJsonOutput -Depth 8
