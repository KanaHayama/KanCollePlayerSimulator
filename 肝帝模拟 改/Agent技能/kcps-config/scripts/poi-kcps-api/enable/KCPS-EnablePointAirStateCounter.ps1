#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$GroupName,

    [Parameter(Mandatory = $true)]
    [int]$MapId,

    [Parameter(Mandatory = $true)]
    [int[]]$ConditionValue,

    [Parameter(Mandatory = $true)]
    [string]$PointName,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 99)]
    [int]$RequiredCount,

    [ValidateRange(2, 99)]
    [int]$SafetyLoopMax = 10,

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

$sortieBegin = '# KCPS_POINT_AIR_STATE_PROBE_BEGIN'
$sortieEnd = '# KCPS_POINT_AIR_STATE_PROBE_END'
$controllerBegin = '# KCPS_POINT_AIR_STATE_COUNTER_BEGIN'
$controllerEnd = '# KCPS_POINT_AIR_STATE_COUNTER_END'

function ConvertTo-PythonString {
    param([AllowEmptyString()][string]$Value)

    return ($Value | ConvertTo-Json -Compress)
}

function Remove-ManagedBlock {
    param(
        [string]$Script,
        [string]$Begin,
        [string]$End
    )

    if ([string]::IsNullOrWhiteSpace($Script)) { return '' }
    $pattern = '(?ms)^' + [regex]::Escape($Begin) + '.*?^' + [regex]::Escape($End) + '\s*'
    return ([regex]::Replace($Script, $pattern, '')).Trim()
}

function Set-ManagedBlock {
    param(
        [string]$Script,
        [string]$Begin,
        [string]$End,
        [string]$Block
    )

    $remaining = Remove-ManagedBlock -Script $Script -Begin $Begin -End $End
    if ([string]::IsNullOrWhiteSpace($remaining)) {
        return $Block.Trim()
    }
    return ($remaining.TrimEnd() + "`r`n`r`n" + $Block.Trim())
}

function Assert-NoHookConflict {
    param(
        [string]$Script,
        [string]$Begin,
        [string]$End,
        [string[]]$HookNames,
        [string]$Owner
    )

    $remaining = Remove-ManagedBlock -Script $Script -Begin $Begin -End $End
    foreach ($hookName in $HookNames) {
        if ($remaining -match ('(?m)^\s*def\s+' + [regex]::Escape($hookName) + '\s*\(')) {
            throw "$Owner already defines $hookName outside the managed point-air-state block; automatic composition would overwrite existing behavior."
        }
    }
}

function Set-MemoSection {
    param(
        [string]$Memo,
        [string]$Name,
        [string]$Body
    )

    $section = "【$Name】`r`n$($Body.Trim())"
    $pattern = '(?ms)^' + [regex]::Escape("【$Name】") + '\s*.*?(?=^【|\z)'
    if ([regex]::IsMatch($Memo, $pattern)) {
        return ([regex]::Replace($Memo, $pattern, $section + "`r`n`r`n")).TrimEnd()
    }
    if ([string]::IsNullOrWhiteSpace($Memo)) {
        return $section
    }
    return ($Memo.TrimEnd() + "`r`n`r`n" + $section)
}

if ($SafetyLoopMax -le $RequiredCount) {
    throw 'SafetyLoopMax must be larger than RequiredCount; the loop cap is a safety stop, not proof of completion.'
}

$resolvedPath = (Resolve-Path -LiteralPath $Path).Path
$config = Read-KcpsJson -Path $resolvedPath
$groups = @(Get-KcpsGroups -Config $config)
$matches = @($groups | Where-Object { [string]$_['Name'] -eq $GroupName })
if ($matches.Count -ne 1) {
    throw "Expected exactly one group named '$GroupName', found $($matches.Count)."
}

$group = $matches[0]
$workflows = @($group['List'])
$controllers = @($workflows | Where-Object {
    Test-KcpsWorkflowType -Workflow $_ -TypeName 'RelationalSortieWorkflow'
})
$sorties = @($workflows | Where-Object {
    Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleSortieWorkflow'
})
if ($controllers.Count -ne 1 -or $sorties.Count -ne 1) {
    throw "Group '$GroupName' must contain exactly one relational controller and one sortie workflow."
}

$controller = $controllers[0]
$sortie = $sorties[0]
$memoWorkflows = @($workflows | Where-Object {
    Test-KcpsWorkflowType -Workflow $_ -TypeName 'MemoWorkflow'
})
if ($memoWorkflows.Count -ne 1) {
    throw "Group '$GroupName' must contain exactly one memo workflow."
}
$memoWorkflow = $memoWorkflows[0]
$stopNotices = @($workflows | Where-Object {
    (Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleRaiseUserEventWorkflow') -and
    [string]$_['Name'] -eq '通知停止'
})
if ($stopNotices.Count -ne 1) {
    throw "Group '$GroupName' must contain exactly one notification workflow named 通知停止."
}
$stopNoticeMessage = [string]$stopNotices[0]['Message']
$conditionValues = @($ConditionValue | Sort-Object -Unique)
$matchingStrategies = @($sortie['Strategies'] | Where-Object {
    [int]$_['Condition']['Type'] -eq 1 -and
    [int]$_['Condition']['Value'] -in $conditionValues
})
if ($matchingStrategies.Count -ne $conditionValues.Count) {
    $foundValues = @($matchingStrategies | ForEach-Object { [int]$_['Condition']['Value'] })
    $missing = @($conditionValues | Where-Object { $_ -notin $foundValues })
    throw "Group '$GroupName' is missing map-point strategies for condition value(s): $($missing -join ', ')."
}

$sortieScript = [string]$sortie['Script']
$controllerScript = [string]$controller['Script']
Assert-NoHookConflict `
    -Script $sortieScript `
    -Begin $sortieBegin `
    -End $sortieEnd `
    -HookNames @('OnPointAirState', 'OnProcess') `
    -Owner 'Sortie workflow'
Assert-NoHookConflict `
    -Script $controllerScript `
    -Begin $controllerBegin `
    -End $controllerEnd `
    -HookNames @('OnFilterEvent', 'OnAutoStop', 'OnAutoStopped') `
    -Owner 'Relational controller'

$messagePrefix = "KCPS_POINT_AIR_STATE:$($sortie['Guid'])"
$spec = [ordered]@{
    Version = 2
    TokenStrategy = 'SortieRunAndBattleOrdinal'
    MapId = $MapId
    ConditionValues = @($conditionValues)
    PointName = $PointName
    RequiredCount = $RequiredCount
    MessagePrefix = $messagePrefix
}
$specJson = $spec | ConvertTo-Json -Compress
$pythonValues = '(' + (($conditionValues | ForEach-Object { [string]$_ }) -join ', ') + ')'
if ($conditionValues.Count -eq 1) {
    $pythonValues = "($($conditionValues[0]),)"
}
$pythonPointName = ConvertTo-PythonString -Value $PointName
$pythonPrefix = ConvertTo-PythonString -Value $messagePrefix

$sortieBlock = @"
$sortieBegin
# KCPS_POINT_AIR_STATE_PROBE_SPEC $specJson
from KancollePlayerSimulatorKaiCore import *
from System import Guid

POINT_AIR_STATE_MAP = $MapId
POINT_AIR_STATE_VALUES = $pythonValues
POINT_AIR_STATE_NAME = $pythonPointName
POINT_AIR_STATE_PREFIX = $pythonPrefix
_point_air_state_run = None

def OnProcess():
    # 每次执行单次出击创建新标识，不依赖poi时间字段
    global _point_air_state_run
    _point_air_state_run = str(Guid.NewGuid())

def _point_air_state_token_value(token):
    if token is None:
        return None
    try:
        return int(str(token))
    except:
        return None

def _read_point_air_state():
    # 读取当前目标点的制空结果
    state = GameState.Battle()
    if state is None:
        return (None, None)
    try:
        status = state["_status"]
        map_id = _point_air_state_token_value(status["map"])
        cell = _point_air_state_token_value(status["currentCell"])
        if map_id != POINT_AIR_STATE_MAP or cell not in POINT_AIR_STATE_VALUES:
            return (None, None)
        battle_index = _point_air_state_token_value(Workflow.BattleCount)
        if _point_air_state_run is None or battle_index is None or battle_index < 0:
            Logger.Error("{0}制空计数失败：缺少本轮出击标识或战斗序号".format(
                POINT_AIR_STATE_NAME))
            return (None, None)
        battle = status["battle"]
        if battle is None:
            return (None, None)
        packets = battle["packet"]
        if packets is None:
            return (None, None)
        packet_list = list(packets)
        for packet in reversed(packet_list):
            for key in ("api_kouku", "api_kouku2"):
                kouku = packet[key]
                if kouku is None:
                    continue
                stage1 = kouku["api_stage1"]
                if stage1 is None:
                    continue
                seiku = _point_air_state_token_value(stage1["api_disp_seiku"])
                if seiku is not None:
                    token = "{0}:{1}:{2}:{3}".format(
                        _point_air_state_run, map_id, cell, battle_index)
                    return (seiku, token)
        return (None, None)
    except Exception as ex:
        Logger.Error("{0}制空结果读取失败：{1}".format(
            POINT_AIR_STATE_NAME, ex))
        return (None, None)

def OnPointAirState():
    seiku, token = _read_point_air_state()
    if seiku is None or token is None:
        Logger.Error("{0}没有读取到可计数的制空结果".format(
            POINT_AIR_STATE_NAME))
        return
    if seiku not in (1, 2):
        names = {0: "未判定", 3: "航空均衡", 4: "制空权丧失"}
        Logger.Info("{0}未取得航空优势，不计数：{1}".format(
            POINT_AIR_STATE_NAME, names.get(seiku, "状态{0}".format(seiku))))
        return
    Utility.RaiseEvent(UserEvent("{0}|{1}|{2}".format(
        POINT_AIR_STATE_PREFIX, token, seiku)))
$sortieEnd
"@

$controllerBlock = @"
$controllerBegin
# KCPS_POINT_AIR_STATE_COUNTER_SPEC $specJson
from KancollePlayerSimulatorKaiCore import *

POINT_AIR_STATE_PREFIX = $pythonPrefix
POINT_AIR_STATE_NAME = $pythonPointName
POINT_AIR_STATE_REQUIRED = $RequiredCount
_point_air_state_count = 0
_point_air_state_seen = set()

def OnFilterEvent(e):
    global _point_air_state_count
    if not isinstance(e, UserEvent):
        return True
    message = str(e.Message)
    prefix = POINT_AIR_STATE_PREFIX + "|"
    if not message.startswith(prefix):
        return True
    parts = message.split("|")
    if len(parts) != 3:
        Logger.Error("{0}制空计数消息格式错误".format(POINT_AIR_STATE_NAME))
        return False
    token = parts[1]
    if token in _point_air_state_seen:
        return False
    try:
        seiku = int(parts[2])
    except:
        Logger.Error("{0}制空计数消息状态错误".format(POINT_AIR_STATE_NAME))
        return False
    _point_air_state_seen.add(token)
    if seiku in (1, 2):
        _point_air_state_count += 1
        Logger.Info("{0}航空优势计数：{1}/{2}".format(
            POINT_AIR_STATE_NAME,
            _point_air_state_count,
            POINT_AIR_STATE_REQUIRED))
    return False

def OnAutoStop():
    return _point_air_state_count >= POINT_AIR_STATE_REQUIRED

def OnAutoStopped():
    global _point_air_state_count
    global _point_air_state_seen
    _point_air_state_count = 0
    _point_air_state_seen = set()
$controllerEnd
"@

$newSortieScript = Set-ManagedBlock `
    -Script $sortieScript `
    -Begin $sortieBegin `
    -End $sortieEnd `
    -Block $sortieBlock
$newControllerScript = Set-ManagedBlock `
    -Script $controllerScript `
    -Begin $controllerBegin `
    -End $controllerEnd `
    -Block $controllerBlock

$changed = $false
if ([string]$sortie['Script'] -ne $newSortieScript) {
    $sortie['Script'] = $newSortieScript
    $changed = $true
}
if (-not [bool]$sortie['EnableScript']) {
    $sortie['EnableScript'] = $true
    $changed = $true
}
foreach ($row in $matchingStrategies) {
    $strategy = $row['Strategy']
    if (-not [bool]$strategy['EnableScriptEnterDayTimeBattleCallback']) {
        $strategy['EnableScriptEnterDayTimeBattleCallback'] = $true
        $changed = $true
    }
    if ([string]$strategy['EnterDayTimeBattleCallbackFunctionName'] -ne 'OnPointAirState') {
        $strategy['EnterDayTimeBattleCallbackFunctionName'] = 'OnPointAirState'
        $changed = $true
    }
}
if ([string]$controller['Script'] -ne $newControllerScript) {
    $controller['Script'] = $newControllerScript
    $changed = $true
}
if (-not [bool]$controller['EnableScript']) {
    $controller['EnableScript'] = $true
    $changed = $true
}
if (-not [bool]$controller['StopIfLoopCountLargerOrEqualThanFlag']) {
    $controller['StopIfLoopCountLargerOrEqualThanFlag'] = $true
    $changed = $true
}
if ([int]$controller['StopIfLoopCountLargerOrEqualThanValue'] -ne $SafetyLoopMax) {
    $controller['StopIfLoopCountLargerOrEqualThanValue'] = $SafetyLoopMax
    $changed = $true
}
# 制空计数是唯一成功条件；关闭与制空结果无关的内建停止条件。
foreach ($flagName in @(
    'StopIfEnemyFlagShipSunkFlag',
    'StopIfBattleRankHigherOrEqualThanFlag',
    'StopIfBossBattleRankHigherOrEqualThanFlag',
    'StopIfArrivedEndPointFlag',
    'StopIfEnemyDebufAtHomeFlag',
    'StopIfAirBaseAttackNoDamageFlag'
)) {
    if ($controller.ContainsKey($flagName) -and [bool]$controller[$flagName]) {
        $controller[$flagName] = $false
        $changed = $true
    }
}
$newMemo = Set-MemoSection `
    -Memo ([string]$memoWorkflow['Memo']) `
    -Name '自动化模式' `
    -Body @"
$PointName 进入昼战后直接读取本队制空状态；仅制空权确保或航空优势精确计数，均衡、丧失、偏航和撤退均不计数。
累计达到 $RequiredCount 次后由总控自动停止。循环上限 $SafetyLoopMax 次只是接口异常、未取得空优或长期偏航时的安全上限，不代表完成。
"@
$newMemo = Set-MemoSection `
    -Memo $newMemo `
    -Name '停止' `
    -Body @"
精确停止：$PointName 航空优势或以上累计达到 $RequiredCount 次。
安全停止：总循环达到 $SafetyLoopMax 次；此时可能尚未完成，必须检查游戏任务或削甲状态。
两条路径都由通知停止发送：
「$stopNoticeMessage」。
不发送 Clear，避免把安全停止误报为完成。
"@
if ($newMemo -ne [string]$memoWorkflow['Memo']) {
    $memoWorkflow['Memo'] = $newMemo
    $changed = $true
}
$newControllerMemo = "$PointName 的制空权确保或航空优势由战斗回调精确计数，达到 $RequiredCount 次停止；$SafetyLoopMax 次仅为安全上限。"
if ([string]$controller['Memo'] -ne $newControllerMemo) {
    $controller['Memo'] = $newControllerMemo
    $changed = $true
}

if ($changed -and -not $CheckOnly) {
    Write-KcpsJson -Value $config | Set-Content -LiteralPath $resolvedPath -Encoding utf8
}

[pscustomobject]@{
    Path = $resolvedPath
    Group = $GroupName
    MapId = $MapId
    ConditionValues = $conditionValues -join ','
    Point = $PointName
    RequiredCount = $RequiredCount
    SafetyLoopMax = $SafetyLoopMax
    Changed = $changed
    CheckOnly = [bool]$CheckOnly
}
