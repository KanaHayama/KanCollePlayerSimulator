#requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

function Set-KcpsWorkflowOrder {
    param([System.Collections.IDictionary]$Group)

    $list = @($Group['List'])
    $memoIndex = -1
    for ($i = 0; $i -lt $list.Count; $i++) {
        $name = [string]$list[$i]['Name']
        if (($name -eq '说明' -or $name -eq '备注') -and
            (Test-KcpsWorkflowType -Workflow $list[$i] -TypeName 'MemoWorkflow')) {
            $memoIndex = $i
            break
        }
    }

    if ($memoIndex -le 0) {
        $order = @($list | ForEach-Object { [string]$_['Name'] })
        return [pscustomobject]@{
            Changed = $false
            OldOrder = @($order)
            NewOrder = @($order)
        }
    }

    $newList = @($list[$memoIndex])
    if ($memoIndex -gt 0) { $newList += $list[0..($memoIndex - 1)] }
    if ($memoIndex + 1 -lt $list.Count) { $newList += $list[($memoIndex + 1)..($list.Count - 1)] }

    $oldOrder = @($list | ForEach-Object { [string]$_['Name'] })
    $newOrder = @($newList | ForEach-Object { [string]$_['Name'] })
    $Group['List'] = @($newList)
    return [pscustomobject]@{
        Changed = $true
        OldOrder = @($oldOrder)
        NewOrder = @($newOrder)
    }
}

$resolvedPaths = @()
$resolved = Resolve-Path -LiteralPath $Path
foreach ($item in $resolved) {
    $target = Get-Item -LiteralPath $item.Path
    if ($target.PSIsContainer) {
        $resolvedPaths += @(Get-ChildItem -LiteralPath $target.FullName -File -Filter '*.conf.json' -Recurse | Where-Object { Test-KcpsConfigScanPath -Path $_.FullName -ScanRoot $target.FullName } | ForEach-Object { $_.FullName })
    } else {
        $resolvedPaths += $target.FullName
    }
}
$resolvedPaths = @($resolvedPaths | Sort-Object -Unique)

$report = @()

foreach ($file in $resolvedPaths) {
    $config = Read-KcpsJson -Path $file
    $groups = Get-KcpsGroups -Config $config
    $fileChanged = $false

    foreach ($group in $groups) {
        if (-not ($group -is [System.Collections.IDictionary]) -or -not (Test-MapKey -Map $group -Key 'List')) { continue }
        $result = Set-KcpsWorkflowOrder -Group $group
        if ($result.Changed) {
            $fileChanged = $true
            $report += [pscustomobject]@{
                File = Split-Path -Leaf $file
                Config = $group['Name']
                OldOrder = @($result.OldOrder)
                NewOrder = @($result.NewOrder)
            }
        }
    }

    if ($fileChanged -and -not $CheckOnly) {
        Write-KcpsJson -Value $config | Set-Content -LiteralPath $file -Encoding UTF8
    }
}

[pscustomobject]@{
    PathCount = $resolvedPaths.Count
    CheckOnly = [bool]$CheckOnly
    Changes = @($report).Count
    Results = @($report)
} | ConvertTo-Json -Depth 20
