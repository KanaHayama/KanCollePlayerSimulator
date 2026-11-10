#requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [string]$BaseUrl = '',

    [string]$SnapshotPath,

    [switch]$NoThrow
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"
. "$PSScriptRoot\KCPS-SupportRotationValidation.ps1"
. "$PSScriptRoot\KCPS-TerminalBattleValidation.ps1"
. "$PSScriptRoot\KCPS-FarmingValidation.ps1"
. "$PSScriptRoot\KCPS-LevelingValidation.ps1"

$config = Read-KcpsJson -Path $Path
$groups = @(Get-KcpsGroups -Config $config)
if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
    $snapshot = Read-KcpsJson -Path $SnapshotPath
    foreach ($key in @('const', 'ships', 'equips', 'fleets', 'maps')) {
        if (-not $snapshot.ContainsKey($key)) {
            throw "Snapshot is missing required key: $key"
        }
    }
    $const = $snapshot['const']
    $ships = $snapshot['ships']
    $equips = $snapshot['equips']
    $fleets = @($snapshot['fleets'])
    $maps = $snapshot['maps']
} else {
    $const = Get-PoiData -Type const -BaseUrl $BaseUrl
    $ships = Get-PoiData -Type ships -BaseUrl $BaseUrl
    $equips = Get-PoiData -Type equips -BaseUrl $BaseUrl
    $fleets = @(Get-PoiData -Type fleets -BaseUrl $BaseUrl)
    $maps = Get-PoiData -Type maps -BaseUrl $BaseUrl
}
$masterEquips = Get-KcpsConstEquips -Const $const
$masterShips = Get-KcpsConstShips -Const $const
$masterEquipByName = @{}
foreach ($masterEquipment in @($masterEquips.Values)) {
    $equipmentName = [string]$masterEquipment['api_name']
    if (-not [string]::IsNullOrWhiteSpace($equipmentName)) {
        $masterEquipByName[$equipmentName] = $masterEquipment
    }
}
$routeSpecPath = Join-Path $PSScriptRoot '..\data\KCPS-RouteSpecs.json'
$routeSpecs = @()
if (Test-Path -LiteralPath $routeSpecPath) {
    $routeSpecDatabase = Read-KcpsJson -Path $routeSpecPath
    $routeSpecs = @($routeSpecDatabase['Routes'])
}
$landBasedAirCorpsRadiusEvidencePath = Join-Path $PSScriptRoot '..\data\KCPS-LandBasedAirCorpsTargetRadii.json'
if (-not (Test-Path -LiteralPath $landBasedAirCorpsRadiusEvidencePath)) {
    throw "缺少独立陆航目标点航程证据表：$landBasedAirCorpsRadiusEvidencePath"
}
$landBasedAirCorpsRadiusEvidenceDatabase = Read-KcpsJson -Path $landBasedAirCorpsRadiusEvidencePath
$landBasedAirCorpsRadiusEvidenceRoutes = $landBasedAirCorpsRadiusEvidenceDatabase['Routes']
if (-not ($landBasedAirCorpsRadiusEvidenceRoutes -is [System.Collections.IDictionary])) {
    throw '独立陆航目标点航程证据表的 Routes 必须是以路线规格 Id 为键的对象。'
}
$landBasedAirCorps = @()
if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
    if ($snapshot.ContainsKey('landBasedAirCorps')) {
        $landBasedAirCorps = @($snapshot['landBasedAirCorps'])
    }
} else {
    try {
        $landBasedAirCorps = @(Get-PoiData -Type landBasedAirCorps -BaseUrl $BaseUrl)
    } catch {
        $landBasedAirCorps = @()
    }
}
$copyAudit = @(Get-KcpsOwnedShipCopyAudit -Const $const -Ships $ships -Fleets $fleets)
$copyById = @{}
foreach ($row in $copyAudit) { $copyById[[string]$row.Id] = $row }

function Get-EventMemoSection {
    param(
        [string]$Memo,
        [string]$Name
    )

    return Get-KcpsMemoSection -Memo $Memo -Name $Name
}

function Get-EventMemoDisplayWidth {
    param([string]$Text)

    $width = 0
    foreach ($character in $Text.ToCharArray()) {
        if ([int]$character -le 0x7f) {
            $width++
        } else {
            $width += 2
        }
    }
    return $width
}

function Get-EventSortieIdentityCheckerSpec {
    param([System.Collections.IDictionary]$Sortie)

    return Get-KcpsSortieIdentityCheckerSpec -Sortie $Sortie
}

function Get-EventMemoLandBasePlan {
    param([string]$Memo)

    return Get-KcpsMemoLandBasePlan -Memo $Memo
}

function Get-EventLandBasePlanConsistencyProblems {
    param(
        [System.Collections.IDictionary]$Sortie,
        [System.Collections.IDictionary]$CheckerSpec,
        [System.Collections.IDictionary]$RouteSpec,
        [string]$Memo
    )

    return @(Get-KcpsLandBasePlanConsistencyProblems `
        -Sortie $Sortie `
        -CheckerSpec $CheckerSpec `
        -RouteSpec $RouteSpec `
        -Memo $Memo)
}

function Get-EventLandBaseRequiredRadiusFromMemo {
    param(
        [string]$LandBaseText,
        [ValidateRange(1, 3)]
        [int]$Corps
    )

    $labels = switch ($Corps) {
        1 { @('第一基地航空队', '第1基地航空队', '第一队', '第1队', '一队') }
        2 { @('第二基地航空队', '第2基地航空队', '第二队', '第2队', '二队') }
        3 { @('第三基地航空队', '第3基地航空队', '第三队', '第3队', '三队') }
    }
    $radiusPattern = '(?:所需航程|航程要求|需要航程|目标点(?:所需)?半径|所需半径|航程)[^0-9]{0,12}(?<radius>\d+)'
    foreach ($line in @($LandBaseText -split "`r?`n")) {
        if (-not ($labels | Where-Object { $line -match [regex]::Escape($_) })) { continue }
        $match = [regex]::Match($line, $radiusPattern)
        if ($match.Success) { return [int]$match.Groups['radius'].Value }
    }
    return $null
}

function Get-EventPointAirStateSpec {
    param(
        [System.Collections.IDictionary]$Workflow,
        [ValidateSet('Probe', 'Counter')]
        [string]$Kind
    )

    if ($null -eq $Workflow) { return $null }
    $marker = if ($Kind -eq 'Probe') {
        'KCPS_POINT_AIR_STATE_PROBE_SPEC'
    } else {
        'KCPS_POINT_AIR_STATE_COUNTER_SPEC'
    }
    $metadataMatch = [regex]::Match(
        [string]$Workflow['Script'],
        ('(?m)^# ' + $marker + ' (?<json>\{.*\})\s*$')
    )
    if (-not $metadataMatch.Success) { return $null }
    try {
        return ($metadataMatch.Groups['json'].Value | ConvertFrom-Json -AsHashtable)
    } catch {
        return $null
    }
}

function Get-EventOwnedShipById {
    param(
        [Parameter(Mandatory)]$OwnedShips,
        [Parameter(Mandatory)][int]$ShipId
    )

    if ($OwnedShips -is [System.Collections.IDictionary]) {
        if ($OwnedShips.ContainsKey([string]$ShipId)) { return $OwnedShips[[string]$ShipId] }
        if ($OwnedShips.ContainsKey($ShipId)) { return $OwnedShips[$ShipId] }
        return $null
    }
    return @($OwnedShips | Where-Object { [int]$_['api_id'] -eq $ShipId }) | Select-Object -First 1
}

function Get-EventRefitRowsForFixedPosition {
    param(
        [Parameter(Mandatory)][object[]]$RefitWorkflows,
        [Parameter(Mandatory)][int]$Fleet,
        [Parameter(Mandatory)][int]$Position,
        [Parameter(Mandatory)][int]$ShipId
    )

    return @(
        foreach ($refit in $RefitWorkflows) {
            foreach ($shipRefit in @($refit['Ships'])) {
                if ([int]$shipRefit['Fleet'] -ne $Fleet) { continue }
                $byPosition = [int]$shipRefit['SelectMethod'] -eq 0 -and
                    [int]$shipRefit['SelectValue'] -eq $Position
                $byId = [int]$shipRefit['SelectMethod'] -eq 3 -and
                    [int]$shipRefit['SelectValue'] -eq $ShipId
                if ($byPosition -or $byId) { $shipRefit }
            }
        }
    )
}

function Get-EventFixedRefitCoverageProblems {
    param(
        [Parameter(Mandatory)][object[]]$Workflows,
        [Parameter(Mandatory)]$OwnedShips,
        [Parameter(Mandatory)][System.Collections.IDictionary]$MasterShips
    )

    $problems = @()
    $refits = @($Workflows | Where-Object {
        Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicRefitEquipmentWorkflow'
    })
    foreach ($organize in @($Workflows | Where-Object {
        Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow'
    })) {
        $fleet = [int]$organize['Fleet']
        $positions = @($organize['Positions'])
        for ($index = 0; $index -lt $positions.Count; $index++) {
            $fixedSelections = @($positions[$index]['Selections'] | Where-Object {
                [int]$_['Type'] -eq 0 -and [string]$_['Value'] -match '^\d+$'
            })
            if ($fixedSelections.Count -ne 1 -or @($positions[$index]['Selections']).Count -ne 1) { continue }

            $position = $index + 1
            $shipId = [int]$fixedSelections[0]['Value']
            $ownedShip = Get-EventOwnedShipById -OwnedShips $OwnedShips -ShipId $shipId
            if ($null -eq $ownedShip) {
                $problems += "第${fleet}舰队第${position}位固定舰ID $shipId 不在当前账号中，无法验证改装完整性。"
                continue
            }
            $masterId = [string]$ownedShip['api_ship_id']
            if (-not $MasterShips.ContainsKey($masterId)) {
                $problems += "第${fleet}舰队第${position}位固定舰ID $shipId 缺少舰船基础数据，无法验证改装完整性。"
                continue
            }
            $shipName = [string]$MasterShips[$masterId]['api_name']
            $rows = @(Get-EventRefitRowsForFixedPosition -RefitWorkflows $refits -Fleet $fleet -Position $position -ShipId $shipId)
            if ($rows.Count -eq 0) {
                $problems += "第${fleet}舰队第${position}位${shipName}($shipId)没有对应的改装行。"
                continue
            }
            if ($rows.Count -gt 1) {
                $problems += "第${fleet}舰队第${position}位${shipName}($shipId)匹配到$($rows.Count)条改装行，目标不唯一。"
                continue
            }

            $shipRefit = $rows[0]
            if ([int]$shipRefit['SelectMethod'] -ne 3 -or [int]$shipRefit['SelectValue'] -ne $shipId) {
                $problems += "第${fleet}舰队第${position}位${shipName}($shipId)的改装仍按位置定位；活动固定舰必须按舰船ID定位。"
            }
            if ([bool]$shipRefit['IgnoreNoShipMatched']) {
                $problems += "第${fleet}舰队第${position}位${shipName}($shipId)的改装允许找不到舰船时静默跳过。"
            }
            $allowedEmptySlots = @()
            $refitMemo = [string]$shipRefit['Memo']
            if ($refitMemo -match 'KCPS_ALLOW_EMPTY_SLOTS') {
                $allowEmptyMatch = [regex]::Match(
                    $refitMemo,
                    '(?m)^KCPS_ALLOW_EMPTY_SLOTS=(?<Slots>\d+(?:,\d+)*);\s*REASON=(?<Reason>.+)$'
                )
                if (-not $allowEmptyMatch.Success) {
                    $problems += "第${fleet}舰队第${position}位${shipName}($shipId)的有意空槽声明格式错误。"
                } else {
                    $allowedEmptySlots = @($allowEmptyMatch.Groups['Slots'].Value.Split(',') | ForEach-Object { [int]$_ })
                    if ([string]::IsNullOrWhiteSpace($allowEmptyMatch.Groups['Reason'].Value)) {
                        $problems += "第${fleet}舰队第${position}位${shipName}($shipId)的有意空槽声明没有填写理由。"
                    }
                }
            }
            $slotRows = @($shipRefit['Slots'])
            $normalSlotCount = [int]$MasterShips[$masterId]['api_slot_num']
            foreach ($allowedSlot in $allowedEmptySlots) {
                if ($allowedSlot -ne 6 -and ($allowedSlot -lt 1 -or $allowedSlot -gt $normalSlotCount)) {
                    $problems += "第${fleet}舰队第${position}位${shipName}($shipId)声明允许空置不存在的第${allowedSlot}槽。"
                }
            }
            foreach ($slotNumber in 1..$normalSlotCount) {
                $matches = @($slotRows | Where-Object { [int]$_['Slot'] -eq $slotNumber })
                if ($slotNumber -in $allowedEmptySlots -and $matches.Count -eq 0) { continue }
                if ($matches.Count -ne 1) {
                    $problems += "第${fleet}舰队第${position}位${shipName}($shipId)的第${slotNumber}普通槽改装行数量为$($matches.Count)，应为1。"
                    continue
                }
                if (Test-KcpsDeclaredEmptyRefitSlot -Ship $shipRefit -Slot $matches[0]) { continue }
                $selectors = @($matches[0]['Equipments'] | Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_['SelectValue'])
                })
                if ($selectors.Count -eq 0) {
                    $problems += "第${fleet}舰队第${position}位${shipName}($shipId)的第${slotNumber}普通槽没有指定装备。"
                }
                if ([bool]$matches[0]['IgnoreSlotNotAvailable']) {
                    $problems += "第${fleet}舰队第${position}位${shipName}($shipId)的第${slotNumber}普通槽允许静默跳过；固定舰普通槽必须严格检查。"
                }
                if ([bool]$matches[0]['IgnoreNoEquipmentMatched']) {
                    $problems += "第${fleet}舰队第${position}位${shipName}($shipId)的第${slotNumber}普通槽允许找不到装备时静默跳过。"
                }
            }

            $extraSlotOpen = [int]$ownedShip['api_slot_ex'] -ne 0
            if ($extraSlotOpen) {
                $extraRows = @($slotRows | Where-Object { [int]$_['Slot'] -eq 6 })
                if (6 -notin $allowedEmptySlots -and ($extraRows.Count -ne 1 -or @($extraRows[0]['Equipments'] | Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_['SelectValue'])
                }).Count -eq 0)) {
                    $problems += "第${fleet}舰队第${position}位${shipName}($shipId)已开放补强增设，但改装没有为第6槽指定装备。"
                } elseif (6 -notin $allowedEmptySlots -and [bool]$extraRows[0]['IgnoreNoEquipmentMatched']) {
                    $problems += "第${fleet}舰队第${position}位${shipName}($shipId)的补强增设允许找不到装备时静默跳过。"
                }
            }
        }
    }
    return @($problems)
}

$results = @()
foreach ($group in $groups) {
    $problems = @()
    $warnings = @()
    $identityCheckerProblems = @()
    $workflows = @($group['List'])
    $problems += @(Get-KcpsSortieWorkflowReferenceProblems -Workflows $workflows | ForEach-Object { "$($_.Workflow): $($_.Problem)" })
    $sortie = @($workflows | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleSortieWorkflow' }) | Select-Object -First 1
    $controller = @($workflows | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'RelationalSortieWorkflow' }) | Select-Object -First 1
    $memoWorkflow = @($workflows | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'MemoWorkflow' }) | Select-Object -First 1
    $memoText = if ($null -eq $memoWorkflow) { '' } else { [string]$memoWorkflow['Memo'] }
    $problems += @(Get-EventFixedRefitCoverageProblems -Workflows $workflows -OwnedShips $ships -MasterShips $masterShips)
    $problems += @(Get-KcpsRefitSlotExistenceProblems -Workflows $workflows -OwnedShips $ships `
        -MasterShips $masterShips -RejectOptionalFixedSlots | ForEach-Object { $_.Problem })
    $problems += @(Get-KcpsRefitSlotContinuityProblems -Workflows $workflows | ForEach-Object { $_.Problem })
    $problems += @(Get-KcpsCombinedWorkflowProblems -Workflows $workflows -OwnedShips $ships `
        -MasterShips $masterShips | ForEach-Object { $_.Problem })
    $problems += @(Get-KcpsMemoBlockSpacingProblems -Memo $memoText)
    $stageText = ([string]$group['Name']) + "`n" + $memoText
    $groupStageMatch = [regex]::Match([string]$group['Name'], '(?i)E(?<event>\d+)\s*P(?<phase>\d+)')
    if ($groupStageMatch.Success) {
        $expectedEvent = [int]$groupStageMatch.Groups['event'].Value
        $expectedPhase = [int]$groupStageMatch.Groups['phase'].Value
        foreach ($workflow in @($workflows | Where-Object { $null -ne $_ -and $_ -ne $memoWorkflow })) {
            $workflowMemo = [string]$workflow['Memo']
            foreach ($mentionedStage in @([regex]::Matches($workflowMemo, '(?i)E(?<event>\d+)\s*P(?<phase>\d+)'))) {
                if ([int]$mentionedStage.Groups['event'].Value -ne $expectedEvent -or
                    [int]$mentionedStage.Groups['phase'].Value -ne $expectedPhase) {
                    $problems += ('执行单元“{0}”的说明残留其他阶段 {1}；当前配置是 E{2} P{3}。复制模板后必须重写执行单元说明。' -f
                        [string]$workflow['Name'], $mentionedStage.Value, $expectedEvent, $expectedPhase)
                }
            }
        }
    }
    $identityCheckerSpec = Get-EventSortieIdentityCheckerSpec -Sortie $sortie
    $matchingRouteSpecs = @($routeSpecs | Where-Object {
        $null -ne $sortie -and [int]$_['Sea'] -eq [int]$sortie['Sea'] -and [int]$_['Area'] -eq [int]$sortie['Area'] -and
        -not [string]::IsNullOrWhiteSpace([string]$_['GroupNameRegex']) -and
        (Test-KcpsRouteSpecGroupName -GroupName ([string]$group['Name']) -RouteSpec $_)
    })
    if ($null -ne $sortie -and $matchingRouteSpecs.Count -ne 1) {
        $problems += '活动出击必须提供恰好一份与当前配置匹配的私有路线规格；缺少或多重匹配时无法验证任务与阶段条件。'
    }
    $routeSpec = if ($matchingRouteSpecs.Count -eq 1) { $matchingRouteSpecs[0] } else { $null }
    $stageDesign = if ($null -ne $routeSpec -and
        $routeSpec.Contains('StageDesign') -and
        $routeSpec['StageDesign'] -is [System.Collections.IDictionary]) {
        $routeSpec['StageDesign']
    } else {
        $null
    }
    $hasExpectedGaugeRange = $null -ne $stageDesign -and
        $stageDesign.Contains('GaugeRangeMin') -and
        $stageDesign.Contains('GaugeRangeMax')
    $expectedGaugeRangeMin = if ($hasExpectedGaugeRange) { [int]$stageDesign['GaugeRangeMin'] } else { 0 }
    $expectedGaugeRangeMax = if ($hasExpectedGaugeRange) { [int]$stageDesign['GaugeRangeMax'] } else { 0 }
    $gaugePhaseBoundary = if ($null -ne $stageDesign -and
        $stageDesign.Contains('GaugePhaseBoundary') -and
        $stageDesign['GaugePhaseBoundary'] -is [System.Collections.IDictionary]) {
        $stageDesign['GaugePhaseBoundary']
    } else {
        $null
    }
    $expectedFinalPhaseGaugeMax = 0
    if ($null -ne $gaugePhaseBoundary) {
        $requiredBoundaryFields = @('GaugeTotal','GrindingBoss','FinalBoss','FinalPhaseGaugeMax','Source','LastVerifiedJst')
        $missingBoundaryFields = @($requiredBoundaryFields | Where-Object {
            -not $gaugePhaseBoundary.Contains($_) -or $null -eq $gaugePhaseBoundary[$_]
        })
        if ($missingBoundaryFields.Count -gt 0) {
            $problems += "GaugePhaseBoundary 缺少字段：$($missingBoundaryFields -join ', ')。"
        }
        foreach ($bossField in @('GrindingBoss','FinalBoss')) {
            $boss = if ($gaugePhaseBoundary.Contains($bossField)) { $gaugePhaseBoundary[$bossField] } else { $null }
            if (-not ($boss -is [System.Collections.IDictionary]) -or
                -not $boss.Contains('Name') -or [string]::IsNullOrWhiteSpace([string]$boss['Name']) -or
                -not $boss.Contains('Hp') -or [int]$boss['Hp'] -le 0) {
                $problems += "GaugePhaseBoundary.$bossField 必须记录有效的 Name 与 Hp。"
            }
        }
        if ($gaugePhaseBoundary.Contains('GaugeTotal') -and [int]$gaugePhaseBoundary['GaugeTotal'] -le 0) {
            $problems += 'GaugePhaseBoundary.GaugeTotal 必须大于0。'
        }
        if ($gaugePhaseBoundary.Contains('FinalPhaseGaugeMax')) {
            $expectedFinalPhaseGaugeMax = [int]$gaugePhaseBoundary['FinalPhaseGaugeMax']
            if ($expectedFinalPhaseGaugeMax -le 0) {
                $problems += 'GaugePhaseBoundary.FinalPhaseGaugeMax 必须大于0。'
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$gaugePhaseBoundary['Source']) -or
            [string]::IsNullOrWhiteSpace([string]$gaugePhaseBoundary['LastVerifiedJst'])) {
            $problems += 'GaugePhaseBoundary 必须记录可追溯的 Source 与 LastVerifiedJst。'
        }
    }
    $isDeclaredFutureStage = $null -ne $routeSpec -and
        $routeSpec.Contains('FutureStagePrerequisite') -and
        -not [string]::IsNullOrWhiteSpace([string]$routeSpec['FutureStagePrerequisite'])
    if ($null -ne $routeSpec -and $routeSpec.Contains('RouteBranchAssertions')) {
        foreach ($assertion in @($routeSpec['RouteBranchAssertions'])) {
            if (-not ($assertion -is [System.Collections.IDictionary])) {
                $problems += 'RouteBranchAssertions 的每一项都必须是对象。'
                continue
            }
            $requiredBranchFields = @('From','To','AppliedRuleOrder','StageCondition','Fleet','ExpectedFleetCount','MemoStageTextRegex','Evidence','LastVerifiedJst')
            $missingBranchFields = @($requiredBranchFields | Where-Object {
                -not $assertion.Contains($_) -or [string]::IsNullOrWhiteSpace([string]$assertion[$_])
            })
            if ($missingBranchFields.Count -gt 0) {
                $problems += "路线阶段分岔断言缺少字段：$($missingBranchFields -join ', ')。"
                continue
            }

            $fromNode = [string]$assertion['From']
            $toNode = [string]$assertion['To']
            $specRoute = @($routeSpec['Route'] | ForEach-Object { [string]$_ })
            $fromIndex = [array]::IndexOf($specRoute, $fromNode)
            if ($fromIndex -lt 0 -or $fromIndex + 1 -ge $specRoute.Count -or $specRoute[$fromIndex + 1] -ne $toNode) {
                $problems += "路线阶段分岔断言 $fromNode→$toNode 不是路线规格中的相邻边。"
            }
            if ([int]$assertion['AppliedRuleOrder'] -lt 1) {
                $problems += "路线阶段分岔断言 $fromNode→$toNode 的 AppliedRuleOrder 必须大于0。"
            }

            try {
                if ($memoText -notmatch ([string]$assertion['MemoStageTextRegex'])) {
                    $problems += "备注没有写明路线阶段分岔 $fromNode→$toNode 的前置状态：$([string]$assertion['StageCondition'])。"
                }
            } catch {
                $problems += "路线阶段分岔断言 $fromNode→$toNode 的 MemoStageTextRegex 无效。"
            }

            $fleetKey = [string][int]$assertion['Fleet']
            $expectedCount = [int]$assertion['ExpectedFleetCount']
            if ($null -eq $identityCheckerSpec -or
                -not ($identityCheckerSpec['Fleets'] -is [System.Collections.IDictionary]) -or
                -not $identityCheckerSpec['Fleets'].Contains($fleetKey)) {
                $problems += "路线阶段分岔断言要求核对第 $fleetKey 舰队，但身份检查没有该舰队声明。"
            } else {
                $actualCount = @($identityCheckerSpec['Fleets'][$fleetKey]).Count
                if ($actualCount -ne $expectedCount) {
                    $problems += "路线阶段分岔 $fromNode→$toNode 在当前阶段要求第 $fleetKey 舰队为 $expectedCount 船，身份检查实际为 $actualCount 船。"
                }
            }
            if (-not $routeSpec.Contains('ExpectedFleetCounts') -or
                -not ($routeSpec['ExpectedFleetCounts'] -is [System.Collections.IDictionary]) -or
                -not $routeSpec['ExpectedFleetCounts'].Contains($fleetKey) -or
                [int]$routeSpec['ExpectedFleetCounts'][$fleetKey] -ne $expectedCount) {
                $problems += "路线阶段分岔 $fromNode→$toNode 的船数没有与 ExpectedFleetCounts 同步。"
            }
        }
    }
    if ($null -ne $routeSpec) {
        if ($routeSpec.Contains('GuideBaselineMode')) {
            $baselineMode = [string]$routeSpec['GuideBaselineMode']
            if ($baselineMode -eq 'Guide' -and -not $routeSpec.Contains('GuideFleetBaseline')) { $problems += 'GuideBaselineMode=Guide requires GuideFleetBaseline.' }
            elseif ($baselineMode -eq 'Independent') {
                foreach ($field in @('PlanningSource', 'PlanningReason')) {
                    if ([string]::IsNullOrWhiteSpace([string]$routeSpec[$field])) { $problems += "Independent planning requires $field." }
                }
                if ($routeSpec.Contains('GuideFleetBaseline')) { $problems += 'Independent planning must not also declare GuideFleetBaseline.' }
            } elseif ($baselineMode -ne 'Guide') { $problems += 'GuideBaselineMode must be Guide or Independent.' }
        }
        if ($null -ne $sortie) { $problems += @(Get-KcpsStageDesignProblems -Group $group -Sortie $sortie -RelationalWorkflows @($controller) -Spec $routeSpec) }
    }
    if ($null -ne $routeSpec -and $routeSpec.Contains('GuideFleetBaseline')) {
        if (-not $routeSpec.Contains('GuideFleetSource') -or
            [string]::IsNullOrWhiteSpace([string]$routeSpec['GuideFleetSource'])) {
            $problems += '路线规格包含攻略船队基准，但没有记录 GuideFleetSource。'
        }
        if ($null -eq $identityCheckerSpec -or
            -not ($identityCheckerSpec['Fleets'] -is [System.Collections.IDictionary])) {
            $problems += '路线规格包含攻略船队基准，但出击前身份检查没有可核对的最终舰队。'
        } else {
            $guideFleetBaseline = $routeSpec['GuideFleetBaseline']
            if (-not ($guideFleetBaseline -is [System.Collections.IDictionary])) {
                $problems += 'GuideFleetBaseline 必须是按舰队编号分组的对象。'
            } else {
                foreach ($fleetKey in @($guideFleetBaseline.Keys)) {
                    $expectedPatterns = @($guideFleetBaseline[$fleetKey])
                    $actualNames = [System.Collections.Generic.List[string]]::new()
                    $identityFleets = $identityCheckerSpec['Fleets']
                    if ($identityFleets.Contains([string]$fleetKey)) {
                        foreach ($shipSpec in @($identityFleets[[string]$fleetKey])) {
                            $shipId = [string]$shipSpec['Id']
                            $actualName = if ($copyById.ContainsKey($shipId)) {
                                [string]$copyById[$shipId].Name
                            } else {
                                [string]$shipSpec['Name']
                            }
                            $actualNames.Add($actualName)
                        }
                    }
                    foreach ($patternValue in $expectedPatterns) {
                        $pattern = [string]$patternValue
                        $matchedIndex = -1
                        for ($actualIndex = 0; $actualIndex -lt $actualNames.Count; $actualIndex++) {
                            try {
                                if ([regex]::IsMatch($actualNames[$actualIndex], $pattern)) {
                                    $matchedIndex = $actualIndex
                                    break
                                }
                            } catch {
                                $problems += "攻略船队基准中的正则无效：第 $fleetKey 舰队 $pattern。"
                                break
                            }
                        }
                        if ($matchedIndex -lt 0) {
                            $problems += "第 $fleetKey 舰队缺少攻略船队基准匹配项：$pattern。"
                        } else {
                            $actualNames.RemoveAt($matchedIndex)
                        }
                    }
                    foreach ($unexpectedName in $actualNames) {
                        $problems += "第 $fleetKey 舰队含有攻略船队基准外的船：$unexpectedName。若确需偏离，应先更新基准允许项并在备注中给出证据。"
                    }
                }
            }
        }
    }
    if ($null -ne $routeSpec -and $routeSpec.Contains('FinalTagCopyPolicy')) {
        $copyPolicy = $routeSpec['FinalTagCopyPolicy']
        if (-not ($copyPolicy -is [System.Collections.IDictionary])) {
            $problems += 'FinalTagCopyPolicy 必须是对象。'
        } elseif ($null -eq $identityCheckerSpec -or
            -not ($identityCheckerSpec['Fleets'] -is [System.Collections.IDictionary])) {
            $problems += '路线规格声明最终贴条多号机政策，但出击前身份检查没有可核对的最终舰队。'
        } else {
            if (-not $copyPolicy.Contains('LockAllocationSource') -or
                [string]::IsNullOrWhiteSpace([string]$copyPolicy['LockAllocationSource'])) {
                $problems += '最终贴条多号机政策必须记录 LockAllocationSource。'
            }

            $copyPolicyAllowedSallyAreas = @(
                if ($routeSpec.Contains('AllowedSallyAreas')) {
                    $routeSpec['AllowedSallyAreas'] | ForEach-Object { [int]$_ } | Sort-Object -Unique
                }
            )
            $identityRows = @(
                foreach ($fleetEntry in $identityCheckerSpec['Fleets'].GetEnumerator()) {
                    foreach ($shipSpec in @($fleetEntry.Value)) {
                        $shipId = [string]$shipSpec['Id']
                        if ($copyById.ContainsKey($shipId)) { $copyById[$shipId] }
                    }
                }
            )
            $explicitAssignments = @(
                if ($copyPolicy.Contains('ExplicitAssignments')) { $copyPolicy['ExplicitAssignments'] }
            )
            $copyExceptions = @(
                if ($copyPolicy.Contains('Exceptions')) { $copyPolicy['Exceptions'] }
            )
            $explicitRowsByShipId = @{}

            foreach ($assignment in $explicitAssignments) {
                if (-not ($assignment -is [System.Collections.IDictionary])) {
                    $problems += 'FinalTagCopyPolicy.ExplicitAssignments 的每一项都必须是对象。'
                    continue
                }
                $familyPattern = [string]$assignment['FamilyNameRegex']
                $reason = [string]$assignment['Reason']
                $memoReasonPattern = [string]$assignment['MemoReasonRegex']
                $requiredCopyNo = if ($assignment.Contains('RequiredCopyNo')) { [int]$assignment['RequiredCopyNo'] } else { 0 }
                if ([string]::IsNullOrWhiteSpace($familyPattern) -or $requiredCopyNo -lt 1 -or
                    [string]::IsNullOrWhiteSpace($reason) -or [string]::IsNullOrWhiteSpace($memoReasonPattern)) {
                    $problems += '最终贴条的明确多号机分配必须同时填写 FamilyNameRegex、RequiredCopyNo、Reason 和 MemoReasonRegex。'
                    continue
                }
                try {
                    $assignmentMatches = @($identityRows | Where-Object { [regex]::IsMatch([string]$_.FamilyNames, $familyPattern) })
                    if ($assignmentMatches.Count -ne 1) {
                        $problems += "最终贴条的明确多号机分配 $familyPattern 应匹配一艘出击船，实际匹配 $($assignmentMatches.Count) 艘。"
                        continue
                    }
                    $assignmentRow = $assignmentMatches[0]
                    $explicitRowsByShipId[[string]$assignmentRow.Id] = $true
                    if ([int]$assignmentRow.CopyNo -ne $requiredCopyNo) {
                        $problems += "$($assignmentRow.Name)($($assignmentRow.Id))应按锁船分配表使用第 $requiredCopyNo 号机，实际选择第 $($assignmentRow.CopyNo) 号机。"
                    }
                    if (-not [regex]::IsMatch($memoText, $memoReasonPattern)) {
                        $problems += "$($assignmentRow.Name)的锁船表多号机选择理由没有按 MemoReasonRegex 写入备注。"
                    }
                } catch {
                    $problems += "最终贴条的明确多号机分配正则无效：$familyPattern 或 $memoReasonPattern。"
                }
            }

            foreach ($row in @($identityRows | Where-Object { [bool]$copyPolicy['PreferLowestCompatibleCopy'] })) {
                if ([int]$row.CopyNo -le 1 -or $explicitRowsByShipId.ContainsKey([string]$row.Id)) {
                    continue
                }
                $compatibleLowerCopies = @($copyAudit | Where-Object {
                    $_.Numbered -and
                    [string]$_.FamilyNames -eq [string]$row.FamilyNames -and
                    [int]$_.CopyNo -lt [int]$row.CopyNo -and
                    ([int]$_.SallyArea -eq 0 -or [int]$_.SallyArea -in $copyPolicyAllowedSallyAreas)
                } | Sort-Object CopyNo)
                if ($compatibleLowerCopies.Count -eq 0) { continue }

                $matchingExceptions = @()
                foreach ($exception in $copyExceptions) {
                    if (-not ($exception -is [System.Collections.IDictionary])) { continue }
                    $familyPattern = [string]$exception['FamilyNameRegex']
                    try {
                        if (-not [string]::IsNullOrWhiteSpace($familyPattern) -and
                            [regex]::IsMatch([string]$row.FamilyNames, $familyPattern) -and
                            [int]$exception['SelectedCopyNo'] -eq [int]$row.CopyNo) {
                            $matchingExceptions += $exception
                        }
                    } catch {
                        $problems += "最终贴条多号机例外正则无效：$familyPattern。"
                    }
                }
                if ($matchingExceptions.Count -ne 1) {
                    $lowerText = ($compatibleLowerCopies | ForEach-Object { "$($_.Name)第$($_.CopyNo)号机" }) -join '、'
                    $problems += "$($row.Name)选择第 $($row.CopyNo) 号机，但本阶段仍可使用更靠前的实例：$lowerText。当前显式政策 PreferLowestCompatibleCopy 要求最靠前兼容实例，或记录唯一且可复核的例外。"
                    continue
                }
                $copyException = $matchingExceptions[0]
                $exceptionReason = [string]$copyException['Reason']
                $memoReasonPattern = [string]$copyException['MemoReasonRegex']
                if ([string]::IsNullOrWhiteSpace($exceptionReason) -or [string]::IsNullOrWhiteSpace($memoReasonPattern)) {
                    $problems += "$($row.Name)的最终贴条多号机例外缺少 Reason 或 MemoReasonRegex。"
                    continue
                }
                try {
                    if (-not [regex]::IsMatch($memoText, $memoReasonPattern)) {
                        $problems += "$($row.Name)保留更靠前实例的具体原因没有按 MemoReasonRegex 写入备注。"
                    }
                } catch {
                    $problems += "$($row.Name)的最终贴条多号机例外备注正则无效：$memoReasonPattern。"
                }
            }
        }
    }
    if ($null -ne $routeSpec -and $routeSpec.Contains('MinimumShipLevel')) {
        $minimumShipLevel = [int]$routeSpec['MinimumShipLevel']
        if ($minimumShipLevel -lt 1) {
            $problems += 'MinimumShipLevel 必须大于0。'
        }
        if (-not $routeSpec.Contains('MinimumShipLevelReason') -or
            [string]::IsNullOrWhiteSpace([string]$routeSpec['MinimumShipLevelReason'])) {
            $problems += '路线规格声明最低练度时必须记录 MinimumShipLevelReason。'
        }

        $levelExceptions = @{}
        if ($routeSpec.Contains('MinimumShipLevelExceptions')) {
            if (-not ($routeSpec['MinimumShipLevelExceptions'] -is [System.Collections.IDictionary])) {
                $problems += 'MinimumShipLevelExceptions 必须是船ID到豁免理由的对象。'
            } else {
                foreach ($entry in $routeSpec['MinimumShipLevelExceptions'].GetEnumerator()) {
                    if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
                        $problems += "最低练度豁免船ID $($entry.Key) 缺少理由。"
                    } else {
                        $levelExceptions[[string]$entry.Key] = [string]$entry.Value
                    }
                }
            }
        }

        if ($null -eq $identityCheckerSpec -or
            -not ($identityCheckerSpec['Fleets'] -is [System.Collections.IDictionary])) {
            $problems += '路线规格声明最低练度，但出击前身份检查没有可核对的最终舰队。'
        } else {
            foreach ($fleetEntry in $identityCheckerSpec['Fleets'].GetEnumerator()) {
                foreach ($shipSpec in @($fleetEntry.Value)) {
                    $shipId = [string]$shipSpec['Id']
                    if ($levelExceptions.ContainsKey($shipId) -or -not $copyById.ContainsKey($shipId)) {
                        continue
                    }
                    $shipRow = $copyById[$shipId]
                    if ([int]$shipRow.Level -lt $minimumShipLevel) {
                        $problems += "第 $($fleetEntry.Key) 舰队的 $($shipRow.Name)($shipId) 仅 $($shipRow.Level) 级，低于本阶段最低练度 $minimumShipLevel 级。应改用足够练度的实例，或在 MinimumShipLevelExceptions 中记录逐船豁免理由。"
                    }
                }
            }
        }
    }
    if ($null -ne $routeSpec -and $routeSpec.Contains('RequiredFinalVariants')) {
        $requiredVariants = @($routeSpec['RequiredFinalVariants'])
        $pair = [string]$routeSpec['FinalAutomationPair']
        if ($requiredVariants.Count -eq 0 -or [string]::IsNullOrWhiteSpace($pair)) {
            $problems += 'RequiredFinalVariants 必须是非空数组，并提供 FinalAutomationPair。'
        } else {
            foreach ($expectedVariant in $requiredVariants) {
                $variantSpecs = @($routeSpecs | Where-Object { [string]$_['FinalAutomationPair'] -eq $pair -and [string]$_['FinalAutomationVariant'] -eq [string]$expectedVariant })
                if ($variantSpecs.Count -ne 1) { $problems += "显式变体集合 '$pair' 需要唯一 $expectedVariant 路线规格。"; continue }
                $matchingGroups = @($groups | Where-Object { Test-KcpsRouteSpecGroupName -GroupName ([string]$_['Name']) -RouteSpec $variantSpecs[0] })
                if ($matchingGroups.Count -ne 1) { $problems += "显式变体集合 '$pair' 需要唯一 $expectedVariant 配置。" }
            }
        }
    }
    $isDocumentedGaugePhaseGate = $stageText -match '(?:磨血|削血|击破|斩杀|最終|最终)' -and
        $stageText -match '(?:允许区间|允許区間|门禁|門禁)'

    if ($workflows.Count -eq 0 -or
        -not (Test-KcpsWorkflowType -Workflow $workflows[0] -TypeName 'MemoWorkflow') -or
        [string]$workflows[0]['Name'] -ne '备注') {
        $problems += '活动配置的第一个执行单元必须是名为“备注”的 MemoWorkflow。'
    }
    if ($workflows.Count -lt 2 -or
        -not (Test-KcpsWorkflowType -Workflow $workflows[1] -TypeName 'RelationalSortieWorkflow') -or
        [string]$workflows[1]['Name'] -ne '总控') {
        $problems += '活动配置的第二个执行单元必须是紧跟“备注”的“总控” RelationalSortieWorkflow。'
    }

    if ($null -eq $sortie) {
        $problems += '缺少出击执行单元。'
    } elseif ([int]$sortie['Sea'] -ne 0) {
        $problems += "活动海域的 SimpleSortieWorkflow.Sea 应为 0，当前为 $($sortie['Sea'])。"
    }
    if ($null -ne $sortie) {
        $identityCheckerProblems = @(
            Get-KcpsSortieIdentityCheckerProblems `
                -Group $group `
                -Sortie $sortie `
                -Const $const `
                -RequireEnabled
        )
        foreach ($problem in $identityCheckerProblems) {
            $problems += "出击舰队/陆航身份检查：$($problem.Problem)"
        }
        $problems += @(Get-EventLandBasePlanConsistencyProblems `
            -Sortie $sortie `
            -CheckerSpec $identityCheckerSpec `
            -RouteSpec $routeSpec `
            -Memo $memoText)
        if ($null -ne $identityCheckerSpec) {
            foreach ($capacityProblem in @(Get-KcpsLandBaseEquipmentCapacityProblems `
                -Sortie $sortie `
                -CheckerSpec $identityCheckerSpec `
                -Equips $equips `
                -Const $const)) {
                $problems += "陆航装备容量：$($capacityProblem.Problem)"
            }
        }
    }
    if ($null -ne $sortie -and [bool]$sortie['MapHpInRangeFlag']) {
        $actualGaugeRangeMin = [int]$sortie['MapHpInRangeValueMin']
        $actualGaugeRangeMax = [int]$sortie['MapHpInRangeValueMax']
        if ($hasExpectedGaugeRange -and
            ($actualGaugeRangeMin -ne $expectedGaugeRangeMin -or
             $actualGaugeRangeMax -ne $expectedGaugeRangeMax)) {
            $problems += "海域量值门禁为 $actualGaugeRangeMin–$actualGaugeRangeMax，但路线规格要求 $expectedGaugeRangeMin–$expectedGaugeRangeMax。"
        } elseif ($actualGaugeRangeMin -eq 1 -and
            $actualGaugeRangeMax -lt 99999 -and
            -not $isDocumentedGaugePhaseGate) {
            $problems += 'HP 血条和 TP 条的单纯存在检查必须使用 1–99999；更窄区间必须在路线规格和【海域量值】中明确声明阶段门禁。'
        }
    }
    if ($null -ne $sortie) {
        $problems += @(Get-KcpsTerminalBattleProblems -RouteSpec $routeSpec -Sortie $sortie)
        foreach ($conditionalStrategy in @($sortie['Strategies'])) {
            $battleStrategy = $conditionalStrategy['Strategy']
            if ($null -eq $battleStrategy) { continue }

            $strategyMemo = [string]$battleStrategy['Memo']
            $advance = [int]$battleStrategy['DefaultAdvance']
            if ($strategyMemo -match '(?:回港|撤退)' -and $advance -ne 2) {
                $problems += ('条件策略备注写明回港或撤退，但 DefaultAdvance={0}；应设为 2（撤退），否则会停在战后进击选择。' -f $advance)
            }
            if ($strategyMemo -match '(?:^|[、，；;：:\s])进击(?:$|[、，；;。.\s])' -and $advance -ne 1) {
                $problems += ('条件策略备注写明进击，但 DefaultAdvance={0}；应设为 1（进击）。' -f $advance)
            }
        }

        if ($null -ne $routeSpec) {
            $routeSelectionValues = @($routeSpec['Nodes'] | Where-Object {
                ($_.ContainsKey('RequiresWayPoint') -and [bool]$_['RequiresWayPoint']) -or
                [string]$_['Kind'] -eq 'waypoint-select'
            } | ForEach-Object { [int]$_['Value'] })
            foreach ($conditionalStrategy in @($sortie['Strategies'] | Where-Object {
                [int]$_['Condition']['Type'] -eq 1
            })) {
                $value = [int]$conditionalStrategy['Condition']['Value']
                $wayPoint = $conditionalStrategy['Strategy']['DefaultWayPoint']
                if ($value -in $routeSelectionValues) {
                    if (-not (Test-KcpsWayPointValid -WayPoint $wayPoint)) {
                        $problems += "地图点值 $value 是能动分歧，但 DefaultWayPoint 缺失或点击框无效。"
                    }
                } elseif ($null -ne $wayPoint) {
                    $problems += "地图点值 $value 不是能动分歧，DefaultWayPoint 必须为 null；零坐标空对象也属于错误设置。"
                }
            }
        }
    }
    if ($null -ne $sortie) {
        $mainOrganize = @($workflows | Where-Object {
            (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') -and
            [int]$_['Fleet'] -eq [int]$sortie['Fleet']
        }) | Select-Object -First 1
        $mainRefit = @($workflows | Where-Object {
            Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicRefitEquipmentWorkflow'
        }) | Select-Object -First 1
        $flagshipHasRetreatHeadquarters = $false
        if ($null -ne $mainOrganize -and @($mainOrganize['Positions']).Count -eq 7 -and $null -ne $mainRefit) {
            $flagshipSelection = @($mainOrganize['Positions'][0]['Selections'] | Where-Object {
                [int]$_['Type'] -eq 0 -and [string]$_['Value'] -match '^\d+$'
            }) | Select-Object -First 1
            $flagshipId = if ($null -eq $flagshipSelection) { 0 } else { [int]$flagshipSelection['Value'] }
            foreach ($shipRefit in @(Get-EventRefitRowsForFixedPosition `
                -RefitWorkflows @($mainRefit) `
                -Fleet ([int]$sortie['Fleet']) `
                -Position 1 `
                -ShipId $flagshipId)) {
                foreach ($slot in @($shipRefit['Slots'])) {
                    if (@($slot['Equipments'] | Where-Object {
                        [string]$_['SelectValue'] -in @('遊撃部隊 艦隊司令部', '精鋭水雷戦隊 司令部')
                    }).Count -gt 0) {
                        $flagshipHasRetreatHeadquarters = $true
                    }
                }
            }
        }
        if ($flagshipHasRetreatHeadquarters) {
            $allBattleStrategies = @($sortie['DefaultStrategy']) + @(
                $sortie['Strategies'] | ForEach-Object { $_['Strategy'] }
            )
            $retreatEnabledStrategies = @($allBattleStrategies | Where-Object {
                [int]$_['DefaultEscortRetreat'] -eq 1
            })
            $invalidRetreatStrategies = @($allBattleStrategies | Where-Object {
                [int]$_['DefaultEscortRetreat'] -notin @(1, 2)
            })
            $refreshStrategies = @($allBattleStrategies | Where-Object {
                [int]$_['DefaultFormation'] -eq 7
            })
            $retreatMemo = Get-EventMemoSection -Memo $memoText -Name '退避与偏航'

            if ($invalidRetreatStrategies.Count -gt 0) {
                $problems += '使用退避司令部时，默认与每条地图点策略都必须显式选择“退避”或“不退避”，不得保留手动选择。'
            }
            if (@($allBattleStrategies | Where-Object {
                -not [bool]$_['RejectEscortRetreatIfMoreOrEqualThanTwoEscortShipsHeavilyDamaged'] -or
                [int]$_['EscortShipsHeavilyDamagedStrategy'] -ne 1
            }).Count -gt 0) {
                $problems += '单舰退避必须保留“两艘以上大破拒绝退避”和“伴随舰大破强制撤退”安全兜底。'
            }
            if ([string]::IsNullOrWhiteSpace($retreatMemo)) {
                $problems += '使用退避司令部时，备注必须单列“【退避与偏航】”，逐点说明退避决策、带路或索敌风险及止损方式。'
            } elseif ($retreatEnabledStrategies.Count -gt 0) {
                if ($retreatMemo -notmatch '开启|允许|自动.*退避' -or $retreatMemo -notmatch '偏航|带路|索敌') {
                    $problems += '存在自动单舰退避策略，但“【退避与偏航】”没有说明开启点及其偏航、带路或索敌分析。'
                }
                if ($retreatMemo -match '刷新' -and $refreshStrategies.Count -eq 0) {
                    $problems += '“【退避与偏航】”声称用阵型页面刷新止损，但条件策略中没有 Formation=Refresh 的显式偏航策略。'
                }
                foreach ($enabledStrategy in $retreatEnabledStrategies) {
                    $enabledMemo = [string]$enabledStrategy['Memo']
                    $pointMatch = [regex]::Match($enabledMemo, '^(?<point>[A-Z][A-Z0-9]*)（')
                    if ($pointMatch.Success -and $retreatMemo -notmatch [regex]::Escape($pointMatch.Groups['point'].Value)) {
                        $problems += "地图点 $($pointMatch.Groups['point'].Value) 开启单舰退避，但【退避与偏航】没有点名说明。"
                    }
                }
            } else {
                if ($retreatMemo -notmatch '关闭.*退避|不使用.*退避') {
                    $problems += '退避司令部配置没有启用单舰退避，但“【退避与偏航】”未说明关闭退避的原因。'
                }
                if ($memoText -notmatch '仅(?:使用|保留).{0,12}(?:面板|补正)|仅.{0,12}(?:面板|补正).{0,12}(?:使用|保留)') {
                    $problems += '旗舰装备退避司令部，但所有地图点都拒绝退避；若只为面板补正保留，必须在备注中明确比较结论，否则应移除司令部。'
                }
                if ($refreshStrategies.Count -gt 0 -and
                    $retreatMemo -notmatch '非退避原因|随机分歧|索敌不足|编成变化') {
                    $problems += '所有地图点均拒绝退避，却仍配置偏航刷新点；必须删除因退避才会出现的不可达点，或说明随机分歧、索敌不足等非退避来源。'
                }
            }
            foreach ($refreshStrategy in $refreshStrategies) {
                $refreshMemo = [string]$refreshStrategy['Memo']
                $pointMatch = [regex]::Match($refreshMemo, '^(?<point>[A-Z][A-Z0-9]*)（')
                if ($pointMatch.Success -and $retreatMemo -notmatch [regex]::Escape($pointMatch.Groups['point'].Value)) {
                    $problems += "偏航刷新策略 $($pointMatch.Groups['point'].Value) 没有在【退避与偏航】中说明来源、触发条件和止损理由。"
                }
            }
        }

        $combinedWorkflow = @($workflows | Where-Object {
            Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicCombinedFleetWorkflow'
        }) | Select-Object -First 1
        if ($null -ne $routeSpec -and $routeSpec.Contains('ExpectedCombinedFleetType')) {
            $expectedCombinedFleetType = [int]$routeSpec['ExpectedCombinedFleetType']
            $combinedTypeNames = @{ 1 = '空母机动'; 2 = '水上打击'; 3 = '输送护卫' }
            if ($null -eq $combinedWorkflow) {
                $problems += "路线规格要求$($combinedTypeNames[$expectedCombinedFleetType])联合舰队，但配置缺少组成联合舰队执行单元。"
            } elseif ([int]$combinedWorkflow['CombinedFleetType'] -ne $expectedCombinedFleetType) {
                $actualCombinedFleetType = [int]$combinedWorkflow['CombinedFleetType']
                $problems += ('联合舰队类型与路线规格不符：应为{0}({1})，实际为{2}({3})。' -f
                    $combinedTypeNames[$expectedCombinedFleetType], $expectedCombinedFleetType,
                    $combinedTypeNames[$actualCombinedFleetType], $actualCombinedFleetType)
            } elseif ([string]$combinedWorkflow['Memo'] -notmatch [regex]::Escape($combinedTypeNames[$expectedCombinedFleetType])) {
                $problems += "组成联合舰队执行单元的说明没有写明实际联合舰队类型：$($combinedTypeNames[$expectedCombinedFleetType])。"
            }
        }
        if ($null -ne $combinedWorkflow -and $null -ne $controller) {
            $enabledDockingBeforeRefs = @($controller['DockingBeforeWorkflows'] | Where-Object {
                $null -ne $_ -and (-not $_.ContainsKey('Enabled') -or [bool]$_['Enabled'])
            })
            $combinedRef = @($enabledDockingBeforeRefs | Where-Object {
                [string]$_['Guid'] -eq [string]$combinedWorkflow['Guid']
            })
            if ($combinedRef.Count -ne 1) {
                $problems += '联合舰队的“组成联合舰队”没有由总控的 DockingBeforeWorkflows 正确触发。'
            } elseif ($enabledDockingBeforeRefs.Count -eq 0 -or
                [string]$enabledDockingBeforeRefs[0]['Guid'] -ne [string]$combinedWorkflow['Guid']) {
                $problems += '联合舰队的“组成联合舰队”必须是总控 DockingBeforeWorkflows 的第一个启用项。'
            }

            $workflowByGuid = @{}
            foreach ($workflow in $workflows) {
                $workflowByGuid[[string]$workflow['Guid']] = $workflow
            }
            $dockingCompletionCount = @($enabledDockingBeforeRefs | Where-Object {
                $guid = [string]$_['Guid']
                $workflowByGuid.ContainsKey($guid) -and
                (Test-KcpsWorkflowType -Workflow $workflowByGuid[$guid] -TypeName 'BasicDockingWorkflow')
            }).Count
            if ([int]$controller['DockingBeforeFinishedEventThreshold'] -ne $dockingCompletionCount) {
                $problems += ('联合舰队的 DockingBeforeFinishedEventThreshold 应为入渠完成事件数 {0}；“组成联合舰队”不计入该阈值。' -f $dockingCompletionCount)
            }
        }
        $mainFleetIds = if ($null -ne $combinedWorkflow) {
            @(1, 2)
        } else {
            @([int]$sortie['Fleet'])
        }
        $mainEquipmentNames = @(
            foreach ($shipRefit in @($mainRefit['Ships'] | Where-Object {
                [int]$_['Fleet'] -in $mainFleetIds
            })) {
                foreach ($slot in @($shipRefit['Slots'])) {
                    foreach ($candidate in @($slot['Equipments'])) {
                        [string]$candidate['SelectValue']
                    }
                }
            }
        )
        $providerStrategies = @($sortie['DefaultStrategy'])
        if ($sortie.Contains('DefaultBossBattleStrategy') -and
            $null -ne $sortie['DefaultBossBattleStrategy']) {
            $providerStrategies += $sortie['DefaultBossBattleStrategy']
        }
        $providerStrategies += @($sortie['Strategies'] | ForEach-Object { $_['Strategy'] })

        $smokeEnabledStrategies = @($providerStrategies | Where-Object {
            $null -ne $_ -and [bool]$_['DefaultSmoke']
        })
        $smokeEquipmentNames = @($mainEquipmentNames | Where-Object {
            $_ -match '^発煙装置(?:改)?\(煙幕\)$'
        })
        if ($smokeEnabledStrategies.Count -gt 0 -and $smokeEquipmentNames.Count -eq 0) {
            $problems += '战斗策略启用了烟幕，但实际出击舰队改装中没有発煙装置(煙幕)或発煙装置改(煙幕)。战术开关必须有装备提供者。'
        }
        if ($smokeEnabledStrategies.Count -eq 0 -and $smokeEquipmentNames.Count -gt 0) {
            $problems += '实际出击舰队携带烟幕装备，但没有任何战斗策略启用烟幕；这是无效占槽，必须按当前目标重新配装或明确启用经过推演的烟幕点。'
        }

        if ($null -ne $combinedWorkflow) {
            $firstFleetOrganize = @($workflows | Where-Object {
                (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') -and
                [int]$_['Fleet'] -eq 1
            }) | Select-Object -First 1
            $firstFleetFlagshipSelection = if ($null -eq $firstFleetOrganize) { $null } else {
                @($firstFleetOrganize['Positions'][0]['Selections'] | Where-Object {
                    [int]$_['Type'] -eq 0 -and [string]$_['Value'] -match '^\d+$'
                }) | Select-Object -First 1
            }
            $firstFleetFlagshipId = if ($null -eq $firstFleetFlagshipSelection) { 0 } else { [int]$firstFleetFlagshipSelection['Value'] }
            $firstFleetFlagshipEquipmentNames = @(
                foreach ($shipRefit in @(Get-EventRefitRowsForFixedPosition `
                    -RefitWorkflows @($mainRefit) `
                    -Fleet 1 `
                    -Position 1 `
                    -ShipId $firstFleetFlagshipId)) {
                    foreach ($slot in @($shipRefit['Slots'])) {
                        foreach ($candidate in @($slot['Equipments'])) {
                            [string]$candidate['SelectValue']
                        }
                    }
                }
            )
            $hasCombinedFleetCommand = '艦隊司令部施設' -in $firstFleetFlagshipEquipmentNames
            $nonManualRetreatStrategies = @($providerStrategies | Where-Object {
                $null -ne $_ -and [int]$_['DefaultEscortRetreat'] -ne 0
            })
            if ($nonManualRetreatStrategies.Count -gt 0 -and -not $hasCombinedFleetCommand) {
                $problems += '联合舰队没有在第一舰队旗舰装备艦隊司令部施設，却把退避设成了非手动选择。没有能力提供者时，默认与条件策略的退避都必须保持手动选择。'
            }
        }
    }
    $liveGauge = $null
    if ($null -ne $sortie) {
        $liveGauge = Get-KcpsLiveMapGaugeInfo -Maps $maps -Sea ([int]$sortie['Sea']) -Area ([int]$sortie['Area'])
    }
    $declaredGaugeNumber = if ($null -ne $routeSpec -and
        $routeSpec.Contains('StageDesign') -and
        $routeSpec['StageDesign'] -is [System.Collections.IDictionary] -and
        $routeSpec['StageDesign'].Contains('GaugeNumber')) {
        [int]$routeSpec['StageDesign']['GaugeNumber']
    } else { 0 }
    $isDifferentDeclaredStage = $null -ne $liveGauge -and
        $null -ne $liveGauge.GaugeNumber -and
        $declaredGaugeNumber -gt 0 -and
        [int]$liveGauge.GaugeNumber -ne $declaredGaugeNumber
    if ($null -ne $sortie -and [bool]$sortie['MapHpInRangeFlag']) {
        $configuredGauge = if ([int]$sortie['MapHpInRangeValueGauge'] -eq 0) { 'HP' } else { 'TP' }
        $futureGaugeMatchesSpec = $isDeclaredFutureStage -and
            $isDifferentDeclaredStage -and
            $routeSpec.Contains('ExpectedMapGaugeType') -and
            [string]$routeSpec['ExpectedMapGaugeType'] -eq $configuredGauge
        if ($null -eq $liveGauge) {
            $warnings += '已启用海域量值检查，但无法从 poi maps 数据唯一确认本阶段地图及量值类型；交付前必须人工核对。'
        } elseif ($isDifferentDeclaredStage) {
            $warnings += ('当前游戏处于第 {0} 条量值，配置声明第 {1} 条；按路线规格校验历史或后续阶段，不用当前量值类型否定配置。' -f
                [int]$liveGauge.GaugeNumber, $declaredGaugeNumber)
        } elseif ($liveGauge.Name -notin @('HP', 'TP') -and -not $futureGaugeMatchesSpec) {
            $problems += "已启用海域量值检查，但当前地图 $($liveGauge.MapId) 的量值状态为 $($liveGauge.Name)，KCPS 无法按 HP/TP 范围执行。"
        } elseif ([int]$sortie['MapHpInRangeValueGauge'] -ne [int]$liveGauge.SelectableValue -and -not $futureGaugeMatchesSpec) {
            $problems += "海域量值类型与当前游戏状态不符：地图 $($liveGauge.MapId) 实际为 $($liveGauge.Name)，配置却要求 $configuredGauge。"
        } elseif ($futureGaugeMatchesSpec -and $liveGauge.Name -ne $configuredGauge) {
            $warnings += ('目标阶段尚未开放：当前地图 {0} 为 {1}，路线规格声明前置为：{2}；配置仍按目标阶段 {3} 校验。' -f
                $liveGauge.MapId, $liveGauge.Name, [string]$routeSpec['FutureStagePrerequisite'], $configuredGauge)
        }
    }
    if ($null -eq $controller) { $problems += '缺少关联出击总控。' }
    if ($null -ne $sortie -and $null -ne $controller) {
        $isLandBaseDefenseObjective = $stageText -match '(?:守家空优|基地防空.{0,16}(?:航空优(?:势|勢)|空优|空確|制空权确保|制空権確保))'
        if ($isLandBaseDefenseObjective) {
            $defenseCorps = @(1..3 | Where-Object {
                [int]$sortie["LandBasedAirCorps$($_)Action"] -eq 2
            })
            if ($defenseCorps.Count -eq 0) {
                $problems += '目标是基地防空航空优势或确保，但没有任何基地航空队设为防空。'
            }
            if ([bool]$controller['StopIfAirBaseAttackNoDamageFlag']) {
                $problems += '基地空袭无伤不等于防空航空优势或确保；守家空优配置不得使用 StopIfAirBaseAttackNoDamage 作为完成计数。'
            }
            if ([bool]$controller['StopIfArrivedEndPointFlag']) {
                $problems += '守家空优目标不得用到达终点次数停止；终点到达不能证明本次发生基地空袭并取得目标制空状态。'
            }
            if ([bool]$controller['StopIfEnemyDebufAtHomeFlag']) {
                if ([int]$controller['StopIfEnemyDebufAtHomeValueThreshold'] -ne 1) {
                    $problems += '返港削弱提示只在条件整体完成时出现一次；StopIfEnemyDebufAtHome 阈值必须为 1，不能写成所需空优次数。'
                }
                if ($memoText -notmatch '(?:仅剩|只剩|唯一\s*剩余|其他[\s\S]{0,40}(?:已经|已)完成)' -or
                    $memoText -notmatch '(?:返港|回港)[\s\S]{0,40}(?:削弱|提示)') {
                    $problems += '使用返港削弱提示停止守家空优时，备注必须证明其他可能触发提示的条件已经完成，且说明返港提示的适用边界。'
                }
            }
            if ([bool]$controller['StopIfLoopCountLargerOrEqualThanFlag']) {
                $noticeGuids = @($workflows | Where-Object {
                    (Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleRaiseUserEventWorkflow') -and
                    [string]$_['Name'] -eq '通知通关'
                } | ForEach-Object { [string]$_['Guid'] })
                $autoStopNotices = @($controller['AutoStoppedTriggerWorkflows'] | Where-Object {
                    [bool]$_['Enabled'] -and [string]$_['Guid'] -in $noticeGuids
                })
                if ($autoStopNotices.Count -gt 0) {
                    $problems += '守家空优配置启用循环次数上限时也会触发同一个“通知通关”，可能未完成便误发 Clear；应取消上限或另行设计不发送完成消息的停止分支。'
                }
            }
            if ([string]$controller['Script'] -match 'def\s+OnAutoStop\s*\(' -and
                [string]$controller['Script'] -match '(?:AirBase|LandBased|m_flag2|Battle)') {
                $problems += 'OnAutoStop 不能可靠取得本次基地空袭制空结果；不得用最近响应或缓存伪造守家空优计数。'
            }
        }

        $pointAirObjectiveMatch = [regex]::Match(
            $stageText,
            '(?is)(?<point>[A-Z][A-Z0-9]*)点.{0,32}?(?:航空优(?:势|勢)|空优|空優|空确|空確|制空权确保|制空権確保)\s*(?<count>\d+)\s*次'
        )
        if ($pointAirObjectiveMatch.Success -and -not $isLandBaseDefenseObjective) {
            $pointName = $pointAirObjectiveMatch.Groups['point'].Value + '点'
            $requiredCount = [int]$pointAirObjectiveMatch.Groups['count'].Value
            $probeSpec = Get-EventPointAirStateSpec -Workflow $sortie -Kind Probe
            $counterSpec = Get-EventPointAirStateSpec -Workflow $controller -Kind Counter

            if ($null -eq $probeSpec -or $null -eq $counterSpec) {
                $problems += "目标是 $pointName 航空优势或确保 $requiredCount 次；不得把固定循环次数当作成功次数，必须安装目标点制空精确计数器。"
            } else {
                foreach ($field in @('Version', 'MapId', 'PointName', 'RequiredCount', 'MessagePrefix')) {
                    if (-not $probeSpec.ContainsKey($field) -or -not $counterSpec.ContainsKey($field) -or
                        [string]$probeSpec[$field] -ne [string]$counterSpec[$field]) {
                        $problems += "目标点制空计数器的出击探针与总控声明字段 $field 不一致。"
                    }
                }
                $probeValues = @($probeSpec['ConditionValues'] | ForEach-Object { [int]$_ } | Sort-Object -Unique)
                $counterValues = @($counterSpec['ConditionValues'] | ForEach-Object { [int]$_ } | Sort-Object -Unique)
                if (($probeValues -join ',') -ne ($counterValues -join ',')) {
                    $problems += '目标点制空计数器的出击探针与总控进入边编号不一致。'
                }
                if ([string]$probeSpec['PointName'] -ne $pointName -or
                    [int]$probeSpec['RequiredCount'] -ne $requiredCount) {
                    $problems += "目标点制空计数声明与配置目标不符：声明为 $($probeSpec['PointName']) $($probeSpec['RequiredCount']) 次，目标为 $pointName $requiredCount 次。"
                }
                if ($null -ne $routeSpec -and
                    $routeSpec.ContainsKey('StageDesign') -and
                    $null -ne $routeSpec['StageDesign'] -and
                    $routeSpec['StageDesign'].ContainsKey('PointAirStateTarget')) {
                    $routeTarget = $routeSpec['StageDesign']['PointAirStateTarget']
                    $routeValues = @($routeTarget['ConditionValues'] | ForEach-Object { [int]$_ } | Sort-Object -Unique)
                    if ([string]$routeTarget['PointName'] -ne [string]$probeSpec['PointName'] -or
                        [int]$routeTarget['RequiredCount'] -ne [int]$probeSpec['RequiredCount'] -or
                        ($routeValues -join ',') -ne ($probeValues -join ',')) {
                        $problems += '目标点制空计数声明与路线规格中的 PointAirStateTarget 不一致。'
                    }
                }

                $targetStrategies = @($sortie['Strategies'] | Where-Object {
                    [int]$_['Condition']['Type'] -eq 1 -and
                    [int]$_['Condition']['Value'] -in $probeValues
                })
                if ($probeValues.Count -eq 0 -or $targetStrategies.Count -ne $probeValues.Count) {
                    $problems += '目标点制空计数声明的进入边编号没有被条件战斗策略完整覆盖。'
                }
                foreach ($targetStrategyRow in $targetStrategies) {
                    $targetStrategy = $targetStrategyRow['Strategy']
                    if (-not [bool]$targetStrategy['EnableScriptEnterDayTimeBattleCallback'] -or
                        [string]$targetStrategy['EnterDayTimeBattleCallbackFunctionName'] -ne 'OnPointAirState') {
                        $problems += "目标点进入边 $($targetStrategyRow['Condition']['Value']) 没有启用 OnPointAirState 昼战回调。"
                    }
                    if ([int]$targetStrategy['DefaultAdvance'] -ne 2) {
                        $problems += "目标点进入边 $($targetStrategyRow['Condition']['Value']) 没有在战后回港；最近战斗特例只能用于目标点为本次最后一战的配置。"
                    }
                }

                $sortieScript = [string]$sortie['Script']
                $controllerScriptForPointAir = [string]$controller['Script']
                if ([int]$probeSpec['Version'] -lt 2 -or
                    [string]$probeSpec['TokenStrategy'] -ne 'SortieRunAndBattleOrdinal' -or
                    $sortieScript -notmatch 'def\s+OnProcess\s*\(' -or
                    $sortieScript -notmatch 'Guid\.NewGuid\s*\(' -or
                    $sortieScript -notmatch 'Workflow\.BattleCount' -or
                    $sortieScript -match 'status\["time"\]') {
                    $problems += '目标点制空去重仍依赖不保证存在的poi时间，或缺少每轮出击标识与战斗序号；请重生成新版制空计数器。'
                }
                $coreRuntimeImportPattern = '(?m)^\s*from\s+KancollePlayerSimulatorKaiCore\s+import\s+\*\s*$'
                if (-not [bool]$sortie['EnableScript'] -or
                    $sortieScript -notmatch 'def\s+OnPointAirState\s*\(' -or
                    $sortieScript -notmatch 'api_disp_seiku' -or
                    $sortieScript -notmatch 'GameState\.Battle\s*\(' -or
                    $sortieScript -notmatch 'POINT_AIR_STATE_MAP' -or
                    $sortieScript -notmatch 'POINT_AIR_STATE_VALUES') {
                    $problems += '目标点制空探针没有完整核对地图、进入边和 api_disp_seiku。'
                }
                if (-not [bool]$controller['EnableScript'] -or
                    $controllerScriptForPointAir -notmatch 'def\s+OnFilterEvent\s*\(' -or
                    $controllerScriptForPointAir -notmatch 'def\s+OnAutoStop\s*\(' -or
                    $controllerScriptForPointAir -notmatch 'def\s+OnAutoStopped\s*\(' -or
                    $controllerScriptForPointAir -notmatch '_point_air_state_seen' -or
                    $controllerScriptForPointAir -notmatch '(?s)def\s+OnFilterEvent\s*\([^)]*\).*?return\s+False') {
                    $problems += '目标点制空总控没有完整实现 UserEvent 过滤、战斗去重、达成停止和停止后清理。'
                }
                if ($sortieScript -notmatch $coreRuntimeImportPattern) {
                    $problems += '目标点制空探针使用 KCPS 运行时类型，但该出击脚本没有显式导入 KancollePlayerSimulatorKaiCore。'
                }
                if ($controllerScriptForPointAir -notmatch $coreRuntimeImportPattern) {
                    $problems += '目标点制空总控使用 UserEvent，但该总控脚本没有显式导入 KancollePlayerSimulatorKaiCore。'
                }
                if ([string]$probeSpec['MessagePrefix'] -ne [string]$counterSpec['MessagePrefix'] -or
                    $sortieScript -notmatch [regex]::Escape([string]$probeSpec['MessagePrefix']) -or
                    $controllerScriptForPointAir -notmatch [regex]::Escape([string]$probeSpec['MessagePrefix'])) {
                    $problems += '目标点制空探针与总控的内部消息前缀不一致。'
                }

                $competingPointAirStopFlags = @(@(
                    'StopIfEnemyFlagShipSunkFlag',
                    'StopIfBattleRankHigherOrEqualThanFlag',
                    'StopIfBossBattleRankHigherOrEqualThanFlag',
                    'StopIfArrivedEndPointFlag',
                    'StopIfEnemyDebufAtHomeFlag',
                    'StopIfAirBaseAttackNoDamageFlag'
                ) | Where-Object {
                    $controller.ContainsKey($_) -and [bool]$controller[$_]
                })
                if ($competingPointAirStopFlags.Count -gt 0) {
                    $problems += "目标点制空精确计数仍同时启用其他成功停止条件：$($competingPointAirStopFlags -join '、')；可能在空优次数达标前提前停止。"
                }
            }

            if (-not [bool]$controller['StopIfLoopCountLargerOrEqualThanFlag'] -or
                [int]$controller['StopIfLoopCountLargerOrEqualThanValue'] -le $requiredCount) {
                $problems += "目标点制空精确计数必须保留大于目标次数的循环安全上限；$requiredCount 次上限仍会把尝试次数冒充成功次数。"
            }

            $autoStopTriggerGuids = @($controller['AutoStoppedTriggerWorkflows'] | Where-Object {
                [bool]$_['Enabled']
            } | ForEach-Object { [string]$_['Guid'] })
            $autoStopNotifications = @($workflows | Where-Object {
                (Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleRaiseUserEventWorkflow') -and
                [string]$_['Guid'] -in $autoStopTriggerGuids
            })
            if (@($autoStopNotifications | Where-Object { [string]$_['Name'] -eq '通知通关' }).Count -gt 0 -or
                @($autoStopNotifications | Where-Object { [string]$_['Name'] -eq '通知停止' }).Count -eq 0) {
                $problems += '目标点制空配置有循环安全上限，自动停止后必须触发“通知停止”，不得触发“通知通关”。'
            }
            if ($memoText -notmatch '精确计数' -or $memoText -notmatch '安全上限') {
                $problems += '目标点制空配置的备注必须区分航空优势精确计数和循环安全上限两条停止路径。'
            }
        }

        foreach ($problem in @(Get-KcpsHighMoraleSingleLoopProblems -SortieWorkflows @($sortie) -RelationalWorkflows @($controller))) {
            $problems += ('高士气单次出击设置错误：{0}' -f $problem.Problem)
        }

        $controllerScript = [string]$controller['Script']
        $isHpGrinding = [bool]$sortie['MapHpInRangeFlag'] -and
            [int]$sortie['MapHpInRangeValueGauge'] -eq 0 -and
            [string]$group['Name'] -match '(?:磨血|削血)'
        if ($isHpGrinding) {
            $grindingMin = [int]$sortie['MapHpInRangeValueMin']
            $grindingMax = [int]$sortie['MapHpInRangeValueMax']
            $expectedGrindingMin = if ($hasExpectedGaugeRange) {
                $expectedGaugeRangeMin
            } elseif ($expectedFinalPhaseGaugeMax -gt 0) {
                $expectedFinalPhaseGaugeMax + 1
            } elseif ($null -ne $stageDesign -and $stageDesign.Contains('BossHp') -and [int]$stageDesign['BossHp'] -gt 0) {
                [int]$stageDesign['BossHp'] + 1
            } else {
                0
            }
            $expectedGrindingMax = if ($hasExpectedGaugeRange) { $expectedGaugeRangeMax } else { 99999 }
            if ($expectedGrindingMin -le 1) {
                $problems += '活动磨血路线规格缺少可验证的 GaugeRangeMin/Max 或 BossHp，无法核对磨血阶段门禁。'
            } elseif ($grindingMin -ne $expectedGrindingMin -or $grindingMax -ne $expectedGrindingMax) {
                $problems += "活动磨血的 HP 门禁为 $grindingMin–$grindingMax，但路线规格要求 $expectedGrindingMin–$expectedGrindingMax。"
            }
            if ([bool]$controller['StopIfEnemyFlagShipSunkFlag']) {
                $problems += '活动 HP 条按 Boss 旗舰实际损失 HP 削减；磨血总控不得用固定旗舰击沉次数代替 HP 进度。'
            }

            $hasHpAutoStop = $controllerScript -match 'def\s+OnAutoStop\s*\(' -and
                $controllerScript -match 'MapUtility\.CurrentHp\s*\(' -and
                $controllerScript -match 'MiscApi\.Maps\s*\('
            if ($hasHpAutoStop) {
                $expectedStopMax = if ($null -ne $routeSpec -and
                    $expectedFinalPhaseGaugeMax -gt 0) {
                    $expectedFinalPhaseGaugeMax
                } elseif ($null -ne $routeSpec -and
                    $routeSpec.ContainsKey('StageDesign') -and
                    $routeSpec['StageDesign'] -is [System.Collections.IDictionary] -and
                    $routeSpec['StageDesign'].ContainsKey('BossHp')) {
                    [int]$routeSpec['StageDesign']['BossHp']
                } else {
                    0
                }
                $thresholdMatch = [regex]::Match($controllerScript, '(?i)\bhp\s*<=\s*(?<value>\d+)')
                if ($expectedStopMax -le 0) {
                    $problems += '活动磨血路线规格的 StageDesign 缺少 BossHp，无法核对磨血停止线。'
                } elseif (-not $thresholdMatch.Success -or
                    [int]$thresholdMatch.Groups['value'].Value -ne $expectedStopMax) {
                    $actualThreshold = if ($thresholdMatch.Success) { $thresholdMatch.Groups['value'].Value } else { '<未找到>' }
                    $problems += "磨血 OnAutoStop 的 HP 停止线为 $actualThreshold，但出击门禁要求相邻停止线 $expectedStopMax。"
                }

                $hasVerifiedMapRefresh = $false
                foreach ($reference in @($controller['SupplyAfterWorkflows'] | Where-Object { [bool]$_['Enabled'] })) {
                    $related = @($workflows | Where-Object { [string]$_['Guid'] -eq [string]$reference['Guid'] }) | Select-Object -First 1
                    if ($null -ne $related -and
                        (Test-KcpsWorkflowType -Workflow $related -TypeName 'BasicOutfitLandBasedAirCorpWorkflow')) {
                        $hasVerifiedMapRefresh = $true
                        break
                    }
                }
                $hasNextLoopGaugeGateRecovery = [bool]$controller['IgnoreSortieFailure'] -and
                    -not [bool]$controller['FinishLoopIfSortieFailureFlag'] -and
                    [bool]$controller['MinimalSleepSecondsAfterFailureOccuredFlag'] -and
                    [int]$controller['MinimalSleepSecondsAfterFailureOccuredValue'] -ge 180 -and
                    [bool]$sortie['MapHpInRangeFlag'] -and
                    $expectedGrindingMin -gt 1 -and
                    [int]$sortie['MapHpInRangeValueMin'] -eq $expectedGrindingMin -and
                    [int]$sortie['MapHpInRangeValueMax'] -eq $expectedGrindingMax
                if (-not $hasVerifiedMapRefresh -and -not $hasNextLoopGaugeGateRecovery) {
                    $problems += '磨血总控使用即时 HP 自动停止，但既没有已验证的 mapinfo 刷新，也没有“忽略出击失败+等待180秒+下一循环阶段量值门禁”的恢复链。'
                }
            } else {
                $hasNextLoopGaugeGateRecovery = [bool]$controller['IgnoreSortieFailure'] -and
                    -not [bool]$controller['FinishLoopIfSortieFailureFlag'] -and
                    [bool]$controller['MinimalSleepSecondsAfterFailureOccuredFlag'] -and
                    [int]$controller['MinimalSleepSecondsAfterFailureOccuredValue'] -ge 180 -and
                    [bool]$sortie['MapHpInRangeFlag'] -and
                    $expectedGrindingMin -gt 1 -and
                    [int]$sortie['MapHpInRangeValueMin'] -eq $expectedGrindingMin -and
                    [int]$sortie['MapHpInRangeValueMax'] -eq $expectedGrindingMax
                if (-not $hasNextLoopGaugeGateRecovery) {
                    $problems += '活动磨血既没有基于 mapinfo 的 OnAutoStop，也没有“忽略出击失败+等待180秒+下一循环量值门禁”的恢复链；可能越过阶段或无限循环。'
                }
            }
        }

        $isHpFinal = [bool]$sortie['MapHpInRangeFlag'] -and
            [int]$sortie['MapHpInRangeValueGauge'] -eq 0 -and
            [string]$group['Name'] -match '(?:斩杀|击破|擊破)'
        if ($isHpFinal) {
            if (-not [bool]$controller['StopIfEnemyFlagShipSunkFlag']) {
                $problems += '活动HP条斩杀/击破必须启用Boss旗舰击沉直接停止；下一轮量值门禁或OnAutoStop只能作为后备。'
            } else {
                if ([int]$controller['StopIfEnemyFlagShipSunkValueConditionType'] -ne 1) {
                    $problems += '活动HP条斩杀/击破的Boss旗舰击沉停止必须使用地图点条件。'
                }
                if ([int]$controller['StopIfEnemyFlagShipSunkValueThreshold'] -ne 1) {
                    $problems += '活动HP条斩杀/击破必须在Boss旗舰击沉1次后停止。'
                }
            }

            if ($null -eq $routeSpec) {
                $problems += '活动HP条斩杀/击破缺少唯一匹配的路线规格，无法验证Boss进入边编号和击沉停止条件。'
            } else {
                $bossNodes = @($routeSpec['Nodes'] | Where-Object { [string]$_['Kind'] -eq 'boss' })
                if ($bossNodes.Count -ne 1) {
                    $problems += "活动HP条斩杀/击破的路线规格 $($routeSpec['Id']) 必须且只能定义一个Boss节点。"
                } else {
                    $bossNode = $bossNodes[0]
                    $bossValue = [int]$bossNode['Value']
                    if ([bool]$controller['StopIfEnemyFlagShipSunkFlag'] -and
                        [int]$controller['StopIfEnemyFlagShipSunkValueConditionValue'] -ne $bossValue) {
                        $problems += "Boss旗舰击沉停止指向 $($controller['StopIfEnemyFlagShipSunkValueConditionValue'])，但路线规格Boss进入边编号为 $bossValue。"
                    }
                    if (-not $bossNode.ContainsKey('BossKillCount') -or
                        [int]$bossNode['BossKillCount'] -ne 1) {
                        $problems += "活动HP条斩杀/击破的路线规格 $($routeSpec['Id']) 必须在Boss节点声明 BossKillCount=1。"
                    }
                }
            }
        }

        $isTpPhase = [bool]$sortie['MapHpInRangeFlag'] -and
            [int]$sortie['MapHpInRangeValueGauge'] -eq 1
        $hasTpAutoStop = $controllerScript -match 'def\s+OnAutoStop\s*\(' -and
            $controllerScript -match 'MapUtility\.CurrentHp\s*\(' -and
            $controllerScript -match 'MapUtility\.Gauge\s*\('
        if ($isTpPhase -and $hasTpAutoStop) {
            if (-not [bool]$controller['StopIfLoopCountLargerOrEqualThanFlag'] -or
                [int]$controller['StopIfLoopCountLargerOrEqualThanValue'] -lt 20) {
                $problems += '以削减或清空TP条为目标的自动循环配置，循环安全上限默认不得低于20次；10次可能在运输完成前提前停止。'
            }
            if ($controllerScript -notmatch 'api_gauge_num' -or
                $controllerScript -notmatch '(?i)gauge_num\s+is\s+not\s+None.{0,120}gauge_num\s*!=') {
                $problems += 'TP阶段的 OnAutoStop 没有核对 api_gauge_num；连续两条TP时可能误入下一阶段。'
            }
            $sortieScript = [string]$sortie['Script']
            $baselinePrefixMatch = [regex]::Match($controllerScript, '(?m)^\s*_tp_baseline_prefix\s*=\s*["''](?<prefix>[^"'']+)["'']')
            $hasPreSortieTpBaseline = [bool]$sortie['EnableScriptSortieChecker'] -and
                $sortieScript -match 'def\s+OnCheckSortieFleetAndLandBases\s*\(' -and
                $sortieScript -match 'MiscApi\.Maps\s*\(' -and
                $sortieScript -match 'Utility\.RaiseEvent\s*\(\s*UserEvent\s*\(' -and
                $sortieScript -match 'MapGauge\.Tp' -and
                $sortieScript -match 'api_gauge_num'
            if (-not $baselinePrefixMatch.Success -or
                $controllerScript -notmatch 'def\s+OnFilterEvent\s*\(' -or
                $controllerScript -notmatch 'isinstance\s*\(\s*e\s*,\s*UserEvent\s*\)' -or
                $controllerScript -notmatch '(?i)\btp\s*>\s*_baseline_tp' -or
                -not $hasPreSortieTpBaseline) {
                $problems += 'TP阶段必须在每次出击前主动刷新 mapinfo 并发送本轮TP基线 UserEvent，由总控 OnFilterEvent 记录后交给 OnAutoStop 判断。'
            } elseif ($sortieScript -notmatch [regex]::Escape($baselinePrefixMatch.Groups['prefix'].Value)) {
                $problems += '单次出击发送的TP基线消息前缀与总控监听前缀不一致。'
            }
            if ($controllerScript -notmatch '(?s)def\s+OnFilterEvent\s*\([^)]*\).*?return\s+False') {
                $problems += '总控收到TP基线 UserEvent 后必须在 OnFilterEvent 返回 False，避免该内部消息触发关联出击状态机。'
            }
            if ($controllerScript -match 'def\s+OnEnabled\s*\([^)]*\)\s*:\s*(?:\r?\n[ \t]+.*){0,12}(?:MapUtility|MiscApi)\.') {
                $problems += 'TP阶段不得在 OnEnabled 中读取海域量值建立基线；该时点可能早于 mapinfo 刷新。'
            }
            if ($controllerScript -notmatch '(?i)gauge\s*!=\s*MapGauge\.Tp' -or
                $controllerScript -notmatch '(?i)tp\s+is\s+None' -or
                $controllerScript -notmatch '(?i)\btp\s*<=\s*0') {
                $problems += 'TP阶段的 OnAutoStop 必须覆盖量值变为非TP、量值消失和TP归零三种停止证据。'
            }

            $hasVerifiedTpMapRefresh = $false
            foreach ($reference in @($controller['SupplyAfterWorkflows'] | Where-Object { [bool]$_['Enabled'] })) {
                $related = @($workflows | Where-Object { [string]$_['Guid'] -eq [string]$reference['Guid'] }) | Select-Object -First 1
                if ($null -ne $related -and
                    (Test-KcpsWorkflowType -Workflow $related -TypeName 'BasicOutfitLandBasedAirCorpWorkflow')) {
                    $hasVerifiedTpMapRefresh = $true
                    break
                }
            }
            $hasNextLoopTpGateRecovery = [bool]$controller['IgnoreSortieFailure'] -and
                -not [bool]$controller['FinishLoopIfSortieFailureFlag'] -and
                [bool]$controller['MinimalSleepSecondsAfterFailureOccuredFlag'] -and
                [int]$controller['MinimalSleepSecondsAfterFailureOccuredValue'] -ge 180 -and
                [bool]$sortie['MapHpInRangeFlag'] -and
                [int]$sortie['MapHpInRangeValueMin'] -eq 1 -and
                [int]$sortie['MapHpInRangeValueMax'] -eq 99999
            if (-not $hasVerifiedTpMapRefresh -and -not $hasNextLoopTpGateRecovery) {
                $problems += 'TP阶段总控使用即时量值自动停止，但既没有已验证的 mapinfo 刷新，也没有“忽略出击失败+等待180秒+下一循环1至99999量值门禁”的恢复链。'
            }
        }

        $readsOnlyLatestBattle = $controllerScript -match 'GameState\.Battle\s*\(' -or
            $controllerScript -match 'api_req_(?:sortie|combined_battle|battle_midnight).*(?:battle|airbattle)'
        if ($readsOnlyLatestBattle -and
            ($memoText -notmatch '最后一场战斗' -or
             $memoText -notmatch '唯一标识|去重')) {
            $problems += '总控读取最近一次战斗状态，却没有证明目标点是本次出击最后一场战斗并按唯一标识去重；后续战斗会覆盖结果。'
        }
    }

    $suppressWorkflows = @($workflows | Where-Object {
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleRaiseUserEventWorkflow') -and
        [string]$_['Name'] -eq '抑制其他配置'
    })
    if ($suppressWorkflows.Count -ne 1) {
        $problems += ('活动配置必须且只能包含一个“抑制其他配置”执行单元，当前为 {0} 个。' -f $suppressWorkflows.Count)
    } elseif ([string]$suppressWorkflows[0]['Message'] -ne '正在连续出击') {
        $problems += '“抑制其他配置”必须发送“正在连续出击”。'
    } elseif ($null -ne $controller) {
        $suppressGuid = [string]$suppressWorkflows[0]['Guid']
        $suppressRef = @($controller['QuestBeforeWorkflows'] | Where-Object {
            [string]$_['Guid'] -eq $suppressGuid -and [bool]$_['Enabled']
        })
        if ($suppressRef.Count -eq 0) {
            $problems += '“抑制其他配置”没有由总控在循环开始前正确触发。'
        }
        if ([int]$controller['QuestBeforeFinishedEventThreshold'] -ne 0) {
            $problems += '“抑制其他配置”只发送 UserEvent，不会发送接交任务完成事件；QuestBeforeFinishedEventThreshold 必须为 0，否则总控会永久等待。'
        }
    }

    $memo = if ($null -ne $memoWorkflow) { [string]$memoWorkflow['Memo'] } else { '' }
    $stageText = ([string]$group['Name']) + "`n" + $memo
    $objectiveSection = Get-EventMemoSection -Memo $memo -Name '目标'
    $objectiveHeadline = @($objectiveSection -split "`r?`n" | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | Select-Object -First 1)
    $objectiveText = ([string]$group['Name']) + "`n" + $objectiveSection
    $isPointUnlockObjective = $objectiveText -match '(?:开路|開路|解谜|解謎|ギミック|削甲|破甲)' -and
        $objectiveText -match '(?:[A-Z][A-Z0-9]*点|目标点|目標点).{0,60}(?:S胜|S勝|A胜|A勝|到达|到達)'
    $hasNamedPhase = $stageText -match '(?<![A-Za-z0-9])P\d+(?![A-Za-z0-9])'
    $isUnlockPhase = $null -ne $stageDesign -and [string]$stageDesign['Phase'] -eq 'Unlock'
    $isFarmingPhase = $null -ne $stageDesign -and [string]$stageDesign['Phase'] -eq 'Farming'
    $isLevelingPhase = $null -ne $stageDesign -and [string]$stageDesign['Phase'] -eq 'Leveling'
    $problems += @(Get-KcpsLevelingProblems -RouteSpec $routeSpec -Controller $controller -Sortie $sortie -Maps $maps -Workflows $workflows -Ships $ships -MasterShips $masterShips -Equips $equips -MasterEquips $masterEquips -Groups $groups -Routes $routeSpecs -Const $const)
    $problems += @(Get-KcpsFarmingProblems -RouteSpec $routeSpec -Controller $controller -Sortie $sortie -Maps $maps)
    if ($null -ne $sortie -and $hasNamedPhase -and
        $null -ne $liveGauge -and $liveGauge.Name -in @('HP', 'TP') -and
        -not $isUnlockPhase -and
        -not $isFarmingPhase -and
        -not $isLevelingPhase -and
        -not $isDifferentDeclaredStage -and
        -not [bool]$sortie['MapHpInRangeFlag']) {
        $problems += "当前活动地图 $($liveGauge.MapId) 存在 $($liveGauge.Name) 海域量值；P阶段配置必须启用海域量值检查作为阶段门禁。"
    }
    if ($null -ne $sortie -and [bool]$sortie['MapHpInRangeFlag'] -and
        $memo -notmatch '【海域量值】') {
        $problems += '活动配置启用 HP/TP 海域量值检查时，必须在【海域量值】中写明类型、区间、阶段门禁用途、当前值/最大值和核对来源。'
    }
    if ($null -ne $gaugePhaseBoundary -and
        $null -ne $stageDesign -and
        [string]$stageDesign['Phase'] -in @('Grinding','Final','SemiAutomatic')) {
        $gaugeSection = Get-EventMemoSection -Memo $memo -Name '海域量值'
        $gaugeSectionCompact = $gaugeSection -replace '\s+', ''
        $grindingBoss = $gaugePhaseBoundary['GrindingBoss']
        $finalBoss = $gaugePhaseBoundary['FinalBoss']
        $expectedBoundaryMemoParts = @(
            "磨血Boss$([string]$grindingBoss['Name'])耐久$([int]$grindingBoss['Hp'])",
            "最终Boss$([string]$finalBoss['Name'])耐久$([int]$finalBoss['Hp'])",
            "最终编成切换上界为$expectedFinalPhaseGaugeMax",
            "磨血门禁$($expectedFinalPhaseGaugeMax + 1)～99999",
            "斩杀门禁1～$expectedFinalPhaseGaugeMax"
        )
        foreach ($part in $expectedBoundaryMemoParts) {
            if ($gaugeSectionCompact -notlike "*$part*") {
                $problems += "【海域量值】未准确记录阶段数据：$part。"
            }
        }
    }
    if ($null -ne $sortie -and [bool]$sortie['MapHpInRangeFlag'] -and
        $isPointUnlockObjective -and $memo -notmatch '本身不|不消耗|不削减|不减少') {
        $problems += '指定点开路、解谜或削甲目标使用海域量值阶段门禁时，备注必须明确目标本身是否消耗该量值。'
    }
    if ($memo -notmatch '【锁船】') { $problems += '备注未记录本阶段锁船标签。' }
    if ($memo -notmatch '多号机') { $problems += '备注未记录多号机判定与取舍。' }
    if ($memo -notmatch '攻略' -or $memo -notmatch '锁船分配表|分配表') {
        $problems += '备注必须同时记录攻略与锁船分配表依据。'
    }
    foreach ($section in @('【攻略与分配】', '【候选与排除】', '【选船结论】', '【配装对照】')) {
        if ($memo -notmatch [regex]::Escape($section)) {
            $problems += "活动备注缺少 $section，不能完整复核选船与配装决策。"
        }
    }
    $noEnemyAir = $memo -match '本路线没有航空战|路线没有航空敌人|没有敌方航空兵力'
    $refitWorkflows = @($workflows | Where-Object {
        Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicRefitEquipmentWorkflow'
    })
    $exSlotMachineGuns = @()
    $exSlotTorpedoLookouts = @()
    foreach ($refitWorkflow in $refitWorkflows) {
        foreach ($shipRefit in @($refitWorkflow['Ships'])) {
            foreach ($slot in @($shipRefit['Slots'] | Where-Object { [int]$_['Slot'] -eq 6 })) {
                foreach ($equipment in @($slot['Equipments'])) {
                    $equipmentName = [string]$equipment['SelectValue']
                    if ($equipmentName -match '機銃|机枪') {
                        $exSlotMachineGuns += $equipmentName
                    }
                    if ($equipmentName -match '水雷戦隊\s*熟練見張員|水雷战队\s*熟练见张员') {
                        $exSlotTorpedoLookouts += $equipmentName
                    }
                }
            }
        }
    }
    if ($noEnemyAir -and $exSlotMachineGuns.Count -gt 0 -and $memo -notmatch '【补强机枪理由】') {
        $problems += '备注明确本路线没有航空战，但补强槽仍配置机枪；应改用经舰船补正与射程推演后更合适的装备，或在【补强机枪理由】说明不可替代收益。'
    }
    if ($exSlotTorpedoLookouts.Count -gt 0 -and $memo -notmatch '射程') {
        $problems += '补强槽使用水雷战队熟练见张员时，备注必须说明射程变为中对攻击顺序的影响。'
    }
    $objectiveIdentityText = ([string]$group['Name']) + "`n" + [string]$objectiveHeadline
    $isTransportObjective = $objectiveIdentityText -match '(?:运输|輸送|TP条|TPゲージ)'
    $isPointBattleObjective = $isPointUnlockObjective -and
        $objectiveText -match '(?:S胜|S勝|A胜|A勝)'
    if ($isPointBattleObjective -and $null -ne $sortie -and $null -ne $routeSpec -and
        $routeSpec.ContainsKey('StageDesign') -and $routeSpec['StageDesign'] -is [System.Collections.IDictionary] -and
        [string]$routeSpec['StageDesign']['Target'] -eq 'Rank' -and $routeSpec['StageDesign'].ContainsKey('TargetValue')) {
        $targetValue = [int]$routeSpec['StageDesign']['TargetValue']
        $targetStrategies = @($sortie['Strategies'] | Where-Object {
            [int]$_['Condition']['Type'] -eq 1 -and [int]$_['Condition']['Value'] -eq $targetValue
        })
        $allowSmokeAtObjective = $routeSpec.ContainsKey('AllowSmokeAtVictoryObjective') -and
            [bool]$routeSpec['AllowSmokeAtVictoryObjective']
        if (-not $allowSmokeAtObjective -and @($targetStrategies | Where-Object {
            [bool]$_['Strategy']['DefaultSmoke']
        }).Count -gt 0) {
            $problems += '本配置要求目标点取得 A/S 胜，却在目标点启用了烟幕。烟幕会压低己方命中与伤害；应关闭，或在路线规格中显式声明 AllowSmokeAtVictoryObjective 并给出胜率依据。'
        }
    }
    if ($isPointBattleObjective -and -not $isTransportObjective -and $null -ne $mainRefit -and $null -ne $sortie) {
        $reusesOldStage = $memo -match '(?:沿用|复用|回打|旧阶段|原阶段|前一阶段|上一阶段)'
        if ($reusesOldStage) {
            $targetChangeAudit = Get-EventMemoSection -Memo $memo -Name '目标变化审计'
            if ([string]::IsNullOrWhiteSpace($targetChangeAudit)) {
                $problems += '复用旧阶段舰队骨架的非TP指定点胜利配置必须填写【目标变化审计】，证明配装和自动化已按新目标重算。'
            } else {
                foreach ($requiredAuditItem in @('旧目标', '新目标', '仅复用', '已重算', '已删除')) {
                    if ($targetChangeAudit -notmatch [regex]::Escape($requiredAuditItem)) {
                        $problems += ('【目标变化审计】缺少“{0}”。' -f $requiredAuditItem)
                    }
                }
            }
        }
        $pureTransportEquipments = @(
            foreach ($shipRefit in @($mainRefit['Ships'] | Where-Object {
                [int]$_['Fleet'] -eq [int]$sortie['Fleet']
            })) {
                foreach ($slot in @($shipRefit['Slots'])) {
                    foreach ($equipment in @($slot['Equipments'])) {
                        $equipmentName = [string]$equipment['SelectValue']
                        if ($equipmentName -match '^(?:大発動艇|特大発動艇|ドラム缶\(輸送用\))$') {
                            $equipmentName
                        }
                    }
                }
            }
        )
        if ($pureTransportEquipments.Count -gt 0 -and $memo -notmatch '【非运输舟艇理由】') {
            $problems += ('非TP的指定点胜利目标仍在主舰队配置了 {0} 件纯运输装备；必须按战斗目标重配，或在【非运输舟艇理由】逐船说明对地战斗用途。' -f $pureTransportEquipments.Count)
        }
        $memoForStaleTransportCheck = $memo -replace '(?ms)^【目标变化审计】\r?\n.*?(?=^【|\z)', ''
        if ($memoForStaleTransportCheck -match '(?:S胜|S勝|A胜|A勝)(?![^。\r\n]{0,8}(?:不结算|不计算|不需要|不消耗))[^。\r\n]{0,8}TP|TP约|每轮TP|三格运输|运输核心|承担运输|运输与烟幕') {
            $problems += '非TP的指定点胜利目标仍在备注中引用上一阶段的TP或运输分工，说明目标变化后没有完整重做配装决策。'
        }
        if ([string]$sortie['Memo'] -match '(?:运输|輸送|TP条|TPゲージ)') {
            $problems += '非TP的指定点胜利目标在出击执行单元备注中仍标记为运输阶段。'
        }
    }
    $sourceText = Get-EventMemoSection -Memo $memo -Name '资料来源'
    if ([string]::IsNullOrWhiteSpace($sourceText) -or $sourceText -notmatch '(?s)攻略.*?https?://' -or $sourceText -notmatch '(?s)锁船分配表.*?https?://') {
        $problems += '资料来源必须分别写明攻略与锁船分配表的名称和 URL。'
    }
    foreach ($forbidden in @('首次出击会贴', '贴条不可逆', '不可撤销', '【攻略状态】', '新版攻略', '旧版攻略', '最新攻略', '进入边')) {
        if ($memo -match [regex]::Escape($forbidden)) {
            $problems += "活动备注包含不应写入的人类说明或内部实现信息：$forbidden。"
        }
    }
    if ($memo -match '(?m)(?:^|[、，；;\s])(?:[A-Z][A-Z0-9]*)\s*=\s*\d+') {
        $problems += '活动备注不得列出地图点条件值或进入边编号；这些数值只写入条件策略。'
    }
    $memoLines = @($memo -split '\r?\n')
    $structuredOperationLinePattern =
        '^(?:第(?:一|二|三|[1-3])基地航空队(?:[｜|]|[：:])|第\s*[1-4]\s*槽[：:]|防空制空[：:]|自动控制[：:])'
    for ($lineIndex = 0; $lineIndex -lt $memoLines.Count; $lineIndex++) {
        $line = $memoLines[$lineIndex]
        $trimmed = $line.Trim()
        $displayWidth = Get-EventMemoDisplayWidth -Text $trimmed
        if ($displayWidth -gt 120 -and $trimmed -notmatch '^https?://') {
            $problems += ('活动备注正文超过120显示列：{0}' -f $trimmed.Substring(0, [Math]::Min(30, $trimmed.Length)))
        }
        if ($lineIndex + 1 -lt $memoLines.Count) {
            $next = $memoLines[$lineIndex + 1].Trim()
            $isContinuation = -not [string]::IsNullOrWhiteSpace($trimmed) -and
                -not [string]::IsNullOrWhiteSpace($next) -and
                $trimmed -notmatch '^【[^】]+】$' -and
                $next -notmatch '^【[^】]+】$' -and
                $trimmed -notmatch '^https?://' -and
                $trimmed -notmatch $structuredOperationLinePattern -and
                $next -notmatch $structuredOperationLinePattern -and
                $trimmed -notmatch '[。！？；：.!?;:]$'
            if ($isContinuation -and (Get-EventMemoDisplayWidth -Text ($trimmed + $next)) -le 120) {
                $problems += ('活动备注在仍可容纳同一连续表达时过早换行：{0}' -f $trimmed.Substring(0, [Math]::Min(30, $trimmed.Length)))
            }
        }
    }
    $normalizedMemo = $memo -replace "`r`n", "`n"
    $sectionHeadings = @([regex]::Matches($normalizedMemo, '(?m)^【[^】]+】'))
    foreach ($heading in @($sectionHeadings | Select-Object -Skip 1)) {
        if ($heading.Index -lt 2 -or $normalizedMemo.Substring($heading.Index - 2, 2) -ne "`n`n") {
            $problems += ('活动备注的小节“{0}”前缺少空白行。' -f $heading.Value)
        }
    }

    $eventClearMessagePattern = '^E\d+\s+P\d+(?:\s+\S+){3,}\s+Clear$'
    $eventStoppedMessagePattern = '^E\d+\s+(?:P\d+|舰船练级)(?:\s+\S+){2,}\s+已停止$'
    $noticeWorkflows = @($workflows | Where-Object {
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleRaiseUserEventWorkflow') -and
        [string]$_['Name'] -in @('通知通关', '通知停止')
    })
    if ($noticeWorkflows.Count -ne 1) {
        $problems += ('活动配置必须且只能包含一个名为“通知通关”或“通知停止”的执行单元，当前为 {0} 个。' -f $noticeWorkflows.Count)
    } else {
        $noticeName = [string]$noticeWorkflows[0]['Name']
        $noticeMessage = [string]$noticeWorkflows[0]['Message']
        if ($noticeName -eq '通知通关' -and $noticeMessage -notmatch $eventClearMessagePattern) {
            $problems += '活动完成消息必须使用“E编号 阶段 用途 目标 条件 Clear”，格式为“E编号 P阶段 用途 目标 条件 Clear”；不得省略用途、评级或次数。'
        }
        if ($noticeName -eq '通知停止' -and $noticeMessage -notmatch $eventStoppedMessagePattern) {
            $problems += '活动停止消息必须使用“E编号 阶段 用途 目标 已停止”，且不得包含 Clear。'
        }
        if ($memo -notmatch [regex]::Escape($noticeMessage)) {
            $problems += "【终止】必须逐字写明${noticeName}将发送的完整消息。"
        }
        if ($null -ne $controller) {
            $noticeGuid = [string]$noticeWorkflows[0]['Guid']
            $noticeRefs = @($controller['AutoStoppedTriggerWorkflows'] | Where-Object {
                [bool]$_['Enabled'] -and [string]$_['Guid'] -eq $noticeGuid
            })
            if ($noticeRefs.Count -eq 0) {
                $problems += "${noticeName}没有挂入总控的自动停止后触发列表。"
            }
        }
    }

    $supportText = Get-EventMemoSection -Memo $memo -Name '支援'
    if ([string]::IsNullOrWhiteSpace($supportText)) {
        $problems += '活动备注缺少【支援】，无法判断是否应保留第三、四舰队流程。'
    } else {
        $routeMentioned = $supportText -match '道中支援'
        $bossMentioned = $supportText -match '决战支援'
        $routeDisabled = $supportText -match '(?:不使用|不用|不启用).{0,8}道中支援|道中支援.{0,8}(?:不使用|不用|不启用)'
        $bossDisabled = $supportText -match '(?:不使用|不用|不启用).{0,8}决战支援|决战支援.{0,8}(?:不使用|不用|不启用)'
        $usesRouteSupport = $routeMentioned -and -not $routeDisabled
        $usesBossSupport = $bossMentioned -and -not $bossDisabled
        $groupDeclaresRouteSupport = [string]$group['Name'] -match '道中支援'
        $groupDeclaresBossSupport = [string]$group['Name'] -match '决战支援'
        if ($null -ne $sortie) {
            if ($groupDeclaresRouteSupport -ne [bool]$sortie['NormalSupportExpedition']) {
                $problems += '配置名的“道中支援”标记与出击执行单元的前卫支援开关不一致。'
            }
            if ($groupDeclaresBossSupport -ne [bool]$sortie['BossSupportExpedition']) {
                $problems += '配置名的“决战支援”标记与出击执行单元的决战支援开关不一致。'
            }
        }
        if ($groupDeclaresRouteSupport -ne $usesRouteSupport) {
            $problems += '配置名的“道中支援”标记与【支援】备注结论不一致。'
        }
        if ($groupDeclaresBossSupport -ne $usesBossSupport) {
            $problems += '配置名的“决战支援”标记与【支援】备注结论不一致。'
        }
        $mainFleetForSupport = if ($null -ne $controller -and $controller.ContainsKey('Fleet')) {
            [int]$controller['Fleet']
        } elseif ($null -ne $sortie) {
            [int]$sortie['Fleet']
        } else {
            0
        }
        $routeSupportFleet = if ($null -ne $sortie -and
            [bool]$sortie['NormalSupportExpedition']) {
            [int]$sortie['NormalSupportExpeditionFleet']
        } else {
            3
        }
        $bossSupportFleet = if ($null -ne $sortie -and
            [bool]$sortie['BossSupportExpedition']) {
            [int]$sortie['BossSupportExpeditionFleet']
        } else {
            4
        }

        $routeOrganize = @($workflows | Where-Object {
            (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') -and
            [int]$_['Fleet'] -eq $routeSupportFleet -and
            $mainFleetForSupport -ne $routeSupportFleet
        })
        $routeSupply = @($workflows | Where-Object {
            (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicSupplyFleetWorkflow') -and
            [int]$_['Fleet'] -eq $routeSupportFleet -and
            $mainFleetForSupport -ne $routeSupportFleet
        })
        $bossOrganize = @($workflows | Where-Object {
            (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') -and
            [int]$_['Fleet'] -eq $bossSupportFleet -and
            $mainFleetForSupport -ne $bossSupportFleet
        })
        $bossSupply = @($workflows | Where-Object {
            (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicSupplyFleetWorkflow') -and
            [int]$_['Fleet'] -eq $bossSupportFleet -and
            $mainFleetForSupport -ne $bossSupportFleet
        })
        if ($usesRouteSupport -and -not $usesBossSupport -and
            $routeSupportFleet -eq $bossSupportFleet) {
            $bossOrganize = @()
            $bossSupply = @()
        }
        if ($usesBossSupport -and -not $usesRouteSupport -and
            $routeSupportFleet -eq $bossSupportFleet) {
            $routeOrganize = @()
            $routeSupply = @()
        }
        $supportFleetIds = @(@($routeSupportFleet, $bossSupportFleet) | Select-Object -Unique)
        $supportRefits = @($workflows | Where-Object {
            (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicRefitEquipmentWorkflow') -and (
                [string]$_['Name'] -match '支援|所有舰队' -or
                @($_['Ships'] | Where-Object {
                    [int]$_['Fleet'] -in $supportFleetIds -and
                    [int]$_['Fleet'] -ne $mainFleetForSupport
                }).Count -gt 0
            )
        })
        $supportDocking = @($workflows | Where-Object {
            (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicDockingWorkflow') -and [string]$_['Name'] -match '支援'
        })

        if ($usesRouteSupport) {
            if ($routeOrganize.Count -eq 0) { $problems += "备注决定使用道中支援，但缺少第 $routeSupportFleet 舰队编成执行单元。" }
            if ($routeSupply.Count -eq 0) { $problems += "备注决定使用道中支援，但缺少第 $routeSupportFleet 舰队补给执行单元。" }
            if ($null -ne $sortie) {
                if (-not [bool]$sortie['NormalSupportExpedition'] -or
                    [int]$sortie['NormalSupportExpeditionFleet'] -ne $routeSupportFleet) {
                    $problems += "备注决定使用道中支援，但出击执行单元没有把第 $routeSupportFleet 舰队设为前卫支援。"
                }

            }
            if ($routeOrganize.Count -eq 1 -and [bool]$sortie['NormalSupportExpeditionCheckMorale']) {
                $position = 0
                foreach ($candidatePosition in @($routeOrganize[0]['Positions'])) {
                    $position++
                    $changesUnstarred = [bool]$candidatePosition['ChangeIfMoraleInRangeFlag'] -and
                        [int]$candidatePosition['ChangeIfMoraleInRangeValueMin'] -eq 0 -and
                        [int]$candidatePosition['ChangeIfMoraleInRangeValueMax'] -ge 49
                    $skipsUnstarred = [bool]$candidatePosition['SkipMoraleInRangeFlag'] -and
                        [int]$candidatePosition['SkipMoraleInRangeValueMin'] -eq 0 -and
                        [int]$candidatePosition['SkipMoraleInRangeValueMax'] -ge 49
                    if (-not $changesUnstarred -or -not $skipsUnstarred) {
                        $problems += "前卫支援编成位置 $position 没有同时换下cond不高于49的船并跳过cond不高于49的候选；这会在派出时被全员闪检查拦截。"
                    }
                }
            }
        } elseif ($routeOrganize.Count -gt 0 -or $routeSupply.Count -gt 0) {
            $problems += '备注未使用道中支援，但配置仍残留第三舰队支援编成或补给空壳。'
        }
        if ($usesBossSupport) {
            if ($bossOrganize.Count -eq 0) { $problems += "备注决定使用决战支援，但缺少第 $bossSupportFleet 舰队编成执行单元。" }
            if ($bossSupply.Count -eq 0) { $problems += "备注决定使用决战支援，但缺少第 $bossSupportFleet 舰队补给执行单元。" }
            if ($null -ne $sortie) {
                if (-not [bool]$sortie['BossSupportExpedition'] -or
                    [int]$sortie['BossSupportExpeditionFleet'] -ne $bossSupportFleet) {
                    $problems += "备注决定使用决战支援，但出击执行单元没有把第 $bossSupportFleet 舰队设为决战支援。"
                }

            }
            if ($bossOrganize.Count -eq 1 -and @($bossOrganize[0]['Positions']).Count -gt 0 -and [bool]$sortie['BossSupportExpeditionCheckMorale']) {
                $flagshipPosition = $bossOrganize[0]['Positions'][0]
                $changesUnstarredFlagship = [bool]$flagshipPosition['ChangeIfMoraleInRangeFlag'] -and
                    [int]$flagshipPosition['ChangeIfMoraleInRangeValueMin'] -eq 0 -and
                    [int]$flagshipPosition['ChangeIfMoraleInRangeValueMax'] -ge 49
                $skipsUnstarredFlagship = [bool]$flagshipPosition['SkipMoraleInRangeFlag'] -and
                    [int]$flagshipPosition['SkipMoraleInRangeValueMin'] -eq 0 -and
                    [int]$flagshipPosition['SkipMoraleInRangeValueMax'] -ge 49
                if (-not $changesUnstarredFlagship -or -not $skipsUnstarredFlagship) {
                    $problems += '决战支援编成旗舰没有同时换下cond不高于49的船并跳过cond不高于49的候选；这会在派出时被旗舰闪检查拦截。'
                }
            }
        } elseif ($bossOrganize.Count -gt 0 -or $bossSupply.Count -gt 0) {
            $problems += '备注未使用决战支援，但配置仍残留第四舰队支援编成或补给空壳。'
        }
        if ($usesRouteSupport -or $usesBossSupport) {
            if ($supportRefits.Count -eq 0) { $problems += '使用支援舰队时必须有覆盖支援舰队的改装执行单元。' }
            if ($supportDocking.Count -eq 0) { $problems += '使用支援舰队时必须保留支援舰队出击前入渠检查执行单元。' }
            foreach ($supportFleet in @(
                [pscustomobject]@{ Fleet = $routeSupportFleet; Enabled = $usesRouteSupport; Organize = @($routeOrganize | Select-Object -First 1) },
                [pscustomobject]@{ Fleet = $bossSupportFleet; Enabled = $usesBossSupport; Organize = @($bossOrganize | Select-Object -First 1) }
            )) {
                if (-not $supportFleet.Enabled -or $supportFleet.Organize.Count -eq 0) { continue }
                $position = 0
                foreach ($positionConfig in @($supportFleet.Organize[0]['Positions'])) {
                    $position++
                    $supportSelections = @($positionConfig['Selections'])
                    if (@($supportSelections | Where-Object { [int]$_['Type'] -eq 8 }).Count -gt 0) {
                        $positionRefits = @(
                            foreach ($supportRefit in $supportRefits) {
                                $supportRefit['Ships'] | Where-Object {
                                    [int]$_['Fleet'] -eq [int]$supportFleet.Fleet -and
                                    [int]$_['SelectMethod'] -eq 0 -and [int]$_['SelectValue'] -eq $position
                                }
                            }
                        )
                        if ($positionRefits.Count -ne 1) {
                            $problems += "第 $($supportFleet.Fleet) 舰队第 $position 位通用支援候选没有唯一的按位置改装。"
                        }
                    }

                }
            }
        } elseif ($supportRefits.Count -gt 0 -or $supportDocking.Count -gt 0) {
            $warnings += '当前不使用支援，但仍有名称指向支援/所有舰队的改装或入渠执行单元；请确认它不是模板残留。'
        }
    }

    $landBaseText = Get-EventMemoSection -Memo $memo -Name '陆航'
    if ([string]::IsNullOrWhiteSpace($landBaseText)) {
        $problems += '活动备注缺少【陆航】，无法核对三队基地航空队的条件配置。'
    } elseif ($null -ne $sortie) {
        if ($null -ne $identityCheckerSpec -and
            $identityCheckerSpec['LandBases'] -is [System.Collections.IDictionary]) {
            $ownedEquipMasterIds = @($equips.Values | ForEach-Object {
                [int]$_['api_slotitem_id']
            })
            $landBaseComparisonText = Get-EventMemoSection -Memo $memo -Name '陆航方案比较'
            $checkedVariantPairs = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($corpsKey in @($identityCheckerSpec['LandBases'].Keys)) {
                foreach ($configuredPlane in @($identityCheckerSpec['LandBases'][$corpsKey])) {
                    $configuredName = [string]$configuredPlane['Name']
                    if ([string]::IsNullOrWhiteSpace($configuredName) -or
                        $configuredName -match '\(熟練\)') {
                        continue
                    }
                    $plusIndex = $configuredName.IndexOf('+')
                    $trainedName = if ($plusIndex -ge 0) {
                        $configuredName.Substring(0, $plusIndex) +
                            '(熟練)' +
                            $configuredName.Substring($plusIndex)
                    } else {
                        $configuredName + '(熟練)'
                    }
                    $trainedMasterEntries = @($const['$equips'].Values | Where-Object {
                        [string]$_['api_name'] -eq $trainedName
                    })
                    if ($trainedMasterEntries.Count -eq 0) { continue }
                    $trainedMasterId = [int]$trainedMasterEntries[0]['api_id']
                    if ($trainedMasterId -notin $ownedEquipMasterIds) { continue }
                    $pairKey = "$configuredName|$trainedName"
                    if (-not $checkedVariantPairs.Add($pairKey)) { continue }

                    if ([string]::IsNullOrWhiteSpace($landBaseComparisonText)) {
                        $problems += ('陆航使用 {0}，账号同时拥有 {1}，但备注缺少【陆航方案比较】；不能静默跳过熟练型号。' -f
                            $configuredName, $trainedName)
                        continue
                    }
                    if ($landBaseComparisonText -notmatch [regex]::Escape($configuredName) -or
                        $landBaseComparisonText -notmatch [regex]::Escape($trainedName)) {
                        $problems += ('【陆航方案比较】没有同时点名 {0} 和 {1}，无法复核型号取舍。' -f
                            $configuredName, $trainedName)
                    }
                    if ($landBaseComparisonText -notmatch '改修' -or
                        $landBaseComparisonText -notmatch '制空' -or
                        $landBaseComparisonText -notmatch '命中|抗击坠|対空射撃回避') {
                        $problems += ('【陆航方案比较】必须比较 {0} 与熟练型号的改修、制空、命中或抗击坠，不能只按名称判断上下位。' -f
                            $configuredName)
                    }
                }
            }
        }
        if ($landBaseText -notmatch '基地空袭[：:]\s*(?:有|无)') {
            $problems += '【陆航】必须明确写“基地空袭：有”或“基地空袭：无”；舰队路线无航空战不能替代基地空袭判断。'
        }
        $landBaseWorkflows = @($workflows | Where-Object {
            Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOutfitLandBasedAirCorpWorkflow'
        })
        $usedCorps = @()
        foreach ($corps in 1..3) {
            $action = [int]$sortie["LandBasedAirCorps$($corps)Action"]
            if ($action -in 1, 2) { $usedCorps += $corps }
            $requiresFullProficiency = [bool]$sortie["LandBasedAirCorps$($corps)CheckAnyProficiencyNotFull"]
            if ($requiresFullProficiency) {
                if ($action -notin 1, 2) {
                    $problems += "第 $corps 基地航空队未用于出击或防空，却残留满熟练度检查。"
                }
                if ([string]::IsNullOrWhiteSpace(
                    (Get-EventMemoSection -Memo $memo -Name '陆航满熟练度理由')
                )) {
                    $problems += "第 $corps 基地航空队开启满熟练度检查，但备注缺少【陆航满熟练度理由】、检查目的与补充方式。"
                }
            }

            $label = @('一', '二', '三')[$corps - 1]
            $declaredAction = if ($action -eq 1) { '出击' } elseif ($action -eq 2) { '防空' } else { '不使用' }
            if ($action -in 1, 2) {
                if ($landBaseText -notmatch "(?:第)?(?:$label|$corps)(?:基地航空)?队[^；;。]*$declaredAction") {
                    $problems += "第 $corps 基地航空队在出击执行单元中设为$declaredAction，但【陆航】没有按队写明相同动作。"
                }
            }
        }

        if ($usedCorps.Count -eq 0) {
            if ($landBaseText -notmatch '不使用') {
                $problems += '三队陆航均未使用，但【陆航】没有明确写“不使用”。'
            }
            if ($landBaseWorkflows.Count -gt 0) {
                $problems += '三队陆航均未使用，但仍残留基地航空队设置或陆航休息执行单元。'
            }
        } else {
            foreach ($workflow in $landBaseWorkflows) {
                $corps = [int]$workflow['Corps']
                if ($corps -notin $usedCorps) {
                    $problems += ('第 {0} 基地航空队未使用，却残留执行单元“{1}”。' -f $corps, [string]$workflow['Name'])
                }
            }
        }

        $eventMap = @($maps.Values | Where-Object {
            $_ -is [hashtable] -and
            $_.ContainsKey('api_eventmap') -and
            $_.ContainsKey('api_id') -and
            ([int]$_['api_id'] % 10) -eq [int]$sortie['Area']
        }) | Select-Object -First 1
        $openedCorps = @()
        $openedIds = @()
        if ($null -ne $eventMap -and $eventMap.ContainsKey('api_id')) {
            $eventAreaId = [int]([Math]::Floor([int]$eventMap['api_id'] / 10))
            $openedCorps = @($landBasedAirCorps | Where-Object {
                $_ -is [hashtable] -and
                $_.ContainsKey('api_area_id') -and
                [int]$_['api_area_id'] -eq $eventAreaId
            })
        }
        $hasDeclaredOpenedCount = $null -ne $routeSpec -and
            $routeSpec.Contains('ExpectedOpenedLandBasedAirCorps')
        $expectedDeclaredOpenedCount = if ($hasDeclaredOpenedCount) {
            [int]$routeSpec['ExpectedOpenedLandBasedAirCorps']
        } else { 0 }
        if ($hasDeclaredOpenedCount) {
            $openedIds = if ($expectedDeclaredOpenedCount -gt 0) { @(1..$expectedDeclaredOpenedCount) } else { @() }
            $declaredCountDocumented = if ($expectedDeclaredOpenedCount -eq 0) {
                $landBaseText -match '(?:开放\s*0\s*队|尚未开放|未开放)'
            } else {
                $landBaseText -match "开放\s*$expectedDeclaredOpenedCount\s*队|只开放\s*$expectedDeclaredOpenedCount\s*队"
            }
            if (-not $declaredCountDocumented) {
                $problems += "【陆航】没有写明路线规格所声明的本阶段开放数量：$expectedDeclaredOpenedCount 队。"
            }
            if ($openedCorps.Count -ne $expectedDeclaredOpenedCount) {
                $stageReason = if ($isDifferentDeclaredStage) {
                    "当前为第 $([int]$liveGauge.GaugeNumber) 条量值，配置为第 $declaredGaugeNumber 条"
                } elseif ($isDeclaredFutureStage) {
                    "前置为：$([string]$routeSpec['FutureStagePrerequisite'])"
                } else {
                    '请复核路线规格或实时数据'
                }
                $warnings += ('实时数据为 {0} 队基地航空队；本配置阶段路线规格要求 {1} 队（{2}）。' -f
                    $openedCorps.Count, $expectedDeclaredOpenedCount, $stageReason)
            }
        } elseif ($openedCorps.Count -eq 0) {
            $warnings += '无法从实时 landBasedAirCorps 数据确认本阶段开放的基地航空队数量；交付前必须人工核对。'
        } else {
            $openedIds = @($openedCorps | ForEach-Object { [int]$_['api_rid'] } | Sort-Object)
            if ($landBaseText -notmatch "开放\s*$($openedIds.Count)\s*队|只开放\s*$($openedIds.Count)\s*队") {
                $problems += "【陆航】没有写明实时确认的开放数量：$($openedIds.Count) 队。"
            }
        }
        if (@($openedIds).Count -gt 0) {
            $lastOpened = [int]($openedIds | Select-Object -Last 1)
            if ($landBaseText -match '基地空袭[：:]\s*有') {
                $defenseIds = @($openedIds | Where-Object {
                    [int]$sortie["LandBasedAirCorps$($_)Action"] -eq 2
                })
                $standbyIds = @($openedIds | Where-Object {
                    [int]$sortie["LandBasedAirCorps$($_)Action"] -eq 0
                })
                if ($defenseIds.Count -eq 0 -and $standbyIds.Count -gt 0) {
                    $problems += '基地会遭空袭且存在待机的开放航空队，却没有设置防空队。'
                } elseif (
                    $defenseIds.Count -eq 0 -and
                    [string]::IsNullOrWhiteSpace((Get-EventMemoSection -Memo $memo -Name '不设防空理由'))
                ) {
                    $problems += '基地会遭空袭但所有开放队均用于出击；必须在【不设防空理由】说明不设防空的收益权衡。'
                } elseif (
                    $defenseIds.Count -gt 0 -and
                    $lastOpened -notin $defenseIds -and
                    [string]::IsNullOrWhiteSpace((Get-EventMemoSection -Memo $memo -Name '防空队序例外'))
                ) {
                    $problems += "防空队应使用最后一支开放队（第 $lastOpened 队）；例外必须在【防空队序例外】说明。"
                }
            }
        }

        $defenseCorps = @($usedCorps | Where-Object {
            [int]$sortie["LandBasedAirCorps$($_)Action"] -eq 2
        })
        if ($null -ne $routeSpec -and
            $routeSpec.Contains('ExpectedLandBasedAirCorps')) {
            $expectedLandBases = $routeSpec['ExpectedLandBasedAirCorps']
            if ($null -eq $identityCheckerSpec -or
                -not ($identityCheckerSpec['LandBases'] -is [System.Collections.IDictionary])) {
                $problems += '路线规格已经锁定陆航定稿，但出击前身份检查没有可核对的陆航声明。'
            } else {
                foreach ($corpsKey in @($expectedLandBases.Keys)) {
                    $expectedPlanes = @($expectedLandBases[$corpsKey])
                    $declaredPlanes = @($identityCheckerSpec['LandBases'][$corpsKey])
                    if ($declaredPlanes.Count -ne $expectedPlanes.Count) {
                        $problems += "第 $corpsKey 基地航空队与路线规格定稿的槽位数不一致。"
                        continue
                    }
                    foreach ($slotIndex in 0..($expectedPlanes.Count - 1)) {
                        $expectedPlane = $expectedPlanes[$slotIndex]
                        $declaredPlane = $declaredPlanes[$slotIndex]
                        if ([int]$declaredPlane['Id'] -ne [int]$expectedPlane['Id'] -or
                            [string]$declaredPlane['Name'] -ne [string]$expectedPlane['Name']) {
                            $problems += ('第 {0} 基地航空队第 {1} 槽偏离路线规格定稿：应为 {2}，身份检查声明为 {3}。' -f
                                $corpsKey, ($slotIndex + 1), [string]$expectedPlane['Name'], [string]$declaredPlane['Name'])
                        }
                    }
                }
            }
        }
        if ($null -ne $routeSpec -and $routeSpec.Contains('LandBasedAirCorpsPlanClass')) {
            $planClass = [string]$routeSpec['LandBasedAirCorpsPlanClass']
            $allowedPlanClasses = @('GuidePrimary', 'GuideAlternative', 'AccountOptimized')
            if ($planClass -notin $allowedPlanClasses) {
                $problems += "陆航方案类型无效：$planClass。"
            }
            if (-not $routeSpec.Contains('LandBasedAirCorpsGuideSource') -or
                [string]::IsNullOrWhiteSpace([string]$routeSpec['LandBasedAirCorpsGuideSource'])) {
                $problems += '陆航方案已分类，但路线规格没有保存攻略基线来源。'
            }
            if ($planClass -in @('GuidePrimary', 'GuideAlternative') -and
                (-not $routeSpec.Contains('LandBasedAirCorpsGuideBaseline') -or
                -not ($routeSpec['LandBasedAirCorpsGuideBaseline'] -is [System.Collections.IDictionary]))) {
                $problems += '攻略原案或攻略备选陆航没有保存攻略图片主方案基线。'
            } elseif ($planClass -eq 'AccountOptimized' -and
                (-not $routeSpec.Contains('LandBasedAirCorpsGuideRequirements') -or
                -not ($routeSpec['LandBasedAirCorpsGuideRequirements'] -is [System.Collections.IDictionary]))) {
                $problems += '账号优化陆航没有保存由攻略提取的目标、航程与制空约束。'
            } elseif ($planClass -eq 'GuidePrimary') {
                $guideLandBases = $routeSpec['LandBasedAirCorpsGuideBaseline']
                $finalLandBases = if ($routeSpec.Contains('ExpectedLandBasedAirCorps')) {
                    $routeSpec['ExpectedLandBasedAirCorps']
                } else { $null }
                if (-not ($finalLandBases -is [System.Collections.IDictionary])) {
                    $problems += '陆航标记为攻略图片主方案，但路线规格没有最终四槽定稿。'
                } else {
                    foreach ($corpsKey in @($guideLandBases.Keys)) {
                        $guidePlanes = @($guideLandBases[$corpsKey])
                        $finalPlanes = @($finalLandBases[$corpsKey])
                        if ($guidePlanes.Count -ne $finalPlanes.Count) {
                            $problems += "第 $corpsKey 基地航空队标记为攻略主方案，但最终槽位数偏离攻略图片基线。"
                            continue
                        }
                        foreach ($slotIndex in 0..($guidePlanes.Count - 1)) {
                            if ([int]$guidePlanes[$slotIndex]['Id'] -ne [int]$finalPlanes[$slotIndex]['Id'] -or
                                [string]$guidePlanes[$slotIndex]['Name'] -ne [string]$finalPlanes[$slotIndex]['Name']) {
                                $problems += ('第 {0} 基地航空队第 {1} 槽标记为攻略主方案，但最终为 {2}，攻略图片基线为 {3}。' -f
                                    $corpsKey, ($slotIndex + 1), [string]$finalPlanes[$slotIndex]['Name'], [string]$guidePlanes[$slotIndex]['Name'])
                            }
                        }
                    }
                }
            } elseif ([string]::IsNullOrWhiteSpace((Get-EventMemoSection -Memo $memo -Name '陆航方案比较'))) {
                $problems += '采用攻略备选或账号优化陆航时，备注必须包含【陆航方案比较】。'
            }
            if ($planClass -eq 'AccountOptimized' -and $routeSpec.Contains('LandBasedAirCorpsGuideBaseline')) {
                $problems += '账号优化陆航不得把最终账号四槽反写成攻略图片主方案基线。'
            }
            if ($planClass -eq 'AccountOptimized' -and
                (-not $routeSpec.Contains('LandBasedAirCorpsDecision') -or
                [string]::IsNullOrWhiteSpace([string]$routeSpec['LandBasedAirCorpsDecision']))) {
                $problems += '账号优化陆航没有保存从攻略约束到最终四槽的决策说明。'
            }
        }
        $requiredRadiusSpec = if ($null -ne $routeSpec -and
            $routeSpec.Contains('RequiredLandBasedAirCorpsRadius')) {
            $routeSpec['RequiredLandBasedAirCorpsRadius']
        } else {
            $null
        }
        $radiusEvidenceRoute = if ($null -ne $routeSpec -and
            $landBasedAirCorpsRadiusEvidenceRoutes.Contains([string]$routeSpec['Id'])) {
            $landBasedAirCorpsRadiusEvidenceRoutes[[string]$routeSpec['Id']]
        } else {
            $null
        }
        $memoLandBasePlan = Get-EventMemoLandBasePlan -Memo $memoText
        foreach ($corps in @($usedCorps | Where-Object {
            [int]$sortie["LandBasedAirCorps$($_)Action"] -eq 1
        })) {
            $corpsKey = [string]$corps
            $memoRequiredRadius = Get-EventLandBaseRequiredRadiusFromMemo `
                -LandBaseText $landBaseText `
                -Corps $corps
            $specRequiredRadius = $null
            if ($requiredRadiusSpec -is [System.Collections.IDictionary] -and
                $requiredRadiusSpec.Contains($corpsKey)) {
                $specRequiredRadius = [int]$requiredRadiusSpec[$corpsKey]
            }

            if ($null -eq $radiusEvidenceRoute -or
                -not ($radiusEvidenceRoute['Corps'] -is [System.Collections.IDictionary]) -or
                -not $radiusEvidenceRoute['Corps'].Contains($corpsKey)) {
                $routeId = if ($null -eq $routeSpec) { '未匹配路线规格' } else { [string]$routeSpec['Id'] }
                $problems += "第 $corps 基地航空队缺少独立目标点航程证据；路线规格为 $routeId。"
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$radiusEvidenceRoute['Source']) -or
                [string]::IsNullOrWhiteSpace([string]$radiusEvidenceRoute['LastVerifiedJst'])) {
                $problems += "第 $corps 基地航空队的独立目标点航程证据缺少来源或核对日期。"
            }
            if ($null -ne $routeSpec -and
                $routeSpec.Contains('KcNavMap') -and
                [string]$radiusEvidenceRoute['Map'] -ne [string]$routeSpec['KcNavMap']) {
                $problems += "第 $corps 基地航空队的航程证据地图 $($radiusEvidenceRoute['Map']) 与路线规格地图 $($routeSpec['KcNavMap']) 不同。"
            }

            $evidenceCorps = $radiusEvidenceRoute['Corps'][$corpsKey]
            $evidenceRequiredRadius = [int]$evidenceCorps['RequiredRadius']
            $evidenceTargets = @($evidenceCorps['TargetPoints'] | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            $memoTargets = @(if ($memoLandBasePlan.Contains($corpsKey)) {
                $memoLandBasePlan[$corpsKey]['TargetPoints'] | ForEach-Object { [string]$_ } | Sort-Object -Unique
            })
            if ($evidenceTargets.Count -eq 0) {
                $problems += "第 $corps 基地航空队的独立航程证据没有记录目标点。"
            } elseif (($memoTargets -join ',') -cne ($evidenceTargets -join ',')) {
                $problems += ('第 {0} 基地航空队备注目标点为 {1}，独立证据要求 {2}。' -f
                    $corps, $(if ($memoTargets.Count -eq 0) { '未解析' } else { $memoTargets -join '/' }), ($evidenceTargets -join '/'))
            }
            if ($null -eq $specRequiredRadius) {
                $problems += "第 $corps 基地航空队用于出击，但路线规格没有声明目标点所需航程 $evidenceRequiredRadius。"
            } elseif ($specRequiredRadius -ne $evidenceRequiredRadius) {
                $problems += "第 $corps 基地航空队路线规格写航程 $specRequiredRadius，独立目标点证据要求 $evidenceRequiredRadius。"
            }
            if ($null -eq $memoRequiredRadius) {
                $problems += "第 $corps 基地航空队用于出击，但【陆航】没有在动作行写明航程要求 $evidenceRequiredRadius。"
            } elseif ($memoRequiredRadius -ne $evidenceRequiredRadius) {
                $problems += "第 $corps 基地航空队备注写航程 $memoRequiredRadius，独立目标点证据要求 $evidenceRequiredRadius。"
            }
            if ($null -eq $identityCheckerSpec -or
                -not ($identityCheckerSpec['LandBases'] -is [System.Collections.IDictionary]) -or
                -not $identityCheckerSpec['LandBases'].Contains($corpsKey)) {
                $problems += "第 $corps 基地航空队缺少出击前身份检查配装，无法计算有效航程。"
                continue
            }

            $declaredPlanes = @($identityCheckerSpec['LandBases'][$corpsKey])
            foreach ($targetPoint in $memoTargets) {
                $targetNode = @($routeSpec['Nodes'] | Where-Object { [string]$_['Letter'] -eq [string]$targetPoint } | Select-Object -First 1)
                if ($targetNode.Count -eq 0) { continue }
                if ([string]::IsNullOrWhiteSpace([string]$targetNode[0]['CombatTypeSource']) -or
                    [string]::IsNullOrWhiteSpace([string]$targetNode[0]['CombatTypeLastVerifiedJst'])) {
                    $problems += "目标点 $targetPoint 缺少独立敌编成类型来源或核对日期。"
                }
                $targetKind = [string]$targetNode[0]['Kind']
                if ($targetKind -in 'submarine', 'anti-sub-air-raid') {
                    $antiSubPlanes = @($declaredPlanes | Where-Object {
                        $masterId = [string][int]$_['Id']
                        $masterEquips.ContainsKey($masterId) -and [int]$masterEquips[$masterId]['api_tais'] -ge 7
                    })
                    if ($antiSubPlanes.Count -eq 0) {
                        $problems += "第 $corps 基地航空队投向潜水目标 $targetPoint，但四槽没有任何对潜值达到基地反潜攻击门槛的飞机。"
                    }
                }
                if ([string]$group['Name'] -match '空优|空優|航空优势|航空優勢' -and $targetKind -eq 'airraid') {
                    $fighterPlanes = @($declaredPlanes | Where-Object {
                        $masterId = [string][int]$_['Id']
                        if (-not $masterEquips.ContainsKey($masterId)) { return $false }
                        [int]$masterEquips[$masterId]['api_type'][2] -in 6, 45, 48
                    })
                    if ($fighterPlanes.Count -eq 0) {
                        $problems += "第 $corps 基地航空队投向空优目标 $targetPoint，却没有任何战斗机；不能机械复用对舰轰炸方案。"
                    }
                }
            }
            try {
                $radiusResult = Get-KcpsLandBasedAirCorpsRadius `
                    -Const $const `
                    -EquipConstIds @($declaredPlanes | ForEach-Object { [int]$_['Id'] })
                if ($radiusResult.EffectiveRadius -lt $evidenceRequiredRadius) {
                    $planeSummary = @($radiusResult.Planes | ForEach-Object {
                        '{0}(半径{1})' -f $_.Name, $_.Distance
                    }) -join ' / '
                    $problems += ('第 {0} 基地航空队有效航程只有 {1}，目标点要求 {2}；配装为 {3}。' -f
                        $corps, $radiusResult.EffectiveRadius, $evidenceRequiredRadius, $planeSummary)
                }
            } catch {
                $problems += "第 $corps 基地航空队有效航程计算失败：$($_.Exception.Message)"
            }
        }
        foreach ($line in @($landBaseText -split "`r?`n")) {
            $slotLabels = [regex]::Matches($line, '第\s*[1-4]\s*槽[：:]')
            if ($slotLabels.Count -gt 1) {
                $problems += '【陆航】的第1至第4槽必须各占一行，不能把多个槽合并在同一行。'
                break
            }
        }
        if ($landBaseText -match '未被舰船|未被其他基地|当前.{0,20}占用|从.{0,20}拆|挪用') {
            $problems += '【陆航】不得写装备当前占用位置或搬运来源；配置会重复使用，只保留逐槽装备与简短选择理由。'
        }
        $totalDefenseRocketCount = 0
        foreach ($corps in $defenseCorps) {
            $corpsBlockMatch = [regex]::Match(
                $landBaseText,
                "(?ms)^第\s*$corps\s*基地航空队[：:].*?(?=^第\s*[1-3]\s*基地航空队[：:]|\z)"
            )
            $corpsBlock = if ($corpsBlockMatch.Success) { $corpsBlockMatch.Value } else { '' }
            foreach ($slot in 1..4) {
                if ($corpsBlock -notmatch "第\s*$slot\s*槽[：:]") {
                    $problems += "第 $corps 基地航空队设为防空，但【陆航】没有写明第 $slot 槽的手工配装。"
                } elseif ($corpsBlock -notmatch "(?m)^第\s*$slot\s*槽[：:][^`r`n｜|]+[｜|].{3,}[。.]?$") {
                    $problems += ('第 {0} 基地航空队第 {1} 槽必须使用“第N槽：装备名｜简短理由。”格式。' -f $corps, $slot)
                }
            }
            if ($corpsBlock -notmatch '本队防空制空') {
                $problems += "第 $corps 基地航空队设为防空，但【陆航】没有写明该队在侦察机倍率后的防空制空。"
            }
            if ($null -ne $identityCheckerSpec -and
                $identityCheckerSpec['LandBases'] -is [System.Collections.IDictionary] -and
                $identityCheckerSpec['LandBases'].Contains([string]$corps)) {
                $rocketMasterIds = @(350, 351, 352)
                $declaredPlanes = @($identityCheckerSpec['LandBases'][[string]$corps])
                $rocketCount = @($declaredPlanes | Where-Object {
                    [int]$_['Id'] -in $rocketMasterIds
                }).Count
                $totalDefenseRocketCount += $rocketCount
            }
        }
        if ($defenseCorps.Count -gt 0) {
            if ($landBaseText -notmatch '防空队合计制空' -or
                $landBaseText -notmatch '优势线|優勢線|空优线|空優線|航空优(?:势|勢)' -or
                $landBaseText -notmatch '确保线|確保線|制空权确保|制空権確保') {
                $problems += '【陆航】没有写明全部防空队合计制空、敌方航空优势线和确保线。'
            }
            $highAltitudeMatch = [regex]::Match($landBaseText, '高高度空袭[：:]\s*(?<value>是|否)')
            if (-not $highAltitudeMatch.Success) {
                $problems += '基地航空队设为防空，但【陆航】没有明确写高高度空袭：是或高高度空袭：否。'
            } elseif ($highAltitudeMatch.Groups['value'].Value -eq '是') {
                if ($totalDefenseRocketCount -eq 0) {
                    $problems += '面对高高度空袭的全部防空队都没有秋水、试制秋水或Me163B；0架火箭局战会受到0.5倍防空制空惩罚。Me 262不属于火箭局战。'
                }
                $memoRocketMatch = [regex]::Match($landBaseText, '防空队合计火箭局战[：:]\s*(?<count>\d+)\s*架')
                if (-not $memoRocketMatch.Success) {
                    $problems += '面对高高度空袭，但【陆航】没有写明防空队合计火箭局战：N架。'
                } elseif ([int]$memoRocketMatch.Groups['count'].Value -ne $totalDefenseRocketCount) {
                    $problems += "备注写防空队合计火箭局战$($memoRocketMatch.Groups['count'].Value)架，出击前身份检查声明实际合计为${totalDefenseRocketCount}架。"
                }
            }
            if ($null -ne $routeSpec -and $routeSpec.Contains('LandBasedAirCorpsDefense')) {
                $defenseSpec = $routeSpec['LandBasedAirCorpsDefense']
                if ([int]$defenseSpec['DefenseCorpsCount'] -ne $defenseCorps.Count) {
                    $problems += "路线规格声明防空$($defenseSpec['DefenseCorpsCount'])队，配置实际为$($defenseCorps.Count)队。"
                }
                if ([int]$defenseSpec['RocketCount'] -ne $totalDefenseRocketCount) {
                    $problems += "路线规格声明防空队合计火箭局战$($defenseSpec['RocketCount'])架，身份检查实际为${totalDefenseRocketCount}架。"
                }
                $memoDefenseMatch = [regex]::Match($landBaseText, '防空队合计制空[：:]\s*(?<value>\d+)')
                if (-not $memoDefenseMatch.Success) {
                    $problems += '【陆航】缺少“防空队合计制空：N”实算值。'
                } elseif ([int]$memoDefenseMatch.Groups['value'].Value -ne [int]$defenseSpec['FinalAirPower']) {
                    $problems += "备注写防空队合计制空$($memoDefenseMatch.Groups['value'].Value)，路线规格实算为$($defenseSpec['FinalAirPower'])。"
                }
                if ([int]$defenseSpec['EnemyAirPower'] -le 0 -or
                    [int]$defenseSpec['AirSuperiorityLine'] -le 0 -or
                    [int]$defenseSpec['AirSupremacyLine'] -le 0 -or
                    [string]::IsNullOrWhiteSpace([string]$defenseSpec['FormulaSource']) -or
                    [string]::IsNullOrWhiteSpace([string]$defenseSpec['EnemyFormationSource']) -or
                    [string]::IsNullOrWhiteSpace([string]$defenseSpec['LastVerifiedJst'])) {
                    $problems += '路线规格的基地防空结论缺少敌制空、空优线、确保线、公式来源、敌编成来源或核对日期。'
                }
            } elseif ($null -ne $routeSpec) {
                $problems += '配置使用基地防空，但路线规格缺少LandBasedAirCorpsDefense实算结论。'
            }
        }
    }

    if ($null -ne $routeSpec -and
        $routeSpec.ContainsKey('MixedSubmarineSurfacePlan') -and
        $routeSpec['MixedSubmarineSurfacePlan'] -is [System.Collections.IDictionary] -and
        $null -ne $sortie) {
        $mixedPlan = $routeSpec['MixedSubmarineSurfacePlan']
        $mixedRequiredFields = @(
            'TargetPoint', 'TargetValue', 'EnemySubmarineCount', 'EnemySurfaceCount',
            'ExpectedTargetFormation', 'ExpectedTargetMidnight',
            'MinimumMainOpeningAswShips', 'ExpectedOpeningAswShipIds',
            'MinimumAntiSubLandBasedAirCorpsAtTarget',
            'MinimumSurfaceLandBasedAirCorpsAtTarget',
            'MaximumSurfaceOnlyLandBasedAirCorpsAtTarget', 'Source', 'LastVerifiedJst'
        )
        $missingMixedFields = @($mixedRequiredFields | Where-Object {
            -not $mixedPlan.ContainsKey($_) -or $null -eq $mixedPlan[$_]
        })
        if ($missingMixedFields.Count -gt 0) {
            $problems += "MixedSubmarineSurfacePlan 缺少字段：$($missingMixedFields -join ', ')。"
        } else {
            $mixedPoint = [string]$mixedPlan['TargetPoint']
            $mixedValue = [int]$mixedPlan['TargetValue']
            if ([int]$mixedPlan['EnemySubmarineCount'] -le 0 -or
                [int]$mixedPlan['EnemySurfaceCount'] -le 0) {
                $problems += 'MixedSubmarineSurfacePlan 必须同时记录大于0的潜艇数和水面舰数。'
            }
            if ([string]::IsNullOrWhiteSpace([string]$mixedPlan['Source']) -or
                [string]::IsNullOrWhiteSpace([string]$mixedPlan['LastVerifiedJst'])) {
                $problems += 'MixedSubmarineSurfacePlan 缺少敌编成来源或核对日期。'
            }

            $mixedNode = @($routeSpec['Nodes'] | Where-Object {
                [string]$_['Letter'] -eq $mixedPoint -and [int]$_['Value'] -eq $mixedValue
            }) | Select-Object -First 1
            if ($null -eq $mixedNode -or [string]$mixedNode['Kind'] -notmatch '^mixed-submarine-surface') {
                $problems += "目标点 $mixedPoint 同时有潜艇和水面舰，但路线节点没有标记为 mixed-submarine-surface。"
            }
            $mixedStrategies = @($sortie['Strategies'] | Where-Object {
                [int]$_['Condition']['Type'] -eq 1 -and
                [int]$_['Condition']['Value'] -eq $mixedValue
            })
            if ($mixedStrategies.Count -ne 1) {
                $problems += "水潜混编目标点 $mixedPoint 必须且只能有一条地图点策略。"
            } else {
                $mixedStrategy = $mixedStrategies[0]['Strategy']
                if ([int]$mixedStrategy['DefaultFormation'] -ne [int]$mixedPlan['ExpectedTargetFormation']) {
                    $problems += "水潜混编目标点 $mixedPoint 阵型为 $($mixedStrategy['DefaultFormation'])，方案要求 $($mixedPlan['ExpectedTargetFormation'])。"
                }
                if ([int]$mixedStrategy['DefaultMidnight'] -ne [int]$mixedPlan['ExpectedTargetMidnight']) {
                    $problems += "水潜混编目标点 $mixedPoint 夜战策略为 $($mixedStrategy['DefaultMidnight'])，方案要求 $($mixedPlan['ExpectedTargetMidnight'])。"
                }
            }

            $fixedMainOrganize = @($workflows | Where-Object {
                (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') -and
                [int]$_['Fleet'] -eq [int]$sortie['Fleet']
            }) | Select-Object -First 1
            $fixedMainRefit = @($workflows | Where-Object {
                Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicRefitEquipmentWorkflow'
            }) | Select-Object -First 1
            $openingAswValid = 0
            foreach ($shipIdValue in @($mixedPlan['ExpectedOpeningAswShipIds'])) {
                $shipId = [int]$shipIdValue
                $isSelected = $null -ne $fixedMainOrganize -and @($fixedMainOrganize['Positions'] | Where-Object {
                    @($_['Selections'] | Where-Object {
                        [int]$_['Type'] -eq 0 -and [int]$_['Value'] -eq $shipId
                    }).Count -gt 0
                }).Count -gt 0
                if (-not $isSelected) {
                    $problems += "路线规格声明舰船ID $shipId 负责先制反潜，但主舰队没有选中该实例。"
                    continue
                }
                $ownedShip = Get-EventOwnedShipById -OwnedShips $ships -ShipId $shipId
                $refitRows = @(
                    if ($null -ne $fixedMainRefit) {
                        $fixedMainRefit['Ships'] | Where-Object {
                        [int]$_['Fleet'] -eq [int]$sortie['Fleet'] -and
                        [int]$_['SelectMethod'] -eq 3 -and [int]$_['SelectValue'] -eq $shipId
                        }
                    }
                )
                if ($null -eq $ownedShip) {
                    $problems += "无法核对舰船ID $shipId 的先制反潜：实时账号中不存在该实例。"
                    continue
                }
                if ($refitRows.Count -ne 1) {
                    $problems += "无法核对舰船ID $shipId 的先制反潜：要求唯一ID改装行，实际为 $($refitRows.Count) 行。"
                    continue
                }
                $baseAswValues = @($ownedShip['api_taisen'])
                $baseAsw = if ($baseAswValues.Count -ge 2) { [int]$baseAswValues[1] } else { 0 }
                $guaranteedEquipmentAsw = 0
                $hasGuaranteedSonar = $false
                foreach ($slot in @($refitRows[0]['Slots'])) {
                    $candidateMasters = @(
                        foreach ($equipment in @($slot['Equipments'])) {
                            $name = Normalize-KcpsEquipmentDisplayName -Name ([string]$equipment['SelectValue'])
                            if ($masterEquipByName.ContainsKey($name)) { $masterEquipByName[$name] }
                        }
                    )
                    if ($candidateMasters.Count -eq 0) { continue }
                    $guaranteedEquipmentAsw += [int](
                        $candidateMasters | ForEach-Object { [int]$_['api_tais'] } | Measure-Object -Minimum
                    ).Minimum
                    if (@($candidateMasters | Where-Object { [int]$_['api_type'][2] -eq 14 }).Count -eq $candidateMasters.Count) {
                        $hasGuaranteedSonar = $true
                    }
                }
                $configuredAsw = $baseAsw + $guaranteedEquipmentAsw
                if (-not $hasGuaranteedSonar -or $configuredAsw -lt 100) {
                    $problems += "舰船ID $shipId 被计入先制反潜，但保守装备后对潜为 $configuredAsw，或没有保证携带声呐。"
                } else {
                    $openingAswValid++
                }
            }
            if ($openingAswValid -lt [int]$mixedPlan['MinimumMainOpeningAswShips']) {
                $problems += "水潜混编目标要求至少 $($mixedPlan['MinimumMainOpeningAswShips']) 艘可靠先制反潜舰，当前只验证到 $openingAswValid 艘。"
            }

            $mixedRadiusEvidence = if ($landBasedAirCorpsRadiusEvidenceRoutes.Contains([string]$routeSpec['Id'])) {
                $landBasedAirCorpsRadiusEvidenceRoutes[[string]$routeSpec['Id']]
            } else { $null }
            $antiSubCorpsAtTarget = 0
            $surfaceOnlyCorpsAtTarget = 0
            foreach ($corps in 1..3) {
                if ([int]$sortie["LandBasedAirCorps${corps}Action"] -ne 1 -or
                    $null -eq $mixedRadiusEvidence -or
                    -not $mixedRadiusEvidence['Corps'].ContainsKey([string]$corps)) { continue }
                $targets = @($mixedRadiusEvidence['Corps'][[string]$corps]['TargetPoints'] | ForEach-Object { [string]$_ })
                if ($mixedPoint -notin $targets) { continue }
                $declaredPlanes = if ($null -ne $identityCheckerSpec -and
                    $identityCheckerSpec['LandBases'] -is [System.Collections.IDictionary] -and
                    $identityCheckerSpec['LandBases'].ContainsKey([string]$corps)) {
                    @($identityCheckerSpec['LandBases'][[string]$corps])
                } else { @() }
                $antiSubPlanes = @($declaredPlanes | Where-Object {
                    $masterEquips.ContainsKey([string][int]$_['Id']) -and
                    [int]$masterEquips[[string][int]$_['Id']]['api_tais'] -ge 7
                })
                if ($antiSubPlanes.Count -gt 0) { $antiSubCorpsAtTarget++ } else { $surfaceOnlyCorpsAtTarget++ }
            }
            if ($antiSubCorpsAtTarget -lt [int]$mixedPlan['MinimumAntiSubLandBasedAirCorpsAtTarget']) {
                $problems += "水潜混编目标 $mixedPoint 至少需要 $($mixedPlan['MinimumAntiSubLandBasedAirCorpsAtTarget']) 队有效反潜陆航，当前为 $antiSubCorpsAtTarget 队。"
            }
            if ($surfaceOnlyCorpsAtTarget -lt [int]$mixedPlan['MinimumSurfaceLandBasedAirCorpsAtTarget']) {
                $problems += "水潜混编目标 $mixedPoint 至少需要 $($mixedPlan['MinimumSurfaceLandBasedAirCorpsAtTarget']) 队对舰陆航清理水面舰，当前为 $surfaceOnlyCorpsAtTarget 队。"
            }
            if ($surfaceOnlyCorpsAtTarget -gt [int]$mixedPlan['MaximumSurfaceOnlyLandBasedAirCorpsAtTarget']) {
                $problems += "水潜混编目标 $mixedPoint 最多允许 $($mixedPlan['MaximumSurfaceOnlyLandBasedAirCorpsAtTarget']) 队纯对舰陆航，当前为 $surfaceOnlyCorpsAtTarget 队；后续队可能在水面舰清空后整队失去目标。"
            }
        }
    }

    if ($null -ne $routeSpec -and
        $routeSpec.ContainsKey('BossSupportPlan') -and
        $routeSpec['BossSupportPlan'] -is [System.Collections.IDictionary] -and
        $null -ne $sortie) {
        $bossSupportPlan = $routeSpec['BossSupportPlan']
        if ($bossSupportPlan['SelectionMode'] -eq 'DynamicRoles') {
            $problems += @(Get-KcpsDynamicAswSupportProblems -Plan $bossSupportPlan -Workflows $workflows -MasterEquipByName $masterEquipByName -Memo $memo)
        } else {
        foreach ($requiredField in @(
            'Mode', 'Fleet', 'ExpectedShipIds', 'MinimumAviationAswSlots',
            'EnemyAirPower', 'MinimumSupportAirPower', 'ExpectedSupportAirPower',
            'ExpectedAirState', 'AirPowerSource', 'AirPowerLastVerifiedJst',
            'Source', 'LastVerifiedJst'
        )) {
            if (-not $bossSupportPlan.ContainsKey($requiredField) -or $null -eq $bossSupportPlan[$requiredField]) {
                $problems += "BossSupportPlan 缺少字段：$requiredField。"
            }
        }
        if ([string]$bossSupportPlan['Mode'] -eq 'AntiSubmarine') {
            $plannedBossFleet = [int]$bossSupportPlan['Fleet']
            if (-not [bool]$sortie['BossSupportExpedition'] -or
                [int]$sortie['BossSupportExpeditionFleet'] -ne $plannedBossFleet) {
                $problems += "路线规格要求第 $plannedBossFleet 舰队执行反潜决战支援，但出击设置不一致。"
            }
            if ($supportText -notmatch '决战支援[：:].{0,40}反潜支援|决战.*反潜支援|反潜支援.*决战') {
                $problems += 'BossSupportPlan 要求反潜决战支援，但【支援】没有明确写明。'
            }
            $plannedBossOrganize = @($workflows | Where-Object {
                (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') -and
                [int]$_['Fleet'] -eq $plannedBossFleet
            }) | Select-Object -First 1
            $actualBossShipIds = @(
                if ($null -ne $plannedBossOrganize) {
                    foreach ($position in @($plannedBossOrganize['Positions'])) {
                        $selection = @($position['Selections'] | Where-Object {
                            [int]$_['Type'] -eq 0 -and [string]$_['Value'] -match '^\d+$'
                        }) | Select-Object -First 1
                        if ($null -ne $selection) { [int]$selection['Value'] }
                    }
                }
            )
            $expectedBossShipIds = @($bossSupportPlan['ExpectedShipIds'] | ForEach-Object { [int]$_ })
            if (($actualBossShipIds -join ',') -ne ($expectedBossShipIds -join ',')) {
                $problems += "反潜决战支援舰船顺序为 [$($actualBossShipIds -join ',')]，路线规格要求 [$($expectedBossShipIds -join ',')]。"
            }
            $aviationAswSlots = 0
            foreach ($refitWorkflow in @($workflows | Where-Object {
                Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicRefitEquipmentWorkflow'
            })) {
                foreach ($shipRefit in @($refitWorkflow['Ships'] | Where-Object {
                    [int]$_['Fleet'] -eq $plannedBossFleet
                })) {
                    foreach ($slot in @($shipRefit['Slots'] | Where-Object { [int]$_['Slot'] -in 1..5 })) {
                        $candidateMasters = @(
                            foreach ($equipment in @($slot['Equipments'])) {
                                $name = Normalize-KcpsEquipmentDisplayName -Name ([string]$equipment['SelectValue'])
                                if ($masterEquipByName.ContainsKey($name)) { $masterEquipByName[$name] }
                            }
                        )
                        if ($candidateMasters.Count -gt 0 -and
                            @($candidateMasters | Where-Object {
                                [int]$_['api_tais'] -ge 1 -and [int]$_['api_type'][2] -in @(7, 8, 11, 25, 26)
                            }).Count -eq $candidateMasters.Count) {
                            $aviationAswSlots++
                        }
                    }
                }
            }
            if ($aviationAswSlots -lt [int]$bossSupportPlan['MinimumAviationAswSlots']) {
                $problems += "反潜决战支援至少需要 $($bossSupportPlan['MinimumAviationAswSlots']) 个舰载反潜攻击槽，当前只验证到 $aviationAswSlots 个。"
            }
            $supportAirPower = 0
            foreach ($shipId in $expectedBossShipIds) {
                $ownedSupportShip = Get-EventOwnedShipById -OwnedShips $ships -ShipId $shipId
                if ($null -eq $ownedSupportShip) { continue }
                $supportShipMasterId = [string]$ownedSupportShip['api_ship_id']
                if (-not $masterShips.ContainsKey($supportShipMasterId)) { continue }
                $supportSlotCapacities = @($masterShips[$supportShipMasterId]['api_maxeq'])
                $supportRefitRows = @(
                    foreach ($refitWorkflow in @($workflows | Where-Object {
                        Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicRefitEquipmentWorkflow'
                    })) {
                        $refitWorkflow['Ships'] | Where-Object {
                            [int]$_['Fleet'] -eq $plannedBossFleet -and
                            [int]$_['SelectMethod'] -eq 3 -and
                            [int]$_['SelectValue'] -eq $shipId
                        }
                    }
                )
                if ($supportRefitRows.Count -ne 1) { continue }
                foreach ($slot in @($supportRefitRows[0]['Slots'] | Where-Object {
                    [int]$_['Slot'] -ge 1 -and [int]$_['Slot'] -le $supportSlotCapacities.Count
                })) {
                    $slotNumber = [int]$slot['Slot']
                    $slotCapacity = [int]$supportSlotCapacities[$slotNumber - 1]
                    if ($slotCapacity -le 0) { continue }
                    $candidateMasters = @(
                        foreach ($equipment in @($slot['Equipments'])) {
                            $name = Normalize-KcpsEquipmentDisplayName -Name ([string]$equipment['SelectValue'])
                            if ($masterEquipByName.ContainsKey($name)) { $masterEquipByName[$name] }
                        }
                    )
                    if ($candidateMasters.Count -eq 0 -or
                        @($candidateMasters | Where-Object {
                            [int]$_['api_tais'] -ge 1 -and [int]$_['api_type'][2] -in @(7, 8, 11, 25, 26)
                        }).Count -ne $candidateMasters.Count) { continue }
                    $minimumAntiAir = [int](
                        $candidateMasters | ForEach-Object { [int]$_['api_tyku'] } | Measure-Object -Minimum
                    ).Minimum
                    $supportAirPower += [Math]::Floor($minimumAntiAir * [Math]::Sqrt($slotCapacity))
                }
            }
            $enemySupportAirPower = [int]$bossSupportPlan['EnemyAirPower']
            $supportAirState = if ($enemySupportAirPower -le 0 -or $supportAirPower -ge 3 * $enemySupportAirPower) {
                'AirSupremacy'
            } elseif (2 * $supportAirPower -ge 3 * $enemySupportAirPower) {
                'AirSuperiority'
            } elseif (3 * $supportAirPower -ge 2 * $enemySupportAirPower) {
                'AirParity'
            } elseif (3 * $supportAirPower -gt $enemySupportAirPower) {
                'AirDenial'
            } else {
                'AirLoss'
            }
            if ($supportAirPower -lt [int]$bossSupportPlan['MinimumSupportAirPower']) {
                $problems += "反潜决战支援面对敌制空 $enemySupportAirPower 时至少需要制空 $($bossSupportPlan['MinimumSupportAirPower'])，当前保守值为 $supportAirPower。"
            }
            if ($supportAirPower -ne [int]$bossSupportPlan['ExpectedSupportAirPower']) {
                $problems += "反潜决战支援保守制空为 $supportAirPower，路线规格记录为 $($bossSupportPlan['ExpectedSupportAirPower'])。"
            }
            if ($supportAirState -ne [string]$bossSupportPlan['ExpectedAirState']) {
                $problems += "反潜决战支援制空状态为 $supportAirState，路线规格要求 $($bossSupportPlan['ExpectedAirState'])。"
            }
            if ([string]::IsNullOrWhiteSpace([string]$bossSupportPlan['AirPowerSource']) -or
                [string]::IsNullOrWhiteSpace([string]$bossSupportPlan['AirPowerLastVerifiedJst'])) {
                $problems += 'BossSupportPlan 缺少敌制空来源或核对日期。'
            }
            if ([string]::IsNullOrWhiteSpace([string]$bossSupportPlan['Source']) -or
                [string]::IsNullOrWhiteSpace([string]$bossSupportPlan['LastVerifiedJst'])) {
                $problems += 'BossSupportPlan 缺少支援机制来源或核对日期。'
            }
        }
        }
    }

    $routeText = Get-EventMemoSection -Memo $memo -Name '路线'
    if ([string]::IsNullOrWhiteSpace($routeText)) {
        $problems += '活动备注缺少【路线】。'
    } else {
        $routeText = $routeText -replace '\s+', ''
        $routeNodes = @([regex]::Matches($routeText, '(?<![A-Za-z0-9])([A-Z][A-Z0-9]*)(?=（|→|$)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        foreach ($node in $routeNodes) {
            if ($routeText -notmatch ([regex]::Escape($node) + '（[^）]+）')) {
                $problems += "路线节点 $node 后必须用中文括号写明点类型。"
            }
        }

        $startMatch = [regex]::Match($routeText, '^(?<start>第一|第二|第三|第四)出发点')
        $routeCodeMatch = [regex]::Match([string]$group['Name'], '(?<code>\d(?:[A-Z][A-Z0-9]*)+)$')
        if ($startMatch.Success -and $routeCodeMatch.Success) {
            $startNumbers = @{ '第一' = '1'; '第二' = '2'; '第三' = '3'; '第四' = '4' }
            $rawOrderedNodes = @([regex]::Matches($routeText, '(?<![A-Za-z0-9])([A-Z][A-Z0-9]*)(?=（|→|$)') | ForEach-Object { $_.Groups[1].Value })
            $orderedNodes = @()
            foreach ($node in $rawOrderedNodes) {
                if ($orderedNodes.Count -gt 0 -and $orderedNodes[-1] -eq $node) {
                    $problems += "【路线】在换行或分句衔接处重复列出节点 $node；路线码只记录实际经过一次的节点，备注也不得重复。"
                    continue
                }
                $orderedNodes += $node
            }
            $expectedRouteCode = $startNumbers[$startMatch.Groups['start'].Value] + ($orderedNodes -join '')
            $actualRouteCode = $routeCodeMatch.Groups['code'].Value
            if ($actualRouteCode -ne $expectedRouteCode) {
                $problems += ('配置名末尾路线码为 {0}，但备注路线逐点编码应为 {1}。节点名称必须完整保留，不能合并相同前缀。' -f $actualRouteCode, $expectedRouteCode)
            }
            $fileStem = [regex]::Replace([System.IO.Path]::GetFileName($Path), '\.conf\.json$', '')
            $fileStageMatch = [regex]::Match($fileStem, '^(?<stage>E\d+\s+P\d+)\b')
            $groupStageMatch = [regex]::Match([string]$group['Name'], '^(?<stage>E\d+\s+P\d+)\b')
            if (-not $isFarmingPhase -and -not $isLevelingPhase -and (-not $fileStageMatch.Success -or -not $groupStageMatch.Success -or
                $fileStageMatch.Groups['stage'].Value -ne $groupStageMatch.Groups['stage'].Value)) {
                $problems += '配置文件的 E# P# 阶段必须与内部每个配置一致。'
            }
        } else {
            $problems += '无法从备注路线和配置名解析出发点及路线码。'
        }
    }

    $mainFleet = if ($null -ne $controller -and $controller.ContainsKey('Fleet')) { [int]$controller['Fleet'] } else { 0 }
    $sortieFleetIds = if ($null -ne $identityCheckerSpec -and
        $identityCheckerSpec['Fleets'] -is [System.Collections.IDictionary]) {
        @($identityCheckerSpec['Fleets'].Keys | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    } elseif ($null -ne $combinedWorkflow) {
        @(1, 2)
    } elseif ($mainFleet -gt 0) {
        @($mainFleet)
    } else {
        @()
    }
    $allowedSallyAreas = @(
        if ($null -ne $routeSpec -and $routeSpec.Contains('AllowedSallyAreas')) {
            $routeSpec['AllowedSallyAreas'] | ForEach-Object { [int]$_ } | Sort-Object -Unique
        }
    )
    if ($null -ne $routeSpec -and $routeSpec.Contains('ExpectedSallyLabel')) {
        $expectedSallyLabel = [string]$routeSpec['ExpectedSallyLabel']
        if ([string]::IsNullOrWhiteSpace($expectedSallyLabel) -or
            $memo -notmatch [regex]::Escape($expectedSallyLabel)) {
            $problems += '路线规格声明的预计贴条名称没有在备注中明确记录。'
        }
        if ($allowedSallyAreas.Count -eq 0) {
            $problems += '路线规格声明了预计贴条名称，但没有提供 AllowedSallyAreas 数值映射。'
        }
    }

    $selected = @()
    foreach ($fleetNo in $sortieFleetIds) {
        $organizes = @($workflows | Where-Object {
            (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') -and
            [int]$_['Fleet'] -eq $fleetNo
        })
        if ($organizes.Count -ne 1) {
            $problems += "第 $fleetNo 出击舰队必须且只能有一个编成执行单元；实际为 $($organizes.Count) 个。"
            continue
        }

        $position = 0
        foreach ($slot in @($organizes[0]['Positions'])) {
            $position++
            $selections = @($slot['Selections'])
            if ($selections.Count -ne 1) {
                $problems += "第 $fleetNo 出击舰队位置 $position 必须固定为一个候选；活动海域禁止等价船疲劳轮换。"
                continue
            }
            $value = [string]$selections[0]['Value']
            $shipId = 0
            if (-not [int]::TryParse($value, [ref]$shipId) -or $shipId -le 0) {
                $problems += "第 $fleetNo 出击舰队位置 $position 不是明确的舰船实例 ID。"
                continue
            }
            if (-not $copyById.ContainsKey([string]$shipId)) {
                $problems += "第 $fleetNo 出击舰队位置 $position 的舰船实例 $shipId 不存在于当前账号。"
                continue
            }

            $row = $copyById[[string]$shipId]
            $selected += $row
            if (-not $row.Numbered) {
                $problems += "$($row.Name)($shipId)未锁定，不能自动认定为第几号机或用于不可逆锁船决策。"
            } else {
                $selectionMemo = [string]$selections[0]['Memo']
                $selectionMemo = $selectionMemo.Trim().TrimStart('[').TrimEnd(']')
                if (-not $selectionMemo.StartsWith($row.Name, [System.StringComparison]::Ordinal)) {
                    $problems += "第 $fleetNo 出击舰队位置 $position 的候选备注必须先写船名 $($row.Name)。"
                }
                $copyLabels = @('零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十')
                $cn = if ($row.CopyNo -lt $copyLabels.Count) { $copyLabels[$row.CopyNo] } else { [string]$row.CopyNo }
                if ($row.CopyNo -eq 1 -and $selectionMemo -match '(?:#?1|一)号机') {
                    $problems += "$($row.Name)($shipId)是一号机，候选备注应省略一号机标记。"
                }
                if ($row.CopyNo -gt 1 -and
                    $selectionMemo -notmatch "(?:#$($row.CopyNo)|$($row.CopyNo)号机|${cn}号机)") {
                    $problems += "$($row.Name)($shipId)是第 $($row.CopyNo) 号机，候选备注必须写明几号机。"
                }
                $idPattern = [regex]::Escape([string]$shipId)
                if ($memo -notmatch $idPattern) {
                    $problems += "备注没有记录 $($row.Name)($shipId) 的舰船实例 ID。"
                } elseif (
                    $row.CopyNo -gt 1 -and
                    $memo -notmatch "(?i)$([regex]::Escape($row.Name)).{0,20}(#$($row.CopyNo)|$($row.CopyNo)号机|${cn}号机)"
                ) {
                    $problems += "备注没有明确记录 $($row.Name)($shipId) 为第 $($row.CopyNo) 号机。"
                }
            }
            if ($row.SallyArea -gt 0) {
                if ($allowedSallyAreas.Count -eq 0) {
                    $problems += "$($row.Name)($shipId)已贴条 api_sally_area=$($row.SallyArea)，但路线规格没有声明允许的贴条编号，无法证明兼容。"
                } elseif ([int]$row.SallyArea -notin $allowedSallyAreas) {
                    $problems += "$($row.Name)($shipId)的贴条 api_sally_area=$($row.SallyArea) 与本阶段允许值 $($allowedSallyAreas -join ',') 冲突。"
                }
            }
            if ($row.Fleet -gt 0 -and $row.Mission -and $row.Mission -notmatch '^0,') {
                $warnings += "$($row.Name)($shipId)当前在第 $($row.Fleet) 舰队远征中，回来前编成会失败或等待。"
            }
        }
    }

    $results += [pscustomobject]@{
        Group = [string]$group['Name']
        MainFleet = $mainFleet
        SelectedShips = @($selected | Select-Object Id, Name, CopyNo, Locked, SallyArea, Fleet, Mission)
        SortieIdentityCheckerProblems = @($identityCheckerProblems)
        Problems = @($problems)
        Warnings = @($warnings)
        Valid = ($problems.Count -eq 0)
    }
}

$results | ConvertTo-KcpsJsonOutput -Depth 10
if (-not $NoThrow -and @($results | Where-Object { -not $_.Valid }).Count -gt 0) {
    throw '活动出击配置校验失败；请根据 Problems 修正后再加载。'
}
