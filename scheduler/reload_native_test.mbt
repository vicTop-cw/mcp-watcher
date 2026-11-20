// ============================================================================
// reload_native_test —— EP-01d · native 验收：rules_file 真实文件 →
// internal reload_config 通道 → 规则表热切换（新规则生效）
//
// 门控 native：@mon.fs_write_atomic 需 native C FFI（同 internal_wiring_test 范式）。
// 防抖/门控逻辑见全目标 reload_test.mbt；本文件聚焦「真文件 → 真 reload op →
// 规则表切换 + 失败保留旧表」的验收闭环。
// ============================================================================

///|
fn mk_rule_ep01d(id : String) -> @config.Rule {
  let a = @config.ActionSpec::new_internal("log_event", Some("x"))
  @config.Rule::new(id, ["create"], ["*.tmp"], [], None, [a], false, 0, None)
}

///|
fn ep01d_cfg(rules_body : String) -> String {
  "{\"schema_version\":1,\"watch_id\":\"ep01d\",\"watch_dir\":\".\"," +
    "\"rules\":" +
    rules_body +
    ",\"allowed_programs\":[\"echo\"]}"
}

///|
fn ep01d_ev(tmp : String) -> @watch.FsEvent {
  @watch.FsEvent::new(@config.EventType::Modify, tmp, false, 0, 0)
}

///|
test "验收: 规则文件 1→2 规则 → internal 通道 reload → 规则表热切换" {
  @rx.install_real_clock()
  let tmp = "tests/harness/.ep01d-reload.json"
  let r1 =
    "{\"id\":\"r1\",\"events\":[\"create\"],\"patterns\":[\"*.tmp\"]," +
    "\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"a\"]}]}"
  match @mon.fs_write_atomic(tmp, ep01d_cfg("[" + r1 + "]")) {
    Err(_) => assert_true(false)
    Ok(_) => ()
  }
  // 初始规则表：1 条（daemon 启动时加载的形态）
  let rules_ref = Ref::Ref([mk_rule_ep01d("r1")])
  let state = @scheduler.WatcherState::new(
    tmp, "ep01d", ".", rules_ref=Some(rules_ref),
  )
  let reg = @scheduler.build_internal_registry(state)
  let log : Ref[Array[String]] = Ref::Ref([])

  // 1) 首次触发：解析文件（1 规则）→ 热切换
  @scheduler.fire_rules_reload(reg, state, ep01d_ev(tmp), log)
  assert_eq(rules_ref.val.length(), 1)
  assert_eq(rules_ref.val[0].id, "r1")
  assert_true(log.val[0].contains("ok"))

  // 2) 文件改为 2 规则 → 触发 → 新规则生效（验收核心）
  let r2 =
    "{\"id\":\"r2\",\"events\":[\"modify\"],\"patterns\":[\"*.log\"]," +
    "\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"b\"]}]}"
  match @mon.fs_write_atomic(tmp, ep01d_cfg("[" + r1 + ", " + r2 + "]")) {
    Err(_) => assert_true(false)
    Ok(_) => ()
  }
  @scheduler.fire_rules_reload(reg, state, ep01d_ev(tmp), log)
  assert_eq(rules_ref.val.length(), 2)
  assert_eq(rules_ref.val[1].id, "r2")
  assert_true(log.val[1].contains("ok"))

  // 3) 坏文件 → 触发 → 保留旧表（2 规则不变）+ 失败可诊断
  match @mon.fs_write_atomic(tmp, "{broken json") {
    Err(_) => assert_true(false)
    Ok(_) => ()
  }
  @scheduler.fire_rules_reload(reg, state, ep01d_ev(tmp), log)
  assert_eq(rules_ref.val.length(), 2)
  assert_eq(rules_ref.val[1].id, "r2")
  assert_true(log.val[2].contains("err"))
  let _ = @mon.fs_remove(tmp)
}

///|
test "op: 带 rules_ref 的 reload_config → 回执消息含「热切换」标注" {
  @rx.install_real_clock()
  let tmp = "tests/harness/.ep01d-opmsg.json"
  let r1 =
    "{\"id\":\"r1\",\"events\":[\"create\"],\"patterns\":[\"*.tmp\"]," +
    "\"actions\":[{\"kind\":\"command\",\"argv\":[\"echo\",\"a\"]}]}"
  match @mon.fs_write_atomic(tmp, ep01d_cfg("[" + r1 + "]")) {
    Err(_) => assert_true(false)
    Ok(_) => ()
  }
  let rules_ref = Ref::Ref([mk_rule_ep01d("r0")])
  let state = @scheduler.WatcherState::new(
    tmp, "ep01d", ".", rules_ref=Some(rules_ref),
  )
  let reg = @scheduler.build_internal_registry(state)
  let mut got = false
  match reg.lookup("reload_config") {
    Some(h) => {
      got = true
      let oc = h(
        @config.ActionSpec::new_internal("reload_config", None),
        ep01d_ev(tmp),
        ".",
      )
      assert_true(oc.ok)
      assert_true(oc.stdout.contains("热切换"))
      assert_eq(rules_ref.val.length(), 1)
      assert_eq(rules_ref.val[0].id, "r1")
    }
    None => assert_true(false)
  }
  assert_true(got)
  let _ = @mon.fs_remove(tmp)
}
