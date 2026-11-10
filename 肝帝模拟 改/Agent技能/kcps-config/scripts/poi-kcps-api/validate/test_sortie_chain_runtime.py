# 离线运行生成脚本。宿主仅提供 IronPython 与合成 CLR 类型，不加载应用程序集。
from System import Guid

checks = 0
RANKS = {"SS": 1, "S": 2, "A": 3, "B": 4, "C": 5, "D": 6, "E": 7}


def check(condition, label):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1


def invoke(scope, name):
    if name in scope:
        return scope[name]()


def environment(case):
    source = WorkflowDouble()
    source_scope = {"Workflow": source}
    exec(case["ControllerScript"], source_scope)
    notice = WorkflowDouble()
    notice_scope = {"Workflow": notice}
    exec(case["NoticeScript"], notice_scope)
    meta = case["Metadata"]
    source.StopIfBossBattleRankHigherOrEqualThanFlag = True
    source.StopIfBossBattleRankHigherOrEqualThanValueRank = RANKS[meta["Condition"]["Rank"]]
    source.StopIfBossBattleRankHigherOrEqualThanValueThreshold = int(meta["Condition"]["Count"])
    invoke(source_scope, "OnEnabled")
    invoke(notice_scope, "OnEnabled")
    return {"source": source, "source_scope": source_scope, "notice": notice,
            "notice_scope": notice_scope, "meta": meta}


def start(env):
    source = env["source"]
    source.IsRunning = False
    source.IsExecuting = True
    source.StopIfBossBattleRankHigherOrEqualThanCount = 0
    env["source_scope"]["OnProcess"]()
    source.IsRunning = True
    source.IsExecuting = False


def capture(env, count):
    env["source"].StopIfBossBattleRankHigherOrEqualThanCount = count
    before = UtilityDouble.Events.Count
    result = env["source_scope"]["OnAutoStop"]()
    check(result is False, "总控快照 hook 始终返回 False，不承担完成判定")
    check(UtilityDouble.Events.Count == before, "停止前采集快照不发内部结果或 Clear")


def native_reset(env):
    # 对应原生 Stop()：先清零，再执行停止后的 hook；此时执行任务尚未退出。
    env["source"].IsRunning = False
    env["source"].IsExecuting = True
    env["source"].StopIfBossBattleRankHigherOrEqualThanCount = 0


def stopped(env):
    # AutoStop 的 ExecuteAsync 还会调用一次 OnProcess，此时仍 IsRunning。
    env["source_scope"]["OnProcess"]()
    native_reset(env)
    before = UtilityDouble.Events.Count
    env["source_scope"]["OnAutoStopped"]()
    env["source"].IsExecuting = False
    return list(UtilityDouble.Events)[before:]


def result_fields(env, event):
    prefix = env["meta"]["ResultMessagePrefix"]
    check(event.Message.startswith(prefix), "总控只发送当前配对的内部结果")
    fields = event.Message[len(prefix):].split("|")
    check(len(fields) == 6 and fields[0] == "1", "快照具有约定的六字段格式")
    return fields


def deliver_notice(env, event, expected):
    before = UtilityDouble.Events.Count
    accepted = env["notice_scope"]["OnEvent"](event)
    check(bool(accepted) == expected, "通知单元独立决定是否接受结果")
    check(UtilityDouble.Events.Count == before, "通知 OnEvent 只判定，不自己发 Clear")
    if accepted:
        # 对应 SimpleRaiseUserEventWorkflow：通过事件条件后才执行 OnProcess 并发送 Message。
        env["notice"].IsExecuting = True
        invoke(env["notice_scope"], "OnProcess")
        UtilityDouble.RaiseEvent(UserEventDouble(env["meta"]["CompletionMessage"]))
        env["notice"].IsExecuting = False
        check(UtilityDouble.Events.Count == before + 1, "原生通知执行只发一个 Clear")
    return bool(accepted)


def payload(env, fields, prefix=None):
    return UserEventDouble((prefix or env["meta"]["ResultMessagePrefix"]) + "|".join(fields))


for case in Cases:
    env = environment(case)
    required = int(env["meta"]["Condition"]["Count"])
    expected_rank = RANKS[env["meta"]["Condition"]["Rank"]]
    UtilityDouble.Events.Clear()
    start(env)
    capture(env, required)
    check(UtilityDouble.Events.Count == 0, "目标已达到但总控收尾前没有 Clear")
    events = stopped(env)
    check(len(events) == 1, "自动停止后总控只转发一个快照")
    fields = result_fields(env, events[0])
    check(int(fields[5]) == required and env["source"].StopIfBossBattleRankHigherOrEqualThanCount == 0,
          "原生计数清零后快照仍保留停止前计数")
    check(events[0].Message != env["meta"]["CompletionMessage"], "总控不直接发布 Clear")
    deliver_notice(env, events[0], True)
    check(UtilityDouble.Events[UtilityDouble.Events.Count - 1].Message == env["meta"]["CompletionMessage"], "Clear 由独立通知发布")
    deliver_notice(env, events[0], False)
    before = UtilityDouble.Events.Count
    env["source_scope"]["OnAutoStopped"]()
    check(UtilityDouble.Events.Count == before, "重复停止 hook 不重复转发旧快照")

    for cause in ("loop limit", "capacity", "forced stop"):
        env = environment(case)
        UtilityDouble.Events.Clear()
        start(env)
        capture(env, required - 1)
        events = stopped(env)
        check(len(events) == 1, "未达标安全停止也转发快照：" + cause)
        fields = result_fields(env, events[0])
        check(int(fields[5]) == required - 1, "未达标计数未经总控改写")
        deliver_notice(env, events[0], False)
        check(UtilityDouble.Events.Count == 1, "安全停止结果未被通知升级为 Clear")

    env = environment(case)
    UtilityDouble.Events.Clear()
    start(env)
    events = stopped(env)
    check(len(events) == 0, "准备阶段提前停止且无计数快照时不宣布完成")

    for restart in ("disabled", "manual restart"):
        env = environment(case)
        UtilityDouble.Events.Clear()
        start(env)
        capture(env, required)
        native_reset(env)  # 人工停止没有 OnAutoStopped，不能消费旧完成快照。
        env["source"].IsExecuting = False
        if restart == "disabled":
            invoke(env["source_scope"], "OnDisabled")
            invoke(env["source_scope"], "OnEnabled")
        start(env)
        check(len(stopped(env)) == 0, "重启清除未消费旧快照：" + restart)
        start(env)
        capture(env, 0)
        events = stopped(env)
        check(len(events) == 1, "重启后的未达标结果仍正常转发")
        deliver_notice(env, events[0], False)

    env = environment(case)
    UtilityDouble.Events.Clear()
    start(env)
    for count in range(required):
        capture(env, count)
        env["source_scope"]["OnProcess"]()
    capture(env, required)
    events = stopped(env)
    deliver_notice(env, events[0], True)
    check(int(result_fields(env, events[0])[5]) == required, "N 次累计保留最后一次完整快照")
    # 同一运行达到目标且同时触发安全上限，仍以真实计数作完成证据。
    check(UtilityDouble.Events[UtilityDouble.Events.Count - 1].Message == env["meta"]["CompletionMessage"], "达到目标并同时安全停止可完成")

    env = environment(case)
    UtilityDouble.Events.Clear()
    run_ids = []
    previous_event = None
    for run in range(2):
        start(env)
        capture(env, required)
        events = stopped(env)
        run_ids.append(result_fields(env, events[0])[1])
        deliver_notice(env, events[0], True)
        if previous_event is not None:
            deliver_notice(env, previous_event, False)
        previous_event = events[0]
    check(run_ids[0] != run_ids[1], "同一总控重新运行获得不同 RunId 且可再次完成")

    for field, value in (
        ("StopIfBossBattleRankHigherOrEqualThanFlag", False),
        ("StopIfBossBattleRankHigherOrEqualThanValueRank", 2 if expected_rank != 2 else 3),
        ("StopIfBossBattleRankHigherOrEqualThanValueThreshold", required + 1),
    ):
        env = environment(case)
        UtilityDouble.Events.Clear()
        start(env)
        setattr(env["source"], field, value)
        capture(env, required + 1)
        events = stopped(env)
        check(len(events) == 1, "原生目标改变仍转发原始快照：" + field)
        deliver_notice(env, events[0], False)

    env = environment(case)
    meta = env["meta"]
    valid = ["1", "12345678-1234-4abc-8def-1234567890ab", "1",
             str(expected_rank), str(required), str(required)]
    bad_fields = []
    for index, values in (
        (0, ("0", "2", "")),
        (1, ("not-a-guid", "12345678-1234-4ABC-8DEF-1234567890AB",
             "1234567812344abc8def1234567890ab")),
        (2, ("true", "2", "")),
        (3, ("0", "8", "-1", "+3", "03", "3.0")),
        (4, ("0", "-1", "01", "2147483648")),
        (5, ("-1", "+1", "01", "1.0", "2147483648", " 1", "1 ")),
    ):
        for value in values:
            bad = list(valid)
            bad[index] = value
            bad_fields.append(bad)
    bad_fields += [valid[:-1], valid + ["extra"]]
    UtilityDouble.Events.Clear()
    check(not env["notice_scope"]["OnEvent"](object()), "通知忽略非 UserEvent")
    check(not env["notice_scope"]["OnEvent"](UserEventDouble("unrelated")), "通知忽略其他消息")
    for bad in bad_fields:
        deliver_notice(env, payload(env, bad), False)
    for old_guid in (meta["ControllerGuid"], meta["NoticeGuid"]):
        wrong_prefix = meta["ResultMessagePrefix"].replace(old_guid, "ffffffff-ffff-4fff-8fff-ffffffffffff")
        deliver_notice(env, payload(env, valid, wrong_prefix), False)
    for index, value in ((2, "0"), (3, str(2 if expected_rank != 2 else 3)),
                         (4, str(required + 1)), (5, str(required - 1))):
        bad = list(valid)
        bad[1] = str(Guid.NewGuid().ToString("D"))
        bad[index] = value
        deliver_notice(env, payload(env, bad), False)
    check(UtilityDouble.Events.Count == 0, "坏 payload、错来源和错目标均不发送 Clear")
    deliver_notice(env, payload(env, valid), True)
    deliver_notice(env, payload(env, valid), False)
    check(UtilityDouble.Events.Count == 1, "坏消息不污染后续有效运行，重复 RunId 只完成一次")

    env = environment(case)
    event = payload(env, valid)
    UtilityDouble.Events.Clear()
    env["notice"].IsExecuting = True
    deliver_notice(env, event, False)
    env["notice"].IsExecuting = False
    deliver_notice(env, event, True)
    check(UtilityDouble.Events.Count == 1, "通知忙时拒绝结果但不提前消耗 RunId")

    env = environment(case)
    listener = env["source_scope"]["OnEvent"]
    listen = env["meta"]["ListenMessage"]
    check(not listener(object()), "总控忽略非消息事件")
    check(not listener(UserEventDouble("unrelated")), "总控忽略无关消息")
    check(not listener(payload(env, valid)), "总控不直接监听内部快照")
    if listen is None:
        check(not listener(UserEventDouble(env["meta"]["CompletionMessage"])), "首阶段等待手动开始")
    else:
        event = UserEventDouble(listen)
        env["source"].IsExecuting = True
        check(not listener(event), "启动或停止执行窗口拒绝接续")
        env["source"].IsRunning = True
        check(not listener(event), "运行中的总控拒绝接续")
        env["source"].IsExecuting = False
        check(not listener(event), "轮间等待仍属于运行中")
        env["source"].IsRunning = False
        check(listener(event), "空闲下游只需匹配 Clear")
        check(not listener(event), "开始前排队的重复 Clear 被拒绝")
        start(env)
        check(not listener(event), "开始后重复 Clear 被拒绝")

# 完整接续：每阶段只有通知发出的 Clear 可以激活下一阶段。
chain = [environment(case) for case in ChainCases]
previous = None
for index, env in enumerate(chain):
    UtilityDouble.Events.Clear()
    if previous is not None:
        check(env["source_scope"]["OnEvent"](previous), "下一阶段接收上一通知的 Clear")
    start(env)
    required = int(env["meta"]["Condition"]["Count"])
    for count in range(1, required + 1):
        capture(env, count)
        env["source_scope"]["OnProcess"]()
    check(UtilityDouble.Events.Count == 0, "阶段收尾前没有任何接续消息")
    events = stopped(env)
    check(len(events) == 1, "阶段仅转发一次内部快照")
    if index + 1 < len(chain):
        check(not chain[index + 1]["source_scope"]["OnEvent"](events[0]),
              "内部快照不能直接启动下一阶段")
    deliver_notice(env, events[0], True)
    previous = UtilityDouble.Events[UtilityDouble.Events.Count - 1]
    check(previous.Message == env["meta"]["CompletionMessage"], "该阶段由独立通知完成")
check(len(chain) >= 2, "实际执行了多阶段接续")

