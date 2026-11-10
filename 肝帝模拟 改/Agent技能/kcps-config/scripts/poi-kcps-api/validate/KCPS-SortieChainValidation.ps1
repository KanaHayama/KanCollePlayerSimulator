#requires -Version 7.0
. (Join-Path $PSScriptRoot '..\common\KCPS-SortieChain.ps1')

function Test-KcpsCanonicalSortieChainScript {
    param([string]$Script, [string]$Role = '')
    try {
        $metadata = Get-KcpsSortieChainMetadata -Script $Script
        if ($null -eq $metadata -or $metadata['Version'] -ne 2 -or
            ($Role -and [string]$metadata['Role'] -cne $Role)) { return $false }
        $expected = New-KcpsSortieChainScript -Metadata $metadata
        return (($Script -replace "`r`n", "`n") -ceq ($expected -replace "`r`n", "`n"))
    } catch { return $false }
}

function Test-KcpsCanonicalSortieCompletionNotice {
    param($Workflow)
    if ($Workflow -isnot [System.Collections.IDictionary] -or
        [string]$Workflow['Type'] -notmatch '(?:^|\.)SimpleRaiseUserEventWorkflow(?:,|$)' -or
        [string]$Workflow['Name'] -cne '出击完成' -or
        -not (Test-KcpsCanonicalSortieChainScript -Script ([string]$Workflow['Script']) -Role Notice)) { return $false }
    $metadata = Get-KcpsSortieChainMetadata -Script ([string]$Workflow['Script'])
    return ([string]$Workflow['Guid'] -eq [string]$metadata['NoticeGuid'] -and
        [string]$Workflow['Message'] -ceq [string]$metadata['CompletionMessage'] -and
        $Workflow['EnableOnLoad'] -is [bool] -and $Workflow['EnableOnLoad'] -and
        $Workflow['EnableScript'] -is [bool] -and $Workflow['EnableScript'] -and
        $Workflow['TriggerOnEnabled'] -is [bool] -and -not $Workflow['TriggerOnEnabled'])
}

function Get-KcpsSortieChainValidation {
    param([object[]]$Groups, [object]$PolicyDocument = $null)
    $problems = [System.Collections.Generic.List[object]]::new()
    $records = [System.Collections.Generic.List[object]]::new()
    $chains = [System.Collections.Generic.List[object]]::new()
    $independent = @{}
    $add = {
        param($Code, $Group, $QuestId, $ChainId, $Text)
        $problems.Add([pscustomobject]@{ Code=$Code; Group=$Group; QuestId=$QuestId; ChainId=$ChainId; Problem=$Text })
    }
    $isType = { param($Workflow, $Name)
        $Workflow -is [System.Collections.IDictionary] -and
        [string]$Workflow['Type'] -match ('(?:^|\.)' + [regex]::Escape($Name) + '(?:,|$)')
    }
    foreach ($group in @($Groups)) {
        $list = @($group['List'])
        $sorties = @($list | Where-Object { & $isType $_ 'SimpleSortieWorkflow' })
        $controllers = @($list | Where-Object { & $isType $_ 'RelationalSortieWorkflow' })
        $normal = $sorties.Count -gt 0
        foreach ($sortie in $sorties) {
            $seaValue = 0; $areaValue = 0
            if (-not [int]::TryParse([string]$sortie['Sea'], [ref]$seaValue) -or
                -not [int]::TryParse([string]$sortie['Area'], [ref]$areaValue) -or $seaValue -lt 0 -or $areaValue -lt 1) {
                $normal = $false
                & $add 'SortieMapShape' ([string]$group['Name']) $null $null '出击海域必须是非负整数 Sea 与正整数 Area，不能据无效海域判断接续范围。'
            } elseif ($seaValue -eq 0) { $normal = $false }
        }
        $taskIds = @(@($list | Where-Object { & $isType $_ 'BasicAcceptQuestWorkflow' }) | ForEach-Object {
            foreach ($selector in @($_['Quests'])) {
                if ($selector -is [System.Collections.IDictionary] -and $selector.Contains('SelectMethod') -and
                    [int]$selector['SelectMethod'] -eq 0 -and [string]$selector['SelectValue'] -match '^[1-9]\d*$') {
                    [long]$selector['SelectValue']
                }
            }
        } | Sort-Object -Unique)
        $managed = @($list | Where-Object {
            [string]$_['Script'] -match 'KCPS Sortie Chain|KCPS-SORTIE-CHAIN-METADATA'
        })
        $record = [pscustomobject]@{
            Name=[string]$group['Name']; Group=$group; List=$list; Sorties=$sorties; Controllers=$controllers
            IsNormal=$normal; TaskIds=$taskIds; Metadata=$null; Canonical=$false; Notice=$null; NoticeMetadata=$null
            Managed=$managed.Count -gt 0; Candidate=$false
        }
        $records.Add($record)
        if ($managed.Count -eq 0) { continue }
        if (-not $normal -or $sorties.Count -ne 1 -or $controllers.Count -ne 1) {
            & $add 'ManagedScope' $record.Name $null $null '受管理接续仅支持每组一个通常海域出击、一个总控和一个独立出击完成通知。'
            continue
        }
        $parsed = @()
        foreach ($workflow in $managed) {
            try {
                $metadata = Get-KcpsSortieChainMetadata -Script ([string]$workflow['Script'])
                if ($null -eq $metadata) { throw '缺少有效元数据。' }
                $expectedScript = New-KcpsSortieChainScript -Metadata $metadata
                $canonical = (([string]$workflow['Script'] -replace "`r`n", "`n") -ceq ($expectedScript -replace "`r`n", "`n"))
                if (-not $canonical) {
                    & $add 'ManagedScriptMismatch' $record.Name $metadata['QuestId'] $metadata['ChainId'] '受管理脚本与元数据对应的完整生成代码不一致；不能仅凭标记或元数据放行。'
                }
                if ($metadata['Version'] -eq 1) {
                    & $add 'LegacyChainNeedsUpgrade' $record.Name $metadata['QuestId'] $metadata['ChainId'] '检测到 v1 接续；需要迁移为独立出击完成通知的 v2 结构，不能按新配置交付。'
                    continue
                }
                $parsed += [pscustomobject]@{Workflow=$workflow;Metadata=$metadata;Canonical=$canonical}
            } catch {
                & $add 'ManagedMetadata' $record.Name $null $null '接续标记或元数据无效，无法核验完整脚本。'
            }
        }
        $sources = @($parsed | Where-Object { $_.Metadata['Role'] -ceq 'Controller' })
        $notices = @($parsed | Where-Object { $_.Metadata['Role'] -ceq 'Notice' })
        if ($sources.Count -ne 1 -or -not (& $isType $sources[0].Workflow 'RelationalSortieWorkflow')) {
            & $add 'MissingManagedController' $record.Name $null $null '每个接续阶段必须有唯一的 v2 总控结果源。'
        } else {
            $record.Metadata=$sources[0].Metadata; $record.Canonical=$sources[0].Canonical
        }
        if ($notices.Count -ne 1 -or -not (& $isType $notices[0].Workflow 'SimpleRaiseUserEventWorkflow')) {
            & $add 'MissingCompletionNotice' $record.Name $null $null '每个接续阶段必须有唯一的 v2 出击完成通知，不能由总控直接发送 Clear。'
        } else {
            $record.Notice=$notices[0].Workflow; $record.NoticeMetadata=$notices[0].Metadata
        }
    }

    # Exceptions are explicit input, never inferred from names or prose in configuration memos.
    if ($null -ne $PolicyDocument) {
        if ($PolicyDocument -isnot [System.Collections.IDictionary] -or
            @($PolicyDocument.Keys | Where-Object { $_ -cnotin @('Version','Policies') }).Count -gt 0 -or
            ($PolicyDocument['Version'] -isnot [int] -and $PolicyDocument['Version'] -isnot [long]) -or
            $PolicyDocument['Version'] -ne 1 -or $PolicyDocument['Policies'] -isnot [array]) {
            & $add 'PolicyShape' $null $null $null '独立运行计划必须仅包含 Version=1 和 Policies 数组。'
        } else {
            foreach ($policy in @($PolicyDocument['Policies'])) {
                if ($policy -isnot [System.Collections.IDictionary] -or
                    @($policy.Keys | Where-Object { $_ -cnotin @('QuestId','Mode','Groups','Reason') }).Count -gt 0 -or
                    ($policy['QuestId'] -isnot [int] -and $policy['QuestId'] -isnot [long]) -or
                    [long]$policy['QuestId'] -le 0 -or $policy['Reason'] -isnot [string] -or
                    [string]::IsNullOrWhiteSpace([string]$policy['Reason']) -or
                    $policy['Groups'] -isnot [array] -or @($policy['Groups']).Count -eq 0) {
                    & $add 'PolicyShape' $null $null $null '每项独立运行计划必须给出精确 QuestId、Mode、非空 Groups 数组与 Reason，不接受额外字段。'
                    continue
                }
                if ([string]$policy['Mode'] -cne 'Independent') {
                    & $add 'PolicyModeUnsupported' $null $policy['QuestId'] $null '当前只支持显式 Independent 计划；跨文件 External 接续需要单独核验，不能据此声明通过。'
                    continue
                }
                $seen = @{}
                foreach ($name in @($policy['Groups'])) {
                    if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or $seen.ContainsKey($name)) {
                        & $add 'PolicyGroupDuplicate' ([string]$name) $policy['QuestId'] $null '独立计划的组名必须非空且不能重复。'
                        continue
                    }
                    $seen[$name] = $true
                    $matches = @($records | Where-Object { $_.Name -ceq $name })
                    if ($matches.Count -ne 1 -or -not $matches[0].IsNormal -or
                        [long]$policy['QuestId'] -notin $matches[0].TaskIds) {
                        & $add 'PolicyGroupScope' $name $policy['QuestId'] $null '独立计划必须精确命中唯一通常海域配置，且该配置含相同的精确任务 ID。'
                        continue
                    }
                    $key = "$($policy['QuestId'])|$name"
                    if ($independent.ContainsKey($key)) {
                        & $add 'PolicyGroupDuplicate' $name $policy['QuestId'] $null '同一任务配置重复声明独立计划。'
                    } else { $independent[$key] = $true }
                    if ($matches[0].Managed) {
                        & $add 'PolicyManagedConflict' $name $policy['QuestId'] $null 'Independent 不能覆盖已经安装的接续脚本；请先明确该组的实际运行方式。'
                    }
                }
            }
        }
    }

    $allTaskIds = @($records | Where-Object IsNormal | ForEach-Object { $_.TaskIds } | Sort-Object -Unique)
    foreach ($taskId in $allTaskIds) {
        $taskGroups = @($records | Where-Object { $_.IsNormal -and $taskId -in $_.TaskIds })
        $maps = @($taskGroups | ForEach-Object { $_.Sorties } | ForEach-Object { "$($_['Sea'])-$($_['Area'])" } | Sort-Object -Unique)
        if ($maps.Count -lt 2) { continue }
        foreach ($record in $taskGroups) {
            $record.Candidate = $true
            # A managed chain identifies its primary verified quest explicitly; shared secondary quests do not require extra chains.
            if ($record.Managed) { continue }
            if (-not $independent.ContainsKey("${taskId}|$($record.Name)")) {
                & $add 'MissingChain' $record.Name $taskId $null '同一精确任务包含多个海域，但此配置未加入完整受管理接续，也没有显式独立运行计划。'
            }
        }
    }

    $allControllerGuids = @($records | ForEach-Object { $_.Controllers } | ForEach-Object { [string]$_['Guid'] })
    $managedRecords = @($records | Where-Object { $null -ne $_.Metadata })
    foreach ($record in @($records)) {
        if (-not $record.Candidate -and -not $record.Managed -and
            @($independent.Keys | Where-Object { $_.EndsWith('|' + $record.Name, [StringComparison]::Ordinal) }).Count -eq 0) { continue }
        foreach ($workflow in $record.List) {
            if ((& $isType $workflow 'SimpleRaiseUserEventWorkflow') -and [string]$workflow['Message'] -match '(?:^|\s)Clear\s*$' -and
                -not (Test-KcpsCanonicalSortieCompletionNotice -Workflow $workflow)) {
                & $add 'UnguardedClearNotice' $record.Name $null $null 'Clear 通知必须是完整核验的 v2 独立通知；名称、标记或 Independent 例外都不能代替成功判定。'
            }
            $workflowScript = [string]$workflow['Script']
            if ($workflowScript -cmatch '\bClear\b' -and $workflowScript -match '\b(?:RaiseEvent|UserEvent)\b' -and
                -not (Test-KcpsCanonicalSortieChainScript -Script $workflowScript)) {
                & $add 'UnverifiedClearScript' $record.Name $null $null '多海域配置包含无法核验成功门控或监听关系的 Clear 事件脚本；独立计划不能豁免事件脚本验证。'
            }
        }
        if ($null -eq $record.Metadata) { continue }
        $m = $record.Metadata; $rel = $record.Controllers[0]; $sortie = $record.Sorties[0]
        if ([string]$rel['Guid'] -ne [string]$m['ControllerGuid']) {
            & $add 'ControllerBinding' $record.Name $m['QuestId'] $m['ChainId'] '总控结果源 GUID 与元数据不一致。'
        }
        if ($null -ne $record.Notice) {
            $notice=$record.Notice; $noticeMetadata=$record.NoticeMetadata
            $sourceBinding=[ordered]@{}; $noticeBinding=[ordered]@{}
            foreach($key in $m.Keys) { if($key -cne 'Role') { $sourceBinding[$key]=$m[$key] } }
            foreach($key in $noticeMetadata.Keys) { if($key -cne 'Role') { $noticeBinding[$key]=$noticeMetadata[$key] } }
            if ((ConvertTo-Json -InputObject $sourceBinding -Depth 12 -Compress) -cne
                (ConvertTo-Json -InputObject $noticeBinding -Depth 12 -Compress) -or
                [string]$notice['Guid'] -ne [string]$m['NoticeGuid']) {
                & $add 'NoticeBinding' $record.Name $m['QuestId'] $m['ChainId'] '总控和通知必须在同组互相绑定，并共享完全相同的任务、阶段、目标、内部结果消息及 GUID。'
            }
            if ([string]$notice['Name'] -cne '出击完成' -or @($record.List | Where-Object { [string]$_['Name'] -ceq '出击完成' }).Count -ne 1) {
                & $add 'NoticeName' $record.Name $m['QuestId'] $m['ChainId'] '阶段必须恰有一个名为出击完成的独立通知。'
            }
            if ([string]$notice['Message'] -cne [string]$m['CompletionMessage']) {
                & $add 'NoticeMessage' $record.Name $m['QuestId'] $m['ChainId'] '通知的原生 Message 必须等于本阶段完成消息。'
            }
            if ($notice['EnableOnLoad'] -isnot [bool] -or -not $notice['EnableOnLoad'] -or
                $notice['EnableScript'] -isnot [bool] -or -not $notice['EnableScript'] -or
                $notice['TriggerOnEnabled'] -isnot [bool] -or $notice['TriggerOnEnabled']) {
                & $add 'NoticeFlags' $record.Name $m['QuestId'] $m['ChainId'] '出击完成必须加载时启用脚本监听，同时关闭开即触发。'
            }
        }
        if ([string]$m['Mode'] -cne 'Sequential' -or [string]$m['GroupName'] -cne $record.Name -or
            [int]$m['Map']['Sea'] -ne [int]$sortie['Sea'] -or [int]$m['Map']['Area'] -ne [int]$sortie['Area']) {
            & $add 'StageScope' $record.Name $m['QuestId'] $m['ChainId'] '接续阶段的模式、精确组名或海域与实际出击不一致。'
        }
        if (($null -ne $m['QuestId'] -and [long]$m['QuestId'] -notin $record.TaskIds) -or
            ($null -eq $m['QuestId'] -and $record.TaskIds.Count -gt 0)) {
            & $add 'StageQuest' $record.Name $m['QuestId'] $m['ChainId'] '接续任务 ID 必须命中配置中的精确任务选择器；不能漏填或按标题推断。'
        }
        if ($rel['EnableOnLoad'] -isnot [bool] -or -not $rel['EnableOnLoad'] -or
            $rel['EnableScript'] -isnot [bool] -or -not $rel['EnableScript'] -or
            $rel['TriggerOnEnabled'] -isnot [bool] -or $rel['TriggerOnEnabled']) {
            & $add 'ListenerFlags' $record.Name $m['QuestId'] $m['ChainId'] '接续总控必须启用加载监听和脚本，同时关闭开即触发。'
        }
        if (-not $rel.Contains('ReturnRoomAtLast') -or [bool]$rel['ReturnRoomAtLast']) {
            & $add 'ReturnRoomRace' $record.Name $m['QuestId'] $m['ChainId'] '接续总控必须显式设置 ReturnRoomAtLast=false，避免发送完成消息后再争抢下一阶段界面。'
        }
        $waitForMorale = ($rel['SleepUntilMoraleRecoveredFlag'] -is [bool] -and $rel['SleepUntilMoraleRecoveredFlag']) -or
            ($rel['SleepUntilFlagShipMoraleRecoveredFlag'] -is [bool] -and $rel['SleepUntilFlagShipMoraleRecoveredFlag'])
        if ($waitForMorale -and ($rel['DoNotSleepAtFirstLoop'] -isnot [bool] -or $rel['DoNotSleepAtFirstLoop'])) {
            & $add 'FirstLoopMoraleWait' $record.Name $m['QuestId'] $m['ChainId'] '接续总控已启用士气恢复等待，必须显式设置 DoNotSleepAtFirstLoop=false；原生默认首轮跳过等待会使新阶段直接进入出击检查。'
        }
        if ([string]$m['Condition']['Type'] -cne 'BossRank' -or
            -not [bool]$rel['StopIfBossBattleRankHigherOrEqualThanFlag'] -or
            [int]$rel['StopIfBossBattleRankHigherOrEqualThanValueRank'] -ne (Get-KcpsSortieChainRankValue -Rank $m['Condition']['Rank']) -or
            [int]$rel['StopIfBossBattleRankHigherOrEqualThanValueThreshold'] -ne [int]$m['Condition']['Count']) {
            & $add 'CompletionCondition' $record.Name $m['QuestId'] $m['ChainId'] '通知声明的成功目标必须与总控原生 Boss 胜利等级及次数完全一致；成功判定由通知执行。'
        }
        if (@($rel['AutoStoppedTriggerWorkflows'] | Where-Object { Test-KcpsSortieChainReferenceEnabled -Reference $_ }).Count -gt 0 -or
            @($rel['AutoStoppedEnableWorkflows'] | Where-Object { Test-KcpsSortieChainReferenceEnabled -Reference $_ }).Count -gt 0) {
            & $add 'UnsafeStopCallbacks' $record.Name $m['QuestId'] $m['ChainId'] '受管理接续不得在自动停止后另外触发或启用工作流。'
        }
        foreach ($reference in @($rel['AutoStoppedDisableWorkflows'])) {
            if ((Test-KcpsSortieChainReferenceEnabled -Reference $reference) -and [string]$reference['Guid'] -in $allControllerGuids) {
                & $add 'DisabledChainController' $record.Name $m['QuestId'] $m['ChainId'] '自动停止后的安全关闭列表不得关闭本链或其他接续总控。'
            }
        }
        $expectedMessage = "$($m['ChainId']) $($m['Stage']) Clear"
        if ([string]$m['CompletionMessage'] -cne $expectedMessage) {
            & $add 'CompletionMessage' $record.Name $m['QuestId'] $m['ChainId'] '完成消息必须由本链 ID 和阶段精确构成。'
        }
    }

    # Native relationships call/enable/disable workflows directly and can bypass a notice's OnEvent gate.
    $protectedGuids = @($managedRecords | ForEach-Object {
        [string]$_.Metadata['ControllerGuid']; [string]$_.Metadata['NoticeGuid']
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    foreach ($record in $records) {
        foreach ($reference in @(Get-KcpsSortieChainProtectedReferences -Node $record.Group -ProtectedGuids $protectedGuids)) {
            & $add 'NativeChainReference' $record.Name $null $null "原生关联 $($reference.Path) 直接操作了受管理总控或出击完成；必须由已核验事件监听接续，不能强制触发、启用或关闭。"
        }
    }

    foreach ($duplicate in @($managedRecords | Group-Object { [string]$_.Metadata['CompletionMessage'] } | Where-Object Count -gt 1)) {
        & $add 'DuplicateMessage' $null $null $null "多个阶段发送相同完成消息，无法唯一接续：$($duplicate.Name)"
    }
    foreach ($duplicate in @($managedRecords | Group-Object { [string]$_.Metadata['ResultMessagePrefix'] } | Where-Object Count -gt 1)) {
        & $add 'DuplicateResultMessage' $null $null $null '多个阶段复用了同一个内部结果消息标识，结果源与通知不能唯一配对。'
    }
    foreach ($task in @($managedRecords | Where-Object { $null -ne $_.Metadata['QuestId'] } | Group-Object { [string]$_.Metadata['QuestId'] })) {
        $taskChains = @($task.Group | ForEach-Object { [string]$_.Metadata['ChainId'] } | Sort-Object -Unique)
        if ($taskChains.Count -gt 1) {
            & $add 'DisconnectedTaskChains' $null $task.Name $null '同一主任务被拆成多条互不相连的接续；同文件顺序完成方案必须由一条完整链覆盖。'
        }
    }
    foreach ($chain in @($managedRecords | Group-Object { [string]$_.Metadata['ChainId'] })) {
        $stages = @($chain.Group | Sort-Object { [int]$_.Metadata['StageIndex'] })
        $counts = @($stages | ForEach-Object { [int]$_.Metadata['StageCount'] } | Sort-Object -Unique)
        $questKeys = @($stages | ForEach-Object { if ($null -eq $_.Metadata['QuestId']) { '<none>' } else { [string]$_.Metadata['QuestId'] } } | Sort-Object -Unique)
        if ($counts.Count -ne 1 -or $counts[0] -ne $stages.Count -or $questKeys.Count -ne 1) {
            & $add 'IncompleteChain' $null $null $chain.Name '同文件接续必须包含声明的全部阶段，并保持阶段总数及任务 ID 一致；跨文件阶段不能冒充完整链。'
        }
        $labels = @{}
        for ($index=0; $index -lt $stages.Count; $index++) {
            $stage = $stages[$index]; $m = $stage.Metadata
            if ([int]$m['StageIndex'] -ne $index -or $labels.ContainsKey([string]$m['Stage'])) {
                & $add 'StageOrder' $stage.Name $m['QuestId'] $chain.Name '阶段索引必须从零连续且不重复，阶段标识也必须唯一。'
            }
            $labels[[string]$m['Stage']] = $true
            $expectedListen = if ($index -eq 0) { $null } else { [string]$stages[$index-1].Metadata['CompletionMessage'] }
            if (($index -eq 0 -and $null -ne $m['ListenMessage']) -or
                ($index -gt 0 -and [string]$m['ListenMessage'] -cne $expectedListen)) {
                & $add 'ListenerTopology' $stage.Name $m['QuestId'] $chain.Name '首阶段不得监听前驱；其余阶段只能监听紧邻前一阶段的唯一完成消息，禁止孤立、分叉或循环。'
            }
        }
        $chains.Add([pscustomobject]@{ChainId=$chain.Name;StageCount=$stages.Count;Groups=@($stages | ForEach-Object Name)})
    }
    [pscustomobject]@{
        ProblemCount=$problems.Count; Problems=@($problems.ToArray()); Chains=@($chains.ToArray())
        IndependentGroupCount=$independent.Count
        Scope='同文件通常海域 v2 Sequential 接续及独立完成通知；精确任务 ID 的多图缺链检测；显式 Independent 只豁免缺链。'
    }
}
