// ============================================================================
// mcp_native_test —— EP-01c mcp_tool_call · 非 js 目标诚实降级（仅 native）
//
// 仅 native 目标（moon.pkg 门控到 "native"）：无 node:child_process 同步
// stdio 原语的目标上，run_mcp_action **不伪装成功**，返回可诊断 Err
// （与 webhook/trash 同款诚实降级策略）。
// ============================================================================

///|
fn mk_ev_mcpn(path : String) -> @watch.FsEvent {
  @watch.FsEvent::new(@config.EventType::Create, path, false, 1700000000, 10)
}

///|
test "mcp native: stdio 传输不可用 → 诚实降级（ok=false + 可诊断原因）" {
  let spec = @config.ActionSpec::new_mcp(
    "node",
    "publish",
    Some("{\"x\":1}"),
    Some(["srv.mjs"]),
    1000,
  )
  let o = @action.run_mcp_action(
    spec,
    mk_ev_mcpn("/tmp/a.txt"),
    @action.build_policy(["node"]),
    ".",
    "w",
  )
  assert_true(!o.ok)
  assert_eq(o.exit_code, -1)
  assert_true(o.stderr.contains("mcp"))
  assert_true(o.stderr.contains("目标"))
}

///|
test "mcp native: run_action 的 mcp 分支返回 Err（诚实降级）" {
  let spec = @config.ActionSpec::new_mcp("node", "publish", None, None, 1000)
  let logging : @config.LoggingConfig =
    { enabled: false, log_dir: "", log_file: "mcp-watcher.log", }
  match @action.run_action(
    spec,
    mk_ev_mcpn("/tmp/a.txt"),
    @action.build_policy(["node"]),
    logging,
    ".",
  ) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("mcp"))
  }
}

///|
test "mcp 全目标: sse/http transport 未实现 → 可诊断 Err（v1 仅 stdio）" {
  let spec = @config.ActionSpec::new_mcp(
    "node",
    "publish",
    None,
    Some(["srv.mjs"]),
    1000,
  )
  // 直接构造 sse 变体：复用 new_mcp 后无法改 transport（字段非 pub 可写），
  // 故经 loader 解析构造
  let json =
    "{\"schema_version\":1,\"watch_id\":\"t\",\"watch_dir\":\".\"," +
    "\"rules\":[{\"id\":\"r\",\"events\":[\"create\"],\"patterns\":[\"**/*\"]," +
    "\"actions\":[{\"type\":\"mcp_tool_call\",\"server\":\"node\",\"tool\":\"publish\",\"transport\":\"sse\"}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => {
      let s = cfg.rules[0].actions[0]
      let o = @action.run_mcp_action(
        s,
        mk_ev_mcpn("/tmp/a.txt"),
        @action.build_policy(["node"]),
        ".",
        "w",
      )
      assert_true(!o.ok)
      assert_true(o.stderr.contains("transport"))
    }
    Err(_) => assert_true(false)
  }
}
