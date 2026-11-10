#requires -Version 7.0
# All stages, tasks and messages in this file are synthetic. No settings, game API or user configurations are read.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'KCPS-SortieChainValidation.ps1')
$checks = 0
function Assert-Chain([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw "Failed: $Label" }
    $script:checks++
}
function New-SyntheticChain {
    param([string]$ChainId='synthetic', [int]$QuestId=900001, [int]$StageCount=3)
    for ($i=0; $i -lt $StageCount; $i++) {
        $controllerGuid=[guid]::NewGuid().ToString(); $noticeGuid=[guid]::NewGuid().ToString()
        $metadata = [ordered]@{
            Version=2; Role='Controller'; Mode='Sequential'; QuestId=$QuestId; ChainId=$ChainId
            GroupName="合成阶段$i"; Stage="stage$i"; StageIndex=$i; StageCount=$StageCount
            Map=@{Sea=1;Area=$i+1};Condition=@{Type='BossRank';Rank='A';Count=1}
            ListenMessage=$(if($i -eq 0){$null}else{"$ChainId stage$($i-1) Clear"})
            CompletionMessage="$ChainId stage$i Clear"
            ControllerGuid=$controllerGuid;NoticeGuid=$noticeGuid
            ResultMessagePrefix="KCPS-SORTIE-RESULT/v2/$controllerGuid/${noticeGuid}:"
        }
        $noticeMetadata=[ordered]@{};foreach($key in $metadata.Keys){$noticeMetadata[$key]=$metadata[$key]};$noticeMetadata.Role='Notice'
        @{
            Name="合成阶段$i";List=@(
                @{Type='KancollePlayerSimulatorKai.RelationalSortieWorkflow, KancollePlayerSimulatorKai';Name='总控';Guid=$controllerGuid
                    EnableOnLoad=$true;EnableScript=$true;TriggerOnEnabled=$false;ReturnRoomAtLast=$false
                    StopIfBossBattleRankHigherOrEqualThanFlag=$true;StopIfBossBattleRankHigherOrEqualThanValueRank=3
                    StopIfBossBattleRankHigherOrEqualThanValueThreshold=1;Script=(New-KcpsSortieChainScript $metadata)
                    AutoStoppedTriggerWorkflows=@();AutoStoppedEnableWorkflows=@();AutoStoppedDisableWorkflows=@()}
                @{Type='KancollePlayerSimulatorKai.SimpleSortieWorkflow, KancollePlayerSimulatorKai';Name='出击';Guid="synthetic-sortie-$i";Sea=1;Area=$i+1;Script=$null}
                @{Type='KancollePlayerSimulatorKai.BasicAcceptQuestWorkflow, KancollePlayerSimulatorKai';Name='接任务';Guid="synthetic-quest-$i";Script=$null
                    Quests=@(@{SelectMethod=0;SelectValue=$QuestId})}
                @{Type='KancollePlayerSimulatorKai.SimpleRaiseUserEventWorkflow, KancollePlayerSimulatorKai';Name='出击完成';Guid=$noticeGuid
                    Message=$metadata.CompletionMessage;EnableOnLoad=$true;EnableScript=$true;TriggerOnEnabled=$false
                    Script=(New-KcpsSortieChainScript $noticeMetadata)}
            )
        }
    }
}
function Assert-Code($Groups, [string]$Code, [string]$Label, $Policy=$null) {
    $result = Get-KcpsSortieChainValidation -Groups $Groups -PolicyDocument $Policy
    Assert-Chain (@($result.Problems | Where-Object Code -eq $Code).Count -gt 0) $Label
}
function Update-Metadata($Group, [scriptblock]$Change) {
    $metadata=Get-KcpsSortieChainMetadata $Group.List[0].Script
    & $Change $metadata
    $Group.List[0].Script=New-KcpsSortieChainScript $metadata
    $noticeMetadata=[ordered]@{};foreach($key in $metadata.Keys){$noticeMetadata[$key]=$metadata[$key]};$noticeMetadata.Role='Notice'
    $Group.List[3].Script=New-KcpsSortieChainScript $noticeMetadata
    $Group.List[3].Message=$metadata.CompletionMessage
}
function Remove-SyntheticChain($Group) {
    $Group.List[0].Script=$null
    $Group.List=@($Group.List | Where-Object { $_.Name -ne '出击完成' })
}
$valid=@(New-SyntheticChain)
$result=Get-KcpsSortieChainValidation $valid
Assert-Chain ($result.ProblemCount -eq 0 -and $result.Chains.Count -eq 1) 'complete three-stage chain passes'
Assert-Chain (Test-KcpsCanonicalSortieChainScript ($valid[1].List[0].Script.Replace("`n","`r`n"))) 'CRLF normalization preserves exact script'

$groups=@(New-SyntheticChain);foreach($g in $groups){Remove-SyntheticChain $g}
Assert-Code $groups 'MissingChain' 'entire absent chain is detected by exact quest ID'
$groups=@(New-SyntheticChain -StageCount 5);foreach($g in $groups){Remove-SyntheticChain $g}
Assert-Chain ((Get-KcpsSortieChainValidation $groups).ProblemCount -eq 5) 'all five stages without any chain fail validation'
$groups=@(New-SyntheticChain);$groups[1].List[0].Script=$null
Assert-Code $groups 'MissingManagedController' 'isolated stage without a source script is detected'
Assert-Code @($valid[0],$valid[2]) 'IncompleteChain' 'missing intermediate stage is rejected'
Assert-Code @($valid[1]) 'IncompleteChain' 'cross-file fragment cannot claim complete validation'
$groups=@(New-SyntheticChain);Update-Metadata $groups[2] {param($m)$m.ListenMessage='synthetic stage0 Clear'}
Assert-Code $groups 'ListenerTopology' 'forked listener is rejected'
$groups=@(New-SyntheticChain);Update-Metadata $groups[1] {param($m)$m.ListenMessage='synthetic stage2 Clear'}
Assert-Code $groups 'ListenerTopology' 'cycle is rejected'
$groups=@(New-SyntheticChain);Update-Metadata $groups[2] {param($m)$m.ListenMessage='synthetic missing Clear'}
Assert-Code $groups 'ListenerTopology' 'orphan listener is rejected'
$groups=@(New-SyntheticChain);Update-Metadata $groups[2] {param($m)$m.Stage='stage0';$m.CompletionMessage='synthetic stage0 Clear'}
Assert-Code $groups 'DuplicateMessage' 'duplicate completion message is rejected'
$groups=@(New-SyntheticChain);Update-Metadata $groups[2] {param($m)$m.StageIndex=1}
Assert-Code $groups 'StageOrder' 'duplicate stage index is rejected'
$first=@(New-SyntheticChain -ChainId 'synthetic-a' -StageCount 2)
$second=@(New-SyntheticChain -ChainId 'synthetic-b' -StageCount 2)
foreach($g in $second){$g.Name='另一方案'+$g.Name;Update-Metadata $g {param($m)$m.GroupName='另一方案'+$m.GroupName}}
Assert-Chain ((Get-KcpsSortieChainValidation $first).ProblemCount -eq 0 -and (Get-KcpsSortieChainValidation $second).ProblemCount -eq 0) 'split-chain fixture has two individually valid chains'
$groups=$first+$second
Assert-Code $groups 'DisconnectedTaskChains' 'two internally complete chains cannot silently split one primary quest'
$groups=@(New-SyntheticChain);Update-Metadata $groups[1] {param($m)$m.Map.Area=7}
Assert-Code $groups 'StageScope' 'wrong map metadata is rejected'
$groups=@(New-SyntheticChain);Update-Metadata $groups[1] {param($m)$m.QuestId=900002}
Assert-Code $groups 'StageQuest' 'metadata task must match exact selector'
foreach($field in @('EnableOnLoad','EnableScript')) {
    $groups=@(New-SyntheticChain);$groups[1].List[0][$field]=$false
    Assert-Code $groups 'ListenerFlags' "disabled $field listener is rejected"
}
$groups=@(New-SyntheticChain);$groups[1].List[0].TriggerOnEnabled=$true
Assert-Code $groups 'ListenerFlags' 'start-on-enable is rejected'
$groups=@(New-SyntheticChain);$groups[1].List[0].ReturnRoomAtLast=$true
Assert-Code $groups 'ReturnRoomRace' 'post-message return-room race is rejected'
foreach ($waitFlags in @(
    @('SleepUntilMoraleRecoveredFlag'),
    @('SleepUntilFlagShipMoraleRecoveredFlag'),
    @('SleepUntilMoraleRecoveredFlag', 'SleepUntilFlagShipMoraleRecoveredFlag')
)) {
    $groups=@(New-SyntheticChain)
    foreach ($flag in $waitFlags) { $groups[1].List[0][$flag]=$true }
    $groups[1].List[0].DoNotSleepAtFirstLoop=$true
    Assert-Code $groups 'FirstLoopMoraleWait' "first-loop skip bypasses $($waitFlags -join ',')"
    $groups[1].List[0].Remove('DoNotSleepAtFirstLoop')
    Assert-Code $groups 'FirstLoopMoraleWait' 'omitted first-loop flag retains the unsafe native true default'
    $groups[1].List[0].DoNotSleepAtFirstLoop=$false
    Assert-Chain ((Get-KcpsSortieChainValidation $groups).ProblemCount -eq 0) 'explicit first-loop waiting preserves configured morale recovery'
}
foreach ($skipFirstLoop in @($true, $false, $null)) {
    $groups=@(New-SyntheticChain)
    $groups[1].List[0].SleepUntilMoraleRecoveredFlag=$false
    $groups[1].List[0].SleepUntilFlagShipMoraleRecoveredFlag=$false
    if ($null -ne $skipFirstLoop) { $groups[1].List[0].DoNotSleepAtFirstLoop=$skipFirstLoop }
    Assert-Chain ((Get-KcpsSortieChainValidation $groups).ProblemCount -eq 0) 'chains without morale waiting keep their existing first-loop policy'
}
$groups=@(New-SyntheticChain);$groups[1].List[0].StopIfBossBattleRankHigherOrEqualThanValueThreshold=2
Assert-Code $groups 'CompletionCondition' 'native success threshold mismatch is rejected'
$groups=@(New-SyntheticChain);$groups[1].List[0].Script += "`nUtility.RaiseEvent(UserEvent('synthetic bypass Clear'))`n"
Assert-Code $groups 'ManagedScriptMismatch' 'valid marker does not permit appended unsafe code'
Assert-Chain (-not (Test-KcpsCanonicalSortieChainScript $groups[1].List[0].Script)) 'damaged managed code gets no template-marker exception'
$groups=@(New-SyntheticChain);$groups[1].List[0].Script=$groups[1].List[0].Script.Replace('def OnAutoStopped():', 'def OnAutoStoppedChanged():')
Assert-Code $groups 'ManagedScriptMismatch' 'changed source lifecycle callback is rejected'
$groups=@(New-SyntheticChain);$groups[1].List[0].Script='# KCPS Sortie Chain v1'
Assert-Code $groups 'ManagedMetadata' 'marker without metadata is rejected safely'
$groups=@(New-SyntheticChain);$groups[1].List[0].AutoStoppedTriggerWorkflows=@(@{Guid='synthetic-notice';Enabled=$true})
Assert-Code $groups 'UnsafeStopCallbacks' 'additional post-stop trigger is rejected'
$groups=@(New-SyntheticChain);$groups[1].List[0].AutoStoppedEnableWorkflows=@(@{Guid='synthetic-notice'})
Assert-Code $groups 'UnsafeStopCallbacks' 'omitted enabled flag keeps native active default'
$groups=@(New-SyntheticChain);$groups[1].List[0].AutoStoppedDisableWorkflows=@(@{Guid=$groups[2].List[0].Guid;Enabled=$true})
Assert-Code $groups 'DisabledChainController' 'disabling another listener is rejected'
$groups=@(New-SyntheticChain);$groups[1].List[0].AutoStoppedDisableWorkflows=@(@{Guid=$groups[1].List[0].Guid})
Assert-Code $groups 'DisabledChainController' 'omitted enabled flag cannot hide self-disable'
$groups=@(New-SyntheticChain);$groups[1].List[0].AutoStoppedDisableWorkflows=@(@{Guid='synthetic-docking';Enabled=$true})
Assert-Chain ((Get-KcpsSortieChainValidation $groups).ProblemCount -eq 0) 'safe post-stop docking disable remains compatible'
$groups=@(New-SyntheticChain);$groups[1].List[0].AutoStoppedTriggerWorkflows=@(@{Guid='synthetic-disabled';Enabled=$false})
Assert-Chain ((Get-KcpsSortieChainValidation $groups).ProblemCount -eq 0) 'disabled stop callback placeholders remain compatible'

$groups=@(New-SyntheticChain);foreach($g in $groups){Remove-SyntheticChain $g}
$policy=@{Version=1;Policies=@(@{QuestId=900001;Mode='Independent';Groups=@('合成阶段0','合成阶段1','合成阶段2');Reason='合成独立运行计划'})}
Assert-Chain ((Get-KcpsSortieChainValidation $groups $policy).ProblemCount -eq 0) 'explicit exact independent plan covers missing chain'
$groups[0].List+=@{Type='KancollePlayerSimulatorKai.SimpleRaiseUserEventWorkflow, KancollePlayerSimulatorKai';Name='任意名称';Message='synthetic stage0 Clear';Script=$null}
Assert-Code $groups 'UnguardedClearNotice' 'independent plan cannot bypass unconditional native clear' $policy
$groups=@(New-SyntheticChain);foreach($g in $groups){Remove-SyntheticChain $g}
$groups[0].List[0].Script="def OnAutoStopped():`n    Utility.RaiseEvent(UserEvent('synthetic unsafe Clear'))`n"
Assert-Code $groups 'UnverifiedClearScript' 'independent plan cannot bypass an unmanaged inline clear emitter' $policy
$groups=@(New-SyntheticChain)
Assert-Code $groups 'PolicyManagedConflict' 'independent plan cannot waive an existing chain' $policy
$groups=@(New-SyntheticChain);foreach($g in $groups){Remove-SyntheticChain $g}
foreach($mutation in @('UnknownGroup','DuplicateGroup','WrongQuest','UnknownKey','External','EmptyReason','WrongVersion')) {
    $bad=$policy | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
    switch($mutation) {
        UnknownGroup {$bad.Policies[0].Groups=@('不存在的合成组');$code='PolicyGroupScope'}
        DuplicateGroup {$bad.Policies[0].Groups=@('合成阶段0','合成阶段0');$code='PolicyGroupDuplicate'}
        WrongQuest {$bad.Policies[0].QuestId=900002;$code='PolicyGroupScope'}
        UnknownKey {$bad.Policies[0].Skip=$true;$code='PolicyShape'}
        External {$bad.Policies[0].Mode='External';$code='PolicyModeUnsupported'}
        EmptyReason {$bad.Policies[0].Reason='';$code='PolicyShape'}
        WrongVersion {$bad.Version='1';$code='PolicyShape'}
    }
    Assert-Code $groups $code "malformed independent policy: $mutation" $bad
}
$groups=@(New-SyntheticChain);foreach($g in $groups){Remove-SyntheticChain $g;$g.List[1].Area=1}
Assert-Chain ((Get-KcpsSortieChainValidation $groups).ProblemCount -eq 0) 'same-map alternatives do not imply a multi-map chain'
$groups=@(New-SyntheticChain);foreach($g in $groups){Remove-SyntheticChain $g;$g.List[1].Sea=0}
Assert-Chain ((Get-KcpsSortieChainValidation $groups).ProblemCount -eq 0) 'legacy event branches remain outside ordinary chain inference'
$single=@((New-SyntheticChain)[0]);Remove-SyntheticChain $single[0]
Assert-Chain ((Get-KcpsSortieChainValidation $single).ProblemCount -eq 0) 'unmanaged single-map sortie remains compatible'
$exercise=@{Name='合成演习';List=@(@{Type='KancollePlayerSimulatorKai.SimpleExerciseWorkflow, KancollePlayerSimulatorKai';Script=$null})}
Assert-Chain ((Get-KcpsSortieChainValidation @($exercise)).ProblemCount -eq 0) 'exercise workflow remains outside sortie scope'
$groups=@(New-SyntheticChain);foreach($g in $groups){$g.Name='不含任务海域的任意'+$g.Name;Remove-SyntheticChain $g}
Assert-Code $groups 'MissingChain' 'task grouping does not depend on display names'
$groups=@(New-SyntheticChain);foreach($g in $groups){Remove-SyntheticChain $g;$g.List[1].Sea=91}
Assert-Code $groups 'MissingChain' 'positive future ordinary sea values cannot bypass chain checking'
$groups=@(New-SyntheticChain);$groups[0].List[1].Sea='invalid'
Assert-Code $groups 'SortieMapShape' 'invalid sea produces a structured problem'

$groups=@(New-SyntheticChain)
Assert-Chain (Test-KcpsCanonicalSortieCompletionNotice $groups[0].List[3]) 'canonical native notice is accepted only with complete v2 script'
$groups[0].List=@($groups[0].List | Where-Object Name -ne '出击完成')
Assert-Code $groups 'MissingCompletionNotice' 'missing standalone completion notice is rejected'
foreach($field in @('EnableOnLoad','EnableScript')) {
    $groups=@(New-SyntheticChain);$groups[1].List[3][$field]=$false
    Assert-Code $groups 'NoticeFlags' "disabled notice $field is rejected"
}
$groups=@(New-SyntheticChain);$groups[1].List[3].TriggerOnEnabled=$true
Assert-Code $groups 'NoticeFlags' 'notice cannot start immediately on enable'
$groups=@(New-SyntheticChain);$groups[1].List[3].Message='synthetic wrong Clear'
Assert-Code $groups 'NoticeMessage' 'native message must match the bound stage'
$groups=@(New-SyntheticChain);$groups[1].List[3].Name='出击完成的近似名称'
Assert-Code $groups 'NoticeName' 'name prefix is not an exemption'
$groups=@(New-SyntheticChain);$groups[1].List[3].Guid=[guid]::NewGuid().ToString()
Assert-Code $groups 'NoticeBinding' 'notice GUID must match source binding'
$groups=@(New-SyntheticChain);$groups[1].List[0].Guid=[guid]::NewGuid().ToString()
Assert-Code $groups 'ControllerBinding' 'controller GUID must match raw-result source'
$groups=@(New-SyntheticChain);$noticeMeta=Get-KcpsSortieChainMetadata $groups[1].List[3].Script
$noticeMeta.Condition.Count=2;$groups[1].List[3].Script=New-KcpsSortieChainScript $noticeMeta
Assert-Code $groups 'NoticeBinding' 'notice cannot silently use a different success target'
$groups=@(New-SyntheticChain);$groups[1].List[3].Script += "`n# modified notification gate`n"
Assert-Code $groups 'ManagedScriptMismatch' 'notice script is checked in full, not by marker'
Assert-Chain (-not (Test-KcpsCanonicalSortieCompletionNotice $groups[1].List[3])) 'modified notice receives no native-clear exemption'
$groups=@(New-SyntheticChain)
$groups[1].List[3].Script=$groups[1].List[3].Script.Replace('KCPS-SORTIE-RESULT/v2/', 'incorrect-result-prefix/')
Assert-Code $groups 'ManagedScriptMismatch' 'changed internal result message is rejected'
$groups=@(New-SyntheticChain)
Assert-Chain ($groups[1].List[3].Script.Contains('_kcps_notice_seen.add(run_id)')) 'deduplication test targets the generated gate'
$groups[1].List[3].Script=$groups[1].List[3].Script.Replace('_kcps_notice_seen.add(run_id)', '# removed run identity check')
Assert-Code $groups 'ManagedScriptMismatch' 'removed RunId deduplication is rejected'
$groups=@(New-SyntheticChain);$groups[1].List[3].EnableScript='false'
Assert-Code $groups 'NoticeFlags' 'string flag cannot masquerade as enabled notification'
$groups=@(New-SyntheticChain);$groups[1].List+=($groups[1].List[3]|ConvertTo-Json -Depth 10|ConvertFrom-Json -AsHashtable)
Assert-Code $groups 'MissingCompletionNotice' 'duplicate standalone notices cannot pass as a unique notifier'
foreach($key in @('BeforeLoopsTriggerWorkflows','BeforeLoopsEnableWorkflows','SubroutineBeforeWorkflows','Workflows','AutoStoppedDisableWorkflows')) {
    $groups=@(New-SyntheticChain)
    $caller=@{Type='KancollePlayerSimulatorKai.SeriesWorkflow, KancollePlayerSimulatorKai';Name='合成原生调用';Guid=[guid]::NewGuid().ToString();Script=$null}
    $caller[$key]=@(@{Guid=$groups[1].List[3].Guid})
    $groups[0].List+= $caller
    Assert-Code $groups 'NativeChainReference' "native $key cannot bypass independent notice listener"
}
$groups=@(New-SyntheticChain)
$groups[0].List[0].SubroutineBeforeWorkflows=@(@{Guid=$groups[1].List[0].Guid;Enabled=$true})
Assert-Code $groups 'NativeChainReference' 'native direct controller start is also rejected'
$groups=@(New-SyntheticChain)
$groups[0].List[0].SubroutineBeforeWorkflows=@(@{Guid=$groups[1].List[3].Guid;Enabled=$false})
Assert-Chain ((Get-KcpsSortieChainValidation $groups).ProblemCount -eq 0) 'explicitly disabled native reference remains inert'

# Construct the supported legacy format, then migrate only its metadata/model into v2.
$groups=@(New-SyntheticChain)
foreach($g in $groups) {
    $old=Get-KcpsSortieChainMetadata $g.List[0].Script
    $legacy=[ordered]@{};foreach($key in $old.Keys){if($key -notin @('Role','ControllerGuid','NoticeGuid','ResultMessagePrefix')){$legacy[$key]=$old[$key]}}
    $legacy.Version=1;$g.List[0].Script=New-KcpsSortieChainScript $legacy
    $g.List=@($g.List | Where-Object Name -ne '出击完成')
}
Assert-Code $groups 'LegacyChainNeedsUpgrade' 'v1 is recognized as migratable but cannot pass as v2'
Assert-Chain (-not (Test-KcpsCanonicalSortieChainScript $groups[0].List[0].Script)) 'v1 gets no current canonical exemption'
foreach($g in $groups) {
    $old=Get-KcpsSortieChainMetadata $g.List[0].Script
    $meta=[ordered]@{};foreach($key in $old.Keys){$meta[$key]=$old[$key]}
    $meta.Version=2;$meta.Role='Controller';$meta.ControllerGuid=$g.List[0].Guid;$meta.NoticeGuid=[guid]::NewGuid().ToString()
    $meta.ResultMessagePrefix="KCPS-SORTIE-RESULT/v2/$($meta.ControllerGuid)/$($meta.NoticeGuid):"
    $g.List[0].Script=New-KcpsSortieChainScript $meta
    $meta.Role='Notice'
    $g.List+=@{Type='KancollePlayerSimulatorKai.SimpleRaiseUserEventWorkflow, KancollePlayerSimulatorKai';Name='出击完成';Guid=$meta.NoticeGuid
        Message=$meta.CompletionMessage;EnableOnLoad=$true;EnableScript=$true;TriggerOnEnabled=$false;Script=(New-KcpsSortieChainScript $meta)}
}
Assert-Chain ((Get-KcpsSortieChainValidation $groups).ProblemCount -eq 0) 'migrated v2 source/notice pairs form the same complete chain'
Write-Output "Passed $checks synthetic sortie-chain validation checks."
