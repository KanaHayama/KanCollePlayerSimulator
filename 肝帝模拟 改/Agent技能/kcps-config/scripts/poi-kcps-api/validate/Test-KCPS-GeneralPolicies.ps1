#requires -Version 7.0
# Synthetic offline regression; never loads existing private workspaces.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../KCPS-Common.ps1"
$tests=0
function Assert($value,$label) { if(-not $value){ throw $label }; $script:tests++ }
function Assert-Throws([scriptblock]$Action,$label) { $caught=$false; try { & $Action | Out-Null } catch { $caught=$true }; Assert $caught $label }
function Import-Function($Path,$Name) {
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$null,[ref]$null)
    $node=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true)
    if(-not $node){throw "missing test target $Name"}
    . ([scriptblock]::Create('function global:'+$Name+$node.Extent.Text.Substring(('function '+$Name).Length)))
}
Import-Function "$PSScriptRoot/../inspect/KCPS-AuditFleetOrder.ps1" 'Get-FixedPrefixHint'
Import-Function "$PSScriptRoot/KCPS-ValidateConfig.ps1" 'Get-KcpsRouteSpecProblems'
foreach($name in @('Synthetic alpha','Independent beta')) {
    Assert ((Get-FixedPrefixHint $name 2) -eq 2) 'explicit prefix independent of task name'
    Assert-Throws { Get-FixedPrefixHint $name } 'missing prefix rejected'
    foreach($sea in @(0,4)) {
        $problems=@(Get-KcpsRouteSpecProblems -Group @{Name=$name} -SortieWorkflows @(@{Name='Synthetic sortie';Sea=$sea;Area=7}) -RouteSpecDocument @{Routes=@()})
        Assert ($problems.Count -eq 1) 'missing event or ordinary route rejected'
    }
}
foreach($mode in @('MultiLoop','SemiAutomaticSingleLoop')) {
    $loop=if($mode -eq 'MultiLoop'){4}else{1}
    $morale=if($mode -eq 'MultiLoop'){60}else{35}
    $design=@{AutomationMode=$mode;LoopLimit=$loop;MoraleMinimum=$morale;LandBaseProficiencyChecks=@{'1'=$true;'2'=$false};BossNightBattle=0;SupportMoraleChecks=@{Normal=$false}}
    $sortie=@{FlagShipMoraleLargerOrEqualThanFlag=$true;FlagShipMoraleLargerOrEqualThanValue=$morale;EscortShipMoraleLargerOrEqualThanFlag=$true;EscortShipMoraleLargerOrEqualThanValue=$morale
        LandBasedAirCorps1Action=1;LandBasedAirCorps1CheckAnyProficiencyNotFull=$true;LandBasedAirCorps2Action=1;LandBasedAirCorps2CheckAnyProficiencyNotFull=$false
        Strategies=@(@{Strategy=@{Memo='Synthetic Boss';DefaultMidnight=0}});NormalSupportExpedition=$true;NormalSupportExpeditionCheckMorale=$false}
    $controller=@{StopIfLoopCountLargerOrEqualThanFlag=$true;StopIfLoopCountLargerOrEqualThanValue=$loop}
    $arguments=@{Group=@{Name='Neutral synthetic name';List=@()};Sortie=$sortie;RelationalWorkflows=@($controller);Spec=@{StageDesign=$design}}
    Assert (@(Get-KcpsStageDesignProblems @arguments).Count -eq 0) 'independent declared stage choices'
    $design.LandBaseProficiencyChecks.Remove('1')
    Assert (@(Get-KcpsStageDesignProblems @arguments | Where-Object { $_ -match 'explicitly declare' }).Count -eq 1) 'missing active-base declaration'
    Assert (@(Get-KcpsHighMoraleSingleLoopProblems -SortieWorkflows @($sortie) -RelationalWorkflows @($controller)).Count -eq 0) 'high morale is not inherently single-loop'
    $controller.SleepUntilMoraleRecoveredFlag=$true
    $problems=@(Get-KcpsHighMoraleSingleLoopProblems -SortieWorkflows @($sortie) -RelationalWorkflows @($controller))
    Assert (($problems.Count -eq 1) -eq ($morale -gt 49)) 'natural recovery ceiling preserved'
}
$temp=[IO.Path]::Combine([IO.Path]::GetTempPath(),'kcps-generic-'+[guid]::NewGuid().ToString('N'))
$saved=@{}; foreach($name in @('KCPS_WORKSPACE','KCPS_SETTINGS_PATH','KCPS_ROUTE_OVERRIDES')) { $saved[$name]=[Environment]::GetEnvironmentVariable($name) }
try {
    [IO.Directory]::CreateDirectory((Join-Path $temp '.work')) | Out-Null
    $env:KCPS_WORKSPACE=$temp; $env:KCPS_SETTINGS_PATH=$null; $env:KCPS_ROUTE_OVERRIDES=$null
    $public=Join-Path $temp 'KCPS-RouteSpecs.json'; $radii=Join-Path $temp 'KCPS-LandBasedAirCorpsTargetRadii.json'; $private=Join-Path $temp '.work/route-overrides.json'
    @{Version=2;Routes=@();EventBossStages=@();RouteBranchRules=@()} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $public
    @{Version=1;Routes=@{}} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $radii
    Assert ((Import-KcpsRouteDatabase $public).Routes.Count -eq 0) 'selected workspace without route input remains empty'
    $overlay=@{Routes=@(@{Id='synthetic-alpha';Sea=0;Area=2;KcNavMap='91-2'},@{Id='synthetic-beta';Sea=0;Area=8;KcNavMap='93-8'})
        EventBossStages=@(@{Id='synthetic';Area=2;RouteSpecIdRegex='^synthetic-alpha$';BossPoints=@{Q=1};Source='synthetic';LastVerifiedJst='2000-01-01';RefreshAfterDays=1})
        RouteBranchRules=@(@{KcNavMap='91-2';From='A';To='B';Formula='synthetic';Threshold=2})
        LandBasedAirCorpsTargetRadii=@{Version=1;Routes=@{'synthetic-alpha'=@{Map='91-2';Source='synthetic';Corps=@{'1'=@{TargetPoints=@('Q');RequiredRadius=4}}}}}}
    $overlay | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $private
    $read=Import-KcpsRouteDatabase $public
    Assert ($read.Routes.Count -eq 2 -and $read.EventBossStages.Count -eq 1 -and $read.RouteBranchRules.Count -eq 1) 'selected workspace evidence is loaded and merged'
    Assert ((Import-KcpsRouteDatabase $public -PublicOnly).Routes.Count -eq 0) 'PublicOnly ignores runtime input'
    Assert ((Import-KcpsLandBaseRadiusEvidence $radii).Routes['synthetic-alpha'].Corps['1'].RequiredRadius -eq 4) 'private independent radius evidence'
    Assert ((Import-KcpsLandBaseRadiusEvidence $radii -PublicOnly).Routes.Count -eq 0) 'PublicOnly radii ignores private evidence'
    Assert-Throws { Import-KcpsRouteDatabase $public -OverridesPath (Join-Path $temp 'missing.json') } 'explicit missing evidence file rejected'
    $overlay.EventBossStages=@{}; $overlay | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $private
    Assert-Throws { Import-KcpsRouteDatabase $public } 'malformed stage evidence rejected'

    $overlay.EventBossStages=@(); $overlay | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $private
    $copiedApi=Join-Path $temp 'independent skill/scripts/poi-kcps-api'
    [IO.Directory]::CreateDirectory($copiedApi) | Out-Null
    foreach($file in @('KCPS-Connection.ps1','KCPS-RouteData.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "../$file") -Destination (Join-Path $copiedApi $file)
    }
    . (Join-Path $copiedApi 'KCPS-RouteData.ps1')
    $env:KCPS_WORKSPACE=$null; $env:KCPS_SETTINGS_PATH=$null; $env:KCPS_ROUTE_OVERRIDES=$null
    'INVALID SYNTHETIC SETTINGS' | Set-Content -LiteralPath (Join-Path $temp '.work/kcps.local.json')
    Assert ((Get-KcpsLocalSettings).Count -eq 0) 'neighboring malformed settings are not read'
    Assert ((Import-KcpsRouteDatabase $public).Routes.Count -eq 0) 'neighboring route evidence is not discovered'
    Assert ((Import-KcpsLandBaseRadiusEvidence $radii).Routes.Count -eq 0) 'neighboring radius evidence is not discovered'
    Assert-Throws { Get-KcpsPrivatePath 'snapshot.json' } 'unselected neighboring data cannot establish output workspace'
    Assert-Throws { Save-KcpsPrivateRoutePlans -Routes @(@{Id='synthetic-output'}) } 'route writes require an explicit destination or workspace'
    Assert ((Import-KcpsRouteDatabase $public -OverridesPath $private).Routes.Count -eq 2) 'explicit route path works without a workspace'
    $env:KCPS_ROUTE_OVERRIDES=$private
    Assert ((Import-KcpsRouteDatabase $public).Routes.Count -eq 2) 'explicit environment route path works without a workspace'
    $env:KCPS_ROUTE_OVERRIDES=$null
    $selectedSettings=Join-Path $temp 'selected-settings.json'
    @{WorkspaceRoot='.'} | ConvertTo-Json | Set-Content -LiteralPath $selectedSettings
    $env:KCPS_SETTINGS_PATH=$selectedSettings
    Assert ((Import-KcpsRouteDatabase $public).Routes.Count -eq 2) 'workspace declared in explicitly selected settings provides runtime inputs'
    Assert ((Get-KcpsPrivatePath 'snapshot.json') -eq (Join-Path $temp '.work/snapshot.json')) 'explicit settings workspace supplies the output root'
} finally {
    foreach($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) }
    $resolved=[IO.Path]::GetFullPath($temp); $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'kcps-generic-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Output "Passed $tests synthetic general-policy checks."
