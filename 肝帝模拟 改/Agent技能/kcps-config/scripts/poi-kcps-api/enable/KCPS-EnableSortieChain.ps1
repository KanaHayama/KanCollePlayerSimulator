#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$PlanPath,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../KCPS-Common.ps1"
. "$PSScriptRoot/../common/KCPS-SortieChain.ps1"

$resolvedPath = (Resolve-Path -LiteralPath $Path).Path
$config = Read-KcpsJson -Path $resolvedPath
$plan = Read-KcpsJson -Path $PlanPath
$rows = @(Get-KcpsSortieChainPlanStages -Config $config -Plan $plan)
$changes = @()
$protectedGuids = @()
foreach ($row in $rows) {
    $controller = $row.Controller
    # 原生载入器先从完整 Type 读取版本；通知与总控属于同一程序集。
    $controllerType = [string]$controller['Type']
    $versionMatch = [regex]::Match($controllerType, 'Version=([\d\.]+),')
    $typeVersion = $null
    if (-not $versionMatch.Success -or -not [version]::TryParse($versionMatch.Groups[1].Value, [ref]$typeVersion) -or
        $controllerType -cnotmatch '^KancollePlayerSimulatorKai\.RelationalSortieWorkflow,\s*KancollePlayerSimulatorKai,') {
        throw "配置 $($row.Stage.GroupName) 的总控 Type 缺少可解析的完整程序集版本，不能生成可载入的通知。"
    }
    $newNoticeType = $controllerType -creplace '^KancollePlayerSimulatorKai\.RelationalSortieWorkflow,', 'KancollePlayerSimulatorKai.SimpleRaiseUserEventWorkflow,'
    $controllerGuid = ConvertTo-KcpsSortieChainGuid $controller['Guid'] '总控 Guid'
    $oldScript = [string]$controller['Script']
    $oldMetadata = $null
    if (-not [string]::IsNullOrWhiteSpace($oldScript)) {
        $oldMetadata = Get-KcpsSortieChainMetadata -Script $oldScript
        if ($null -eq $oldMetadata -or $oldScript.Replace("`r`n", "`n") -cne (New-KcpsSortieChainScript $oldMetadata)) {
            throw "配置 $($row.Stage.GroupName) 已有未知或修改过的脚本，不能自动覆盖。"
        }
        if ($oldMetadata.Version -eq 2 -and ($oldMetadata.Role -cne 'Controller' -or $oldMetadata.ControllerGuid -ne $controllerGuid)) {
            throw "配置 $($row.Stage.GroupName) 的既有脚本不是绑定当前总控的受管理脚本。"
        }
    }
    foreach ($key in @('AutoStoppedEnableWorkflows', 'AutoStoppedTriggerWorkflows')) {
        if (@($controller[$key] | Where-Object { Test-KcpsSortieChainReferenceEnabled $_ }).Count -gt 0) {
            throw "配置 $($row.Stage.GroupName) 的 $key 含既有动作；须先确认其与受保护完成消息的关系。"
        }
    }
    foreach ($reference in @($controller.AutoStoppedDisableWorkflows | Where-Object { Test-KcpsSortieChainReferenceEnabled $_ })) {
        $targets = @($row.Group.List | Where-Object { [string]$_.Guid -eq [string]$reference.Guid })
        if ($targets.Count -ne 1 -or (Test-KcpsWorkflowType $targets[0] 'RelationalSortieWorkflow')) {
            throw "配置 $($row.Stage.GroupName) 自动停止后禁用目标无法安全解析，或会中断接续总控。"
        }
    }
    $notices = @($row.Group.List | Where-Object { [string]$_['Name'] -ceq '出击完成' })
    if ($notices.Count -gt 1) { throw "配置 $($row.Stage.GroupName) 有多个出击完成单元。" }
    if ($notices.Count -eq 1) {
        $notice = $notices[0]
        if (-not (Test-KcpsWorkflowType $notice 'SimpleRaiseUserEventWorkflow')) { throw '已有同名出击完成单元不是原生通知类型。' }
        $noticeGuid = ConvertTo-KcpsSortieChainGuid $notice['Guid'] '出击完成 Guid'
        $noticeScript = [string]$notice['Script']
        if ([string]::IsNullOrWhiteSpace($noticeScript)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$notice['Message'])) { throw '已有出击完成单元并非空白骨架，不能覆盖。' }
        } else {
            $noticeMetadata = Get-KcpsSortieChainMetadata $noticeScript
            if ($null -eq $noticeMetadata -or $noticeMetadata.Version -ne 2 -or $noticeMetadata.Role -cne 'Notice' -or
                $noticeMetadata.ControllerGuid -ne $controllerGuid -or $noticeMetadata.NoticeGuid -ne $noticeGuid -or
                $noticeScript.Replace("`r`n", "`n") -cne (New-KcpsSortieChainScript $noticeMetadata)) {
                throw '已有出击完成单元包含未知、修改过或绑定不一致的脚本。'
            }
        }
    } else {
        $noticeGuid = if ($null -ne $oldMetadata -and $oldMetadata.Version -eq 2) { $oldMetadata.NoticeGuid } else { [guid]::NewGuid().ToString('D') }
        $notice = [ordered]@{
            Type = $newNoticeType
            Guid = $noticeGuid; Name = '出击完成'; Message = ''; Script = $null
            EnableOnLoad = $false; EnableScript = $true; TriggerOnEnabled = $false; Memo = ''
        }
        $row.Group.List = @($row.Group.List) + @($notice)
        $changes += [pscustomobject]@{ Group = $row.Stage.GroupName; Field = 'List.AddNotice' }
    }
    # 只修复本工具曾生成的精确短类型名，不覆盖其他自定义或有效版本。
    if ([string]$notice['Type'] -ceq 'KancollePlayerSimulatorKai.SimpleRaiseUserEventWorkflow, KancollePlayerSimulatorKai') {
        $notice['Type'] = $newNoticeType
        $changes += [pscustomobject]@{ Group = $row.Stage.GroupName; Field = 'Notice.Type' }
    }
    $noticeVersionMatch = [regex]::Match([string]$notice['Type'], 'Version=([\d\.]+),')
    $noticeTypeVersion = $null
    if (-not $noticeVersionMatch.Success -or -not [version]::TryParse($noticeVersionMatch.Groups[1].Value, [ref]$noticeTypeVersion)) {
        throw "配置 $($row.Stage.GroupName) 的出击完成 Type 版本无效，无法被 KCPS 载入。"
    }
    if ($null -ne $oldMetadata -and $oldMetadata.Version -eq 2 -and $oldMetadata.NoticeGuid -ne $noticeGuid) {
        throw '总控和出击完成单元的既有绑定不一致。'
    }
    if (@($row.Group.List | Where-Object {
        -not [object]::ReferenceEquals($_, $notice) -and (Test-KcpsWorkflowType $_ 'SimpleRaiseUserEventWorkflow') -and
        [string]$_['Message'] -match '(?:^|\s)Clear\s*$'
    }).Count -gt 0) {
        throw "配置 $($row.Stage.GroupName) 已有其他原生 Clear 通知，须先核对其成功判定。"
    }
    $metadata = $row.Metadata
    $metadata.Version = 2
    $metadata.Role = 'Controller'
    $metadata.ControllerGuid = $controllerGuid
    $metadata.NoticeGuid = $noticeGuid
    $metadata.ResultMessagePrefix = Get-KcpsSortieChainResultPrefix $controllerGuid $noticeGuid
    $row.Metadata = ConvertTo-KcpsSortieChainMetadata $metadata
    $noticeMetadata = ConvertTo-KcpsSortieChainMetadata $row.Metadata
    $noticeMetadata.Role = 'Notice'
    $row | Add-Member -NotePropertyMembers @{ Notice = $notice; NoticeMetadata = $noticeMetadata }
    $protectedGuids += @($controllerGuid, $noticeGuid)
}

# 原生关联直接 TryFire，绕过 OnEvent；任何作用于总控/通知的启用关联都必须拒绝。
$allWorkflows = @(Get-KcpsGroups -Config $config | ForEach-Object { $_.List })
foreach ($guid in $protectedGuids) {
    $matches = @($allWorkflows | Where-Object { [string]$_['Guid'] -eq $guid })
    if ($matches.Count -ne 1) { throw "受保护执行单元 GUID 不唯一：$guid。" }
}
$unsafeReferences = @(Get-KcpsSortieChainProtectedReferences -Node $config -ProtectedGuids $protectedGuids)
if ($unsafeReferences.Count -gt 0) {
    throw "原生关联会绕过或破坏接续监听：$($unsafeReferences.Path -join ', ')。"
}

foreach ($row in $rows) {
    $controller = $row.Controller
    $notice = $row.Notice
    if (-not [object]::ReferenceEquals(@($row.Group.List)[-1], $notice)) {
        $row.Group.List = @($row.Group.List | Where-Object { -not [object]::ReferenceEquals($_, $notice) }) + @($notice)
        $changes += [pscustomobject]@{ Group = $row.Stage.GroupName; Field = 'List.NoticeOrder' }
    }
    $desired = [ordered]@{
        EnableOnLoad = $true; EnableScript = $true; TriggerOnEnabled = $false; ReturnRoomAtLast = $false
        Script = New-KcpsSortieChainScript $row.Metadata
    }
    # 每个接续阶段都是一次新运行；原生首轮跳过等待也会跳过已启用的士气恢复等待。
    if (($controller['SleepUntilMoraleRecoveredFlag'] -is [bool] -and $controller['SleepUntilMoraleRecoveredFlag']) -or
        ($controller['SleepUntilFlagShipMoraleRecoveredFlag'] -is [bool] -and $controller['SleepUntilFlagShipMoraleRecoveredFlag'])) {
        $desired.DoNotSleepAtFirstLoop = $false
    }
    foreach ($key in $desired.Keys) {
        if ($controller[$key] -cne $desired[$key]) {
            $changes += [pscustomobject]@{ Group = $row.Stage.GroupName; Field = $key }
            $controller[$key] = $desired[$key]
        }
    }
    $noticeDesired = [ordered]@{
        EnableOnLoad = $true; EnableScript = $true; TriggerOnEnabled = $false
        Message = $row.NoticeMetadata.CompletionMessage
        Script = New-KcpsSortieChainScript $row.NoticeMetadata
        Memo = "接收本阶段总控的出击结果；Boss 评级达到 $($row.Metadata.Condition.Rank) 或以上累计 $($row.Metadata.Condition.Count) 次时发送完成消息。未达标的停止不会推进。"
    }
    foreach ($key in $noticeDesired.Keys) {
        if ($notice[$key] -cne $noticeDesired[$key]) {
            $changes += [pscustomobject]@{ Group = $row.Stage.GroupName; Field = "Notice.$key" }
            $notice[$key] = $noticeDesired[$key]
        }
    }
}
if ($changes.Count -gt 0 -and -not $CheckOnly) {
    [IO.File]::WriteAllText($resolvedPath, (Write-KcpsJson -Value $config), [Text.UTF8Encoding]::new($false))
}
[pscustomobject]@{ Path = $resolvedPath; ChainId = $plan.ChainId; StageCount = $rows.Count; CheckOnly = [bool]$CheckOnly; Changed = $changes.Count -gt 0; ChangeCount = $changes.Count; Changes = $changes } | ConvertTo-Json -Depth 8
