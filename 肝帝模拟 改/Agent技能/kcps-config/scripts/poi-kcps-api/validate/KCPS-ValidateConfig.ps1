#requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [string]$BaseUrl = '',

    [string]$SnapshotPath,

    [string]$SortieChainPolicyPath,

    [switch]$AllowConsumables,

    [switch]$AllowRepeatedFleetUtilityEquipment,

    [switch]$RequireRouteSpec,

    [switch]$AllowMissingRouteSpec,

    [switch]$FailOnProblems
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"
. "$PSScriptRoot\KCPS-LevelingValidation.ps1"
. "$PSScriptRoot\KCPS-SortieChainValidation.ps1"

function Get-KcpsWorkflowTypeLoadProblems {
    param([object[]]$Workflows)

    foreach ($workflow in @($Workflows)) {
        $type = $workflow['Type']
        $problem = $null
        if ($type -isnot [string] -or [string]::IsNullOrWhiteSpace($type)) {
            $problem = 'Type 必须是含程序集版本的非空类型字符串；KCPS 无法载入缺失类型的执行单元。'
        } else {
            # 对齐 KCPS UpgradeOldVersionConfiguration 的版本门槛；大小写、逗号及版本解析均沿用原生规则。
            # 这里只检查载入格式，不加载本机程序集，也不要求配置版本等于本机版本。
            $match = [regex]::Match($type, 'Version=([\d\.]+),')
            $version = $null
            if (-not $match.Success) {
                $problem = 'Type 缺少原生载入器可识别的 Version=数字版本, 字段；程序集名称的简写形式会使该执行单元被跳过。'
            } elseif (-not [version]::TryParse($match.Groups[1].Value, [ref]$version)) {
                $problem = 'Type 的 Version 字段无法解析为 System.Version；KCPS 会跳过该执行单元。'
            }
        }
        if ($problem) {
            [pscustomobject]@{ Workflow = $workflow['Name']; Key = 'Type'; Type = $type; Problem = $problem }
        }
    }
}

$workflowRefCollectionKeys = @(
    'SubroutineBeforeWorkflows',
    'SubroutineAfterWorkflows',
    'QuestBeforeWorkflows',
    'QuestAfterWorkflows',
    'OrganizeBeforeWorkflows',
    'OrganizeAfterWorkflows',
    'RefitEquipmentBeforeWorkflows',
    'RefitEquipmentAfterWorkflows',
    'ScrapShipBeforeWorkflows',
    'ScrapShipAfterWorkflows',
    'DockingBeforeWorkflows',
    'DockingAfterWorkflows',
    'SupplyBeforeWorkflows',
    'SupplyAfterWorkflows',
    'ResupplyBeforeWorkflows',
    'ResupplyAfterWorkflows',
    'BeforeLoopsEnableWorkflows',
    'BeforeLoopsDisableWorkflows',
    'BeforeLoopsTriggerWorkflows',
    'AutoStoppedEnableWorkflows',
    'AutoStoppedDisableWorkflows',
    'AutoStoppedTriggerWorkflows'
)

function Get-WorkflowRefShapeProblems {
    param(
        [hashtable]$Workflow,
        [string[]]$Keys
    )

    $problems = @()
    foreach ($key in $Keys) {
        if (-not $Workflow.ContainsKey($key)) { continue }
        $value = $Workflow[$key]
        if ($null -eq $value) { continue }
        if ($value -is [hashtable]) {
            $problems += [pscustomobject]@{
                Workflow = $Workflow['Name']
                Key = $key
                Problem = 'Related workflow collection must be a JSON array; a single object crashes KCPS deserialization.'
            }
        }
    }
    $problems
}

function Get-KcpsJsonCollectionShapeProblems {
    param(
        [object]$Node,
        [string]$WorkflowName,
        [string]$Path
    )

    $problems = @()
    if ($Node -is [hashtable]) {
        $currentWorkflowName = $WorkflowName
        if ($Node.ContainsKey('Name')) {
            $currentWorkflowName = [string]$Node['Name']
        }

        foreach ($key in @($Node.Keys)) {
            $value = $Node[$key]
            $childPath = if ($Path) { "$Path.$key" } else { [string]$key }
            if (($script:KcpsJsonCollectionKeys -contains [string]$key) -and $null -ne $value -and ($value -is [hashtable])) {
                $problems += [pscustomobject]@{
                    Workflow = $currentWorkflowName
                    Key = [string]$key
                    Path = $childPath
                    Problem = 'KCPS ObservableCollection field must be a JSON array even when it has one item; a single object crashes KCPS deserialization.'
                }
            }
            $problems += Get-KcpsJsonCollectionShapeProblems -Node $value -WorkflowName $currentWorkflowName -Path $childPath
        }
    } elseif (Test-KcpsArrayLike -Value $Node) {
        $index = 0
        foreach ($item in @($Node)) {
            $problems += Get-KcpsJsonCollectionShapeProblems -Node $item -WorkflowName $WorkflowName -Path "$Path[$index]"
            $index++
        }
    }
    $problems
}

function Test-KcpsShipExtraSlotAvailable {
    param([hashtable]$Ship)

    # 补强增设「可用(已开孔)」的按游戏数据字段判断：
    # api_slot_ex == 0 → 未开孔(不可用); != 0 → 已开孔(可用)。
    # 其中 -1 = 已开孔但空着(可用!), >0 = 已开孔且已装该 id 的装备(可用)。
    # 切勿用 >0 判定——会把 -1(开孔空着)误判成不可用。
    if ($null -eq $Ship -or -not $Ship.ContainsKey('api_slot_ex')) { return $false }
    return ([int]$Ship['api_slot_ex'] -ne 0)
}

function Get-WorkflowRefs {
    param(
        [hashtable]$Workflow,
        [string[]]$Keys
    )

    $result = @()
    foreach ($key in $Keys) {
        if (-not $Workflow.ContainsKey($key)) { continue }
        $value = $Workflow[$key]
        if ($null -eq $value) { continue }
        if ($value -is [array]) {
            foreach ($ref in $value) {
                if ($null -ne $ref -and $ref.ContainsKey('Guid')) {
                    $result += [pscustomobject]@{
                        Workflow = $Workflow['Name']
                        Key = $key
                        Guid = $ref['Guid']
                        DisplayName = $ref['DisplayName']
                        Enabled = $ref['Enabled']
                        IgnoreTriggerFailure = $ref['IgnoreTriggerFailure']
                    }
                }
            }
        } elseif ($value -is [hashtable] -and $value.ContainsKey('Guid')) {
            $result += [pscustomobject]@{
                Workflow = $Workflow['Name']
                Key = $key
                Guid = $value['Guid']
                DisplayName = $value['DisplayName']
                Enabled = $value['Enabled']
                IgnoreTriggerFailure = $value['IgnoreTriggerFailure']
            }
        }
    }
    $result
}

function Get-NameFromEnumValue {
    param(
        [hashtable]$Map,
        [object]$Value
    )
    $key = [string]$Value
    if ($Map.ContainsKey($key)) { return $Map[$key] }
    return "Unknown($Value)"
}

$formationNames = @{
    '0' = 'Manual'
    '1' = 'LineAhead'
    '2' = 'DoubleLine'
    '3' = 'Diamond'
    '4' = 'Echelon'
    '5' = 'LineAbreast'
    '6' = 'Alert'
    '7' = 'Refresh'
}
$midnightNames = @{
    '0' = 'Manual'
    '1' = 'StopPursuit'
    '2' = 'NightAttack'
    '3' = 'StopIfEnemyFlagShipSunk_UNIMPLEMENTED'
    '4' = 'StopIfEnemyOnlySubmarinesRemained_UNIMPLEMENTED'
    '5' = 'StopIfRankA_UNIMPLEMENTED'
    '6' = 'StopIfRankAB_UNIMPLEMENTED'
    '7' = 'AttackIfAnyShipHeavilyDamaged_UNIMPLEMENTED'
}
$advanceNames = @{
    '0' = 'Manual'
    '1' = 'Advance'
    '2' = 'Retreat'
}

$hardcodedRuleRegistry = @(
    @{
        Id = 'kcps-battle-strategy-enums'
        Scope = 'KCPS strategy enum values'
        Source = '工具接口约束：本校验器使用的阵型、夜战与进退枚举映射；目标 KCPS 版本兼容性需验证。'
        VerificationStatus = 'RequiresValidation'
        LastVerifiedJst = $null
        RefreshAfterDays = 180
        Risk = 'KCPS enum or UI mapping changes can invalidate formation/night/advance validation.'
    },
    @{
        Id = 'kcps-unimplemented-midnight-values'
        Scope = 'DefaultMidnight 3..7'
        Source = '工具接口假设：本校验器将 DefaultMidnight 3..7 视为未支持；目标 KCPS 版本的实现情况需验证。'
        VerificationStatus = 'RequiresValidation'
        LastVerifiedJst = $null
        RefreshAfterDays = 90
        Risk = 'If KCPS implements these values later, warnings may become too conservative.'
    },
    @{
        Id = 'airraid-vs-airbattle-node-semantics'
        Scope = '空襲戦/LongDistanceAirBattle versus old 航空戦マス/AirBattle'
        Source = '工具接口假设：本校验器区分空袭战与航空战的夜战选择；具体节点类别和目标 KCPS 版本行为需验证。'
        VerificationStatus = 'RequiresValidation'
        LastVerifiedJst = $null
        RefreshAfterDays = 90
        Risk = 'Modern 空襲戦 has no night-battle choice and should keep DefaultMidnight=0, while old 航空戦マス has a night-battle choice and must use StopPursuit/NightAttack. Confusing them can pause automation or choose a wrong night-battle action.'
    },
    @{
        Id = 'slot-ex-api-contract'
        Scope = 'api_mst_equip_exslot/api_mst_equip_exslot_ship compatibility validation'
        Source = '工具接口约束：按本次输入的 api_mst_equip_exslot/api_mst_equip_exslot_ship 判断装备兼容性；API 字段语义需与目标版本核对。'
        VerificationStatus = 'RequiresValidation'
        LastVerifiedJst = $null
        RefreshAfterDays = 90
        Risk = 'Mostly data-driven, but API schema changes would require script updates.'
    },
    @{
        Id = 'equivalent-ship-fatigue-rotation-normal-map-only'
        Scope = 'Organize multi-candidate fatigue rotation Sea=1..7 only'
        Source = '工具安全约束：当前实现仅允许通常海域使用同型舰多候选轮换；此限制不作为活动锁船机制的证据。'
        VerificationStatus = 'RequiresValidation'
        LastVerifiedJst = $null
        RefreshAfterDays = 30
        Risk = 'If tag-lock semantics or event-map Sea numbering changes, rotation tooling must be refreshed before generating event configs.'
    },
    @{
        Id = 'post-sortie-bucket-docking-fatigue-recovery'
        Scope = 'BasicDockingWorkflow named 扔桶 after sortie'
        Source = '工具接口约束：出击后入渠工作流的触发关系与修复参数须一致；目标 KCPS 版本行为需验证。'
        VerificationStatus = 'RequiresValidation'
        LastVerifiedJst = $null
        RefreshAfterDays = 90
        Risk = 'If KCPS docking workflow loop or ForceDocking semantics change, post-sortie fatigue recovery configs may hang or spend unintended buckets.'
    },
    @{
        Id = 'post-sortie-land-base-rest'
        Scope = 'BasicOutfitLandBasedAirCorpWorkflow named 陆航休息N after sortie'
        Source = '工具接口约束：陆航休息工作流通过出击后的补给阶段触发，并使用对应事件计数规则；目标 KCPS 版本行为需验证。'
        VerificationStatus = 'RequiresValidation'
        LastVerifiedJst = $null
        RefreshAfterDays = 90
        Risk = 'If KCPS adds a dedicated land-base post-sortie phase or changes OutfitLandBasedAirCorpFinishedEvent routing, SupplyAfter threshold rules must be refreshed.'
    },
    @{
        Id = 'sortie-route-spec-required-by-default'
        Scope = 'Sortie configs must have current runtime route-spec coverage'
        Source = '工具完整性约束：每个声明的路线节点必须有匹配策略，并由本次运行的路线证据支持。'
        VerificationStatus = 'RequiresValidation'
        LastVerifiedJst = $null
        RefreshAfterDays = 90
        Risk = 'If route-spec coverage is skipped for new configs, missing map-point strategies can leave KCPS at battle/advance choices or make it rely on unsafe fallback behavior.'
    },
    @{
        Id = 'map-1-6-completion-stop-condition'
        Scope = '1-6 escort-success/N-arrival tasks using Sortie_Map16_Clear'
        Source = '工具接口假设：Sortie_Map16_Clear 不计入 ArrivedEndPoint，当前校验器据此要求相应停止条件；目标 KCPS 版本行为需验证。'
        VerificationStatus = 'RequiresValidation'
        LastVerifiedJst = $null
        RefreshAfterDays = 90
        Risk = 'If KCPS later starts counting Sortie_Map16_Clear as ArrivedEndPoint, route specs using last-battle point-rank completion should be reviewed and possibly simplified.'
    },
    @{
        Id = 'memo-quality-evidence-consistency'
        Scope = 'MemoWorkflow evidence, completion-condition and equipment-role consistency'
        Source = '工具说明质量约束：拒绝未核验节点、与完成计数假设冲突及装备职责错配的说明；允许明确目标和资源条件下的取舍。'
        VerificationStatus = 'RequiresValidation'
        LastVerifiedJst = $null
        RefreshAfterDays = 90
        Risk = 'This is a quality gate, not game data; refresh wording patterns when new failure modes appear.'
    }
)

function Get-JstNow {
    try {
        return [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([System.DateTimeOffset]::UtcNow, 'Tokyo Standard Time')
    } catch {
        return [System.DateTimeOffset]::UtcNow.ToOffset([System.TimeSpan]::FromHours(9))
    }
}

function Get-KcpsHardcodedRuleFreshness {
    param([object[]]$Rules)

    $now = Get-JstNow
    $warnings = @()
    $rulesOut = @()
    foreach ($rule in @($Rules)) {
        $ageDays = $null
        $hasVerificationDate = -not [string]::IsNullOrWhiteSpace([string]$rule['LastVerifiedJst'])
        $requiresValidation = $rule['VerificationStatus'] -eq 'RequiresValidation' -or -not $hasVerificationDate
        if ($hasVerificationDate) {
            $lastVerified = [datetimeoffset]::Parse([string]$rule['LastVerifiedJst'])
            if ($lastVerified.Offset -eq [TimeSpan]::Zero) {
                $lastVerified = [datetimeoffset]::new($lastVerified.DateTime, [TimeSpan]::FromHours(9))
            }
            $ageDays = [int][Math]::Floor(($now - $lastVerified).TotalDays)
        }
        $refreshAfterDays = [int]$rule['RefreshAfterDays']
        $entry = [pscustomobject]@{
            Id = $rule['Id']
            Scope = $rule['Scope']
            Source = $rule['Source']
            VerificationStatus = if ($requiresValidation) { 'RequiresValidation' } else { 'DatedVerification' }
            LastVerifiedJst = $rule['LastVerifiedJst']
            AgeDays = $ageDays
            RefreshAfterDays = $refreshAfterDays
            Risk = $rule['Risk']
        }
        $rulesOut += $entry
        if ($requiresValidation -or $ageDays -ge $refreshAfterDays) {
            $warnings += [pscustomobject]@{
                Id = $rule['Id']
                Scope = $rule['Scope']
                AgeDays = $ageDays
                RefreshAfterDays = $refreshAfterDays
                Warning = if ($requiresValidation) {
                    '工具接口约束或兼容性假设尚未记录目标版本核验；使用前应核对相应接口或公开机制证据。'
                } else {
                    'Hardcoded or heuristic validation rule is stale; refresh against current wikiwiki/TsunKit/poi/KCPS API before relying on it.'
                }
                Risk = $rule['Risk']
            }
        }
    }

    [pscustomobject]@{
        NowJst = $now.ToString('yyyy-MM-dd HH:mm:ss zzz')
        Rules = @($rulesOut)
        Warnings = @($warnings)
    }
}

function Read-KcpsRouteSpecs {
    param([string]$SpecPath)

    if (-not (Test-Path -LiteralPath $SpecPath)) {
        return @{ Version = 2; EventBossStages = @(); Routes = @() }
    }
    return Import-KcpsRouteDatabase -Path $SpecPath
}

function Read-KcpsSpecialAttackRules {
    param([string]$RulePath)

    if (-not (Test-Path -LiteralPath $RulePath)) {
        return @{ Version = 1; Rules = @() }
    }
    return Get-Content -LiteralPath $RulePath -Raw | ConvertFrom-Json -AsHashtable
}

function Get-KcpsFleetFormationMode {
    param(
        [hashtable]$Group,
        [hashtable]$Sortie
    )

    $combined = @($Group['List'] | Where-Object {
        Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicCombinedFleetWorkflow'
    })
    if ($combined.Count -gt 0) {
        return 'Combined'
    }

    $sortieFleet = [int]$Sortie['Fleet']
    $organize = @($Group['List'] | Where-Object {
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') -and
        [int]$_['Fleet'] -eq $sortieFleet
    } | Select-Object -First 1)
    if ($organize.Count -eq 1 -and @($organize[0]['Positions']).Count -eq 7) {
        return 'Striking'
    }
    return 'Single'
}

function Get-KcpsSpecialAttackPlanProblems {
    param(
        [hashtable]$Group,
        [hashtable]$Sortie,
        [hashtable]$Spec,
        [hashtable]$SpecialAttackRuleDocument
    )

    $problems = @()
    $allMemo = (@($Group['List'] | ForEach-Object { [string]$_['Memo'] }) -join "`n")
    $mentionsSpecialAttack = $allMemo -match '特殊攻击|特殊攻撃'
    if (-not $Spec.ContainsKey('SpecialAttackPlan') -or $null -eq $Spec['SpecialAttackPlan']) {
        if ($mentionsSpecialAttack) {
            $problems += "Route spec $($Spec['Id']) memo mentions a special attack, but no structured SpecialAttackPlan exists."
        }
        return $problems
    }

    $plan = $Spec['SpecialAttackPlan']
    $actualMode = Get-KcpsFleetFormationMode -Group $Group -Sortie $Sortie
    $declaredMode = [string]$Spec['FleetFormationMode']
    if ([string]::IsNullOrWhiteSpace($declaredMode)) {
        $problems += "Route spec $($Spec['Id']) has SpecialAttackPlan but no FleetFormationMode."
        return $problems
    }
    if ($actualMode -ne $declaredMode) {
        $problems += "Route spec $($Spec['Id']) declares FleetFormationMode=$declaredMode, but config structure is $actualMode."
    }

    $ruleId = [string]$plan['RuleId']
    $rules = @($SpecialAttackRuleDocument['Rules'] | Where-Object { [string]$_['Id'] -eq $ruleId })
    if ($rules.Count -ne 1) {
        $problems += "Route spec $($Spec['Id']) references unknown or duplicated special-attack rule '$ruleId'. Refresh the rule registry from current Japanese wiki before generation."
        return $problems
    }
    $rule = $rules[0]
    $verified = [datetime]::ParseExact([string]$rule['LastVerifiedJst'], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $ageDays = [math]::Floor(((Get-Date).Date - $verified.Date).TotalDays)
    if ($ageDays -ge [int]$rule['RefreshAfterDays']) {
        $problems += "Special-attack rule '$ruleId' is stale ($ageDays days old). Refresh it from $($rule['Source']) before relying on the formation plan."
    }

    if (-not $rule['FormationEnums'].ContainsKey($declaredMode)) {
        $problems += "Special-attack rule '$ruleId' has no formation mapping for fleet mode $declaredMode."
        return $problems
    }
    $activationFormations = @($rule['FormationEnums'][$declaredMode] | ForEach-Object { [int]$_ })
    $pointStrategies = @($Sortie['Strategies'] | Where-Object { [int]$_['Condition']['Type'] -eq 1 })
    $activationValue = [int]$plan['ActivationNodeValue']
    $activationNode = [string]$plan['ActivationNode']
    $activationStrategies = @($pointStrategies | Where-Object { [int]$_['Condition']['Value'] -eq $activationValue })
    if ($activationStrategies.Count -ne 1) {
        $problems += "SpecialAttackPlan expects one activation strategy at $activationNode value $activationValue, but config has $($activationStrategies.Count)."
    } else {
        $actualFormation = [int]$activationStrategies[0]['Strategy']['DefaultFormation']
        if ($activationFormations -notcontains $actualFormation) {
            $problems += "SpecialAttackPlan expects '$ruleId' to activate at $activationNode value $activationValue in $declaredMode mode, but formation $actualFormation is not one of [$($activationFormations -join ',')]."
        }
        $activationMemo = [string]$activationStrategies[0]['Strategy']['Memo']
        if ($activationMemo -notmatch '特殊攻击|特殊攻撃') {
            $problems += "SpecialAttackPlan activation node $activationNode value $activationValue does not document the special attack in its strategy memo."
        }
        $formationLabel = if ($declaredMode -eq 'Combined') {
            switch ($actualFormation) {
                1 { '第四警戒' }
                2 { '第二警戒' }
                3 { '第三警戒' }
                5 { '第一警戒' }
                default { $null }
            }
        } else {
            switch ($actualFormation) {
                1 { '单纵阵' }
                2 { '复纵阵' }
                3 { '轮形阵' }
                4 { '梯形阵' }
                5 { '单横阵' }
                6 { '警戒阵' }
                default { $null }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($formationLabel) -and $activationMemo -notmatch [regex]::Escape($formationLabel)) {
            $problems += "SpecialAttackPlan activation node $activationNode value $activationValue uses formation $actualFormation, but its strategy memo does not name $formationLabel."
        }
        if ([string]$rule['ActivationPhase'] -eq 'Night' -and [int]$activationStrategies[0]['Strategy']['DefaultMidnight'] -eq 1) {
            $problems += "SpecialAttackPlan '$ruleId' activates at night, but $activationNode value $activationValue is configured to skip night battle."
        }
    }

    $suppressionValues = if ($plan.ContainsKey('SuppressionNodeValues') -and
        $null -ne $plan['SuppressionNodeValues']) {
        @($plan['SuppressionNodeValues'] | ForEach-Object { [int]$_ })
    } else {
        @()
    }
    foreach ($value in $suppressionValues) {
        $strategies = @($pointStrategies | Where-Object { [int]$_['Condition']['Value'] -eq $value })
        if ($strategies.Count -ne 1) {
            $problems += "SpecialAttackPlan suppression node value $value has $($strategies.Count) matching strategies instead of one."
            continue
        }
        $formation = [int]$strategies[0]['Strategy']['DefaultFormation']
        if ($activationFormations -contains $formation) {
            $problems += "SpecialAttackPlan suppression node value $value uses activation formation $formation; the special attack may be spent before $activationNode."
        }
    }

    $inertByValue = @{}
    foreach ($entry in @($plan['InertSameFormationNodes'] | Where-Object { $null -ne $_ })) {
        $inertByValue[[string][int]$entry['Value']] = $entry
        $node = @($Spec['Nodes'] | Where-Object { [int]$_['Value'] -eq [int]$entry['Value'] } | Select-Object -First 1)
        if ($node.Count -ne 1) {
            $problems += "SpecialAttackPlan inert exception value $($entry['Value']) is not present in route nodes."
            continue
        }
        if ([string]$entry['Reason'] -eq 'EnemyAllPT') {
            if (-not [bool]$rule['EnemyAllPtInert'] -or [string]$node[0]['Kind'] -ne 'pt') {
                $problems += "SpecialAttackPlan marks value $($entry['Value']) as EnemyAllPT, but the rule or route-node kind does not prove that exception."
            }
        } else {
            $problems += "SpecialAttackPlan inert exception value $($entry['Value']) uses unsupported reason '$($entry['Reason'])'."
        }
    }

    foreach ($strategy in $pointStrategies) {
        $value = [int]$strategy['Condition']['Value']
        if ($value -eq $activationValue) { continue }
        $formation = [int]$strategy['Strategy']['DefaultFormation']
        if ($activationFormations -contains $formation -and
            $suppressionValues -notcontains $value -and
            -not $inertByValue.ContainsKey([string]$value)) {
            $problems += "Map-point strategy value $value uses special-attack activation formation $formation before/away from $activationNode without a verified inert exception."
        }
    }

    foreach ($required in @($plan['RequiredPositions'])) {
        $fleetNo = [int]$required['Fleet']
        $positionNo = [int]$required['Position']
        $organize = @($Group['List'] | Where-Object {
            (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') -and
            [int]$_['Fleet'] -eq $fleetNo
        } | Select-Object -First 1)
        if ($organize.Count -ne 1 -or @($organize[0]['Positions']).Count -lt $positionNo) {
            $problems += "SpecialAttackPlan requires fleet $fleetNo position $positionNo, but no matching organize position exists."
            continue
        }
        $selectionMemo = (@($organize[0]['Positions'][$positionNo - 1]['Selections'] | ForEach-Object { [string]$_['Memo'] }) -join ' ')
        if ($selectionMemo -notmatch [string]$required['ShipNameRegex']) {
            $problems += "SpecialAttackPlan requires fleet $fleetNo position $positionNo to match '$($required['ShipNameRegex'])', but candidate memo is '$selectionMemo'."
        }
    }
    return $problems
}

$script:KcNavRouteEdgeCache = @{}

function Get-KcNavRouteEdgeIndex {
    param([Parameter(Mandatory)][string]$Map)

    if ($script:KcNavRouteEdgeCache.ContainsKey($Map)) {
        return $script:KcNavRouteEdgeCache[$Map]
    }

    $result = [ordered]@{
        Map = $Map
        Url = "https://tsunkit.net/api/routing/maps/$Map"
        Error = $null
        Edges = @{}
    }
    try {
        $response = Invoke-RestMethod -Uri $result['Url'] -TimeoutSec 20
        $routeData = $response.result.route
        foreach ($property in @($routeData.PSObject.Properties)) {
            $edge = @($property.Value)
            if ($edge.Count -lt 2) { continue }
            $from = [string]$edge[0]
            $to = [string]$edge[1]
            $key = "$from→$to"
            if (-not $result['Edges'].ContainsKey($key)) {
                $result['Edges'][$key] = @()
            }
            $result['Edges'][$key] = @($result['Edges'][$key]) + [int]$property.Name
        }
    } catch {
        $result['Error'] = $_.Exception.Message
    }

    $script:KcNavRouteEdgeCache[$Map] = $result
    return $result
}

function Get-KcNavRouteSpecSourceProblems {
    param(
        [Parameter(Mandatory)][hashtable]$Spec,
        [Parameter(Mandatory)][string]$Workflow,
        [Parameter(Mandatory)][int]$Sea,
        [Parameter(Mandatory)][int]$Area
    )

    $problems = @()
    $hasMap = $Spec.ContainsKey('KcNavMap') -and -not [string]::IsNullOrWhiteSpace([string]$Spec['KcNavMap'])
    $hasRoute = $Spec.ContainsKey('Route') -and @($Spec['Route']).Count -ge 2
    $isEventSpec = $Sea -eq 0

    if ($isEventSpec -and (-not $hasMap -or -not $hasRoute)) {
        $problems += [pscustomobject]@{
            Workflow = $Workflow
            Sea = $Sea
            Area = $Area
            RouteSpec = $Spec['Id']
            Problem = "Event route spec $($Spec['Id']) must include KcNavMap and an ordered Route array. Local node values alone cannot detect an entering-edge ID copied from the wrong predecessor."
        }
        return @($problems)
    }
    if (-not $hasMap -and -not $hasRoute) {
        return @()
    }
    if (-not $hasMap -or -not $hasRoute) {
        $problems += [pscustomobject]@{
            Workflow = $Workflow
            Sea = $Sea
            Area = $Area
            RouteSpec = $Spec['Id']
            Problem = "Route spec $($Spec['Id']) must define KcNavMap and Route together."
        }
        return @($problems)
    }

    $source = Get-KcNavRouteEdgeIndex -Map ([string]$Spec['KcNavMap'])
    if (-not [string]::IsNullOrWhiteSpace([string]$source['Error'])) {
        $problems += [pscustomobject]@{
            Workflow = $Workflow
            Sea = $Sea
            Area = $Area
            RouteSpec = $Spec['Id']
            Problem = "Could not verify route spec $($Spec['Id']) against KCNav $($source['Url']): $($source['Error'])"
        }
        return @($problems)
    }

    $route = @($Spec['Route'] | ForEach-Object { [string]$_ })
    $nodes = @($Spec['Nodes'])
    for ($i = 0; $i -lt $route.Count - 1; $i++) {
        $from = $route[$i]
        $to = $route[$i + 1]
        $key = "$from→$to"
        $sourceValues = @(
            if ($source['Edges'].ContainsKey($key)) {
                $source['Edges'][$key] | ForEach-Object { [int]$_ }
            }
        )
        if ($sourceValues.Count -eq 0) {
            $problems += [pscustomobject]@{
                Workflow = $Workflow
                Sea = $Sea
                Area = $Area
                RouteSpec = $Spec['Id']
                Problem = "KCNav map $($Spec['KcNavMap']) has no edge $key recorded for route spec $($Spec['Id']). The ordered route is stale or mistyped."
            }
            continue
        }

        $destinationNodes = @($nodes | Where-Object { [string]$_['Letter'] -eq $to })
        if ($destinationNodes.Count -eq 0) { continue }
        $localValues = @($destinationNodes | ForEach-Object { [int]$_['Value'] })
        if (@($localValues | Where-Object { $sourceValues -contains $_ }).Count -eq 0) {
            $problems += [pscustomobject]@{
                Workflow = $Workflow
                Sea = $Sea
                Area = $Area
                RouteSpec = $Spec['Id']
                Problem = "Route spec $($Spec['Id']) assigns $to value(s) $($localValues -join '/'), but KCNav map $($Spec['KcNavMap']) says entering edge $key uses value(s) $($sourceValues -join '/'). Map-point values are entering-edge IDs, not fixed node IDs."
            }
        }
    }

    return @($problems)
}

function Get-KcpsRouteSpecFreshness {
    param([hashtable]$RouteSpecDocument)

    $now = Get-JstNow
    $warnings = @()
    $routesOut = @()
    $eventBossStagesOut = @()
    foreach ($route in @($RouteSpecDocument['Routes'])) {
        if (-not $route.ContainsKey('LastVerifiedJst') -or -not $route.ContainsKey('RefreshAfterDays')) { continue }
        $lastVerified = [datetimeoffset]::Parse([string]$route['LastVerifiedJst'])
        if ($lastVerified.Offset -eq [TimeSpan]::Zero) {
            $lastVerified = [datetimeoffset]::new($lastVerified.DateTime, [TimeSpan]::FromHours(9))
        }
        $ageDays = [int][Math]::Floor(($now - $lastVerified).TotalDays)
        $refreshAfterDays = [int]$route['RefreshAfterDays']
        $entry = [pscustomobject]@{
            Id = $route['Id']
            Sea = $route['Sea']
            Area = $route['Area']
            Source = $route['Source']
            LastVerifiedJst = $route['LastVerifiedJst']
            AgeDays = $ageDays
            RefreshAfterDays = $refreshAfterDays
        }
        $routesOut += $entry
        if ($ageDays -ge $refreshAfterDays) {
            $warnings += [pscustomobject]@{
                Id = $route['Id']
                Sea = $route['Sea']
                Area = $route['Area']
                AgeDays = $ageDays
                RefreshAfterDays = $refreshAfterDays
                Warning = 'Route spec is stale; refresh against current KCNav/TsunKit and wikiwiki before relying on this node-value validation.'
                Source = $route['Source']
            }
        }
    }

    foreach ($mapping in @($RouteSpecDocument['EventBossStages'])) {
        if (-not $mapping.ContainsKey('LastVerifiedJst') -or -not $mapping.ContainsKey('RefreshAfterDays')) { continue }
        $lastVerified = [datetimeoffset]::Parse([string]$mapping['LastVerifiedJst'])
        if ($lastVerified.Offset -eq [TimeSpan]::Zero) {
            $lastVerified = [datetimeoffset]::new($lastVerified.DateTime, [TimeSpan]::FromHours(9))
        }
        $ageDays = [int][Math]::Floor(($now - $lastVerified).TotalDays)
        $refreshAfterDays = [int]$mapping['RefreshAfterDays']
        $entry = [pscustomobject]@{
            Id = $mapping['Id']
            Area = $mapping['Area']
            Source = $mapping['Source']
            LastVerifiedJst = $mapping['LastVerifiedJst']
            AgeDays = $ageDays
            RefreshAfterDays = $refreshAfterDays
        }
        $eventBossStagesOut += $entry
        if ($ageDays -ge $refreshAfterDays) {
            $warnings += [pscustomobject]@{
                Id = $mapping['Id']
                Sea = 0
                Area = $mapping['Area']
                AgeDays = $ageDays
                RefreshAfterDays = $refreshAfterDays
                Warning = 'Event Boss-stage mapping is stale; refresh every phase Boss point against the latest Japanese wiki before naming armor-break configs.'
                Source = $mapping['Source']
            }
        }
    }

    [pscustomobject]@{
        NowJst = $now.ToString('yyyy-MM-dd HH:mm:ss zzz')
        Routes = @($routesOut)
        EventBossStages = @($eventBossStagesOut)
        Warnings = @($warnings)
    }
}

function Get-KcpsRouteSpecProblems {
    param(
        [hashtable]$Group,
        [hashtable[]]$SortieWorkflows,
        [hashtable[]]$RelationalWorkflows,
        [hashtable]$RouteSpecDocument,
        [hashtable]$SpecialAttackRuleDocument,
        [AllowNull()][object]$RouteContext = $null,
        [bool]$RequireRouteSpec = $true
    )

    $problems = @()
    $groupName = [string]$Group['Name']
    foreach ($sortie in @($SortieWorkflows)) {
        $matchingSpecs = @($RouteSpecDocument['Routes'] | Where-Object {
            [int]$_['Sea'] -eq [int]$sortie['Sea'] -and
            [int]$_['Area'] -eq [int]$sortie['Area'] -and
            ([string]::IsNullOrWhiteSpace([string]$_['GroupNameRegex']) -or
                (Test-KcpsRouteSpecGroupName -GroupName $groupName -RouteSpec $_))
        })
        if ($matchingSpecs.Count -eq 0) {
            if ($RequireRouteSpec) {
                $problems += [pscustomobject]@{
                    Workflow = $sortie['Name']
                    Sea = [int]$sortie['Sea']
                    Area = [int]$sortie['Area']
                    RouteSpec = $null
                    Problem = 'No matching runtime route spec exists for this sortie; task, route and stage conditions cannot be verified.'
                }
            }
            continue
        }
        if ($matchingSpecs.Count -gt 1) {
            $matchingIds = @($matchingSpecs | ForEach-Object { [string]$_['Id'] })
            $problems += [pscustomobject]@{
                Workflow = $sortie['Name']
                Sea = [int]$sortie['Sea']
                Area = [int]$sortie['Area']
                RouteSpec = ($matchingIds -join ', ')
                Problem = "Multiple route specs match this config: $($matchingIds -join ', '). GroupNameRegex must identify exactly one task/map/stage; do not match only a generic sea name."
            }
            continue
        }

        $historicalBossExpectation = Get-KcpsHistoricalBossStageExpectation `
            -GroupName $groupName `
            -RouteSpec $matchingSpecs[0] `
            -RouteSpecDocument $RouteSpecDocument
        if ($null -ne $historicalBossExpectation) {
            $expectedLabel = [string]$historicalBossExpectation['ExpectedLabel']
            $actualLabel = [string]$historicalBossExpectation['ActualLabel']
            if ([int]$historicalBossExpectation['MappingCount'] -ne 1) {
                $problems += [pscustomobject]@{
                    Workflow = $sortie['Name']
                    Sea = [int]$sortie['Sea']
                    Area = [int]$sortie['Area']
                    RouteSpec = $matchingSpecs[0]['Id']
                    Problem = 'Armor-break config lacks exactly one event Boss-stage mapping. Verify every phase Boss point from the latest Japanese wiki and update EventBossStages before delivery.'
                }
            } elseif ($actualLabel -cne $expectedLabel) {
                $pointName = [string]$historicalBossExpectation['Point'] + '点'
                $expectedText = if ([string]::IsNullOrWhiteSpace($expectedLabel)) {
                    $pointName
                } else {
                    "$pointName($expectedLabel)"
                }
                $actualText = if ([string]::IsNullOrWhiteSpace($actualLabel)) {
                    $pointName
                } else {
                    "$pointName($actualLabel)"
                }
                $problems += [pscustomobject]@{
                    Workflow = $sortie['Name']
                    Sea = [int]$sortie['Sea']
                    Area = [int]$sortie['Area']
                    RouteSpec = $matchingSpecs[0]['Id']
                    Problem = "Armor-break target stage label is wrong: actual '$actualText', expected '$expectedText'. Add (P#) only when revisiting a Boss point from an earlier phase; ordinary points must remain unlabelled."
                }
            }
        }

        $pointStrategies = @($sortie['Strategies'] | Where-Object { $_['Condition']['Type'] -eq 1 })
        $strategyValues = @($pointStrategies | ForEach-Object { [int]$_['Condition']['Value'] })

        foreach ($spec in $matchingSpecs) {
            $problems += @(Get-KcNavRouteSpecSourceProblems -Spec $spec -Workflow ([string]$sortie['Name']) -Sea ([int]$sortie['Sea']) -Area ([int]$sortie['Area']))
            $orderedRoute = @($spec['Route'] | ForEach-Object { [string]$_ })
            $mapBranchRules = if ($RouteSpecDocument.ContainsKey('RouteBranchRules')) {
                @($RouteSpecDocument['RouteBranchRules'] | Where-Object {
                    [string]$_['KcNavMap'] -eq [string]$spec['KcNavMap']
                })
            } else { @() }
            foreach ($knownRule in $mapBranchRules) {
                $edgePresent = $false
                for ($routeIndex = 0; $routeIndex -lt $orderedRoute.Count - 1; $routeIndex++) {
                    if ($orderedRoute[$routeIndex] -eq [string]$knownRule['From'] -and
                        $orderedRoute[$routeIndex + 1] -eq [string]$knownRule['To']) {
                        $edgePresent = $true
                        break
                    }
                }
                if (-not $edgePresent) { continue }
                $declaredRules = if ($spec.ContainsKey('LosBranchRules')) { @($spec['LosBranchRules']) } else { @() }
                $matchingRule = @($declaredRules | Where-Object {
                    [string]$_['From'] -eq [string]$knownRule['From'] -and
                    [string]$_['To'] -eq [string]$knownRule['To'] -and
                    [string]$_['Formula'] -eq [string]$knownRule['Formula'] -and
                    [int]$_['Coefficient'] -eq [int]$knownRule['Coefficient'] -and
                    [double]$_['Threshold'] -eq [double]$knownRule['Threshold']
                })
                if ($matchingRule.Count -ne 1) {
                    $problems += [pscustomobject]@{
                        Workflow = $sortie['Name']
                        Sea = [int]$sortie['Sea']
                        Area = [int]$sortie['Area']
                        RouteSpec = $spec['Id']
                        Problem = "Route spec $($spec['Id']) traverses known LoS branch $($knownRule['From'])->$($knownRule['To']) on KCNav map $($spec['KcNavMap']) but does not declare the matching $($knownRule['Formula']) coefficient $($knownRule['Coefficient']) threshold $($knownRule['Threshold']) rule."
                    }
                }
            }
            foreach ($problemText in @(Get-KcpsStageDesignProblems -Group $Group -Sortie $sortie -RelationalWorkflows $RelationalWorkflows -Spec $spec)) {
                $problems += [pscustomobject]@{
                    Workflow = $sortie['Name']
                    Sea = [int]$sortie['Sea']
                    Area = [int]$sortie['Area']
                    RouteSpec = $spec['Id']
                    Problem = $problemText
                }
            }
            foreach ($problemText in @(Get-KcpsSpecialAttackPlanProblems -Group $Group -Sortie $sortie -Spec $spec -SpecialAttackRuleDocument $SpecialAttackRuleDocument)) {
                $problems += [pscustomobject]@{
                    Workflow = $sortie['Name']
                    Sea = [int]$sortie['Sea']
                    Area = [int]$sortie['Area']
                    RouteSpec = $spec['Id']
                    Problem = $problemText
                }
            }
            if ($spec.ContainsKey('ExpectedFleetSpeed') -and
                -not [string]::IsNullOrWhiteSpace([string]$spec['ExpectedFleetSpeed'])) {
                $expectedFleetSpeed = [string]$spec['ExpectedFleetSpeed']
                if ($expectedFleetSpeed -ne 'Fast') {
                    $problems += [pscustomobject]@{
                        Workflow = $sortie['Name']
                        Sea = [int]$sortie['Sea']
                        Area = [int]$sortie['Area']
                        RouteSpec = $spec['Id']
                        Problem = "Route spec $($spec['Id']) uses unsupported ExpectedFleetSpeed '$expectedFleetSpeed'."
                    }
                } elseif ($null -eq $RouteContext) {
                    $problems += [pscustomobject]@{
                        Workflow = $sortie['Name']
                        Sea = [int]$sortie['Sea']
                        Area = [int]$sortie['Area']
                        RouteSpec = $spec['Id']
                        Problem = "Route spec $($spec['Id']) requires a Fast fleet, but ship master/account data is unavailable; speed cannot be verified."
                    }
                } else {
                    $speedOverrides = if ($spec.ContainsKey('ExpectedSpeedEquipmentOverrides')) {
                        @($spec['ExpectedSpeedEquipmentOverrides'])
                    } else {
                        @()
                    }
                    $fleetNumbers = if ($spec.ContainsKey('ExpectedFleetCounts')) {
                        @($spec['ExpectedFleetCounts'].Keys | ForEach-Object { [int]$_ })
                    } else {
                        @()
                    }
                    $refitWorkflows = @($Group['List'] | Where-Object {
                        Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicRefitEquipmentWorkflow'
                    })

                    foreach ($fleetNo in $fleetNumbers) {
                        $organizeWorkflows = @($Group['List'] | Where-Object {
                            (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') -and
                            [int]$_['Fleet'] -eq $fleetNo
                        })
                        if ($organizeWorkflows.Count -ne 1) { continue }

                        foreach ($ship in @(Get-KcpsPrimaryFleetShips -OrganizeWorkflow $organizeWorkflows[0] -RouteContext $RouteContext)) {
                            if ([int]$ship.Speed -ge 10) { continue }

                            $matchingOverrides = @($speedOverrides | Where-Object {
                                [int]$_['Fleet'] -eq $fleetNo -and
                                [int]$_['Position'] -eq [int]$ship.Position -and
                                [string]$ship.Name -match [string]$_['ShipNameRegex']
                            })
                            if ($matchingOverrides.Count -ne 1) {
                                $problems += [pscustomobject]@{
                                    Workflow = $sortie['Name']
                                    Sea = [int]$sortie['Sea']
                                    Area = [int]$sortie['Area']
                                    RouteSpec = $spec['Id']
                                    Problem = "Route spec $($spec['Id']) requires Fast, but fleet $fleetNo position $($ship.Position) $($ship.Name) has base speed $($ship.Speed) and lacks exactly one verified speed-equipment override."
                                }
                                continue
                            }

                            $refitRows = @()
                            foreach ($refitWorkflow in $refitWorkflows) {
                                $refitRows += @($refitWorkflow['Ships'] | Where-Object {
                                    [int]$_['Fleet'] -eq $fleetNo -and (
                                        ([int]$_['SelectMethod'] -eq 0 -and [int]$_['SelectValue'] -eq [int]$ship.Position) -or
                                        ([int]$_['SelectMethod'] -eq 3 -and [string]$_['SelectValue'] -eq [string]$ship.OwnedId)
                                    )
                                })
                            }
                            if ($refitRows.Count -ne 1) {
                                $problems += [pscustomobject]@{
                                    Workflow = $sortie['Name']
                                    Sea = [int]$sortie['Sea']
                                    Area = [int]$sortie['Area']
                                    RouteSpec = $spec['Id']
                                    Problem = "Route spec $($spec['Id']) cannot verify speed equipment for fleet $fleetNo position $($ship.Position) $($ship.Name): expected exactly one refit row, found $($refitRows.Count)."
                                }
                                continue
                            }

                            $configuredEquipment = @($refitRows[0]['Slots'] | ForEach-Object {
                                @($_['Equipments']) | ForEach-Object { [string]$_['SelectValue'] }
                            })
                            $requiredEquipment = @($matchingOverrides[0]['AllOf'] | ForEach-Object { [string]$_ })
                            $missingEquipment = @($requiredEquipment | Where-Object { $_ -notin $configuredEquipment })
                            if ($missingEquipment.Count -gt 0) {
                                $problems += [pscustomobject]@{
                                    Workflow = $sortie['Name']
                                    Sea = [int]$sortie['Sea']
                                    Area = [int]$sortie['Area']
                                    RouteSpec = $spec['Id']
                                    Problem = "Route spec $($spec['Id']) requires fleet $fleetNo position $($ship.Position) $($ship.Name) to carry speed equipment [$($requiredEquipment -join ', ')], but refit is missing [$($missingEquipment -join ', ')]."
                                }
                            }
                        }
                    }
                }
            }
            if ($spec.ContainsKey('ExpectedFleetCounts') -and $null -ne $spec['ExpectedFleetCounts']) {
                foreach ($fleetEntry in $spec['ExpectedFleetCounts'].GetEnumerator()) {
                    $fleetNo = [int]$fleetEntry.Key
                    $expectedFleetCount = [int]$fleetEntry.Value
                    $organizeWorkflows = @($Group['List'] | Where-Object {
                        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') -and
                        [int]$_['Fleet'] -eq $fleetNo
                    })
                    if ($organizeWorkflows.Count -ne 1) {
                        $problems += [pscustomobject]@{
                            Workflow = $sortie['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Route spec $($spec['Id']) expects exactly one organize workflow for fleet $fleetNo, but config has $($organizeWorkflows.Count)."
                        }
                        continue
                    }
                    $actualFleetCount = @($organizeWorkflows[0]['Positions']).Count
                    if ($actualFleetCount -ne $expectedFleetCount) {
                        $problems += [pscustomobject]@{
                            Workflow = $sortie['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Route spec $($spec['Id']) expects fleet $fleetNo to sortie with exactly $expectedFleetCount ship(s), but organize workflow has $actualFleetCount position(s). Follow the guide's exact composition unless a verified deviation is documented in the route spec."
                        }
                    }
                }
            }
            if ($spec.ContainsKey('ShipTypeCountRules') -and $null -ne $spec['ShipTypeCountRules']) {
                if ($null -eq $RouteContext) {
                    $problems += [pscustomobject]@{
                        Workflow = $sortie['Name']
                        Sea = [int]$sortie['Sea']
                        Area = [int]$sortie['Area']
                        RouteSpec = $spec['Id']
                        Problem = "Route spec $($spec['Id']) declares ship-type route conditions, but ship master/account data is unavailable."
                    }
                } else {
                    $fleetNumbers = if ($spec.ContainsKey('ExpectedFleetCounts')) {
                        @($spec['ExpectedFleetCounts'].Keys | ForEach-Object { [int]$_ })
                    } else {
                        @($Group['List'] | Where-Object {
                            Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow'
                        } | ForEach-Object { [int]$_['Fleet'] } | Sort-Object -Unique)
                    }
                    $routeShips = @()
                    foreach ($fleetNo in $fleetNumbers) {
                        $organizeWorkflows = @($Group['List'] | Where-Object {
                            (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') -and
                            [int]$_['Fleet'] -eq $fleetNo
                        })
                        if ($organizeWorkflows.Count -eq 1) {
                            $routeShips += @(Get-KcpsPrimaryFleetShips -OrganizeWorkflow $organizeWorkflows[0] -RouteContext $RouteContext)
                        }
                    }
                    foreach ($rule in @($spec['ShipTypeCountRules'])) {
                        $shipTypes = @($rule['ShipTypes'] | ForEach-Object { [string]$_ })
                        $unknownTypes = @($shipTypes | Where-Object { $_ -notin $RouteContext.StypeById.Values })
                        if ($shipTypes.Count -eq 0 -or $unknownTypes.Count -gt 0 -or
                            -not ($rule.ContainsKey('Exact') -or $rule.ContainsKey('Minimum') -or $rule.ContainsKey('Maximum'))) {
                            $problems += [pscustomobject]@{
                                Workflow = $sortie['Name']; Sea = [int]$sortie['Sea']; Area = [int]$sortie['Area']; RouteSpec = $spec['Id']
                                Problem = "Route spec $($spec['Id']) has an invalid ShipTypeCountRules entry: use known master ship-type names and at least one count bound; unknown types [$($unknownTypes -join ', ')]."
                            }
                            continue
                        }
                        $actual = @($routeShips | Where-Object { [string]$_.ShipType -in $shipTypes }).Count
                        $violated = $false
                        $expectation = ''
                        if ($rule.ContainsKey('Exact')) {
                            $expected = [int]$rule['Exact'];$violated = $actual -ne $expected;$expectation = "exactly $expected"
                        }
                        if ($rule.ContainsKey('Minimum')) {
                            $minimum = [int]$rule['Minimum'];$violated = $violated -or $actual -lt $minimum;$expectation += $(if($expectation){'; '}else{''}) + "at least $minimum"
                        }
                        if ($rule.ContainsKey('Maximum')) {
                            $maximum = [int]$rule['Maximum'];$violated = $violated -or $actual -gt $maximum;$expectation += $(if($expectation){'; '}else{''}) + "at most $maximum"
                        }
                        if ($violated) {
                            $reason = if ($rule.ContainsKey('Reason')) { [string]$rule['Reason'] } else { 'declared route branch condition' }
                            $problems += [pscustomobject]@{
                                Workflow = $sortie['Name']
                                Sea = [int]$sortie['Sea']
                                Area = [int]$sortie['Area']
                                RouteSpec = $spec['Id']
                                Problem = "Route spec $($spec['Id']) requires ship types [$($shipTypes -join ', ')] to be $expectation, but the configured sortie fleets contain $actual. $reason"
                            }
                        }
                    }
                }
            }
            if ($spec.ContainsKey('GuideFleetBaseline') -and $null -ne $spec['GuideFleetBaseline']) {
                foreach ($fleetEntry in $spec['GuideFleetBaseline'].GetEnumerator()) {
                    $fleetNo = [int]$fleetEntry.Key
                    $expectedPatterns = @($fleetEntry.Value | ForEach-Object { [string]$_ })
                    $organizeWorkflows = @($Group['List'] | Where-Object {
                        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') -and
                        [int]$_['Fleet'] -eq $fleetNo
                    })
                    if ($organizeWorkflows.Count -ne 1) { continue }

                    $positions = @($organizeWorkflows[0]['Positions'])
                    for ($positionIndex = 0; $positionIndex -lt $expectedPatterns.Count; $positionIndex++) {
                        if ($positionIndex -ge $positions.Count) { break }
                        $pattern = $expectedPatterns[$positionIndex]
                        $actualNames = @($positions[$positionIndex]['Selections'] | Where-Object { $null -ne $_ } | ForEach-Object {
                            $shipInfo = Resolve-KcpsShipInfoFromSelection -Selection $_ -RouteContext $RouteContext
                            if ($null -ne $shipInfo) {
                                [string]$shipInfo.Name
                            } else {
                                Normalize-KcpsShipMemo ([string]$_['Memo'])
                            }
                        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
                        if (@($actualNames | Where-Object { $_ -match $pattern }).Count -eq 0) {
                            $problems += [pscustomobject]@{
                                Workflow = $sortie['Name']
                                Sea = [int]$sortie['Sea']
                                Area = [int]$sortie['Area']
                                RouteSpec = $spec['Id']
                                Problem = "Route spec $($spec['Id']) expects guide/adaptation fleet $fleetNo position $($positionIndex + 1) to match '$pattern', but config candidates are [$($actualNames -join ', ')]. Re-check the latest guide, lock allocation, account substitution reason, and ship order."
                            }
                        }
                    }
                }
            }
            $expectedNodes = @($spec['Nodes'])
            $expectedValues = @($expectedNodes | ForEach-Object { [int]$_['Value'] })
            $noFormationNodes = if ($spec.ContainsKey('NoFormationNodes')) {
                @($spec['NoFormationNodes'])
            } else {
                @()
            }

            foreach ($node in $noFormationNodes) {
                $value = [int]$node['Value']
                $letter = [string]$node['Letter']
                $matchingStrategies = @($pointStrategies | Where-Object {
                    [int]$_['Condition']['Value'] -eq $value
                })
                if ($matchingStrategies.Count -eq 0) { continue }

                $problems += [pscustomobject]@{
                    Workflow = $sortie['Name']
                    Sea = [int]$sortie['Sea']
                    Area = [int]$sortie['Area']
                    RouteSpec = $spec['Id']
                    Problem = "Route spec $($spec['Id']) marks node $letter value $value as having no formation-selection page, but the config defines a map-point battle strategy for it. KCPS cannot execute formation/refresh actions there; remove the strategy and prevent the diversion at an earlier battle node when necessary."
                }
            }

            # boss 击沉停止条件 vs 路线 boss 节点：防止漏设、指向错节点或次数不符
            $bossCandidates = @($expectedNodes | Where-Object { [string]$_['Kind'] -eq 'boss' })
            if ($bossCandidates.Count -gt 0) {
                $bossNode = $bossCandidates[0]
                $bossValue = [int]$bossNode['Value']
                $bossLetter = [string]$bossNode['Letter']
                $requiredBossKills = if ($bossNode.ContainsKey('BossKillCount')) {
                    [int]$bossNode['BossKillCount']
                } else {
                    0
                }
                foreach ($ctrl in @($RelationalWorkflows)) {
                    $stopEnabled = $ctrl.ContainsKey('StopIfEnemyFlagShipSunkFlag') -and
                        [bool]$ctrl['StopIfEnemyFlagShipSunkFlag']
                    if ($requiredBossKills -gt 0 -and -not $stopEnabled) {
                        $problems += [pscustomobject]@{
                            Workflow = $ctrl['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Route spec $($spec['Id']) requires $requiredBossKills flagship sink(s) at boss node $bossLetter value $bossValue, but the controller does not enable StopIfEnemyFlagShipSunk."
                        }
                    }
                    if (-not $stopEnabled) { continue }

                    if ([int]$ctrl['StopIfEnemyFlagShipSunkValueConditionType'] -ne 1) {
                        $problems += [pscustomobject]@{
                            Workflow = $ctrl['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Controller StopIfEnemyFlagShipSunk must use map-point condition type 1 for route spec $($spec['Id'])."
                        }
                    }
                    $stopNode = [int]$ctrl['StopIfEnemyFlagShipSunkValueConditionValue']
                    $stopCount = [int]$ctrl['StopIfEnemyFlagShipSunkValueThreshold']
                    if ($stopNode -ne $bossValue) {
                        $problems += [pscustomobject]@{
                            Workflow = $ctrl['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Controller StopIfEnemyFlagShipSunk targets node value $stopNode, but route spec $($spec['Id']) boss is node $bossLetter value $bossValue. The stop-on-boss-sunk condition points to the wrong node (likely copy-pasted from another gauge); the controller will never auto-stop on the real boss."
                        }
                    } elseif ($requiredBossKills -gt 0 -and $stopCount -ne $requiredBossKills) {
                        $problems += [pscustomobject]@{
                            Workflow = $ctrl['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Controller StopIfEnemyFlagShipSunk threshold is $stopCount, but route spec $($spec['Id']) boss node $bossLetter requires $requiredBossKills flagship sink(s) to break the gauge."
                        }
                    }
                }
            }

            $indexByValue = @{}
            for ($i = 0; $i -lt $strategyValues.Count; $i++) {
                if (-not $indexByValue.ContainsKey([string]$strategyValues[$i])) {
                    $indexByValue[[string]$strategyValues[$i]] = $i
                }
            }

            $routeSelectionValues = @($expectedNodes | Where-Object {
                ($_.ContainsKey('RequiresWayPoint') -and [bool]$_['RequiresWayPoint']) -or
                [string]$_['Kind'] -eq 'waypoint-select'
            } | ForEach-Object { [int]$_['Value'] })
            foreach ($pointStrategy in $pointStrategies) {
                $pointValue = [int]$pointStrategy['Condition']['Value']
                $wayPoint = $pointStrategy['Strategy']['DefaultWayPoint']
                if ($pointValue -in $routeSelectionValues) {
                    if (-not (Test-KcpsWayPointValid -WayPoint $wayPoint)) {
                        $problems += [pscustomobject]@{
                            Workflow = $sortie['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Route spec $($spec['Id']) node value $pointValue is an active route-selection node, but DefaultWayPoint is missing or invalid. Set a named positive-size normalized click rectangle fully inside the map."
                        }
                    }
                } elseif ($null -ne $wayPoint) {
                    $problems += [pscustomobject]@{
                        Workflow = $sortie['Name']
                        Sea = [int]$sortie['Sea']
                        Area = [int]$sortie['Area']
                        RouteSpec = $spec['Id']
                        Problem = "Route spec $($spec['Id']) node value $pointValue is not an active route-selection node, so DefaultWayPoint must be null. An empty zero-coordinate object still counts as an incorrectly configured route."
                    }
                }
            }

            foreach ($node in $expectedNodes) {
                $value = [int]$node['Value']
                $letter = [string]$node['Letter']
                if (-not $indexByValue.ContainsKey([string]$value)) {
                    $problems += [pscustomobject]@{
                        Workflow = $sortie['Name']
                        Sea = [int]$sortie['Sea']
                        Area = [int]$sortie['Area']
                        RouteSpec = $spec['Id']
                        Problem = "Route spec $($spec['Id']) expects node $letter value $value, but no matching map-point conditional strategy exists."
                    }
                    continue
                }

                $strategy = @($pointStrategies | Where-Object { [int]$_['Condition']['Value'] -eq $value } | Select-Object -First 1)[0]
                $memo = [string]$strategy['Strategy']['Memo']
                if ($node.ContainsKey('MemoRegex') -and -not [string]::IsNullOrWhiteSpace([string]$node['MemoRegex']) -and $memo -notmatch [string]$node['MemoRegex']) {
                    $problems += [pscustomobject]@{
                        Workflow = $sortie['Name']
                        Sea = [int]$sortie['Sea']
                        Area = [int]$sortie['Area']
                        RouteSpec = $spec['Id']
                        Problem = "Route spec $($spec['Id']) expects value $value to be node $letter, but strategy memo '$memo' does not match expected node/type."
                    }
                }
                $nodeKind = if ($node.ContainsKey('Kind')) { [string]$node['Kind'] } else { '' }
                $memoLooksAirRaid = $memo -match '空袭|空襲|air\s*raid'
                $memoLooksAirBattle = $memo -match '航空戦|航空战|air\s*battle'
                if ($nodeKind -match '^airbattle' -and $memoLooksAirRaid) {
                    $problems += [pscustomobject]@{
                        Workflow = $sortie['Name']
                        Sea = [int]$sortie['Sea']
                        Area = [int]$sortie['Area']
                        RouteSpec = $spec['Id']
                        Problem = "Route spec $($spec['Id']) classifies node $letter value $value as old-style AirBattle/航空戦マス, but strategy memo '$memo' calls it air raid. 航空戦マス has a night-battle choice and must not use air-raid midnight rules."
                    }
                }
                if ($nodeKind -match '^airraid' -and $memoLooksAirBattle) {
                    $problems += [pscustomobject]@{
                        Workflow = $sortie['Name']
                        Sea = [int]$sortie['Sea']
                        Area = [int]$sortie['Area']
                        RouteSpec = $spec['Id']
                        Problem = "Route spec $($spec['Id']) classifies node $letter value $value as modern LongDistanceAirBattle/空襲戦, but strategy memo '$memo' calls it 航空戦. 空襲戦 has no night-battle choice and should keep DefaultMidnight=0."
                    }
                }
                if ($nodeKind -match '^airbattle' -and [int]$strategy['Strategy']['DefaultMidnight'] -eq 0) {
                    $problems += [pscustomobject]@{
                        Workflow = $sortie['Name']
                        Sea = [int]$sortie['Sea']
                        Area = [int]$sortie['Area']
                        RouteSpec = $spec['Id']
                        Problem = "Route spec $($spec['Id']) classifies node $letter value $value as old-style AirBattle/航空戦マス. DefaultMidnight=0 would pause at the night-battle choice; use StopPursuit(1) or NightAttack(2) by tactical decision."
                    }
                }
                if ($nodeKind -match '^airraid' -and [int]$strategy['Strategy']['DefaultMidnight'] -ne 0) {
                    $problems += [pscustomobject]@{
                        Workflow = $sortie['Name']
                        Sea = [int]$sortie['Sea']
                        Area = [int]$sortie['Area']
                        RouteSpec = $spec['Id']
                        Problem = "Route spec $($spec['Id']) classifies node $letter value $value as modern LongDistanceAirBattle/空襲戦. It has no night-battle choice, so DefaultMidnight should stay Manual(0)."
                    }
                }

                foreach ($field in @('ExpectedFormation', 'ExpectedMidnight', 'ExpectedAdvance', 'ExpectedEscortRetreat', 'ExpectedSmoke')) {
                    if (-not $node.ContainsKey($field)) { continue }
                    $strategyField = switch ($field) {
                        'ExpectedFormation' { 'DefaultFormation' }
                        'ExpectedMidnight' { 'DefaultMidnight' }
                        'ExpectedAdvance' { 'DefaultAdvance' }
                        'ExpectedEscortRetreat' { 'DefaultEscortRetreat' }
                        'ExpectedSmoke' { 'DefaultSmoke' }
                    }
                    if ([int][bool]$strategy['Strategy'][$strategyField] -ne [int][bool]$node[$field] -and $field -eq 'ExpectedSmoke') {
                        $problems += [pscustomobject]@{
                            Workflow = $sortie['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Route spec $($spec['Id']) expects node $letter value $value $strategyField=$($node[$field]), but config has $($strategy['Strategy'][$strategyField])."
                        }
                    } elseif ($field -ne 'ExpectedSmoke' -and [int]$strategy['Strategy'][$strategyField] -ne [int]$node[$field]) {
                        $problems += [pscustomobject]@{
                            Workflow = $sortie['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Route spec $($spec['Id']) expects node $letter value $value $strategyField=$($node[$field]), but config has $($strategy['Strategy'][$strategyField])."
                        }
                    }
                }
            }

            if ($spec.ContainsKey('ExpectedCompletion') -and $null -ne $spec['ExpectedCompletion']) {
                $completionWorkflow = @($RelationalWorkflows | Select-Object -First 1)[0]
                $completion = $spec['ExpectedCompletion']
                $completionType = [string]$completion['Type']
                if ($null -eq $completionWorkflow) {
                    $problems += [pscustomobject]@{
                        Workflow = $sortie['Name']
                        Sea = [int]$sortie['Sea']
                        Area = [int]$sortie['Area']
                        RouteSpec = $spec['Id']
                        Problem = "Route spec $($spec['Id']) expects completion stop settings, but no RelationalSortieWorkflow exists in this group."
                    }
                    continue
                }
                if ($completionType -eq 'point-rank') {
                    $expectedConditionType = 1
                    $expectedValue = [string]$completion['Value']
                    $expectedRank = [int]$completion['Rank']
                    $expectedThreshold = [int]$completion['Threshold']

                    if ([bool]$completionWorkflow['StopIfArrivedEndPointFlag']) {
                        $problems += [pscustomobject]@{
                            Workflow = $completionWorkflow['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Route spec $($spec['Id']) expects point-rank completion, but StopIfArrivedEndPointFlag is enabled. For 1-6 Sortie_Map16_Clear this endpoint counter is not reliable."
                        }
                    }
                    if (-not [bool]$completionWorkflow['StopIfBattleRankHigherOrEqualThanFlag']) {
                        $problems += [pscustomobject]@{
                            Workflow = $completionWorkflow['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Route spec $($spec['Id']) expects point-rank completion, but StopIfBattleRankHigherOrEqualThanFlag is disabled."
                        }
                    }
                    if ([int]$completionWorkflow['StopIfBattleRankHigherOrEqualThanValueConditionType'] -ne $expectedConditionType) {
                        $problems += [pscustomobject]@{
                            Workflow = $completionWorkflow['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Route spec $($spec['Id']) expects point-rank completion condition type $expectedConditionType, but config has $($completionWorkflow['StopIfBattleRankHigherOrEqualThanValueConditionType'])."
                        }
                    }
                    if ([string]$completionWorkflow['StopIfBattleRankHigherOrEqualThanValueConditionValue'] -ne $expectedValue) {
                        $problems += [pscustomobject]@{
                            Workflow = $completionWorkflow['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Route spec $($spec['Id']) expects point-rank completion value $expectedValue, but config has $($completionWorkflow['StopIfBattleRankHigherOrEqualThanValueConditionValue'])."
                        }
                    }
                    if ([int]$completionWorkflow['StopIfBattleRankHigherOrEqualThanValueRank'] -ne $expectedRank) {
                        $problems += [pscustomobject]@{
                            Workflow = $completionWorkflow['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Route spec $($spec['Id']) expects point-rank completion rank $expectedRank, but config has $($completionWorkflow['StopIfBattleRankHigherOrEqualThanValueRank'])."
                        }
                    }
                    if ([int]$completionWorkflow['StopIfBattleRankHigherOrEqualThanValueThreshold'] -ne $expectedThreshold) {
                        $problems += [pscustomobject]@{
                            Workflow = $completionWorkflow['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Route spec $($spec['Id']) expects point-rank completion threshold $expectedThreshold, but config has $($completionWorkflow['StopIfBattleRankHigherOrEqualThanValueThreshold'])."
                        }
                    }
                } else {
                    $problems += [pscustomobject]@{
                        Workflow = $sortie['Name']
                        Sea = [int]$sortie['Sea']
                        Area = [int]$sortie['Area']
                        RouteSpec = $spec['Id']
                        Problem = "Route spec $($spec['Id']) has unsupported ExpectedCompletion.Type '$completionType'."
                    }
                }
            }

            if ($spec.ContainsKey('BranchCoverageRules') -and $null -ne $spec['BranchCoverageRules']) {
                foreach ($rule in @($spec['BranchCoverageRules'])) {
                    $from = [string]$rule['From']
                    $edges = @($rule['Edges'] | ForEach-Object { [int]$_ })
                    $refreshEdges = @($rule['RefreshEdges'] | ForEach-Object { [int]$_ })
                    foreach ($edge in $edges) {
                        if (-not $indexByValue.ContainsKey([string]$edge)) {
                            $problems += [pscustomobject]@{
                                Workflow = $sortie['Name']
                                Sea = [int]$sortie['Sea']
                                Area = [int]$sortie['Area']
                                RouteSpec = $spec['Id']
                                Problem = "Route spec $($spec['Id']) branch coverage from $from expects edge value $edge, but no matching map-point conditional strategy exists."
                            }
                        }
                    }
                    foreach ($edge in $refreshEdges) {
                        if (-not $indexByValue.ContainsKey([string]$edge)) { continue }
                        $refreshStrategy = @($pointStrategies | Where-Object { [int]$_['Condition']['Value'] -eq $edge } | Select-Object -First 1)[0]
                        $formation = [int]$refreshStrategy['Strategy']['DefaultFormation']
                        $memo = [string]$refreshStrategy['Strategy']['Memo']
                        if ($formation -ne 7) {
                            $problems += [pscustomobject]@{
                                Workflow = $sortie['Name']
                                Sea = [int]$sortie['Sea']
                                Area = [int]$sortie['Area']
                                RouteSpec = $spec['Id']
                                Problem = "Route spec $($spec['Id']) branch coverage marks edge value $edge from $from as a Refresh branch, but DefaultFormation is $formation instead of Refresh(7)."
                            }
                        }
                        if ($memo -notmatch 'Refresh|刷新|回港|母港|不可|到達不可|到达不可|目标失败|目標失敗') {
                            $problems += [pscustomobject]@{
                                Workflow = $sortie['Name']
                                Sea = [int]$sortie['Sea']
                                Area = [int]$sortie['Area']
                                RouteSpec = $spec['Id']
                                Problem = "Route spec $($spec['Id']) branch coverage marks edge value $edge from $from as a Refresh branch, but strategy memo does not document refresh/return-home failure handling."
                            }
                        }
                    }
                }
            }

            if ($spec.ContainsKey('LosBranchRules') -and $null -ne $spec['LosBranchRules']) {
                $memoText = @($Group['List'] | Where-Object {
                    [string]$_['Type'] -match '\.MemoWorkflow,'
                } | ForEach-Object { [string]$_['Memo'] }) -join "`n"
                $retreatEnabled = @($pointStrategies | Where-Object {
                    [int]$_['Strategy']['DefaultEscortRetreat'] -eq 1
                }).Count -gt 0

                foreach ($rule in @($spec['LosBranchRules'])) {
                    $formula = [regex]::Escape([string]$rule['Formula'])
                    $coefficient = [int]$rule['Coefficient']
                    $threshold = [double]$rule['Threshold']
                    if ($memoText -notmatch "$formula.{0,80}(?:系数|係数)\s*$coefficient.{0,80}$threshold") {
                        $problems += [pscustomobject]@{
                            Workflow = $sortie['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Route spec $($spec['Id']) requires a documented $($rule['Formula']) coefficient $coefficient LoS threshold $threshold for $($rule['From'])->$($rule['To'])."
                        }
                    }
                    if ($retreatEnabled -and [bool]$rule['AuditEverySingleRetreat'] -and
                        $memoText -notmatch '(?:任意一艘|逐艘|每艘).{0,40}退避.{0,120}(?:最低|最小|余量|餘量)') {
                        $problems += [pscustomobject]@{
                            Workflow = $sortie['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Route spec $($spec['Id']) permits retreat before a LoS branch; memo must record every single-ship retreat audit and its conservative minimum/margin."
                        }
                    }
                    if ($retreatEnabled -and $rule.ContainsKey('AuditEveryPairRetreat') -and
                        [bool]$rule['AuditEveryPairRetreat'] -and
                        $memoText -notmatch '(?:联合舰队|聯合艦隊|任意两船|任意兩船|两船组合|兩船組合).{0,80}退避.{0,120}(?:最低|最小|余量|餘量)') {
                        $problems += [pscustomobject]@{
                            Workflow = $sortie['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Route spec $($spec['Id']) permits combined-fleet retreat before a LoS branch; memo must record conservative two-ship retreat minimum/margin."
                        }
                    }
                }
            }

            for ($i = 0; $i -lt $expectedValues.Count - 1; $i++) {
                $current = [string]$expectedValues[$i]
                $next = [string]$expectedValues[$i + 1]
                if (-not $indexByValue.ContainsKey($current) -or -not $indexByValue.ContainsKey($next)) { continue }
                if ([int]$indexByValue[$current] -gt [int]$indexByValue[$next]) {
                    $problems += [pscustomobject]@{
                        Workflow = $sortie['Name']
                        Sea = [int]$sortie['Sea']
                        Area = [int]$sortie['Area']
                        RouteSpec = $spec['Id']
                        Problem = "Route spec $($spec['Id']) expects value $current before $next, but conditional strategies are ordered differently."
                    }
                }
            }

            foreach ($strategy in $pointStrategies) {
                $value = [int]$strategy['Condition']['Value']
                $memo = [string]$strategy['Strategy']['Memo']
                foreach ($node in $expectedNodes) {
                    $letter = [string]$node['Letter']
                    if ($memo -match "(^|\\s|->|→)$([regex]::Escape($letter))(\\s|$|boss|水上|潜水|空袭|空襲|航空戦|航空战)") {
                        $sameLetterValues = @($expectedNodes | Where-Object { [string]$_['Letter'] -eq $letter } | ForEach-Object { [int]$_['Value'] })
                        if ($sameLetterValues -contains $value) { continue }
                        $problems += [pscustomobject]@{
                            Workflow = $sortie['Name']
                            Sea = [int]$sortie['Sea']
                            Area = [int]$sortie['Area']
                            RouteSpec = $spec['Id']
                            Problem = "Strategy memo '$memo' claims node $letter but uses value $value; route spec $($spec['Id']) says node $letter valid value(s) are $($sameLetterValues -join ', ')."
                        }
                    }
                }
            }
        }
    }

    return @($problems)
}

function Get-MemoQualityProblems {
    param([hashtable[]]$MemoWorkflows)

    $problems = @()
    $bannedPatterns = @(
        @{
            Pattern = '未验证.*(点ID|boss点ID|Boss点ID|节点|route|Route)|使用默认boss策略|默认boss策略|若KCPS未识别boss'
            Reason = '出击配置不得在节点 ID 或 boss 条件未验证时交付；必须先补 route spec 和地图点条件策略。'
        },
        @{
            Pattern = '1-6.*使用到达终点.*停止|1-6.*到达给资源的终点|1-6.*ArrivedEndPoint.*启用|1-6.*StopIfArrivedEndPoint.*启用'
            Reason = '当前 KCPS 不把 1-6 的 Sortie_Map16_Clear 计入 ArrivedEndPoint；1-6 护卫成功/N 到达类任务应按路线最后战斗点的点位 rank 计数。'
        },
        @{
            Pattern = '(?m)^第\d+槽：.*(?:艦戦|戦闘機|隼|Spitfire|烈風|震電).*｜按目标舰种补足输出。'
            Reason = '陆航战斗机槽位被误写成输出机职责；应按实际装备类别说明每波制空与降低陆攻损失。'
        }
    )

    foreach ($workflow in @($MemoWorkflows)) {
        $memo = [string]$workflow['Memo']
        if ([string]::IsNullOrWhiteSpace($memo)) { continue }
        foreach ($rule in $bannedPatterns) {
            if ($memo -match [string]$rule.Pattern) {
                $problems += [pscustomobject]@{
                    Workflow = $workflow['Name']
                    Pattern = $rule.Pattern
                    Problem = $rule.Reason
                }
            }
        }
    }

    return @($problems)
}

function Get-KcpsBattleStrategyMemoLanguageProblems {
    param($SortieWorkflows)

    $problems = @()
    $japanesePattern = '[ぁ-ゟ゠-ヿ]|単縦|単横|複縦|輪形|空襲|航空戦|対潜|潜水|水上|針路|選択|能動|無戦闘|到達|経由|発煙|一斉射|旗艦|特殊攻撃|輸送|レ級'
    $englishWordsAllowed = @('PT', 'SS', 'BOSS')
    foreach ($sortie in @($SortieWorkflows)) {
        $entries = @(
            [pscustomobject]@{ Scope = '默认策略'; Cell = $null; Strategy = $sortie['DefaultStrategy'] },
            [pscustomobject]@{ Scope = 'Boss战专用策略'; Cell = $null; Strategy = $sortie['DefaultBossBattleStrategy'] }
        )
        $entries += @($sortie['Strategies'] | ForEach-Object {
            [pscustomobject]@{ Scope = '地图点条件策略'; Cell = [int]$_['Condition']['Value']; Strategy = $_['Strategy'] }
        })
        foreach ($entry in $entries) {
            $memo = [string]$entry.Strategy['Memo']
            if ([string]::IsNullOrWhiteSpace($memo)) { continue }
            $reasons = @()
            if ($memo -match $japanesePattern) {
                $reasons += '含日文假名或日式战斗术语'
            }
            if ($memo -match '首领|首領') {
                $reasons += '使用了旧称“首领”，应改为玩家通用术语“Boss”'
            }
            if ($memo -cmatch '\bboss\b') {
                $reasons += 'Boss 的首字母必须大写'
            }
            # 条件策略通常以 A、B2、ZZ 等地图节点开头；节点不是英文叙述。
            $memoForEnglishCheck = [regex]::Replace($memo, '^[A-Z][A-Z0-9]*(?=（)', '')
            $latinWords = @([regex]::Matches($memoForEnglishCheck, '[A-Za-z]+') | ForEach-Object { $_.Value })
            $englishProse = @($latinWords | Where-Object {
                $_.Length -gt 1 -and $_.ToUpperInvariant() -notin $englishWordsAllowed
            })
            if ($englishProse.Count -gt 0) {
                $reasons += "含英文叙述词: $($englishProse -join ', ')"
            }
            if ($reasons.Count -gt 0) {
                $problems += [pscustomobject]@{
                    Workflow = [string]$sortie['Name']
                    Scope = [string]$entry.Scope
                    Cell = $entry.Cell
                    Memo = $memo
                    Problem = "战斗策略备注必须只用中文（节点字母、数字、P1/P2/P3、胜利等级和PT等必要标识除外）：$($reasons -join '；')。"
                }
            }
        }
    }
    return @($problems)
}

function Convert-StrategySummary {
    param(
        [hashtable]$Strategy,
        [string]$Scope
    )

    if ($null -eq $Strategy) { return $null }
    $midnight = $Strategy['DefaultMidnight']
    $memo = [string]$Strategy['Memo']
    $isAirRaid = ($memo -match '空袭|空襲|air\s*raid') -and ($memo -notmatch '航空戦|航空战|air\s*battle')
    $isWayPointSelection = Test-KcpsWayPointValid -WayPoint $Strategy['DefaultWayPoint']
    $warnings = @()
    $errors = @()
    if ($Scope -eq 'Default' -or $Scope -eq 'Boss') {
        if ($Strategy['DefaultFormation'] -ne 0) { $errors += 'Default battle strategy formation must stay Manual; use point conditional strategies for automation.' }
        if ($Strategy['FallbackFormation'] -ne 0) { $errors += 'Default battle strategy fallback formation must stay Manual.' }
        if ($Strategy['DefaultMidnight'] -ne 0) { $errors += 'Default battle strategy midnight must stay Manual; use point conditional strategies for automation.' }
        if ($Strategy['DefaultAdvance'] -ne 2) { $errors += 'Default battle strategy advance must be Retreat. KCPS only applies escort-heavy-damage force-retreat when a strategy would otherwise auto-advance, so Manual is not a safe fallback.' }
        if ($Strategy['EscortShipsHeavilyDamagedStrategy'] -ne 1) { $errors += 'Default battle strategy escort-heavy-damage setting must force retreat.' }
    } else {
        if ($midnight -eq 0) {
            $intentionalSemiAutomaticNight = $memo -match '夜战手动选择' -and
                $memo -match '斩杀|半自动|止损'
            $isRefreshAtFormation = [int]$Strategy['DefaultFormation'] -eq 7
            if (-not $isAirRaid -and -not $isWayPointSelection -and
                -not $intentionalSemiAutomaticNight -and -not $isRefreshAtFormation) {
                $warnings += 'Manual night battle will pause automation.'
            }
        } elseif ($midnight -ge 3) {
            $errors += 'Conditional midnight strategies 3-7 are not implemented in KCPS and can throw at the midnight choice screen.'
        }
        if ($Strategy['EscortShipsHeavilyDamagedStrategy'] -ne 1) {
            $isEscortDamageWhitelist = $memo -match '大破.*(許可|允许|可|ignore|白名单|白名單)'
            if (-not $isEscortDamageWhitelist) {
                $errors += 'Conditional escort-heavy-damage setting must force retreat unless this exact point is a documented whitelist case in Memo.'
            }
        }
    }

    [pscustomobject]@{
        Scope = $Scope
        Memo = $memo
        Formation = $Strategy['DefaultFormation']
        FormationName = Get-NameFromEnumValue -Map $formationNames -Value $Strategy['DefaultFormation']
        FallbackFormation = $Strategy['FallbackFormation']
        FallbackFormationName = Get-NameFromEnumValue -Map $formationNames -Value $Strategy['FallbackFormation']
        Midnight = $midnight
        MidnightName = Get-NameFromEnumValue -Map $midnightNames -Value $midnight
        Advance = $Strategy['DefaultAdvance']
        AdvanceName = Get-NameFromEnumValue -Map $advanceNames -Value $Strategy['DefaultAdvance']
        Warnings = @($warnings)
        Errors = @($errors)
    }
}

function Get-ConditionSummary {
    param([hashtable]$Condition)
    if ($null -eq $Condition) { return $null }
    $interesting = @{}
    foreach ($key in $Condition.Keys) {
        if ($key -match 'Cell|Point|BattleCount|Boss|Rank|Air|Enemy|Way|Map|Condition|Value') {
            $value = $Condition[$key]
            if ($null -ne $value -and $value -ne $false -and $value -ne '') {
                $interesting[$key] = $value
            }
        }
    }
    $interesting
}
function Get-RelatedThresholdProblems {
    param(
        [hashtable]$Workflow,
        [hashtable]$WorkflowByGuid
    )

    $pairs = @(
        @{ Key = 'SubroutineBeforeWorkflows'; Threshold = 'SubroutineBeforeFinishedEventThreshold'; CompatibleTypes = @() },
        @{ Key = 'SubroutineAfterWorkflows'; Threshold = 'SubroutineAfterFinishedEventThreshold'; CompatibleTypes = @() },
        @{ Key = 'QuestBeforeWorkflows'; Threshold = 'QuestBeforeFinishedEventThreshold'; CompatibleTypes = @('BasicAcceptQuestWorkflow', 'BasicSubmitQuestWorkflow') },
        @{ Key = 'QuestAfterWorkflows'; Threshold = 'QuestAfterFinishedEventThreshold'; CompatibleTypes = @('BasicAcceptQuestWorkflow', 'BasicSubmitQuestWorkflow') },
        @{ Key = 'OrganizeBeforeWorkflows'; Threshold = 'OrganizeBeforeFinishedEventThreshold'; CompatibleTypes = @('BasicOrganizeFleetWorkflow') },
        @{ Key = 'OrganizeAfterWorkflows'; Threshold = 'OrganizeAfterFinishedEventThreshold'; CompatibleTypes = @('BasicOrganizeFleetWorkflow') },
        @{ Key = 'RefitEquipmentBeforeWorkflows'; Threshold = 'RefitEquipmentBeforeFinishedEventThreshold'; CompatibleTypes = @('BasicRefitEquipmentWorkflow') },
        @{ Key = 'RefitEquipmentAfterWorkflows'; Threshold = 'RefitEquipmentAfterFinishedEventThreshold'; CompatibleTypes = @('BasicRefitEquipmentWorkflow') },
        @{ Key = 'ScrapShipBeforeWorkflows'; Threshold = 'ScrapShipBeforeFinishedEventThreshold'; CompatibleTypes = @('BasicScrapShipWorkflow') },
        @{ Key = 'ScrapShipAfterWorkflows'; Threshold = 'ScrapShipAfterFinishedEventThreshold'; CompatibleTypes = @('BasicScrapShipWorkflow') },
        @{ Key = 'DockingBeforeWorkflows'; Threshold = 'DockingBeforeFinishedEventThreshold'; CompatibleTypes = @('BasicDockingWorkflow', 'SimpleDockingWorkflow') },
        @{ Key = 'DockingAfterWorkflows'; Threshold = 'DockingAfterFinishedEventThreshold'; CompatibleTypes = @('BasicDockingWorkflow', 'SimpleDockingWorkflow') },
        @{ Key = 'SupplyBeforeWorkflows'; Threshold = 'SupplyBeforeFinishedEventThreshold'; CompatibleTypes = @('BasicSupplyFleetWorkflow', 'SimpleSupplyFleetWorkflow') },
        @{ Key = 'SupplyAfterWorkflows'; Threshold = 'SupplyAfterFinishedEventThreshold'; CompatibleTypes = @('BasicSupplyFleetWorkflow', 'SimpleSupplyFleetWorkflow') }
    )

    $problems = @()
    foreach ($pair in $pairs) {
        if (-not $Workflow.ContainsKey($pair.Key) -or -not $Workflow.ContainsKey($pair.Threshold)) { continue }
        $refs = @($Workflow[$pair.Key])
        $threshold = [int]$Workflow[$pair.Threshold]
        if ($refs.Count -gt 0 -and $threshold -gt $refs.Count) {
            $problems += [pscustomobject]@{
                Workflow = $Workflow['Name']
                Key = $pair.Key
                ReferenceCount = $refs.Count
                ThresholdKey = $pair.Threshold
                Threshold = $threshold
                Problem = 'Threshold is larger than related workflow count; the controller can wait forever.'
            }
        }

        # RelationalSortieWorkflow only counts stage-specific completion events.
        # Disabled references are treated as already complete; enabled references
        # must point to a workflow type that can emit the expected event.
        if ($refs.Count -gt 0 -and $threshold -gt 0 -and $pair.CompatibleTypes.Count -gt 0) {
            $compatibleCompletionCount = 0
            $incompatibleRefs = @()
            foreach ($ref in $refs) {
                if ($null -eq $ref) {
                    continue
                }
                $refEnabled = -not $ref.ContainsKey('Enabled') -or [bool]$ref['Enabled']
                if (-not $refEnabled) {
                    $compatibleCompletionCount++
                    continue
                }

                $guid = [string]$ref['Guid']
                $target = if ($WorkflowByGuid.ContainsKey($guid)) { $WorkflowByGuid[$guid] } else { $null }
                if ($null -eq $target) { continue }

                $compatible = @($pair.CompatibleTypes | Where-Object {
                    Test-KcpsWorkflowType -Workflow $target -TypeName $_
                }).Count -gt 0
                if ($compatible) {
                    $compatibleCompletionCount++
                } else {
                    $incompatibleRefs += [pscustomobject]@{
                        Guid = $guid
                        Name = [string]$target['Name']
                        Type = [string]$target['Type']
                    }
                }
            }

            if ($threshold -gt $compatibleCompletionCount) {
                $problems += [pscustomobject]@{
                    Workflow = $Workflow['Name']
                    Key = $pair.Key
                    ReferenceCount = $refs.Count
                    CompatibleCompletionCount = $compatibleCompletionCount
                    ThresholdKey = $pair.Threshold
                    Threshold = $threshold
                    IncompatibleReferences = @($incompatibleRefs)
                    Problem = 'Threshold is larger than the number of references that can emit this stage completion event; the controller can wait forever.'
                }
            }
        }
    }
    $problems
}

function Get-KcpsFleetSelectionValue {
    param([int]$Fleet)

    switch ($Fleet) {
        1 { return 0x1 -bor 0x2 }
        2 { return 0x4 -bor 0x8 }
        3 { return 0x10 -bor 0x20 }
        4 { return 0x40 -bor 0x80 }
        default { return $null }
    }
}

function Test-KcpsCombinedSortieGroup {
    param([hashtable]$Group)

    return @($Group['List'] | Where-Object {
        [string]$_['Type'] -match '\.BasicCombinedFleetWorkflow,'
    }).Count -gt 0
}

function Get-KcpsMainSortieFleetSelectionValue {
    param(
        [hashtable]$Group,
        [hashtable]$Sortie,
        [hashtable]$Controller
    )

    if (Test-KcpsCombinedSortieGroup -Group $Group) {
        return 15
    }

    $fleet = if ($Sortie.ContainsKey('Fleet')) {
        [int]$Sortie['Fleet']
    } elseif ($Controller.ContainsKey('Fleet')) {
        [int]$Controller['Fleet']
    } else {
        1
    }
    return Get-KcpsFleetSelectionValue -Fleet $fleet
}

function Get-KcpsSupportFleetSelectionValue {
    param([hashtable]$Group)

    $selection = 0
    foreach ($workflow in @($Group['List'] | Where-Object {
        [string]$_['Type'] -match '\.BasicOrganizeFleetWorkflow,' -and
        [string]$_['Name'] -match '支援'
    })) {
        $value = Get-KcpsFleetSelectionValue -Fleet ([int]$workflow['Fleet'])
        if ($null -ne $value) { $selection = $selection -bor [int]$value }
    }
    return $selection
}

function Get-SortieMoraleBucketMax {
    param(
        [hashtable]$Sortie,
        [int]$DefaultMoraleMax = 32
    )

    $thresholds = @()
    if ($Sortie.ContainsKey('FlagShipMoraleLargerOrEqualThanFlag') -and [bool]$Sortie['FlagShipMoraleLargerOrEqualThanFlag']) {
        $thresholds += [int]$Sortie['FlagShipMoraleLargerOrEqualThanValue']
    }
    if ($Sortie.ContainsKey('EscortShipMoraleLargerOrEqualThanFlag') -and [bool]$Sortie['EscortShipMoraleLargerOrEqualThanFlag']) {
        $thresholds += [int]$Sortie['EscortShipMoraleLargerOrEqualThanValue']
    }
    if ($thresholds.Count -eq 0) { return $DefaultMoraleMax }

    $derived = ([int](@($thresholds | Measure-Object -Minimum).Minimum)) - 1
    if ($derived -lt 0) { return 0 }
    return [Math]::Min($DefaultMoraleMax, $derived)
}

function Get-PostSortieBucketDockingProblems {
    param(
        [hashtable]$Group,
        [object[]]$SortieWorkflows,
        [object[]]$RelWorkflows,
        [object[]]$DockingWorkflows
    )

    $problems = @()
    if (@($SortieWorkflows).Count -eq 0) { return @($problems) }
    if (@($RelWorkflows).Count -eq 0) { return @($problems) }

    $sortie = @($SortieWorkflows | Select-Object -First 1)[0]
    $controller = @($RelWorkflows | Select-Object -First 1)[0]
    $expectedMainFleet = Get-KcpsMainSortieFleetSelectionValue -Group $Group -Sortie $sortie -Controller $controller
    $combined = Test-KcpsCombinedSortieGroup -Group $Group
    $mainFleetDescription = if ($combined) { 'combined first and second fleets' } else { "sortie fleet $([int]$sortie['Fleet'])" }
    $mainDocking = @($DockingWorkflows | Where-Object { $_['Name'] -eq '入渠' })
    $supportDocking = @($DockingWorkflows | Where-Object { $_['Name'] -eq '入渠（支援舰队）' })
    $bucket = @($DockingWorkflows | Where-Object { $_['Name'] -eq '扔桶' })
    $salvage = @($DockingWorkflows | Where-Object { $_['Name'] -eq '捞出' })

    if ($mainDocking.Count -ne 1) {
        $problems += [pscustomobject]@{
            Workflow = '入渠'
            Problem = "Sortie config must contain exactly one pre-sortie main docking workflow named 入渠; found $($mainDocking.Count)."
        }
    } elseif (-not [bool]$mainDocking[0]['LimitFleetFlag'] -or [int]$mainDocking[0]['LimitFleetValue'] -ne [int]$expectedMainFleet) {
        $problems += [pscustomobject]@{
            Workflow = $mainDocking[0]['Name']
            Problem = "LimitFleet must cover the $mainFleetDescription as FleetSelection value $expectedMainFleet."
        }
    }

    if ($supportDocking.Count -gt 0) {
        $expectedSupportFleet = Get-KcpsSupportFleetSelectionValue -Group $Group
        foreach ($supportDock in @($supportDocking)) {
            if ($expectedSupportFleet -le 0) {
                $problems += [pscustomobject]@{
                    Workflow = $supportDock['Name']
                    Problem = 'Support docking exists, but no support-fleet organize workflow was found to derive its fleet selection.'
                }
            } elseif (-not [bool]$supportDock['LimitFleetFlag'] -or [int]$supportDock['LimitFleetValue'] -ne [int]$expectedSupportFleet) {
                $problems += [pscustomobject]@{
                    Workflow = $supportDock['Name']
                    Problem = "LimitFleet must cover every configured support fleet as FleetSelection value $expectedSupportFleet."
                }
            }
        }
    }

    if ($salvage.Count -ne 1) {
        $problems += [pscustomobject]@{
            Workflow = '捞出'
            Problem = "Sortie config must contain exactly one pre-sortie docking workflow named 捞出; found $($salvage.Count)."
        }
    } else {
        $salvageWorkflow = $salvage[0]
        $salvageChecks = @()
        if (-not [bool]$salvageWorkflow['LimitFleetFlag'] -or [int]$salvageWorkflow['LimitFleetValue'] -ne [int]$expectedMainFleet) {
            $salvageChecks += "LimitFleet must cover the $mainFleetDescription as FleetSelection value $expectedMainFleet."
        }
        if (-not [bool]$salvageWorkflow['LimitDockingStateFlag'] -or -not [bool]$salvageWorkflow['LimitDockingStateValueDocking'] -or [bool]$salvageWorkflow['LimitDockingStateValueIdle']) {
            $salvageChecks += 'Docking-state filter must select only ships already repairing.'
        }
        if ([bool]$salvageWorkflow['ForceDocking'] -or -not [bool]$salvageWorkflow['InstantRepair'] -or -not [bool]$salvageWorkflow['ApplyInstantRepairToDockingShips']) {
            $salvageChecks += 'ForceDocking must be false; InstantRepair and ApplyInstantRepairToDockingShips must be true.'
        }
        if (-not [bool]$salvageWorkflow['AutoStop'] -or -not [bool]$salvageWorkflow['Repeat']) {
            $salvageChecks += 'AutoStop and Repeat must be true.'
        }
        if ([bool]$salvageWorkflow['EnableOnLoad'] -or [bool]$salvageWorkflow['TriggerOnEnabled']) {
            $salvageChecks += '捞出 must not EnableOnLoad or TriggerOnEnabled; the controller triggers it before sortie.'
        }
        foreach ($check in $salvageChecks) {
            $problems += [pscustomobject]@{ Workflow = $salvageWorkflow['Name']; Problem = $check }
        }
    }

    if ($bucket.Count -ne 1) {
        $problems += [pscustomobject]@{
            Workflow = '扔桶'
            Problem = "Sortie config must contain exactly one post-sortie bucket docking workflow named 扔桶; found $($bucket.Count)."
        }
        return @($problems)
    }
    $bucket = $bucket[0]

    $expectedMoraleMax = Get-SortieMoraleBucketMax -Sortie $sortie -DefaultMoraleMax 32

    $checks = @()
    if (-not [bool]$bucket['LimitFleetFlag'] -or [int]$bucket['LimitFleetValue'] -ne [int]$expectedMainFleet) {
        $checks += "LimitFleet must cover the $mainFleetDescription as FleetSelection value $expectedMainFleet."
    }
    if (-not [bool]$bucket['LimitHpPercentFlag'] -or [double]$bucket['LimitHpPercentMinValue'] -ne 0.0 -or [double]$bucket['LimitHpPercentMaxValue'] -gt 0.99) {
        $checks += 'HP filter must include damaged ships only: 0.00..0.99, not full-HP ships.'
    }
    if (-not [bool]$bucket['LimitMoraleFlag'] -or [int]$bucket['LimitMoraleMinValue'] -ne 0 -or [int]$bucket['LimitMoraleMaxValue'] -ne $expectedMoraleMax) {
        $checks += "Morale filter must be 0..$expectedMoraleMax, derived from sortie morale threshold and capped at 32."
    }
    if (-not [bool]$bucket['ForceDocking'] -or -not [bool]$bucket['InstantRepair'] -or -not [bool]$bucket['ApplyInstantRepairToDockingShips']) {
        $checks += 'ForceDocking, InstantRepair, and ApplyInstantRepairToDockingShips must be true so the workflow does not hang behind occupied docks and can finish low-morale repairs with buckets.'
    }
    if (-not [bool]$bucket['AutoStop'] -or -not [bool]$bucket['Repeat']) {
        $checks += 'AutoStop and Repeat must be true so the docking workflow loops through eligible ships and stops when none remain.'
    }
    if (-not [bool]$bucket['SkipExpeditioningShips']) {
        $checks += 'SkipExpeditioningShips must be true.'
    }
    if ([bool]$bucket['EnableOnLoad'] -or [bool]$bucket['TriggerOnEnabled']) {
        $checks += '扔桶 must not EnableOnLoad or TriggerOnEnabled; the controller triggers it after sortie.'
    }
    if ([int]$bucket['Docks'] -le 0) {
        $checks += 'Docks must include at least one repair dock.'
    }
    foreach ($check in $checks) {
        $problems += [pscustomobject]@{
            Workflow = $bucket['Name']
            Problem = $check
        }
    }

    if (-not (Test-RelatedWorkflowRef -Refs $controller['DockingAfterWorkflows'] -Guid $bucket['Guid'])) {
        $problems += [pscustomobject]@{
            Workflow = $controller['Name']
            Problem = '扔桶 is not enabled in DockingAfterWorkflows; post-sortie fatigue recovery will not run.'
        }
    }

    $preSortieDocking = @($DockingWorkflows | Where-Object { $_['Name'] -ne '扔桶' })
    $combinedWorkflows = @($Group['List'] | Where-Object {
        ($_ -is [System.Collections.IDictionary]) -and
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicCombinedFleetWorkflow')
    })
    if ($combined) {
        if ($combinedWorkflows.Count -ne 1) {
            $problems += [pscustomobject]@{
                Workflow = '组成联合舰队'
                Problem = "Combined sortie config must contain exactly one BasicCombinedFleetWorkflow; found $($combinedWorkflows.Count)."
            }
        } else {
            $combinedWorkflow = $combinedWorkflows[0]
            if (-not (Test-RelatedWorkflowRef -Refs $controller['DockingBeforeWorkflows'] -Guid $combinedWorkflow['Guid'])) {
                $problems += [pscustomobject]@{
                    Workflow = $controller['Name']
                    Problem = '组成联合舰队 is not enabled in DockingBeforeWorkflows; the controller will organize both fleets but never form the combined fleet before sortie.'
                }
            } else {
                $enabledBeforeRefs = @($controller['DockingBeforeWorkflows'] | Where-Object {
                    $null -ne $_ -and (-not $_.ContainsKey('Enabled') -or [bool]$_['Enabled'])
                })
                if ($enabledBeforeRefs.Count -eq 0 -or [string]$enabledBeforeRefs[0]['Guid'] -ne [string]$combinedWorkflow['Guid']) {
                    $problems += [pscustomobject]@{
                        Workflow = $controller['Name']
                        Problem = '组成联合舰队 must be the first enabled DockingBeforeWorkflows operation.'
                    }
                }
            }
        }
    }
    foreach ($dock in @($preSortieDocking)) {
        if (-not (Test-RelatedWorkflowRef -Refs $controller['DockingBeforeWorkflows'] -Guid $dock['Guid'])) {
            $problems += [pscustomObject]@{
                Workflow = $controller['Name']
                DockingWorkflow = $dock['Name']
                Problem = 'Non-bucket docking workflows such as 入渠/捞出 must be enabled in DockingBeforeWorkflows, not in post-sortie docking.'
            }
        }
        if (Test-RelatedWorkflowRef -Refs $controller['DockingAfterWorkflows'] -Guid $dock['Guid']) {
            $problems += [pscustomObject]@{
                Workflow = $controller['Name']
                DockingWorkflow = $dock['Name']
                Problem = 'Only 扔桶 belongs in DockingAfterWorkflows; 捞出 and other normal docking workflows must run before sortie.'
            }
        }
    }
    if (Test-RelatedWorkflowRef -Refs $controller['DockingBeforeWorkflows'] -Guid $bucket['Guid']) {
        $problems += [pscustomObject]@{
            Workflow = $controller['Name']
            DockingWorkflow = $bucket['Name']
            Problem = '扔桶 must not be enabled in DockingBeforeWorkflows; it is only a post-sortie fatigue recovery workflow.'
        }
    }

    $dockingWorkflowGuids = @{}
    foreach ($dock in @($preSortieDocking)) {
        $dockingWorkflowGuids[[string]$dock['Guid']] = $true
    }
    $enabledBeforeCompletionCount = @($controller['DockingBeforeWorkflows'] | Where-Object {
        $null -ne $_ -and
        (-not $_.ContainsKey('Enabled') -or [bool]$_['Enabled']) -and
        $dockingWorkflowGuids.ContainsKey([string]$_['Guid'])
    }).Count
    if (@($controller['DockingBeforeWorkflows']).Count -gt 0 -and [int]$controller['DockingBeforeFinishedEventThreshold'] -ne $enabledBeforeCompletionCount) {
        $problems += [pscustomobject]@{
            Workflow = $controller['Name']
            Problem = "DockingBeforeFinishedEventThreshold must equal enabled pre-sortie docking completion count ($enabledBeforeCompletionCount). BasicCombinedFleetWorkflow is triggered in this phase but does not emit a docking completion event."
        }
    }

    $enabledAfterCount = @($controller['DockingAfterWorkflows'] | Where-Object { $null -ne $_ -and (-not $_.ContainsKey('Enabled') -or [bool]$_['Enabled']) }).Count
    if ([int]$controller['DockingAfterFinishedEventThreshold'] -ne $enabledAfterCount) {
        $problems += [pscustomobject]@{
            Workflow = $controller['Name']
            Problem = "DockingAfterFinishedEventThreshold must equal enabled DockingAfterWorkflows count ($enabledAfterCount) so the controller waits for all post-sortie docking workflows."
        }
    }

    foreach ($dock in @($DockingWorkflows)) {
        if (-not (Test-RelatedWorkflowRef -Refs $controller['AutoStoppedDisableWorkflows'] -Guid $dock['Guid'])) {
            $problems += [pscustomobject]@{
                Workflow = $controller['Name']
                DockingWorkflow = $dock['Name']
                Problem = 'Every BasicDockingWorkflow in the config must be enabled in AutoStoppedDisableWorkflows so looping docking workflows are disabled when the sortie controller finishes.'
            }
        }
    }

    return @($problems)
}

function Get-UsedLandBaseCorps {
    param([hashtable]$Sortie)

    $used = @()
    foreach ($corps in 1..3) {
        $key = "LandBasedAirCorps$($corps)Action"
        if (-not $Sortie.ContainsKey($key)) { continue }
        $action = [int]$Sortie[$key]
        if ($action -in 1, 2) {
            $used += [pscustomobject]@{
                Corps = $corps
                Action = $action
            }
        }
    }
    return @($used)
}

function Get-LandBaseRestProblems {
    param(
        [hashtable]$Group,
        [object[]]$SortieWorkflows,
        [object[]]$RelWorkflows,
        [object[]]$SupplyWorkflows,
        [hashtable]$RouteSpec
    )

    $problems = @()
    if (@($SortieWorkflows).Count -eq 0 -or @($RelWorkflows).Count -eq 0) { return @($problems) }

    $list = @($Group['List'])
    $sortie = @($SortieWorkflows | Select-Object -First 1)[0]
    $controller = @($RelWorkflows | Select-Object -First 1)[0]
    $usedCorps = @(Get-UsedLandBaseCorps -Sortie $sortie)
    $landBaseWorkflows = @($list | Where-Object {
        Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOutfitLandBasedAirCorpWorkflow'
    })
    $restWorkflows = @($landBaseWorkflows | Where-Object {
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOutfitLandBasedAirCorpWorkflow') -and
        ([string]$_['Name'] -match '^陆航休息[123]$')
    })

    if ($usedCorps.Count -eq 0) {
        if ($landBaseWorkflows.Count -gt 0) {
            $problems += [pscustomobject]@{
                Workflow = $controller['Name']
                Problem = 'This sortie does not use land-base action Mission/AirDefense, but contains land-base workflow(s). Remove all stale land-base setup/rest placeholders.'
            }
        }
        return @($problems)
    }

    foreach ($entry in $usedCorps) {
        $corps = [int]$entry.Corps
        $action = [int]$entry.Action
        $point1 = $sortie["LandBasedAirCorps$($corps)Point1"]
        $point2 = $sortie["LandBasedAirCorps$($corps)Point2"]
        $expectedFatigueCheck = $true
        if ($RouteSpec -and [string]$RouteSpec['StageDesign']['Phase'] -eq 'Leveling') {
            $checks = $RouteSpec['StageDesign']['LandBaseFatigueChecks']
            if ($checks -and $checks.Contains([string]$corps) -and $checks[[string]$corps] -is [bool]) {
                $expectedFatigueCheck = $checks[[string]$corps]
            }
        }
        if ([bool]$sortie["LandBasedAirCorps$($corps)CheckFatigue"] -ne $expectedFatigueCheck) {
            $problems += [pscustomobject]@{
                Workflow = $sortie['Name']
                Corps = $corps
                Problem = "Land-base corps $corps fatigue checking must match its policy ($expectedFatigueCheck)."
            }
        }
        if ([int]$sortie["LandBasedAirCorps$($corps)Resupply"] -ne 15) {
            $problems += [pscustomobject]@{
                Workflow = $sortie['Name']
                Corps = $corps
                Problem = "Used land-base corps $corps must resupply all four squadrons (mask 15)."
            }
        }
        if ($action -eq 1 -and ($null -eq $point1 -or $null -eq $point2)) {
            $problems += [pscustomobject]@{
                Workflow = $sortie['Name']
                Corps = $corps
                Problem = "Mission land-base corps $corps must configure both target point ranges."
            }
        }
        if ($action -eq 2 -and ($null -ne $point1 -or $null -ne $point2)) {
            $problems += [pscustomobject]@{
                Workflow = $sortie['Name']
                Corps = $corps
                Problem = "Air-defense land-base corps $corps must not retain sortie target point ranges."
            }
        }
        $matches = @($restWorkflows | Where-Object { [int]$_['Corps'] -eq $corps })
        if ($matches.Count -ne 1) {
            $problems += [pscustomobject]@{
                Workflow = $controller['Name']
                Corps = $corps
                Problem = "Used land-base corps $corps must have exactly one post-sortie 陆航休息$corps workflow; found $($matches.Count)."
            }
            continue
        }
        $workflow = $matches[0]
        $checks = @()
        if ([string]$workflow['Name'] -ne "陆航休息$corps") {
            $checks += "Workflow name must be 陆航休息$corps so the suffix matches the land-base corps number."
        }
        if ([int]$workflow['Sea'] -ne [int]$sortie['Sea'] -or [int]$workflow['Area'] -ne [int]$sortie['Area']) {
            $checks += "Sea/Area must match sortie $($sortie['Sea'])-$($sortie['Area'])."
        }
        if (-not [bool]$workflow['SetAction'] -or [int]$workflow['Action'] -ne 4) {
            $checks += 'SetAction must be true and Action must be Rest(4).'
        }
        if (-not [bool]$workflow['Resupply'] -or [int]$workflow['ResupplySquadrons'] -ne 15) {
            $checks += 'Resupply must be true and ResupplySquadrons must be All(15), so used land bases are supplied while flipping to rest.'
        }
        if ([bool]$workflow['SetAirplanes']) {
            $checks += 'SetAirplanes must be false; 陆航休息 only changes action/rest and resupplies.'
        }
        if (-not [bool]$workflow['SuccessIfAirCorpNotAvailable']) {
            $checks += 'SuccessIfAirCorpNotAvailable should be true so an unavailable air corps does not fail this rest-only workflow.'
        }
        if ([bool]$workflow['WaitHomeAtFirst'] -or [bool]$workflow['RefreshDataBefore'] -or [bool]$workflow['ReturnRoomAtLast']) {
            $checks += 'WaitHomeAtFirst, RefreshDataBefore, and ReturnRoomAtLast should be false because the sortie controller already owns the flow.'
        }
        if ([bool]$workflow['EnableOnLoad'] -or [bool]$workflow['TriggerOnEnabled']) {
            $checks += '陆航休息 must not EnableOnLoad or TriggerOnEnabled; the sortie controller triggers it after sortie.'
        }
        if (-not (Test-RelatedWorkflowRef -Refs $controller['SupplyAfterWorkflows'] -Guid $workflow['Guid'])) {
            $checks += '陆航休息 must be enabled in SupplyAfterWorkflows, because RelationalSortieWorkflow has no dedicated land-base-after phase.'
        }

        $sortieIndex = [array]::IndexOf(@($list | ForEach-Object { $_['Guid'] }), $sortie['Guid'])
        $restIndex = [array]::IndexOf(@($list | ForEach-Object { $_['Guid'] }), $workflow['Guid'])
        if ($sortieIndex -ge 0 -and $restIndex -ge 0 -and $restIndex -le $sortieIndex) {
            $checks += '陆航休息 workflow should be listed after 出击 for UI readability and to mirror actual post-sortie use.'
        }

        foreach ($check in $checks) {
            $problems += [pscustomobject]@{
                Workflow = $workflow['Name']
                Corps = $corps
                Problem = $check
            }
        }
    }

    foreach ($workflow in $landBaseWorkflows) {
        $corps = [int]$workflow['Corps']
        if ($corps -notin @($usedCorps | ForEach-Object { [int]$_.Corps })) {
            $problems += [pscustomobject]@{
                Workflow = $workflow['Name']
                Corps = $corps
                Problem = "Unused land-base corps $corps must not retain a setup/rest workflow."
            }
        } elseif ([string]$workflow['Name'] -notmatch '^陆航休息[123]$') {
            $problems += [pscustomobject]@{
                Workflow = $workflow['Name']
                Corps = $corps
                Problem = 'Used land-base corps must have only its numbered post-sortie 陆航休息 workflow; action, resupply, fatigue check, and target ranges belong to the sortie workflow.'
            }
        }
    }

    $enabledSupplyAfterRefs = @($controller['SupplyAfterWorkflows'] | Where-Object {
        $null -ne $_ -and (-not $_.ContainsKey('Enabled') -or [bool]$_['Enabled'])
    })
    $expectedThreshold = 0
    foreach ($ref in $enabledSupplyAfterRefs) {
        $targets = @($list | Where-Object { $_['Guid'] -eq $ref['Guid'] } | Select-Object -First 1)
        if ($targets.Count -eq 0) {
            $problems += [pscustomobject]@{
                Workflow = $controller['Name']
                Problem = "SupplyAfterWorkflows contains an unresolved workflow reference: $($ref['Guid'])."
            }
            continue
        }
        $target = $targets[0]
        if ($null -ne $target -and (Test-KcpsWorkflowType -Workflow $target -TypeName 'BasicSupplyFleetWorkflow')) {
            $expectedThreshold++
        }
    }
    if ([int]$controller['SupplyAfterFinishedEventThreshold'] -ne $expectedThreshold) {
        $problems += [pscustomobject]@{
            Workflow = $controller['Name']
            Problem = "SupplyAfterFinishedEventThreshold must count only workflows that emit the SupplyAfter-stage event ($expectedThreshold), not 陆航休息 workflows."
        }
    }

    return @($problems)
}

function Test-RelatedWorkflowRef {
    param(
        [object]$Refs,
        [string]$Guid,
        [bool]$RequireEnabled = $true
    )

    foreach ($ref in @($Refs)) {
        if ($null -eq $ref -or -not $ref.ContainsKey('Guid')) { continue }
        if ($ref['Guid'] -ne $Guid) { continue }
        if ($RequireEnabled -and $ref.ContainsKey('Enabled') -and $ref['Enabled'] -eq $false) { continue }
        return $true
    }
    return $false
}

function Get-KcpsExpectedClearMessage {
    param([string]$GroupName)

    if ([string]::IsNullOrWhiteSpace($GroupName)) { return $null }
    $parts = @($GroupName -split '\s+' | Where-Object { $_ })
    if ($parts.Count -lt 2) { return $null }

    $frequencyPattern = '^(?:单次|日常|月常|周常|季常|年常(?:[1-9]|1[0-2])月)(?:（不确定）)?$'
    $kindPattern = '^(?:出击|编成|演习|工厂|远征|改装|补给／入渠)$'
    if ($parts.Count -ge 2 -and $parts[0] -match $frequencyPattern -and $parts[1] -match $kindPattern) {
        # 新命名规则不再在配置名中保存 TaskId。Clear 消息与显示配置名解耦，交给消息格式和监听一致性校验。
        return $null
    }

    $taskId = $parts[0]
    $areaIndex = -1
    for ($i = $parts.Count - 1; $i -ge 0; $i--) {
        if ($parts[$i] -match '^\d+-\d+$') {
            $areaIndex = $i
            break
        }
    }
    if ($areaIndex -lt 0) { return $null }

    $messageParts = @($taskId, $parts[$areaIndex])
    if ($areaIndex + 1 -lt $parts.Count) {
        $phase = $parts[$areaIndex + 1]
        if ($phase -match '^(?:P\d+(?:开路|開路)?|开路|開路|ギミック)$') {
            $messageParts += $phase
        }
    }
    return "$(($messageParts -join ' ')) Clear"
}

function Test-RuleMapContains {
    param(
        [object]$Map,
        [string]$Key
    )

    return ($null -ne $Map -and $Map.ContainsKey($Key) -and [int]$Map[$Key] -eq 1)
}

function New-KcpsExSlotContext {
    param(
        [hashtable]$Start2,
        [hashtable]$MemberShips,
        [hashtable]$MemberEquips
    )

    if ($null -eq $Start2) { return $null }

    $equipmentByName = @{}
    $equipmentById = @{}
    foreach ($equip in @($Start2['api_mst_slotitem'])) {
        $id = [string]$equip['api_id']
        $equipmentById[$id] = $equip
        if (-not $equipmentByName.ContainsKey($equip['api_name'])) {
            $equipmentByName[$equip['api_name']] = $equip
        }
    }

    $shipById = @{}
    $shipNameToIds = @{}
    foreach ($ship in @($Start2['api_mst_ship'])) {
        $id = [string]$ship['api_id']
        $shipById[$id] = $ship
        $name = [string]$ship['api_name']
        if (-not $shipNameToIds.ContainsKey($name)) {
            $shipNameToIds[$name] = @()
        }
        $shipNameToIds[$name] += [int]$ship['api_id']
    }

    $ownedShipConstById = @{}
    foreach ($entry in $MemberShips.GetEnumerator()) {
        $ownedShipConstById[[string]$entry.Key] = [int]$entry.Value['api_ship_id']
    }

    $ownedEquipmentLevelsByConstId = @{}
    $ownedEquipmentCountsByName = @{}
    $ownedEquipmentLevelsByName = @{}
    foreach ($entry in $MemberEquips.GetEnumerator()) {
        $equip = $entry.Value
        $constId = [string]$equip['api_slotitem_id']
        $level = [int]$equip['api_level']
        if (-not $ownedEquipmentLevelsByConstId.ContainsKey($constId)) {
            $ownedEquipmentLevelsByConstId[$constId] = @()
        }
        $ownedEquipmentLevelsByConstId[$constId] += $level
        if ($equipmentById.ContainsKey($constId)) {
            $name = [string]$equipmentById[$constId]['api_name']
            if (-not $ownedEquipmentCountsByName.ContainsKey($name)) {
                $ownedEquipmentCountsByName[$name] = 0
            }
            if (-not $ownedEquipmentLevelsByName.ContainsKey($name)) {
                $ownedEquipmentLevelsByName[$name] = @()
            }
            $ownedEquipmentCountsByName[$name]++
            $ownedEquipmentLevelsByName[$name] += $level
        }
    }

    # 普通装备槽兼容性: 舰种(stype)可装类别 ∪ 单舰额外可装类别(api_mst_equip_ship)
    $stypeEquipCats = @{}
    foreach ($stype in @($Start2['api_mst_stype'])) {
        $set = [System.Collections.Generic.HashSet[int]]::new()
        $et = $stype['api_equip_type']
        if ($null -ne $et) {
            foreach ($kv in $et.GetEnumerator()) {
                if ([int]$kv.Value -eq 1) { [void]$set.Add([int]$kv.Key) }
            }
        }
        $stypeEquipCats[[string]$stype['api_id']] = $set
    }
    $shipEquipShipCats = @{}
    if ($null -ne $Start2['api_mst_equip_ship']) {
        foreach ($entry in $Start2['api_mst_equip_ship'].GetEnumerator()) {
            $set = [System.Collections.Generic.HashSet[int]]::new()
            $inner = $entry.Value['api_equip_type']
            if ($null -ne $inner) {
                foreach ($ikv in $inner.GetEnumerator()) { [void]$set.Add([int]$ikv.Key) }
            }
            $shipEquipShipCats[[string]$entry.Key] = $set
        }
    }

    [pscustomobject]@{
        EquipmentByName = $equipmentByName
        EquipmentById = $equipmentById
        ShipById = $shipById
        ShipNameToIds = $shipNameToIds
        OwnedShipConstById = $ownedShipConstById
        OwnedEquipmentLevelsByConstId = $ownedEquipmentLevelsByConstId
        OwnedEquipmentCountsByName = $ownedEquipmentCountsByName
        OwnedEquipmentLevelsByName = $ownedEquipmentLevelsByName
        ExSlotTypeIds = @($Start2['api_mst_equip_exslot'] | ForEach-Object { [int]$_ })
        ExSlotShipRules = $Start2['api_mst_equip_exslot_ship']
        HasCompleteExSlotShipRules = ($null -ne $Start2['api_mst_equip_exslot_ship'] -and @($Start2['api_mst_equip_exslot_ship'].Keys | Where-Object { $_ -match '^\d+$' }).Count -gt 0)
        StypeEquipCats = $stypeEquipCats
        ShipEquipShipCats = $shipEquipShipCats
        HasCompleteShipEquipRules = ($null -ne $Start2['api_mst_equip_ship'])
    }
}

function Get-ConfigShipConstId {
    param(
        [hashtable]$Ship,
        [object]$ExSlotContext
    )

    $memo = [string]$Ship['Memo']
    # 活动配置会把多号机写成“船名 #2 (实例ID)”。括号内实例 ID
    # 比 # 后的多号机编号更明确，必须优先解析。
    if ($memo -match '\((?<id>\d+)\)') {
        $ownedId = $Matches.id
        if ($ExSlotContext.OwnedShipConstById.ContainsKey($ownedId)) {
            return [int]$ExSlotContext.OwnedShipConstById[$ownedId]
        }
    }
    if ($memo -match '#(?<id>\d+)') {
        $ownedId = $Matches.id
        if ($ExSlotContext.OwnedShipConstById.ContainsKey($ownedId)) {
            return [int]$ExSlotContext.OwnedShipConstById[$ownedId]
        }
    }

    $shipName = ($memo -replace '\s*#.*$', '')
    if ($ExSlotContext.ShipNameToIds.ContainsKey($shipName)) {
        return [int]@($ExSlotContext.ShipNameToIds[$shipName])[0]
    }

    return $null
}

function Test-KcpsExSlotEquipment {
    param(
        [hashtable]$Ship,
        [string]$EquipmentName,
        [object]$ExSlotContext
    )

    if ($null -eq $ExSlotContext) { return $null }
    if (-not $ExSlotContext.EquipmentByName.ContainsKey($EquipmentName)) {
        return "SlotEx unknown equipment name '$EquipmentName'; cannot validate ex-slot compatibility."
    }

    $shipConstId = Get-ConfigShipConstId -Ship $Ship -ExSlotContext $ExSlotContext
    if ($null -eq $shipConstId -or -not $ExSlotContext.ShipById.ContainsKey([string]$shipConstId)) {
        return "SlotEx cannot resolve ship '$($Ship['Memo'])' to master ship id; cannot validate ex-slot compatibility."
    }

    $shipConst = $ExSlotContext.ShipById[[string]$shipConstId]
    $equip = $ExSlotContext.EquipmentByName[$EquipmentName]
    $equipId = [string]$equip['api_id']
    $equipType = [int]$equip['api_type'][2]
    $genericAllowed = $ExSlotContext.ExSlotTypeIds -contains $equipType

    $specialMatched = $false
    $reqLevel = 0
    if ($ExSlotContext.ExSlotShipRules.ContainsKey($equipId)) {
        $rule = $ExSlotContext.ExSlotShipRules[$equipId]
        $specialMatched = (Test-RuleMapContains -Map $rule['api_ship_ids'] -Key ([string]$shipConstId)) `
            -or (Test-RuleMapContains -Map $rule['api_stypes'] -Key ([string]$shipConst['api_stype'])) `
            -or (Test-RuleMapContains -Map $rule['api_stypes'] -Key '99') `
            -or (Test-RuleMapContains -Map $rule['api_ctypes'] -Key ([string]$shipConst['api_ctype']))
        if ($specialMatched) {
            $reqLevel = [int]$rule['api_req_level']
        }
    }

    if (-not $genericAllowed -and -not $specialMatched) {
        if (-not $ExSlotContext.HasCompleteExSlotShipRules) { return $null }
        return "SlotEx '$EquipmentName' is not allowed for $($shipConst['api_name']) by api_mst_equip_exslot/api_mst_equip_exslot_ship."
    }

    if ($specialMatched -and $reqLevel -gt 0) {
        $levels = @()
        if ($ExSlotContext.OwnedEquipmentLevelsByConstId.ContainsKey($equipId)) {
            $levels = @($ExSlotContext.OwnedEquipmentLevelsByConstId[$equipId])
        }
        if (@($levels | Where-Object { $_ -ge $reqLevel }).Count -eq 0) {
            return "SlotEx '$EquipmentName' for $($shipConst['api_name']) requires improvement level >= $reqLevel, but no owned candidate currently satisfies it."
        }
    }

    return $null
}

$script:KcpsEquipCategoryNames = @{
    1='小口径主砲';2='中口径主砲';3='大口径主砲';4='副砲';5='魚雷';6='艦上戦闘機';7='艦上爆撃機';8='艦上攻撃機';
    9='艦上偵察機';10='水上偵察機';11='水上爆撃機';12='小型電探';13='大型電探';14='ソナー';15='爆雷';16='追加装甲';
    17='機関部強化';18='対空強化弾';19='対艦強化弾';20='VT信管';21='対空機銃';22='特殊潜航艇';23='応急修理要員';
    24='上陸用舟艇';25='オートジャイロ';26='対潜哨戒機';27='追加装甲(中型)';28='追加装甲(大型)';29='探照灯';
    30='簡易輸送部材';31='艦艇修理施設';32='潜水艦魚雷';33='噴進砲';34='司令部施設';35='航空要員';36='高射装置';
    37='対地装備';38='大口径主砲(II)';39='水上艦要員';40='大型ソナー';41='大型飛行艇';42='大型探照灯';43='戦闘糧食';
    44='補給物資';45='水上戦闘機';46='特型内火艇';47='陸上攻撃機';48='局地戦闘機';49='陸上偵察機';50='輸送機材';
    56='噴式戦闘機';57='噴式戦闘爆撃機';58='噴式攻撃機'
}

# 普通装备槽: 校验装备类别能否装在该母舰(局地戦闘機/陸上機 上空母这类硬不兼容)
function Test-KcpsConventionalSlotEquipment {
    param(
        [hashtable]$Ship,
        [string]$EquipmentName,
        [object]$ExSlotContext
    )

    if ($null -eq $ExSlotContext) { return $null }
    if ([string]::IsNullOrWhiteSpace($EquipmentName)) { return $null }
    # 未知装备名: 交给库存检查, 这里不误报
    if (-not $ExSlotContext.EquipmentByName.ContainsKey($EquipmentName)) { return $null }

    $shipConstId = Get-ConfigShipConstId -Ship $Ship -ExSlotContext $ExSlotContext
    if ($null -eq $shipConstId -or -not $ExSlotContext.ShipById.ContainsKey([string]$shipConstId)) { return $null }

    $shipConst = $ExSlotContext.ShipById[[string]$shipConstId]
    $equip = $ExSlotContext.EquipmentByName[$EquipmentName]
    $equipCat = [int]$equip['api_type'][2]

    $stypeId = [string]$shipConst['api_stype']
    $inStype = $ExSlotContext.StypeEquipCats.ContainsKey($stypeId) -and $ExSlotContext.StypeEquipCats[$stypeId].Contains($equipCat)
    $inShip = $ExSlotContext.ShipEquipShipCats.ContainsKey([string]$shipConstId) -and $ExSlotContext.ShipEquipShipCats[[string]$shipConstId].Contains($equipCat)

    if (-not $inStype -and -not $inShip) {
        if (-not $ExSlotContext.HasCompleteShipEquipRules) { return $null }
        $catName = if ($script:KcpsEquipCategoryNames.ContainsKey($equipCat)) { $script:KcpsEquipCategoryNames[$equipCat] } else { "类别$equipCat" }
        return "'$EquipmentName' (类别$equipCat=$catName) 不可装备于 $($shipConst['api_name']); 该装备类别与母舰槽位不兼容(KCPS换装会失败,连累相邻槽)。"
    }

    return $null
}

function Normalize-KcpsShipMemo {
    param([string]$Memo)

    if ($null -eq $Memo) { return '' }
    $value = $Memo.Trim()
    $value = $value -replace '^\[', '' -replace '\]$', ''
    $value = $value -replace '\s*\(\d+\)', ''
    $value = $value -replace '\s*#\d+', ''
    return $value.Trim()
}

function New-KcpsRouteContext {
    param(
        [hashtable]$Start2,
        [hashtable]$MemberShips
    )

    if ($null -eq $Start2) { return $null }

    $stypeById = @{}
    foreach ($stype in @($Start2['api_mst_stype'])) {
        $stypeById[[string]$stype['api_id']] = [string]$stype['api_name']
    }

    $masterShipById = @{}
    $shipNameToMaster = @{}
    foreach ($ship in @($Start2['api_mst_ship'])) {
        $id = [string]$ship['api_id']
        $masterShipById[$id] = $ship
        $name = [string]$ship['api_name']
        if (-not $shipNameToMaster.ContainsKey($name)) {
            $shipNameToMaster[$name] = $ship
        }
    }

    $ownedShipConstById = @{}
    foreach ($entry in $MemberShips.GetEnumerator()) {
        $ownedShipConstById[[string]$entry.Key] = [int]$entry.Value['api_ship_id']
    }

    [pscustomobject]@{
        StypeById = $stypeById
        MasterShipById = $masterShipById
        ShipNameToMaster = $shipNameToMaster
        OwnedShipConstById = $ownedShipConstById
    }
}

function Resolve-KcpsShipInfoFromSelection {
    param(
        [hashtable]$Selection,
        [object]$RouteContext
    )

    if ($null -eq $RouteContext -or $null -eq $Selection) { return $null }

    $masterShip = $null
    $ownedId = [string]$Selection['Value']
    if ($RouteContext.OwnedShipConstById.ContainsKey($ownedId)) {
        $constId = [string]$RouteContext.OwnedShipConstById[$ownedId]
        if ($RouteContext.MasterShipById.ContainsKey($constId)) {
            $masterShip = $RouteContext.MasterShipById[$constId]
        }
    }

    if ($null -eq $masterShip) {
        $name = Normalize-KcpsShipMemo ([string]$Selection['Memo'])
        if ($RouteContext.ShipNameToMaster.ContainsKey($name)) {
            $masterShip = $RouteContext.ShipNameToMaster[$name]
        }
    }

    if ($null -eq $masterShip) { return $null }
    $stypeName = $RouteContext.StypeById[[string]$masterShip['api_stype']]

    [pscustomobject]@{
        Name = [string]$masterShip['api_name']
        ShipType = $stypeName
        ShipTypeId = [int]$masterShip['api_stype']
        Speed = [int]$masterShip['api_soku']
        MasterId = [int]$masterShip['api_id']
        OwnedId = $ownedId
        Memo = [string]$Selection['Memo']
    }
}

function Test-KcpsMasterShipSameBase {
    param(
        [int]$MasterIdA,
        [int]$MasterIdB,
        [object]$RouteContext
    )

    if ($MasterIdA -eq $MasterIdB) { return $true }
    if ($null -eq $RouteContext) { return $false }
    if (-not $RouteContext.MasterShipById.ContainsKey([string]$MasterIdA) -or -not $RouteContext.MasterShipById.ContainsKey([string]$MasterIdB)) {
        return $false
    }

    $shipA = $RouteContext.MasterShipById[[string]$MasterIdA]
    $shipB = $RouteContext.MasterShipById[[string]$MasterIdB]
    if ([Math]::Floor([int]$shipA['api_sort_id'] / 10) -eq [Math]::Floor([int]$shipB['api_sort_id'] / 10)) {
        return $true
    }

    function Test-InheritPath {
        param(
            [int]$FromId,
            [int]$ToId,
            [object]$Context
        )

        $verified = @{}
        $currentId = $FromId
        while ($true) {
            if ($currentId -eq $ToId) { return $true }
            if ($verified.ContainsKey([string]$currentId)) { return $false }
            $verified[[string]$currentId] = $true
            if (-not $Context.MasterShipById.ContainsKey([string]$currentId)) { return $false }
            $current = $Context.MasterShipById[[string]$currentId]
            $nextId = [int]$current['api_aftershipid']
            if ($nextId -eq 0) { return $false }
            $currentId = $nextId
        }
    }

    return (Test-InheritPath -FromId $MasterIdA -ToId $MasterIdB -Context $RouteContext) -or `
        (Test-InheritPath -FromId $MasterIdB -ToId $MasterIdA -Context $RouteContext)
}

function Get-KcpsPrimaryFleetShips {
    param(
        [hashtable]$OrganizeWorkflow,
        [object]$RouteContext
    )

    $ships = @()
    $index = 0
    foreach ($pos in @($OrganizeWorkflow['Positions'])) {
        $index++
        $selection = @($pos['Selections'] | Where-Object { $null -ne $_ } | Select-Object -First 1)
        if ($selection.Count -eq 0) { continue }
        $info = Resolve-KcpsShipInfoFromSelection -Selection $selection[0] -RouteContext $RouteContext
        if ($null -eq $info) { continue }
        $info | Add-Member -NotePropertyName Position -NotePropertyValue $index
        $ships += $info
    }
    return @($ships)
}

function Get-KcpsOrganizeSameBaseProblems {
    param(
        [hashtable[]]$OrganizeWorkflows,
        [object]$RouteContext
    )

    $problems = @()
    if ($null -eq $RouteContext) { return @($problems) }

    foreach ($organize in @($OrganizeWorkflows)) {
        $ships = @(Get-KcpsPrimaryFleetShips -OrganizeWorkflow $organize -RouteContext $RouteContext)
        for ($i = 0; $i -lt $ships.Count; $i++) {
            for ($j = $i + 1; $j -lt $ships.Count; $j++) {
                if (Test-KcpsMasterShipSameBase -MasterIdA $ships[$i].MasterId -MasterIdB $ships[$j].MasterId -RouteContext $RouteContext) {
                    $problems += [pscustomobject]@{
                        Workflow = $organize['Name']
                        PositionA = $ships[$i].Position
                        ShipA = "$($ships[$i].Name)#$($ships[$i].OwnedId)"
                        PositionB = $ships[$j].Position
                        ShipB = "$($ships[$j].Name)#$($ships[$j].OwnedId)"
                        Problem = 'KCPS BasicOrganizeFleetWorkflow expands already selected ships to all same-base ships; same-base selections in one fleet can make later positions fail.'
                    }
                }
            }
        }
    }

    return @($problems)
}

function Get-KcpsSlotRestrictionProblems {
    # 部分舰的特定装备槽有类型限制。优先按 api_type[2] 判定，名称正则只在 master 未知时后备，避免把対潜短魚雷(爆雷类)误判为攻击用魚雷。
    param(
        $RefitWorkflows,
        $Rules,
        $EquipmentContext
    )
    $problems = @()
    if (@($Rules).Count -eq 0) { return @($problems) }
    foreach ($refit in @($RefitWorkflows)) {
        foreach ($ship in @($refit['Ships'])) {
            $shipMemo = [string]$ship['Memo']
            foreach ($rule in @($Rules)) {
                $shipRe = [string]$rule['shipNameRegex']
                if ([string]::IsNullOrWhiteSpace($shipRe) -or $shipMemo -notmatch $shipRe) { continue }
                $slotNo = [int]$rule['slot']
                $forbidTypeIds = @($rule['forbidTypeIds'] | ForEach-Object { [int]$_ })
                $allowTypeIds = @($rule['allowTypeIds'] | ForEach-Object { [int]$_ })
                $forbid = [string]$rule['forbidNameRegex']
                $allow = [string]$rule['allowNameRegex']
                foreach ($slot in @($ship['Slots'])) {
                    if ([int]$slot['Slot'] -ne $slotNo) { continue }
                    foreach ($eq in @($slot['Equipments'])) {
                        $name = [string]$eq['SelectValue']
                        if ([string]::IsNullOrWhiteSpace($name)) { continue }
                        $equipType = $null
                        if ($null -ne $EquipmentContext -and $EquipmentContext.EquipmentByName.ContainsKey($name)) {
                            $equipType = [int]$EquipmentContext.EquipmentByName[$name]['api_type'][2]
                        }
                        $blocked = $false
                        if ($null -ne $equipType -and $forbidTypeIds.Count -gt 0) {
                            $blocked = $forbidTypeIds -contains [int]$equipType
                        }
                        elseif (-not [string]::IsNullOrWhiteSpace($forbid)) {
                            $blocked = $name -match $forbid
                        }
                        # 装备 master 可用时只按类别判定；名称规则仅供 master 未知时后备，不能覆盖结构化禁用类别。
                        $allowed = if ($null -ne $equipType) {
                            $allowTypeIds -contains [int]$equipType
                        }
                        else {
                            -not [string]::IsNullOrWhiteSpace($allow) -and $name -match $allow
                        }
                        if ($blocked -and -not $allowed) {
                            $typeText = if ($null -ne $equipType) { " (api_type[2]=$equipType)" } else { '' }
                            $problems += [pscustomobject]@{
                                Workflow = [string]$refit['Name']
                                Ship = $shipMemo
                                Slot = $slotNo
                                Equipment = $name
                                Problem = "Slot $slotNo of $shipMemo cannot equip '$name'${typeText}: $([string]$rule['note']) KCPS will fail at runtime with 'slot N: no equipment matched'."
                            }
                        }
                    }
                }
            }
        }
    }
    return @($problems)
}

$start2 = $null
$const = $null
$memberShips = @{}
$memberEquips = @{}
$memberMaps = @{}
if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
    $snapshot = Read-KcpsJson -Path $SnapshotPath
    foreach ($key in @('const', 'ships', 'equips', 'maps')) {
        if (-not $snapshot.ContainsKey($key)) {
            throw "Snapshot is missing required key: $key"
        }
    }

    $const = $snapshot['const']
    $start2 = [ordered]@{
        api_mst_ship = @($const['$ships'].Values)
        api_mst_stype = @($const['$shipTypes'].Values)
        api_mst_slotitem = @($const['$equips'].Values)
        api_mst_equip_exslot = @($const['$exslotEquips'])
        api_mst_equip_exslot_ship = $const['$exslotEquipShips']
        api_mst_equip_ship = $const['$equipShip']
    }
    $memberShips = $snapshot['ships']
    $memberEquips = $snapshot['equips']
    $memberMaps = $snapshot['maps']
} else {
    try {
        $start2 = Get-PoiJson -BaseUrl $BaseUrl -Path '/response?type=/kcsapi/api_start2/getData'
        $memberShips = Get-PoiData -BaseUrl $BaseUrl -Type 'ships'
        $memberEquips = Get-PoiData -BaseUrl $BaseUrl -Type 'equips'
    } catch {
        $start2 = $null
    }
    try {
        $const = Get-PoiData -BaseUrl $BaseUrl -Type 'const'
    } catch {
        $const = $null
    }
    try {
        $memberMaps = Get-PoiData -BaseUrl $BaseUrl -Type 'maps'
    } catch {
        $memberMaps = @{}
    }
}
$exSlotContext = New-KcpsExSlotContext -Start2 $start2 -MemberShips $memberShips -MemberEquips $memberEquips
$routeContext = New-KcpsRouteContext -Start2 $start2 -MemberShips $memberShips
$consumableEquipmentNames = @(
    '応急修理要員',
    '応急修理女神',
    '戦闘糧食',
    '戦闘糧食(特別なおにぎり)',
    '秋刀魚の缶詰',
    '洋上補給'
)

$cfg = Read-KcpsJson -Path $Path
$groups = Get-KcpsGroups -Config $cfg
$routeSpecPath = Join-Path $PSScriptRoot '..\data\KCPS-RouteSpecs.json'
$routeSpecs = Read-KcpsRouteSpecs -SpecPath $routeSpecPath
$specialAttackRulePath = Join-Path $PSScriptRoot '..\data\KCPS-SpecialAttackRules.json'
$specialAttackRules = Read-KcpsSpecialAttackRules -RulePath $specialAttackRulePath
$fitBonusPath = Join-Path $PSScriptRoot '..\data\KCPS-FitBonus.json'
$slotRestrictionRules = @()
if (Test-Path -LiteralPath $fitBonusPath) {
    $fitBonusDoc = Get-Content -LiteralPath $fitBonusPath -Raw | ConvertFrom-Json -AsHashtable
    if ($fitBonusDoc.ContainsKey('slotRestrictions') -and $fitBonusDoc['slotRestrictions'].ContainsKey('rules')) {
        $slotRestrictionRules = @($fitBonusDoc['slotRestrictions']['rules'])
    }
}
$groupResults = @()
$fileProblems = @()
$sortieChainPolicy = if (-not [string]::IsNullOrWhiteSpace($SortieChainPolicyPath)) {
    Read-KcpsJson -Path $SortieChainPolicyPath
} else { $null }
$sortieChainCheck = Get-KcpsSortieChainValidation -Groups @($groups) -PolicyDocument $sortieChainPolicy
foreach ($problem in @($sortieChainCheck.Problems)) {
    $fileProblems += "Sortie chain [$($problem.Code)] $($problem.Group): $($problem.Problem)"
}
$fileGuidRows = @(
    foreach ($group in $groups) {
        foreach ($workflow in @($group['List'])) {
            if (-not $workflow.ContainsKey('Guid')) { continue }
            [pscustomobject]@{
                Guid = [string]$workflow['Guid']
                Group = [string]$group['Name']
                Workflow = [string]$workflow['Name']
            }
        }
    }
)
foreach ($duplicate in @($fileGuidRows | Group-Object Guid | Where-Object Count -gt 1)) {
    $locations = @($duplicate.Group | ForEach-Object { "$($_.Group)/$($_.Workflow)" }) -join ' | '
    $fileProblems += "Workflow GUID $($duplicate.Name) is duplicated across the config file: $locations"
}
$duplicateGroupNames = @($groups | Group-Object { [string]$_['Name'] } | Where-Object Count -gt 1)
foreach ($duplicate in $duplicateGroupNames) {
    $fileProblems += "Config name is duplicated within the file: $($duplicate.Name)"
}
$totalProblems = $fileProblems.Count
$hardcodedRuleFreshness = Get-KcpsHardcodedRuleFreshness -Rules $hardcodedRuleRegistry
$routeSpecFreshness = Get-KcpsRouteSpecFreshness -RouteSpecDocument $routeSpecs

foreach ($group in $groups) {
    $list = @($group['List'])
    $guidMap = @{}
    $workflowByGuid = @{}
    foreach ($workflow in $list) {
        if ($workflow.ContainsKey('Guid')) {
            $guidMap[$workflow['Guid']] = $workflow['Name']
            $workflowByGuid[[string]$workflow['Guid']] = $workflow
        }
    }

    $workflowTypeLoadProblems = @(Get-KcpsWorkflowTypeLoadProblems -Workflows $list)
    $workflowRefShapeProblems = @(Get-KcpsSortieWorkflowReferenceProblems -Workflows $list)
    $jsonCollectionShapeProblems = @()
    foreach ($workflow in $list) {
        $workflowRefShapeProblems += Get-WorkflowRefShapeProblems -Workflow $workflow -Keys $workflowRefCollectionKeys
        $jsonCollectionShapeProblems += Get-KcpsJsonCollectionShapeProblems -Node $workflow -WorkflowName ([string]$workflow['Name']) -Path ([string]$workflow['Name'])
    }
    $jsonCollectionShapeProblems = @($jsonCollectionShapeProblems | Where-Object { $workflowRefCollectionKeys -notcontains $_.Key })

    $refs = @()
    foreach ($workflow in $list) {
        $refs += Get-WorkflowRefs -Workflow $workflow -Keys (@(
            'SortieWorkflow',
            'Workflows'
        ) + $workflowRefCollectionKeys)
    }

    $brokenRefs = foreach ($ref in $refs) {
        if (-not $guidMap.ContainsKey($ref.Guid)) { $ref }
    }

    $memoWorkflows = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'MemoWorkflow' })
    $questWorkflows = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicAcceptQuestWorkflow' })
    $organizeWorkflows = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow' })
    $refitWorkflows = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicRefitEquipmentWorkflow' })
    $dockingWorkflows = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicDockingWorkflow' })
    $supplyWorkflows = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicSupplyFleetWorkflow' })
    $sortieWorkflows = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleSortieWorkflow' })
    $relWorkflows = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'RelationalSortieWorkflow' })
    $sortieSeaValues = @($sortieWorkflows | ForEach-Object { if ($_.ContainsKey('Sea')) { [int]$_['Sea'] } else { -1 } })
    $isNormalSortieGroup = @($sortieWorkflows).Count -gt 0 -and @($sortieSeaValues | Where-Object { $_ -lt 1 -or $_ -gt 7 }).Count -eq 0
    $isEventSortieGroup = @($sortieWorkflows).Count -gt 0 -and @($sortieSeaValues | Where-Object { $_ -eq 0 }).Count -gt 0
    $matchingGroupRouteSpecs = @($routeSpecs['Routes'] | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_['GroupNameRegex']) -and
        (Test-KcpsRouteSpecGroupName -GroupName ([string]$group['Name']) -RouteSpec $_)
    })
    $groupRouteSpec = if ($matchingGroupRouteSpecs.Count -eq 1) { $matchingGroupRouteSpecs[0] } else { $null }
    $isDeclaredFutureStage = $null -ne $groupRouteSpec -and
        $groupRouteSpec.ContainsKey('FutureStagePrerequisite') -and
        -not [string]::IsNullOrWhiteSpace([string]$groupRouteSpec['FutureStagePrerequisite'])

    $questProblems = @()
    foreach ($questWorkflow in $questWorkflows) {
        foreach ($selector in @($questWorkflow['Quests'])) {
            $questId = [string]$selector['SelectValue']
            if ([int]$selector['SelectMethod'] -ne 0) {
                $questProblems += "$($questWorkflow['Name']):quest selector must use game api_no ID."
            }
            if ($questId -notmatch '^\d+$') {
                $questProblems += "$($questWorkflow['Name']):quest id '$questId' is not numeric."
            }
            if (-not [bool]$selector['FailIfNotExist']) {
                $questProblems += "$($questWorkflow['Name']):quest $questId must set FailIfNotExist=true; missing or wrong quest ids must stop the sortie."
            }
            if ([bool]$selector['SuccessIfFull']) {
                $questProblems += "$($questWorkflow['Name']):quest $questId must set SuccessIfFull=false; a full quest list must not allow sortie continuation."
            }
        }
    }

    $positions = @()
    $organizeEnumProblems = @()
    $multiCandidateRotationProblems = @()
    $singleCandidateSalvageProblems = @()
    foreach ($organize in $organizeWorkflows) {
        $index = 0
        foreach ($pos in @($organize['Positions'])) {
            $index++
            $selectionCount = @($pos['Selections']).Count
            $sortingMethod = [int]$pos['SelectionSortingMethod']
            if ($sortingMethod -lt 1 -or $sortingMethod -gt 7) {
                $organizeEnumProblems += "$($organize['Name']) position ${index}: SelectionSortingMethod=$sortingMethod is invalid; KCPS OrganizeSelectionSortingMethod values are 1..7."
            }
            $rotationProblem = $null
            if ($selectionCount -gt 1 -and @($sortieWorkflows).Count -gt 0) {
                if (-not $isNormalSortieGroup) {
                    $rotationProblem = 'Multiple ship candidates are not allowed on event/tag-lock maps; equivalent-ship fatigue rotation is normal-map only.'
                } else {
                    $sortie = @($sortieWorkflows | Select-Object -First 1)[0]
                    $threshold = 33
                    if ($index -eq 1 -and [bool]$sortie['FlagShipMoraleLargerOrEqualThanFlag']) {
                        $threshold = [int]$sortie['FlagShipMoraleLargerOrEqualThanValue']
                    } elseif ($index -ne 1 -and [bool]$sortie['EscortShipMoraleLargerOrEqualThanFlag']) {
                        $threshold = [int]$sortie['EscortShipMoraleLargerOrEqualThanValue']
                    }
                    $max = [Math]::Max(0, $threshold - 1)
                    $problems = @()
                    if (-not [bool]$pos['ChangeIfMoraleInRangeFlag'] -or [int]$pos['ChangeIfMoraleInRangeValueMin'] -ne 0 -or [int]$pos['ChangeIfMoraleInRangeValueMax'] -ne $max) {
                        $problems += "ChangeIfMoraleInRange must be 0..$max."
                    }
                    if (-not [bool]$pos['SkipMoraleInRangeFlag'] -or [int]$pos['SkipMoraleInRangeValueMin'] -ne 0 -or [int]$pos['SkipMoraleInRangeValueMax'] -ne $max) {
                        $problems += "SkipMoraleInRange must be 0..$max."
                    }
                    if ([int]$pos['SelectionSortingMethod'] -ne 1) {
                        $problems += 'SelectionSortingMethod must be Original(1).'
                    }
                    if ([bool]$pos['IncludeCurrentShip'] -or [bool]$pos['IncludeCurrentSelection']) {
                        $problems += 'IncludeCurrentShip/IncludeCurrentSelection must be false for deterministic candidate order.'
                    }
                    if ([bool]$pos['KeepIfAllSelectionsFailed']) {
                        $problems += 'KeepIfAllSelectionsFailed must be false so controller retry can handle fatigue.'
                    }
                    if (-not [bool]$pos['ChangeIfRepairing'] -or -not [bool]$pos['SkipRepairingShips']) {
                        $problems += 'Multi-candidate rotation must change and skip repairing ships so it can select a ready equivalent copy.'
                    }
                    $selectionIds = @($pos['Selections'] | ForEach-Object {
                        if (($_ -is [hashtable]) -and $_.ContainsKey('Value') -and (($_['Value'] -as [string]) -match '^\d+$')) {
                            [int]$_['Value']
                        }
                    })
                    if ($selectionIds.Count -gt 1 -and $memberShips.Count -gt 0) {
                        $anchorId = [string]$selectionIds[0]
                        if ($memberShips.ContainsKey($anchorId)) {
                            $anchor = $memberShips[$anchorId]
                            $anchorConstId = [int]$anchor['api_ship_id']
                            $anchorExtra = Test-KcpsShipExtraSlotAvailable -Ship $anchor
                            foreach ($selectionId in @($selectionIds | Select-Object -Skip 1)) {
                                $selectionKey = [string]$selectionId
                                if (-not $memberShips.ContainsKey($selectionKey)) { continue }
                                $candidate = $memberShips[$selectionKey]
                                if ([int]$candidate['api_ship_id'] -ne $anchorConstId) {
                                    $problems += "Candidate $selectionId is not the same remodel as anchor $anchorId."
                                } elseif ((Test-KcpsShipExtraSlotAvailable -Ship $candidate) -ne $anchorExtra) {
                                    $problems += "Candidate $selectionId extra-slot availability differs from anchor $anchorId; opened extra slot = api_slot_ex != 0 (-1 empty or >0 equipped both count as opened; only 0 means not opened)."
                                }
                            }
                        }
                    }
                    if (@($problems).Count -gt 0) {
                        $rotationProblem = ($problems -join ' ')
                    }
                }
                if ($rotationProblem) {
                    $multiCandidateRotationProblems += "$($organize['Name']) position ${index}: $rotationProblem"
                }
            }
            $isFixedSingleCandidate = $selectionCount -eq 1 -and
                [int]@($pos['Selections'])[0]['Type'] -eq 0
            if ($isFixedSingleCandidate -and @($sortieWorkflows).Count -gt 0) {
                if ([bool]$pos['ChangeIfRepairing'] -or [bool]$pos['SkipRepairingShips']) {
                    $singleCandidateSalvageProblems += "$($organize['Name']) position ${index}: a fixed single candidate must set ChangeIfRepairing=false and SkipRepairingShips=false, otherwise organize rejects the repairing ship before pre-sortie 捞出 can bucket it."
                }
            }
            $positions += [pscustomobject]@{
                Workflow = $organize['Name']
                Position = $index
                SelectionCount = $selectionCount
                Selections = @($pos['Selections'] | ForEach-Object { "$($_['Type']):$($_['Value']) [$($_['Memo'])]" })
                KeepIfEmpty = $pos['KeepIfSelectionCollectionEmpty']
                KeepIfAllFailed = $pos['KeepIfAllSelectionsFailed']
                RotationProblem = $rotationProblem
                Problem = $(if ($selectionCount -eq 0 -and -not $pos['KeepIfSelectionCollectionEmpty']) { 'Empty candidate row can fail organization.' } else { $null })
            }
        }
    }

    $refitSlots = @()
    $slotProblems = @()
    $slotMasters = @{}
    if ($null -ne $start2) {
        foreach ($master in @($start2['api_mst_ship'])) { $slotMasters[[string]$master['api_id']] = $master }
    }
    $refitSlotExistenceProblems = @(Get-KcpsRefitSlotExistenceProblems -Workflows @($group['List']) `
        -OwnedShips $memberShips -MasterShips $slotMasters `
        -RejectOptionalFixedSlots:(@($sortieWorkflows | Where-Object { [int]$_['Sea'] -eq 0 }).Count -gt 0))
    $slotProblems += @($refitSlotExistenceProblems | ForEach-Object { $_.Problem })
    $slotProblems += @(Get-KcpsRefitSlotContinuityProblems -Workflows @($group['List']) | ForEach-Object { $_.Problem })
    $refitOrderWarnings = @()
    $dynamicOrganizeFleets = @{}
    foreach ($organize in $organizeWorkflows) {
        $hasDynamicSelection = @($organize['Positions'] | Where-Object {
            @($_['Selections'] | Where-Object { [int]$_['Type'] -ne 0 }).Count -gt 0
        }).Count -gt 0
        if ($hasDynamicSelection) {
            $dynamicOrganizeFleets[[int]$organize['Fleet']] = $true
        }
    }
    foreach ($refit in $refitWorkflows) {
        $fleetUtilitySelections = @()
        $exactEquipmentRequests = @{}
        $exactEquipmentRequestDetails = @{}
        foreach ($ship in @($refit['Ships'])) {
            $isDynamicRefitShip = $dynamicOrganizeFleets.ContainsKey([int]$ship['Fleet'])
            $shipSlots = @($ship['Slots'] | ForEach-Object { [int]$_['Slot'] })
            $fixedWithoutExtra = [int]$ship['SelectMethod'] -eq 3 -and
                $memberShips.Contains([string]$ship['SelectValue']) -and
                [int]$memberShips[[string]$ship['SelectValue']]['api_slot_ex'] -eq 0
            if ($shipSlots -notcontains 6 -and -not $fixedWithoutExtra) {
                $slotProblems += "$($refit['Name']) $($ship['SelectValue']):missing slot6 SlotEx strategy"
            }
            foreach ($slot in @($ship['Slots'])) {
                if (Test-KcpsDeclaredEmptyRefitSlot -Ship $ship -Slot $slot) { continue }
                $equipmentCount = @($slot['Equipments']).Count
                if (-not $isDynamicRefitShip -and $equipmentCount -ne 1) {
                    $slotProblems += "$($refit['Name']) $($ship['SelectValue']):slot$($slot['Slot']) has $equipmentCount selectors"
                }
                foreach ($equipment in @($slot['Equipments'])) {
                    $equipmentName = [string]$equipment['SelectValue']
                    if ($equipmentCount -eq 1 -and
                        [int]$equipment['SelectMethod'] -eq 0 -and
                        -not [bool]$slot['IgnoreNoEquipmentMatched'] -and
                        -not [string]::IsNullOrWhiteSpace($equipmentName)) {
                        if (-not $exactEquipmentRequests.ContainsKey($equipmentName)) {
                            $exactEquipmentRequests[$equipmentName] = 0
                            $exactEquipmentRequestDetails[$equipmentName] = @()
                        }
                        $exactEquipmentRequests[$equipmentName]++
                        $exactEquipmentRequestDetails[$equipmentName] += [pscustomobject]@{
                            Ship = [string]$ship['Memo']
                            ShipSelectValue = [string]$ship['SelectValue']
                            Slot = [int]$slot['Slot']
                        }
                    }
                    if (-not $AllowConsumables -and $equipmentName -in $consumableEquipmentNames) {
                        $slotProblems += "$($refit['Name']) $($ship['Memo']):slot$($slot['Slot']) uses consumable equipment '$equipmentName'; default sortie configs must not use consumables without explicit user approval."
                    }
                    if ($equipmentName -like '彩雲*') {
                        $fleetUtilitySelections += "$($ship['Memo']):slot$($slot['Slot'])=$equipmentName"
                    }
                }
                if (-not $isDynamicRefitShip -and [int]$slot['Slot'] -eq 6) {
                    foreach ($equipment in @($slot['Equipments'])) {
                        $exSlotProblem = Test-KcpsExSlotEquipment -Ship $ship -EquipmentName ([string]$equipment['SelectValue']) -ExSlotContext $exSlotContext
                        if ($exSlotProblem) {
                            $slotProblems += "$($refit['Name']) $($ship['Memo']):slot6 $exSlotProblem"
                        }
                    }
                }
                elseif (-not $isDynamicRefitShip) {
                    foreach ($equipment in @($slot['Equipments'])) {
                        if ([int]$equipment['SelectMethod'] -ne 0) { continue }
                        $compatProblem = Test-KcpsConventionalSlotEquipment -Ship $ship -EquipmentName ([string]$equipment['SelectValue']) -ExSlotContext $exSlotContext
                        if ($compatProblem) {
                            $slotProblems += "$($refit['Name']) $($ship['Memo']):slot$($slot['Slot']) $compatProblem"
                        }
                    }
                }
                $refitSlots += [pscustomobject]@{
                    Workflow = $refit['Name']
                    Ship = $ship['SelectValue']
                    Slot = $slot['Slot']
                    EquipmentCount = $equipmentCount
                    Equipments = @($slot['Equipments'] | ForEach-Object { $_['SelectValue'] })
                    IgnoreNoEquipmentMatched = $slot['IgnoreNoEquipmentMatched']
                    IgnoreSlotNotAvailable = $slot['IgnoreSlotNotAvailable']
                }
            }
        }
        if ($null -ne $exSlotContext) {
            $capacityProblems = @(Get-KcpsRefitEquipmentCapacityProblems -RefitWorkflows @($refit) -OwnedEquipmentCountsByName $exSlotContext.OwnedEquipmentCountsByName)
            foreach ($capacityProblem in $capacityProblems) {
                $slotProblems += "$($capacityProblem.Workflow): $($capacityProblem.Problem)"
            }
            foreach ($name in @($exactEquipmentRequests.Keys)) {
                $needed = [int]$exactEquipmentRequests[$name]
                $owned = 0
                if ($exSlotContext.OwnedEquipmentCountsByName.ContainsKey($name)) {
                    $owned = [int]$exSlotContext.OwnedEquipmentCountsByName[$name]
                }
                if ($needed -gt $owned) {
                    $slotProblems += "$($refit['Name']):requests exact equipment '$name' $needed time(s), but current inventory only has $owned; later slots can fail."
                }
                if ($needed -gt 1) {
                    $ownedLevels = @()
                    if ($exSlotContext.OwnedEquipmentLevelsByName.ContainsKey($name)) {
                        $ownedLevels = @($exSlotContext.OwnedEquipmentLevelsByName[$name] | Sort-Object -Unique)
                    }
                    if (@($ownedLevels).Count -gt 1) {
                        $details = @($exactEquipmentRequestDetails[$name] | ForEach-Object { "$($_.Ship):slot$($_.Slot)" }) -join ' | '
                        $refitOrderWarnings += [pscustomobject]@{
                            Workflow = $refit['Name']
                            Equipment = $name
                            OwnedLevels = @($ownedLevels)
                            Requests = $needed
                            RequestOrder = $details
                            Warning = 'Same-name equipment has multiple improvement levels; confirm Ships/Slots order so high-star copies are selected by the ships/slots that need them.'
                        }
                    }
                }
            }
        }
        if (-not $AllowRepeatedFleetUtilityEquipment -and @($fleetUtilitySelections).Count -gt 1) {
            $slotProblems += "$($refit['Name']):repeats fleet-level utility equipment 彩雲 family $(@($fleetUtilitySelections) -join ' | '); T-disadvantage prevention does not stack, so repeated 彩雲 needs explicit justification."
        }
    }

    $sortieSummaries = @()
    $escortRetreatEquipmentProblems = @()
    foreach ($sortie in $sortieWorkflows) {
        $strategies = @()
        $sortieProblems = @()
        $strategies += Convert-StrategySummary -Strategy $sortie['DefaultStrategy'] -Scope 'Default'
        $strategies += Convert-StrategySummary -Strategy $sortie['DefaultBossBattleStrategy'] -Scope 'Boss'
        if ($sortie['DefaultBossBattleStrategyFlag']) {
            $sortieProblems += 'Default boss battle strategy checkbox must be off; configure boss behavior with a map-point conditional strategy.'
        }
        if (@($sortie['Strategies']).Count -eq 0) {
            $sortieProblems += 'No conditional map-point battle strategies; safe fallback will retreat/manual-pause instead of clearing automatically.'
        }
        $index = 0
        foreach ($conditional in @($sortie['Strategies'])) {
            $index++
            $summary = Convert-StrategySummary -Strategy $conditional['Strategy'] -Scope "Conditional#$index"
            if ($null -ne $summary) {
                $summary | Add-Member -NotePropertyName Condition -NotePropertyValue (Get-ConditionSummary -Condition $conditional['Condition'])
                if ($conditional['Condition']['Type'] -ne 1) {
                    $sortieProblems += "Conditional#$index must use map-point condition Type=1."
                }
                $strategies += $summary
            }
        }
        $sortieProblems += @($strategies | ForEach-Object { @($_.Warnings) + @($_.Errors) } | Where-Object { $_ })
        $sortieSummaries += [pscustomobject]@{
            Name = $sortie['Name']
            Fleet = $sortie['Fleet']
            Sea = $sortie['Sea']
            Area = $sortie['Area']
            Strategies = @($strategies)
            Problems = @($sortieProblems)
        }

        $usesEscortRetreat = [int]$sortie['DefaultStrategy']['DefaultEscortRetreat'] -eq 1 -or
            ([bool]$sortie['DefaultBossBattleStrategyFlag'] -and
                [int]$sortie['DefaultBossBattleStrategy']['DefaultEscortRetreat'] -eq 1) -or
            @($sortie['Strategies'] | Where-Object {
                [int]$_['Strategy']['DefaultEscortRetreat'] -eq 1
            }).Count -gt 0
        if (-not $usesEscortRetreat) { continue }

        $fleet = [int]$sortie['Fleet']
        $strikingOrganize = @($organizeWorkflows | Where-Object {
            [int]$_['Fleet'] -eq $fleet -and @($_['Positions']).Count -eq 7
        } | Select-Object -First 1)
        if ($strikingOrganize.Count -eq 0) { continue }

        $flagshipSelection = @($strikingOrganize[0]['Positions'][0]['Selections'] | Where-Object {
            [int]$_['Type'] -eq 0 -and [string]$_['Value'] -match '^\d+$'
        }) | Select-Object -First 1
        $flagshipId = if ($null -eq $flagshipSelection) { 0 } else { [int]$flagshipSelection['Value'] }
        $flagshipRows = @($refitWorkflows | ForEach-Object {
            @($_['Ships'] | Where-Object {
                [int]$_['Fleet'] -eq $fleet -and (
                    ([int]$_['SelectMethod'] -eq 0 -and [int]$_['SelectValue'] -eq 1) -or
                    ([int]$_['SelectMethod'] -eq 3 -and [int]$_['SelectValue'] -eq $flagshipId)
                )
            })
        })
        $hasYugekiCommand = @($flagshipRows | ForEach-Object {
            @($_['Slots'] | Where-Object {
                [int]$_['Slot'] -ne 6 -and
                @($_['Equipments'] | Where-Object {
                    [int]$_['SelectMethod'] -eq 0 -and
                    [string]$_['SelectValue'] -eq '遊撃部隊 艦隊司令部'
                }).Count -gt 0
            })
        }).Count -gt 0

        $hasEliteTorpedoCommand = @($flagshipRows | ForEach-Object {
            @($_['Slots'] | Where-Object {
                @($_['Equipments'] | Where-Object {
                    [int]$_['SelectMethod'] -eq 0 -and
                    [string]$_['SelectValue'] -eq '精鋭水雷戦隊 司令部'
                }).Count -gt 0
            })
        }).Count -gt 0

        $eliteTorpedoCompositionValid = $false
        if ($hasEliteTorpedoCommand -and $null -ne $routeContext) {
            $escortStrikingPositions = @($strikingOrganize[0]['Positions'])
            $flagshipTypes = if ($escortStrikingPositions.Count -ge 1) {
                @($escortStrikingPositions[0]['Selections'] | Where-Object { $null -ne $_ } | ForEach-Object {
                    $shipInfo = Resolve-KcpsShipInfoFromSelection -Selection $_ -RouteContext $routeContext
                    if ($null -ne $shipInfo) { [int]$shipInfo.ShipTypeId }
                } | Sort-Object -Unique)
            } else {
                @()
            }
            $companionTypes = @()
            if ($escortStrikingPositions.Count -ge 2) {
                foreach ($position in @($escortStrikingPositions[1..($escortStrikingPositions.Count - 1)])) {
                    $companionTypes += @($position['Selections'] | Where-Object { $null -ne $_ } | ForEach-Object {
                        $shipInfo = Resolve-KcpsShipInfoFromSelection -Selection $_ -RouteContext $routeContext
                        if ($null -ne $shipInfo) { [int]$shipInfo.ShipTypeId }
                    })
                }
                $companionTypes = @($companionTypes | Sort-Object -Unique)
            }
            $eliteTorpedoCompositionValid =
                @($flagshipTypes).Count -gt 0 -and
                @($flagshipTypes | Where-Object { $_ -notin @(2, 3) }).Count -eq 0 -and
                @($companionTypes).Count -gt 0 -and
                @($companionTypes | Where-Object { $_ -notin @(2, 4) }).Count -eq 0
        }

        if (-not $hasYugekiCommand -and -not ($hasEliteTorpedoCommand -and $eliteTorpedoCompositionValid)) {
            $reason = if ($hasEliteTorpedoCommand) {
                '精鋭水雷戦隊 司令部 is selected, but every flagship candidate must be a DD/CL and every companion candidate must be a DD/CLT for its single-ship retreat.'
            } else {
                'The flagship does not select 遊撃部隊 艦隊司令部 or a composition-valid 精鋭水雷戦隊 司令部.'
            }
            $escortRetreatEquipmentProblems += [pscustomobject]@{
                Workflow = [string]$sortie['Name']
                Fleet = $fleet
                Problem = "A seven-ship striking-force sortie enables single-ship retreat. $reason"
            }
        }
    }

    $relatedThresholdProblems = @()
    foreach ($rel in $relWorkflows) {
        $relatedThresholdProblems += Get-RelatedThresholdProblems -Workflow $rel -WorkflowByGuid $workflowByGuid
    }
    $highMoraleSingleLoopProblems = @(Get-KcpsHighMoraleSingleLoopProblems -SortieWorkflows $sortieWorkflows -RelationalWorkflows $relWorkflows)
    $postSortieDockingProblems = @(Get-PostSortieBucketDockingProblems -Group $group -SortieWorkflows $sortieWorkflows -RelWorkflows $relWorkflows -DockingWorkflows $dockingWorkflows)
    $landBaseRestProblems = @(Get-LandBaseRestProblems -Group $group -SortieWorkflows $sortieWorkflows -RelWorkflows $relWorkflows -SupplyWorkflows $supplyWorkflows -RouteSpec $groupRouteSpec)
    $mapHpExistenceRangeProblems = @()
    $mapGaugeTypeProblems = @()
    $mapGaugePurposeProblems = @()
    $groupMemoText = (@($memoWorkflows | ForEach-Object { [string]$_['Memo'] }) -join "`n")
    $stageText = ([string]$group['Name']) + "`n" + $groupMemoText
    $isDocumentedGaugePhaseGate = $stageText -match '(?:磨血|削血|击破|斩杀|最終|最终)' -and
        $stageText -match '(?:允许区间|允許区間|门禁|門禁)'
    $isPointUnlockObjective = $stageText -match '(?:开路|開路|解谜|解謎|ギミック|削甲|破甲)' -and
        $stageText -match '(?:[A-Z][A-Z0-9]*点|目标点|目標点).{0,60}(?:S胜|S勝|A胜|A勝|到达|到達)'
    foreach ($sortieWorkflow in $sortieWorkflows) {
        if ([bool]$sortieWorkflow['MapHpInRangeFlag'] -and
            [int]$sortieWorkflow['MapHpInRangeValueMin'] -eq 1 -and
            [int]$sortieWorkflow['MapHpInRangeValueMax'] -lt 99999 -and
            -not $isDocumentedGaugePhaseGate) {
            $mapHpExistenceRangeProblems += [pscustomobject]@{
                Workflow = [string]$sortieWorkflow['Name']
                Gauge = [int]$sortieWorkflow['MapHpInRangeValueGauge']
                Min = [int]$sortieWorkflow['MapHpInRangeValueMin']
                Max = [int]$sortieWorkflow['MapHpInRangeValueMax']
                Problem = 'Both map HP-gauge and TP-gauge existence checks must use the open range 1..99999; 9999 is not a safe upper bound.'
            }
        }
        if ([bool]$sortieWorkflow['MapHpInRangeFlag'] -and $memberMaps.Count -gt 0) {
            $liveGauge = Get-KcpsLiveMapGaugeInfo -Maps $memberMaps -Sea ([int]$sortieWorkflow['Sea']) -Area ([int]$sortieWorkflow['Area'])
            $configuredGauge = if ([int]$sortieWorkflow['MapHpInRangeValueGauge'] -eq 0) { 'HP' } else { 'TP' }
            $declaredGaugeNumber = if ($null -ne $groupRouteSpec -and
                $groupRouteSpec.ContainsKey('StageDesign') -and
                $groupRouteSpec['StageDesign'] -is [System.Collections.IDictionary] -and
                $groupRouteSpec['StageDesign'].Contains('GaugeNumber')) {
                [int]$groupRouteSpec['StageDesign']['GaugeNumber']
            } else { 0 }
            $isDifferentDeclaredStage = $null -ne $liveGauge -and
                $null -ne $liveGauge.GaugeNumber -and
                $declaredGaugeNumber -gt 0 -and
                [int]$liveGauge.GaugeNumber -ne $declaredGaugeNumber
            $futureGaugeMatchesSpec = $isDeclaredFutureStage -and
                $groupRouteSpec.ContainsKey('ExpectedMapGaugeType') -and
                [string]$groupRouteSpec['ExpectedMapGaugeType'] -eq $configuredGauge
            if ($null -ne $liveGauge -and $liveGauge.Name -notin @('HP', 'TP') -and
                -not $futureGaugeMatchesSpec -and -not $isDifferentDeclaredStage) {
                $mapGaugeTypeProblems += [pscustomobject]@{
                    Workflow = [string]$sortieWorkflow['Name']
                    MapId = $liveGauge.MapId
                    Actual = $liveGauge.Name
                    Configured = [int]$sortieWorkflow['MapHpInRangeValueGauge']
                    Problem = "Map gauge range check is enabled, but live map $($liveGauge.MapId) gauge state is $($liveGauge.Name), not HP/TP."
                }
            } elseif ($null -ne $liveGauge -and
                [int]$sortieWorkflow['MapHpInRangeValueGauge'] -ne [int]$liveGauge.SelectableValue -and
                -not $futureGaugeMatchesSpec -and -not $isDifferentDeclaredStage) {
                $mapGaugeTypeProblems += [pscustomobject]@{
                    Workflow = [string]$sortieWorkflow['Name']
                    MapId = $liveGauge.MapId
                    Actual = $liveGauge.Name
                    Configured = $configuredGauge
                    Problem = "Configured map gauge type $configuredGauge does not match live map $($liveGauge.MapId) gauge type $($liveGauge.Name)."
                }
            }
        }
        if ([bool]$sortieWorkflow['MapHpInRangeFlag'] -and $isPointUnlockObjective -and
            $groupMemoText -notmatch '【海域量值】') {
            $mapGaugePurposeProblems += [pscustomobject]@{
                Workflow = [string]$sortieWorkflow['Name']
                Problem = 'Point-based unlock/gimmick/armor-break objectives must not enable the HP/TP range check by default. If it is an intentional phase gate, document type, range, purpose, and source in 【海域量值】.'
            }
        }
    }

    $failureHandlingProblems = @()
    if ($isNormalSortieGroup) {
        foreach ($rel in $relWorkflows) {
            if (@($rel['OrganizeBeforeWorkflows']).Count -le 0) { continue }
            if (-not [bool]$rel['MinimalSleepSecondsAfterFailureOccuredFlag'] -or [int]$rel['MinimalSleepSecondsAfterFailureOccuredValue'] -ne 180) {
                $failureHandlingProblems += "$($rel['Name']): failure handling must wait at least 180 seconds before the next loop."
            }
            if (-not [bool]$rel['IgnoreSortieFailure']) {
                $failureHandlingProblems += "$($rel['Name']): IgnoreSortieFailure must be true so a failed sortie execution advances into the next loop."
            }
            if ([bool]$rel['StopIfOrganizeBeforeSelectFailed']) {
                $failureHandlingProblems += "$($rel['Name']): StopIfOrganizeBeforeSelectFailed must be false."
            }
            foreach ($key in @('IgnoreQuestBeforeFailure','IgnoreQuestAfterFailure','IgnoreOrganizeBeforeFailure','IgnoreOrganizeAfterFailure','IgnoreRefitEquipmentBeforeFailure','IgnoreRefitEquipmentAfterFailure')) {
                if ([bool]$rel[$key]) {
                    $failureHandlingProblems += "$($rel['Name']): $key must be false; only IgnoreSortieFailure is enabled."
                }
            }
            foreach ($prefix in @('QuestBefore','QuestAfter','OrganizeBefore','OrganizeAfter','RefitEquipmentBefore','RefitEquipmentAfter','Sortie')) {
                $flag = "FinishLoopIf${prefix}FailureFlag"
                if ([bool]$rel[$flag]) {
                    $failureHandlingProblems += "$($rel['Name']): $flag must be false; bounded failure jumps can repeat errors and eventually throw instead of naturally entering the next loop."
                }
            }
        }
    }

    # 出击循环只在第一步(编成)刷新数据：除 RefreshDataBeforeOrganize 外，任何 RefreshDataBefore* 为 true 都报问题。
    $refreshDataProblems = @()
    $refreshFlagNames = @('RefreshDataBeforeRefit', 'RefreshDataBeforeSupplyFleet', 'RefreshDataBeforeDocking', 'RefreshDataBeforeSortie', 'RefreshDataBeforeExpedition')
    foreach ($wf in @($list)) {
        foreach ($flag in $refreshFlagNames) {
            if ((Test-MapKey -Map $wf -Key $flag) -and [bool]$wf[$flag]) {
                $refreshDataProblems += [pscustomobject]@{
                    Workflow = [string]$wf['Name']
                    Flag = $flag
                    Problem = "$flag is true; the sortie loop only needs to refresh data once at its first step. Keep only 编成's RefreshDataBeforeOrganize=true and set all other RefreshDataBefore* to false (later steps reuse the loop-start refresh; redundant refreshes just add server calls and slow the loop)."
                }
            }
        }
    }

    $completionNoticeProblems = @()
    $completionNoticeWorkflows = @($list | Where-Object {
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleRaiseUserEventWorkflow') -and
        ($_['Name'] -in @('通知通关', '通知停止') -or (Test-KcpsCanonicalSortieCompletionNotice -Workflow $_))
    })
    $userEventMessageProblems = @()
    $eventClearMessagePattern = '^E\d+\s+P\d+(?:\s+\S+){3,}\s+Clear$'
    $eventStoppedMessagePattern = '^E\d+\s+(?:P\d+|舰船练级)(?:\s+\S+){2,}\s+已停止$'
    $expectedClearMessage = Get-KcpsExpectedClearMessage -GroupName ([string]$group['Name'])
    $usesNewDisplayNaming = [string]$group['Name'] -match '^(?:单次|日常|月常|周常|季常|年常(?:[1-9]|1[0-2])月)(?:（不确定）)?\s+(?:出击|编成|演习|工厂|远征|改装|补给／入渠)\s+'
    foreach ($notice in $completionNoticeWorkflows) {
        # v2 notices validate the raw result themselves; their exact script and binding are checked file-wide.
        if (Test-KcpsCanonicalSortieCompletionNotice -Workflow $notice) { continue }
        if ($isEventSortieGroup) {
            $validEventMessage = if ([string]$notice['Name'] -eq '通知停止') {
                [string]$notice['Message'] -match $eventStoppedMessagePattern
            } else {
                [string]$notice['Message'] -match $eventClearMessagePattern
            }
            if (-not $validEventMessage) {
                $userEventMessageProblems += [pscustomobject]@{
                    Workflow = $notice['Name']
                    Message = $notice['Message']
                    Expected = if ([string]$notice['Name'] -eq '通知停止') { 'E<n> P<n> Purpose Target 已停止' } else { 'E<n> P<n> Purpose Target Condition Clear' }
                    Problem = if ([string]$notice['Name'] -eq '通知停止') {
                        'Event-map stop UserEvent must identify area, phase, purpose, and target, end in 已停止, and must not claim Clear.'
                    } else {
                        'Event-map Clear UserEvent must uniquely identify area, phase, purpose, target, and full condition, using "E编号 P阶段 用途 目标 条件 Clear".'
                    }
                }
            }
        } elseif ($usesNewDisplayNaming) {
            if ([string]$notice['Message'] -notmatch '^\S+\s+\d+-\d+(?:\s+\S+)*\s+Clear$') {
                $userEventMessageProblems += [pscustomobject]@{
                    Workflow = $notice['Name']
                    Message = $notice['Message']
                    Expected = 'TaskId Area Clear'
                    Problem = 'New display naming omits TaskId, but Clear UserEvent must still use exactly "TaskId Area Clear".'
                }
            }
        } elseif ([string]::IsNullOrWhiteSpace($expectedClearMessage)) {
            $userEventMessageProblems += [pscustomobject]@{
                Workflow = $notice['Name']
                Message = $notice['Message']
                Expected = $null
                Problem = 'Cannot infer expected clear UserEvent from config name; use "TaskId Area Clear", for example "By10 5-2 Clear".'
            }
        } elseif ($notice['Message'] -ne $expectedClearMessage) {
            $userEventMessageProblems += [pscustomobject]@{
                Workflow = $notice['Name']
                Message = $notice['Message']
                Expected = $expectedClearMessage
                Problem = 'Clear UserEvent message must be exactly "TaskId Area Clear".'
            }
        }
    }
    $messageRegex = [regex]"e\.Message\s*==\s*r?['""]([^'""]+)['""]"
    foreach ($rel in $relWorkflows) {
        $script = [string]$rel['Script']
        if ([string]::IsNullOrWhiteSpace($script)) { continue }
        foreach ($match in $messageRegex.Matches($script)) {
            $message = $match.Groups[1].Value
            if ($message -notmatch '^\S+\s+\d+-\d+(?:\s+\S+)*\s+Clear$' -and
                $message -notmatch $eventClearMessagePattern -and
                $message -notmatch $eventStoppedMessagePattern) {
                $userEventMessageProblems += [pscustomobject]@{
                    Workflow = $rel['Name']
                    Message = $message
                    Expected = 'TaskId Area Clear or E<n> P<n> Purpose Target Condition Clear'
                    Problem = 'Python UserEvent listener must match the normal-map or detailed event-map clear format, using "任务标识 海域 Clear" or "E编号 P阶段 用途 目标 条件 Clear".'
                }
            }
        }
    }
    $triggerScriptSyntaxProblems = @()
    $triggerScriptTemplateProblems = @()
    $autoGenMark = '# Auto Generated Python Script'
    foreach ($rel in $relWorkflows) {
        $script = [string]$rel['Script']
        if ([string]::IsNullOrWhiteSpace($script)) { continue }
        # External .py / URL forms are compiled elsewhere; only inspect embedded scripts here.
        if ($script.TrimEnd().EndsWith('.py')) { continue }
        if ($script -match '^\s*https?://') { continue }
        # Managed chains are inline lifecycle scripts, not UI-generated templates.
        # Only an exact regenerated script receives this exception; topology is checked file-wide.
        if (Test-KcpsCanonicalSortieChainScript -Script $script) { continue }

        $looksLikeClearListener = ($script -match '\bClear\b') -and ($script -match '(?:\.Message|\[''Message''\])')
        $usesForeignOnEventSyntax = ($script -match '(?m)^\s*function\s+OnEvent\s*\(') -or ($script -match '\$event') -or ($script -match '\s-is\s+\[')
        $hasPythonOnEvent = $script -match '(?m)^\s*def\s+OnEvent\s*\(\s*e\s*\)\s*:'
        if ($usesForeignOnEventSyntax -or ($looksLikeClearListener -and -not $hasPythonOnEvent)) {
            $triggerScriptSyntaxProblems += [pscustomobject]@{
                Workflow = $rel['Name']
                Problem = "UserEvent listener is not valid KCPS IronPython template syntax. Use 'def OnEvent(e):' with isinstance(e, UserEvent); never use C#/PowerShell forms such as 'function OnEvent(`$event) { ... }'."
            }
            continue
        }
        if ($script -notmatch 'def\s+OnEvent') { continue }
        if ($script.IndexOf($autoGenMark) -lt 0) {
            $triggerScriptTemplateProblems += [pscustomobject]@{
                Workflow = $rel['Name']
                Problem = "OnEvent trigger script lacks the marker line '$autoGenMark', so KCPS classifies it as an inline script (内嵌脚本) rather than a template (模板). Triggering still works (ShouldTriggerAsync calls OnEvent either way), but prepend the marker line and use KCPS's canonical template form (tab indent, 'if <clause>: return True', trailing 'pass' / 'return False') to make it a recognized, editor-roundtrippable template."
            }
        }
    }
    foreach ($rel in $relWorkflows) {
        foreach ($notice in $completionNoticeWorkflows) {
            if (Test-KcpsCanonicalSortieCompletionNotice -Workflow $notice) { continue }
            if (-not (Test-RelatedWorkflowRef -Refs $rel['AutoStoppedTriggerWorkflows'] -Guid $notice['Guid'])) {
                $completionNoticeProblems += [pscustomobject]@{
                    Workflow = $rel['Name']
                    NoticeWorkflow = $notice['Name']
                    NoticeGuid = $notice['Guid']
                    Problem = 'Completion notice is not enabled in AutoStoppedTriggerWorkflows; chained UserEvent will not be raised.'
                }
            }
        }
    }

    $stopSummaries = @()
    foreach ($rel in $relWorkflows) {
        $stopSummaries += [pscustomobject]@{
            Workflow = $rel['Name']
            BossRankFlag = $rel['StopIfBossBattleRankHigherOrEqualThanFlag']
            BossRank = $rel['StopIfBossBattleRankHigherOrEqualThanValueRank']
            BossThreshold = $rel['StopIfBossBattleRankHigherOrEqualThanValueThreshold']
            PointRankFlag = $rel['StopIfBattleRankHigherOrEqualThanFlag']
            PointConditionType = $rel['StopIfBattleRankHigherOrEqualThanValueConditionType']
            PointConditionValue = $rel['StopIfBattleRankHigherOrEqualThanValueConditionValue']
            PointRank = $rel['StopIfBattleRankHigherOrEqualThanValueRank']
            PointThreshold = $rel['StopIfBattleRankHigherOrEqualThanValueThreshold']
        }
    }
    $routeSpecProblems = @(Get-KcpsRouteSpecProblems -Group $group -SortieWorkflows $sortieWorkflows -RelationalWorkflows $relWorkflows -RouteSpecDocument $routeSpecs -SpecialAttackRuleDocument $specialAttackRules -RouteContext $routeContext -RequireRouteSpec (-not [bool]$AllowMissingRouteSpec))
    $sameBaseProblems = @(Get-KcpsOrganizeSameBaseProblems -OrganizeWorkflows $organizeWorkflows -RouteContext $routeContext)
    $combinedCompositionProblems = @(Get-KcpsCombinedWorkflowProblems -Workflows $list -OwnedShips $memberShips -MasterShips $slotMasters)
    $memoQualityProblems = @(Get-MemoQualityProblems -MemoWorkflows $memoWorkflows)
    $battleStrategyMemoLanguageProblems = @(Get-KcpsBattleStrategyMemoLanguageProblems -SortieWorkflows $sortieWorkflows)
    $slotRestrictionProblems = @(Get-KcpsSlotRestrictionProblems -RefitWorkflows $refitWorkflows -Rules $slotRestrictionRules -EquipmentContext $exSlotContext)

    # 备注覆盖: 关键执行单元 + 每条条件战斗策略都必须有 Memo(配置自文档化)
    $memoCoverageProblems = @()
    foreach ($w in @($list)) {
        $nm = [string]$w['Name']
        if ($nm -in @('总控','接任务','编成','改装','出击','通知通关','通知停止','扔桶','说明')) {
            if ([string]::IsNullOrWhiteSpace([string]$w['Memo'])) {
                $memoCoverageProblems += "execution unit '$nm' has an empty Memo;每个执行单元都应写角色备注。"
            }
        }
    }
    foreach ($sw in @($sortieWorkflows)) {
        foreach ($cs in @($sw['Strategies'])) {
            if ([int]$cs['Condition']['Type'] -eq 1 -and [string]::IsNullOrWhiteSpace([string]$cs['Strategy']['Memo'])) {
                $memoCoverageProblems += "$($sw['Name']) cell $($cs['Condition']['Value']) 条件战斗策略缺 Memo; 应注明节点字母/类型/阵型。"
            }
        }
    }
    # 组名必须含出击任务本身的名字(从接任务 Quest 的 Memo 取)
    $groupNameTaskProblems = @()
    foreach ($qw in @($questWorkflows)) {
        foreach ($q in @($qw['Quests'])) {
            $taskName = ([string]$q['Memo']).Trim()
            # 新显示命名不含任务编号；Quest.Memo 仍可保留 By10/955 等稳定标识供日志和 Clear 消息使用。
            $taskName = ($taskName -replace '^(?:\d+|[A-Za-z]+\d+)\s+', '').Trim()
            if ($taskName.Length -ge 4 -and ([string]$group['Name']) -notlike "*$taskName*") {
                $groupNameTaskProblems += "组名 '$($group['Name'])' 未包含出击任务名 '$taskName'(来自接任务 Quest.Memo); 组名应含任务本身的名字便于识别。"
            }
        }
    }

    $groupProblems = @()
    if (@($workflowTypeLoadProblems).Count -gt 0) { $groupProblems += 'Workflow Type cannot pass the KCPS loader version check.' }
    if ($combinedCompositionProblems.Count) { $groupProblems += 'Combined fleet composition is invalid or cannot be verified from planned ship candidates.' }
    if (@($workflowRefShapeProblems).Count -gt 0) { $groupProblems += 'Related workflow collection field is not serialized as JSON array.' }
    if (@($jsonCollectionShapeProblems).Count -gt 0) { $groupProblems += 'KCPS collection field is not serialized as JSON array.' }
    if (@($brokenRefs).Count -gt 0) { $groupProblems += 'Broken workflow reference(s).' }
    if (@($positions | Where-Object { $_.Problem }).Count -gt 0) { $groupProblems += 'Organize workflow has empty candidate row(s).' }
    if (@($slotProblems).Count -gt 0) { $groupProblems += 'Refit workflow has equipment selector, inventory, consumable, or slot-compatibility problem(s).' }
    if (@($relatedThresholdProblems).Count -gt 0) { $groupProblems += 'Related workflow threshold exceeds reference count or compatible completion-event producer count.' }
    if (@($highMoraleSingleLoopProblems).Count -gt 0) { $groupProblems += 'Morale requirement above 49 is not configured as a manual-preparation single-loop sortie.' }
    if (@($postSortieDockingProblems).Count -gt 0) { $groupProblems += 'Post-sortie bucket docking setup problem(s).' }
    if (@($landBaseRestProblems).Count -gt 0) { $groupProblems += 'Post-sortie land-base rest setup problem(s).' }
    if (@($mapHpExistenceRangeProblems).Count -gt 0) { $groupProblems += 'Map-HP/TP existence range upper bound is too low.' }
    if (@($mapGaugeTypeProblems).Count -gt 0) { $groupProblems += 'Configured map gauge type does not match the live game map gauge.' }
    if (@($mapGaugePurposeProblems).Count -gt 0) { $groupProblems += 'Point-based event objective enables map gauge checking without documented phase-gate justification.' }
    if (@($completionNoticeProblems).Count -gt 0) { $groupProblems += 'Completion notice is not triggered after total controller auto-stop.' }
    if (@($userEventMessageProblems).Count -gt 0) { $groupProblems += 'Clear UserEvent message format problem(s).' }
    if (@($refreshDataProblems).Count -gt 0) { $groupProblems += 'Redundant RefreshDataBefore* enabled; only 编成 RefreshDataBeforeOrganize should be true.' }
    if (@($slotRestrictionProblems).Count -gt 0) { $groupProblems += 'Refit puts a forbidden equipment type in a restricted ship slot (e.g. 主砲/魚雷 in 吹雪改三 slot4); KCPS will fail at runtime.' }
    if (@($triggerScriptSyntaxProblems).Count -gt 0) { $groupProblems += 'UserEvent listener script is not valid KCPS IronPython syntax.' }
    if (@($triggerScriptTemplateProblems).Count -gt 0) { $groupProblems += 'OnEvent trigger script(s) missing template marker; KCPS will show them as inline scripts.' }
    if (@($routeSpecProblems).Count -gt 0) { $groupProblems += 'Route specification coverage/order problem(s).' }
    if (@($memoQualityProblems).Count -gt 0) { $groupProblems += 'Memo contains unverified-route or inconsistent workflow descriptions.' }
    if (@($battleStrategyMemoLanguageProblems).Count -gt 0) { $groupProblems += 'Conditional battle strategy Memo must use Chinese only; Japanese/English prose is not allowed.' }
    if (@($memoCoverageProblems).Count -gt 0) { $groupProblems += 'Execution unit or conditional battle strategy has an empty Memo; configs must be self-documenting.' }
    if (@($groupNameTaskProblems).Count -gt 0) { $groupProblems += 'Group name does not include the sortie task name.' }
    if (@($sameBaseProblems).Count -gt 0) { $groupProblems += 'Organize workflow has same-base ship selections that KCPS will treat as conflicts.' }
    if (@($questProblems).Count -gt 0) { $groupProblems += 'Accept quest workflow has unsafe or unverifiable settings.' }
    if (@($organizeEnumProblems).Count -gt 0) { $groupProblems += 'Organize workflow has invalid enum value(s).' }
    if (@($multiCandidateRotationProblems).Count -gt 0) { $groupProblems += 'Equivalent-ship fatigue rotation setting problem(s).' }
    if (@($singleCandidateSalvageProblems).Count -gt 0) { $groupProblems += 'Single-candidate pre-sortie salvage setting problem(s).' }
    if (@($failureHandlingProblems).Count -gt 0) { $groupProblems += 'Relational sortie failure-handling setting problem(s).' }
    if (@($escortRetreatEquipmentProblems).Count -gt 0) { $groupProblems += 'Striking-force retreat is enabled without 遊撃部隊 艦隊司令部 in the flagship main slots.' }
    foreach ($sortie in $sortieSummaries) { $groupProblems += @($sortie.Problems) }
    $totalProblems += @($groupProblems).Count

    # 舰队轮换摘要：把"位置有多个候选(疲劳轮换)"显式列清楚，避免被误读成"队里多了一艘船/备选是另一艘船"。
    # KCPS 编成的每个位置最终只选择一艘船，
    # 所以出击船数=位置数；多候选只是同一位置的轮换备选，出击仍只上1艘。
    $fleetRotationSummary = @()
    foreach ($wfName in (@($positions | ForEach-Object { $_.Workflow }) | Select-Object -Unique)) {
        $wfPositions = @($positions | Where-Object { $_.Workflow -eq $wfName })
        $rotations = @($wfPositions | Where-Object { [int]$_.SelectionCount -gt 1 } | ForEach-Object {
            $shipName = if (@($_.Selections).Count -gt 0 -and ($_.Selections[0] -match '\[([^\(\]\[]+?)\s*\(')) { $Matches[1].Trim() } else { '?' }
            [pscustomobject]@{
                Position = $_.Position
                Ship = $shipName
                CopyCount = [int]$_.SelectionCount
                Candidates = @($_.Selections)
                Note = "fatigue rotation: $shipName ×$([int]$_.SelectionCount) copies — KCPS sorties only 1 of them for this position."
            }
        })
        $fleetRotationSummary += [pscustomobject]@{
            Workflow = $wfName
            SortieShipCount = @($wfPositions).Count
            RotationPositionCount = @($rotations).Count
            Note = "Fleet sorties $(@($wfPositions).Count) ship(s) (= position count). Positions with >1 candidate are same-base fatigue rotations, NOT extra fleet members."
            Rotations = @($rotations)
        }
    }

    $levelingPreparationProblems = @(Get-KcpsLevelingPreparationProblems -RouteSpec $groupRouteSpec -Controller ($relWorkflows | Select-Object -First 1) -Sortie ($sortieWorkflows | Select-Object -First 1) -Workflows $list -Ships $memberShips -Const $const)
    $groupProblems += $levelingPreparationProblems
    $totalProblems += $levelingPreparationProblems.Count
    $groupResults += [pscustomobject]@{
        Name = $group['Name']
        WorkflowCount = @($list).Count
        BrokenRefCount = @($brokenRefs).Count
        BrokenRefs = @($brokenRefs)
        WorkflowTypeLoadProblems = @($workflowTypeLoadProblems)
        WorkflowRefShapeProblems = @($workflowRefShapeProblems)
        LevelingPreparationProblems = $levelingPreparationProblems
        JsonCollectionShapeProblems = @($jsonCollectionShapeProblems)
        Quests = @($questWorkflows | ForEach-Object {
            $workflow = $_
            @($workflow['Quests'] | ForEach-Object {
                [pscustomobject]@{
                    Workflow = $workflow['Name']
                    SelectMethod = $_['SelectMethod']
                    No = $_['SelectValue']
                    Memo = $_['Memo']
                    Priority = $_['Priority']
                    Replace = $_['AllowReplaceLowPriorityTasks']
                    Required = $_['FailIfNotExist']
                    SuccessIfFull = $_['SuccessIfFull']
                }
            })
        })
        QuestProblems = @($questProblems)
        Positions = @($positions)
        FleetRotationSummary = @($fleetRotationSummary)
        RefitSlots = @($refitSlots)
        RefitSlotProblems = @($slotProblems)
        RefitOrderWarnings = @($refitOrderWarnings)
        RelatedThresholdProblems = @($relatedThresholdProblems)
        HighMoraleSingleLoopProblems = @($highMoraleSingleLoopProblems)
        PostSortieBucketDockingProblems = @($postSortieDockingProblems)
        LandBaseRestProblems = @($landBaseRestProblems)
        MapHpExistenceRangeProblems = @($mapHpExistenceRangeProblems)
        MapGaugeTypeProblems = @($mapGaugeTypeProblems)
        MapGaugePurposeProblems = @($mapGaugePurposeProblems)
        CompletionNoticeProblems = @($completionNoticeProblems)
        UserEventMessageProblems = @($userEventMessageProblems)
        RefreshDataProblems = @($refreshDataProblems)
        SlotRestrictionProblems = @($slotRestrictionProblems)
        RefitSlotExistenceProblems = @($refitSlotExistenceProblems)
        TriggerScriptSyntaxProblems = @($triggerScriptSyntaxProblems)
        TriggerScriptTemplateProblems = @($triggerScriptTemplateProblems)
        SortieChainProblems = @($sortieChainCheck.Problems | Where-Object { $_.Group -ceq [string]$group['Name'] })
        RouteSpecProblems = @($routeSpecProblems)
        MemoQualityProblems = @($memoQualityProblems)
        BattleStrategyMemoLanguageProblems = @($battleStrategyMemoLanguageProblems)
        MemoCoverageProblems = @($memoCoverageProblems)
        GroupNameTaskProblems = @($groupNameTaskProblems)
        SameBaseOrganizeProblems = @($sameBaseProblems)
        CombinedCompositionProblems = @($combinedCompositionProblems)
        OrganizeEnumProblems = @($organizeEnumProblems)
        MultiCandidateRotationProblems = @($multiCandidateRotationProblems)
        SingleCandidateSalvageProblems = @($singleCandidateSalvageProblems)
        FailureHandlingProblems = @($failureHandlingProblems)
        EscortRetreatEquipmentProblems = @($escortRetreatEquipmentProblems)
        Sorties = @($sortieSummaries)
        Stop = @($stopSummaries)
        Problems = @($groupProblems)
    }
}

$validationResult = [pscustomobject]@{
    Path = (Resolve-Path -LiteralPath $Path).Path
    GroupCount = @($groups).Count
    ProblemCount = $totalProblems
    FileProblems = @($fileProblems)
    SortieChainCheck = $sortieChainCheck
    SortieChainProblems = @($sortieChainCheck.Problems)
    HardcodedRuleCheck = $hardcodedRuleFreshness
    HardcodedRuleFreshnessWarnings = @($hardcodedRuleFreshness.Warnings)
    RouteSpecPath = $routeSpecPath
    RouteSpecCheck = $routeSpecFreshness
    RouteSpecFreshnessWarnings = @($routeSpecFreshness.Warnings)
    Groups = @($groupResults)
}

$validationResult | ConvertTo-KcpsJsonOutput -Depth 80

if ($FailOnProblems -and $totalProblems -gt 0) {
    throw "KCPS config validation failed: ProblemCount=$totalProblems; Path=$((Resolve-Path -LiteralPath $Path).Path)"
}
