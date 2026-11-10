#requires -Version 7.0
# Synthetic roles and equipment only; no private plan or game API.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../KCPS-Common.ps1"
. "$PSScriptRoot/KCPS-SupportRotationValidation.ps1"
$master=@{'Synthetic gun'=@{api_id=1;api_tyku=0;api_tais=0;api_type=@(0,0,1)};'Synthetic plane'=@{api_id=2;api_tyku=3;api_tais=5;api_type=@(0,0,7)}}
$keys=@('guard_a','guard_b','wing_a','wing_b','wing_c','wing_d')
$roles=@{};$runtime=@{};$positions=@();$rows=@()
for($i=0;$i -lt 6;$i++) {
    $isAircraft=$i -ge 2
    $type=if($i -lt 2){2}elseif($i -eq 5){11}else{7}
    $names=if($isAircraft){@('Synthetic plane','Synthetic plane','Synthetic plane','Synthetic plane')}else{@('Synthetic gun','Synthetic gun','Synthetic gun')}
    $roles[$keys[$i]]=@{ShipTypes=@($type);MinimumLevel=30;MinimumSlots=$names.Count;MinimumTotalCapacity=0;MinimumAircraftPerSlot=$(if($isAircraft){1}else{0});MinimumAirPower=0;EquipmentNames=$names;OptionalSlots=@()}
    $r=$roles[$keys[$i]]|ConvertTo-Json|ConvertFrom-Json -AsHashtable
    $r.Remove('EquipmentNames');$r.EquipmentIds=@($names|ForEach-Object {$master[$_].api_id});$r.AntiAir=@($names|ForEach-Object {$master[$_].api_tyku});$runtime[$keys[$i]]=$r
    $positions+=@{Selections=@(@{Type=8;Value=$keys[$i]});SkipShipsInOtherFleets=$true;SkipRepairingShips=$true;SkipExpeditioningShips=$true
        ChangeIfMoraleInRangeFlag=$true;ChangeIfMoraleInRangeValueMin=0;ChangeIfMoraleInRangeValueMax=35;SkipMoraleInRangeFlag=$true;SkipMoraleInRangeValueMin=0;SkipMoraleInRangeValueMax=35}
    $slots=@();for($n=0;$n -lt $names.Count;$n++){$slots+=@{Slot=$n+1;IgnoreSlotNotAvailable=$false;Equipments=@(@{SelectMethod=0;SelectValue=$names[$n]})}}
    $rows+=@{Fleet=2;SelectMethod=0;SelectValue=[string]($i+1);Slots=$slots}
}
$plan=@{Fleet=2;Roles=$roles;PositionRoles=$keys;MoraleExclusionMax=@(35,35,35,35,35,35);MinimumAviationAswSlots=12;MinimumSupportAirPower=0;EnemyAirPower=0}
$org=@{Type='BasicOrganizeFleetWorkflow';Fleet=2;Positions=$positions;EnableScript=$true;Script=('SUPPORT_ROLES = '+($runtime|ConvertTo-Json -Depth 10 -Compress)+"`n"+(Get-Content -LiteralPath "$PSScriptRoot/../enable/support_rotation.py" -Raw))}
$base=@{Plan=$plan;Workflows=@($org,@{Type='BasicRefitEquipmentWorkflow';Ships=$rows});MasterEquipByName=$master;Memo='Synthetic roles'}
function Check($value) {@(Get-KcpsDynamicAswSupportProblems @value)}
$issues=@(Check $base);if($issues.Count){throw ($issues -join '; ')}
$cases=@(
    @{Label='fixed role';Pattern='通用角色';Edit={param($x)$x.Workflows[0].Positions[0].Selections[0].Type=0}},
    @{Label='morale declaration';Pattern='MoraleExclusionMax';Edit={param($x)$x.Plan.Remove('MoraleExclusionMax')}},
    @{Label='occupied ships';Pattern='占用';Edit={param($x)$x.Workflows[0].Positions[2].SkipShipsInOtherFleets=$false}},
    @{Label='explicit refit';Pattern='按位置改装';Edit={param($x)$x.Workflows[1].Ships[2].SelectMethod=3}},
    @{Label='declared equipment';Pattern='候选能力校验';Edit={param($x)$x.Workflows[1].Ships[2].Slots[0].Equipments[0].SelectValue='Other'}},
    @{Label='runtime drift';Pattern='不一致';Edit={param($x)$x.Plan.Roles.wing_a.MinimumAirPower=1}},
    @{Label='optional slots';Pattern='候选能力校验';Edit={param($x)$x.Workflows[1].Ships[0].Slots[2].IgnoreSlotNotAvailable=$true}},
    @{Label='minimum attack slots';Pattern='攻击槽';Edit={param($x)$x.Plan.MinimumAviationAswSlots=20}}
)
foreach($case in $cases){$x=$base|ConvertTo-Json -Depth 50|ConvertFrom-Json -AsHashtable;& $case.Edit $x;if(((Check $x)-join '; ') -notmatch $case.Pattern){throw ('Missed '+$case.Label)}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('kcps-support-'+[guid]::NewGuid().ToString('N'))
$saved=@{};foreach($key in @('KCPS_WORKSPACE','KCPS_ROUTE_OVERRIDES','KCPS_SETTINGS_PATH')){$saved[$key]=[Environment]::GetEnvironmentVariable($key)}
$integrationChecks=0
try {
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    $env:KCPS_WORKSPACE=$temp;$env:KCPS_ROUTE_OVERRIDES=Join-Path $temp 'routes.json';$env:KCPS_SETTINGS_PATH=$null
    $path=Join-Path $temp 'config.json';$snapshot=Join-Path $temp 'snapshot.json'
    $plan.SelectionMode='DynamicRoles'
    @{Routes=@(@{Id='synthetic-support';BossSupportPlan=$plan})}|ConvertTo-Json -Depth 50|Set-Content -LiteralPath $env:KCPS_ROUTE_OVERRIDES
    $equipment=@{};foreach($entry in $master.GetEnumerator()){$entry.Value['api_name']=$entry.Key;$equipment[[string]$entry.Value.api_id]=$entry.Value}
    @{const=@{'$equips'=$equipment}}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $snapshot
    @{Name='Synthetic support';List=$base.Workflows}|ConvertTo-Json -Depth 50|Set-Content -LiteralPath $path
    & "$PSScriptRoot/../enable/KCPS-EnableDynamicAswSupport.ps1" -Path $path -GroupName 'Synthetic support' -RouteId 'synthetic-support' -SnapshotPath $snapshot | Out-Null
    $generated=Read-KcpsJson $path
    $problems=@(Get-KcpsDynamicAswSupportProblems -Plan $plan -Workflows $generated.List -MasterEquipByName $master -Memo 'Synthetic roles')
    if($problems.Count){throw ('Generated support: '+($problems -join '; '))};$integrationChecks++
    $before=Get-Content -LiteralPath $path -Raw
    & "$PSScriptRoot/../normalize/KCPS-NormalizeSupportDestroyerRefit.ps1" -Path $path | Out-Null
    if($before -cne (Get-Content -LiteralPath $path -Raw)){throw 'Inspection modified a declared support loadout'};$integrationChecks++
} finally {
    foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])}
    $full=[IO.Path]::GetFullPath($temp);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $full) -like 'kcps-support-*'){Remove-Item -LiteralPath $full -Recurse -Force}
}
Write-Output "Passed $($cases.Count+1+$integrationChecks) synthetic support checks."
