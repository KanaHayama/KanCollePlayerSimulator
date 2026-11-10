#requires -Version 7.0
param(
    [Parameter(Mandatory)][string[]]$Path,
    [string]$BaseUrl = '',
    [switch]$FailOnProblems
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"
$const = Get-PoiData -Type const -BaseUrl $BaseUrl
$ships = Get-PoiData -Type ships -BaseUrl $BaseUrl
$masters = Get-KcpsConstShips $const
$files = @(
    foreach ($inputPath in $Path) {
        $item = Get-Item -LiteralPath $inputPath
        if ($item.PSIsContainer) {
            Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Filter '*.conf.json' |
                Where-Object { Test-KcpsConfigScanPath -Path $_.FullName -ScanRoot $item.FullName }
        } else { $item }
    }
) | Sort-Object FullName -Unique
$results = @(); $groupCount = 0
foreach ($file in $files) {
    foreach ($group in @(Get-KcpsGroups (Read-KcpsJson $file.FullName))) {
        $groupCount++
        $event = @($group['List'] | Where-Object { (Test-KcpsWorkflowType $_ 'SimpleSortieWorkflow') -and [int]$_['Sea'] -eq 0 }).Count -gt 0
        foreach ($problem in @(Get-KcpsRefitSlotExistenceProblems -Workflows @($group['List']) `
            -OwnedShips $ships -MasterShips $masters -RejectOptionalFixedSlots:$event)) {
            $problem | Add-Member -NotePropertyName File -NotePropertyValue $file.FullName
            $problem | Add-Member -NotePropertyName Config -NotePropertyValue $group['Name']
            $results += $problem
        }
    }
}
[ordered]@{FilesScanned=@($files).Count; GroupsScanned=$groupCount; ProblemCount=$results.Count; Problems=$results} | ConvertTo-Json -Depth 12
if ($FailOnProblems -and $results.Count) { throw "发现 $($results.Count) 个改装槽位问题。" }
