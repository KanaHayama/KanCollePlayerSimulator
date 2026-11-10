#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/KCPS-FarmingValidation.ps1"
. "$PSScriptRoot/../analyze/KCPS-FarmingAnalysis.ps1"
$script:checks = 0
function Assert($ok, $name) {
    if (-not $ok) { throw $name }
    $script:checks++
}
$maps = @{'11' = @{api_cleared=1}}
$route = @{StageDesign=@{Phase='Farming';AutomationMode='MultiLoop';DropTargets=@('Target A','Target (B)');PostClearRequiredMaps=@(11)}}
$ctl = @{StopIfGetShipFlag=$true;StopIfGetShipValueShipName='^(Target\ A|Target\ \(B\))$';StopIfLoopCountLargerOrEqualThanFlag=$true;StopIfLoopCountLargerOrEqualThanValue=30}
$sortie = @{MapHpInRangeFlag=$false}
function Problems { @(Get-KcpsFarmingProblems -RouteSpec $route -Controller $ctl -Sortie $sortie -Maps $maps) }
Assert (@(Problems).Count -eq 0) 'valid farming'
foreach ($target in $route.StageDesign.DropTargets) { Assert ([regex]::IsMatch($target,$ctl.StopIfGetShipValueShipName)) 'any target matches' }
foreach ($other in @('Common','Target AB','Target B','','Old Target A')) { Assert (-not [regex]::IsMatch($other,$ctl.StopIfGetShipValueShipName)) 'unrelated drop does not match' }
$ctl.StopIfGetShipValueShipName='.*'
Assert (@(Problems).Count -gt 0) 'unanchored any ship rejected'
$ctl.StopIfGetShipValueShipName='^(Target\ A|Target\ \(B\))$'
$sortie.MapHpInRangeFlag=$true
Assert (@(Problems).Count -gt 0) 'stale gauge rejected'
$sortie.MapHpInRangeFlag=$false
$ctl.StopIfBossFlagshipSunkFlag=$true
Assert (@(Problems).Count -gt 0) 'stale mission stop rejected'
$ctl.Remove('StopIfBossFlagshipSunkFlag')
$ctl.StopIfLoopCountLargerOrEqualThanValue=1
Assert (@(Problems).Count -gt 0) 'one loop rejected'
$ctl.StopIfLoopCountLargerOrEqualThanValue=30
$maps['11'].api_cleared=0
Assert (@(Problems).Count -gt 0) 'uncleared map rejected'
$maps.Clear()
Assert (@(Problems).Count -gt 0) 'missing map rejected'
$route.StageDesign.Phase='Grinding'
Assert (@(Problems).Count -eq 0) 'other phases unchanged'
Assert ((Get-KcpsResupplyCost -Missing 20 -Married $true) -eq 17) 'married fuel'
Assert ((Get-KcpsResupplyCost -Missing 26 -Married $true) -eq 22) 'married ammo floor'
Assert ((Get-KcpsResupplyCost -Missing 20 -Married $false) -eq 20) 'unmarried supply'
Assert ((Get-KcpsResupplyCost -Missing 1 -Married $true) -eq 1) 'minimum one'
Assert ((Get-KcpsResupplyCost -Missing 0 -Married $true) -eq 0) 'no missing supply'
$fighter=@{api_type=@(0,0,6);api_tyku=12;api_houk=9;api_houm=9}
Assert ((Get-KcpsDefensePlaneAirPower -Master $fighter) -eq 50) 'carrier hit evasion not interceptor stats'
$local=@{api_type=@(0,0,48);api_tyku=11;api_houk=6;api_houm=5}
Assert ((Get-KcpsDefensePlaneAirPower -Master $local) -eq 114) 'interceptor stats apply'
$recon=@{api_type=@(0,0,9);api_tyku=2;api_houk=9;api_houm=9}
Assert ((Get-KcpsDefensePlaneAirPower -Master $recon -ProficiencyBonus ([math]::Sqrt(12))) -eq 7) 'recon four aircraft'
Assert ((Get-KcpsDefensePlaneAirPower -Master $fighter -AircraftCount 0 -ProficiencyBonus 25) -eq 0) 'empty squadron no proficiency'
"PASS: $script:checks checks"
