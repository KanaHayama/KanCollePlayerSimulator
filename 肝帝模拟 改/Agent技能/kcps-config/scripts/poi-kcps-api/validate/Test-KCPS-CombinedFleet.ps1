#requires -Version 7.0
param([string]$ConfigPath, [string]$GroupNameRegex)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"
function New-Fleet([int[]]$Types) {
    @(foreach ($type in $Types) { @{Candidates=@(@{Stype=$type; BaseSpeed=10; Name="Type$type"; IsEscortCarrier=$false})} })
}
function Check([string]$Name, [int]$Type, [hashtable]$Fleets, [string[]]$Expected=@()) {
    $actual = @(Get-KcpsCombinedFleetCompositionProblems $Type $Fleets)
    foreach ($rule in $Expected) { if ($rule -notin $actual.Rule) { throw "$Name 未检出 $rule" } }
    if (-not $Expected.Count -and $actual.Count) { throw "$Name 意外失败：$($actual.Problem -join ';')" }
    [pscustomobject]@{Test=$Name; Passed=$true; Rules=@($actual | ForEach-Object Rule)}
}
$main = New-Fleet @(8,8,5,3,2,7)
$escort = New-Fleet @(3,2,2,2,2,2)
$results = @(
    Check '合法水打' 2 @{'1'=$main; '2'=$escort}
    Check '六驱逐缺轻巡' 2 @{'1'=$main; '2'=(New-Fleet @(2,2,2,2,2,2))} @('EscortLightCruiser','EscortDestroyers')
    Check '三重巡缺轻巡' 2 @{'1'=$main; '2'=(New-Fleet @(5,5,5,2,2,2))} @('EscortLightCruiser','EscortHeavyCruisers')
    Check '轻巡放错队' 2 @{'1'=(New-Fleet @(8,8,3,3,5,7)); '2'=(New-Fleet @(2,2,2,2,2,2))} @('EscortLightCruiser')
    Check '雷巡不能代轻巡' 2 @{'1'=$main; '2'=(New-Fleet @(4,2,2,2,2,2))} @('EscortLightCruiser')
    Check '练巡不能代水打轻巡' 2 @{'1'=$main; '2'=(New-Fleet @(21,2,2,2,2,2))} @('EscortLightCruiser')
    Check '海防不能代水打驱逐' 2 @{'1'=$main; '2'=(New-Fleet @(3,2,1,5,5,16))} @('EscortDestroyers')
    Check '护卫双轻巡' 2 @{'1'=$main; '2'=(New-Fleet @(3,3,2,2,2,2))} @('EscortLightCruiser')
    Check '水打正轻母混编' 2 @{'1'=(New-Fleet @(8,8,3,2,11,7)); '2'=$escort} @('SurfaceMixedCarriers')
    Check '水打主队核心不足' 2 @{'1'=(New-Fleet @(3,2,2,2,2,7)); '2'=$escort} @('SurfaceMainCapitalShips')
    Check '合法机动' 1 @{'1'=(New-Fleet @(8,8,11,11,18,7)); '2'=$escort}
    Check '机动少空母' 1 @{'1'=$main; '2'=$escort} @('CarrierMainCarriers')
    Check '护卫不能正空母' 1 @{'1'=(New-Fleet @(8,8,11,11,18,7)); '2'=(New-Fleet @(3,2,2,11,5,5))} @('EscortRegularCarriers')
    Check '潜母不能旗舰' 2 @{'1'=(New-Fleet @(14,8,8,3,2,7)); '2'=$escort} @('SubmarineFlagship')
    Check '合法输送含练巡海防' 3 @{'1'=(New-Fleet @(2,2,2,1,16,10)); '2'=(New-Fleet @(21,2,2,1,5,6))}
    Check '输送旗舰错误' 3 @{'1'=(New-Fleet @(2,2,2,2,16,10)); '2'=(New-Fleet @(2,3,2,2,5,6))} @('TransportEscortFlagship')
    Check '输送主队少驱逐' 3 @{'1'=$main; '2'=$escort} @('TransportMainDestroyers','TransportMainTypes','TransportEscortCarrier')
    Check '缺少舰队' 2 @{'1'=$main; '2'=@()} @('FleetSize')
    $unknown = New-Fleet @(0,2,2,2,2,2)
    Check '缺少舰种拒绝放行' 2 @{'1'=$main; '2'=$unknown} @('UnknownCandidate')
    $rotation = New-Fleet @(3,2,2,2,2,2)
    $rotation[0]['Candidates'] += @{Stype=2; BaseSpeed=10; Name='备用驱逐'}
    Check '备用候选不合法' 2 @{'1'=$main; '2'=$rotation} @('EscortLightCruiser')
    $slow = New-Fleet @(3,2,2,9,5,5)
    $slow[3]['Candidates'][0]['BaseSpeed']=5
    Check '低速战舰不能假设提速' 2 @{'1'=$main; '2'=$slow} @('EscortSpeedNeedsEvidence')
    $owned=@{}; $masters=@{}; $workflows=@()
    foreach ($f in @(1,2)) {
        $types=if($f -eq 1){@(8,8,5,3,2,7)}else{@(2,2,2,2,2,2)}
        $positions=@(); $n=0
        foreach ($t in $types) {
            $id=[string]($f*100+(++$n)); $owned[$id]=@{api_ship_id=$id}; $masters[$id]=@{api_stype=$t;api_soku=10;api_name=$id}
            $positions+=@{Selections=@(@{Type=0;Value=$id;Memo='轻巡'})}
        }
        $workflows+=@{Type='KancollePlayerSimulatorKai.BasicOrganizeFleetWorkflow, Test'; Fleet=$f; Positions=$positions}
    }
    $workflows+=@{Type='KancollePlayerSimulatorKai.BasicCombinedFleetWorkflow, Test'; CombinedFleetType=2; Name='组成联合舰队'}
    $actual=@(Get-KcpsCombinedWorkflowProblems $workflows $owned $masters)
    if ('EscortLightCruiser' -notin $actual.Rule) { throw '实际舰种读取失败，不能信任船名备注。' }
    [pscustomobject]@{Test='从最终编成实例读主数据，不信任备注';Passed=$true}
)
if ($ConfigPath) {
    $cfg=Read-KcpsJson $ConfigPath
    $groups=@(Get-KcpsGroups $cfg | Where-Object { [string]$_['Name'] -match $GroupNameRegex })
    if ($groups.Count -ne 1) { throw '集成测试需要明确指定一套配置。' }
    $group=$groups[0]
    $owned=Get-PoiData ships; $masters=Get-KcpsConstShips (Get-PoiData const)
    $main=@($group.List | Where-Object { (Test-KcpsWorkflowType $_ 'BasicOrganizeFleetWorkflow') -and [int]$_['Fleet'] -eq 1 })[0]
    $escort=@($group.List | Where-Object { (Test-KcpsWorkflowType $_ 'BasicOrganizeFleetWorkflow') -and [int]$_['Fleet'] -eq 2 })[0]
    $dd=@(0..($main.Positions.Count-1) | Where-Object {
        $id=[string]$main.Positions[$_].Selections[0].Value
        [int]$masters[[string]$owned[$id]['api_ship_id']]['api_stype'] -eq 2
    })[0]
    $cl=@(0..($escort.Positions.Count-1) | Where-Object {
        $id=[string]$escort.Positions[$_].Selections[0].Value
        [int]$masters[[string]$owned[$id]['api_ship_id']]['api_stype'] -eq 3
    })[0]
    $swap=$main.Positions[$dd];$main.Positions[$dd]=$escort.Positions[$cl];$escort.Positions[$cl]=$swap
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('kcps-combined-regression-'+[guid]::NewGuid()+'.conf.json')
    try {
        [IO.File]::WriteAllText($temp,(Write-KcpsJson @($group)),[Text.UTF8Encoding]::new($false))
        $general=& "$PSScriptRoot\KCPS-ValidateConfig.ps1" -Path $temp | Out-String | ConvertFrom-Json -AsHashtable
        $target=@($general.Groups)[0]
        if ('EscortLightCruiser' -notin @($target.CombinedCompositionProblems | ForEach-Object {$_['Rule']}) -or -not $general.ProblemCount) {
            throw '普通校验入口漏报护卫缺轻巡。'
        }
        $results += [pscustomobject]@{Test='普通校验入口阻断轻巡放错队';Passed=$true}
        $event=@(& "$PSScriptRoot\KCPS-ValidateEventSortieConfig.ps1" -Path $temp -NoThrow | Out-String | ConvertFrom-Json -AsHashtable)
        if (-not @($event[0].Problems | Where-Object {$_ -match '第2舰队：轻巡.*实际为0艘'}).Count -or $event[0].Valid) {
            throw '活动校验入口漏报护卫缺轻巡。'
        }
        $results += [pscustomobject]@{Test='活动校验入口阻断轻巡放错队';Passed=$true}
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
}
[ordered]@{Tests=$results.Count; Passed=$results.Count; Results=$results} | ConvertTo-Json -Depth 8
