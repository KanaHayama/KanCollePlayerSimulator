#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$IronPythonDirectory,
    [string]$ConfigPath,
    [string]$KcpsRuntimeDirectory
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../KCPS-Common.ps1"
. "$PSScriptRoot/../common/KCPS-SortieChain.ps1"
$checks = 0
function Assert-ChainBehavior([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw $Label }; $script:checks++
}
function Assert-ChainThrows([scriptblock]$Action, [string]$Label) {
    $caught = $false; try { & $Action | Out-Null } catch { $caught = $true }
    Assert-ChainBehavior $caught $Label
}
function Copy-ChainFixture($Value) { ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 100) -AsHashtable -NoEnumerate }
function Write-ChainFixture($Value, [string]$Path) { [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 100), [Text.UTF8Encoding]::new($false)) }
function Get-ChainFixtureType([string]$Name) { "KancollePlayerSimulatorKai.$Name, KancollePlayerSimulatorKai, Version=1.5.2.1, Culture=neutral, PublicKeyToken=null" }
function Get-ChainRuntimeCase($Group) {
    $controllers = @($Group.List | Where-Object { Test-KcpsWorkflowType $_ 'RelationalSortieWorkflow' })
    $notices = @($Group.List | Where-Object { Test-KcpsWorkflowType $_ 'SimpleRaiseUserEventWorkflow' })
    if ($controllers.Count -ne 1 -or $notices.Count -ne 1) { throw '每阶段必须恰有一组总控和完成通知。' }
    $controller = $controllers[0]; $notice = $notices[0]
    $metadata = Get-KcpsSortieChainMetadata $controller.Script
    $noticeMetadata = Get-KcpsSortieChainMetadata $notice.Script
    foreach ($workflow in @($controller, $notice)) {
        $m = Get-KcpsSortieChainMetadata $workflow.Script
        if ($null -eq $m -or $m.Version -ne 2 -or $workflow.Script.Replace("`r`n", "`n") -cne (New-KcpsSortieChainScript $m)) {
            throw '运行测试只接受完整且未修改的 v2 接续脚本。'
        }
    }
    if ($metadata.Role -cne 'Controller' -or $noticeMetadata.Role -cne 'Notice' -or
        $metadata.ControllerGuid -cne $controller.Guid -or $metadata.NoticeGuid -cne $notice.Guid -or
        $notice.Message -cne $metadata.CompletionMessage) { throw '总控和完成通知身份不一致。' }
    return @{ ControllerScript=$controller.Script; NoticeScript=$notice.Script; Metadata=$metadata }
}

# 所有写入均为调用方所选目录内的合成文件，不读取本机设置或游戏接口。
$testDirectory = Join-Path ([IO.Path]::GetFullPath($WorkDirectory)) ('synthetic-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($testDirectory)
$fixture = @(); $stages = @()
foreach ($i in 0..4) {
    $name = "合成任务阶段 $i"; $guid = [guid]::NewGuid().ToString(); $cleanupGuid = [guid]::NewGuid().ToString()
    $required = if ($i -eq 2) { 3 } else { 1 }
    $fixture += @{
        Name = $name; List = @(
            @{Type=(Get-ChainFixtureType 'RelationalSortieWorkflow');Guid=$guid;Name='总控';Script=$null;EnableScript=$false;EnableOnLoad=$false;TriggerOnEnabled=$true;ReturnRoomAtLast=$true
              StopIfBossBattleRankHigherOrEqualThanFlag=$true;StopIfBossBattleRankHigherOrEqualThanValueRank=3;StopIfBossBattleRankHigherOrEqualThanValueThreshold=$required
              AutoStoppedEnableWorkflows=@();AutoStoppedTriggerWorkflows=@();AutoStoppedDisableWorkflows=@(@{Guid=$cleanupGuid;Enabled=$true})},
            @{Type=(Get-ChainFixtureType 'SimpleSortieWorkflow');Guid=[guid]::NewGuid().ToString();Sea='3';Area=[string]($i+1);Strategies=@()},
            @{Type=(Get-ChainFixtureType 'BasicDockingWorkflow');Guid=$cleanupGuid;Name='合成清理';Marker='preserve'},
            @{Type=(Get-ChainFixtureType 'BasicAcceptQuestWorkflow');Guid=[guid]::NewGuid().ToString();Quests=@(@{SelectMethod=0;SelectValue='700001'})}
        )
    }
    $stages += @{GroupName=$name;Stage="3-$($i+1)";Condition=@{Type='BossRank';Rank='A';Count=$required}}
}
$plan = @{Version=1;ChainId='synthetic-chain';Stages=$stages}
$configFile = Join-Path $testDirectory 'fixture.conf.json'; $planFile = Join-Path $testDirectory 'plan.json'
Write-ChainFixture $fixture $configFile; Write-ChainFixture $plan $planFile
$tool = Join-Path $PSScriptRoot '../enable/KCPS-EnableSortieChain.ps1'
$beforeHash = (Get-FileHash -LiteralPath $configFile).Hash
$preview = (& $tool -Path $configFile -PlanPath $planFile -CheckOnly | Out-String) | ConvertFrom-Json
Assert-ChainBehavior ($preview.Changed -and $beforeHash -eq (Get-FileHash -LiteralPath $configFile).Hash) 'CheckOnly 不写入配置'
$null = & $tool -Path $configFile -PlanPath $planFile
$configured = Read-KcpsJson $configFile
$installedHash = (Get-FileHash -LiteralPath $configFile).Hash
$second = (& $tool -Path $configFile -PlanPath $planFile -CheckOnly | Out-String) | ConvertFrom-Json
Assert-ChainBehavior (-not $second.Changed) '第二次安装不产生变更'
$null = & $tool -Path $configFile -PlanPath $planFile
Assert-ChainBehavior ($installedHash -eq (Get-FileHash -LiteralPath $configFile).Hash) '重复安装不重写文件或更换 GUID'
$cases = @()
foreach ($i in 0..4) {
    $controller = $configured[$i].List[0]
    $case = Get-ChainRuntimeCase $configured[$i]; $cases += $case
    $metadata = $case.Metadata
    $notice = @($configured[$i].List | Where-Object { Test-KcpsWorkflowType $_ 'SimpleRaiseUserEventWorkflow' })[0]
    Assert-ChainBehavior ($metadata.QuestId -eq 700001) '按精确选择项推断共同任务'
    Assert-ChainBehavior ($controller.EnableOnLoad -and $controller.EnableScript -and -not $controller.TriggerOnEnabled -and -not $controller.ReturnRoomAtLast) '总控监听已启用且不提前启动或排入返回提督室'
    Assert-ChainBehavior ($notice.EnableOnLoad -and $notice.EnableScript -and -not $notice.TriggerOnEnabled) '完成通知只等待事件'
    Assert-ChainBehavior ($notice.Type -ceq (Get-ChainFixtureType 'SimpleRaiseUserEventWorkflow')) '新通知保留总控的完整程序集版本标识，可通过原生预加载'
    Assert-ChainBehavior ((ConvertTo-Json -InputObject $fixture[$i].List[1..3] -Depth 40 -Compress) -ceq (ConvertTo-Json -InputObject $configured[$i].List[1..3] -Depth 40 -Compress)) '保留出击及其他原有单元'
    Assert-ChainBehavior ((ConvertTo-Json $controller.AutoStoppedDisableWorkflows -Compress) -ceq (ConvertTo-Json $fixture[$i].List[0].AutoStoppedDisableWorkflows -Compress)) '保留安全禁用关联'
    Assert-ChainBehavior ($controller.Guid -ceq $fixture[$i].List[0].Guid) '保留原有总控 GUID'
    Assert-ChainBehavior ($configured[$i].List.Count -eq 5 -and $metadata.NoticeGuid -ceq $notice.Guid) '只新增一个明确关联的完成通知'
}

# 用旧版完整脚本构造迁移输入，检查迁移结果及再次应用的稳定性。
$legacy = Copy-ChainFixture $fixture
foreach ($i in 0..4) {
    $metadata = Copy-ChainFixture $cases[$i].Metadata
    $metadata.Version = 1
    foreach ($key in @('Role','ControllerGuid','NoticeGuid','ResultMessagePrefix')) { $metadata.Remove($key) }
    $legacy[$i].List[0].Script = New-KcpsSortieChainScript $metadata
    Assert-ChainBehavior ($legacy[$i].List[0].Script.StartsWith('# KCPS Sortie Chain v1')) '迁移输入确为 v1 脚本'
}
$legacyFile = Join-Path $testDirectory 'legacy.conf.json'
Write-ChainFixture $legacy $legacyFile
$legacyHash = (Get-FileHash -LiteralPath $legacyFile).Hash
$preview = (& $tool -Path $legacyFile -PlanPath $planFile -CheckOnly | Out-String) | ConvertFrom-Json
Assert-ChainBehavior ($preview.Changed -and $legacyHash -eq (Get-FileHash -LiteralPath $legacyFile).Hash) 'v1 迁移预览不写入'
$null = & $tool -Path $legacyFile -PlanPath $planFile
$migrated = Read-KcpsJson $legacyFile
foreach ($i in 0..4) {
    $case = Get-ChainRuntimeCase $migrated[$i]
    Assert-ChainBehavior ($case.Metadata.Version -eq 2 -and $case.Metadata.ControllerGuid -ceq $legacy[$i].List[0].Guid) 'v1 升级为分离的 v2 总控与通知且保留总控身份'
    Assert-ChainBehavior ($migrated[$i].List.Count -eq 5) 'v1 迁移只新增一个通知'
}
$migrationHash = (Get-FileHash -LiteralPath $legacyFile).Hash
$null = & $tool -Path $legacyFile -PlanPath $planFile
Assert-ChainBehavior ($migrationHash -eq (Get-FileHash -LiteralPath $legacyFile).Hash) '迁移后重复安装 GUID 与内容稳定'

# 修复已生成脚本正确、但类型缺少版本的旧通知；绑定和脚本均不得漂移。
$shortNoticeConfig = Copy-ChainFixture $configured
$shortNotice = @($shortNoticeConfig[0].List | Where-Object { Test-KcpsWorkflowType $_ 'SimpleRaiseUserEventWorkflow' })[0]
$shortNotice.Type = 'KancollePlayerSimulatorKai.SimpleRaiseUserEventWorkflow, KancollePlayerSimulatorKai'
$shortNoticeFile = Join-Path $testDirectory 'short-notice.conf.json'
Write-ChainFixture $shortNoticeConfig $shortNoticeFile
$shortNoticeHash = (Get-FileHash -LiteralPath $shortNoticeFile).Hash
$preview = (& $tool -Path $shortNoticeFile -PlanPath $planFile -CheckOnly | Out-String) | ConvertFrom-Json
Assert-ChainBehavior ($preview.Changed -and $shortNoticeHash -eq (Get-FileHash -LiteralPath $shortNoticeFile).Hash) '缺版本通知修复预览不写入'
$null = & $tool -Path $shortNoticeFile -PlanPath $planFile
Assert-ChainBehavior ((ConvertTo-Json -InputObject (Read-KcpsJson $shortNoticeFile) -Depth 100 -Compress) -ceq (ConvertTo-Json -InputObject $configured -Depth 100 -Compress)) '缺版本通知只补全 Type，保留 GUID、脚本和所有其它配置'
$second = (& $tool -Path $shortNoticeFile -PlanPath $planFile -CheckOnly | Out-String) | ConvertFrom-Json
Assert-ChainBehavior (-not $second.Changed) '缺版本通知修复后再次检查无变化'

$versionedNoticeConfig = Copy-ChainFixture $configured
$versionedNotice = @($versionedNoticeConfig[0].List | Where-Object { Test-KcpsWorkflowType $_ 'SimpleRaiseUserEventWorkflow' })[0]
$versionedNotice.Type = $versionedNotice.Type.Replace('Version=1.5.2.1', 'Version=1.6.0.2')
$versionedNoticeFile = Join-Path $testDirectory 'versioned-notice.conf.json'
Write-ChainFixture $versionedNoticeConfig $versionedNoticeFile
$versionedHash = (Get-FileHash -LiteralPath $versionedNoticeFile).Hash
$null = & $tool -Path $versionedNoticeFile -PlanPath $planFile
Assert-ChainBehavior ($versionedHash -eq (Get-FileHash -LiteralPath $versionedNoticeFile).Hash) '已有合法完整通知类型保留自己的版本'

# 每次接续都重新开始总控的首轮；启用士气等待时不得跳过该等待。
# 用已安装的链隔离这一项修复，并逐项保留原有等待目标、出击士气限制和安全停止条件。
foreach ($fleetWait in @($false, $true)) {
    foreach ($flagshipWait in @($false, $true)) {
        foreach ($skipFirst in @($null, $false, $true)) {
            $moraleConfig = Copy-ChainFixture $configured
            $moraleController = $moraleConfig[0].List[0]
            $moraleController.SleepUntilMoraleRecoveredFlag = $fleetWait
            $moraleController.SleepUntilMoraleRecoveredValueMorale = 49
            $moraleController.SleepUntilFlagShipMoraleRecoveredFlag = $flagshipWait
            $moraleController.SleepUntilFlagShipMoraleRecoveredValueMorale = 46
            if ($null -eq $skipFirst) { $moraleController.Remove('DoNotSleepAtFirstLoop') }
            else { $moraleController.DoNotSleepAtFirstLoop = $skipFirst }
            $moraleController.SleepTimeBase = '00:03:00'
            $moraleController.SleepTimeRandomMax = '00:00:30'
            $moraleController.StopIfLoopCountLargerOrEqualThanFlag = $true
            $moraleController.StopIfLoopCountLargerOrEqualThanValue = 10
            $moraleController.StopIfShipVacancyLessOrEqualThanFlag = $true
            $moraleController.StopIfShipVacancyLessOrEqualThanValue = 3
            $moraleSortie = $moraleConfig[0].List[1]
            $moraleSortie.FlagShipMoraleLargerOrEqualThanFlag = $true
            $moraleSortie.FlagShipMoraleLargerOrEqualThanValue = 49
            $moraleSortie.EscortShipMoraleLargerOrEqualThanFlag = $true
            $moraleSortie.EscortShipMoraleLargerOrEqualThanValue = 49
            $moraleSortie.EscortShipNoHeavilyDamaged = $true
            $expectedMoraleConfig = Copy-ChainFixture $moraleConfig
            $mustChange = ($fleetWait -or $flagshipWait) -and ($null -eq $skipFirst -or $skipFirst)
            if ($fleetWait -or $flagshipWait) { $expectedMoraleConfig[0].List[0].DoNotSleepAtFirstLoop = $false }
            $skipLabel = if ($null -eq $skipFirst) { 'default' } else { [string][int]$skipFirst }
            $label = "舰队等待=$fleetWait，旗舰等待=$flagshipWait，首轮跳过=$skipLabel"
            $moraleFile = Join-Path $testDirectory ("morale-{0}-{1}-{2}.conf.json" -f [int]$fleetWait, [int]$flagshipWait, $skipLabel)
            Write-ChainFixture $moraleConfig $moraleFile
            $moraleHash = (Get-FileHash -LiteralPath $moraleFile).Hash
            $preview = (& $tool -Path $moraleFile -PlanPath $planFile -CheckOnly | Out-String) | ConvertFrom-Json
            Assert-ChainBehavior ($preview.Changed -eq $mustChange -and $preview.ChangeCount -eq [int]$mustChange) "只修复已启用等待且跳过首轮的组合：$label"
            Assert-ChainBehavior ($moraleHash -eq (Get-FileHash -LiteralPath $moraleFile).Hash) "士气等待修复预览不写入：$label"
            $null = & $tool -Path $moraleFile -PlanPath $planFile
            Assert-ChainBehavior ((ConvertTo-Json -InputObject (Read-KcpsJson $moraleFile) -Depth 100 -Compress) -ceq (ConvertTo-Json -InputObject $expectedMoraleConfig -Depth 100 -Compress)) "仅修改首轮跳过开关，保留高士气、等待目标和安全条件：$label"
            $second = (& $tool -Path $moraleFile -PlanPath $planFile -CheckOnly | Out-String) | ConvertFrom-Json
            Assert-ChainBehavior (-not $second.Changed) "士气等待修复后再次检查无变化：$label"
        }
    }
}

foreach ($name in @('unknown script','modified managed script','unconditional trigger','implicit enabled trigger','automatic enable','self disable','implicit self disable','native Clear notice','native target mismatch','noninteger count','unknown metadata','event sea','unversioned controller')) {
    $badConfig = Copy-ChainFixture $fixture; $badPlan = Copy-ChainFixture $plan
    switch ($name) {
        'unknown script' { $badConfig[0].List[0].Script = 'def OnEvent(e): return True' }
        'modified managed script' { $badConfig[0].List[0].Script = $cases[0].ControllerScript + "`n# modified" }
        'unconditional trigger' { $badConfig[0].List[0].AutoStoppedTriggerWorkflows = @(@{Guid=$badConfig[0].List[2].Guid;Enabled=$true}) }
        'implicit enabled trigger' { $badConfig[0].List[0].AutoStoppedTriggerWorkflows = @(@{Guid=$badConfig[0].List[2].Guid}) }
        'automatic enable' { $badConfig[0].List[0].AutoStoppedEnableWorkflows = @(@{Guid=$badConfig[0].List[2].Guid;Enabled=$true}) }
        'self disable' { $badConfig[0].List[0].AutoStoppedDisableWorkflows[0].Guid = $badConfig[0].List[0].Guid }
        'implicit self disable' { $badConfig[0].List[0].AutoStoppedDisableWorkflows = @(@{Guid=$badConfig[0].List[0].Guid}) }
        'native Clear notice' { $badConfig[0].List += @{Type='SimpleRaiseUserEventWorkflow';Message='synthetic Clear'} }
        'native target mismatch' { $badConfig[0].List[0].StopIfBossBattleRankHigherOrEqualThanValueThreshold = 2 }
        'noninteger count' { $badPlan.Stages[0].Condition.Count = '1' }
        'unknown metadata' { $badPlan.Stages[0].Condition.Extra = $true }
        'event sea' { $badConfig[0].List[1].Sea = '0' }
        'unversioned controller' { $badConfig[0].List[0].Type = 'KancollePlayerSimulatorKai.RelationalSortieWorkflow, KancollePlayerSimulatorKai' }
    }
    Write-ChainFixture $badConfig $configFile; Write-ChainFixture $badPlan $planFile
    $hash = (Get-FileHash -LiteralPath $configFile).Hash
    Assert-ChainThrows { & $tool -Path $configFile -PlanPath $planFile } "拒绝 $name"
    Assert-ChainBehavior ($hash -eq (Get-FileHash -LiteralPath $configFile).Hash) "拒绝时不写入：$name"
}
$chainCases = $cases
if ($ConfigPath) {
    $chainCases = @(Get-KcpsGroups -Config (Read-KcpsJson $ConfigPath) | ForEach-Object { Get-ChainRuntimeCase $_ } | Sort-Object { $_.Metadata.StageIndex })
    $cases += $chainCases
}

# 显式提供运行库时，在独立进程中调用原生载入前的版本升级入口。
# 不创建 Host 或执行单元，不初始化配置，不启用任何监听，也不调用游戏接口。
# 与下方脚本行为模拟隔离，避免合成 CLR 类型遮蔽真实程序集。
$nativePreload = [pscustomobject]@{ Applied=$false; WorkflowsChecked=0; RejectedUnversionedNotice=$false }
if ($KcpsRuntimeDirectory) {
    $probePath = Join-Path $testDirectory 'native-preload-probe.ps1'
    $nativeFixturePath = Join-Path $testDirectory 'native-fixture.conf.json'
    Write-ChainFixture $configured $nativeFixturePath
    $probe = @'
#requires -Version 7.0
param([Parameter(Mandatory)][string]$RuntimeDirectory, [Parameter(Mandatory)][string]$FixturePath, [string]$ConfigPath)
$ErrorActionPreference = 'Stop'
$runtime = (Resolve-Path -LiteralPath $RuntimeDirectory).Path
foreach ($file in @('log4net.dll', 'KancollePlayerSimulatorKaiCore.dll')) {
    $null = [Reflection.Assembly]::LoadFrom((Join-Path $runtime $file))
}
$assembly = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'KancollePlayerSimulatorKaiCore' } | Select-Object -First 1
$type = $assembly.GetType('KancollePlayerSimulatorKaiCore.WorkflowUtility', $true)
$method = $type.GetMethod('UpgradeOldVersionConfiguration', [Reflection.BindingFlags]'NonPublic,Static')
if ($null -eq $method) { throw '此运行库没有可验证的原生版本升级入口。' }
$checked = 0; $counts = @()
$paths = @($FixturePath)
if ($ConfigPath) { $paths += $ConfigPath }
foreach ($path in $paths) {
    $groups = [Newtonsoft.Json.Linq.JArray]::Parse([IO.File]::ReadAllText($path))
    $fileCount = 0
    foreach ($group in $groups.Children()) {
        foreach ($workflow in $group['List'].Children()) {
            $null = $method.Invoke($null, [object[]](,$workflow))
            $checked++; $fileCount++
        }
    }
    $counts += $fileCount
}
$bad = [Newtonsoft.Json.Linq.JObject]::Parse('{"Type":"KancollePlayerSimulatorKai.SimpleRaiseUserEventWorkflow, KancollePlayerSimulatorKai"}')
$rejected = $false
try { $null = $method.Invoke($null, [object[]](,$bad)) }
catch {
    if ($_.Exception.InnerException.Message -notmatch '无法解析执行单元的版本') { throw }
    $rejected = $true
}
if (-not $rejected) { throw '原生预加载未能复现缺版本通知被拒绝的回归条件。' }
[pscustomobject]@{ Applied=$true; WorkflowsChecked=$checked; FileWorkflowCounts=$counts; RejectedUnversionedNotice=$rejected; RuntimeVersion=$assembly.GetName().Version.ToString() } | ConvertTo-Json -Depth 5
'@
    [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
    $probeArgs = @('-NoLogo','-NoProfile','-NonInteractive','-File',$probePath,'-RuntimeDirectory',$KcpsRuntimeDirectory,'-FixturePath',$nativeFixturePath)
    if ($ConfigPath) { $probeArgs += @('-ConfigPath',$ConfigPath) }
    $probeOutput = & (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) @probeArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "原生预加载回归失败：$($probeOutput -join [Environment]::NewLine)" }
    $nativePreload = ($probeOutput | Out-String) | ConvertFrom-Json
    Assert-ChainBehavior ($nativePreload.Applied -and $nativePreload.RejectedUnversionedNotice) '真实运行库拒绝缺版本通知，并接受生成配置中全部单元'
}

# 只加载解释器和合成类型，不加载应用程序集。
$existingUtility = 'KancollePlayerSimulatorKaiCore.Utility' -as [type]
$existingDouble = 'KcpsSortieChainTest.WorkflowDouble' -as [type]
if ($null -ne $existingUtility -and ($null -eq $existingDouble -or $existingUtility.Assembly -ne $existingDouble.Assembly)) {
    throw '请在未加载应用程序集的新 PowerShell 进程运行离线测试。'
}
foreach ($name in @('Microsoft.Scripting.dll', 'Microsoft.Dynamic.dll', 'IronPython.dll')) {
    $dll = Join-Path $IronPythonDirectory $name
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) { throw "缺少解释器依赖：$name" }
    Add-Type -Path $dll
}
if (-not ('KcpsSortieChainTest.WorkflowDouble' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Collections.Generic;
namespace KancollePlayerSimulatorKaiCore {
    public class UserEvent { public string Message; public UserEvent(string message) { Message = message; } }
    public static class Utility { public static List<UserEvent> Events = new List<UserEvent>(); public static void RaiseEvent(UserEvent e) { Events.Add(e); } }
}
namespace KcpsSortieChainTest {
    public class WorkflowDouble {
        public bool IsRunning, IsExecuting;
        public bool StopIfBossBattleRankHigherOrEqualThanFlag;
        public int StopIfBossBattleRankHigherOrEqualThanValueRank, StopIfBossBattleRankHigherOrEqualThanValueThreshold, StopIfBossBattleRankHigherOrEqualThanCount;
    }
}
'@
}
$engine = [IronPython.Hosting.Python]::CreateEngine()
$engine.Runtime.LoadAssembly([KcpsSortieChainTest.WorkflowDouble].Assembly)
$scope = $engine.CreateScope()
$scope.SetVariable('Cases', [object[]]$cases)
$scope.SetVariable('ChainCases', [object[]]$chainCases)
$engine.Execute('from KcpsSortieChainTest import WorkflowDouble', $scope) | Out-Null
$engine.Execute('from KancollePlayerSimulatorKaiCore import UserEvent as UserEventDouble, Utility as UtilityDouble', $scope) | Out-Null
try {
    $engine.Execute((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'test_sortie_chain_runtime.py') -Raw), $scope) | Out-Null
} catch {
    $formatter = $engine.GetService[Microsoft.Scripting.Hosting.ExceptionOperations]()
    throw $formatter.FormatException($_.Exception.InnerException)
}
$runtimeChecks = [int]$scope.GetVariable('checks')
[pscustomobject]@{ ToolChecks=$checks; RuntimeChecks=$runtimeChecks; NativePreload=$nativePreload; Engine=[IronPython.Hosting.Python]::GetSysModule($engine).GetVariable('version'); ChainStages=$chainCases.Count; WorkDirectory=$testDirectory } | ConvertTo-Json -Depth 5

