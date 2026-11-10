#requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,

    [string]$RouteSpecPath = (Join-Path $PSScriptRoot '..\data\KCPS-RouteSpecs.json'),

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"
. "$PSScriptRoot\..\validate\KCPS-TerminalBattleValidation.ps1"

$routeSpecs = @()
if (Test-Path -LiteralPath $RouteSpecPath -PathType Leaf) {
    $routeSpecs = @((Read-KcpsJson -Path $RouteSpecPath)['Routes'])
}

function Set-SafeFallbackStrategy {
    param([hashtable]$Strategy)

    if ($null -eq $Strategy) { return @() }
    $changes = @()

    $expected = [ordered]@{
        DefaultFormation = 0
        FallbackFormation = 0
        DefaultMidnight = 0
        DefaultAdvance = 2
        EscortShipsHeavilyDamagedStrategy = 1
        RejectEscortRetreatIfMoreOrEqualThanTwoEscortShipsHeavilyDamaged = $true
    }

    foreach ($key in $expected.Keys) {
        if ($Strategy[$key] -ne $expected[$key]) {
            $changes += "${key}: $($Strategy[$key]) -> $($expected[$key])"
            if (-not $CheckOnly) {
                $Strategy[$key] = $expected[$key]
            }
        }
    }

    return $changes
}

$allReports = @()

foreach ($pathValue in $Path) {
    $resolvedPath = (Resolve-Path -LiteralPath $pathValue).Path
    $config = Read-KcpsJson -Path $resolvedPath
    $fileChanged = $false
    $reports = @()

    foreach ($group in Get-KcpsGroups -Config $config) {
        $groupSortie = @($group['List'] | Where-Object {
            Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleSortieWorkflow'
        } | Select-Object -First 1)[0]
        $matchingRouteSpecs = if ($null -eq $groupSortie) {
            @()
        } else {
            @($routeSpecs | Where-Object {
                [int]$_['Sea'] -eq [int]$groupSortie['Sea'] -and
                [int]$_['Area'] -eq [int]$groupSortie['Area'] -and
                -not [string]::IsNullOrWhiteSpace([string]$_['GroupNameRegex']) -and
                (Test-KcpsRouteSpecGroupName -GroupName ([string]$group['Name']) -RouteSpec $_)
            })
        }
        $routeSpec = if ($matchingRouteSpecs.Count -eq 1) { $matchingRouteSpecs[0] } else { $null }

        foreach ($workflow in @($group['List'])) {
            if (-not (Test-KcpsWorkflowType -Workflow $workflow -TypeName 'SimpleSortieWorkflow')) { continue }

            $workflowChanges = @()
            foreach ($node in @(Get-KcpsTerminalBattleNodes -RouteSpec $routeSpec)) {
                foreach ($entry in @($workflow['Strategies'] | Where-Object {
                    [int]$_['Condition']['Type'] -eq 1 -and
                    [int]$_['Condition']['Value'] -eq [int]$node['Value']
                })) {
                    if ($entry['Strategy']['DefaultAdvance'] -ne 2) {
                        $workflowChanges += "Terminal $($node['Letter']) DefaultAdvance: $($entry['Strategy']['DefaultAdvance']) -> 2"
                        if (-not $CheckOnly) { $entry['Strategy']['DefaultAdvance'] = 2 }
                        $fileChanged = $true
                    }
                }
            }
            foreach ($fallbackName in @('DefaultStrategy', 'DefaultBossBattleStrategy')) {
                $fallback = $workflow[$fallbackName]
                if ($null -ne $fallback -and $null -ne $fallback['DefaultWayPoint']) {
                    $workflowChanges += "${fallbackName}.DefaultWayPoint: configured -> null"
                    if (-not $CheckOnly) {
                        $fallback['DefaultWayPoint'] = $null
                    }
                    $fileChanged = $true
                }
            }
            $defaultChanges = @(Set-SafeFallbackStrategy -Strategy $workflow['DefaultStrategy'])
            if ($defaultChanges.Count -gt 0) {
                $workflowChanges += "DefaultStrategy: $($defaultChanges -join '; ')"
                $fileChanged = $true
            }

            if ($workflow['DefaultBossBattleStrategyFlag'] -ne $false) {
                $workflowChanges += "DefaultBossBattleStrategyFlag: $($workflow['DefaultBossBattleStrategyFlag']) -> false"
                if (-not $CheckOnly) {
                    $workflow['DefaultBossBattleStrategyFlag'] = $false
                }
                $fileChanged = $true
            }

            $bossChanges = @(Set-SafeFallbackStrategy -Strategy $workflow['DefaultBossBattleStrategy'])
            if ($bossChanges.Count -gt 0) {
                $workflowChanges += "DefaultBossBattleStrategy: $($bossChanges -join '; ')"
                $fileChanged = $true
            }

            $conditionalProblems = @()
            $conditionIndex = 0
            foreach ($conditional in @($workflow['Strategies'])) {
                $conditionIndex++
                if ($conditional['Condition']['Type'] -ne 1) {
                    $conditionalProblems += "Conditional#$conditionIndex uses Condition.Type=$($conditional['Condition']['Type']); expected map-point Type=1."
                }
                $strategy = $conditional['Strategy']
                $memo = [string]$strategy['Memo']
                $routeNode = $null
                if ($null -ne $routeSpec -and [int]$conditional['Condition']['Type'] -eq 1) {
                    $routeNode = @($routeSpec['Nodes'] | Where-Object {
                        [int]$_['Value'] -eq [int]$conditional['Condition']['Value']
                    } | Select-Object -First 1)[0]
                }
                $requiresWayPoint = $null -ne $routeNode -and (
                    ($routeNode.ContainsKey('RequiresWayPoint') -and [bool]$routeNode['RequiresWayPoint']) -or
                    [string]$routeNode['Kind'] -eq 'waypoint-select'
                )
                $wayPoint = $strategy['DefaultWayPoint']
                if ($null -ne $wayPoint -and -not $requiresWayPoint -and (
                    $null -ne $routeSpec -or (Test-KcpsWayPointEmpty -WayPoint $wayPoint)
                )) {
                    $workflowChanges += "Conditional#$conditionIndex DefaultWayPoint: configured on a non-route-selection node -> null"
                    if (-not $CheckOnly) {
                        $strategy['DefaultWayPoint'] = $null
                    }
                    $fileChanged = $true
                }
                if ($requiresWayPoint -and -not (Test-KcpsWayPointValid -WayPoint $wayPoint)) {
                    $conditionalProblems += "Conditional#$conditionIndex is a route-selection node but DefaultWayPoint is missing or invalid. Name must be set and the positive-size normalized rectangle must remain inside the map."
                }
                $isAirRaid = ($memo -match '空袭|空襲|air\s*raid') -and ($memo -notmatch '航空戦|航空战|air\s*battle')
                $isAirBattle = $memo -match '航空戦|航空战|air\s*battle'
                $isEscortDamageWhitelist = $memo -match '大破.*(許可|允许|可|ignore|白名单|白名單)'
                $declaredManualNight = $null -ne $routeNode -and $routeNode.Contains('ExpectedMidnight') -and [int]$routeNode['ExpectedMidnight'] -eq 0
                if ($strategy['DefaultMidnight'] -eq 0 -and -not $isAirRaid -and -not $declaredManualNight) {
                    if ($isAirBattle) {
                        $conditionalProblems += "Conditional#$conditionIndex is an old-style AirBattle/航空戦マス; it has a night-battle choice, so use StopPursuit(1) or NightAttack(2), not manual midnight."
                    } else {
                        $conditionalProblems += "Conditional#$conditionIndex has manual midnight but Memo is not a modern air-raid/空襲戦 point."
                    }
                } elseif ($strategy['DefaultMidnight'] -ge 3) {
                    $conditionalProblems += "Conditional#$conditionIndex uses unimplemented midnight strategy $($strategy['DefaultMidnight']); use 1/2, or manual 0 only for modern air-raid/空襲戦 points."
                }
                if ($strategy['EscortShipsHeavilyDamagedStrategy'] -ne 1 -and -not $isEscortDamageWhitelist) {
                    $conditionalProblems += "Conditional#$conditionIndex allows escort heavy-damage advance without a documented whitelist Memo."
                }
            }
            if (@($workflow['Strategies']).Count -eq 0) {
                $conditionalProblems += 'No conditional map-point strategies. Safe fallback will retreat/manual-pause instead of clearing automatically.'
            }

            if ($workflowChanges.Count -gt 0 -or $conditionalProblems.Count -gt 0) {
                $reports += [pscustomobject]@{
                    Group = $group['Name']
                    Workflow = $workflow['Name']
                    Sea = $workflow['Sea']
                    Area = $workflow['Area']
                    Changes = @($workflowChanges)
                    Problems = @($conditionalProblems)
                }
            }
        }
    }

    if ($fileChanged -and -not $CheckOnly) {
        Write-KcpsJson -Value $config | Set-Content -LiteralPath $resolvedPath -Encoding UTF8
    }

    $allReports += [pscustomobject]@{
        Path = $resolvedPath
        Changed = [bool]($fileChanged -and -not $CheckOnly)
        WouldChange = [bool]$fileChanged
        Reports = @($reports)
    }
}

$allReports | ConvertTo-Json -Depth 20
