#requires -Version 7.0
# Offline synthetic checks. Load only selected definitions, never runtime settings or game data.
$ErrorActionPreference = 'Stop'
$checks = 0
function Assert-Check([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw "Failed: $Label" }
    $script:checks++
}
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'KCPS-ValidateConfig.ps1'), [ref]$tokens, [ref]$parseErrors)
Assert-Check ($parseErrors.Count -eq 0) 'validator parses'
foreach ($name in @('Get-MemoQualityProblems', 'Get-JstNow', 'Get-KcpsHardcodedRuleFreshness')) {
    $node = $ast.Find({ param($item)
        $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name
    }, $true)
    Assert-Check ($null -ne $node) "definition exists: $name"
    . ([scriptblock]::Create($node.Extent.Text))
}
$registryNode = $ast.Find({ param($item)
    $item -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $item.Left.Extent.Text -eq '$hardcodedRuleRegistry'
}, $true)
Assert-Check ($null -ne $registryNode) 'registry definition exists'
. ([scriptblock]::Create($registryNode.Extent.Text))
Assert-Check ($hardcodedRuleRegistry.Count -eq 10) 'only implemented rule registrations remain'
Assert-Check (@($hardcodedRuleRegistry | Where-Object {
    $_.VerificationStatus -ne 'RequiresValidation' -or $null -ne $_.LastVerifiedJst
}).Count -eq 0) 'interface assumptions do not claim a verification date'
$metadata = Get-KcpsHardcodedRuleFreshness -Rules $hardcodedRuleRegistry
Assert-Check ($metadata.Rules.Count -eq 10 -and $metadata.Warnings.Count -eq 10) 'unverified contracts remain visible'
Assert-Check (@($metadata.Rules | Where-Object { $null -ne $_.AgeDays }).Count -eq 0) 'unknown verification age stays unknown'
$fresh = @{ Id='synthetic-current'; Scope='synthetic'; Source='synthetic'; LastVerifiedJst=(Get-JstNow).ToString('yyyy-MM-dd'); RefreshAfterDays=2; Risk='synthetic' }
$dated = Get-KcpsHardcodedRuleFreshness -Rules @($fresh)
Assert-Check ($dated.Warnings.Count -eq 0 -and $dated.Rules[0].VerificationStatus -eq 'DatedVerification') 'dated current verification remains supported'
$fresh.LastVerifiedJst = '2000-01-01'
$dated = Get-KcpsHardcodedRuleFreshness -Rules @($fresh)
Assert-Check ($dated.Warnings.Count -eq 1 -and $dated.Rules[0].AgeDays -gt 2) 'expired dated verification warns'

foreach ($memo in @(
    '本次只需A胜，在已核验的路线和资源预算内选择低消耗方案，不是纯火力最优。',
    '本次不是伤害最优方案；按明确的保留装备要求安排，满足当前目标。',
    '敌方火力较低且风险很低，仍使用已核验的节点和安全停止条件。'
)) {
    $result = @(Get-MemoQualityProblems -MemoWorkflows @(@{Name='合成说明';Memo=$memo}))
    Assert-Check ($result.Count -eq 0) 'explicit goal and resource tradeoffs are accepted'
}
foreach ($memo in @(
    '未验证节点 ID，先生成配置。',
    '使用默认boss策略。',
    '第1槽：烈風｜按目标舰种补足输出。'
)) {
    $result = @(Get-MemoQualityProblems -MemoWorkflows @(@{Name='合成说明';Memo=$memo}))
    Assert-Check ($result.Count -gt 0) 'unsupported evidence or equipment-role mismatch is rejected'
}
Write-Output "Passed $checks synthetic memo and registry checks."
