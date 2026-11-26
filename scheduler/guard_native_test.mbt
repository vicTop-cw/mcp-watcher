// ============================================================================
// scheduler · 守卫门集成验证（native 专属 · PLAN-gates.md §二）
//
// 真实 cmd 命令 + EventBus 派发，覆盖验收用例（最少集）：
//   1. guard exit 0 → actions 正常执行
//   2. guard 非 0 + on_fail=skip → actions 零执行、guard_fail 事件在位
//      （skip 不退场：再次事件仍触发 guard_fail）
//   3. guard 程序不在白名单 → 运行期 ExecPolicy 拒绝（与 command 同策略）
//   4. 无 guard 字段 → v1.0 行为不变（向后兼容锁，由既有 scheduler_test 覆盖）
// 另有 stop 语义：guard 非 0 + on_fail=stop → 规则退场，后续事件不再处理
// ============================================================================

///|
fn quiet_guard() -> @config.LoggingConfig {
  { enabled: false, log_dir: "", log_file: "mcp-watcher.log", }
}

///|
fn gmk_event(path : String) -> @watch.FsEvent {
  @watch.FsEvent::new(@config.EventType::Create, path, false, 0, 0)
}

///|
fn mk_action(id : String) -> @config.ActionSpec {
  @config.ActionSpec::new(
    "command",
    Some(["cmd", "/c", "echo", "ACT-" + id]),
    None,
    None,
    None,
  )
}

///|
fn mk_guard(argv : Array[String], on_fail : String) -> @config.GuardSpec {
  @config.GuardSpec::new(argv, on_fail)
}

///|
fn gmk_rule(id : String, guard_spec : @config.GuardSpec?) -> @config.Rule {
  @config.Rule::new(
    id,
    ["create"],
    ["*.tmp"],
    [],
    None,
    [mk_action(id)],
    false,
    0,
    guard_spec,
  )
}

///|
/// 验收用例1：guard exit 0 → actions 正常执行
test "guard: pass executes actions" {
  @rx.install_real_clock()
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let rule = gmk_rule(
    "g-pass",
    Some(mk_guard(["cmd", "/c", "echo", "guard-ok"], "skip")),
  )
  let policy = @action.build_policy(["cmd"])
  let _ = @scheduler.attach_rules(
    [rule],
    bus,
    policy,
    "C:/tmp",
    quiet_guard(),
    log,
    records,
  )
  bus.publish("create.*", gmk_event("C:/tmp/g-pass.tmp"))
  // 动作真实执行 1 次（ok 日志），无 guard_fail
  let action_lines = log.val.filter(fn(l : String) { l.contains(" ok exit=") })
  assert_eq(action_lines.length(), 1)
  let guard_lines = log.val.filter(fn(l : String) { l.contains("guard_fail") })
  assert_eq(guard_lines.length(), 0)
  assert_eq(records.val.length(), 1)
  assert_eq(records.val[0].action_type, "command")
}

///|
/// 验收用例2：guard 非 0 + on_fail=skip → actions 零执行、guard_fail 事件在位
test "guard: fail + skip skips actions" {
  @rx.install_real_clock()
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let rule = gmk_rule(
    "g-skip",
    Some(mk_guard(["cmd", "/c", "exit", "1"], "skip")),
  )
  let policy = @action.build_policy(["cmd"])
  let _ = @scheduler.attach_rules(
    [rule],
    bus,
    policy,
    "C:/tmp",
    quiet_guard(),
    log,
    records,
  )
  bus.publish("create.*", gmk_event("C:/tmp/g-skip.tmp"))
  // actions 零执行
  let action_lines = log.val.filter(fn(l : String) { l.contains(" ok exit=") })
  assert_eq(action_lines.length(), 0)
  // guard_fail 事件在位（日志 + 结果记录，action_type=guard）
  let guard_lines = log.val.filter(fn(l : String) { l.contains("guard_fail") })
  assert_eq(guard_lines.length(), 1)
  assert_eq(records.val.length(), 1)
  assert_eq(records.val[0].action_type, "guard")
  assert_eq(records.val[0].exit_code, -1)
  assert_true(records.val[0].stderr.contains("退出码 1"))
  // skip 不退场：再次事件仍触发 guard_fail（规则存活）
  bus.publish("create.*", gmk_event("C:/tmp/g-skip2.tmp"))
  let guard_lines2 = log.val.filter(fn(l : String) { l.contains("guard_fail") })
  assert_eq(guard_lines2.length(), 2)
}

///|
/// on_fail=stop：guard 失败后规则退场，后续事件不再处理
test "guard: fail + stop retires rule" {
  @rx.install_real_clock()
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let rule = gmk_rule(
    "g-stop",
    Some(mk_guard(["cmd", "/c", "exit", "1"], "stop")),
  )
  let policy = @action.build_policy(["cmd"])
  let _ = @scheduler.attach_rules(
    [rule],
    bus,
    policy,
    "C:/tmp",
    quiet_guard(),
    log,
    records,
  )
  bus.publish("create.*", gmk_event("C:/tmp/g-stop.tmp"))
  bus.publish("create.*", gmk_event("C:/tmp/g-stop.tmp"))
  // 只 1 次 guard_fail：第二个事件被已退场规则短路
  let guard_lines = log.val.filter(fn(l : String) { l.contains("guard_fail") })
  assert_eq(guard_lines.length(), 1)
  assert_eq(records.val.length(), 1)
  let action_lines = log.val.filter(fn(l : String) { l.contains(" ok exit=") })
  assert_eq(action_lines.length(), 0)
}

///|
/// 验收用例3（运行期侧）：guard 程序不在白名单 → ExecPolicy 拒绝、actions 跳过
test "guard: program not in whitelist denied at runtime" {
  @rx.install_real_clock()
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  // guard 用 agent-cli（不在白名单），动作仍用 cmd（在白名单）
  let rule = gmk_rule(
    "g-deny",
    Some(mk_guard(["agent-cli", "--probe"], "skip")),
  )
  let policy = @action.build_policy(["cmd"])
  let _ = @scheduler.attach_rules(
    [rule],
    bus,
    policy,
    "C:/tmp",
    quiet_guard(),
    log,
    records,
  )
  bus.publish("create.*", gmk_event("C:/tmp/g-deny.tmp"))
  let guard_lines = log.val.filter(fn(l : String) { l.contains("guard_fail") })
  assert_eq(guard_lines.length(), 1)
  // 拒绝原因可观测（与 command 同策略），actions 零执行
  assert_eq(records.val.length(), 1)
  assert_eq(records.val[0].action_type, "guard")
  assert_true(records.val[0].stderr.contains("策略拒绝"))
  let action_lines = log.val.filter(fn(l : String) { l.contains(" ok exit=") })
  assert_eq(action_lines.length(), 0)
}

// ============================================================================
// 组合场景（acceptance + guard 双门禁叠加 · 任务清单 ⑤ 顺手校验）
// ============================================================================

///|
/// 组合：guard 通过 + 动作验收不过 → 无 guard_fail、动作真实执行但
/// acceptance_failed 在位（保留真实 exit 码，record stderr 带验收原因）
test "guard + acceptance: guard passes, acceptance fails" {
  @rx.install_real_clock()
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  // 动作输出 "boom"，验收要求 stdout 含 "DONE"（stdout_contains）→ 必然假绿被堵
  let action = @config.ActionSpec::new(
    "command",
    Some(["cmd", "/c", "echo", "boom"]),
    None,
    None,
    Some(@config.AcceptanceSpec::new(0, ["DONE"], [], [], None)),
  )
  let rule = @config.Rule::new(
    "combo-acc",
    ["create"],
    ["*.tmp"],
    [],
    None,
    [action],
    false,
    0,
    Some(mk_guard(["cmd", "/c", "echo", "guard-ok"], "skip")),
  )
  let policy = @action.build_policy(["cmd"])
  let _ = @scheduler.attach_rules(
    [rule],
    bus,
    policy,
    "C:/tmp",
    quiet_guard(),
    log,
    records,
  )
  bus.publish("create.*", gmk_event("C:/tmp/combo-acc.tmp"))
  // 守卫通过：无 guard_fail
  let guard_lines = log.val.filter(fn(l : String) { l.contains("guard_fail") })
  assert_eq(guard_lines.length(), 0)
  // 动作真实执行但验收不过（acceptance_failed 日志 + record 带原因）
  let acc_lines = log.val.filter(fn(l : String) {
    l.contains("acceptance_failed")
  })
  assert_eq(acc_lines.length(), 1)
  assert_eq(records.val.length(), 1)
  assert_eq(records.val[0].action_type, "command")
  assert_eq(records.val[0].exit_code, 0)
  assert_true(records.val[0].stderr.contains("acceptance failed"))
}

///|
/// 组合：guard 失败 → 动作（含验收）零执行，只有 guard_fail（门禁互不串扰）
test "guard + acceptance: guard fails, acceptance untouched" {
  @rx.install_real_clock()
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  // 动作本身能通过验收（stdout 含 DONE），但守卫先拦下
  let action = @config.ActionSpec::new(
    "command",
    Some(["cmd", "/c", "echo", "DONE"]),
    None,
    None,
    Some(@config.AcceptanceSpec::new(0, ["DONE"], [], [], None)),
  )
  let rule = @config.Rule::new(
    "combo-guard",
    ["create"],
    ["*.tmp"],
    [],
    None,
    [action],
    false,
    0,
    Some(mk_guard(["cmd", "/c", "exit", "1"], "skip")),
  )
  let policy = @action.build_policy(["cmd"])
  let _ = @scheduler.attach_rules(
    [rule],
    bus,
    policy,
    "C:/tmp",
    quiet_guard(),
    log,
    records,
  )
  bus.publish("create.*", gmk_event("C:/tmp/combo-guard.tmp"))
  // 只有 guard_fail；动作零执行（不会误报 ok / acceptance_failed）
  let guard_lines = log.val.filter(fn(l : String) { l.contains("guard_fail") })
  assert_eq(guard_lines.length(), 1)
  let acc_lines = log.val.filter(fn(l : String) {
    l.contains("acceptance_failed")
  })
  assert_eq(acc_lines.length(), 0)
  let action_lines = log.val.filter(fn(l : String) { l.contains(" ok exit=") })
  assert_eq(action_lines.length(), 0)
  assert_eq(records.val.length(), 1)
  assert_eq(records.val[0].action_type, "guard")
}
