#requires -Version 7.0
# 本文件只使用合成计划、模板和快照，不查询游戏接口。
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-ExpeditionCommon.ps1"
$script:checks = 0
function Assert-Test([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw "远征回归失败：$Label" }
    $script:checks++
}
function Assert-Rejected([scriptblock]$Action, [string]$Label) {
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $true }
    Assert-Test $rejected $Label
}
function New-FixtureWorkflow([string]$Type, [string]$Name) {
    return @{ Type = "KancollePlayerSimulatorKai.$Type, KancollePlayerSimulatorKai"; Guid = [guid]::NewGuid().ToString(); Name = $Name; EnableOnLoad = $true; TriggerOnEnabled = $true; EnableScript = $false; Script = $null }
}
function New-FixtureStepTemplate([string]$Name, [int]$Fleet, [int]$Mission) {
    $send = New-FixtureWorkflow 'SimpleExpeditionWorkflow' '合成出发'
    $send.Fleet = $Fleet; $send.Expedition = $Mission
    $send.EnableScript = $true; $send.EnableScriptChecker = $true
    $send.ScriptCheckerName = 'OnCheck'; $send.Script = "def OnCheck(fleet, expeditionId):`n    return True # 仅供离线测试"
    $organize = New-FixtureWorkflow 'BasicOrganizeFleetWorkflow' '合成编成'
    $organize.Fleet = $Fleet; $organize.Script = '# 合成编成检查'; $organize.Positions = @(@{ Selections = @(@{ Type = 0; Value = '合成条件' }) })
    $refit = New-FixtureWorkflow 'BasicRefitEquipmentWorkflow' '合成改装'
    $refit.Ships = @(@{ Fleet = $Fleet; SelectValue = 1; Slots = @(@{ Slot = 1; Equipments = @(@{ SelectValue = 90001 }) }) })
    $rel = New-FixtureWorkflow 'RelationalExpeditionWorkflow' '合成总控'
    $rel.Fleet = $Fleet; $rel.ExpeditionWorkflow = New-KcpsExpeditionReference $send.Guid
    $rel.OrganizeBeforeWorkflows = @((New-KcpsExpeditionReference $organize.Guid))
    $rel.RefitEquipmentBeforeWorkflows = @((New-KcpsExpeditionReference $refit.Guid))
    $rel.StopIfOrganizeBeforeSelectFailed = $false
    $rel.StopIfRuntimeLengthExceedFlag = $false; $rel.StopIfWithinTimePeriodFlag = $false
    $rel.AutoStoppedTriggerWorkflows = @(); $rel.StopIfLoopCountLargerOrEqualThanFlag = $false
    return @{ Name = $Name; List = @($rel, $send, $organize, $refit) }
}

$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempParent ('kcps-expedition-test-' + [guid]::NewGuid().ToString('N'))
try {
    $null = [IO.Directory]::CreateDirectory($testRoot)
    $generator = Join-Path $PSScriptRoot '..\New-KCPSExpeditionChain.ps1'
    $snapshotTool = Join-Path $PSScriptRoot '..\Get-KCPSExpeditionSnapshot.ps1'
    $nextTool = Join-Path $PSScriptRoot '..\Get-KCPSNextExpedition.ps1'
    $previousGuids = @()
    foreach ($case in @(
        @{ Key = '甲'; Quest = 91001; Missions = @(8101, 8102); Fleets = @(2, 4); Order = @(8102, 8101); Counts = @(2, 1) },
        @{ Key = '乙'; Quest = 92001; Missions = @(8203, 8202); Fleets = @(3, 2); Order = @(8203, 8202); Counts = @(1, 3) }
    )) {
        $planPath = Join-Path $testRoot "$($case.Key)-plan.json"
        $templatePath = Join-Path $testRoot "$($case.Key)-templates.json"
        $sourcePath = Join-Path $testRoot "$($case.Key)-raw.json"
        $snapshotPath = Join-Path $testRoot "$($case.Key)-snapshot.json"
        $statePath = Join-Path $testRoot "$($case.Key)-state.json"
        $outputPath = Join-Path $testRoot "$($case.Key)-output.conf.json"
        $base = @{ Name = '合成控制模板'; List = @((New-FixtureWorkflow 'MemoWorkflow' '说明'), (New-FixtureWorkflow 'SeriesByTimerWorkflow' '启动器'), (New-FixtureWorkflow 'BasicAcceptQuestWorkflow' '接任务')) }
        $templates = @($base)
        $chains = @()
        for ($f = 0; $f -lt $case.Fleets.Count; $f++) {
            $steps = @()
            $order = if ($f -eq 0) { $case.Order } else { @($case.Order[-1]) }
            foreach ($id in $order) {
                $templateName = "合成$($case.Key)舰队$($case.Fleets[$f])远征$id"
                $templates += New-FixtureStepTemplate $templateName $case.Fleets[$f] $id
                $steps += @{ missionId = $id; count = $case.Counts[$f]; templateName = $templateName }
            }
            $chains += @{ fleet = $case.Fleets[$f]; steps = $steps }
        }
        $plan = @{
            version = 1; name = "单次 远征 合成计划$($case.Key)"; memo = '仅验证结构，不用于游戏。'
            missions = @($case.Missions | ForEach-Object { @{ id = $_; name = "合成远征$_"; minutes = $_ - 8000; unlockStateRequired = 2 } })
            tasks = @(@{ questNo = $case.Quest; title = "合成任务$($case.Key)"; priority = 5; requirements = @($case.Missions | ForEach-Object { @{ missionId = $_; count = 4 } }) })
            chains = $chains
        }
        $raw = @{
            CapturedAt = [DateTimeOffset]::UtcNow.ToString('o')
            Fleets = @($case.Fleets | ForEach-Object { @{ api_id = $_; api_name = '合成舰队'; api_mission = @(0, 0, 0); api_ship = @(1, 2) } })
            QuestList = @{ api_list = @(-1, @{ api_no = $case.Quest; api_state = 2; api_progress_flag = 0; api_title = "合成任务$($case.Key)" }) }
            MissionList = @{ api_list_items = @($case.Missions | ForEach-Object { @{ api_mission_id = $_; api_state = 2 } }) }
        }
        $counts = @{}; foreach ($id in $case.Missions) { $counts[[string]$id] = 0 }
        $state = @{ completed = @{ ([string]$case.Quest) = $counts } }
        Write-KcpsExpeditionJson $plan $planPath
        Write-KcpsExpeditionJson $templates $templatePath
        Write-KcpsExpeditionJson $raw $sourcePath
        Write-KcpsExpeditionJson $state $statePath
        $templateHash = (Get-FileHash -LiteralPath $templatePath).Hash
        $found = @(& "$PSScriptRoot\..\Find-KCPSDefaultExpeditionTemplate.ps1" -DefaultPath $templatePath -ExpeditionId $case.Missions)
        Assert-Test ($found.Count -eq 3 -and @($found | Where-Object { $_.ExpeditionId -notin $case.Missions }).Count -eq 0) '模板查找按显式远征 ID 筛选'
        $snapshot = & $snapshotTool -PlanPath $planPath -SourcePath $sourcePath -OutputPath $snapshotPath
        Assert-Test ($snapshot.Quests.Count -eq 1 -and $snapshot.Quests[0].No -eq $case.Quest) '快照只提取输入任务，且跳过 API 占位元素'
        Assert-Test ($snapshot.TargetMissions.Count -eq $case.Missions.Count) '快照目标远征来自输入计划'
        $recommendation = & $nextTool -PlanPath $planPath -StatePath $statePath -Fleet $case.Fleets[0] -SnapshotPath $snapshotPath
        Assert-Test ($recommendation.Recommendation -eq 'candidate' -and $recommendation.Selected.QuestNo -eq $case.Quest) '下一项推荐使用输入任务'
        Assert-Test ($recommendation.Selected.MissionId -in $case.Missions) '推荐不引入计划外远征'
        $summary = & $generator -PlanPath $planPath -TemplatePath $templatePath -SnapshotPath $snapshotPath -OutputPath $outputPath
        $output = Read-KcpsExpeditionJson $outputPath
        Assert-Test ($output.Name -eq $plan.name -and $output.List[0].Name -eq '说明') '配置名称来自计划，说明位于首项'
        $guids = @($output.List | ForEach-Object { $_.Guid })
        Assert-Test (($guids | Sort-Object -Unique).Count -eq $guids.Count) '所有输出 GUID 唯一'
        $oldGuids = @($templates | ForEach-Object { $_.List } | ForEach-Object { $_.Guid })
        Assert-Test (@($guids | Where-Object { $_ -in $oldGuids -or $_ -in $previousGuids }).Count -eq 0) '输出 GUID 与模板及其他计划均不同'
        $previousGuids = $guids
        $accept = @($output.List | Where-Object { (Get-KcpsExpeditionType $_) -eq 'BasicAcceptQuestWorkflow' })[0]
        Assert-Test ($accept.Quests -is [array] -and $accept.Quests.Count -eq 1 -and $accept.Quests[0].SelectValue -eq [string]$case.Quest) '任务 ID 精确来自输入'
        Assert-Test (-not $accept.Quests[0].SuccessIfFull -and -not $accept.Quests[0].FailIfAccepted -and $accept.Quests[0].FailIfNotExist) '任务选择器失败语义保持严格'
        for ($c = 0; $c -lt $chains.Count; $c++) {
            $chainReport = $summary.Chains[$c]
            Assert-Test ($chainReport.Fleet -eq $chains[$c].fleet) '舰队顺序来自输入'
            for ($s = 0; $s -lt $chains[$c].steps.Count; $s++) {
                $step = $chains[$c].steps[$s]
                $report = $chainReport.Steps[$s]
                $controller = @($output.List | Where-Object { $_.Guid -eq $report.ControllerGuid })[0]
                $send = @($output.List | Where-Object { $_.Guid -eq $controller.ExpeditionWorkflow.Guid })[0]
                Assert-Test ($send.Expedition -eq $step.missionId -and $send.Fleet -eq $chains[$c].fleet) '出发步骤的远征和舰队对应输入'
                Assert-Test ($controller.StopIfLoopCountLargerOrEqualThanValue -eq $step.count -and $controller.Repeat) '步骤计数阈值来自输入'
                Assert-Test (-not $controller.StopIfOrganizeBeforeSelectFailed -and -not $controller.IgnoreExpeditionFailure) '失败不会被当成自动推进或忽略'
                Assert-Test ($controller.OrganizeBeforeWorkflows[0].Guid -in $guids -and $controller.RefitEquipmentBeforeWorkflows[0].Guid -in $guids) '编成和配装引用已重建'
                Assert-Test ($send.EnableScriptChecker -and $send.Script -like '*仅供离线测试*') '原有出发检查器保留'
                if ($s -lt $chains[$c].steps.Count - 1) {
                    Assert-Test ($controller.AutoStoppedTriggerWorkflows[0].Guid -eq $chainReport.Steps[$s + 1].ControllerGuid) '串联引用按输入步骤顺序生成'
                } else { Assert-Test ($controller.AutoStoppedTriggerWorkflows.Count -eq 0) '链末尾不循环或触发其他配置' }
            }
        }
        Assert-Test (@($output.List | Where-Object { $_.EnableOnLoad -or $_.TriggerOnEnabled }).Count -eq 0) '所有执行单元均不自动启动'
        Assert-Test ((Get-FileHash -LiteralPath $templatePath).Hash -eq $templateHash) '源模板保持不变'
        $badPlan = Copy-KcpsExpeditionObject $plan; $badPlan.Remove('chains')
        $badPath = Join-Path $testRoot 'bad.json'; Write-KcpsExpeditionJson $badPlan $badPath
        Assert-Rejected { & $generator -PlanPath $badPath -TemplatePath $templatePath -SnapshotPath $snapshotPath -OutputPath $outputPath } '缺少必要计划输入时拒绝生成'
        Write-KcpsExpeditionJson @{ completed = @{} } $badPath
        Assert-Rejected { & $nextTool -PlanPath $planPath -StatePath $badPath -Fleet $case.Fleets[0] -SnapshotPath $snapshotPath } '缺少完成记录时不猜测为零'
        $badSnapshot = Copy-KcpsExpeditionObject $snapshot; $badSnapshot.TargetMissions[0].IsOpen = $false
        Write-KcpsExpeditionJson $badSnapshot $badPath
        Assert-Rejected { & $generator -PlanPath $planPath -TemplatePath $templatePath -SnapshotPath $badPath -OutputPath $outputPath } '远征未开放时拒绝生成'
        $badSnapshot = Copy-KcpsExpeditionObject $snapshot; $badSnapshot.Quests = @()
        Write-KcpsExpeditionJson $badSnapshot $badPath
        Assert-Rejected { & $generator -PlanPath $planPath -TemplatePath $templatePath -SnapshotPath $badPath -OutputPath $outputPath } '无法验证任务 ID 时拒绝生成'
        $busySnapshot = Copy-KcpsExpeditionObject $snapshot; $busySnapshot.Fleets[0].IsExpeditioning = $true
        Write-KcpsExpeditionJson $busySnapshot $badPath
        $busy = & $nextTool -PlanPath $planPath -StatePath $statePath -Fleet $case.Fleets[0] -SnapshotPath $badPath
        Assert-Test ($busy.Recommendation -eq 'wait' -and $null -eq $busy.Selected) '忙碌舰队只建议等待'
        Assert-Rejected { & $generator -PlanPath $planPath -TemplatePath $templatePath -SnapshotPath $badPath -OutputPath $outputPath } '不把已经派出的远征混入新链'
        $closedSnapshot = Copy-KcpsExpeditionObject $snapshot
        foreach ($mission in $closedSnapshot.TargetMissions) { $mission.IsOpen = $false }
        Write-KcpsExpeditionJson $closedSnapshot $badPath
        $closed = & $nextTool -PlanPath $planPath -StatePath $statePath -Fleet $case.Fleets[0] -SnapshotPath $badPath
        Assert-Test ($closed.Recommendation -eq 'blocked' -and $null -eq $closed.Selected) '未开放远征不作为派遣候选'
        $badTemplates = Copy-KcpsExpeditionObject $templates
        $badTemplates[1].List[0].StopIfOrganizeBeforeSelectFailed = $true
        Write-KcpsExpeditionJson $badTemplates $badPath
        Assert-Rejected { & $generator -PlanPath $planPath -TemplatePath $badPath -SnapshotPath $snapshotPath -OutputPath $outputPath } '有额外自动停止条件时拒绝串联'
        $badTemplates = Copy-KcpsExpeditionObject $templates
        $badTemplates[1].List[0].ForceAutoStopAfterThisLoop = $true
        Write-KcpsExpeditionJson $badTemplates $badPath
        Assert-Rejected { & $generator -PlanPath $planPath -TemplatePath $badPath -SnapshotPath $snapshotPath -OutputPath $outputPath } '模板已启用强制自动停止时拒绝串联'
        $badSnapshot = Copy-KcpsExpeditionObject $snapshot; $badSnapshot.Fleets[0].IsExpeditioning = 'unknown'
        Write-KcpsExpeditionJson $badSnapshot $badPath
        Assert-Rejected { & $nextTool -PlanPath $planPath -StatePath $statePath -Fleet $case.Fleets[0] -SnapshotPath $badPath } '未知舰队状态不能被当成空闲'
    }
    $forbidden = Join-Path $script:KcpsSkillRoot 'expedition-test-output.conf.json'
    Assert-Rejected { & $generator -PlanPath $planPath -TemplatePath $templatePath -SnapshotPath $snapshotPath -OutputPath $forbidden } '不能将账号配置写入 Skill'
    Assert-Test (-not (Test-Path -LiteralPath $forbidden)) '禁止的输出位置没有创建文件'
    [pscustomobject]@{ Test = '通用远征离线回归'; Passed = $script:checks }
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith([IO.Path]::TrimEndingDirectorySeparator($tempParent) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolved) -notlike 'kcps-expedition-test-*') { throw '拒绝清理临时测试目录以外的路径。' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
