[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AnalysisPath,
    [Parameter(Mandatory)][int]$CandidateIndex,
    [Parameter(Mandatory)][string]$SourcesManifestPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ConfirmationBatchPath,
    [string]$ConfirmationCasePrefix
)
. (Join-Path $PSScriptRoot 'KCPS-SortieAnalysisCommon.ps1')
$analysis = Read-KcpsJsonHashtable -Path $AnalysisPath
if ([int]$analysis['SchemaVersion'] -ne 2) { throw '分析导出要求版本2；旧分析未记录实际初始状态，不能补写为满状态。' }
Assert-KcpsAnalysisRequest -Request $analysis['Request']
$entries = @($analysis['Entries'] | Where-Object { [int]$_['CandidateIndex'] -eq $CandidateIndex })
if ($entries.Count -ne 1) { throw '候选不存在或不唯一。' }
$entry = $entries[0]
Assert-KcpsAnalysisAssumptions -Assumptions $entry['Assumptions']
$goal = $analysis['Request']['Goal']
$minimumRank = [string]$goal['MinimumRank']
$runs = [long]$entry['Trials']
$reached = [long]$entry['ReachedTarget']
$successes = [long]$entry['TargetSuccesses']
$seedCount = @($analysis['Request']['Simulation']['Seeds']).Count
$reliable = [bool]$entry['Reliable']
$unavailable = [string]$entry['UnavailableReason']
if ($ConfirmationBatchPath -or $ConfirmationCasePrefix) {
    if (-not $ConfirmationBatchPath -or -not $ConfirmationCasePrefix) { throw '复核批次路径与案例前缀必须同时提供。' }
    $confirmation = Read-KcpsJsonHashtable -Path $ConfirmationBatchPath
    $matching = @($confirmation['results'] | Where-Object { [string]$_['id'] -like "$ConfirmationCasePrefix-*" })
    if ($matching.Count -eq 0) { throw '未找到复核案例。' }
    $targetLabels = @($analysis['Request']['BattleNodes'] | ForEach-Object { $_['Label'] })
    $targetIndex = $targetLabels.IndexOf([string]$goal['TargetNode'])
    $runs = 0L; $reached = 0L; $successes = 0L
    $seenSeeds = @{}
    foreach ($row in $matching) {
        if ($row['inputDigest'] -cne $entry['ScenarioFileSha256'] -or $seenSeeds.ContainsKey([string]$row['seed'])) { throw '复核输入指纹不匹配或种子重复，不能替换原统计。' }
        $seenSeeds[[string]$row['seed']] = $true
        $runs += [long]$row['simulations']
        $node = $row['result']['nodes'][$targetIndex]
        $reached += [long]$node['num']
        $successes += [long]$node['ranks']['S']
        if ($minimumRank -in @('A','B')) { $successes += [long]$node['ranks']['A'] }
        if ($minimumRank -eq 'B') { $successes += [long]$node['ranks']['B'] }
        if (@($row['warnings']).Count -gt 0) { $reliable = $false; $unavailable = '复核模拟器仍有未解决警告。' }
    }
    $seedCount = $seenSeeds.Count
}
if ($runs -le 0 -or $reached -lt 0 -or $reached -gt $runs -or $successes -lt 0 -or $successes -gt $reached) { throw '分析计数无效，不能导出概率。' }
$sourcesManifest = Read-KcpsJsonHashtable -Path $SourcesManifestPath
$sources = [Collections.Generic.List[object]]::new()
foreach ($source in @($sourcesManifest['Entries'])) {
    $sources.Add([ordered]@{ Kind='KCNav'; Url=[string]$source['Url']; RetrievedAt=[string]$sourcesManifest['RetrievedAtJst']; ContentHash=[string]$source['Sha256']; Confidence='B' })
}
if ($analysis['Request'].Contains('ResearchSources')) {
    foreach ($source in @($analysis['Request']['ResearchSources'])) {
        $sources.Add([ordered]@{ Kind=[string]$source['Kind']; Url=[string]$source['Url']; RetrievedAt=[string]$source['RetrievedAtJst']; ContentHash=(Get-KcpsSha256 -Text ([string]$source['ContentFingerprint'])); Confidence=[string]$source['Confidence'] })
    }
}
$profile = @($analysis['Request']['BonusProfiles'] | Where-Object { $_['Name'] -eq $entry['BonusProfile'] })[0]
$sources.Add([ordered]@{ Kind='EventBonus'; Url=[string]$profile['Source']; RetrievedAt=([string]$profile['LastVerifiedJst'] + 'T00:00:00+09:00'); ContentHash=(Get-KcpsSha256 -Text ($profile | ConvertTo-Json -Depth 30 -Compress)); Confidence='B' })
$jointRate = $successes / [double]$runs
$reachRate = $reached / [double]$runs
$required = [int]$goal['RequiredSuccesses']
$independent = [bool]$goal['IndependentRepeatedSuccesses']
$metrics = [ordered]@{}
if ($reliable) {
    $metrics['TargetReachRate'] = $reachRate
    $metrics['RetreatRate'] = 1 - $reachRate
    if ($reached -gt 0) { $metrics["Rank$($minimumRank)$(if ($minimumRank -ne 'S') {'OrBetter'})Rate"] = $successes / [double]$reached }
    $metrics['JointTargetSuccessRate'] = $jointRate
    if ($independent) {
        $metrics['AllRequiredSuccessesInMinimumSortiesRate'] = [math]::Pow($jointRate, $required)
        if ($jointRate -gt 0) { $metrics['ExpectedSorties'] = $required / $jointRate }
    }
}
$uncertainties = @('显示熟练度模型不等于精确内部熟练度；实际内部值未建模', '模拟器公式与游戏实装可能存在差异', '敌编成权重来自所提供的观测样本')
if (-not $independent) { $uncertainties += '未假定跨航次独立同分布，未估算累计目标完成次数。' }
if ($successes -eq 0) { $uncertainties += '样本中未观察到成功不等于目标不可能；不输出零次或有限预计完成次数。' }
$result = [ordered]@{
    SchemaVersion=2
    AnalysisId="$($analysis['Request']['Map'])-$($goal['TargetNode'])-$CandidateIndex"
    GeneratedAt=Get-KcpsJapanTimestamp
    Simulator=[ordered]@{ Name=$analysis['Simulator']['Name']; SourceUrl=$analysis['Simulator']['Repository']; Revision=$analysis['Simulator']['Revision'] }
    Sources=$sources
    Assumptions=$entry['Assumptions']
    Stages=@([ordered]@{
        Key="$($analysis['Request']['Map'])-$($goal['TargetNode'])"
        Label="$($goal['TargetNode'])点$minimumRank 胜以上"
        Goal="$($goal['TargetNode'])点$minimumRank 胜以上累计 $required 次"
        Reliable=$reliable; UnavailableReason=$unavailable
        Runs=$runs; Successes=$successes; SeedCount=$seedCount
        RequiredSuccessCount=$required; IndependentRepeatedSuccesses=$independent
        Metrics=$metrics; ModelConfidence='B'; Uncertainties=$uncertainties
    })
}
Write-KcpsJson -Value $result -Path $OutputPath
$result

