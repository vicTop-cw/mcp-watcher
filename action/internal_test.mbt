// ============================================================================
// internal_test —— EP-01a internal 动作注册表 + 占位符渲染（纯测试，全目标）
//
// 覆盖：
//   - render_placeholders（schema §7 变量占位符：全变量 / 未知变量 / 无扩展名 / 空模板）
//   - InternalRegistry（register / lookup）
//   - run_internal_action（缺 op / 未注册 / 正常分派）
//   - run_action 的 internal 分支接线（注册表分派 / 未注册可诊断错误）
//   - LifecycleEvent Logged 变体（product.logged）与 message 字段
//   - ActionSpec::new_internal 字段回环
// ============================================================================

///|
fn mk_ev_int(path : String) -> @watch.FsEvent {
  @watch.FsEvent::new(@config.EventType::Create, path, false, 1700000000, 1234)
}

///|
fn quiet_int() -> @config.LoggingConfig {
  { enabled: false, log_dir: "", log_file: "mcp-watcher.log", }
}

// ---------------------------------------------------------------------------
// render_placeholders（schema §7）
// ---------------------------------------------------------------------------

///|
test "render: 全变量集合按 schema §7 替换" {
  let ev = mk_ev_int("/tmp/sub/data.txt")
  let (out, warns) = @action.render_placeholders(
    "{file.path}|{file.name}|{file.dir}|{file.ext}|{file.size}|{file.mtime}|{event.type}|{watch_dir}|{watch_id}",
    ev,
    "D:/watch",
    "wid-1",
  )
  assert_eq(
    out,
    "/tmp/sub/data.txt|data.txt|/tmp/sub|txt|1234|1700000000|create|D:/watch|wid-1",
  )
  assert_eq(warns.length(), 0)
}

///|
test "render: Windows 反斜杠路径的 dir/name/ext 拆分" {
  let ev = @watch.FsEvent::new(
    @config.EventType::Create, "C:\\work\\sub\\a.txt", false, 0, 5,
  )
  let (out, warns) = @action.render_placeholders(
    "{file.dir}|{file.name}|{file.ext}",
    ev,
    "",
    "",
  )
  assert_eq(out, "C:\\work\\sub|a.txt|txt")
  assert_eq(warns.length(), 0)
}

///|
test "render: 未知占位符替换为空串并记 warning（不中断）" {
  let ev = mk_ev_int("/tmp/a.txt")
  let (out, warns) = @action.render_placeholders("x={unknown.var}y", ev, ".", "w")
  assert_eq(out, "x=y")
  assert_eq(warns.length(), 1)
}

///|
test "render: 无扩展名文件的 {file.ext} 替换为空串并记 warning" {
  let ev = @watch.FsEvent::new(
    @config.EventType::Modify, "/tmp/README", false, 0, 0,
  )
  let (out, warns) = @action.render_placeholders("e={file.ext}", ev, ".", "w")
  assert_eq(out, "e=")
  assert_eq(warns.length(), 1)
}

///|
test "render: 空模板直通（无 warning）" {
  let ev = mk_ev_int("/tmp/a.txt")
  let (out, warns) = @action.render_placeholders("", ev, ".", "w")
  assert_eq(out, "")
  assert_eq(warns.length(), 0)
}

// ---------------------------------------------------------------------------
// InternalRegistry
// ---------------------------------------------------------------------------

///|
test "registry: register 后可 lookup，未注册返回 None" {
  let reg = @action.InternalRegistry::new()
  reg.register(
    "demo",
    fn(_spec : @config.ActionSpec, _ev : @watch.FsEvent, _d : String) {
      @action.ActionOutcome::new("internal", true, 0, "demo-ok", "")
    },
  )
  match reg.lookup("demo") {
    Some(_) => ()
    None => assert_true(false)
  }
  match reg.lookup("missing") {
    None => ()
    Some(_) => assert_true(false)
  }
}

///|
test "run_internal_action: 缺 op 返回可诊断错误" {
  let reg = @action.InternalRegistry::new()
  let spec = @config.ActionSpec::new("internal", None, None, None, None)
  match @action.run_internal_action(reg, spec, mk_ev_int("/tmp/a"), "d") {
    Err(e) => assert_true(e.contains("op"))
    Ok(_) => assert_true(false)
  }
}

///|
test "run_internal_action: 未注册 op 返回可诊断错误（含 op 名）" {
  let reg = @action.InternalRegistry::new()
  let spec = @config.ActionSpec::new_internal("ghost_op", None)
  match @action.run_internal_action(reg, spec, mk_ev_int("/tmp/a"), "d") {
    Err(e) => assert_true(e.contains("ghost_op"))
    Ok(_) => assert_true(false)
  }
}

///|
test "run_internal_action: 注册 handler 的失败结果映射为 Err" {
  let reg = @action.InternalRegistry::new()
  reg.register(
    "boom",
    fn(_spec : @config.ActionSpec, _ev : @watch.FsEvent, _d : String) {
      @action.ActionOutcome::new("internal", false, -1, "", "boom-failed")
    },
  )
  let spec = @config.ActionSpec::new_internal("boom", None)
  match @action.run_internal_action(reg, spec, mk_ev_int("/tmp/a"), "d") {
    Err(e) => assert_true(e.contains("boom-failed"))
    Ok(_) => assert_true(false)
  }
}

// ---------------------------------------------------------------------------
// run_action internal 分支
// ---------------------------------------------------------------------------

///|
test "run_action: internal 动作经注册表分派（stdout 可断言）" {
  let reg = @action.InternalRegistry::new()
  reg.register(
    "demo",
    fn(_spec : @config.ActionSpec, _ev : @watch.FsEvent, _d : String) {
      @action.ActionOutcome::new("internal", true, 0, "demo-marker", "")
    },
  )
  let spec = @config.ActionSpec::new_internal("demo", None)
  let policy = @action.build_policy([])
  match @action.run_action(
    spec, mk_ev_int("/tmp/a"), policy, quiet_int(), "D:/watch", registry=reg,
  ) {
    Ok(o) => {
      assert_true(o.ok)
      assert_true(o.accepted)
      assert_eq(o.stdout, "demo-marker")
    }
    Err(_) => assert_true(false)
  }
}

///|
test "run_action: internal 未注册 op 返回可诊断错误" {
  let reg = @action.InternalRegistry::new()
  let spec = @config.ActionSpec::new_internal("ghost_op", None)
  let policy = @action.build_policy([])
  match @action.run_action(
    spec, mk_ev_int("/tmp/a"), policy, quiet_int(), "D:/watch", registry=reg,
  ) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("ghost_op"))
  }
}

// ---------------------------------------------------------------------------
// 模型增量：ActionSpec.op/message 与 LifecycleEvent.Logged
// ---------------------------------------------------------------------------

///|
test "ActionSpec::new_internal: 字段回环" {
  let s = @config.ActionSpec::new_internal("log_event", Some("hello {file.name}"))
  assert_eq(s.kind, "internal")
  match s.op {
    Some("log_event") => ()
    _ => assert_true(false)
  }
  match s.message {
    Some(m) => assert_eq(m, "hello {file.name}")
    None => assert_true(false)
  }
}

///|
test "ActionSpec::new: v1.0 构造 op/message 缺省为 None（向后兼容锁）" {
  let s = @config.ActionSpec::new("command", Some(["echo"]), None, None, None)
  match s.op {
    None => ()
    Some(_) => assert_true(false)
  }
  match s.message {
    None => ()
    Some(_) => assert_true(false)
  }
}

///|
test "LifecycleEvent: Logged 变体 product.logged 与 message 字段" {
  let e = @action.LifecycleEvent::new_with_message(
    @config.LifecycleEventType::Logged,
    "/tmp/a.txt",
    "msg-1",
  )
  assert_eq(e.event_name(), "product.logged")
  assert_eq(e.message, "msg-1")
  // 向后兼容：new() 保持两参，message 缺省空串
  let e2 = @action.LifecycleEvent::new(
    @config.LifecycleEventType::Logged, "/tmp/a.txt",
  )
  assert_eq(e2.message, "")
}

///|
test "LifecycleEventType: logged 字符串往返" {
  assert_eq(@config.LifecycleEventType::Logged.to_string(), "product.logged")
  match @config.LifecycleEventType::from_string("logged") {
    Some(@config.LifecycleEventType::Logged) => ()
    _ => assert_true(false)
  }
}
