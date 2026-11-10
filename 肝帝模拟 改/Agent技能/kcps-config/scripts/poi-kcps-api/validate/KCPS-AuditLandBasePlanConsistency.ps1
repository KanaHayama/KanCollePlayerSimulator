#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,

    [switch]$IncludeWorkingFiles,

    [switch]$FailOnProblems
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

$routeSpecPath = Join-Path $PSScriptRoot '..\data\KCPS-RouteSpecs.json'
$routeSpecs = @()
if (Test-Path -LiteralPath $routeSpecPath) {
    $routeSpecDatabase = Read-KcpsJson -Path $routeSpecPath
    $routeSpecs = @($routeSpecDatabase['Routes'])
}

$files = @(@(
    foreach ($item in $Path) {
        $resolved = Resolve-Path -LiteralPath $item
        if ((Get-Item -LiteralPath $resolved).PSIsContainer) {
            Get-ChildItem -LiteralPath $resolved -Recurse -Filter '*.conf.json' -File |
                Where-Object { Test-KcpsConfigScanPath -Path $_.FullName -ScanRoot $resolved -IncludeWorkingFiles:$IncludeWorkingFiles }
        } else {
            Get-Item -LiteralPath $resolved
        }
    }
) | Sort-Object FullName -Unique)

$entries = @()
$dynamic = @()
foreach ($file in $files) {
    $config = Read-KcpsJson -Path $file.FullName
    foreach ($group in @(Get-KcpsGroups -Config $config)) {
        $workflows = @($group['List'])
        $sortie = @($workflows | Where-Object {
            Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleSortieWorkflow'
        }) | Select-Object -First 1
        if ($null -eq $sortie) { continue }

        $checkerSpec = Get-KcpsSortieIdentityCheckerSpec -Sortie $sortie
        $isEvent = [int]$sortie['Sea'] -eq 0
        if (-not $isEvent -and $null -eq $checkerSpec) { continue }

        $memoWorkflow = @($workflows | Where-Object {
            Test-KcpsWorkflowType -Workflow $_ -TypeName 'MemoWorkflow'
        }) | Select-Object -First 1
        $memo = if ($null -eq $memoWorkflow) { '' } else { [string]$memoWorkflow['Memo'] }
        $matchingRouteSpecs = @($routeSpecs | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_['GroupNameRegex']) -and
            (Test-KcpsRouteSpecGroupName -GroupName ([string]$group['Name']) -RouteSpec $_)
        })
        $routeSpec = if ($matchingRouteSpecs.Count -eq 1) { $matchingRouteSpecs[0] } else { $null }
        $routeHasPlan = $null -ne $routeSpec -and
            $routeSpec.Contains('ExpectedLandBasedAirCorps') -and
            $routeSpec['ExpectedLandBasedAirCorps'] -is [System.Collections.IDictionary] -and
            $routeSpec['ExpectedLandBasedAirCorps'].Count -gt 0
        if ($null -eq $checkerSpec -and -not $routeHasPlan) {
            if ([string]$sortie['Script'] -match '(?m)^# KCPS_DYNAMIC_LAND_BASE_PLAN\s+\S+') {
                $dynamic += [ordered]@{
                    Path = $file.FullName
                    Group = [string]$group['Name']
                    Reason = '显式声明为动态陆航方案，不固定四槽飞机。'
                }
                continue
            }
        }

        $problems = @(Get-KcpsLandBasePlanConsistencyProblems `
            -Sortie $sortie `
            -CheckerSpec $checkerSpec `
            -RouteSpec $routeSpec `
            -Memo $memo)
        if ($matchingRouteSpecs.Count -gt 1) {
            $problems += "配置同时匹配 $($matchingRouteSpecs.Count) 条路线规格，无法确定陆航定稿。"
        }

        $usesLandBases = @(1..3 | Where-Object {
            [int]$sortie["LandBasedAirCorps$($_)Action"] -in @(1, 2)
        }).Count -gt 0
        if ($usesLandBases -or $problems.Count -gt 0) {
            $entries += [ordered]@{
                Path = $file.FullName
                Group = [string]$group['Name']
                RouteSpec = if ($null -eq $routeSpec) { $null } else { [string]$routeSpec['Id'] }
                Problems = @($problems)
                Valid = $problems.Count -eq 0
            }
        }
    }
}

$problemCount = @($entries | ForEach-Object { @($_['Problems']) } | Where-Object { $_ }).Count
$result = [ordered]@{
    Files = $files.Count
    GroupsWithLandBases = $entries.Count
    DynamicGroups = $dynamic.Count
    ProblemCount = $problemCount
    Entries = @($entries)
    Dynamic = @($dynamic)
}
$result | ConvertTo-KcpsJsonOutput -Depth 10
if ($FailOnProblems -and $problemCount -gt 0) {
    throw "陆航方案一致性审计失败，共发现 $problemCount 个问题。"
}
