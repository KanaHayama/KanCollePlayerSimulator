#requires -Version 7.0

<#
.SYNOPSIS
    扫描 KCPS 配置中的改装装备并发占用，找出必然耗尽的候选。
.DESCRIPTION
    从实时 poi 数据读取账号装备总数，只做结构性容量审计，不把瞬时远征占用当成配置缺陷。
    动态支援舰队与固定出击舰队均按改装执行单元中的实际顺序计入。
#>
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,

    [string]$BaseUrl = '',

    [switch]$FailOnProblems
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

$files = @()
foreach ($inputPath in $Path) {
    $resolved = Resolve-Path -LiteralPath $inputPath
    foreach ($item in $resolved) {
        if ((Get-Item -LiteralPath $item.Path).PSIsContainer) {
            $files += Get-ChildItem -LiteralPath $item.Path -Recurse -File -Filter '*.conf.json' |
                Where-Object { Test-KcpsConfigScanPath -Path $_.FullName -ScanRoot $item.Path }
        }
        else {
            $files += Get-Item -LiteralPath $item.Path
        }
    }
}
$files = @($files | Sort-Object FullName -Unique)

$const = Get-PoiData -BaseUrl $BaseUrl -Type 'const'
$equips = Get-PoiData -BaseUrl $BaseUrl -Type 'equips'
$ownedCounts = @{}
foreach ($entry in $equips.GetEnumerator()) {
    $name = Get-KcpsConstEquipName -Const $const -EquipConstId ([int]$entry.Value['api_slotitem_id'])
    if (-not $ownedCounts.ContainsKey($name)) { $ownedCounts[$name] = 0 }
    $ownedCounts[$name]++
}

$results = @()
foreach ($file in $files) {
    $config = Read-KcpsJson -Path $file.FullName
    foreach ($group in @($config)) {
        $refits = @($group['List'] | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicRefitEquipmentWorkflow' })
        if ($refits.Count -eq 0) { continue }
        foreach ($problem in @(Get-KcpsRefitEquipmentCapacityProblems -RefitWorkflows $refits -OwnedEquipmentCountsByName $ownedCounts)) {
            $results += [pscustomobject]@{
                File = $file.FullName
                Config = [string]$group['Name']
                Category = $problem.Category
                Workflow = $problem.Workflow
                Fleet = $problem.Fleet
                Position = $problem.Position
                Ship = $problem.Ship
                Slot = $problem.Slot
                Equipment = $problem.Equipment
                Required = $problem.Required
                Owned = $problem.Owned
                Problem = $problem.Problem
            }
        }
    }
}

$output = [pscustomobject]@{
    Timestamp = (Get-Date).ToString('s')
    FilesScanned = $files.Count
    ProblemCount = $results.Count
    Problems = @($results)
}
$output | ConvertTo-KcpsJsonOutput -Depth 30

if ($FailOnProblems -and $results.Count -gt 0) {
    throw "发现 $($results.Count) 个改装装备容量问题。"
}
