#requires -Version 7.0
# Synthetic offline fixtures; no account snapshots or game connection.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../KCPS-Common.ps1"
. "$PSScriptRoot/KCPS-LevelingValidation.ps1"
$tests=0
function Assert($value,$label) { if(-not $value){throw $label};$script:tests++ }
function Clone($v) { ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $v -Depth 100) -AsHashtable -NoEnumerate }
function New-Fixture([string]$Map,[int]$Fleet,[int]$Node,[int]$Formation) {
    $stage=@{Phase='Leveling';SelectionMode='FixedInstances';FatigueMode='Recover';MoraleMinimum=35;LoopLimit=3
        LandBaseActions=@{'1'=0;'2'=0;'3'=0};LandBaseFatigueChecks=@{'1'=$false;'2'=$false;'3'=$false};PostClearRequiredMaps=@()
        TargetStrategies=@(@{ConditionValue=$Node;Formation=$Formation;Advance=2;Midnight=1;WayPoint='Synthetic'})
        RouteCompositionRules=@(@{Name='synthetic count';Fleet=$Fleet;ShipTypes=@(2);MinCount=1;MaxCount=1;Source='synthetic fixture';LastVerifiedJst='2000-01-01'})
        SelectionAudit=@(@{Id=700001;Name='Synthetic ship';Role='待练';CopyNo=3;Level=120;Fleet=$Fleet})}
    $route=@{Id='synthetic';GroupNameRegex='^Synthetic$';KcNavMap=$Map;StageDesign=$stage}
    $controller=@{StopIfLoopCountLargerOrEqualThanFlag=$true;StopIfLoopCountLargerOrEqualThanValue=3;SleepUntilMoraleRecoveredFlag=$true;SleepUntilMoraleRecoveredValueMorale=35}
    $sortie=@{Strategies=@(@{Condition=@{Type=1;Value=$Node};Strategy=@{DefaultFormation=$Formation;DefaultAdvance=2;DefaultMidnight=1;DefaultWayPoint='Synthetic'}})}
    foreach($n in 1..3){$sortie["LandBasedAirCorps${n}Action"]=0;$sortie["LandBasedAirCorps${n}Resupply"]=0;$sortie["LandBasedAirCorps${n}CheckFatigue"]=$false}
    $workflows=@(@{Type='BasicOrganizeFleetWorkflow';Fleet=$Fleet;Positions=@(@{Selections=@(@{Type=0;Value='700001'})})},@{Type='BasicRefitEquipmentWorkflow';Name='Synthetic refit';Ships=@(@{Fleet=$Fleet;SelectMethod=3;SelectValue='700001';Slots=@()})})
    return @{RouteSpec=$route;Controller=$controller;Sortie=$sortie;Maps=@{};Workflows=$workflows;Ships=@{'700001'=@{api_ship_id=800001;api_lv=120}};MasterShips=@{'800001'=@{api_name='Synthetic ship';api_stype=2;api_soku=10}};Equips=@{};MasterEquips=@{};Groups=@();Routes=@($route);Const=@{}}
}
foreach($case in @(@('91-2',1,7,1),@('93-8',3,29,5))){
    $fixture=New-Fixture $case[0] $case[1] $case[2] $case[3]
    $problems=@(Get-KcpsLevelingProblems @fixture)
    Assert ($problems.Count -eq 0) ("valid synthetic fixture: "+($problems -join '; '))
    $copy=Clone $fixture;$copy.RouteSpec.StageDesign.Remove('SelectionMode')
    Assert (@(Get-KcpsLevelingProblems @copy).Count -gt 0) 'missing selection contract'
    $copy=Clone $fixture;$copy.RouteSpec.StageDesign.Remove('RouteCompositionRules')
    Assert (@(Get-KcpsLevelingProblems @copy|Where-Object {$_ -match 'RouteCompositionRules'}).Count -gt 0) 'missing current route evidence'
    $copy=Clone $fixture;$copy.RouteSpec.StageDesign.TargetStrategies[0].Formation=9
    Assert (@(Get-KcpsLevelingProblems @copy|Where-Object {$_ -match '当前策略不符'}).Count -gt 0) 'mismatched target formation'
    $copy=Clone $fixture;$copy.RouteSpec.StageDesign.RouteCompositionRules[0].MinCount=2
    Assert (@(Get-KcpsLevelingProblems @copy|Where-Object {$_ -match '带路计数'}).Count -gt 0) 'composition count failure'
    $copy=Clone $fixture;$copy.RouteSpec.StageDesign.SelectionPolicy=@{'待练'=@{AllowedCopyNumbers=@(1);MaximumLevelExclusive=99}}
    Assert (@(Get-KcpsLevelingProblems @copy|Where-Object {$_ -match '当前角色策略'}).Count -eq 2) 'explicit copy and level constraints'
    $copy=Clone $fixture;$copy.RouteSpec.StageDesign.FlagshipTraining=@{Required=$true;ExpectedIds=@{([string]$case[1])=700001}}
    Assert (@(Get-KcpsLevelingProblems @copy).Count -eq 0) 'arbitrary declared training fleet'
    $copy=Clone $fixture;$copy.Sortie=$null
    Assert (@(Get-KcpsLevelingProblems @copy|Where-Object {$_ -match '缺少总控或出击'}).Count -eq 1) 'missing sortie failure'
    $copy=Clone $fixture;$copy.RouteSpec.StageDesign.FillAllUsableSlots=$true;$copy.Const=$null
    Assert (@(Get-KcpsLevelingProblems @copy|Where-Object {$_ -match '缺少舰船及装备主数据'}).Count -eq 1) 'leveling still reports missing required const data'
}
foreach ($ordinaryRoute in @($null, @{}, @{ StageDesign = $null }, @{ StageDesign = @{} }, @{ StageDesign = @{ Phase = 'Sortie' } })) {
    Assert (@(Get-KcpsLevelingPreparationProblems -RouteSpec $ordinaryRoute -Const $null).Count -eq 0) 'ordinary routes do not require leveling metadata'
}

# Exercise the validator's actual input-loading branch with synthetic readers.
$validatorText = Get-Content -LiteralPath "$PSScriptRoot/KCPS-ValidateConfig.ps1" -Raw
$inputStart = $validatorText.IndexOf('$start2 = $null', [StringComparison]::Ordinal)
$inputEnd = $validatorText.IndexOf('$exSlotContext =', $inputStart, [StringComparison]::Ordinal)
if ($inputStart -lt 0 -or $inputEnd -le $inputStart) { throw 'Cannot locate validator input-loading block.' }
$loadInputs = [scriptblock]::Create($validatorText.Substring($inputStart, $inputEnd - $inputStart))
function Invoke-SyntheticInputLoading([string]$Mode) {
    $SnapshotPath = if ($Mode -eq 'Snapshot') { 'synthetic snapshot' } else { '' }
    $BaseUrl = 'synthetic reader only'
    $const = @{ Marker = 'stale parent value' }
    $fixtureConst = @{
        Marker = $Mode
        '$ships' = @{}; '$shipTypes' = @{}; '$equips' = @{}
        '$exslotEquips' = @(); '$exslotEquipShips' = @{}; '$equipShip' = @{}
    }
    function Read-KcpsJson {
        param($Path)
        return @{ const = $fixtureConst; ships = @{}; equips = @{}; maps = @{} }
    }
    function Get-PoiJson {
        param($BaseUrl, $Path)
        if ($Mode -eq 'Snapshot') { throw 'Snapshot mode must not query live readers.' }
        if ($Mode -eq 'Offline') { throw 'Synthetic unavailable reader.' }
        return @{ api_mst_ship = @() }
    }
    function Get-PoiData {
        param($BaseUrl, $Type)
        if ($Mode -eq 'Snapshot') { throw 'Snapshot mode must not query live readers.' }
        if ($Mode -eq 'Offline' -or ($Mode -eq 'MissingConst' -and $Type -eq 'const')) { throw 'Synthetic unavailable reader.' }
        if ($Type -eq 'const') { return $fixtureConst }
        return @{}
    }
    . $loadInputs
    return @{ Const = $const; Start2 = $start2 }
}
foreach ($mode in @('Live', 'Snapshot')) {
    $loaded = Invoke-SyntheticInputLoading $mode
    Assert ($loaded.Const.Marker -eq $mode) "$mode provides the current const data"
}
$loaded = Invoke-SyntheticInputLoading 'Offline'
Assert ($null -eq $loaded.Const -and $null -eq $loaded.Start2) 'unavailable readers leave initialized missing data'
$loaded = Invoke-SyntheticInputLoading 'MissingConst'
Assert ($null -eq $loaded.Const -and $null -ne $loaded.Start2) 'missing const does not discard independently available master data'
Write-Output "Passed $tests synthetic leveling checks."
