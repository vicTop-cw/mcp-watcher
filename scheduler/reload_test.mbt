// ============================================================================
// scheduler/reload_test.mbt —— EP-01d · rules_file 热重载（全目标）
//
// 覆盖：
//   - RulesFileDebounce 状态机（record/due/fire；假时钟，含窗口边界）
//   - rules_file_event_match（斜杠归一 / 精确 / 分段后缀；反假阳性）
//   - is_reload_trigger（modify/create 触发；delete/rename/attrib 不触发）
//   - rules_file_dir / dir_covers（daemon「rules 目录补监控」判定）
//   - fire_rules_reload（EP-01a internal 通道触发 reload_config；
//     未注册/op 失败 → 可诊断日志）
//   - 确定性 e2e：bus 事件 → 路径匹配 → 防抖 → 恰好触发一次
//     （install_real_clock_with 可控墙钟 + real_clock_tick 驱动，
//       无需真实 sleep；timer 挂在 default_clock 上由 tick 推进）
//
// ⚠️ e2e 会推进 rx 全局 default_clock（虚拟定时器路径不可避免）；
//    测试末尾 uninstall_real_clock 恢复虚拟路径。既有测试不依赖
//    虚拟时钟绝对值，无污染。
// ============================================================================

///|
fn mk_re_ev(path : String, t : @config.EventType) -> @watch.FsEvent {
  @watch.FsEvent::new(t, path, false, 1700000000, 10)
}

// ---------------------------------------------------------------------------
// RulesFileDebounce 状态机
// ---------------------------------------------------------------------------

///|
test "debounce: 无 pending 事件 → 任何时刻不触发" {
  let d = @scheduler.RulesFileDebounce::new()
  assert_true(!d.due(0, 300))
  assert_true(!d.due(10_000, 300))
}

///|
test "debounce: 单事件 — 窗口边界内不触发，到期触发" {
  let d = @scheduler.RulesFileDebounce::new()
  d.record(0)
  assert_true(!d.due(299, 300))
  assert_true(d.due(300, 300))
}

///|
test "debounce: 突发合并 — 自最新事件起窗口过后才触发" {
  let d = @scheduler.RulesFileDebounce::new()
  d.record(0)
  d.record(100)
  d.record(200)
  assert_true(!d.due(499, 300))
  assert_true(d.due(500, 300))
}

///|
test "debounce: fire 后清除 — 不重复触发；新事件重新武装" {
  let d = @scheduler.RulesFileDebounce::new()
  d.record(0)
  assert_true(d.due(300, 300))
  d.fire()
  assert_true(!d.due(9999, 300))
  d.record(100)
  assert_true(d.due(400, 300))
}

///|
test "debounce: window=0 → 当拍即触发" {
  let d = @scheduler.RulesFileDebounce::new()
  d.record(5)
  assert_true(d.due(5, 0))
}

// ---------------------------------------------------------------------------
// 路径匹配 / 触发类型 / 目录判定
// ---------------------------------------------------------------------------

///|
test "event 匹配: 精确 / 双向分段后缀 / 反斜杠归一" {
  assert_true(@scheduler.rules_file_event_match("a/b/rules.json", "a/b/rules.json"))
  assert_true(@scheduler.rules_file_event_match("/abs/a/b/rules.json", "a/b/rules.json"))
  assert_true(@scheduler.rules_file_event_match("a/b/rules.json", "/abs/a/b/rules.json"))
  assert_true(@scheduler.rules_file_event_match("a\\b\\rules.json", "a/b/rules.json"))
}

///|
test "event 匹配: 异文件 / 前缀相似名不假阳" {
  assert_true(!@scheduler.rules_file_event_match("a/b/other.json", "a/b/rules.json"))
  assert_true(!@scheduler.rules_file_event_match("a/b/rules.json2", "a/b/rules.json"))
  assert_true(!@scheduler.rules_file_event_match("a/b/rules.json", "a/b/rules.json2"))
}

///|
test "reload 触发: modify/create 触发；delete/rename/attrib 不触发" {
  assert_true(
    @scheduler.is_reload_trigger(mk_re_ev("r.json", @config.EventType::Modify)),
  )
  assert_true(
    @scheduler.is_reload_trigger(mk_re_ev("r.json", @config.EventType::Create)),
  )
  assert_true(
    !@scheduler.is_reload_trigger(mk_re_ev("r.json", @config.EventType::Delete)),
  )
  assert_true(
    !@scheduler.is_reload_trigger(mk_re_ev("r.json", @config.EventType::Rename)),
  )
  assert_true(
    !@scheduler.is_reload_trigger(mk_re_ev("r.json", @config.EventType::Attrib)),
  )
}

///|
test "rules_file_dir: 取目录（反斜杠 / 无目录两种形态）" {
  assert_eq(@scheduler.rules_file_dir("a/b/rules.json"), "a/b")
  assert_eq(@scheduler.rules_file_dir("rules.json"), ".")
  assert_eq(@scheduler.rules_file_dir("a\\b\\rules.json"), "a/b")
  assert_eq(@scheduler.rules_file_dir("/abs/a/b/rules.json"), "/abs/a/b")
}

///|
test "dir_covers: 相等 / 父子覆盖；前缀相似不假阳" {
  assert_true(@scheduler.dir_covers(".", "a/b"))
  assert_true(@scheduler.dir_covers("a/b", "a/b/c"))
  assert_true(@scheduler.dir_covers("a/b", "a/b"))
  assert_true(!@scheduler.dir_covers("a/b/c", "a/b"))
  assert_true(!@scheduler.dir_covers("a/b", "a/bc"))
}

// ---------------------------------------------------------------------------
// fire_rules_reload（internal 通道触发；stub 注册表，无文件 I/O）
// ---------------------------------------------------------------------------

///|
fn mk_stub_registry(ok~ : Bool = true) -> @action.InternalRegistry {
  let reg = @action.InternalRegistry::new()
  @action.InternalRegistry::register(
    reg,
    "reload_config",
    fn(_s : @config.ActionSpec, _e : @watch.FsEvent, _d : String) {
      if ok {
        @action.ActionOutcome::new("internal", true, 0, "reload ok rules=2", "")
      } else {
        @action.ActionOutcome::new(
          "internal", false, -1, "", "热重载失败: parse error",
        )
      }
    },
  )
  reg
}

///|
test "fire_rules_reload: 经 internal 通道触发 reload_config（成功落 log）" {
  let state = @scheduler.WatcherState::new("rules.json", "w", ".")
  let log : Ref[Array[String]] = Ref::Ref([])
  @scheduler.fire_rules_reload(
    mk_stub_registry(),
    state,
    mk_re_ev("rules.json", @config.EventType::Modify),
    log,
  )
  assert_eq(log.val.length(), 1)
  assert_true(log.val[0].contains("reload ok"))
}

///|
test "fire_rules_reload: op 未注册 → 可诊断 log，不抛异常" {
  let state = @scheduler.WatcherState::new("rules.json", "w", ".")
  let log : Ref[Array[String]] = Ref::Ref([])
  @scheduler.fire_rules_reload(
    @action.InternalRegistry::new(),
    state,
    mk_re_ev("x", @config.EventType::Modify),
    log,
  )
  assert_eq(log.val.length(), 1)
  assert_true(log.val[0].contains("未注册"))
}

///|
test "fire_rules_reload: op 失败 → err log 含原因" {
  let state = @scheduler.WatcherState::new("rules.json", "w", ".")
  let log : Ref[Array[String]] = Ref::Ref([])
  @scheduler.fire_rules_reload(
    mk_stub_registry(ok=false),
    state,
    mk_re_ev("x", @config.EventType::Modify),
    log,
  )
  assert_true(log.val[0].contains("err"))
  assert_true(log.val[0].contains("parse error"))
}

// ---------------------------------------------------------------------------
// 确定性 e2e：bus 事件 → 匹配 → 防抖 → 恰好触发一次（可控墙钟）
// ---------------------------------------------------------------------------

///|
fn e2e_setup() -> (
  @rx.EventBus[@watch.FsEvent],
  @scheduler.WatcherState,
  Ref[Array[String]],
  @action.InternalRegistry,
  Ref[Array[String]],
) {
  let calls = Ref::Ref([])
  let reg = @action.InternalRegistry::new()
  @action.InternalRegistry::register(
    reg,
    "reload_config",
    fn(_s : @config.ActionSpec, e : @watch.FsEvent, _d : String) {
      calls.val.push(e.path)
      @action.ActionOutcome::new("internal", true, 0, "reloaded", "")
    },
  )
  let state = @scheduler.WatcherState::new("rules.json", "w", ".")
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  (bus, state, calls, reg, log)
}

///|
test "e2e: 单次变更 → 防抖窗口后恰好触发一次 reload" {
  let wall = @rx.Clock::new()
  @rx.install_real_clock_with(wall)
  let (bus, state, calls, reg, log) = e2e_setup()
  let n = @scheduler.attach_rules_file_reload(bus, state, reg, 300, log)
  assert_eq(n, 2)
  // t=0：变更事件
  bus.publish("modify.*", mk_re_ev("rules.json", @config.EventType::Modify))
  // t=100：窗口未过 → 不触发
  wall.advance(100)
  @rx.real_clock_tick()
  assert_eq(calls.val.length(), 0)
  // t=400：窗口已过 → 恰好触发一次
  wall.advance(300)
  @rx.real_clock_tick()
  assert_eq(calls.val.length(), 1)
  assert_eq(calls.val[0], "rules.json")
  assert_true(log.val.length() >= 1)
  assert_true(log.val[0].contains("ok"))
  // t=2400：无新事件 → 不重复触发
  wall.advance(2000)
  @rx.real_clock_tick()
  assert_eq(calls.val.length(), 1)
  @rx.uninstall_real_clock()
}

///|
test "e2e: 突发合并 — 窗口内多次变更只触发一次（最后一拍才生效）" {
  let wall = @rx.Clock::new()
  @rx.install_real_clock_with(wall)
  let (bus, state, calls, reg, log) = e2e_setup()
  let _ = @scheduler.attach_rules_file_reload(bus, state, reg, 300, log)
  // t=0 变更（timer#1 武装，期限 dc=300）
  bus.publish("modify.*", mk_re_ev("rules.json", @config.EventType::Modify))
  wall.advance(100)
  @rx.real_clock_tick()
  // t=100 再变更（timer#2 武装，期限 dc=400；last_event=100）
  bus.publish("create.*", mk_re_ev("rules.json", @config.EventType::Create))
  // dc=300：timer#1 触发 → 距最新事件仅 200 < 300 → 不触发
  wall.advance(200)
  @rx.real_clock_tick()
  assert_eq(calls.val.length(), 0)
  // dc=400：timer#2 触发 → 距最新事件 300 ≥ 300 → 恰好触发一次
  wall.advance(100)
  @rx.real_clock_tick()
  assert_eq(calls.val.length(), 1)
  @rx.uninstall_real_clock()
}

///|
test "e2e: 门控 — 非匹配路径 / 非触发类型 / paused 均不触发" {
  let wall = @rx.Clock::new()
  @rx.install_real_clock_with(wall)
  let (bus, state, calls, reg, log) = e2e_setup()
  let _ = @scheduler.attach_rules_file_reload(bus, state, reg, 300, log)
  bus.publish("modify.*", mk_re_ev("other/file.txt", @config.EventType::Modify))
  bus.publish("delete.*", mk_re_ev("rules.json", @config.EventType::Delete))
  state.paused.val = true
  bus.publish("modify.*", mk_re_ev("rules.json", @config.EventType::Modify))
  wall.advance(5000)
  @rx.real_clock_tick()
  assert_eq(calls.val.length(), 0)
  @rx.uninstall_real_clock()
}
