[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][string]$CandidateManifestPath,
    [Parameter(Mandatory)][string]$SimulatorRepository,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$SimulatorRevision = '',
    [switch]$ReuseBatch
)

. (Join-Path $PSScriptRoot 'KCPS-SortieAnalysisCommon.ps1')

function Remove-KcpsAnalysisMetadata {
    param($Value)

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($entry in $Value.GetEnumerator()) {
            if ($entry.Key -in @('kcps', 'instanceId')) {
                continue
            }
            $result[$entry.Key] = Remove-KcpsAnalysisMetadata -Value $entry.Value
        }
        return $result
    }
    if ($Value -is [System.Collections.IList]) {
        return @($Value | ForEach-Object { Remove-KcpsAnalysisMetadata -Value $_ })
    }
    return $Value
}

function Get-WilsonInterval {
    param(
        [Parameter(Mandatory)][long]$Successes,
        [Parameter(Mandatory)][long]$Trials,
        [double]$Z = 1.959963984540054
    )

    if ($Trials -le 0) {
        return [ordered]@{ Low = 0.0; High = 0.0 }
    }
    $p = $Successes / [double]$Trials
    $z2 = $Z * $Z
    $denominator = 1 + $z2 / $Trials
    $center = ($p + $z2 / (2 * $Trials)) / $denominator
    $radius = $Z * [math]::Sqrt(
        ($p * (1 - $p) / $Trials) + ($z2 / (4 * $Trials * $Trials))
    ) / $denominator
    return [ordered]@{
        Low = [math]::Max(0.0, [double]($center - $radius))
        High = [math]::Min(1.0, [double]($center + $radius))
    }
}

function Get-RankSuccessCount {
    param(
        [Parameter(Mandatory)]$Ranks,
        [Parameter(Mandatory)][string]$MinimumRank
    )

    switch ($MinimumRank) {
        'S' { return [long]$Ranks['S'] }
        'A' { return [long]$Ranks['S'] + [long]$Ranks['A'] }
        'B' { return [long]$Ranks['S'] + [long]$Ranks['A'] + [long]$Ranks['B'] }
        default { throw "Unsupported rank: $MinimumRank" }
    }
}

$request = Read-KcpsJsonHashtable -Path $RequestPath
Assert-KcpsAnalysisRequest -Request $request
$manifest = Read-KcpsJsonHashtable -Path $CandidateManifestPath
if ([int]$manifest['SchemaVersion'] -ne 2 -or $manifest['RequestSha256'] -ne (Get-KcpsSha256 -Text ($request | ConvertTo-Json -Depth 100 -Compress))) { throw '候选清单与当前版本2请求不一致；请重新生成候选。' }
Assert-KcpsPrivateOutputPath -Path $OutputDirectory
[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

$candidateDirectory = Split-Path -Parent $CandidateManifestPath
$scenarioByHash = [ordered]@{}
$hashByCandidateIndex = [ordered]@{}
$fileHashByCandidateIndex = [ordered]@{}
foreach ($candidate in $manifest['Candidates']) {
    $scenarioPath = Join-Path $candidateDirectory $candidate['File']
    $scenario = Read-KcpsJsonHashtable -Path $scenarioPath
    Assert-KcpsAnalysisAssumptions -Assumptions $candidate['Assumptions']
    if (($candidate['Assumptions'] | ConvertTo-Json -Depth 100 -Compress) -cne ($scenario['kcps']['assumptions'] | ConvertTo-Json -Depth 100 -Compress)) { throw '候选场景与清单的初始状态不一致。' }
    $fileHashByCandidateIndex[[string]$candidate['Index']] = (Get-FileHash -LiteralPath $scenarioPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($candidate['FileSha256'] -cne $fileHashByCandidateIndex[[string]$candidate['Index']]) { throw '候选场景在生成后被修改，请重新生成以保持输入状态与证据一致。' }
    $semanticScenario = Remove-KcpsAnalysisMetadata -Value $scenario
    $semanticJson = $semanticScenario | ConvertTo-Json -Depth 100 -Compress
    $hash = Get-KcpsSha256 -Text $semanticJson
    $hashByCandidateIndex[[string]$candidate['Index']] = $hash
    if (-not $scenarioByHash.Contains($hash)) {
        $scenarioByHash[$hash] = $scenarioPath
    }
}

$jobs = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $scenarioByHash.GetEnumerator()) {
    foreach ($seed in $request['Simulation']['Seeds']) {
        $jobs.Add([ordered]@{
            id = "$($entry.Key)-$seed"
            input = $entry.Value
            seed = [long]$seed
        })
    }
}
$jobsPath = Join-Path $OutputDirectory 'simulation.jobs.json'
Write-KcpsJson -Value $jobs -Path $jobsPath

$runner = Join-Path $PSScriptRoot 'runtime\KC3Kai-HeadlessRunner.js'
$batchPath = Join-Path $OutputDirectory 'simulation.batch.json'
if (-not ($ReuseBatch -and (Test-Path -LiteralPath $batchPath))) {
    & node $runner `
        --repo $SimulatorRepository `
        --jobs $jobsPath `
        --output $batchPath
    if ($LASTEXITCODE -ne 0) {
        throw "KC3Kai headless simulation failed with exit code $LASTEXITCODE"
    }
}

$batch = Read-KcpsJsonHashtable -Path $batchPath
$expectedJobs = @{}
foreach ($job in $jobs) { $expectedJobs[[string]$job['id']] = $job }
if (@($batch['results']).Count -ne $jobs.Count) { throw '模拟批次缺失或含额外结果，不能生成统计。' }
$seenJobs = @{}
$resultsByHash = [ordered]@{}
foreach ($jobResult in $batch['results']) {
    $jobId = [string]$jobResult['id']
    if (-not $expectedJobs.ContainsKey($jobId) -or $seenJobs.ContainsKey($jobId)) { throw '模拟批次任务标识不匹配或重复。' }
    $seenJobs[$jobId] = $true
    $job = $expectedJobs[$jobId]
    $inputDigest = (Get-FileHash -LiteralPath $job['input'] -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($jobResult['inputDigest'] -cne $inputDigest -or [long]$jobResult['seed'] -ne [long]$job['seed'] -or
        [long]$jobResult['simulations'] -ne [long]$request['Simulation']['NumSims']) { throw '模拟结果的输入指纹、种子或次数与当前请求不一致。' }
    $separator = [string]$jobResult['id']
    $hash = $separator.Substring(0, $separator.LastIndexOf('-'))
    if (-not $resultsByHash.Contains($hash)) {
        $resultsByHash[$hash] = [System.Collections.Generic.List[object]]::new()
    }
    $resultsByHash[$hash].Add($jobResult)
}

$targetNodeLabel = [string]$request['Goal']['TargetNode']
$targetNodeIndex = -1
for ($index = 0; $index -lt $request['BattleNodes'].Count; $index++) {
    if ([string]$request['BattleNodes'][$index]['Label'] -eq $targetNodeLabel) {
        $targetNodeIndex = $index
        break
    }
}
if ($targetNodeIndex -lt 0) {
    throw "Target node is not in BattleNodes: $targetNodeLabel"
}

$analysisEntries = [System.Collections.Generic.List[object]]::new()
foreach ($candidate in $manifest['Candidates']) {
    $hash = $hashByCandidateIndex[[string]$candidate['Index']]
    $jobResults = $resultsByHash[$hash]
    $trials = 0L
    $reached = 0L
    $successes = 0L
    $targetTaiha = 0L
    $nodeSummaries = @()
    $warnings = @($jobResults | ForEach-Object { $_['warnings'] } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)

    foreach ($jobResult in $jobResults) {
        $trials += [long]$jobResult['simulations']
        $targetNode = $jobResult['result']['nodes'][$targetNodeIndex]
        $reached += [long]$targetNode['num']
        $successes += Get-RankSuccessCount `
            -Ranks $targetNode['ranks'] `
            -MinimumRank ([string]$request['Goal']['MinimumRank'])
        $targetTaiha += [long]$targetNode['taiha']
    }
    if ($trials -le 0 -or $reached -lt 0 -or $reached -gt $trials -or $successes -lt 0 -or $successes -gt $reached) { throw '模拟计数不一致；未生成概率。' }

    for ($nodeIndex = 0; $nodeIndex -lt $request['BattleNodes'].Count; $nodeIndex++) {
        $nodeTrials = 0L
        $nodeS = 0L
        $nodeTaiha = 0L
        foreach ($jobResult in $jobResults) {
            $nodeResult = $jobResult['result']['nodes'][$nodeIndex]
            $nodeTrials += [long]$nodeResult['num']
            $nodeS += [long]$nodeResult['ranks']['S']
            $nodeTaiha += [long]$nodeResult['taiha']
        }
        $nodeSummaries += [ordered]@{
            Label = [string]$request['BattleNodes'][$nodeIndex]['Label']
            Reached = $nodeTrials
            S = $nodeS
            Taiha = $nodeTaiha
        }
    }

    $jointRate = if ($trials -gt 0) { $successes / [double]$trials } else { 0.0 }
    $reachRate = if ($trials -gt 0) { $reached / [double]$trials } else { 0.0 }
    $conditionalRate = if ($reached -gt 0) { $successes / [double]$reached } else { 0.0 }
    $requiredSuccesses = [int]$request['Goal']['RequiredSuccesses']
    $analysisEntries.Add([ordered]@{
        CandidateIndex = [int]$candidate['Index']
        SemanticHash = $hash
        BonusProfile = [string]$candidate['BonusProfile']
        BonusRole = [string]$candidate['BonusRole']
        Assumptions = $candidate['Assumptions']
        ScenarioFileSha256 = $fileHashByCandidateIndex[[string]$candidate['Index']]
        Reliable = $warnings.Count -eq 0
        UnavailableReason = if ($warnings.Count -gt 0) { '模拟器报告尚未解决的警告：' + ($warnings -join '；') } else { '' }
        ShipOrder = @($candidate['ShipOrder'])
        LoadoutOrder = @($candidate['LoadoutOrder'])
        Trials = $trials
        ReachedTarget = $reached
        TargetSuccesses = $successes
        JointSuccessRate = if ($warnings.Count -eq 0) { $jointRate } else { $null }
        JointSuccessWilson95 = if ($warnings.Count -eq 0) { Get-WilsonInterval -Successes $successes -Trials $trials } else { $null }
        ReachRate = if ($warnings.Count -eq 0) { $reachRate } else { $null }
        ConditionalSuccessRate = if ($warnings.Count -eq 0 -and $reached -gt 0) { $conditionalRate } else { $null }
        RetreatBeforeTargetRate = if ($warnings.Count -eq 0) { 1 - $reachRate } else { $null }
        TargetTaihaRate = if ($warnings.Count -eq 0 -and $reached -gt 0) { $targetTaiha / [double]$reached } else { $null }
        ProbabilityCompleteInMinimumSorties = if ($warnings.Count -eq 0 -and [bool]$request['Goal']['IndependentRepeatedSuccesses']) { [math]::Pow($jointRate, $requiredSuccesses) } else { $null }
        ExpectedSortiesForRequiredSuccesses = if ($warnings.Count -eq 0 -and [bool]$request['Goal']['IndependentRepeatedSuccesses'] -and $jointRate -gt 0) { $requiredSuccesses / $jointRate } else { $null }
        Nodes = $nodeSummaries
    })
}

$sorted = @(
    $analysisEntries | Sort-Object `
        @{ Expression = { if ($_.Reliable -and $_.BonusRole -eq 'Primary') { 0 } else { 1 } }; Ascending = $true }, `
        @{ Expression = 'JointSuccessRate'; Descending = $true }, `
        @{ Expression = 'TargetTaihaRate'; Ascending = $true }, `
        @{ Expression = 'CandidateIndex'; Ascending = $true }
)
$revision = $SimulatorRevision.Trim()
if ([string]::IsNullOrWhiteSpace($revision)) {
    $revision = (& git -C $SimulatorRepository rev-parse HEAD).Trim()
}
$analysis = [ordered]@{
    SchemaVersion = 2
    Kind = 'KcpsEventSortieCandidateAnalysis'
    GeneratedAtJst = Get-KcpsJapanTimestamp
    Request = $request
    Simulator = [ordered]@{
        Name = 'KC3Kai Sortie Simulator'
        Revision = $revision
        Repository = 'https://github.com/KC3Kai/kancolle-replay'
    }
    UniqueScenarioCount = $scenarioByHash.Count
    CandidateCount = $manifest['Candidates'].Count
    Entries = $sorted
}
$analysisPath = Join-Path $OutputDirectory 'analysis.json'
Write-KcpsJson -Value $analysis -Path $analysisPath

$csvPath = Join-Path $OutputDirectory 'analysis.csv'
$sorted | Select-Object `
    CandidateIndex,
    BonusProfile,
    Reliable,
    UnavailableReason,
    @{ Name = 'StateKind'; Expression = { $_.Assumptions.StateKind } },
    @{ Name = 'ShipOrder'; Expression = { $_.ShipOrder -join '-' } },
    @{ Name = 'LoadoutOrder'; Expression = { $_.LoadoutOrder -join ' | ' } },
    Trials,
    ReachedTarget,
    TargetSuccesses,
    JointSuccessRate,
    ReachRate,
    ConditionalSuccessRate,
    RetreatBeforeTargetRate,
    TargetTaihaRate,
    ProbabilityCompleteInMinimumSorties,
    ExpectedSortiesForRequiredSuccesses |
    Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

[pscustomobject]@{
    AnalysisPath = $analysisPath
    CsvPath = $csvPath
    CandidateCount = $manifest['Candidates'].Count
    UniqueScenarioCount = $scenarioByHash.Count
}
