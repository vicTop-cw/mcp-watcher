// ============================================================================
// webhook_native_test —— EP-01b webhook · 非 js 目标诚实降级（仅 native）
//
// 仅 native 目标（moon.pkg 门控到 "native"）：run_webhook_action 在无 node:http
// 的目标上**不伪装成功**，返回 ok=false + 可诊断 Err（trash 同款诚实降级）。
// ============================================================================

///|
fn mk_ev_whn(path : String) -> @watch.FsEvent {
  @watch.FsEvent::new(@config.EventType::Create, path, false, 1700000000, 10)
}

///|
test "webhook native: 无 node:http 目标诚实降级（ok=false + 可诊断原因）" {
  let spec = @config.ActionSpec::new_webhook(
    "http://127.0.0.1:9/hook",
    Some("POST"),
    None,
    Some("x"),
    1000,
  )
  let o = @action.run_webhook_action(spec, mk_ev_whn("/tmp/a.txt"), ".", "w")
  assert_true(!o.ok)
  assert_eq(o.exit_code, -1)
  assert_true(o.stderr.contains("webhook"))
  assert_true(o.stderr.contains("目标"))
}

///|
test "webhook native: run_action 的 webhook 分支返回 Err（诚实降级）" {
  let spec = @config.ActionSpec::new_webhook(
    "http://127.0.0.1:9/hook",
    Some("GET"),
    None,
    None,
    1000,
  )
  let policy = @action.build_policy([])
  let logging : @config.LoggingConfig =
    { enabled: false, log_dir: "", log_file: "mcp-watcher.log", }
  match @action.run_action(spec, mk_ev_whn("/tmp/a.txt"), policy, logging, ".") {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("webhook"))
  }
}
