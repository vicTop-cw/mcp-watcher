// ============================================================================
// internal_wiring_test —— EP-01a 四 op e2e（native 专属）
//
// 覆盖「规则内触发」全链路：规则 → EventBus 派发 → internal 动作 → WatcherState 效果
//   - reload_config：复用 scheduler 既有 reload_config（stdout 带 rules=N；失败可诊断）
//   - pause_watch / resume_watch：WatcherState.paused 门控翻转
//   - log_event：落 LifecycleEvent（Logged / product.logged，message 占位符已展开）
//
// 门控 native：reload 用例需 @mon.fs_write_atomic 写临时规则文件（native C FFI）。
// ============================================================================

///|
fn mk_internal_rule(id : String, op : String, message : String?) -> @config.Rule {
  let a = @config.ActionSpec::new_internal(op, message)
  @config.Rule::new(id, ["create"], ["*.tmp"], [], None, [a], false, 0, None)
}

///|
fn mk_event_wiring(path : String) -> @watch.FsEvent {
  @watch.FsEvent::new(@config.EventType::Create, path, false, 0, 0)
}

///|
fn quiet_sch() -> @config.LoggingConfig {
  { enabled: false, log_dir: "", log_file: "mcp-watcher.log", }
}

// ---------------------------------------------------------------------------
// reload_config（直连 scheduler.mbt 既有函数）
// ---------------------------------------------------------------------------

///|
test "e2e: internal reload_config 成功（stdout 带真实规则数）" {
  @rx.install_real_clock()
  let tmp_rules = "E:/IDEProjects/AI/mcp-watcher/tests/harness/.ep01a-reload.json"
  let rules_json =
    "{\"schema_version\":1,\"watch_id\":\"ep01a\",\"watch_dir\":\".\",\"rules\":[" +
    "{\"id\":\"r1\",\"events\":[\"create\"],\"patterns\":[\"*.tmp\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"a\"]}]}, " +
    "{\"id\":\"r2\",\"events\":[\"modify\"],\"patterns\":[\"*.log\"],\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"b\"]}]}]}"
  match @mon.fs_write_atomic(tmp_rules, rules_json) {
    Err(_) => assert_true(false)
    Ok(_) => ()
  }

  let state = @scheduler.WatcherState::new(tmp_rules, "ep01a", "C:/tmp")
  let reg = @scheduler.build_internal_registry(state)
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let _ = @scheduler.attach_rules(
    [mk_internal_rule("ep01a-reload", "reload_config", None)],
    bus,
    @action.build_policy([]),
    "C:/tmp",
    quiet_sch(),
    log,
    records,
    registry=reg,
  )

  bus.publish("create.*", mk_event_wiring("C:/tmp/ep01a-reload.tmp"))

  assert_eq(records.val.length(), 1)
  assert_eq(records.val[0].exit_code, 0)
  assert_true(records.val[0].stdout.contains("rules=2"))
  assert_true(log.val.length() >= 1)
  assert_true(log.val[0].contains("ok exit=0"))
  let _ = @mon.fs_remove(tmp_rules)
}

///|
test "e2e: internal reload_config 失败（文件不存在，可诊断且退出码 -1）" {
  @rx.install_real_clock()
  let state = @scheduler.WatcherState::new(
    "E:/IDEProjects/AI/mcp-watcher/no-such-ep01a-file.json",
    "ep01a",
    "C:/tmp",
  )
  let reg = @scheduler.build_internal_registry(state)
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let _ = @scheduler.attach_rules(
    [mk_internal_rule("ep01a-reload-bad", "reload_config", None)],
    bus,
    @action.build_policy([]),
    "C:/tmp",
    quiet_sch(),
    log,
    records,
    registry=reg,
  )

  bus.publish("create.*", mk_event_wiring("C:/tmp/ep01a-reload-bad.tmp"))

  // 失败走 run_action 的 Err 分支：exit_code=-1，stderr 携带可诊断原因
  assert_eq(records.val.length(), 1)
  assert_eq(records.val[0].exit_code, -1)
  assert_true(records.val[0].stderr.contains("热重载失败"))
  assert_true(log.val[0].contains("err:"))
}

// ---------------------------------------------------------------------------
// pause_watch / resume_watch
// ---------------------------------------------------------------------------

///|
test "e2e: internal pause_watch 翻转 WatcherState.paused" {
  @rx.install_real_clock()
  let state = @scheduler.WatcherState::new("unused.json", "ep01a", "C:/tmp")
  assert_false(state.paused.val)
  let reg = @scheduler.build_internal_registry(state)
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let _ = @scheduler.attach_rules(
    [mk_internal_rule("ep01a-pause", "pause_watch", None)],
    bus,
    @action.build_policy([]),
    "C:/tmp",
    quiet_sch(),
    log,
    records,
    registry=reg,
  )

  bus.publish("create.*", mk_event_wiring("C:/tmp/ep01a-pause.tmp"))

  assert_true(state.paused.val)
  assert_eq(records.val.length(), 1)
  assert_eq(records.val[0].exit_code, 0)
  assert_eq(records.val[0].stdout, "watch paused")
}

///|
test "e2e: internal resume_watch 恢复 paused=false" {
  @rx.install_real_clock()
  let state = @scheduler.WatcherState::new("unused.json", "ep01a", "C:/tmp")
  state.paused.val = true
  let reg = @scheduler.build_internal_registry(state)
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let _ = @scheduler.attach_rules(
    [mk_internal_rule("ep01a-resume", "resume_watch", None)],
    bus,
    @action.build_policy([]),
    "C:/tmp",
    quiet_sch(),
    log,
    records,
    registry=reg,
  )

  bus.publish("create.*", mk_event_wiring("C:/tmp/ep01a-resume.tmp"))

  assert_false(state.paused.val)
  assert_eq(records.val[0].stdout, "watch resumed")
}

// ---------------------------------------------------------------------------
// log_event（落 LifecycleEvent）
// ---------------------------------------------------------------------------

///|
test "e2e: internal log_event 落 LifecycleEvent（message 占位符已展开）" {
  @rx.install_real_clock()
  let state = @scheduler.WatcherState::new("unused.json", "ep01a", "C:/tmp")
  let reg = @scheduler.build_internal_registry(state)
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let _ = @scheduler.attach_rules(
    [mk_internal_rule(
      "ep01a-log",
      "log_event",
      Some("hit {file.name} {event.type}"),
    )],
    bus,
    @action.build_policy([]),
    "C:/tmp",
    quiet_sch(),
    log,
    records,
    registry=reg,
  )

  bus.publish("create.*", mk_event_wiring("C:/tmp/ep01a-log.tmp"))

  assert_eq(records.val[0].exit_code, 0)
  assert_eq(state.lifecycle_events.val.length(), 1)
  let le = state.lifecycle_events.val[0]
  assert_eq(le.kind.to_string(), "product.logged")
  assert_eq(le.path, "C:/tmp/ep01a-log.tmp")
  assert_eq(le.message, "hit ep01a-log.tmp create")
}

///|
test "run_once: internal log_event 走既有执行日志（单趟离线语义）" {
  let state = @scheduler.WatcherState::new("unused.json", "ep01a", "C:/tmp")
  let reg = @scheduler.build_internal_registry(state)
  let log = @scheduler.run_once(
    [mk_internal_rule("ep01a-log-once", "log_event", Some("once {file.name}"))],
    mk_event_wiring("C:/tmp/once.tmp"),
    @action.build_policy([]),
    quiet_sch(),
    "C:/tmp",
    registry=reg,
  )
  assert_eq(log.length(), 1)
  assert_true(log[0].contains("ok exit=0"))
  assert_eq(state.lifecycle_events.val.length(), 1)
  assert_eq(state.lifecycle_events.val[0].message, "once once.tmp")
}
