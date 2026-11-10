function Get-KcpsCombinedFleetCompositionProblems {
    param(
        [Parameter(Mandatory)][int]$CombinedFleetType,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Fleets
    )
    if ($CombinedFleetType -eq 0) { return }
    $problems = [System.Collections.Generic.List[object]]::new()
    function Add-CompositionProblem([int]$Fleet, [string]$Rule, [string]$Message) {
        $problems.Add([pscustomobject]@{ Fleet=$Fleet; Rule=$Rule; Problem="第${Fleet}舰队：$Message" })
    }
    if ($CombinedFleetType -notin @(1,2,3)) {
        Add-CompositionProblem 0 'UnknownType' "未知联合类型 $CombinedFleetType。"
        return $problems
    }
    foreach ($fleet in @(1,2)) {
        $positions = @($Fleets[[string]$fleet])
        if ($positions.Count -lt 2 -or $positions.Count -gt 6) {
            Add-CompositionProblem $fleet 'FleetSize' "需要2至6艘，实际为 $($positions.Count) 艘。"
        }
        foreach ($position in $positions) {
            if (@($position['Candidates']).Count -eq 0 -or
                @($position['Candidates'] | Where-Object { [int]$_['Stype'] -notin @(1..22) }).Count) {
                Add-CompositionProblem $fleet 'UnknownCandidate' '候选舰种无法解析，不能确认组成条件。'
            }
        }
    }
    if ($problems.Count) { return $problems }
    # 对每个位置的全部候选求上下界，不能只检查第一候选或两队合计。
    function Test-Count([int]$Fleet, [string]$Rule, [scriptblock]$Predicate, [int]$Min, [int]$Max, [string]$Label) {
        $lower = 0; $upper = 0
        foreach ($position in @($Fleets[[string]$Fleet])) {
            $candidates = @($position['Candidates'])
            $hits = @($candidates | Where-Object $Predicate).Count
            if ($hits -eq $candidates.Count) { $lower++ }
            if ($hits -gt 0) { $upper++ }
        }
        if ($lower -lt $Min -or $upper -gt $Max) {
            $actual = if ($lower -eq $upper) { "$lower" } else { "$lower 至 $upper" }
            $required = if ($Min -eq $Max) { "恰好 $Min" } else { "$Min 至 $Max" }
            Add-CompositionProblem $Fleet $Rule "$Label 需要${required}艘，候选编成实际为${actual}艘。"
        }
    }
    if ($CombinedFleetType -in @(1,2)) {
        foreach ($fleet in @(1,2)) {
            if (@($Fleets[[string]$fleet][0]['Candidates'] | Where-Object { [int]$_['Stype'] -in @(13,14) }).Count) {
                Add-CompositionProblem $fleet 'SubmarineFlagship' '潜水舰或潜水空母不能担任旗舰。'
            }
        }
        if ($CombinedFleetType -eq 1) {
            Test-Count 1 'CarrierMainCarriers' { [int]$_['Stype'] -in @(7,11,18) } 2 4 '空母系'
            Test-Count 1 'CarrierMainBattleships' { [int]$_['Stype'] -in @(8,9,10) } 0 2 '战舰级'
        } else {
            Test-Count 1 'SurfaceMainCapitalShips' { [int]$_['Stype'] -in @(3,5,6,8,9,10) } 2 6 '轻巡、重巡级与战舰级合计'
            Test-Count 1 'SurfaceMainHeavyCruisers' { [int]$_['Stype'] -in @(5,6) } 0 4 '重巡级'
            Test-Count 1 'SurfaceMainBattleships' { [int]$_['Stype'] -in @(8,9,10) } 0 4 '战舰级'
            Test-Count 1 'SurfaceMainRegularCarriers' { [int]$_['Stype'] -in @(11,18) } 0 1 '正规或装甲空母'
            Test-Count 1 'SurfaceMainLightCarriers' { [int]$_['Stype'] -eq 7 } 0 2 '轻空母'
            $ps = @($Fleets['1'])
            for ($i=0; $i -lt $ps.Count; $i++) {
                if (-not @($ps[$i]['Candidates'] | Where-Object { [int]$_['Stype'] -in @(11,18) }).Count) { continue }
                for ($j=0; $j -lt $ps.Count; $j++) {
                    if ($i -ne $j -and @($ps[$j]['Candidates'] | Where-Object { [int]$_['Stype'] -eq 7 }).Count) {
                        Add-CompositionProblem 1 'SurfaceMixedCarriers' '水上打击的正规或装甲空母不能与轻空母同时编入。'
                        break
                    }
                }
            }
        }
        Test-Count 2 'EscortLightCruiser' { [int]$_['Stype'] -eq 3 } 1 1 '轻巡（雷巡、练巡不计）'
        Test-Count 2 'EscortDestroyers' { [int]$_['Stype'] -eq 2 } 2 5 '驱逐（海防不计）'
        Test-Count 2 'EscortHeavyCruisers' { [int]$_['Stype'] -in @(5,6) } 0 2 '重巡级'
        Test-Count 2 'EscortSeaplaneCarriers' { [int]$_['Stype'] -eq 16 } 0 1 '水母'
        Test-Count 2 'EscortLightCarriers' { [int]$_['Stype'] -eq 7 } 0 1 '轻空母'
        Test-Count 2 'EscortRegularCarriers' { [int]$_['Stype'] -in @(11,18) } 0 0 '正规或装甲空母'
        Test-Count 2 'EscortBattleships' { [int]$_['Stype'] -in @(8,9,10) } 0 2 '战舰级'
        foreach ($position in @($Fleets['2'])) {
            foreach ($ship in @($position['Candidates'])) {
                if ([int]$ship['Stype'] -in @(8,9,10) -and [int]$ship['BaseSpeed'] -lt 10) {
                    # 组联合可能早于改装，当前装备提速不能替代最终方案的证据。
                    Add-CompositionProblem 2 'EscortSpeedNeedsEvidence' "$($ship['Name'])为原生低速战舰；需要另行证明组成联合时已达到高速+，不能按当前舰队速度或预期改装默认放行。"
                }
            }
        }
    } else {
        Test-Count 1 'TransportMainDestroyers' { [int]$_['Stype'] -in @(1,2) } 4 6 '驱逐与海防'
        Test-Count 1 'TransportMainCarriers' { [int]$_['Stype'] -eq 7 } 0 1 '护卫空母'
        Test-Count 1 'TransportMainTypes' { [int]$_['Stype'] -notin @(1,2,3,6,7,10,16,17,19,20,21,22) } 0 0 '输送主队禁止的舰种'
        foreach ($position in @($Fleets['1'])) {
            foreach ($ship in @($position['Candidates'])) {
                if ([int]$ship['Stype'] -eq 7 -and -not $ship['IsEscortCarrier']) {
                    Add-CompositionProblem 1 'TransportEscortCarrier' "$($ship['Name'])不在护卫空母表内，不能编入输送主队。"
                }
            }
        }
        Test-Count 2 'TransportEscortCruisers' { [int]$_['Stype'] -in @(3,21) } 1 2 '轻巡与练巡（雷巡不计）'
        Test-Count 2 'TransportEscortDestroyers' { [int]$_['Stype'] -in @(1,2) } 3 5 '驱逐与海防'
        Test-Count 2 'TransportEscortHeavyCruisers' { [int]$_['Stype'] -in @(5,6) } 0 2 '重巡级'
        Test-Count 2 'TransportEscortTypes' { [int]$_['Stype'] -notin @(1,2,3,5,6,21) } 0 0 '输送护卫队禁止的舰种'
        if (@($Fleets['2'][0]['Candidates'] | Where-Object { [int]$_['Stype'] -notin @(3,21) }).Count) {
            Add-CompositionProblem 2 'TransportEscortFlagship' '输送护卫队旗舰必须为轻巡或练巡。'
        }
    }
    return $problems
}

function Get-KcpsCombinedWorkflowProblems {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Workflows,
        [Parameter(Mandatory)][System.Collections.IDictionary]$OwnedShips,
        [Parameter(Mandatory)][System.Collections.IDictionary]$MasterShips
    )
    $combined = @($Workflows | Where-Object {
        (Test-KcpsWorkflowType $_ 'BasicCombinedFleetWorkflow') -and [int]$_['CombinedFleetType'] -ne 0
    })
    if (-not $combined.Count) { return }
    $cve = Get-Content -LiteralPath "$PSScriptRoot/data/KCPS-EscortCarrierIds.json" -Raw | ConvertFrom-Json -AsHashtable
    foreach ($workflow in $combined) {
        $fleets = @{}
        foreach ($fleet in @(1,2)) {
            $organize = @($Workflows | Where-Object {
                (Test-KcpsWorkflowType $_ 'BasicOrganizeFleetWorkflow') -and [int]$_['Fleet'] -eq $fleet
            })
            if ($organize.Count -ne 1) {
                [pscustomobject]@{Fleet=$fleet; Rule='AmbiguousOrganize'; Workflow=$workflow['Name']; Problem="第${fleet}舰队：无法唯一确定组成联合前的编成单元，不能用当前舰队代替验证。"}
                continue
            }
            $fleets[[string]$fleet] = @(
                foreach ($position in @($organize[0]['Positions'])) {
                    $candidates = @(
                        foreach ($selection in @($position['Selections'])) {
                            $id = [string]$selection['Value']
                            if ([int]$selection['Type'] -ne 0 -or -not $OwnedShips.Contains($id)) { @{Stype=0}; continue }
                            $ship = $OwnedShips[$id]
                            $masterId = [string]$ship['api_ship_id']
                            if (-not $MasterShips.Contains($masterId)) { @{Stype=0}; continue }
                            $master = $MasterShips[$masterId]
                            @{ Id=$id; Name=$master['api_name']; Stype=$master['api_stype']; BaseSpeed=$master['api_soku']; IsEscortCarrier=([int]$masterId -in $cve['Ids']) }
                        }
                    )
                    @{Candidates=$candidates}
                }
            )
        }
        if ($fleets.Count -ne 2) { continue }
        foreach ($problem in @(Get-KcpsCombinedFleetCompositionProblems -CombinedFleetType ([int]$workflow['CombinedFleetType']) -Fleets $fleets)) {
            $problem | Add-Member -NotePropertyName Workflow -NotePropertyValue $workflow['Name']
            $problem
        }
    }
}
