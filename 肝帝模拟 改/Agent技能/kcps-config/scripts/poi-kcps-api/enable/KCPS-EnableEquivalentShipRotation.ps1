#requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [string]$BaseUrl = '',

    [string]$SnapshotPath,

    [int]$DefaultMoraleThreshold = 33,

    [int]$FailureRetrySleepSeconds = 180,

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

function Test-IdSelection {
    param([hashtable]$Selection)

    if ($null -eq $Selection) { return $false }
    if (-not $Selection.ContainsKey('Type') -or -not $Selection.ContainsKey('Value')) { return $false }
    $type = $Selection['Type']
    if (($type -as [string]) -eq 'Id') { return (($Selection['Value'] -as [string]) -match '^\d+$') }
    try { return ([int]$type -eq 0 -and (($Selection['Value'] -as [string]) -match '^\d+$')) } catch { return $false }
}

function Test-ExtraSlotAvailable {
    param([hashtable]$Ship)

    if (-not $Ship.ContainsKey('api_slot_ex')) { return $false }
    return ([int]$Ship['api_slot_ex'] -ne 0)
}

function Get-ShipName {
    param(
        [hashtable]$Const,
        [hashtable]$Ship
    )

    Get-KcpsConstShipName -Const $Const -ShipConstId ([int]$Ship['api_ship_id'])
}

function New-ShipIdSelection {
    param(
        [int]$ShipId,
        [string]$ShipName
    )

    [ordered]@{
        Type = 0
        Value = [string]$ShipId
        Memo = "[$ShipName ($ShipId)]"
    }
}

function Add-UniqueId {
    param(
        [System.Collections.Generic.List[int]]$List,
        [int]$Id
    )

    if (-not $List.Contains($Id)) {
        [void]$List.Add($Id)
    }
}

function Get-MoraleThresholdForPosition {
    param(
        [hashtable]$SortieWorkflow,
        [int]$Position,
        [int]$DefaultValue
    )

    if ($null -eq $SortieWorkflow) { return $DefaultValue }

    if ($Position -eq 1) {
        if ($SortieWorkflow.ContainsKey('FlagShipMoraleLargerOrEqualThanFlag') -and
            [bool]$SortieWorkflow['FlagShipMoraleLargerOrEqualThanFlag'] -and
            $SortieWorkflow.ContainsKey('FlagShipMoraleLargerOrEqualThanValue')) {
            return [int]$SortieWorkflow['FlagShipMoraleLargerOrEqualThanValue']
        }
    } else {
        if ($SortieWorkflow.ContainsKey('EscortShipMoraleLargerOrEqualThanFlag') -and
            [bool]$SortieWorkflow['EscortShipMoraleLargerOrEqualThanFlag'] -and
            $SortieWorkflow.ContainsKey('EscortShipMoraleLargerOrEqualThanValue')) {
            return [int]$SortieWorkflow['EscortShipMoraleLargerOrEqualThanValue']
        }
    }

    return $DefaultValue
}

function Set-RotationFields {
    param(
        [hashtable]$Position,
        [int]$Threshold
    )

    $max = [Math]::Max(0, $Threshold - 1)
    $Position['ChangeIfMoraleInRangeFlag'] = $true
    $Position['ChangeIfMoraleInRangeValueMin'] = 0
    $Position['ChangeIfMoraleInRangeValueMax'] = $max
    $Position['SkipMoraleInRangeFlag'] = $true
    $Position['SkipMoraleInRangeValueMin'] = 0
    $Position['SkipMoraleInRangeValueMax'] = $max
    $Position['SelectionSortingMethod'] = 1
    $Position['IncludeCurrentShip'] = $false
    $Position['IncludeCurrentSelection'] = $false
    $Position['KeepIfAllSelectionsFailed'] = $false
    $Position['ChangeIfRepairing'] = $true
    $Position['SkipWrongShips'] = $true
    $Position['SkipRepairingShips'] = $true
    $Position['SkipExpeditioningShips'] = $true
    $Position['SkipShipsInOtherFleets'] = $true
}

function Test-RotationFields {
    param(
        [hashtable]$Position,
        [int]$Threshold
    )

    $max = [Math]::Max(0, $Threshold - 1)
    return ([bool]$Position['ChangeIfMoraleInRangeFlag'] -and
        [int]$Position['ChangeIfMoraleInRangeValueMin'] -eq 0 -and
        [int]$Position['ChangeIfMoraleInRangeValueMax'] -eq $max -and
        [bool]$Position['SkipMoraleInRangeFlag'] -and
        [int]$Position['SkipMoraleInRangeValueMin'] -eq 0 -and
        [int]$Position['SkipMoraleInRangeValueMax'] -eq $max -and
        [int]$Position['SelectionSortingMethod'] -eq 1 -and
        -not [bool]$Position['IncludeCurrentShip'] -and
        -not [bool]$Position['IncludeCurrentSelection'] -and
        -not [bool]$Position['KeepIfAllSelectionsFailed'] -and
        [bool]$Position['ChangeIfRepairing'] -and
        [bool]$Position['SkipWrongShips'] -and
        [bool]$Position['SkipRepairingShips'] -and
        [bool]$Position['SkipExpeditioningShips'] -and
        [bool]$Position['SkipShipsInOtherFleets'])
}

function Set-SingleCandidateFields {
    param([hashtable]$Position)

    $Position['ChangeIfMoraleInRangeFlag'] = $false
    $Position['ChangeIfMoraleInRangeValueMin'] = 0
    $Position['ChangeIfMoraleInRangeValueMax'] = 32
    $Position['SkipMoraleInRangeFlag'] = $false
    $Position['SkipMoraleInRangeValueMin'] = 0
    $Position['SkipMoraleInRangeValueMax'] = 32
    $Position['SelectionSortingMethod'] = 2
    $Position['IncludeCurrentShip'] = $false
    $Position['IncludeCurrentSelection'] = $true
    $Position['KeepIfAllSelectionsFailed'] = $false
    $Position['ChangeIfRepairing'] = $false
    $Position['SkipWrongShips'] = $true
    $Position['SkipRepairingShips'] = $false
    $Position['SkipExpeditioningShips'] = $true
    $Position['SkipShipsInOtherFleets'] = $false
}

function Test-SingleCandidateFields {
    param([hashtable]$Position)

    return (-not [bool]$Position['ChangeIfMoraleInRangeFlag'] -and
        -not [bool]$Position['SkipMoraleInRangeFlag'] -and
        [int]$Position['SelectionSortingMethod'] -eq 2 -and
        -not [bool]$Position['IncludeCurrentShip'] -and
        [bool]$Position['IncludeCurrentSelection'] -and
        -not [bool]$Position['KeepIfAllSelectionsFailed'] -and
        -not [bool]$Position['ChangeIfRepairing'] -and
        [bool]$Position['SkipWrongShips'] -and
        -not [bool]$Position['SkipRepairingShips'] -and
        [bool]$Position['SkipExpeditioningShips'] -and
        -not [bool]$Position['SkipShipsInOtherFleets'])
}

function Test-SelectionIdsEqual {
    param(
        [object[]]$Selections,
        [System.Collections.Generic.List[int]]$CandidateIds
    )

    $current = @($Selections | ForEach-Object {
        if (Test-IdSelection -Selection $_) { [int]$_['Value'] } else { $null }
    })
    if ($current.Count -ne $CandidateIds.Count) { return $false }
    for ($i = 0; $i -lt $current.Count; $i++) {
        if ([int]$current[$i] -ne [int]$CandidateIds[$i]) { return $false }
    }
    return $true
}

function Set-RelationalSortieFailureHandling {
    param(
        [hashtable]$Workflow,
        [int]$SleepSeconds
    )

    $Workflow['MinimalSleepSecondsAfterFailureOccuredFlag'] = $true
    $Workflow['MinimalSleepSecondsAfterFailureOccuredValue'] = $SleepSeconds
    $Workflow['StopIfOrganizeBeforeSelectFailed'] = $false
    foreach ($key in @(
        'IgnoreQuestBeforeFailure',
        'IgnoreQuestAfterFailure',
        'IgnoreOrganizeBeforeFailure',
        'IgnoreOrganizeAfterFailure',
        'IgnoreRefitEquipmentBeforeFailure',
        'IgnoreRefitEquipmentAfterFailure'
    )) {
        $Workflow[$key] = $false
    }
    $Workflow['IgnoreSortieFailure'] = $true
    foreach ($prefix in @(
        'QuestBefore',
        'QuestAfter',
        'OrganizeBefore',
        'OrganizeAfter',
        'RefitEquipmentBefore',
        'RefitEquipmentAfter',
        'Sortie'
    )) {
        $Workflow["FinishLoopIf${prefix}FailureFlag"] = $false
        $Workflow["FinishLoopIf${prefix}FailureValueThreshold"] = 1
    }
}

function Test-RelationalSortieFailureHandling {
    param(
        [hashtable]$Workflow,
        [int]$SleepSeconds
    )

    if (-not [bool]$Workflow['MinimalSleepSecondsAfterFailureOccuredFlag'] -or
        [int]$Workflow['MinimalSleepSecondsAfterFailureOccuredValue'] -ne $SleepSeconds -or
        [bool]$Workflow['StopIfOrganizeBeforeSelectFailed'] -or
        -not [bool]$Workflow['IgnoreSortieFailure']) {
        return $false
    }
    foreach ($key in @(
        'IgnoreQuestBeforeFailure',
        'IgnoreQuestAfterFailure',
        'IgnoreOrganizeBeforeFailure',
        'IgnoreOrganizeAfterFailure',
        'IgnoreRefitEquipmentBeforeFailure',
        'IgnoreRefitEquipmentAfterFailure'
    )) {
        if ([bool]$Workflow[$key]) { return $false }
    }
    foreach ($prefix in @(
        'QuestBefore',
        'QuestAfter',
        'OrganizeBefore',
        'OrganizeAfter',
        'RefitEquipmentBefore',
        'RefitEquipmentAfter',
        'Sortie'
    )) {
        if ([bool]$Workflow["FinishLoopIf${prefix}FailureFlag"] -or
            [int]$Workflow["FinishLoopIf${prefix}FailureValueThreshold"] -ne 1) {
            return $false
        }
    }
    return $true
}

$resolvedPaths = @()
$resolved = Resolve-Path -LiteralPath $Path
foreach ($item in $resolved) {
    $target = Get-Item -LiteralPath $item.Path
    if ($target.PSIsContainer) {
        $resolvedPaths += @(Get-ChildItem -LiteralPath $target.FullName -File -Filter '*.conf.json' | Where-Object { Test-KcpsConfigScanPath -Path $_.FullName -ScanRoot $target.FullName } | ForEach-Object { $_.FullName })
    } else {
        $resolvedPaths += $target.FullName
    }
}
$resolvedPaths = @($resolvedPaths | Sort-Object -Unique)

if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
    $snapshot = Read-KcpsJson -Path $SnapshotPath
    foreach ($key in @('const', 'ships')) {
        if (-not $snapshot.ContainsKey($key)) {
            throw "Snapshot is missing required key: $key"
        }
    }
    $const = $snapshot['const']
    $ships = $snapshot['ships']
} else {
    $const = Get-PoiData -BaseUrl $BaseUrl -Type const
    $ships = Get-PoiData -BaseUrl $BaseUrl -Type ships
}

$shipsById = @{}
$equivalentGroups = @{}
foreach ($entry in $ships.GetEnumerator()) {
    $ship = $entry.Value
    $shipId = [int]$ship['api_id']
    $shipsById[[string]$shipId] = $ship

    $constId = [int]$ship['api_ship_id']
    $extra = if (Test-ExtraSlotAvailable -Ship $ship) { '1' } else { '0' }
    # 格纳库增设是舰个体属性（api_onslot_max，仅扩张过的舰有），扩张状态不同的同型舰不等价，否则轮换会静默丢失扩张收益
    $hangar = if ($ship.ContainsKey('api_onslot_max')) { @($ship['api_onslot_max']) -join ',' } else { '' }
    $key = "$constId|$extra|$hangar"
    if (-not $equivalentGroups.ContainsKey($key)) {
        $equivalentGroups[$key] = New-Object 'System.Collections.Generic.List[int]'
    }
    [void]$equivalentGroups[$key].Add($shipId)
}

foreach ($key in @($equivalentGroups.Keys)) {
    $sorted = @($equivalentGroups[$key] | Sort-Object)
    $list = New-Object 'System.Collections.Generic.List[int]'
    foreach ($id in $sorted) { [void]$list.Add([int]$id) }
    $equivalentGroups[$key] = $list
}

$report = @()

foreach ($file in $resolvedPaths) {
    $config = Read-KcpsJson -Path $file
    $groups = Get-KcpsGroups -Config $config
    $fileChanged = $false

    foreach ($group in $groups) {
        if (-not ($group -is [hashtable]) -or -not $group.ContainsKey('List')) { continue }
        $list = @($group['List'])
        $sortie = @($list | Where-Object { ($_ -is [hashtable]) -and (Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleSortieWorkflow') } | Select-Object -First 1)
        if (@($sortie).Count -eq 0) { continue }
        $sortie = $sortie[0]

        $sea = if ($sortie.ContainsKey('Sea')) { [int]$sortie['Sea'] } else { -1 }
        if ($sea -lt 1 -or $sea -gt 7) {
            $report += [pscustomobject]@{
                File = Split-Path -Leaf $file
                Config = $group['Name']
                Action = 'Skipped'
                Detail = "Sea=$sea is not a normal-map sortie. Event maps currently imply tag-locking, so equivalent-ship fatigue rotation was not applied."
            }
            continue
        }

        $organizeWorkflows = @($list | Where-Object { ($_ -is [hashtable]) -and (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') })
        foreach ($organize in $organizeWorkflows) {
            $posIndex = 0
            foreach ($position in @($organize['Positions'])) {
                $posIndex++
                $selections = @($position['Selections'])
                if ($selections.Count -eq 0) { continue }
                if (@($selections | Where-Object { -not (Test-IdSelection -Selection $_) }).Count -gt 0) {
                    if ($selections.Count -eq 1) {
                        $singleOk = Test-SingleCandidateFields -Position $position
                        if (-not $singleOk -and -not $CheckOnly) {
                            Set-SingleCandidateFields -Position $position
                            $fileChanged = $true
                        }
                        if (-not $singleOk) {
                            $report += [pscustomobject]@{
                                File = Split-Path -Leaf $file
                                Config = $group['Name']
                                Workflow = $organize['Name']
                                Position = $posIndex
                                Action = $(if ($CheckOnly) { 'WouldCleanup' } else { 'CleanedUp' })
                                Detail = 'Single non-ID selector retained; fixed-position repairing-ship fields were normalized for pre-sortie 捞出.'
                            }
                        }
                        continue
                    }
                    $report += [pscustomobject]@{
                        File = Split-Path -Leaf $file
                        Config = $group['Name']
                        Workflow = $organize['Name']
                        Position = $posIndex
                        Action = 'Skipped'
                        Detail = 'Position has multiple non-ID ship selections; automatic equivalent expansion was not applied.'
                    }
                    continue
                }

                $candidateIds = New-Object 'System.Collections.Generic.List[int]'
                $primarySelection = @($selections | Select-Object -First 1)[0]
                $primaryId = [int]$primarySelection['Value']
                if (-not $shipsById.ContainsKey([string]$primaryId)) {
                    Add-UniqueId -List $candidateIds -Id $primaryId
                } else {
                    $primary = $shipsById[[string]$primaryId]
                    $constId = [int]$primary['api_ship_id']
                    $extra = if (Test-ExtraSlotAvailable -Ship $primary) { '1' } else { '0' }
                    $key = "$constId|$extra"

                    Add-UniqueId -List $candidateIds -Id $primaryId
                    if ($equivalentGroups.ContainsKey($key)) {
                        foreach ($id in $equivalentGroups[$key]) {
                            Add-UniqueId -List $candidateIds -Id ([int]$id)
                        }
                    }
                }

                $threshold = Get-MoraleThresholdForPosition -SortieWorkflow $sortie -Position $posIndex -DefaultValue $DefaultMoraleThreshold
                if ($candidateIds.Count -le 1) {
                    $alreadySingleOk = (Test-SelectionIdsEqual -Selections $selections -CandidateIds $candidateIds) -and
                        (Test-SingleCandidateFields -Position $position)
                    if (-not $alreadySingleOk) {
                        $newSelections = @()
                        foreach ($id in $candidateIds) {
                            if ($shipsById.ContainsKey([string]$id)) {
                                $ship = $shipsById[[string]$id]
                                $name = Get-ShipName -Const $const -Ship $ship
                            } else {
                                $name = "#$id"
                            }
                            $newSelections += New-ShipIdSelection -ShipId $id -ShipName $name
                        }
                        if (-not $CheckOnly) {
                            $position['Selections'] = @($newSelections)
                            Set-SingleCandidateFields -Position $position
                            $fileChanged = $true
                        }
                        $report += [pscustomobject]@{
                            File = Split-Path -Leaf $file
                            Config = $group['Name']
                            Workflow = $organize['Name']
                            Position = $posIndex
                            Action = $(if ($CheckOnly) { 'WouldCleanup' } else { 'CleanedUp' })
                            Threshold = $threshold
                            CandidateCount = $candidateIds.Count
                            CandidateIds = ($candidateIds -join ',')
                        }
                    }
                    continue
                }

                $alreadyOk = (Test-SelectionIdsEqual -Selections $selections -CandidateIds $candidateIds) -and
                    (Test-RotationFields -Position $position -Threshold $threshold)
                $newSelections = @()
                foreach ($id in $candidateIds) {
                    if ($shipsById.ContainsKey([string]$id)) {
                        $ship = $shipsById[[string]$id]
                        $name = Get-ShipName -Const $const -Ship $ship
                    } else {
                        $name = "#$id"
                    }
                    $newSelections += New-ShipIdSelection -ShipId $id -ShipName $name
                }

                if (-not $alreadyOk -and -not $CheckOnly) {
                    $position['Selections'] = @($newSelections)
                    Set-RotationFields -Position $position -Threshold $threshold
                    $fileChanged = $true
                }

                $report += [pscustomobject]@{
                    File = Split-Path -Leaf $file
                    Config = $group['Name']
                    Workflow = $organize['Name']
                    Position = $posIndex
                    Action = $(if ($alreadyOk) { 'AlreadyOk' } elseif ($CheckOnly) { 'WouldUpdate' } else { 'Updated' })
                    Threshold = $threshold
                    CandidateCount = $candidateIds.Count
                    CandidateIds = ($candidateIds -join ',')
                }
            }
        }

        $relationalWorkflows = @($list | Where-Object {
            ($_ -is [hashtable]) -and
            (Test-KcpsWorkflowType -Workflow $_ -TypeName 'RelationalSortieWorkflow') -and
            $_.ContainsKey('OrganizeBeforeWorkflows') -and
            @($_['OrganizeBeforeWorkflows']).Count -gt 0
        })
        foreach ($rel in $relationalWorkflows) {
            $needsUpdate = -not (Test-RelationalSortieFailureHandling -Workflow $rel -SleepSeconds $FailureRetrySleepSeconds)
            if ($needsUpdate) {
                if (-not $CheckOnly) {
                    Set-RelationalSortieFailureHandling -Workflow $rel -SleepSeconds $FailureRetrySleepSeconds
                    $fileChanged = $true
                }
                $report += [pscustomobject]@{
                    File = Split-Path -Leaf $file
                    Config = $group['Name']
                    Workflow = $rel['Name']
                    Action = $(if ($CheckOnly) { 'WouldUpdateRetry' } else { 'UpdatedRetry' })
                    Detail = "Only sortie-workflow failures are ignored so control advances to the next loop; all bounded FinishLoopIf* failure jumps are disabled, with at least $FailureRetrySleepSeconds seconds before retry."
                }
            }
        }
    }

    if ($fileChanged) {
        Write-KcpsJson -Value $config | Set-Content -LiteralPath $file -Encoding UTF8
    }
}

[pscustomobject]@{
    PathCount = $resolvedPaths.Count
    CheckOnly = [bool]$CheckOnly
    Updates = @($report | Where-Object { $_.Action -like 'Updated*' -or $_.Action -like 'WouldUpdate*' }).Count
    Report = @($report)
} | ConvertTo-KcpsJsonOutput -Depth 20
