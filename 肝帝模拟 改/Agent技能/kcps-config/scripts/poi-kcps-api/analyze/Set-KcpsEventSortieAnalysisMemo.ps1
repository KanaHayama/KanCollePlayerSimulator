[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$AnalysisResultPath,
    [string]$DecisionText,
    [string]$BackupPath,
    [hashtable]$MemoReplacements = @{}
)

. (Join-Path $PSScriptRoot 'KCPS-SortieAnalysisCommon.ps1')

$formatter = Join-Path $PSScriptRoot 'KCPS-FormatSortieProbabilityMemo.ps1'
$probabilityMemo = (& $formatter -Path $AnalysisResultPath -MemoOnly) -join [Environment]::NewLine
$config = Read-KcpsJsonHashtable -Path $ConfigPath
$memoWorkflow = @($config['List'] | Where-Object { [string]$_['Name'] -eq '备注' })[0]
if ($null -eq $memoWorkflow) {
    throw "Memo workflow was not found in $ConfigPath"
}

$memo = [string]$memoWorkflow['Memo']
foreach ($key in $MemoReplacements.Keys) {
    $memo = $memo.Replace([string]$key, [string]$MemoReplacements[$key])
}
$memo = [regex]::Replace(
    $memo,
    '(?s)\r?\n【候选模拟】.*$',
    ''
)
$memo = [regex]::Replace(
    $memo,
    '(?s)\r?\n【出击概率分析】.*$',
    ''
)
if (-not [string]::IsNullOrWhiteSpace($DecisionText)) {
    $memo += [Environment]::NewLine + [Environment]::NewLine +
        '【候选模拟】' + [Environment]::NewLine +
        $DecisionText.Trim()
}
$memo += [Environment]::NewLine + [Environment]::NewLine + $probabilityMemo.Trim()
$memoWorkflow['Memo'] = $memo

if (-not [string]::IsNullOrWhiteSpace($BackupPath)) {
    Assert-KcpsPrivateOutputPath -Path $BackupPath
    $backupParent = Split-Path -Parent $BackupPath
    if ($backupParent) {
        [System.IO.Directory]::CreateDirectory($backupParent) | Out-Null
    }
    Copy-Item -LiteralPath $ConfigPath -Destination $BackupPath -Force
}
Write-KcpsJson -Value $config -Path $ConfigPath

[pscustomobject]@{
    ConfigPath = $ConfigPath
    BackupPath = $BackupPath
    MemoLength = $memo.Length
}
