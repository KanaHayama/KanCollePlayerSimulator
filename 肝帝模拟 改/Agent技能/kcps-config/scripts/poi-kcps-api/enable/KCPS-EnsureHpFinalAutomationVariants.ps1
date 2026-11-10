#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$SourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AutomaticGroupName,

    [Parameter(Mandatory = $true)]
    [string]$SemiAutomaticGroupName,

    [Parameter(Mandatory = $true)]
    [string]$StageLabel,

    [Parameter(Mandatory = $true)]
    [string]$BossPointName,

    [Parameter(Mandatory = $true)]
    [string]$RouteCode,

    [Parameter(Mandatory = $true)]
    [int]$BossConditionValue,

    [string]$RouteSpecPath = (Join-Path $PSScriptRoot '..\data\KCPS-RouteSpecs.json'),

    [Parameter(Mandatory = $true)]
    [string]$SourceRouteId,

    [Parameter(Mandatory = $true)]
    [string]$AutomaticRouteId,

    [Parameter(Mandatory = $true)]
    [string]$SemiAutomaticRouteId,

    [Parameter(Mandatory = $true)]
    [string]$AutomaticPolicyPath,

    [Parameter(Mandatory = $true)]
    [string]$SemiAutomaticPolicyPath,

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

$automaticPolicy = Read-KcpsJson -Path $AutomaticPolicyPath
$semiAutomaticPolicy = Read-KcpsJson -Path $SemiAutomaticPolicyPath
foreach ($policy in @($automaticPolicy, $semiAutomaticPolicy)) {
    foreach ($field in @('LoopLimit','MoraleMinimum','DockingHpThreshold','WaitForNaturalMorale','LandBaseProficiencyChecks','BossNightBattle')) {
        if (-not $policy.Contains($field)) { throw "Automation policy requires explicit $field." }
    }
    if ([int]$policy['LoopLimit'] -lt 1 -or [int]$policy['MoraleMinimum'] -lt 0 -or [int]$policy['MoraleMinimum'] -gt 100 -or
        [double]$policy['DockingHpThreshold'] -lt 0 -or [double]$policy['DockingHpThreshold'] -gt 1 -or
        [int]$policy['BossNightBattle'] -notin @(0,1,2) -or $policy['WaitForNaturalMorale'] -isnot [bool] -or
        $policy['LandBaseProficiencyChecks'] -isnot [System.Collections.IDictionary]) { throw 'Invalid automation policy fields.' }
    if ([int]$policy['MoraleMinimum'] -gt 49 -and $policy['WaitForNaturalMorale']) { throw 'Natural recovery cannot satisfy morale above 49.' }
}
if ([int]$semiAutomaticPolicy['LoopLimit'] -ne 1) { throw 'SemiAutomaticSingleLoop requires LoopLimit=1.' }


function Copy-KcpsValue {
    param([Parameter(Mandatory = $true)][object]$Value)
    $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
}

function Replace-StringsRecursive {
    param(
        [object]$Value,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Replacements
    )

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $Value[$key] = Replace-StringsRecursive -Value $Value[$key] -Replacements $Replacements
        }
        return $Value
    }
    if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            $Value[$index] = Replace-StringsRecursive -Value $Value[$index] -Replacements $Replacements
        }
        return $Value
    }
    if ($Value -is [string]) {
        $text = $Value
        foreach ($key in $Replacements.Keys) {
            $text = $text.Replace([string]$key, [string]$Replacements[$key])
        }
        return $text
    }
    return $Value
}

function Copy-GroupWithNewGuids {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Group)

    $clone = Copy-KcpsValue -Value $Group
    $guidMap = [ordered]@{}
    foreach ($workflow in @($clone['List'])) {
        $oldGuid = [string]$workflow['Guid']
        if ([string]::IsNullOrWhiteSpace($oldGuid)) {
            throw "Workflow '$($workflow['Name'])' has no GUID."
        }
        $guidMap[$oldGuid] = [guid]::NewGuid().ToString()
    }
    Replace-StringsRecursive -Value $clone -Replacements $guidMap
}

function Get-OneWorkflow {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Group,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $matches = @($Group['List'] | Where-Object { [string]$_['Name'] -eq $Name })
    if ($matches.Count -ne 1) {
        throw "Group '$($Group['Name'])' must contain exactly one workflow named '$Name'."
    }
    $matches[0]
}

function Set-MemoSection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Memo,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    $header = "【$Name】"
    $pattern = '(?ms)^' + [regex]::Escape($header) + '\r?\n.*?(?=^【|\z)'
    $replacement = $header + "`n" + $Body.Trim() + "`n`n"
    if ([regex]::IsMatch($Memo, $pattern)) {
        return ([regex]::Replace($Memo, $pattern, $replacement, 1)).TrimEnd()
    }
    return $Memo.TrimEnd() + "`n`n" + $replacement.TrimEnd()
}

function Remove-MemoSection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Memo,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $pattern = '(?ms)^【' + [regex]::Escape($Name) + '】\r?\n.*?(?=^【|\z)'
    [regex]::Replace($Memo, $pattern, '').TrimEnd()
}

function Rename-GroupMode {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Group,
        [Parameter(Mandatory = $true)]
        [string]$FromLabel,
        [Parameter(Mandatory = $true)]
        [string]$ToLabel,
        [Parameter(Mandatory = $true)]
        [string]$NewName
    )

    $replacements = [ordered]@{
        $FromLabel = $ToLabel
        ($FromLabel -replace '\s+', '') = ($ToLabel -replace '\s+', '')
    }
    Replace-StringsRecursive -Value $Group -Replacements $replacements | Out-Null
    $Group['Name'] = $NewName
}

function Set-AutomationFields {
    param([System.Collections.IDictionary]$Group, [ValidateSet('Automatic','SemiAutomatic')][string]$Mode)
    $policy = if ($Mode -eq 'Automatic') { $automaticPolicy } else { $semiAutomaticPolicy }
    $controller = Get-OneWorkflow -Group $Group -Name '总控'
    $sortie = Get-OneWorkflow -Group $Group -Name '出击'
    $docking = Get-OneWorkflow -Group $Group -Name '入渠'
    $memoWorkflow = Get-OneWorkflow -Group $Group -Name '备注'
    $controller['StopIfLoopCountLargerOrEqualThanFlag'] = $true
    $controller['StopIfLoopCountLargerOrEqualThanValue'] = [int]$policy['LoopLimit']
    $controller['SleepUntilMoraleRecoveredFlag'] = [bool]$policy['WaitForNaturalMorale']
    $controller['SleepUntilFlagShipMoraleRecoveredFlag'] = $false
    $controller['SleepUntilMoraleRecoveredValueMorale'] = [int]$policy['MoraleMinimum']
    foreach ($prefix in @('FlagShip','EscortShip')) {
        $sortie["${prefix}MoraleLargerOrEqualThanFlag"] = $true
        $sortie["${prefix}MoraleLargerOrEqualThanValue"] = [int]$policy['MoraleMinimum']
    }
    $docking['LimitHpPercentFlag'] = $true
    $docking['LimitHpPercentMaxValue'] = [double]$policy['DockingHpThreshold']
    foreach ($number in 1..3) {
        if ([int]$sortie["LandBasedAirCorps${number}Action"] -eq 0) { continue }
        if (-not $policy['LandBaseProficiencyChecks'].Contains([string]$number) -or $policy['LandBaseProficiencyChecks'][[string]$number] -isnot [bool]) {
            throw "Automation policy must explicitly declare the proficiency check for active land base $number."
        }
        $sortie["LandBasedAirCorps${number}CheckAnyProficiencyNotFull"] = $policy['LandBaseProficiencyChecks'][[string]$number]
    }
    $bossRows = @($sortie['Strategies'] | Where-Object { [int]$_['Condition']['Type'] -eq 1 -and [int]$_['Condition']['Value'] -eq $BossConditionValue })
    if ($bossRows.Count -ne 1) { throw 'A unique explicit boss strategy is required.' }
    $bossRows[0]['Strategy']['DefaultMidnight'] = [int]$policy['BossNightBattle']
    if ([bool]$sortie['DefaultBossBattleStrategyFlag']) { $sortie['DefaultBossBattleStrategy']['DefaultMidnight'] = [int]$policy['BossNightBattle'] }
    $body = "本次选择 $Mode；循环上限$($policy['LoopLimit'])，士气下限$($policy['MoraleMinimum'])，自然恢复等待$($policy['WaitForNaturalMorale'])。`n" +
        "入渠血量比例阈值$($policy['DockingHpThreshold'])；${BossPointName}点夜战设置$($policy['BossNightBattle'])；陆航熟练度检查按当前明示策略。"
    $memoWorkflow['Memo'] = Set-MemoSection -Memo ([string]$memoWorkflow['Memo']) -Name '自动化模式' -Body $body
    $docking['Memo'] = "本次策略：血量比例低于$($policy['DockingHpThreshold'])时入渠。"
}

$config = Read-KcpsJson -Path $Path
$before = Write-KcpsJson -Value $config
$groups = [System.Collections.ArrayList]::new()
foreach ($group in @(Get-KcpsGroups -Config $config)) {
    [void]$groups.Add($group)
}

$sourceMatches = @($groups | Where-Object {
    [string]$_['Name'] -in @($SourceGroupName, $SemiAutomaticGroupName)
})
if ($sourceMatches.Count -ne 1) {
    throw "Expected one source/semi-automatic group, found $($sourceMatches.Count)."
}
$semiGroup = $sourceMatches[0]
$sourceIndex = $groups.IndexOf($semiGroup)

if ([string]$semiGroup['Name'] -eq $SourceGroupName) {
    Rename-GroupMode `
        -Group $semiGroup `
        -FromLabel "$StageLabel 斩杀" `
        -ToLabel "$StageLabel 半自动斩杀" `
        -NewName $SemiAutomaticGroupName
}
Set-AutomationFields -Group $semiGroup -Mode SemiAutomatic

$automaticMatches = @($groups | Where-Object { [string]$_['Name'] -eq $AutomaticGroupName })
if ($automaticMatches.Count -gt 1) {
    throw "Found more than one automatic group named '$AutomaticGroupName'."
}
if ($automaticMatches.Count -eq 1) {
    $automaticGroup = $automaticMatches[0]
} else {
    $automaticGroup = Copy-GroupWithNewGuids -Group $semiGroup
    Rename-GroupMode `
        -Group $automaticGroup `
        -FromLabel "$StageLabel 半自动斩杀" `
        -ToLabel "$StageLabel 全自动斩杀" `
        -NewName $AutomaticGroupName
}
Set-AutomationFields -Group $automaticGroup -Mode Automatic

$orderedGroups = [System.Collections.ArrayList]::new()
for ($index = 0; $index -lt $groups.Count; $index++) {
    $group = $groups[$index]
    if ([object]::ReferenceEquals($group, $automaticGroup) -or
        [object]::ReferenceEquals($group, $semiGroup)) {
        continue
    }
    if ($index -eq $sourceIndex) {
        [void]$orderedGroups.Add($automaticGroup)
        [void]$orderedGroups.Add($semiGroup)
    }
    [void]$orderedGroups.Add($group)
}
if (-not $orderedGroups.Contains($automaticGroup)) {
    [void]$orderedGroups.Add($automaticGroup)
    [void]$orderedGroups.Add($semiGroup)
}

$after = Write-KcpsJson -Value @($orderedGroups)
$configChanged = $before -ne $after

$routeDatabase = Read-KcpsJson -Path $RouteSpecPath
$routeBefore = Write-KcpsJson -Value $routeDatabase
$routes = [System.Collections.ArrayList]::new()
foreach ($route in @($routeDatabase['Routes'])) {
    [void]$routes.Add($route)
}

$semiRouteMatches = @($routes | Where-Object {
    [string]$_['Id'] -in @($SourceRouteId, $SemiAutomaticRouteId)
})
if ($semiRouteMatches.Count -ne 1) {
    throw "Expected one source/semi-automatic route spec, found $($semiRouteMatches.Count)."
}
$semiRoute = $semiRouteMatches[0]
$semiRouteIndex = $routes.IndexOf($semiRoute)
$semiRoute['Id'] = $SemiAutomaticRouteId
$semiRoute['GroupNameRegex'] = '^' + [regex]::Escape($SemiAutomaticGroupName) + '$'
$semiRoute['Notes'] = "${StageLabel} ${BossPointName}: explicit semi-automatic single-loop policy."
if ($semiRoute['StageDesign'] -isnot [System.Collections.IDictionary]) { throw 'Source route requires StageDesign.' }
foreach ($field in @('MoraleMinimum','DockingHpThreshold','LoopLimit','LandBaseProficiencyChecks','BossNightBattle')) { $semiRoute['StageDesign'][$field] = Copy-KcpsValue $semiAutomaticPolicy[$field] }
$semiRoute['StageDesign']['AutomationMode'] = 'SemiAutomaticSingleLoop'
$semiRoute['RequiredFinalVariants'] = @('Automatic','SemiAutomatic')
$semiRoute['FinalAutomationVariant'] = 'SemiAutomatic'
$semiRoute['FinalAutomationPair'] = "$StageLabel|$BossPointName|$RouteCode"
foreach ($node in @($semiRoute['Nodes'])) {
    if ([int]$node['Value'] -eq $BossConditionValue) {
        $node['ExpectedMidnight'] = [int]$semiAutomaticPolicy['BossNightBattle']
    }
}

$automaticRouteMatches = @($routes | Where-Object { [string]$_['Id'] -eq $AutomaticRouteId })
if ($automaticRouteMatches.Count -gt 1) {
    throw "Found more than one automatic route spec '$AutomaticRouteId'."
}
if ($automaticRouteMatches.Count -eq 1) {
    $automaticRoute = $automaticRouteMatches[0]
} else {
    $automaticRoute = Copy-KcpsValue -Value $semiRoute
}
$automaticRoute['Id'] = $AutomaticRouteId
$automaticRoute['GroupNameRegex'] = '^' + [regex]::Escape($AutomaticGroupName) + '$'
$automaticRoute['Notes'] = "${StageLabel} ${BossPointName}: explicit automatic sortie policy."
foreach ($field in @('MoraleMinimum','DockingHpThreshold','LoopLimit','LandBaseProficiencyChecks','BossNightBattle')) { $automaticRoute['StageDesign'][$field] = Copy-KcpsValue $automaticPolicy[$field] }
$automaticRoute['StageDesign']['AutomationMode'] = if ([int]$automaticPolicy['LoopLimit'] -gt 1) { 'MultiLoop' } else { 'SingleLoop' }
$automaticRoute['RequiredFinalVariants'] = @('Automatic','SemiAutomatic')
$automaticRoute['FinalAutomationVariant'] = 'Automatic'
$automaticRoute['FinalAutomationPair'] = "$StageLabel|$BossPointName|$RouteCode"
foreach ($node in @($automaticRoute['Nodes'])) {
    if ([int]$node['Value'] -eq $BossConditionValue) {
        $node['ExpectedMidnight'] = [int]$automaticPolicy['BossNightBattle']
    }
}

$orderedRoutes = [System.Collections.ArrayList]::new()
for ($index = 0; $index -lt $routes.Count; $index++) {
    $route = $routes[$index]
    if ([object]::ReferenceEquals($route, $automaticRoute) -or
        [object]::ReferenceEquals($route, $semiRoute)) {
        continue
    }
    if ($index -eq $semiRouteIndex) {
        [void]$orderedRoutes.Add($automaticRoute)
        [void]$orderedRoutes.Add($semiRoute)
    }
    [void]$orderedRoutes.Add($route)
}
if (-not $orderedRoutes.Contains($automaticRoute)) {
    [void]$orderedRoutes.Add($automaticRoute)
    [void]$orderedRoutes.Add($semiRoute)
}
$routeDatabase['Routes'] = @($orderedRoutes)
$routeAfter = Write-KcpsJson -Value $routeDatabase
$routeChanged = $routeBefore -ne $routeAfter

if ($configChanged -and -not $CheckOnly) {
    [System.IO.File]::WriteAllText(
        (Resolve-Path -LiteralPath $Path),
        $after + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false))
}
if ($routeChanged -and -not $CheckOnly) {
    Save-KcpsPrivateRoutePlans -Routes @($automaticRoute, $semiRoute) -RemoveRouteIds @($SourceRouteId) | Out-Null
}

[pscustomobject]@{
    Path = (Resolve-Path -LiteralPath $Path).Path
    RouteSpecPath = (Resolve-Path -LiteralPath $RouteSpecPath).Path
    AutomaticGroup = $AutomaticGroupName
    SemiAutomaticGroup = $SemiAutomaticGroupName
    ConfigChanged = $configChanged
    RouteSpecChanged = $routeChanged
    CheckOnly = [bool]$CheckOnly
}
