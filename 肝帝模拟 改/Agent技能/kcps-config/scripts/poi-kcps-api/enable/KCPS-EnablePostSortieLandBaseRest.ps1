#requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

function Get-KcpsInputFiles {
    param([string]$InputPath)

    $resolved = Resolve-Path -LiteralPath $InputPath
    $item = Get-Item -LiteralPath $resolved.Path
    if ($item.PSIsContainer) {
        return @(Get-ChildItem -LiteralPath $item.FullName -File -Filter '*.conf.json' -Recurse | Where-Object { Test-KcpsConfigScanPath -Path $_.FullName -ScanRoot $item.FullName })
    }
    return @($item)
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

function New-LandBaseRestWorkflow {
    param(
        [int]$Sea,
        [int]$Area,
        [int]$Corps,
        [string]$Name
    )

    [ordered]@{
        Type = 'KancollePlayerSimulatorKai.BasicOutfitLandBasedAirCorpWorkflow, KancollePlayerSimulatorKai, Version=1.5.2.1, Culture=neutral, PublicKeyToken=null'
        Guid = [guid]::NewGuid().ToString()
        Name = $Name
        EnableOnLoad = $false
        Sea = $Sea
        Area = $Area
        Corps = $Corps
        SuccessIfAirCorpNotAvailable = $true
        SetAirplanes = $false
        SetAction = $true
        Action = 4
        Resupply = $true
        ResupplySquadrons = 15
        LandBasedAirCorps1CheckFatigue = $false
        RefreshDataTaskPriority = 0
        OutfitLandBasedAirCorpTaskPriority = 0
        WaitHomeAtFirst = $false
        RefreshDataBefore = $false
        ReturnRoomAtLast = $false
        EnableScript = $true
        Script = $null
        TriggerOnEnabled = $false
    }
}

function Set-LandBaseRestWorkflow {
    param(
        [System.Collections.IDictionary]$Workflow,
        [int]$Sea,
        [int]$Area,
        [int]$Corps,
        [string]$Name
    )

    $changed = $false
    $expected = [ordered]@{
        Name = $Name
        EnableOnLoad = $false
        Sea = $Sea
        Area = $Area
        Corps = $Corps
        SuccessIfAirCorpNotAvailable = $true
        SetAirplanes = $false
        SetAction = $true
        Action = 4
        Resupply = $true
        ResupplySquadrons = 15
        LandBasedAirCorps1CheckFatigue = $false
        RefreshDataTaskPriority = 0
        OutfitLandBasedAirCorpTaskPriority = 0
        WaitHomeAtFirst = $false
        RefreshDataBefore = $false
        ReturnRoomAtLast = $false
        EnableScript = $true
        Script = $null
        TriggerOnEnabled = $false
    }

    foreach ($entry in $expected.GetEnumerator()) {
        $old = if (Test-MapKey -Map $Workflow -Key $entry.Key) { $Workflow[$entry.Key] } else { $null }
        if ($old -ne $entry.Value) {
            $Workflow[$entry.Key] = $entry.Value
            $changed = $true
        }
    }
    return $changed
}

function Get-UsedLandBaseCorps {
    param([System.Collections.IDictionary]$Sortie)

    $used = @()
    foreach ($corps in 1..3) {
        $key = "LandBasedAirCorps$($corps)Action"
        if (-not (Test-MapKey -Map $Sortie -Key $key)) { continue }
        $action = [int]$Sortie[$key]
        if ($action -in 1, 2) {
            $used += [pscustomobject]@{
                Corps = $corps
                Action = $action
            }
        }
    }
    return @($used)
}

function Get-LandBaseRestName {
    param([int]$Corps)

    return "陆航休息$Corps"
}

function Test-LandBaseRestName {
    param([string]$Name)

    return $Name -match '^(?:陆航休息(?:[123]|（[一二三]队）)|翻牌(?:[123]|（[一二三]队）)?)$'
}

function Get-WorkflowByGuid {
    param(
        [object[]]$List,
        [string]$Guid
    )

    foreach ($workflow in @($List)) {
        if ($null -ne $workflow -and (Test-MapKey -Map $workflow -Key 'Guid') -and $workflow['Guid'] -eq $Guid) {
            return $workflow
        }
    }
    return $null
}

function Set-SupplyAfterRefs {
    param(
        [System.Collections.IDictionary]$Controller,
        [object[]]$List,
        [object[]]$RestWorkflows
    )

    $changed = $false
    $oldRefs = @($Controller['SupplyAfterWorkflows'])
    $newRefs = @()
    foreach ($ref in $oldRefs) {
        if ($null -eq $ref -or -not (Test-MapKey -Map $ref -Key 'Guid')) { continue }
        $workflow = Get-WorkflowByGuid -List $List -Guid ([string]$ref['Guid'])
        # 已从配置列表移除的陆航休息单元会留下悬空引用，修复时一并清理。
        if ($null -eq $workflow) { continue }
        if ($null -ne $workflow -and (Test-KcpsWorkflowType -Workflow $workflow -TypeName 'BasicOutfitLandBasedAirCorpWorkflow') -and (Test-LandBaseRestName -Name ([string]$workflow['Name']))) {
            continue
        }
        $newRefs += $ref
    }
    foreach ($workflow in @($RestWorkflows)) {
        $newRefs += (New-RelatedWorkflowRef -Workflow $workflow -IgnoreTriggerFailure $false)
    }

    $oldComparable = @($oldRefs | Where-Object { $null -ne $_ -and (Test-MapKey -Map $_ -Key 'Guid') } | ForEach-Object { "$($_['Guid'])|$($_['Enabled'])|$($_['IgnoreTriggerFailure'])" })
    $newComparable = @($newRefs | ForEach-Object { "$($_['Guid'])|$($_['Enabled'])|$($_['IgnoreTriggerFailure'])" })
    if (($oldComparable -join "`n") -ne ($newComparable -join "`n")) {
        $Controller['SupplyAfterWorkflows'] = @($newRefs)
        $changed = $true
    }

    $supplyCount = 0
    foreach ($ref in @($newRefs)) {
        if ($null -eq $ref -or -not (Test-MapKey -Map $ref -Key 'Guid')) { continue }
        if ((Test-MapKey -Map $ref -Key 'Enabled') -and -not [bool]$ref['Enabled']) { continue }
        $workflow = Get-WorkflowByGuid -List $List -Guid ([string]$ref['Guid'])
        if ($null -ne $workflow -and (Test-KcpsWorkflowType -Workflow $workflow -TypeName 'BasicSupplyFleetWorkflow')) {
            $supplyCount++
        }
    }
    if (-not (Test-MapKey -Map $Controller -Key 'SupplyAfterFinishedEventThreshold') -or [int]$Controller['SupplyAfterFinishedEventThreshold'] -ne $supplyCount) {
        $Controller['SupplyAfterFinishedEventThreshold'] = $supplyCount
        $changed = $true
    }

    return $changed
}

function Set-AutoStoppedDisableRefs {
    param(
        [System.Collections.IDictionary]$Controller,
        [object[]]$List,
        [object[]]$RestWorkflows
    )

    $oldRefs = @($Controller['AutoStoppedDisableWorkflows'])
    $newRefs = @()
    foreach ($ref in $oldRefs) {
        if ($null -eq $ref -or -not (Test-MapKey -Map $ref -Key 'Guid')) { continue }
        $workflow = Get-WorkflowByGuid -List $List -Guid ([string]$ref['Guid'])
        if ($null -eq $workflow) { continue }
        if ((Test-KcpsWorkflowType -Workflow $workflow -TypeName 'BasicOutfitLandBasedAirCorpWorkflow') -and
            (Test-LandBaseRestName -Name ([string]$workflow['Name']))) {
            continue
        }
        $newRefs += $ref
    }
    foreach ($workflow in @($RestWorkflows)) {
        $newRefs += (New-RelatedWorkflowRef -Workflow $workflow -IgnoreTriggerFailure $false)
    }

    $oldComparable = @($oldRefs | Where-Object { $null -ne $_ -and (Test-MapKey -Map $_ -Key 'Guid') } | ForEach-Object { "$($_['Guid'])|$($_['Enabled'])|$($_['IgnoreTriggerFailure'])" })
    $newComparable = @($newRefs | ForEach-Object { "$($_['Guid'])|$($_['Enabled'])|$($_['IgnoreTriggerFailure'])" })
    if (($oldComparable -join "`n") -eq ($newComparable -join "`n")) { return $false }

    $Controller['AutoStoppedDisableWorkflows'] = @($newRefs)
    return $true
}

function Set-RestWorkflowsInList {
    param(
        [System.Collections.IDictionary]$Group,
        [System.Collections.IDictionary]$Sortie,
        [object[]]$RestWorkflows
    )

    $list = @($Group['List'])
    $withoutRest = @($list | Where-Object {
        -not ((Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOutfitLandBasedAirCorpWorkflow') -and (Test-LandBaseRestName -Name ([string]$_['Name'])))
    })

    $sortieIndex = -1
    for ($i = 0; $i -lt $withoutRest.Count; $i++) {
        if ((Test-MapKey -Map $withoutRest[$i] -Key 'Guid') -and $withoutRest[$i]['Guid'] -eq $Sortie['Guid']) {
            $sortieIndex = $i
            break
        }
    }
    if ($sortieIndex -lt 0) {
        $Group['List'] = @($withoutRest + $RestWorkflows)
        return $true
    }

    $newList = @()
    if ($sortieIndex -ge 0) {
        $newList += @($withoutRest[0..$sortieIndex])
    }
    $newList += @($RestWorkflows)
    if ($sortieIndex + 1 -lt $withoutRest.Count) {
        $newList += @($withoutRest[($sortieIndex + 1)..($withoutRest.Count - 1)])
    }

    $oldComparable = @($list | ForEach-Object { if (Test-MapKey -Map $_ -Key 'Guid') { $_['Guid'] } else { $_['Name'] } })
    $newComparable = @($newList | ForEach-Object { if (Test-MapKey -Map $_ -Key 'Guid') { $_['Guid'] } else { $_['Name'] } })
    if (($oldComparable -join "`n") -ne ($newComparable -join "`n")) {
        $Group['List'] = @($newList)
        return $true
    }
    return $false
}

$files = Get-KcpsInputFiles -InputPath $Path
$changeRows = @()
$totalChanges = 0

foreach ($file in $files) {
    $config = Read-KcpsJson -Path $file.FullName
    $groups = Get-KcpsGroups -Config $config
    $fileChanged = $false

    foreach ($group in $groups) {
        $list = @($group['List'])
        $controllers = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'RelationalSortieWorkflow' } | Select-Object -First 1)
        $sorties = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleSortieWorkflow' } | Select-Object -First 1)
        if ($controllers.Count -eq 0 -or $sorties.Count -eq 0) { continue }
        $controller = $controllers[0]
        $sortie = $sorties[0]

        $usedCorps = @(Get-UsedLandBaseCorps -Sortie $sortie)
        if ($usedCorps.Count -eq 0) { continue }

        if (-not (Test-MapKey -Map $sortie -Key 'Sea') -or -not (Test-MapKey -Map $sortie -Key 'Area')) {
            Write-Warning "跳过配置 '$($group['Name'])'：出击执行单元缺少 Sea/Area 字段，避免生成 Sea=0 的错误陆航休息执行单元"
            continue
        }
        $sea = [int]$sortie['Sea']
        $area = [int]$sortie['Area']
        $existingRest = @($list | Where-Object {
            (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOutfitLandBasedAirCorpWorkflow') -and (Test-LandBaseRestName -Name ([string]$_['Name']))
        })
        $existingByCorps = @{}
        foreach ($workflow in $existingRest) {
            if (Test-MapKey -Map $workflow -Key 'Corps') {
                $existingByCorps[[int]$workflow['Corps']] = $workflow
            }
        }

        $restWorkflows = @()
        foreach ($entry in $usedCorps) {
            $name = Get-LandBaseRestName -Corps ([int]$entry.Corps)
            if ($existingByCorps.ContainsKey([int]$entry.Corps)) {
                $workflow = $existingByCorps[[int]$entry.Corps]
                if (Set-LandBaseRestWorkflow -Workflow $workflow -Sea $sea -Area $area -Corps ([int]$entry.Corps) -Name $name) {
                    $fileChanged = $true
                    $totalChanges++
                }
            } else {
                $workflow = New-LandBaseRestWorkflow -Sea $sea -Area $area -Corps ([int]$entry.Corps) -Name $name
                $fileChanged = $true
                $totalChanges++
            }
            $restWorkflows += $workflow
        }

        if (Set-RestWorkflowsInList -Group $group -Sortie $sortie -RestWorkflows $restWorkflows) {
            $fileChanged = $true
            $totalChanges++
            $list = @($group['List'])
        }
        if (Set-SupplyAfterRefs -Controller $controller -List $list -RestWorkflows $restWorkflows) {
            $fileChanged = $true
            $totalChanges++
        }
        if (Set-AutoStoppedDisableRefs -Controller $controller -List $list -RestWorkflows $restWorkflows) {
            $fileChanged = $true
            $totalChanges++
        }

        $changeRows += [pscustomobject]@{
            File = $file.Name
            Config = $group['Name']
            UsedCorps = @($usedCorps | ForEach-Object { $_.Corps })
            RestWorkflows = @($restWorkflows | ForEach-Object { $_['Name'] })
            SupplyAfterThreshold = $controller['SupplyAfterFinishedEventThreshold']
        }
    }

    if ($fileChanged -and -not $CheckOnly) {
        Write-KcpsJson -Value $config | Set-Content -LiteralPath $file.FullName -Encoding UTF8
    }
}

[pscustomobject]@{
    PathCount = @($files).Count
    CheckOnly = [bool]$CheckOnly
    Changes = $totalChanges
    GroupsWithLandBaseRest = @($changeRows)
} | ConvertTo-KcpsJsonOutput -Depth 20
