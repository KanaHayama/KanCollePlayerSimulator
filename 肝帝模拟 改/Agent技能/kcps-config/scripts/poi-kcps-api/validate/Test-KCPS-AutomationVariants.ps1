#requires -Version 7.0
# Full generator regression using only synthetic private runtime inputs.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../KCPS-Common.ps1"
$tests=0
function Assert($value,$label){if(-not $value){throw $label};$script:tests++}
function Write-Fixture($value,$path){ConvertTo-Json -InputObject $value -Depth 100 | Set-Content -LiteralPath $path}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('kcps-variants-'+[guid]::NewGuid().ToString('N'))
$saved=@{};foreach($key in @('KCPS_WORKSPACE','KCPS_ROUTE_OVERRIDES','KCPS_SETTINGS_PATH')){$saved[$key]=[Environment]::GetEnvironmentVariable($key)}
try {
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    $env:KCPS_WORKSPACE=$temp;$env:KCPS_ROUTE_OVERRIDES=Join-Path $temp 'routes.json';$env:KCPS_SETTINGS_PATH=$null
    $automaticPath=Join-Path $temp 'automatic.json';$semiPath=Join-Path $temp 'semi.json';$path=Join-Path $temp 'config.json'
    $automatic=@{LoopLimit=4;MoraleMinimum=60;DockingHpThreshold=0.75;WaitForNaturalMorale=$false;LandBaseProficiencyChecks=@{'1'=$true;'2'=$false};BossNightBattle=2}
    $semi=@{LoopLimit=1;MoraleMinimum=35;DockingHpThreshold=0.6;WaitForNaturalMorale=$true;LandBaseProficiencyChecks=@{'1'=$false;'2'=$true};BossNightBattle=0}
    Write-Fixture $automatic $automaticPath;Write-Fixture $semi $semiPath
    foreach($area in @(2,8)) {
        $name="Synthetic stage $area";$node=20+$area
        $sortie=@{Type='SimpleSortieWorkflow';Name='出击';Guid=[guid]::NewGuid().ToString();Sea=0;Area=$area;LandBasedAirCorps1Action=1;LandBasedAirCorps2Action=1;Strategies=@(@{Condition=@{Type=1;Value=$node};Strategy=@{Memo='Synthetic Boss';DefaultMidnight=2}})}
        $controller=@{Type='RelationalSortieWorkflow';Name='总控';Guid=[guid]::NewGuid().ToString()}
        $dock=@{Type='BasicDockingWorkflow';Name='入渠';Guid=[guid]::NewGuid().ToString()}
        $memo=@{Type='MemoWorkflow';Name='备注';Memo='Synthetic memo';Guid=[guid]::NewGuid().ToString()}
        Write-Fixture @{Name=$name;List=@($memo,$controller,$dock,$sortie)} $path
        Write-Fixture @{Routes=@(@{Id='source';Sea=0;Area=$area;GroupNameRegex=('^'+[regex]::Escape($name)+'$');StageDesign=@{Phase='Final'};Nodes=@(@{Value=$node;Kind='boss';Letter='Q'})})} $env:KCPS_ROUTE_OVERRIDES
        $arguments=@{Path=$path;SourceGroupName=$name;AutomaticGroupName="$name automatic";SemiAutomaticGroupName="$name semi";StageLabel=$name;BossPointName='Q';RouteCode='A-Q';BossConditionValue=$node;SourceRouteId='source';AutomaticRouteId='auto';SemiAutomaticRouteId='semi';AutomaticPolicyPath=$automaticPath;SemiAutomaticPolicyPath=$semiPath}
        & "$PSScriptRoot/../enable/KCPS-EnsureHpFinalAutomationVariants.ps1" @arguments | Out-Null
        $groups=@(Get-KcpsGroups (Read-KcpsJson $path));$db=Read-KcpsJson $env:KCPS_ROUTE_OVERRIDES
        Assert ($groups.Count -eq 2 -and $db.Routes.Count -eq 2) 'explicit pair generation'
        foreach($route in $db.Routes) {
            $group=@($groups|Where-Object {Test-KcpsRouteSpecGroupName -GroupName $_.Name -RouteSpec $route})[0]
            $s=@($group.List|Where-Object Name -eq '出击')[0];$c=@($group.List|Where-Object Name -eq '总控')[0]
            $problems=@(Get-KcpsStageDesignProblems -Group $group -Sortie $s -RelationalWorkflows @($c) -Spec $route)
            Assert ($problems.Count -eq 0) ('generated policy mismatch: '+($problems -join '; '))
        }
        $before=Get-Content -LiteralPath $path -Raw
        & "$PSScriptRoot/../enable/KCPS-EnsureHpFinalAutomationVariants.ps1" @arguments | Out-Null
        Assert ($before -ceq (Get-Content -LiteralPath $path -Raw)) 'idempotent generation'
    }
    $automatic.Remove('BossNightBattle');Write-Fixture $automatic $automaticPath
    $before=Get-Content -LiteralPath $path -Raw;$failed=$false
    try { & "$PSScriptRoot/../enable/KCPS-EnsureHpFinalAutomationVariants.ps1" @arguments | Out-Null }catch{$failed=$true}
    Assert $failed 'missing explicit policy rejected'
    Assert ($before -ceq (Get-Content -LiteralPath $path -Raw)) 'failure leaves original config unchanged'
} finally {
    foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])}
    $full=[IO.Path]::GetFullPath($temp);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $full) -like 'kcps-variants-*'){Remove-Item -LiteralPath $full -Recurse -Force}
}
Write-Output "Passed $tests synthetic automation-variant checks."
