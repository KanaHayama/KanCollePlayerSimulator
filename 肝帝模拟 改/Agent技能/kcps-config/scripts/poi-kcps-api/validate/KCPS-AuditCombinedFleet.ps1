#requires -Version 7.0
param(
    [Parameter(Mandatory)][string[]]$Path,
    [string]$BaseUrl = '',
    [switch]$FailOnProblems
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"
$ships = Get-PoiData -Type ships -BaseUrl $BaseUrl
$masters = Get-KcpsConstShips (Get-PoiData -Type const -BaseUrl $BaseUrl)
$files = @(
    foreach ($inputPath in $Path) {
        $item = Get-Item -LiteralPath $inputPath
        if ($item.PSIsContainer) {
            Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Filter '*.conf.json' |
                Where-Object { Test-KcpsConfigScanPath -Path $_.FullName -ScanRoot $item.FullName }
        } else { $item }
    }
) | Sort-Object FullName -Unique
$results = @(); $groups = 0; $combinedGroups = 0
foreach ($file in $files) {
    foreach ($group in @(Get-KcpsGroups (Read-KcpsJson $file.FullName))) {
        $groups++
        if (@($group['List'] | Where-Object { (Test-KcpsWorkflowType $_ 'BasicCombinedFleetWorkflow') -and [int]$_['CombinedFleetType'] -ne 0 }).Count) { $combinedGroups++ }
        foreach ($problem in @(Get-KcpsCombinedWorkflowProblems -Workflows @($group['List']) -OwnedShips $ships -MasterShips $masters)) {
            $problem | Add-Member -NotePropertyName File -NotePropertyValue $file.FullName
            $problem | Add-Member -NotePropertyName Config -NotePropertyValue $group['Name']
            $results += $problem
        }
    }
}
[ordered]@{FilesScanned=@($files).Count; GroupsScanned=$groups; CombinedGroupsScanned=$combinedGroups; ProblemCount=$results.Count; Problems=$results} | ConvertTo-Json -Depth 12
if ($FailOnProblems -and $results.Count) { throw "发现 $($results.Count) 个联合编成问题。" }
