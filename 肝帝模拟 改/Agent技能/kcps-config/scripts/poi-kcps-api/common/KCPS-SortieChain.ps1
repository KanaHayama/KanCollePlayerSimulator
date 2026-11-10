#requires -Version 7.0
# 完成消息只依据当前运行的原生 Boss 评级计数，自动停止本身不是完成证据。

function Assert-KcpsChainKeys {
    param($Value, [string[]]$Keys, [string]$Label)
    if ($Value -isnot [System.Collections.IDictionary]) { throw "$Label 必须是对象。" }
    foreach ($key in $Keys) { if (-not $Value.Contains($key)) { throw "$Label 缺少 $key。" } }
    foreach ($key in $Value.Keys) { if ($key -cnotin $Keys) { throw "$Label 含未知字段 $key。" } }
}

function Assert-KcpsChainInteger {
    param($Value, [long]$Minimum, [long]$Maximum, [string]$Label)
    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt $Minimum -or $Value -gt $Maximum) {
        throw "$Label 必须是 $Minimum 至 $Maximum 的整数。"
    }
}

function Assert-KcpsChainText {
    param($Value, [string]$Label)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value -ne $Value.Trim() -or $Value -match '[\r\n\x00]') {
        throw "$Label 必须是无首尾空白的非空单行字符串。"
    }
}

function Get-KcpsSortieChainRankValue {
    param([string]$Rank)
    $values = @{ SS = 1; S = 2; A = 3; B = 4; C = 5; D = 6; E = 7 }
    if ($Rank -cnotin @('SS', 'S', 'A', 'B', 'C', 'D', 'E')) { throw "不支持的 Boss 评级：$Rank。" }
    return $values[$Rank]
}

function Test-KcpsSortieChainReferenceEnabled {
    param($Reference)
    if ($null -eq $Reference) { return $false }
    # 原生关联省略 Enabled 时默认 true；不把坏类型或缺字段当作禁用。
    return ($Reference -isnot [System.Collections.IDictionary] -or -not $Reference.Contains('Enabled') -or
        $Reference['Enabled'] -isnot [bool] -or [bool]$Reference['Enabled'])
}

function ConvertTo-KcpsSortieChainGuid {
    param($Value, [string]$Label)
    $guid = [guid]::Empty
    if ($Value -isnot [string] -or -not [guid]::TryParse($Value, [ref]$guid) -or $guid -eq [guid]::Empty) { throw "$Label 必须是非空 GUID。" }
    return $guid.ToString('D')
}

function Get-KcpsSortieChainResultPrefix {
    param([string]$ControllerGuid, [string]$NoticeGuid)
    $controller = ConvertTo-KcpsSortieChainGuid $ControllerGuid 'ControllerGuid'
    $notice = ConvertTo-KcpsSortieChainGuid $NoticeGuid 'NoticeGuid'
    return "KCPS-SORTIE-RESULT/v2/$controller/${notice}:"
}

function ConvertTo-KcpsSortieChainMetadata {
    param([Parameter(Mandatory)]$Metadata)
    if ($Metadata -isnot [System.Collections.IDictionary]) { throw '接续元数据必须是对象。' }
    Assert-KcpsChainInteger $Metadata['Version'] 1 2 'Version'
    $keys = @('Version', 'Mode', 'QuestId', 'ChainId', 'GroupName', 'Stage', 'StageIndex', 'StageCount', 'Map', 'Condition', 'ListenMessage', 'CompletionMessage')
    if ($Metadata.Version -eq 2) { $keys += @('Role', 'ControllerGuid', 'NoticeGuid', 'ResultMessagePrefix') }
    Assert-KcpsChainKeys $Metadata $keys '接续元数据'
    if ($Metadata.Mode -cne 'Sequential') { throw '本工具仅支持 Sequential 接续。' }
    if ($null -ne $Metadata.QuestId) { Assert-KcpsChainInteger $Metadata.QuestId 1 ([int]::MaxValue) 'QuestId' }
    foreach ($key in @('ChainId', 'GroupName', 'Stage', 'CompletionMessage')) { Assert-KcpsChainText $Metadata[$key] $key }
    Assert-KcpsChainInteger $Metadata.StageCount 2 ([int]::MaxValue) 'StageCount'
    Assert-KcpsChainInteger $Metadata.StageIndex 0 ($Metadata.StageCount - 1) 'StageIndex'
    Assert-KcpsChainKeys $Metadata.Map @('Sea', 'Area') 'Map'
    Assert-KcpsChainInteger $Metadata.Map.Sea 1 ([int]::MaxValue) 'Map.Sea'
    Assert-KcpsChainInteger $Metadata.Map.Area 1 ([int]::MaxValue) 'Map.Area'
    Assert-KcpsChainKeys $Metadata.Condition @('Type', 'Rank', 'Count') 'Condition'
    if ($Metadata.Condition.Type -cne 'BossRank') { throw '本工具仅支持原生 BossRank 次数完成条件。' }
    $null = Get-KcpsSortieChainRankValue $Metadata.Condition.Rank
    Assert-KcpsChainInteger $Metadata.Condition.Count 1 ([int]::MaxValue) 'Condition.Count'
    if ($Metadata.StageIndex -eq 0) {
        if ($null -ne $Metadata.ListenMessage) { throw '首阶段的 ListenMessage 必须为 null。' }
    } else { Assert-KcpsChainText $Metadata.ListenMessage 'ListenMessage' }
    if ($Metadata.CompletionMessage -cne "$($Metadata.ChainId) $($Metadata.Stage) Clear") { throw '完成消息与 ChainId/Stage 不一致。' }
    if ($Metadata.ListenMessage -ceq $Metadata.CompletionMessage) { throw '阶段不能监听自己的完成消息。' }
    $normalized = [ordered]@{
        Version = [int]$Metadata.Version; Mode = 'Sequential'; QuestId = $Metadata.QuestId
        ChainId = $Metadata.ChainId; GroupName = $Metadata.GroupName; Stage = $Metadata.Stage
        StageIndex = [int]$Metadata.StageIndex; StageCount = [int]$Metadata.StageCount
        Map = [ordered]@{ Sea = [int]$Metadata.Map.Sea; Area = [int]$Metadata.Map.Area }
        Condition = [ordered]@{ Type = 'BossRank'; Rank = $Metadata.Condition.Rank; Count = [int]$Metadata.Condition.Count }
        ListenMessage = $Metadata.ListenMessage; CompletionMessage = $Metadata.CompletionMessage
    }
    if ($Metadata.Version -eq 2) {
        if ($Metadata.Role -cnotin @('Controller', 'Notice')) { throw 'Role 必须是 Controller 或 Notice。' }
        $controllerGuid = ConvertTo-KcpsSortieChainGuid $Metadata.ControllerGuid 'ControllerGuid'
        $noticeGuid = ConvertTo-KcpsSortieChainGuid $Metadata.NoticeGuid 'NoticeGuid'
        if ($controllerGuid -eq $noticeGuid) { throw '总控和通知必须是不同执行单元。' }
        $prefix = Get-KcpsSortieChainResultPrefix $controllerGuid $noticeGuid
        if ($Metadata.ResultMessagePrefix -cne $prefix) { throw '内部结果消息前缀与执行单元绑定不一致。' }
        $normalized.Role = $Metadata.Role
        $normalized.ControllerGuid = $controllerGuid
        $normalized.NoticeGuid = $noticeGuid
        $normalized.ResultMessagePrefix = $prefix
    }
    return $normalized
}

function Get-KcpsSortieChainMetadata {
    param([AllowNull()][AllowEmptyString()][string]$Script)
    if ([string]::IsNullOrWhiteSpace($Script) -or -not $Script.StartsWith('# KCPS Sortie Chain ')) { return $null }
    $lines = $Script.Replace("`r`n", "`n").Split("`n")
    $prefix = '# KCPS-SORTIE-CHAIN-METADATA: '
    if ($lines.Count -lt 2 -or -not $lines[1].StartsWith($prefix)) { throw '接续脚本元数据标记损坏。' }
    try {
        $bytes = [Convert]::FromBase64String($lines[1].Substring($prefix.Length))
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $metadata = ConvertFrom-Json -InputObject $json -AsHashtable
    } catch { throw '接续脚本元数据不是有效的 UTF-8 JSON。' }
    $normalized = ConvertTo-KcpsSortieChainMetadata $metadata
    $header = if ($normalized.Version -eq 1) { '# KCPS Sortie Chain v1' } else { "# KCPS Sortie Chain v2 $($normalized.Role)" }
    if ($lines[0] -cne $header) { throw '接续脚本版本或角色标记与元数据不符。' }
    return $normalized
}

function New-KcpsSortieChainLegacyScript {
    param([Parameter(Mandatory)]$Metadata)
    $meta = ConvertTo-KcpsSortieChainMetadata $Metadata
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($meta | ConvertTo-Json -Depth 10 -Compress)))
    $rank = Get-KcpsSortieChainRankValue $meta.Condition.Rank
    $count = $meta.Condition.Count
    $listen = if ($null -eq $meta.ListenMessage) { 'None' } else { 'u' + (ConvertTo-Json -InputObject $meta.ListenMessage -Compress -EscapeHandling EscapeNonAscii) }
    $message = 'u' + (ConvertTo-Json -InputObject $meta.CompletionMessage -Compress -EscapeHandling EscapeNonAscii)
    # 专属受管理脚本，不使用简单事件模板的 Auto Generated 标记。
    return @"
# KCPS Sortie Chain v1
# KCPS-SORTIE-CHAIN-METADATA: $encoded
from KancollePlayerSimulatorKaiCore import UserEvent, Utility

_kcps_chain_listen = $listen
_kcps_chain_message = $message
_kcps_chain_rank = $rank
_kcps_chain_required = $count
_kcps_chain_complete = False
_kcps_chain_start_pending = False

def _kcps_chain_reset():
    global _kcps_chain_complete, _kcps_chain_start_pending
    _kcps_chain_complete = False
    _kcps_chain_start_pending = False

def OnEnabled():
    _kcps_chain_reset()

def OnDisabled():
    _kcps_chain_reset()

def OnProcess():
    if not Workflow.IsRunning:
        _kcps_chain_reset()

def OnEvent(e):
    global _kcps_chain_start_pending
    if not isinstance(e, UserEvent) or _kcps_chain_listen is None:
        return False
    if e.Message != _kcps_chain_listen:
        return False
    if Workflow.IsRunning or Workflow.IsExecuting or _kcps_chain_start_pending:
        return False
    _kcps_chain_start_pending = True
    return True

def OnAutoStop():
    global _kcps_chain_complete
    _kcps_chain_complete = bool(
        Workflow.StopIfBossBattleRankHigherOrEqualThanFlag and
        int(Workflow.StopIfBossBattleRankHigherOrEqualThanValueRank) == _kcps_chain_rank and
        int(Workflow.StopIfBossBattleRankHigherOrEqualThanValueThreshold) == _kcps_chain_required and
        int(Workflow.StopIfBossBattleRankHigherOrEqualThanCount) >= _kcps_chain_required)
    return _kcps_chain_complete

def OnAutoStopped():
    completed = _kcps_chain_complete
    _kcps_chain_reset()
    if completed:
        Utility.RaiseEvent(UserEvent(_kcps_chain_message))
"@.Replace("`r`n", "`n").TrimEnd() + "`n"
}

function New-KcpsSortieChainScript {
    param([Parameter(Mandatory)]$Metadata)
    $meta = ConvertTo-KcpsSortieChainMetadata $Metadata
    if ($meta.Version -eq 1) { return (New-KcpsSortieChainLegacyScript $meta) }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($meta | ConvertTo-Json -Depth 10 -Compress)))
    $prefix = 'u' + (ConvertTo-Json -InputObject $meta.ResultMessagePrefix -Compress -EscapeHandling EscapeNonAscii)
    if ($meta.Role -eq 'Controller') {
        $listen = if ($null -eq $meta.ListenMessage) { 'None' } else { 'u' + (ConvertTo-Json -InputObject $meta.ListenMessage -Compress -EscapeHandling EscapeNonAscii) }
        $script = @"
# KCPS Sortie Chain v2 Controller
# KCPS-SORTIE-CHAIN-METADATA: $encoded
from System import Guid
from KancollePlayerSimulatorKaiCore import UserEvent, Utility

_kcps_chain_listen = $listen
_kcps_chain_result_prefix = $prefix
_kcps_chain_run_id = None
_kcps_chain_snapshot = None
_kcps_chain_start_pending = False

def _kcps_chain_reset():
    global _kcps_chain_run_id, _kcps_chain_snapshot, _kcps_chain_start_pending
    _kcps_chain_run_id = None
    _kcps_chain_snapshot = None
    _kcps_chain_start_pending = False

def OnEnabled():
    _kcps_chain_reset()

def OnDisabled():
    _kcps_chain_reset()

def OnProcess():
    global _kcps_chain_run_id
    if not Workflow.IsRunning:
        _kcps_chain_reset()
        _kcps_chain_run_id = str(Guid.NewGuid().ToString("D"))

def OnEvent(e):
    global _kcps_chain_start_pending
    if not isinstance(e, UserEvent) or _kcps_chain_listen is None:
        return False
    if e.Message != _kcps_chain_listen:
        return False
    if Workflow.IsRunning or Workflow.IsExecuting or _kcps_chain_start_pending:
        return False
    _kcps_chain_start_pending = True
    return True

def OnAutoStop():
    global _kcps_chain_snapshot
    _kcps_chain_snapshot = None
    if _kcps_chain_run_id is not None:
        _kcps_chain_snapshot = _kcps_chain_result_prefix + "1|{0}|{1}|{2}|{3}|{4}".format(
            _kcps_chain_run_id,
            1 if Workflow.StopIfBossBattleRankHigherOrEqualThanFlag else 0,
            int(Workflow.StopIfBossBattleRankHigherOrEqualThanValueRank),
            int(Workflow.StopIfBossBattleRankHigherOrEqualThanValueThreshold),
            int(Workflow.StopIfBossBattleRankHigherOrEqualThanCount))
    return False

def OnAutoStopped():
    snapshot = _kcps_chain_snapshot
    _kcps_chain_reset()
    if snapshot is not None:
        Utility.RaiseEvent(UserEvent(snapshot))
"@
    } else {
        $rank = Get-KcpsSortieChainRankValue $meta.Condition.Rank
        $count = $meta.Condition.Count
        $script = @"
# KCPS Sortie Chain v2 Notice
# KCPS-SORTIE-CHAIN-METADATA: $encoded
from System import Guid
from KancollePlayerSimulatorKaiCore import UserEvent

_kcps_notice_result_prefix = $prefix
_kcps_notice_rank = $rank
_kcps_notice_required = $count
_kcps_notice_seen = set()

def _kcps_notice_integer(text):
    if not text or len(text) > 10:
        return None
    if any(char < "0" or char > "9" for char in text):
        return None
    number = int(text)
    if number > 2147483647 or str(number) != text:
        return None
    return number

def OnEvent(e):
    if not isinstance(e, UserEvent) or Workflow.IsExecuting:
        return False
    message = e.Message
    if message is None or not message.startswith(_kcps_notice_result_prefix):
        return False
    parts = message[len(_kcps_notice_result_prefix):].split("|")
    if len(parts) != 6 or parts[0] != "1" or parts[2] not in ("0", "1"):
        return False
    run_id = parts[1]
    try:
        parsed_id = Guid(run_id)
        if parsed_id == Guid.Empty or str(parsed_id.ToString("D")) != run_id:
            return False
    except:
        return False
    rank = _kcps_notice_integer(parts[3])
    threshold = _kcps_notice_integer(parts[4])
    count = _kcps_notice_integer(parts[5])
    if rank is None or threshold is None or count is None or not 1 <= rank <= 7 or threshold < 1:
        return False
    if run_id in _kcps_notice_seen:
        return False
    _kcps_notice_seen.add(run_id)
    return (parts[2] == "1" and rank == _kcps_notice_rank and
            threshold == _kcps_notice_required and count >= _kcps_notice_required)
"@
    }
    return $script.Replace("`r`n", "`n").TrimEnd() + "`n"
}

function Get-KcpsSortieChainProtectedReferences {
    param($Node, [string[]]$ProtectedGuids, [string]$Location = '$')
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            $value = $Node[$key]
            $path = "$Location.$key"
            if ([string]$key -match 'Workflows?$') {
                foreach ($reference in @($value)) {
                    if ($reference -is [System.Collections.IDictionary] -and $reference.Contains('Guid') -and
                        (Test-KcpsSortieChainReferenceEnabled $reference) -and [string]$reference.Guid -in $ProtectedGuids) {
                        [pscustomobject]@{ Path = $path; Guid = [string]$reference.Guid }
                    }
                }
            }
            Get-KcpsSortieChainProtectedReferences -Node $value -ProtectedGuids $ProtectedGuids -Location $path
        }
    } elseif ($Node -is [array]) {
        for ($i = 0; $i -lt $Node.Count; $i++) {
            Get-KcpsSortieChainProtectedReferences -Node $Node[$i] -ProtectedGuids $ProtectedGuids -Location "$Location[$i]"
        }
    }
}

function Get-KcpsSortieChainPlanStages {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Plan)
    $planKeys = @('Version', 'ChainId', 'Stages')
    if ($Plan -is [System.Collections.IDictionary] -and $Plan.Contains('QuestId')) { $planKeys += 'QuestId' }
    Assert-KcpsChainKeys $Plan $planKeys '接续计划'
    Assert-KcpsChainInteger $Plan.Version 1 1 'Version'
    Assert-KcpsChainText $Plan.ChainId 'ChainId'
    if ($Plan.Stages -isnot [array] -or $Plan.Stages.Count -lt 2) { throw 'Stages 必须是至少两个阶段的数组。' }
    $groups = @(Get-KcpsGroups -Config $Config)
    $rows = @(); $names = @(); $stages = @(); $commonQuests = $null; $hasQuests = $false
    foreach ($stage in $Plan.Stages) {
        Assert-KcpsChainKeys $stage @('GroupName', 'Stage', 'Condition') '阶段'
        Assert-KcpsChainText $stage.GroupName 'GroupName'; Assert-KcpsChainText $stage.Stage 'Stage'
        if ($stage.GroupName -cin $names -or $stage.Stage -cin $stages) { throw '阶段名与配置名必须各自唯一。' }
        $names += $stage.GroupName; $stages += $stage.Stage
        $matches = @($groups | Where-Object { [string]$_['Name'] -ceq $stage.GroupName })
        if ($matches.Count -ne 1) { throw "配置名必须精确匹配一组：$($stage.GroupName)。" }
        $group = $matches[0]
        $controllers = @($group.List | Where-Object { Test-KcpsWorkflowType $_ 'RelationalSortieWorkflow' })
        $sorties = @($group.List | Where-Object { Test-KcpsWorkflowType $_ 'SimpleSortieWorkflow' })
        if ($controllers.Count -ne 1 -or $sorties.Count -ne 1) { throw "配置 $($stage.GroupName) 必须恰有一个总控和一个出击单元。" }
        $questIds = @($group.List | Where-Object { Test-KcpsWorkflowType $_ 'BasicAcceptQuestWorkflow' } | ForEach-Object { $_.Quests } | Where-Object { [int]$_.SelectMethod -eq 0 -and [string]$_.SelectValue -match '^[1-9][0-9]*$' } | ForEach-Object { [int]$_.SelectValue } | Sort-Object -Unique)
        if ($questIds.Count -gt 0) { $hasQuests = $true }
        if ($null -eq $commonQuests) { $commonQuests = @($questIds) } else { $commonQuests = @($commonQuests | Where-Object { $_ -in $questIds }) }
        $rows += [pscustomobject]@{ Group = $group; Controller = $controllers[0]; Sortie = $sorties[0]; Stage = $stage; QuestIds = $questIds; Metadata = $null }
    }
    $questId = $null
    if ($Plan.Contains('QuestId') -and $null -ne $Plan.QuestId) {
        Assert-KcpsChainInteger $Plan.QuestId 1 ([int]::MaxValue) 'QuestId'
        $questId = [int]$Plan.QuestId
        if (@($rows | Where-Object { $questId -notin $_.QuestIds }).Count -gt 0) { throw 'QuestId 必须存在于各阶段的精确任务选择中。' }
    } elseif ($hasQuests) {
        if (@($commonQuests).Count -ne 1) { throw '无法推断唯一共同任务；请显式提供各阶段共有的 QuestId。' }
        $questId = [int]$commonQuests[0]
    }
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $row = $rows[$i]
        $sea = 0; $area = 0
        if (-not [int]::TryParse([string]$row.Sortie.Sea, [ref]$sea) -or -not [int]::TryParse([string]$row.Sortie.Area, [ref]$area)) { throw '出击的 Sea/Area 必须是整数。' }
        $metadata = [ordered]@{
            Version = 1; Mode = 'Sequential'; QuestId = $questId; ChainId = $Plan.ChainId; GroupName = $row.Stage.GroupName
            Stage = $row.Stage.Stage; StageIndex = $i; StageCount = $rows.Count
            Map = [ordered]@{ Sea = $sea; Area = $area }; Condition = $row.Stage.Condition
            ListenMessage = $(if ($i -eq 0) { $null } else { "$($Plan.ChainId) $($rows[$i - 1].Stage.Stage) Clear" })
            CompletionMessage = "$($Plan.ChainId) $($row.Stage.Stage) Clear"
        }
        $row.Metadata = ConvertTo-KcpsSortieChainMetadata $metadata
        $rank = Get-KcpsSortieChainRankValue $row.Metadata.Condition.Rank
        if (-not $row.Controller.StopIfBossBattleRankHigherOrEqualThanFlag -or
            [int]$row.Controller.StopIfBossBattleRankHigherOrEqualThanValueRank -ne $rank -or
            [int]$row.Controller.StopIfBossBattleRankHigherOrEqualThanValueThreshold -ne [int]$row.Metadata.Condition.Count) {
            throw "配置 $($row.Stage.GroupName) 的原生 Boss 评级停止条件与计划不符；工具不会修改任务目标。"
        }
    }
    return $rows
}
