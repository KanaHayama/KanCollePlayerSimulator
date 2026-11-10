#requires -Version 7.0
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TemplatePath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SnapshotPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [ValidateRange(1, 1440)][int]$MaxSnapshotAgeMinutes = 15
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\KCPS-ExpeditionCommon.ps1"
Assert-KcpsPrivateOutputPath -Path $OutputPath
$plan = Read-KcpsExpeditionPlan -Path $PlanPath
$snapshot = Read-KcpsExpeditionJson -Path $SnapshotPath
Assert-KcpsExpeditionSnapshot -Snapshot $snapshot -MaxAgeMinutes $MaxSnapshotAgeMinutes
$templates = @(Read-KcpsExpeditionJson -Path $TemplatePath)
# ConvertFrom-Json -NoEnumerate 保留文件顶层数组；此处统一展开为配置列表。
if ($templates.Count -eq 1 -and $templates[0] -is [array]) { $templates = @($templates[0]) }
foreach ($group in $templates) {
    if ($group -isnot [System.Collections.IDictionary] -or $group.List -isnot [array]) { throw '模板必须是 KCPS 配置或配置数组，且 List 必须是数组。' }
}
$allTemplateWorkflows = @($templates | ForEach-Object { $_.List })

function New-ControlWorkflow {
    param([string]$Type, [string]$Name, [string]$Memo)
    $matches = @($allTemplateWorkflows | Where-Object { (Get-KcpsExpeditionType $_) -eq $Type })
    if ($matches.Count -eq 0) { throw "模板缺少必要类型：$Type。" }
    $copy = Copy-KcpsExpeditionObject $matches[0]
    foreach ($key in @($copy.Keys)) {
        if ($key -eq 'Workflows' -or $key.EndsWith('Workflows')) { $copy[$key] = @() }
    }
    $copy.Guid = [guid]::NewGuid().ToString()
    $copy.Name = $Name
    $copy.Memo = $Memo
    $copy.EnableOnLoad = $false
    $copy.TriggerOnEnabled = $false
    $copy.EnableScript = $false
    $copy.Script = $null
    return $copy
}

function Update-CopiedGuids {
    param([object]$Value, [hashtable]$GuidMap)
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $child = $Value[$key]
            if ($child -is [string]) {
                if ($GuidMap.ContainsKey($child)) { $Value[$key] = $GuidMap[$child] }
                elseif ($key -eq 'Guid' -and $child) { throw '模板包含指向其他配置的 GUID，不能安全复制。' }
                elseif ($key -eq 'Script') {
                    foreach ($old in $GuidMap.Keys) {
                        if ($child.IndexOf($old, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw '模板脚本内含执行单元 GUID，需先将其改成可独立复用的模板。' }
                    }
                }
            } else { Update-CopiedGuids -Value $child -GuidMap $GuidMap }
        }
    } elseif ($Value -is [array]) {
        foreach ($child in $Value) { Update-CopiedGuids -Value $child -GuidMap $GuidMap }
    }
}

function Assert-GeneratedReferences {
    param([object]$Value, [hashtable]$Known)
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            if ($key -eq 'Guid' -and $Value[$key] -and -not $Known.ContainsKey([string]$Value[$key])) { throw '生成结果包含悬空执行单元引用。' }
            Assert-GeneratedReferences -Value $Value[$key] -Known $Known
        }
    } elseif ($Value -is [array]) {
        foreach ($child in $Value) { Assert-GeneratedReferences -Value $child -Known $Known }
    }
}

function Assert-TemplateFleet {
    param([object]$Value, [int]$Fleet)
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            if ($key -eq 'Fleet' -and [int]$Value[$key] -gt 0 -and [int]$Value[$key] -ne $Fleet) { throw '模板中的编成、改装或其他动作引用了不同舰队，不能直接改写舰队编号。' }
            Assert-TemplateFleet -Value $Value[$key] -Fleet $Fleet
        }
    } elseif ($Value -is [array]) {
        foreach ($child in $Value) { Assert-TemplateFleet -Value $child -Fleet $Fleet }
    }
}

$memo = New-ControlWorkflow -Type 'MemoWorkflow' -Name '说明' -Memo $plan.memo
$starter = New-ControlWorkflow -Type 'SeriesByTimerWorkflow' -Name '启动远征链' -Memo '接取输入任务后，启动各舰队输入的第一步。仅手动启动一次。'
$starter.Days = 0; $starter.Hours = 0; $starter.Minutes = 0; $starter.Seconds = 0
$starter.Random = '00:00:00'; $starter.Restart = $false; $starter.TriggerType = 1
$workflows = [Collections.Generic.List[object]]::new()
$workflows.Add($memo); $workflows.Add($starter)
$startReferences = [Collections.Generic.List[object]]::new()

if ($plan.tasks.Count -gt 0) {
    $accept = New-ControlWorkflow -Type 'BasicAcceptQuestWorkflow' -Name '接任务' -Memo '仅按输入且已由快照核实的任务 ID 接取；不自动提交或选择奖励。'
    $accept.Quests = @(
        foreach ($task in $plan.tasks) {
            $actual = @($snapshot.Quests | Where-Object { $_.No -eq $task.questNo -and $_.Title -eq $task.title -and $_.State -in @(1, 2) })
            if ($actual.Count -ne 1) { throw '无法从快照确认计划任务的 ID、标题或可接取状态。' }
            @{ SelectMethod = 0; SelectValue = [string]$task.questNo; FailIfNotExist = $true; FailIfAccepted = $false; SuccessIfFull = $false }
        }
    )
    $workflows.Add($accept)
    $startReferences.Add((New-KcpsExpeditionReference $accept.Guid))
}

$chainSummary = [Collections.Generic.List[object]]::new()
foreach ($chain in $plan.chains) {
    $fleetState = @($snapshot.Fleets | Where-Object { $_.Fleet -eq $chain.fleet })
    if ($fleetState.Count -ne 1 -or $fleetState[0].IsExpeditioning -isnot [bool]) { throw '指定舰队的当前状态不完整。' }
    if ($fleetState[0].IsExpeditioning) { throw '指定舰队正在远征，请归还后重新查询并生成，避免把已有派遣混入新链。' }
    $controllers = [Collections.Generic.List[object]]::new()
    $steps = [Collections.Generic.List[object]]::new()
    foreach ($step in $chain.steps) {
        $mission = @($plan.missions | Where-Object { $_.id -eq $step.missionId })[0]
        $opened = @($snapshot.TargetMissions | Where-Object { $_.Id -eq $step.missionId -and $_.IsOpen -eq $true -and $_.UnlockState -eq $mission.unlockStateRequired })
        if ($opened.Count -ne 1) { throw '当前快照无法确认步骤中的远征已开放。' }
        $matches = @($templates | Where-Object { $_.Name -eq $step.templateName })
        if ($matches.Count -ne 1) { throw '每个步骤必须指定唯一的现有远征模板配置名。' }
        $source = @($matches[0].List | Where-Object { (Get-KcpsExpeditionType $_) -ne 'MemoWorkflow' })
        $allowed = @('SimpleExpeditionWorkflow', 'RelationalExpeditionWorkflow', 'BasicOrganizeFleetWorkflow', 'BasicRefitEquipmentWorkflow', 'BasicSupplyWorkflow', 'BasicDockingWorkflow')
        foreach ($workflow in $source) {
            if ((Get-KcpsExpeditionType $workflow) -notin $allowed) { throw '步骤模板包含尚未支持安全串联的执行单元，请先拆出独立远征模板。' }
        }
        $sends = @($source | Where-Object { (Get-KcpsExpeditionType $_) -eq 'SimpleExpeditionWorkflow' })
        $rels = @($source | Where-Object { (Get-KcpsExpeditionType $_) -eq 'RelationalExpeditionWorkflow' })
        if ($sends.Count -ne 1 -or $rels.Count -ne 1) { throw '每个步骤模板必须包含唯一的出发执行单元和远征总控。' }
        if ($sends[0].Expedition -ne $step.missionId -or $sends[0].Fleet -ne $chain.fleet -or $rels[0].Fleet -ne $chain.fleet) { throw '模板的远征 ID 或舰队与输入步骤不匹配，不能猜测或直接替换。' }
        if ($rels[0].ExpeditionWorkflow.Guid -ne $sends[0].Guid) { throw '模板总控未关联同一配置中的出发执行单元。' }
        if ($sends[0].EnableScriptChecker -ne $true -or -not $sends[0].ScriptCheckerName -or -not $sends[0].Script) { throw '步骤模板缺少完整的远征条件检查器。' }
        if ($rels[0].Contains('Script') -and $rels[0].Script) { throw '远征总控模板含自定义脚本，可能改变自动停止条件，不能直接串联。' }
        if ($rels[0].Contains('ForceAutoStopAfterThisLoop') -and $rels[0].ForceAutoStopAfterThisLoop) { throw '模板启用了本轮后强制自动停止，不能据此判定步骤完成。' }
        foreach ($key in $rels[0].Keys) {
            if ($key.StartsWith('StopIf') -and $key -ne 'StopIfLoopCountLargerOrEqualThanFlag' -and $rels[0][$key] -is [bool] -and $rels[0][$key]) {
                throw '模板含次数以外的自动停止条件，不能将自动停止直接当成下一步启动信号。'
            }
        }
        Assert-TemplateFleet -Value $source -Fleet $chain.fleet
        $guidMap = @{}
        foreach ($workflow in $source) {
            $id = [string]$workflow.Guid
            $parsed = [guid]::Empty
            if (-not [guid]::TryParse($id, [ref]$parsed) -or $parsed -eq [guid]::Empty -or $guidMap.ContainsKey($id)) { throw '模板执行单元 GUID 无效或重复。' }
            $guidMap[$id] = [guid]::NewGuid().ToString()
        }
        $copies = @(Copy-KcpsExpeditionObject -Value $source)
        if ($copies.Count -eq 1 -and $copies[0] -is [array]) { $copies = @($copies[0]) }
        Update-CopiedGuids -Value $copies -GuidMap $guidMap
        $ordinal = $controllers.Count + 1
        foreach ($copy in $copies) {
            $copy.EnableOnLoad = $false; $copy.TriggerOnEnabled = $false
            $copy.Name = "第$($chain.fleet)舰队 第${ordinal}步 $($copy.Name)"
            $workflows.Add($copy)
        }
        $controller = @($copies | Where-Object { (Get-KcpsExpeditionType $_) -eq 'RelationalExpeditionWorkflow' })[0]
        $controller.StopIfLoopCountLargerOrEqualThanFlag = $true
        $controller.StopIfLoopCountLargerOrEqualThanValue = [int]$step.count
        $controller.Repeat = $true
        $controller.StopIfOrganizeBeforeSelectFailed = $false
        $controller.IgnoreExpeditionFailure = $false
        $controller.StopIfRuntimeLengthExceedFlag = $false
        $controller.StopIfWithinTimePeriodFlag = $false
        $controller.EnableScript = $false
        $controller.Script = $null
        $controller.WaitFleetReturn = $true
        $controller.AutoStoppedEnableWorkflows = @()
        $controller.AutoStoppedTriggerWorkflows = @()
        $controllers.Add($controller)
        $steps.Add(@{ MissionId = $step.missionId; Count = $step.count; ControllerGuid = $controller.Guid; TemplateName = $step.templateName })
    }
    for ($i = 0; $i -lt $controllers.Count - 1; $i++) {
        $controllers[$i].AutoStoppedTriggerWorkflows = @((New-KcpsExpeditionReference $controllers[$i + 1].Guid))
    }
    $startReferences.Add((New-KcpsExpeditionReference $controllers[0].Guid))
    $chainSummary.Add(@{ Fleet = $chain.fleet; Steps = @($steps.ToArray()) })
}
$starter.Workflows = @($startReferences.ToArray())
$memo.Memo = $plan.memo + "`n各舰队按输入顺序完成每步指定次数后推进；条件检查或出发失败不能忽略。运行时不要使用强制自动停止开关，该操作会触发后续步骤；需要中断时应停止整条链。生成文件不会派遣舰队，不自动提交任务或选择奖励。"
$known = @{}
foreach ($workflow in $workflows) {
    if ($known.ContainsKey([string]$workflow.Guid)) { throw '生成结果出现重复 GUID。' }
    $known[[string]$workflow.Guid] = $true
}
Assert-GeneratedReferences -Value $workflows.ToArray() -Known $known
$result = @{ Name = $plan.name; List = @($workflows.ToArray()) }
Write-KcpsExpeditionJson -Value $result -Path $OutputPath
[pscustomobject]@{ OutputPath = Resolve-KcpsFileSystemPath $OutputPath; WorkflowCount = $workflows.Count; Chains = @($chainSummary.ToArray()); StructuralValidationPassed = $true }
