// ============================================================================
// mcp_stdio_js_test —— EP-01c mcp_tool_call · js 目标 stdio 真实 e2e
//
// 仅 js 目标（moon.pkg 门控到 "js"）：内联 mock MCP stdio server（协议一致：
// initialize → notifications/initialized → tools/call），对拍：
//   - publish e2e：tools/call 真实往返，args 的 §7 占位符渲染进真实调用
//     （quartermaster 语义：server 记录收到的 name/arguments，对拍即验收）
//   - 回执超时：server 挂起 → 可诊断 Err（ok=false，exit_code=-1）
//   - 协议错误：server 回 JSON-RPC error → 可诊断 Err（含 error.message）
//
// ⚠️ 诚实标注：本环境无 fist-mbt 可运行 MCP server（实测：本地 fist-mbt/ 与
//    RX-MBT 0.4.5 均仅文档）。本 e2e 用**协议一致的本地 stdio mock** 证明
//    transport 正确；真实 fist-mbt 对拍需目标环境提供 server
//    （server/server_args 可配，见 temp/ep01-design-notes.md §4a）。
//
// ⚠️ mock server 以 temp/mcp_mock_server.mjs 物化（ESM import 语法，
//    node -e 的 CJS 作用域无法 import）；文件读写走 js-only extern（@mon fs
//    在 js 目标的可用性不作假设）。
// ============================================================================

#cfg(target="js")
extern "js" fn ffi_mcp_write_file(path : String, content : String) -> String =
  #| (p, c) => { try { process.getBuiltinModule("node:fs").writeFileSync(p, String(c), "utf8"); return "ok"; } catch (e) { return String((e && e.message) || e); } }

#cfg(target="js")
extern "js" fn ffi_mcp_read_file(path : String) -> String =
  #| (p) => { try { return String(process.getBuiltinModule("node:fs").readFileSync(p, "utf8")); } catch (e) { return ""; } }

// mock MCP stdio server（ESM）：
//   mode=echo  → tools/call 回 result，并把收到的 name/arguments 记入 rec 文件
//   mode=hang  → tools/call 不回复（2s 后自杀，防止残留）
//   mode=err   → tools/call 回 JSON-RPC error
#cfg(target="js")
fn mcp_mock_script() -> String {
  "import { readFileSync, writeFileSync } from 'node:fs';\n" +
    "const [mode, rec] = process.argv.slice(2);\n" +
    "let buf = '';\n" +
    "process.stdin.on('data', (d) => {\n" +
    "  buf += d.toString('utf8');\n" +
    "  let i;\n" +
    "  while ((i = buf.indexOf('\\n')) >= 0) {\n" +
    "    const line = buf.slice(0, i).trim();\n" +
    "    buf = buf.slice(i + 1);\n" +
    "    if (!line) continue;\n" +
    "    let m;\n" +
    "    try { m = JSON.parse(line); } catch (e) { continue; }\n" +
    "    const send = (o) => process.stdout.write(JSON.stringify(o) + '\\n');\n" +
    "    if (m.method === 'initialize') {\n" +
    "      send({ jsonrpc: '2.0', id: m.id, result: { protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'mock-quartermaster', version: '1.0.0' } } });\n" +
    "    } else if (m.method === 'notifications/initialized') {\n" +
    "    } else if (m.method === 'tools/call') {\n" +
    "      if (mode === 'err') {\n" +
    "        send({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'tool not found: ' + m.params.name } });\n" +
    "      } else if (mode === 'hang') {\n" +
    "        setTimeout(() => process.exit(0), 2000);\n" +
    "      } else {\n" +
    "        if (rec) writeFileSync(rec, JSON.stringify({ name: m.params.name, arguments: m.params.arguments }));\n" +
    "        send({ jsonrpc: '2.0', id: m.id, result: { content: [{ type: 'text', text: 'published: ' + JSON.stringify(m.params.arguments) }], isError: false } });\n" +
    "      }\n" +
    "    }\n" +
    "  }\n" +
    "});\n" +
    "process.stdin.on('end', () => { if (mode !== 'hang') { process.exit(0); } });\n" +
    "setTimeout(() => process.exit(0), 8000);\n"
}

// ⚠️ 测试不持有 stdio 桥副本：e2e 直接调产品 @action.run_mcp_action
// （桥在 action/mcp_stdio.mbt，单一实现）。
///|
#cfg(target="js")
fn mcp_write_mock(script_path : String) -> (Bool, String) {
  let script = mcp_mock_script()
  match ffi_mcp_write_file(script_path, script) {
    "ok" => (true, script_path)
    e => (false, e)
  }
}

///|
fn mk_ev_mcp(path : String) -> @watch.FsEvent {
  @watch.FsEvent::new(@config.EventType::Create, path, false, 1700000000, 2048)
}

///|
#cfg(target="js")
test "mcp js e2e: publish 经 stdio 往返，args 占位符渲染进真实调用" {
  let (ok, script_path) = mcp_write_mock("temp/mcp_mock_server.mjs")
  assert_true(ok)
  // 清理上一轮记录文件（避免对拍到陈旧数据）
  let _ = ffi_mcp_write_file("temp/.mcp_rec.json", "")
  let spec = @config.ActionSpec::new_mcp(
    "node",
    "publish",
    Some("{\"path\":\"{file.path}\",\"watch\":\"{watch_id}\"}"),
    Some([script_path, "echo", "temp/.mcp_rec.json"]),
    15000,
  )
  let o = @action.run_mcp_action(
    spec,
    mk_ev_mcp("/data/sub/report.txt"),
    @action.build_policy(["node"]),
    "/data",
    "wid-9",
  )
  assert_true(o.ok)
  assert_eq(o.exit_code, 0)
  assert_true(o.stdout.contains("published:"))
  // 对拍 server 实际收到的工具名与渲染后参数（quartermaster 语义验收）
  let rec = ffi_mcp_read_file("temp/.mcp_rec.json")
  let j = @json.parse(rec) catch {
    _ => @json.Json::string("")
  }
  match j {
    { "name": String(nm), "arguments": Object(am), .. } => {
      assert_eq(nm, "publish")
      match am.get("path") {
        Some(@json.Json::String(p)) => assert_eq(p, "/data/sub/report.txt")
        _ => assert_true(false)
      }
      match am.get("watch") {
        Some(@json.Json::String(w)) => assert_eq(w, "wid-9")
        _ => assert_true(false)
      }
    }
    _ => assert_true(false)
  }
}

///|
#cfg(target="js")
test "mcp js e2e: server 挂起 → 回执超时可诊断 Err" {
  let (ok, script_path) = mcp_write_mock("temp/mcp_mock_server.mjs")
  assert_true(ok)
  let spec = @config.ActionSpec::new_mcp(
    "node",
    "publish",
    None,
    Some([script_path, "hang"]),
    1500,
  )
  let o = @action.run_mcp_action(
    spec,
    mk_ev_mcp("/tmp/a.txt"),
    @action.build_policy(["node"]),
    ".",
    "w",
  )
  assert_true(!o.ok)
  assert_eq(o.exit_code, -1)
  assert_true(o.stderr.contains("timeout"))
}

///|
#cfg(target="js")
test "mcp js e2e: server 回协议 error → 可诊断 Err（含 message）" {
  let (ok, script_path) = mcp_write_mock("temp/mcp_mock_server.mjs")
  assert_true(ok)
  let spec = @config.ActionSpec::new_mcp(
    "node",
    "publish",
    None,
    Some([script_path, "err"]),
    8000,
  )
  let o = @action.run_mcp_action(
    spec,
    mk_ev_mcp("/tmp/a.txt"),
    @action.build_policy(["node"]),
    ".",
    "w",
  )
  assert_true(!o.ok)
  assert_eq(o.exit_code, -1)
  assert_true(o.stderr.contains("tool not found: publish"))
}

///|
#cfg(target="js")
test "mcp js e2e: run_action 分支接线（白名单拒绝 + 成功两路）" {
  let (ok, script_path) = mcp_write_mock("temp/mcp_mock_server.mjs")
  assert_true(ok)
  let _ = ffi_mcp_write_file("temp/.mcp_rec2.json", "")
  let spec = @config.ActionSpec::new_mcp(
    "node",
    "publish",
    None,
    Some([script_path, "echo", "temp/.mcp_rec2.json"]),
    15000,
  )
  let logging : @config.LoggingConfig =
    { enabled: false, log_dir: "", log_file: "mcp-watcher.log", }
  // 白名单空 → 策略拒绝（可诊断）
  match @action.run_action(
    spec,
    mk_ev_mcp("/tmp/a.txt"),
    @action.build_policy([]),
    logging,
    ".",
    watch_id="w",
  ) {
    Err(e) => assert_true(e.contains("策略拒绝"))
    Ok(_) => assert_true(false)
  }
  // 白名单含 node → 成功
  match @action.run_action(
    spec,
    mk_ev_mcp("/tmp/a.txt"),
    @action.build_policy(["node"]),
    logging,
    ".",
    watch_id="w",
  ) {
    Ok(o) => assert_true(o.ok)
    Err(e) => assert_true(false)
  }
}
