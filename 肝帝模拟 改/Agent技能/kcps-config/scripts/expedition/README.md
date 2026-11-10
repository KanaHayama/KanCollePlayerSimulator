# 通用远征工具

这些工具根据本次任务的明确输入查询状态、查找现有模板、推荐下一项远征并生成有限次数的远征链。任务、远征顺序、舰队及次数均来自运行时计划，目录中不附带具体活动的任务表或账号进度。

完整流程和输入格式见 [远征配置](../../references/远征配置.md)。统一入口见 [SKILL.md](../../SKILL.md)。

| 文件 | 用途 |
| --- | --- |
| `Get-KCPSExpeditionSnapshot.ps1` | 按输入计划只读查询当前舰队、任务及远征开放状态；支持离线原始快照 |
| `Find-KCPSDefaultExpeditionTemplate.ps1` | 从用户提供的 KCPS 配置中查找远征模板，保留编成、配装和检查器信息 |
| `Get-KCPSNextExpedition.ps1` | 按计划、明确的已完成次数和当前快照推荐候选；不修改进度或派遣舰队 |
| `New-KCPSExpeditionChain.ps1` | 复制匹配步骤的完整模板，重建 GUID，按输入次数和顺序串联 |
| `KCPS-ExpeditionCommon.ps1` | 通用计划读取、快照检查、对象复制与私人输出保护 |
| `data/expedition-plan.schema.json` | 通用计划结构，不含具体游戏任务 |

连接复用 `../poi-kcps-api/KCPS-Connection.ps1`。私人计划、完成记录、模板来源、快照和生成结果的路径均由调用方明确传入，并位于公开 Skill 之外。工具不会自动接受任务、派遣舰队、提交任务或选择奖励。
