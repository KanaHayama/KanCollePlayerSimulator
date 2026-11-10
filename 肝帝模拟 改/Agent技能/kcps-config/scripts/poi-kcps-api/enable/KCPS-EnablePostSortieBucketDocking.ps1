#requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [int]$DefaultMoraleMax = 32,

    [double]$DamagedHpPercentMax = 0.99,

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

function Get-FleetSelectionValue {
    param([int]$Fleet)

    switch ($Fleet) {
        1 { return 0x1 -bor 0x2 }
        2 { return 0x4 -bor 0x8 }
        3 { return 0x10 -bor 0x20 }
        4 { return 0x40 -bor 0x80 }
        default { throw "Unsupported sortie fleet '$Fleet'." }
    }
}

function Test-CombinedSortieGroup {
    param([System.Collections.IDictionary]$Group)

    return @($Group['List'] | Where-Object {
        ($_ -is [System.Collections.IDictionary]) -and
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicCombinedFleetWorkflow')
    }).Count -gt 0
}

function Get-SortieMoraleBucketMax {
    param(
        [System.Collections.IDictionary]$Sortie,
        [int]$FallbackMax
    )

    $thresholds = @()
    if ((Test-MapKey -Map $Sortie -Key 'FlagShipMoraleLargerOrEqualThanFlag') -and [bool]$Sortie['FlagShipMoraleLargerOrEqualThanFlag']) {
        $thresholds += [int]$Sortie['FlagShipMoraleLargerOrEqualThanValue']
    }
    if ((Test-MapKey -Map $Sortie -Key 'EscortShipMoraleLargerOrEqualThanFlag') -and [bool]$Sortie['EscortShipMoraleLargerOrEqualThanFlag']) {
        $thresholds += [int]$Sortie['EscortShipMoraleLargerOrEqualThanValue']
    }

    if ($thresholds.Count -eq 0) { return $FallbackMax }
    $derived = ([int](@($thresholds | Measure-Object -Minimum).Minimum)) - 1
    if ($derived -lt 0) { return 0 }
    return [Math]::Min($FallbackMax, $derived)
}

function New-RelatedWorkflowRef {
    param(
        [System.Collections.IDictionary]$Workflow,
        [bool]$IgnoreTriggerFailure = $false
    )

    [ordered]@{
        Guid = $Workflow['Guid']
        Enabled = $true
        IgnoreTriggerFailure = $IgnoreTriggerFailure
    }
}

function Test-RelatedWorkflowRef {
    param(
        [object]$Refs,
        [string]$Guid
    )

    foreach ($ref in @($Refs)) {
        if ($null -eq $ref -or -not (Test-MapKey -Map $ref -Key 'Guid')) { continue }
        if ($ref['Guid'] -eq $Guid -and (-not (Test-MapKey -Map $ref -Key 'Enabled') -or [bool]$ref['Enabled'])) {
            return $true
        }
    }
    return $false
}

function Set-RelatedWorkflowRef {
    param(
        [System.Collections.IDictionary]$Controller,
        [string]$Key,
        [System.Collections.IDictionary]$Workflow,
        [bool]$IgnoreTriggerFailure = $false
    )

    if (-not (Test-MapKey -Map $Controller -Key $Key) -or $null -eq $Controller[$Key]) {
        $Controller[$Key] = @()
    }

    $refs = @($Controller[$Key])
    $changed = $false
    $found = $false
    $updated = @()
    foreach ($ref in $refs) {
        if ($null -eq $ref -or -not (Test-MapKey -Map $ref -Key 'Guid')) { continue }
        if ($ref['Guid'] -eq $Workflow['Guid']) {
            $found = $true
            if (-not (Test-MapKey -Map $ref -Key 'Enabled') -or [bool]$ref['Enabled'] -ne $true) {
                $ref['Enabled'] = $true
                $changed = $true
            }
            if (-not (Test-MapKey -Map $ref -Key 'IgnoreTriggerFailure') -or [bool]$ref['IgnoreTriggerFailure'] -ne $IgnoreTriggerFailure) {
                $ref['IgnoreTriggerFailure'] = $IgnoreTriggerFailure
                $changed = $true
            }
        }
        $updated += $ref
    }
    if (-not $found) {
        $updated += (New-RelatedWorkflowRef -Workflow $Workflow -IgnoreTriggerFailure $IgnoreTriggerFailure)
        $changed = $true
    }

    if ($changed) {
        $Controller[$Key] = @($updated)
    }
    return $changed
}

function Set-RelatedWorkflowListExact {
    param(
        [System.Collections.IDictionary]$Controller,
        [string]$Key,
        [object[]]$Workflows,
        [bool]$DefaultIgnoreTriggerFailure = $false
    )

    $existingByGuid = @{}
    foreach ($ref in @($Controller[$Key])) {
        if ($null -ne $ref -and (Test-MapKey -Map $ref -Key 'Guid')) {
            $existingByGuid[[string]$ref['Guid']] = $ref
        }
    }

    $newRefs = @()
    foreach ($workflow in @($Workflows)) {
        if ($null -eq $workflow -or -not (Test-MapKey -Map $workflow -Key 'Guid')) { continue }
        $guid = [string]$workflow['Guid']
        if ($existingByGuid.ContainsKey($guid)) {
            $ref = $existingByGuid[$guid]
            $ignore = if (Test-MapKey -Map $ref -Key 'IgnoreTriggerFailure') { [bool]$ref['IgnoreTriggerFailure'] } else { $DefaultIgnoreTriggerFailure }
            $newRefs += [ordered]@{
                Guid = $guid
                Enabled = $true
                IgnoreTriggerFailure = $ignore
            }
        } else {
            $newRefs += (New-RelatedWorkflowRef -Workflow $workflow -IgnoreTriggerFailure $DefaultIgnoreTriggerFailure)
        }
    }

    $oldComparable = @()
    foreach ($ref in @($Controller[$Key])) {
        if ($null -eq $ref -or -not (Test-MapKey -Map $ref -Key 'Guid')) { continue }
        $oldComparable += "$($ref['Guid'])|$($ref['Enabled'])|$($ref['IgnoreTriggerFailure'])"
    }
    $newComparable = @($newRefs | ForEach-Object { "$($_['Guid'])|$($_['Enabled'])|$($_['IgnoreTriggerFailure'])" })
    $changed = (($oldComparable -join "`n") -ne ($newComparable -join "`n"))
    if ($changed) {
        $Controller[$Key] = @($newRefs)
    }
    return $changed
}

function Set-RelatedWorkflowThreshold {
    param(
        [System.Collections.IDictionary]$Controller,
        [string]$RefsKey,
        [string]$ThresholdKey,
        [int]$ExpectedCompletionCount = -1
    )

    $enabledCount = if ($ExpectedCompletionCount -ge 0) {
        $ExpectedCompletionCount
    } else {
        @($Controller[$RefsKey] | Where-Object {
            $null -ne $_ -and (-not (Test-MapKey -Map $_ -Key 'Enabled') -or [bool]$_['Enabled'])
        }).Count
    }
    $threshold = [Math]::Max(1, $enabledCount)
    if (-not (Test-MapKey -Map $Controller -Key $ThresholdKey) -or [int]$Controller[$ThresholdKey] -ne $threshold) {
        $Controller[$ThresholdKey] = $threshold
        return $true
    }
    return $false
}

function New-BucketDockingWorkflow {
    param(
        [int]$FleetSelectionValue,
        [int]$MoraleMax,
        [double]$HpPercentMax
    )

    [ordered]@{
        Type = 'KancollePlayerSimulatorKai.BasicDockingWorkflow, KancollePlayerSimulatorKai, Version=1.5.2.1, Culture=neutral, PublicKeyToken=null'
        Guid = [guid]::NewGuid().ToString()
        Name = '扔桶'
        Memo = '出击后对目标舰队中疲劳且受损的舰船使用高速修复，恢复血量并减少疲劳等待。'
        EnableOnLoad = $false
        LimitFleetFlag = $true
        LimitFleetValue = $FleetSelectionValue
        LimitHpPercentFlag = $true
        LimitHpPercentMinValue = 0.0
        LimitHpPercentMaxValue = $HpPercentMax
        LimitRepairTimeFlag = $false
        LimitRepairTimeMinValue = '00:00:00'
        LimitRepairTimeMaxValue = '4.04:00:00'
        LimitMoraleFlag = $true
        LimitMoraleMinValue = 0
        LimitMoraleMaxValue = $MoraleMax
        LimitLevelFlag = $false
        LimitLevelMinValue = 1
        LimitLevelMaxValue = 999
        LimitLockStateFlag = $false
        LimitLockStateValueLocked = $true
        LimitLockStateValueUnlocked = $false
        LimitDockingStateFlag = $false
        LimitDockingStateValueDocking = $true
        LimitDockingStateValueIdle = $false
        LimitShipTypeFlag = $false
        LimitShipTypeValue = @()
        EnableScriptFilter = $false
        FilterFunctionName = 'OnFilter'
        SelectStrategy = 0
        Docks = 15
        ForceDocking = $true
        InstantRepair = $true
        ApplyInstantRepairToDockingShips = $true
        InstantRepairTimeLimit = '00:00:00'
        AutoStop = $true
        Repeat = $true
        SkipExpeditioningShips = $true
        RefreshDataTaskPriority = 0
        DockingTaskPriority = 0
        DelaySecondsAfterRepairFinishedBase = 0
        DelaySecondsAfterRepairFinishedRandomMax = -60
        SetNonSetDockingTimersAtFirst = $true
        WaitHomeAtFirst = $false
        RefreshDataBeforeDocking = $false
        ReturnRoomAtLast = $false
        EnableScript = $true
        Script = $null
        TriggerOnEnabled = $false
    }
}

function New-SalvageDockingWorkflow {
    param([int]$FleetSelectionValue)

    [ordered]@{
        Type = 'KancollePlayerSimulatorKai.BasicDockingWorkflow, KancollePlayerSimulatorKai, Version=1.5.2.1, Culture=neutral, PublicKeyToken=null'
        Guid = [guid]::NewGuid().ToString()
        Name = '捞出'
        EnableOnLoad = $false
        LimitFleetFlag = $true
        LimitFleetValue = $FleetSelectionValue
        LimitHpPercentFlag = $false
        LimitHpPercentMinValue = 0.0
        LimitHpPercentMaxValue = 1.0
        LimitRepairTimeFlag = $false
        LimitRepairTimeMinValue = '00:00:00'
        LimitRepairTimeMaxValue = '4.04:00:00'
        LimitMoraleFlag = $false
        LimitMoraleMinValue = 0
        LimitMoraleMaxValue = 100
        LimitLevelFlag = $false
        LimitLevelMinValue = 1
        LimitLevelMaxValue = 999
        LimitLockStateFlag = $false
        LimitLockStateValueLocked = $true
        LimitLockStateValueUnlocked = $false
        LimitDockingStateFlag = $true
        LimitDockingStateValueDocking = $true
        LimitDockingStateValueIdle = $false
        LimitShipTypeFlag = $false
        LimitShipTypeValue = $null
        EnableScriptFilter = $false
        FilterFunctionName = 'OnFilter'
        SelectStrategy = 0
        Docks = 15
        ForceDocking = $false
        InstantRepair = $true
        ApplyInstantRepairToDockingShips = $true
        InstantRepairTimeLimit = '00:00:00'
        AutoStop = $true
        Repeat = $true
        SkipExpeditioningShips = $true
        RefreshDataTaskPriority = 0
        DockingTaskPriority = 0
        DelaySecondsAfterRepairFinishedBase = 0
        DelaySecondsAfterRepairFinishedRandomMax = -60
        SetNonSetDockingTimersAtFirst = $true
        WaitHomeAtFirst = $false
        RefreshDataBeforeDocking = $false
        ReturnRoomAtLast = $false
        EnableScript = $true
        Script = $null
        TriggerOnEnabled = $false
        Memo = '出击前对已编入目标舰队且正在入渠的船使用高速修复。'
    }
}

function Set-SalvageDockingWorkflow {
    param(
        [System.Collections.IDictionary]$Workflow,
        [int]$FleetSelectionValue
    )

    $expected = New-SalvageDockingWorkflow -FleetSelectionValue $FleetSelectionValue
    $expected.Remove('Guid')
    $changed = $false
    foreach ($key in $expected.Keys) {
        if (-not (Test-MapKey -Map $Workflow -Key $key) -or $Workflow[$key] -ne $expected[$key]) {
            $Workflow[$key] = $expected[$key]
            $changed = $true
        }
    }
    return $changed
}

function Set-BucketDockingWorkflow {
    param(
        [System.Collections.IDictionary]$Workflow,
        [int]$FleetSelectionValue,
        [int]$MoraleMax,
        [double]$HpPercentMax
    )

    $expected = @{
        Name = '扔桶'
        EnableOnLoad = $false
        LimitFleetFlag = $true
        LimitFleetValue = $FleetSelectionValue
        LimitHpPercentFlag = $true
        LimitHpPercentMinValue = 0.0
        LimitHpPercentMaxValue = $HpPercentMax
        LimitRepairTimeFlag = $false
        LimitRepairTimeMinValue = '00:00:00'
        LimitRepairTimeMaxValue = '4.04:00:00'
        LimitMoraleFlag = $true
        LimitMoraleMinValue = 0
        LimitMoraleMaxValue = $MoraleMax
        LimitLevelFlag = $false
        LimitLevelMinValue = 1
        LimitLevelMaxValue = 999
        LimitLockStateFlag = $false
        LimitLockStateValueLocked = $true
        LimitLockStateValueUnlocked = $false
        LimitDockingStateFlag = $false
        LimitDockingStateValueDocking = $true
        LimitDockingStateValueIdle = $false
        LimitShipTypeFlag = $false
        EnableScriptFilter = $false
        FilterFunctionName = 'OnFilter'
        SelectStrategy = 0
        Docks = 15
        ForceDocking = $true
        InstantRepair = $true
        ApplyInstantRepairToDockingShips = $true
        InstantRepairTimeLimit = '00:00:00'
        AutoStop = $true
        Repeat = $true
        SkipExpeditioningShips = $true
        RefreshDataTaskPriority = 0
        DockingTaskPriority = 0
        DelaySecondsAfterRepairFinishedBase = 0
        DelaySecondsAfterRepairFinishedRandomMax = -60
        SetNonSetDockingTimersAtFirst = $true
        WaitHomeAtFirst = $false
        RefreshDataBeforeDocking = $false
        ReturnRoomAtLast = $false
        EnableScript = $true
        Script = $null
        TriggerOnEnabled = $false
    }

    $changed = $false
    foreach ($key in $expected.Keys) {
        if (-not (Test-MapKey -Map $Workflow -Key $key) -or $Workflow[$key] -ne $expected[$key]) {
            $Workflow[$key] = $expected[$key]
            $changed = $true
        }
    }
    # The KCPS JSON round trip canonicalizes an unrestricted empty list as null.
    # Treat a present null as valid so repeated -CheckOnly runs remain idempotent.
    if (-not (Test-MapKey -Map $Workflow -Key 'LimitShipTypeValue')) {
        $Workflow['LimitShipTypeValue'] = $null
        $changed = $true
    }
    return $changed
}

function Set-KcpsSortieWorkflowOrder {
    param([System.Collections.IDictionary]$Group)

    $desired = @('备注', '说明', '总控', '抑制其他配置', '接任务', '编成', '组成联合舰队', '改装', '入渠', '捞出', '补给', '出击', '扔桶', '通知通关')
    $rank = @{}
    for ($i = 0; $i -lt $desired.Count; $i++) {
        $rank[$desired[$i]] = $i
    }

    $list = @($Group['List'])
    $indexed = @()
    for ($i = 0; $i -lt $list.Count; $i++) {
        $name = [string]$list[$i]['Name']
        $itemRank = if ($rank.ContainsKey($name)) {
            $rank[$name]
        } elseif ($name -match '^编成') {
            [double]$rank['编成']
        } elseif ($name -match '^改装') {
            [double]$rank['改装']
        } elseif ($name -match '^入渠') {
            [double]$rank['入渠']
        } elseif ($name -match '^捞出') {
            [double]$rank['捞出']
        } elseif ($name -match '^补给') {
            [double]$rank['补给']
        } elseif ($name -match '^陆航休息[123]$') {
            [double]$rank['出击'] + 0.5
        } elseif ($name -match '^通知') {
            [double]$rank['通知通关']
        } else {
            1000 + $i
        }
        $indexed += [pscustomobject]@{
            Rank = $itemRank
            Index = $i
            Item = $list[$i]
        }
    }
    $newList = @($indexed | Sort-Object Rank, Index | ForEach-Object { $_.Item })

    $oldOrder = @($list | ForEach-Object { if ($_ -is [System.Collections.IDictionary] -and (Test-MapKey -Map $_ -Key 'Guid')) { $_['Guid'] } else { '' } })
    $newOrder = @($newList | ForEach-Object { if ($_ -is [System.Collections.IDictionary] -and (Test-MapKey -Map $_ -Key 'Guid')) { $_['Guid'] } else { '' } })
    if (($oldOrder -join '|') -ne ($newOrder -join '|')) {
        $Group['List'] = @($newList)
        return $true
    }
    return $false
}

$resolvedPaths = @()
$resolved = Resolve-Path -LiteralPath $Path
foreach ($item in $resolved) {
    $target = Get-Item -LiteralPath $item.Path
    if ($target.PSIsContainer) {
        $resolvedPaths += @(Get-ChildItem -LiteralPath $target.FullName -Filter '*.conf.json' -File -Recurse | Where-Object { Test-KcpsConfigScanPath -Path $_.FullName -ScanRoot $target.FullName } | ForEach-Object { $_.FullName })
    } else {
        $resolvedPaths += $target.FullName
    }
}
$resolvedPaths = @($resolvedPaths | Sort-Object -Unique)

$report = @()

foreach ($file in $resolvedPaths) {
    $config = Read-KcpsJson -Path $file
    $groups = Get-KcpsGroups -Config $config
    $fileChanged = $false

    foreach ($group in $groups) {
        if (-not ($group -is [System.Collections.IDictionary]) -or -not (Test-MapKey -Map $group -Key 'List')) { continue }
        $list = @($group['List'])
        $sortie = @($list | Where-Object { ($_ -is [System.Collections.IDictionary]) -and (Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleSortieWorkflow') } | Select-Object -First 1)
        $controller = @($list | Where-Object { ($_ -is [System.Collections.IDictionary]) -and (Test-KcpsWorkflowType -Workflow $_ -TypeName 'RelationalSortieWorkflow') } | Select-Object -First 1)
        if ($sortie.Count -eq 0 -or $controller.Count -eq 0) { continue }
        $sortie = $sortie[0]
        $controller = $controller[0]

        $fleet = if (Test-MapKey -Map $sortie -Key 'Fleet') { [int]$sortie['Fleet'] } elseif (Test-MapKey -Map $controller -Key 'Fleet') { [int]$controller['Fleet'] } else { 1 }
        $fleetSelection = if (Test-CombinedSortieGroup -Group $group) {
            (Get-FleetSelectionValue -Fleet 1) -bor (Get-FleetSelectionValue -Fleet 2)
        } else {
            Get-FleetSelectionValue -Fleet $fleet
        }
        $moraleMax = Get-SortieMoraleBucketMax -Sortie $sortie -FallbackMax $DefaultMoraleMax

        $salvage = @($list | Where-Object { ($_ -is [System.Collections.IDictionary]) -and (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicDockingWorkflow') -and $_['Name'] -eq '捞出' } | Select-Object -First 1)
        $action = 'Unchanged'
        if ($salvage.Count -eq 0) {
            $salvage = New-SalvageDockingWorkflow -FleetSelectionValue $fleetSelection
            $action = 'SalvageAdded'
            $fileChanged = $true
            $list = @($list + $salvage)
            $group['List'] = $list
        } else {
            $salvage = $salvage[0]
            if (Set-SalvageDockingWorkflow -Workflow $salvage -FleetSelectionValue $fleetSelection) {
                $action = 'SalvageUpdated'
                $fileChanged = $true
            }
        }

        $bucket = @($list | Where-Object { ($_ -is [System.Collections.IDictionary]) -and (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicDockingWorkflow') -and $_['Name'] -eq '扔桶' } | Select-Object -First 1)
        if ($bucket.Count -eq 0) {
            $bucket = New-BucketDockingWorkflow -FleetSelectionValue $fleetSelection -MoraleMax $moraleMax -HpPercentMax $DamagedHpPercentMax
            if ($action -eq 'Unchanged') { $action = 'BucketAdded' }
            $fileChanged = $true
            $list = @($list + $bucket)
            $group['List'] = $list
        } else {
            $bucket = $bucket[0]
            if (Set-BucketDockingWorkflow -Workflow $bucket -FleetSelectionValue $fleetSelection -MoraleMax $moraleMax -HpPercentMax $DamagedHpPercentMax) {
                if ($action -eq 'Unchanged') { $action = 'BucketUpdated' }
                $fileChanged = $true
            }
        }

        $allDocking = @($list | Where-Object { ($_ -is [System.Collections.IDictionary]) -and (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicDockingWorkflow') })
        $preSortieDocking = @($allDocking | Where-Object { $_['Name'] -ne '扔桶' })
        $combinedFleet = @($list | Where-Object {
            ($_ -is [System.Collections.IDictionary]) -and
            (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicCombinedFleetWorkflow')
        } | Select-Object -First 1)
        $preSortieOperations = @()
        if ($combinedFleet.Count -gt 0) {
            $preSortieOperations += $combinedFleet[0]
        }
        $preSortieOperations += $preSortieDocking

        if (Set-RelatedWorkflowListExact -Controller $controller -Key 'DockingBeforeWorkflows' -Workflows $preSortieOperations -DefaultIgnoreTriggerFailure $false) {
            if ($action -eq 'Unchanged') { $action = 'DockingBeforeLinked' }
            $fileChanged = $true
        }
        # 组成联合舰队借用出击前入渠阶段触发，但不会发送入渠完成事件。
        if (Set-RelatedWorkflowThreshold -Controller $controller -RefsKey 'DockingBeforeWorkflows' `
                -ThresholdKey 'DockingBeforeFinishedEventThreshold' `
                -ExpectedCompletionCount $preSortieDocking.Count) {
            if ($action -eq 'Unchanged') { $action = 'DockingBeforeThresholdUpdated' }
            $fileChanged = $true
        }

        if (Set-RelatedWorkflowListExact -Controller $controller -Key 'DockingAfterWorkflows' -Workflows @($bucket) -DefaultIgnoreTriggerFailure $false) {
            if ($action -eq 'Unchanged') { $action = 'DockingAfterLinked' }
            $fileChanged = $true
        }
        if (Set-RelatedWorkflowThreshold -Controller $controller -RefsKey 'DockingAfterWorkflows' -ThresholdKey 'DockingAfterFinishedEventThreshold') {
            if ($action -eq 'Unchanged') { $action = 'DockingAfterThresholdUpdated' }
            $fileChanged = $true
        }

        foreach ($dock in $allDocking) {
            if (Set-RelatedWorkflowRef -Controller $controller -Key 'AutoStoppedDisableWorkflows' -Workflow $dock -IgnoreTriggerFailure $false) {
                if ($action -eq 'Unchanged') { $action = 'AutoStopDisableLinked' }
                $fileChanged = $true
            }
        }

        if (Set-KcpsSortieWorkflowOrder -Group $group) {
            if ($action -eq 'Unchanged') { $action = 'Reordered' }
            $fileChanged = $true
            $list = @($group['List'])
        }

        $report += [pscustomobject]@{
            File = Split-Path -Leaf $file
            Config = $group['Name']
            Fleet = $fleet
            FleetSelectionValue = $fleetSelection
            MoraleMax = $moraleMax
            HpPercentMax = $DamagedHpPercentMax
            DockingBeforeRefCount = @($controller['DockingBeforeWorkflows']).Count
            DockingBeforeThreshold = [int]$controller['DockingBeforeFinishedEventThreshold']
            DockingAfterRefCount = @($controller['DockingAfterWorkflows']).Count
            DockingAfterThreshold = [int]$controller['DockingAfterFinishedEventThreshold']
            AutoStoppedDisableDockingCount = @($allDocking | Where-Object { Test-RelatedWorkflowRef -Refs $controller['AutoStoppedDisableWorkflows'] -Guid $_['Guid'] }).Count
            Action = $action
        }
    }

    if ($fileChanged -and -not $CheckOnly) {
        Write-KcpsJson -Value $config | Set-Content -LiteralPath $file -Encoding UTF8
    }
}

[pscustomobject]@{
    PathCount = $resolvedPaths.Count
    CheckOnly = [bool]$CheckOnly
    Changes = @($report | Where-Object { $_.Action -ne 'Unchanged' }).Count
    Results = @($report)
} | ConvertTo-Json -Depth 20
