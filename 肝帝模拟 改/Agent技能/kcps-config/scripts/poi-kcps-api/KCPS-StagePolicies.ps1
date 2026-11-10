#requires -Version 7.0

function Get-KcpsStageDesignProblems {
    param([hashtable]$Group, [hashtable]$Sortie, [hashtable[]]$RelationalWorkflows, [hashtable]$Spec)
    $problems = @()
    $design = $Spec['StageDesign']
    if ($null -eq $design) { return $problems }
    if ($design -isnot [System.Collections.IDictionary]) { return @('StageDesign must be an object.') }
    $controllers = @($RelationalWorkflows | Where-Object { $null -ne $_ })
    if ($controllers.Count -ne 1) { return @('StageDesign requires exactly one relational sortie controller.') }
    $controller = $controllers[0]
    $mode = [string]$design['AutomationMode']
    if ($mode -notin @('Configured', 'MultiLoop', 'SingleLoop', 'SemiAutomaticSingleLoop')) {
        $problems += "Unsupported StageDesign.AutomationMode '$mode'."
    }
    if (-not $design.Contains('LoopLimit') -or [int]$design['LoopLimit'] -lt 1) {
        $problems += 'StageDesign.LoopLimit must explicitly specify a positive loop limit.'
    } else {
        $loop = [int]$design['LoopLimit']
        if (-not [bool]$controller['StopIfLoopCountLargerOrEqualThanFlag'] -or [int]$controller['StopIfLoopCountLargerOrEqualThanValue'] -ne $loop) {
            $problems += "StageDesign requires loop limit $loop; the controller differs."
        }
        if (($mode -eq 'MultiLoop' -and $loop -le 1) -or ($mode -in @('SingleLoop','SemiAutomaticSingleLoop') -and $loop -ne 1)) {
            $problems += "StageDesign loop limit $loop does not match AutomationMode '$mode'."
        }
    }
    $redFatigue = [string]$design['FatigueMode'] -eq 'RedFatigue'
    foreach ($prefix in @('FlagShip','EscortShip')) {
        if ($redFatigue) {
            if ([bool]$Sortie["${prefix}MoraleLargerOrEqualThanFlag"]) { $problems += 'RedFatigue requires disabled sortie morale checks.' }
        } elseif ($design.Contains('MoraleMinimum')) {
            $morale = [int]$design['MoraleMinimum']
            if ($morale -lt 0 -or $morale -gt 100) { $problems += 'MoraleMinimum must be between 0 and 100.' }
            if (-not [bool]$Sortie["${prefix}MoraleLargerOrEqualThanFlag"] -or [int]$Sortie["${prefix}MoraleLargerOrEqualThanValue"] -ne $morale) {
                $problems += "StageDesign $prefix morale minimum $morale does not match the sortie."
            }
        }
    }
    if ($design.Contains('DockingHpThreshold')) {
        $dockName = if ($design.Contains('DockingWorkflowName')) { [string]$design['DockingWorkflowName'] } else { '入渠' }
        $docks = @($Group['List'] | Where-Object { (Test-KcpsWorkflowType $_ 'BasicDockingWorkflow') -and [string]$_['Name'] -eq $dockName })
        $threshold = [double]$design['DockingHpThreshold']
        if ($threshold -lt 0 -or $threshold -gt 1) { $problems += 'DockingHpThreshold must be between 0 and 1.' }
        if ($docks.Count -ne 1) { $problems += "StageDesign requires a unique docking workflow '$dockName'." }
        elseif (-not [bool]$docks[0]['LimitHpPercentFlag'] -or [math]::Abs([double]$docks[0]['LimitHpPercentMaxValue'] - $threshold) -gt 0.0001) {
            $problems += "StageDesign docking threshold $threshold differs from the workflow."
        }
    }
    if ($design.Contains('BossFlagshipSinkStop') -and [bool]$controller['StopIfEnemyFlagShipSunkFlag'] -ne [bool]$design['BossFlagshipSinkStop']) {
        $problems += 'StageDesign.BossFlagshipSinkStop differs from the controller.'
    }
    foreach ($n in 1..3) {
        if ([int]$Sortie["LandBasedAirCorps${n}Action"] -eq 0) { continue }
        $checks = $design['LandBaseProficiencyChecks']
        if ($checks -isnot [System.Collections.IDictionary] -or -not $checks.Contains([string]$n) -or $checks[[string]$n] -isnot [bool]) {
            $problems += "StageDesign.LandBaseProficiencyChecks must explicitly declare boolean state for active land base $n."
        } elseif ([bool]$Sortie["LandBasedAirCorps${n}CheckAnyProficiencyNotFull"] -ne $checks[[string]$n]) {
            $problems += "StageDesign proficiency check for land base $n differs from the sortie."
        }
    }
    foreach ($kind in @('Normal','Boss')) {
        if (-not [bool]$Sortie["${kind}SupportExpedition"]) { continue }
        $checks = $design['SupportMoraleChecks']
        if ($checks -isnot [System.Collections.IDictionary] -or -not $checks.Contains($kind) -or $checks[$kind] -isnot [bool]) {
            $problems += "StageDesign.SupportMoraleChecks must declare boolean state for $kind support."
        } elseif ([bool]$Sortie["${kind}SupportExpeditionCheckMorale"] -ne $checks[$kind]) {
            $problems += "StageDesign $kind support morale check differs from the sortie."
        }
    }
    if ($design.Contains('BossNightBattle')) {
        $night = [int]$design['BossNightBattle']
        if ($night -notin @(0,1,2)) { $problems += 'StageDesign.BossNightBattle must be 0, 1 or 2.' }
        $bossStrategies = @($Sortie['Strategies'] | ForEach-Object {
            if ($null -ne $_ -and $null -ne $_['Strategy'] -and [bool]$_['Strategy']['Boss']) { $_['Strategy'] }
            elseif ($null -ne $_ -and $null -ne $_['Strategy'] -and [string]$_['Strategy']['Memo'] -match '(?i)Boss|ボス|首领|首領') { $_['Strategy'] }
        })
        if ([bool]$Sortie['DefaultBossBattleStrategyFlag'] -and $null -ne $Sortie['DefaultBossBattleStrategy']) { $bossStrategies += $Sortie['DefaultBossBattleStrategy'] }
        if ($bossStrategies.Count -eq 0) { $problems += 'BossNightBattle was declared but no boss strategy is identified.' }
        foreach ($strategy in $bossStrategies) {
            if ([int]$strategy['DefaultMidnight'] -ne $night) { $problems += 'StageDesign.BossNightBattle differs from a boss strategy.' }
        }
    }
    return $problems
}
