// ============================================================================
// scheduler_test —— 规则内核 once / 优先级 / 事件名 黑盒测试
// 覆盖：event_names_of 映射、once 语义（同一事件不重复触发）、
//       优先级排序（高优先级先执行）。
// ============================================================================

///|
fn mk_rule(
  id : String,
  events : Array[String],
  priority : Int32,
  once : Bool,
) -> @config.Rule {
  let action = @config.ActionSpec::new(
    "command",
    Some(["cmd", "/c", "echo", id]),
    None,
    None,
    None,
  )
  @config.Rule::new(id, events, ["*.tmp"], [], None, [action], once, priority, None)
}

///|
fn mk_event(path : String) -> @watch.FsEvent {
  @watch.FsEvent::new(@config.EventType::Create, path, false, 0, 0)
}

///|
fn quiet_logging() -> @config.LoggingConfig {
  { enabled: false, log_dir: "", log_file: "mcp-watcher.log", }
}

///|
test "event_names_of：具体事件类型映射为 <type>.*" {
  let r = mk_rule("r", ["create", "modify"], 0, false)
  let names = @scheduler.event_names_of(r)
  assert_eq(names.length(), 2)
  assert_true(names.contains("create.*"))
  assert_true(names.contains("modify.*"))
}

///|
test "event_names_of：all 展开为五种事件订阅" {
  let r = mk_rule("r", ["all"], 0, false)
  let names = @scheduler.event_names_of(r)
  assert_eq(names.length(), 5)
  assert_true(names.contains("create.*"))
  assert_true(names.contains("delete.*"))
}

///|
test "once 语义：同一事件 publish 两次只执行一次" {
  @rx.install_real_clock()
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let rule = mk_rule("once-rule", ["create"], 0, true)
  let policy = @action.build_policy(["cmd"])
  let _ = @scheduler.attach_rules(
    [rule],
    bus,
    policy,
    "C:/tmp",
    quiet_logging(),
    log,
    records,
  )

  let ev = mk_event("C:/tmp/once.tmp")
  bus.publish("create.*", ev)
  bus.publish("create.*", ev)

  // 用日志条数验证 once（wasm 下 command 失败写 err 日志，native 下成功写 ok 日志，
  // 两者都证明 handler 是否执行，三目标语义一致）
  assert_eq(log.val.length(), 1)
}

///|
test "非 once：同一事件 publish 两次执行两次" {
  @rx.install_real_clock()
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let rule = mk_rule("repeat-rule", ["create"], 0, false)
  let policy = @action.build_policy(["cmd"])
  let _ = @scheduler.attach_rules(
    [rule],
    bus,
    policy,
    "C:/tmp",
    quiet_logging(),
    log,
    records,
  )

  let ev = mk_event("C:/tmp/repeat.tmp")
  bus.publish("create.*", ev)
  bus.publish("create.*", ev)

  assert_eq(log.val.length(), 2)
}

///|
test "allowed_programs：返回显式白名单，不从 argv 自动收集" {
  let r = mk_rule("a", ["create"], 0, false) // 规则 argv[0] = cmd
  let cfg : @config.Config = {
    schema_version: 1,
    watch_id: "test",
    watch_dir: ".",
    recursive: true,
    debounce_ms: 0,
    rules: [r],
    allowed_programs: ["git", "node"],
    logging: quiet_logging(),
    extensions: [],
    index: @config.IndexConfig::new(),
  }
  let progs = @scheduler.allowed_programs(cfg)
  // 必须是配置里显式声明的 git/node，而非规则 argv 里的 cmd
  assert_eq(progs.length(), 2)
  assert_true(progs.contains("git"))
  assert_true(progs.contains("node"))
  assert_false(progs.contains("cmd"))
}

///|
test "allowed_programs：空白名单 = 不执行任何命令（安全默认）" {
  let r = mk_rule("a", ["create"], 0, false)
  let cfg : @config.Config = {
    schema_version: 1,
    watch_id: "test",
    watch_dir: ".",
    recursive: true,
    debounce_ms: 0,
    rules: [r],
    allowed_programs: [],
    logging: quiet_logging(),
    extensions: [],
    index: @config.IndexConfig::new(),
  }
  assert_eq(@scheduler.allowed_programs(cfg).length(), 0)
}

// ============================================================================
// scheduler · 守卫门 on_fail 决策（schema v1.1 · PLAN-gates.md §二）纯函数
// ============================================================================

///|
/// guard_fail_decision：skip → 只跳过本次动作，规则不退场
test "guard_fail_decision: skip keeps rule alive" {
  let (skip_actions, retire) = @scheduler.guard_fail_decision("skip")
  assert_true(skip_actions)
  assert_false(retire)
}

///|
/// guard_fail_decision：stop → 跳过动作并让规则退场
test "guard_fail_decision: stop retires rule" {
  let (skip_actions, retire) = @scheduler.guard_fail_decision("stop")
  assert_true(skip_actions)
  assert_true(retire)
}

///|
/// guard_fail_decision：未知值 → 防御性按 skip 处理（解析层已 fail-closed，理论不达）
test "guard_fail_decision: unknown value defensive" {
  let (skip_actions, retire) = @scheduler.guard_fail_decision("crash")
  assert_true(skip_actions)
  assert_false(retire)
}

///|
/// EP-03b：interval_ms_of —— 解析 "interval:<ms>" 条目
test "interval_ms_of: 解析 interval 条目" {
  let r = mk_rule("rule-ivl", ["interval:60000"], 1, false)
  assert_eq(@scheduler.interval_ms_of(r), 60000L)
}

///|
/// EP-03b：interval_ms_of —— 无 interval 条目返回 0
test "interval_ms_of: 无 interval 条目返回 0" {
  let r = mk_rule("rule-fs", ["modify"], 1, false)
  assert_eq(@scheduler.interval_ms_of(r), 0L)
}

///|
/// EP-03b：interval_ms_of —— 低于下限触底到 INTERVAL_MIN_MS（解析层已拦，
/// 此为防御性第二道闸）
test "interval_ms_of: 低于下限触底" {
  let r = mk_rule("rule-ivl", ["interval:200"], 1, false)
  assert_eq(@scheduler.interval_ms_of(r), @config.INTERVAL_MIN_MS)
}

// ---------------------------------------------------------------------------
// P1 规则内核 · EventBus[FsEvent] 端到端验收（development-plan §P1）
//
// 五路：命中 / 不命中 / 排除 / 条件失败 / once 不重复触发；
// 另加一条「priority 落到 TriggerRegistry」的顺序断言。
//
// 夹具口径：动作统一用 `internal log_event`（message 只取受支持占位符
// {file.path}），断言一律读 ExecRecord.rule_id / records 条数 —— 不依赖子进程
//（command 在 js/wasm 下不可靠）⇒ 三目标语义一致。
// ---------------------------------------------------------------------------

///|
fn mk_ev(t : @config.EventType, path : String, size : Int32) -> @watch.FsEvent {
  @watch.FsEvent::new(t, path, false, 0, size)
}

///|
fn mk_log_rule(
  id : String,
  events : Array[String],
  patterns : Array[String],
  exclude : Array[String],
  condition : @config.ConditionSpec?,
  priority : Int32,
  once : Bool,
) -> @config.Rule {
  let a = @config.ActionSpec::new_internal("log_event", Some("{file.path}"))
  @config.Rule::new(id, events, patterns, exclude, condition, [a], once, priority, None)
}

///|
fn mk_kernel_bus() -> @rx.EventBus[@watch.FsEvent] {
  @rx.install_real_clock()
  @rx.EventBus::new()
}

///|
test "P1 命中：patterns + 事件类型通过 → 规则执行" {
  let bus = mk_kernel_bus()
  let rule = mk_log_rule("hit", ["create"], ["*.tmp"], [], None, 0, false)
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let _ = @scheduler.attach_rules(
    [rule],
    bus,
    @action.build_policy([]),
    "C:/tmp",
    quiet_logging(),
    log,
    records,
  )
  bus.publish("create.*", mk_ev(@config.EventType::Create, "C:/tmp/a.tmp", 10))
  assert_eq(records.val.length(), 1)
  assert_eq(records.val[0].rule_id, "hit")
}

///|
test "P1 不命中：patterns 不符 → 规则不执行" {
  let bus = mk_kernel_bus()
  let rule = mk_log_rule("miss", ["create"], ["*.log"], [], None, 0, false)
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let _ = @scheduler.attach_rules(
    [rule],
    bus,
    @action.build_policy([]),
    "C:/tmp",
    quiet_logging(),
    log,
    records,
  )
  bus.publish("create.*", mk_ev(@config.EventType::Create, "C:/tmp/a.tmp", 10))
  assert_eq(records.val.length(), 0)
}

///|
test "P1 排除：exclude 命中 → 即使 patterns 命中也不执行" {
  let bus = mk_kernel_bus()
  let rule = mk_log_rule("excluded", ["create"], ["*.tmp"], ["keep.tmp"], None, 0, false)
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let _ = @scheduler.attach_rules(
    [rule],
    bus,
    @action.build_policy([]),
    "C:/tmp",
    quiet_logging(),
    log,
    records,
  )
  bus.publish("create.*", mk_ev(@config.EventType::Create, "C:/tmp/keep.tmp", 10))
  assert_eq(records.val.length(), 0)
}

///|
test "P1 条件失败：Layer1 命中但 Layer2 谓词为假 → 不执行" {
  let bus = mk_kernel_bus()
  let cond = @config.ConditionSpec::new("size_gt", "100")
  let rule = mk_log_rule("cond-fail", ["create"], ["*.tmp"], [], Some(cond), 0, false)
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let _ = @scheduler.attach_rules(
    [rule],
    bus,
    @action.build_policy([]),
    "C:/tmp",
    quiet_logging(),
    log,
    records,
  )
  // 条件为假（50 <= 100）：不执行
  bus.publish("create.*", mk_ev(@config.EventType::Create, "C:/tmp/small.tmp", 50))
  assert_eq(records.val.length(), 0)
  // 反向对照：同一规则、条件满足时必须执行（否则本格可能恒假绿）
  bus.publish("create.*", mk_ev(@config.EventType::Create, "C:/tmp/big.tmp", 200))
  assert_eq(records.val.length(), 1)
  assert_eq(records.val[0].rule_id, "cond-fail")
}

///|
test "P1 once：stop_after 规则同一事件 publish 两次只执行一次" {
  let bus = mk_kernel_bus()
  let rule = mk_log_rule("once-hit", ["create"], ["*.tmp"], [], None, 0, true)
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let _ = @scheduler.attach_rules(
    [rule],
    bus,
    @action.build_policy([]),
    "C:/tmp",
    quiet_logging(),
    log,
    records,
  )
  let ev = mk_ev(@config.EventType::Create, "C:/tmp/once.tmp", 10)
  bus.publish("create.*", ev)
  bus.publish("create.*", ev)
  assert_eq(records.val.length(), 1)
  // 订阅未注销（scheduler 侧 once 保留订阅以支持热重载语义），由 executed_rules 拦下
  bus.publish("create.*", ev)
  assert_eq(records.val.length(), 1)
}

///|
test "P1 优先级：Rule.priority 落到 TriggerRegistry，高优先先执行" {
  let bus = mk_kernel_bus()
  // 注册序故意低优先在前：若只靠 attach_rules 预排序/或 priority 未下传，顺序会颠倒
  let low = mk_log_rule("low", ["create"], ["*.tmp"], [], None, 1, false)
  let high = mk_log_rule("high", ["create"], ["*.tmp"], [], None, 90, false)
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let _ = @scheduler.attach_rules(
    [low, high],
    bus,
    @action.build_policy([]),
    "C:/tmp",
    quiet_logging(),
    log,
    records,
  )
  bus.publish("create.*", mk_ev(@config.EventType::Create, "C:/tmp/p.tmp", 10))
  assert_eq(records.val.length(), 2)
  assert_eq(records.val[0].rule_id, "high", msg="首条应为高优先")
  assert_eq(records.val[1].rule_id, "low", msg="次条应为低优先")
}
