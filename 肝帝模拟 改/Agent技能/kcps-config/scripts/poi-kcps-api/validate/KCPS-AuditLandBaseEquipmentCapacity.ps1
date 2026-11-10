#requires -Version 7.0

<#
.SYNOPSIS
    扫描 KCPS 活动配置的基地航空队装备总量是否可由账号库存满足。
.DESCRIPTION
    按每个配置单独统计所有设为出击或防空的基地航空队四槽需求。
    装备当前位于舰船、仓库或其他基地不影响结构性容量；只比较账号总持有量。
#>
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,

    [string]$BaseUrl = '',

    [string]$SnapshotPath,

    [switch]$FailOnProblems
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

$files = @()
foreach ($inputPath in $Path) {
    foreach ($item in @(Resolve-Path -LiteralPath $inputPath)) {
        $resolvedItem = Get-Item -LiteralPath $item.Path
        if ($resolvedItem.PSIsContainer) {
            $files += Get-ChildItem -LiteralPath $resolvedItem.FullName -Recurse -File -Filter '*.conf.json' |
                Where-Object { Test-KcpsConfigScanPath -Path $_.FullName -ScanRoot $resolvedItem.FullName }
        } else {
            $files += $resolvedItem
        }
    }
}
$files = @($files | Sort-Object FullName -Unique)

if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
    $snapshot = Read-KcpsJson -Path $SnapshotPath
    $const = $snapshot['const']
    $equips = $snapshot['equips']
} else {
    $const = Get-PoiData -BaseUrl $BaseUrl -Type const
    $equips = Get-PoiData -BaseUrl $BaseUrl -Type equips
}

$results = @()
$groupsChecked = 0
foreach ($file in $files) {
    $config = Read-KcpsJson -Path $file.FullName
    foreach ($group in @(Get-KcpsGroups -Config $config)) {
        $sortie = @($group['List'] | Where-Object {
            Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleSortieWorkflow'
        }) | Select-Object -First 1
        if ($null -eq $sortie) { continue }

        $checkerSpec = Get-KcpsSortieIdentityCheckerSpec -Sortie $sortie
        if ($null -eq $checkerSpec -or
            -not ($checkerSpec['LandBases'] -is [System.Collections.IDictionary])) {
            continue
        }

        $groupsChecked++
        foreach ($problem in @(Get-KcpsLandBaseEquipmentCapacityProblems `
            -Sortie $sortie `
            -CheckerSpec $checkerSpec `
            -Equips $equips `
            -Const $const)) {
            $results += [pscustomobject]@{
                File = $file.FullName
                Config = [string]$group['Name']
                Category = $problem.Category
                EquipmentId = $problem.EquipmentId
                Equipment = $problem.Equipment
                Required = $problem.Required
                Owned = $problem.Owned
                Slots = $problem.Slots
                Problem = $problem.Problem
            }
        }
    }
}

[ordered]@{
    Timestamp = (Get-Date).ToString('s')
    FilesScanned = $files.Count
    GroupsChecked = $groupsChecked
    ProblemCount = $results.Count
    Problems = @($results)
} | ConvertTo-KcpsJsonOutput -Depth 30

if ($FailOnProblems -and $results.Count -gt 0) {
    throw "发现 $($results.Count) 个基地航空队装备容量问题。"
}
