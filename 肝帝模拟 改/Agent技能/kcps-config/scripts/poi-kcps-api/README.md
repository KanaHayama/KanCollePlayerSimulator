# KCPS 配置辅助工具

本目录提供 KCPS 任务配置工作中可重复使用的检查、规范化和校验脚本。这些脚本不会独立设计并生成完整的任务配置。

## 连接设置与路线输入

本机连接、安装设置和账号路线方案由本次明确选择的私人文件提供。使用已指定工作区时，工具约定的默认位置分别为 `<WORKSPACE_ROOT>/.work/kcps.local.json` 和 `<WORKSPACE_ROOT>/.work/route-overrides.json`。脚本通过 `KCPS-Connection.ps1` 解析设置；`Read-KcpsJson` 将公共路线规则与私人方案合并。工具未预置任务路线，当前任务方案由运行时文件提供。公共通常地图节点记录仅作待核对参考，来源 URL 不代表已完成当前版本核验，不能代替本次路线校验。完整字段与加载规则见 [运行时计划与证据](../../references/运行时计划与证据.md)。

## 使用示例

以下示例从本 `scripts/poi-kcps-api` 目录运行。先将 `KCPS_WORKSPACE` 设置为用户明确选定的工作区绝对路径，或通过 `KCPS_SETTINGS_PATH` 指定本次设置文件。Skill 的统一入口是 [SKILL.md](../../SKILL.md)。没有显式设置路径和工作区时，连接工具不读取周边文件。需要默认输出位置的工具要求明确工作区；已显式传入的输出路径可以位于 Skill 之外的任意选定位置。

```powershell
# 从 poi API 查询当前任务、舰队和舰船状态。
pwsh -ExecutionPolicy Bypass -File .\inspect\KCPS-State.ps1 -ShipIds <SHIP_ID> -QuestIds <QUEST_ID>

# 按装备名称检查库存。
pwsh -ExecutionPolicy Bypass -File .\inspect\KCPS-State.ps1 -EquipNames 'HF/DF + Type144/147 ASDIC','Hedgehog(初期型)'

# 从 default.json 查找出击执行单元。
pwsh -ExecutionPolicy Bypass -File .\inspect\KCPS-FindSortie.ps1 -Sea 1 -Area 5

# 校验已生成的配置，默认要求提供路线规格。
pwsh -ExecutionPolicy Bypass -File .\validate\KCPS-ValidateConfig.ps1 -Path '<WORKSPACE_ROOT>\<JST_YYYYMMDD> 单次 出击 <任务名称>.conf.json'

# 检查主力、护卫和动态支援舰队按顺序改装时的装备分配与消耗。
pwsh -ExecutionPolicy Bypass -File .\validate\KCPS-AuditRefitEquipmentCapacity.ps1 -Path '<WORKSPACE_ROOT>\<JST_YYYYMMDD> 单次 出击 <任务名称>.conf.json' -FailOnProblems
pwsh -ExecutionPolicy Bypass -File .\validate\KCPS-AuditRefitEquipmentCapacity.ps1 -Path '<WORKSPACE_ROOT>' -FailOnProblems

# 对照备注、身份检查器和路线规格，检查陆航行动及每个槽位。
pwsh -ExecutionPolicy Bypass -File .\validate\KCPS-AuditLandBasePlanConsistency.ps1 -Path '<WORKSPACE_ROOT>' -FailOnProblems
pwsh -ExecutionPolicy Bypass -File .\validate\KCPS-AuditLandBaseEquipmentCapacity.ps1 -Path '<WORKSPACE_ROOT>' -FailOnProblems

# 同文件普通海域 Boss 评级任务按本次显式计划接续，先检查再应用。
pwsh -ExecutionPolicy Bypass -File .\enable\KCPS-EnableSortieChain.ps1 -Path '<CONFIG_PATH>' -PlanPath '<CHAIN_PLAN_PATH>' -CheckOnly
pwsh -ExecutionPolicy Bypass -File .\enable\KCPS-EnableSortieChain.ps1 -Path '<CONFIG_PATH>' -PlanPath '<CHAIN_PLAN_PATH>'

# 应用全部确定性的出击收尾处理，再运行第二轮检查，确认重复处理不会继续修改配置。
pwsh -ExecutionPolicy Bypass -File .\validate\KCPS-FinalizeSortieConfig.ps1 -Path '<WORKSPACE_ROOT>\<JST_YYYYMMDD> 单次 出击 <任务名称>.conf.json'
pwsh -ExecutionPolicy Bypass -File .\validate\KCPS-FinalizeSortieConfig.ps1 -Path '<WORKSPACE_ROOT>\<JST_YYYYMMDD> 单次 出击 <任务名称>.conf.json' -CheckOnly

# 用当前 poi/KCPS 任务 API 核对任务 api_no。
pwsh -ExecutionPolicy Bypass -File .\validate\KCPS-ValidateQuestIds.ps1 -Path '<WORKSPACE_ROOT>\<JST_YYYYMMDD> 单次 出击 <任务名称>.conf.json'

# 应用共用规范化工具并校验演习配置，再确认重复处理不会继续修改配置。
pwsh -ExecutionPolicy Bypass -File .\validate\KCPS-FinalizeExerciseConfig.ps1 -Path '<WORKSPACE_ROOT>\<JST_YYYYMMDD> 单次 演习 <任务名称>.conf.json'
pwsh -ExecutionPolicy Bypass -File .\validate\KCPS-FinalizeExerciseConfig.ps1 -Path '<WORKSPACE_ROOT>\<JST_YYYYMMDD> 单次 演习 <任务名称>.conf.json' -CheckOnly

# 应用共用规范化工具并校验纯编成任务配置。
pwsh -ExecutionPolicy Bypass -File .\validate\KCPS-FinalizeFormationConfig.ps1 -Path '<WORKSPACE_ROOT>\<JST_YYYYMMDD> 单次 编成 <任务名称>.conf.json'
pwsh -ExecutionPolicy Bypass -File .\validate\KCPS-FinalizeFormationConfig.ps1 -Path '<WORKSPACE_ROOT>\<JST_YYYYMMDD> 单次 编成 <任务名称>.conf.json' -CheckOnly

# 递归检查 WORKSPACE_ROOT 下各配置的 JST 日期、频次和中文任务类型命名。
pwsh -ExecutionPolicy Bypass -File .\validate\KCPS-ValidateNaming.ps1 -Path '<WORKSPACE_ROOT>'

# 规范化出击战斗策略中可由机器检查的规则。
pwsh -ExecutionPolicy Bypass -File .\normalize\KCPS-NormalizeSortieStrategyRules.ps1 -Path '<WORKSPACE_ROOT>\<JST_YYYYMMDD> 单次 出击 <任务名称>.conf.json'

# 统一备注换行、章节间距，以及陆航和舰队内容之间的分段。
pwsh -ExecutionPolicy Bypass -File .\normalize\KCPS-NormalizeMemoParagraphs.ps1 -Path '<WORKSPACE_ROOT>' -CheckOnly
pwsh -ExecutionPolicy Bypass -File .\normalize\KCPS-NormalizeMemoParagraphs.ps1 -Path '<WORKSPACE_ROOT>'

# 将同一活动推进阶段的独立配置合并到一个配置文件。
# 按配置在 KCPS 中应显示的顺序传入源文件；使用 -RemoveSource 前先完成校验。
pwsh -ExecutionPolicy Bypass -File .\normalize\KCPS-MergeEventStageConfigs.ps1 -Path '<TARGET_A>','<TARGET_B>' -OutputPath '<EVENT_ROOT>\E<区域> P<阶段> 开路 第<批次>阶段.conf.json'

# 报告拟进行的规范化修改，以及仍缺少地图点策略的出击配置。
pwsh -ExecutionPolicy Bypass -File .\normalize\KCPS-NormalizeSortieStrategyRules.ps1 -Path '<WORKSPACE_ROOT>\<JST_YYYYMMDD> 单次 出击 <任务名称>.conf.json' -CheckOnly

# 为通常海域的编成位置补充改造形态相同的等价舰船，以便按疲劳状态轮换。
# 活动海域和贴条海域会跳过，并在结果中报告。
pwsh -ExecutionPolicy Bypass -File .\enable\KCPS-EnableEquivalentShipRotation.ps1 -Path '<WORKSPACE_ROOT>' -CheckOnly
pwsh -ExecutionPolicy Bypass -File .\enable\KCPS-EnableEquivalentShipRotation.ps1 -Path '<WORKSPACE_ROOT>'

# 为出击后疲劳且受损的舰船添加或修复扔桶入渠流程。
pwsh -ExecutionPolicy Bypass -File .\enable\KCPS-EnablePostSortieBucketDocking.ps1 -Path '<WORKSPACE_ROOT>' -CheckOnly
pwsh -ExecutionPolicy Bypass -File .\enable\KCPS-EnablePostSortieBucketDocking.ps1 -Path '<WORKSPACE_ROOT>'

# 为本次使用的陆航添加或修复出击后的休息和补给流程。
pwsh -ExecutionPolicy Bypass -File .\enable\KCPS-EnablePostSortieLandBaseRest.ps1 -Path '<WORKSPACE_ROOT>' -CheckOnly
pwsh -ExecutionPolicy Bypass -File .\enable\KCPS-EnablePostSortieLandBaseRest.ps1 -Path '<WORKSPACE_ROOT>'

# 添加或更新仅用于活动海域的出击前舰船和陆航身份检查器。
# Single 检查配置指定的出击舰队；Combined 检查第一、第二舰队。
# 陆航 JSON 只包含行动设为出击或防空的队。
pwsh -ExecutionPolicy Bypass -File .\enable\KCPS-SetSortieFleetLandBaseChecker.ps1 -Path '<EVENT_CONFIG>' -FleetMode Single -LandBasedAirCorpsSpecJson '{"1":[{"Id":1,"Name":"slot1"},{"Id":2,"Name":"slot2"},{"Id":3,"Name":"slot3"},{"Id":4,"Name":"slot4"}]}' -LandBasedAirCorpsSea 0 -CheckOnly

# 将每个配置中的“说明”执行单元移到首位，保留其他执行单元的相对顺序。
pwsh -ExecutionPolicy Bypass -File .\normalize\KCPS-NormalizeWorkflowOrder.ps1 -Path '<WORKSPACE_ROOT>' -CheckOnly
pwsh -ExecutionPolicy Bypass -File .\normalize\KCPS-NormalizeWorkflowOrder.ps1 -Path '<WORKSPACE_ROOT>'
```

## 出击配置指南

- 生成、修复或审计出击任务配置前，先阅读 `..\..\references\通常出击配置.md`。
- `KCPS-FinalizeSortieConfig.ps1` 串联已有的专项规范化和增强工具，并要求第二轮检查不再发现待修改项。它不负责设计舰队、路线、配装、阵型或制空方案。
- `KCPS-EnableSortieChain.ps1` 根据显式计划，为同文件普通海域安装总控统计转发与独立 `出击完成` 通知；通知单元判断 Boss 评级次数目标，下一阶段只监听完成消息。未达标的安全停止不发送完成消息。总校验同时检查整条链和通知是否完整。计划字段、独立启动声明及能力边界见 [跨海域接续](../../references/跨海域接续.md)。
- `KCPS-ValidateConfig.ps1` 支持包含多个配置的文件，拒绝文件内重复的配置名和执行单元 GUID，并检查战斗策略，包括默认策略、Boss 专用策略禁用时的手动回退规则、地图点条件策略、空袭点手动夜战例外、KCPS 尚未实现的条件夜战取值、护卫舰队大破白名单说明、`KCPS-RouteSpecs.json` 中的路线节点覆盖，以及备注中明确未核实的任务、路线或关键执行条件。方案取舍按本次目标与资源预算判断，不因采用较低成本装备或非最高火力方案而拒绝。`-AllowMissingRouteSpec` 只用于检查历史旧配置，不得用于新任务配置。
- `KCPS-AuditRefitEquipmentCapacity.ps1` 读取实时装备总库存，模拟 KCPS 对固定出击舰队和脚本选出的支援舰队按候选顺序选取装备的过程。它会报告具体缺口，以及轮到后续槽位时已无可用候选装备的情况；远征造成的临时装备占用另在运行时诊断。
- `KCPS-AuditLandBasePlanConsistency.ps1` 递归检查每组受管陆航，核对 `【陆航】` 备注、活动身份检查器和 `KCPS-RouteSpecs.json` 中的行动及全部四个槽位。刷熟练辅助配置只有通过 `# KCPS_DYNAMIC_LAND_BASE_PLAN <reason>` 声明理由后，才可采用动态四槽方案；其他活动陆航配置若没有固定检查器或路线规格方案，均无法通过审计。
- `KCPS-ValidateEventSortieConfig.ps1` 还需要 私人 `route-overrides.json` 中的 `LandBasedAirCorpsTargetRadii`。它使用日文 Wiki 独立佐证的目标点和所需航程，逐队比对备注、路线规格、身份检查器及计算出的有效航程，防止多个本地字段互相复制同一个错误距离后仍通过校验。
- `KCPS-AuditLandBaseEquipmentCapacity.ps1` 按准确的飞机主数据 ID，统计每个配置中出击和防空陆航同时需要的飞机数量，拒绝需求超过账号总库存的方案。这样可以发现备注、检查器和路线规格虽然一致，但实际无法配齐装备的配置。
- 活动配置按推进阶段分别保存文件，命名为 `E# P# 开路[ 第#阶段].conf.json` 或 `E# P# 攻略.conf.json`。各个独立目标在文件内仍保持为独立配置。`KCPS-MergeEventStageConfigs.ps1` 只合并顶层文件结构，并拒绝重复的配置名或执行单元 GUID。
- `KCPS-ValidateQuestIds.ps1` 用实时游戏任务 API 检查接任务条目；无法确认游戏 `api_no` 或标题的任务，不得用于生成出击配置。
- `KCPS-NormalizeSortieStrategyRules.ps1` 强制落实出击战斗策略中可由机器检查的规则：默认策略保持手动、关闭 Boss 专用策略勾选，并报告非地图点条件策略、缺失策略或不安全的条件策略。
- `KCPS-NormalizeMemoParagraphs.ps1` 使用 LF 换行符，在备注章节之间、`【陆航】` 中不同陆航队之间，以及 `【选船结论】` 或 `【配装对照】` 中不同舰队之间，保留恰好一个空行。活动校验会拒绝这些分段边界被破坏的配置。
- `KCPS-EnableEquivalentShipRotation.ps1` 读取 poi 实时舰船数据，仅为通常海域的编成位置追加改造形态、补强槽开放状态及搭载扩张状态（`api_onslot_max`）相同的舰船 ID；同时为编成前的疲劳恢复重试设置 180 秒间隔及相应限制。
- `KCPS-EnablePostSortieBucketDocking.ps1` 添加或修复出击后的 `扔桶` 执行单元，类型为 `BasicDockingWorkflow`，将其关联到 `DockingAfterWorkflows`，并确保出击总控自动停止时禁用所有入渠执行单元。
- `KCPS-EnablePostSortieLandBaseRest.ps1` 为行动设为出击或防空的陆航添加或修复编号为 `陆航休息1/2/3` 的 `BasicOutfitLandBasedAirCorpWorkflow` 执行单元，将其关联到 `SupplyAfterWorkflows`，并使 `SupplyAfterFinishedEventThreshold` 只统计实际补给执行单元。
- `KCPS-SetSortieFleetLandBaseChecker.ps1` 仅用于活动海域。它从指定的单支出击舰队或联合舰队的第一、第二舰队提取待检查的舰船 ID，并根据出击或防空行动确定待检查的陆航队；内嵌 Python 不会把检查对象写死为第一舰队或第一陆航队。
- `KCPS-NormalizeWorkflowOrder.ps1` 将每个配置中的 `说明` 执行单元移到首位，保留其他执行单元的相对顺序。

## 演习配置指南

- 生成、修复或审计演习任务配置前，先阅读 `..\..\references\演习配置.md`。
- 演习与出击流程共用本工具目录中的库存、任务 ID、集合规范化、执行单元排序、适重审计和通用校验工具。
- `KCPS-FinalizeExerciseConfig.ps1` 复用共用规范化和校验工具，增加 `KCPS-ValidateExerciseConfig.ps1`，并要求第二轮 `-CheckOnly` 检查无待修改项。
- 演习校验会拒绝出击执行单元、加载或启用时立即触发、不安全的任务选择器标志、缺少六个舰队位置的改装配置，以及 KCPS 当前存在问题的战斗评级自动停止选项。

## 编成配置指南

- 生成、修复或审计纯编成任务配置前，先阅读 `..\..\references\编成配置.md`。
- 编成、演习和出击流程共用本工具目录。必须根据完整任务详情分类；纯编成任务不得借用演习或出击总控。
- `KCPS-FinalizeFormationConfig.ps1` 复用共用的集合、执行单元顺序、通用结构和任务 ID 检查，再应用 `KCPS-ValidateFormationConfig.ps1`。
- 编成校验要求恰好包含 `说明`、`接任务` 和 `编成`，并拒绝演习、出击、远征、改装、补给和入渠执行单元。

## 运行时计划

任务条件、路线与阶段、编成配装、舰船实例、练级选择和支援角色由本次计划提供；必需输入缺失时报告缺项。来源和核对日期随私人证据保存。

- 出击路线、Boss 阶段、分歧与航程：[运行时计划与证据](../../references/运行时计划与证据.md)。
- 远征快照、计划评估和链式配置：[远征配置](../../references/远征配置.md)，通用脚本位于相邻 `../expedition/`。
- 可选的航次概率分析及实际支持边界：[活动出击达成率分析](../../references/活动出击达成率分析.md)。

舰船顺序审计 `inspect/KCPS-AuditFleetOrder.ps1` 需要本次固定前缀船数 `-FixedPrefixCount`，或私人 `-OrderPolicyPath`，形状为 `{Groups:{配置名:{FixedPrefixCount:n}}}`。固定船数由显式输入决定。动态反潜支援的离线输入可通过 `-SnapshotPath` 提供，字段和选船策略见活动规则；缺少必要方案时报告缺项。
