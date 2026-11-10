#requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

function Format-KcpsMemoParagraphs {
    param([AllowEmptyString()][string]$Memo)

    if ([string]::IsNullOrEmpty($Memo)) { return $Memo }

    $lines = @(($Memo -replace "`r`n?", "`n") -split "`n")
    $result = [Collections.Generic.List[string]]::new()
    $section = ''
    $lastBlockKey = ''

    foreach ($sourceLine in $lines) {
        $line = $sourceLine.TrimEnd()
        $sectionMatch = [regex]::Match($line, '^【(?<name>[^】]+)】\s*$')
        if ($sectionMatch.Success) {
            while ($result.Count -gt 0 -and [string]::IsNullOrWhiteSpace($result[$result.Count - 1])) {
                $result.RemoveAt($result.Count - 1)
            }
            if ($result.Count -gt 0) { $result.Add('') }
            $result.Add($line.Trim())
            $section = $sectionMatch.Groups['name'].Value
            $lastBlockKey = ''
            continue
        }

        $blockKey = Get-KcpsMemoLayoutBlockKey -Section $section -Line $line
        if (-not [string]::IsNullOrWhiteSpace($blockKey)) {
            if (-not [string]::IsNullOrWhiteSpace($lastBlockKey) -and $blockKey -ne $lastBlockKey) {
                while ($result.Count -gt 0 -and [string]::IsNullOrWhiteSpace($result[$result.Count - 1])) {
                    $result.RemoveAt($result.Count - 1)
                }
                $result.Add('')
            }
            $lastBlockKey = $blockKey
        }
        $result.Add($line)
    }

    while ($result.Count -gt 0 -and [string]::IsNullOrWhiteSpace($result[$result.Count - 1])) {
        $result.RemoveAt($result.Count - 1)
    }
    return ($result -join "`n")
}

$resolvedPaths = @()
foreach ($item in @(Resolve-Path -LiteralPath $Path)) {
    $target = Get-Item -LiteralPath $item.Path
    if ($target.PSIsContainer) {
        $resolvedPaths += @(Get-ChildItem -LiteralPath $target.FullName -File -Filter '*.conf.json' -Recurse |
            Where-Object { Test-KcpsConfigScanPath -Path $_.FullName -ScanRoot $target.FullName } |
            ForEach-Object FullName)
    } else {
        $resolvedPaths += $target.FullName
    }
}
$resolvedPaths = @($resolvedPaths | Sort-Object -Unique)
$changes = @()

foreach ($file in $resolvedPaths) {
    $config = Read-KcpsJson -Path $file
    $fileChanged = $false
    foreach ($group in @(Get-KcpsGroups -Config $config)) {
        foreach ($workflow in @($group['List'])) {
            if (-not (Test-KcpsWorkflowType -Workflow $workflow -TypeName 'MemoWorkflow')) { continue }
            $oldMemo = [string]$workflow['Memo']
            $newMemo = Format-KcpsMemoParagraphs -Memo $oldMemo
            if ($oldMemo -ceq $newMemo) { continue }
            $fileChanged = $true
            $changes += [ordered]@{
                File = Split-Path -Leaf $file
                Config = [string]$group['Name']
                HadCr = $oldMemo.Contains("`r")
            }
            if (-not $CheckOnly) { $workflow['Memo'] = $newMemo }
        }
    }
    if ($fileChanged -and -not $CheckOnly) {
        Write-KcpsJson -Value $config | Set-Content -LiteralPath $file -Encoding UTF8
    }
}

[ordered]@{
    PathCount = $resolvedPaths.Count
    CheckOnly = [bool]$CheckOnly
    Changes = $changes.Count
    Results = @($changes)
} | ConvertTo-Json -Depth 8
