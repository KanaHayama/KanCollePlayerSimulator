#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$RouteId,
    [string]$BaseUrl = ''
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"
$db = Read-KcpsJson "$PSScriptRoot\..\data\KCPS-RouteSpecs.json"
$route = @($db['Routes'] | Where-Object { $_['Id'] -eq $RouteId })
if ($route.Count -ne 1) { throw 'Expected one route specification.' }
$route = $route[0]
$group = @((Get-KcpsGroups (Read-KcpsJson $Path)) | Where-Object { $_['Name'] -match $route['GroupNameRegex'] })
if ($group.Count -ne 1) { throw 'Expected one matching configuration.' }
$baseline = ConvertTo-Json -InputObject $group[0] -Depth 100
$dir = Join-Path ([IO.Path]::GetTempPath()) ('kcps-startpoint-test-' + [guid]::NewGuid().ToString('N'))
$file = Join-Path $dir 'composition.conf.json'
$null = New-Item -ItemType Directory -Path $dir
$passed = 0
try {
    # 基线同时含支援舰队，支援舰种不能计入出击路线。
    $cases = @(
        @{ Name = 'baseline'; SourceFleet = 0; SourcePosition = 0; Expected = '' },
        @{ Name = 'third heavy cruiser'; SourceFleet = 1; SourcePosition = 2; Expected = '重巡.*exactly 2.*contain 3' },
        @{ Name = 'second light cruiser'; SourceFleet = 2; SourcePosition = 3; Expected = '軽巡.*exactly 1.*contain 2' },
        @{ Name = 'third battleship'; SourceFleet = 1; SourcePosition = 1; Expected = '戦艦.*at most 2.*contain 3' }
    )
    foreach ($case in $cases) {
        $copy = $baseline | ConvertFrom-Json -AsHashtable
        if ($case.SourceFleet) {
            $source = @($copy['List'] | Where-Object { (Test-KcpsWorkflowType $_ 'BasicOrganizeFleetWorkflow') -and $_['Fleet'] -eq $case.SourceFleet })[0]
            $target = @($copy['List'] | Where-Object { (Test-KcpsWorkflowType $_ 'BasicOrganizeFleetWorkflow') -and $_['Fleet'] -eq 2 })[0]
            $target['Positions'][1]['Selections'] = @($source['Positions'][$case.SourcePosition - 1]['Selections'] | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable)
        }
        [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject @($copy) -Depth 100), [Text.UTF8Encoding]::new($false))
        # 负例故意复用实例，只断言真实校验器的路线舰种错误，不把其他错误当作证明。
        $report = (& "$PSScriptRoot\KCPS-ValidateConfig.ps1" -Path $file -BaseUrl $BaseUrl | Out-String) | ConvertFrom-Json -AsHashtable
        $errors = @($report['Groups'][0]['RouteSpecProblems'] | ForEach-Object { $_['Problem'] })
        if ($case.Expected) {
            if (@($errors | Where-Object { $_ -match $case.Expected }).Count -eq 0) { throw "Not detected: $($case.Name): $($errors -join '; ')" }
        } elseif ($report['ProblemCount'] -ne 0) { throw "Baseline failed: $($report | ConvertTo-Json -Depth 8 -Compress)" }
        $passed++
    }
    [pscustomobject]@{ Passed = $passed; Failed = 0 }
} finally {
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    Remove-Item -LiteralPath $dir
}
