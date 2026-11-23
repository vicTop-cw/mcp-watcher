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
