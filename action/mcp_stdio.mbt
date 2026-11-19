// ============================================================================
// action/mcp_stdio.mbt —— EP-01c · mcp_tool_call 动作（stdio transport）
//
// schema §5：server（必，进 allowed_programs 白名单）/ tool（必，复用 target）
//            / args（object，§7 占位符替换）/ server_args（server 命令行参数）/
//            transport（stdio|sse|http，v1.0 仅实现 stdio）/ timeout_ms。
//
// stdio 流程（js 目标真实实现；非 js 诚实降级）：
//   spawn [server, ...server_args]（argv 数组，**不经 shell**）→
//   JSON-RPC：initialize(id=1) → 等回执 → notifications/initialized →
//   tools/call(id=2) → 等回执（stdout 按 id 匹配，容忍 server 日志混杂）→
//   kill server 进程。
//
// 帧构造单一事实源：mcp_call_request（纯函数，全目标可单测）；桥只负责
// 收发与超时。
//
// 桥实现（Windows 实测修正，Rule of Three 后架构修正）：Node 专用同步 API
//   **spawnSync 单层直连**（host 进程内 spawn server；all-at-once 写帧，
//   server 按行顺序处理）；spawnSync timeout 为单一超时源（无双超时陷阱）。
//   已废弃：execFileSync 内嵌 node -e + 异步 spawn 孙进程——Windows 双层
//   嵌套 node 子进程触发 libuv UV_HANDLE_CLOSING 断言（standalone 10/10 过、
//   moon test 必崩；kill/unref/exit 调参 3 次均败，详见 temp 设计笔记 §4b）。
// ============================================================================

///|
/// 构造 JSON-RPC 请求帧（纯函数；产品 stdio 桥复用，单一事实源）
///
///   - method="initialize" 且 params 缺省 → 内置标准 initialize 参数
///   - method="tools/call" 且 params 缺省 → None（必须携带 name/arguments）
///   - params 必须是合法 JSON object（fail-closed，不发坏帧）
///
/// 返回 (request id, 帧文本)
pub fn mcp_call_request(
  request_id : Int32,
  method_name : String,
  params_json : String?,
) -> (Int32, String)? {
  let default_init =
    "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{}," +
    "\"clientInfo\":{\"name\":\"mcp-watcher\",\"version\":\"0.1.0\"}}"
  let params = match (method_name, params_json) {
    ("initialize", None) => default_init
    (_, Some(p)) => p
    _ =>
      if method_name == "tools/call" {
        return None
      } else {
        "{}"
      }
  }
  let j = @json.parse(params) catch {
    _ => return None
  }
  match j {
    Object(_m) =>
      Some((
        request_id,
        "{\"jsonrpc\":\"2.0\",\"id\":" +
          request_id.to_string() +
          ",\"method\":\"" +
          escape_json_string(method_name) +
          "\",\"params\":" +
          params +
          "}",
      ))
    _ => None
  }
}

///|
/// 判断一行 stdout 是否为指定 id 的 JSON-RPC 回执（纯函数）
///
/// server 日志混杂时按 id 精确匹配；notification（无 id）永不匹配。
pub fn mcp_response_matches(line : String, request_id : Int32) -> Bool {
  let j = @json.parse(line) catch {
    _ => return false
  }
  match j {
    { "id": Number(id, ..), .. } => id.to_int() == request_id
    _ => false
  }
}

///|
/// 从匹配的回执提取结果（纯函数）
///
///   - result 存在 → 对象 stringify / 字符串原样
///   - error 存在  → error.message
///   - 匹配但两者皆无 → Some("")（哨兵：成功但空结果）
///   - 非 JSON / id 不匹配 → None
pub fn mcp_parse_response(line : String, request_id~ : Int32 = 1) -> String? {
  let j = @json.parse(line) catch {
    _ => return None
  }
  match j {
    { "id": Number(id, ..), .. } if id.to_int() == request_id =>
      match j {
        { "error": { "message": String(msg), .. }, .. } => Some(msg)
        { "result": String(s), .. } => Some(s)
        { "result": r, .. } => Some(@json.Json::stringify(r))
        _ => Some("")
      }
    _ => None
  }
}

///|
/// js：stdio 桥（spawnSync 单层同步：host 进程内直 spawn MCP server）
///
/// 入参 req_json：{"argv":[...],"initialize":"帧","initialized":"帧","call":"帧"}
/// 出参：{"ok":true,"result":"..."} / {"ok":false,"error":"..."}
#cfg(target="js")
extern "js" fn ffi_mcp_stdin_stdout(req_json : String, timeout_ms : Int32) -> String =
  #| (reqJson, timeout) => { const cp = process.getBuiltinModule("node:child_process"); const req = JSON.parse(String(reqJson)); const argv = Array.isArray(req.argv) ? req.argv.map(String) : []; if (!argv.length) { return JSON.stringify({ ok: false, error: "mcp argv empty" }); } const stdin = String(req.initialize) + "\n" + String(req.initialized) + "\n" + String(req.call) + "\n"; let res; try { res = cp.spawnSync(argv[0], argv.slice(1), { input: stdin, timeout: Number(timeout), encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }); } catch (e) { return JSON.stringify({ ok: false, error: "mcp spawn 失败: " + String((e && e.message) || e) }); } const out = String(res.stdout || ""); let initResp = null, callResp = null; for (const line of out.split("\n")) { const t = line.trim(); if (!t) continue; let m; try { m = JSON.parse(t); } catch (e) { continue; } if (m && m.id === 1) { initResp = m; } else if (m && m.id === 2) { callResp = m; } } if (callResp) { if (callResp.error) { return JSON.stringify({ ok: false, error: "mcp 协议错误: " + (callResp.error.message || "unknown") }); } return JSON.stringify({ ok: true, result: callResp.result === undefined ? "" : JSON.stringify(callResp.result) }); } if (initResp && initResp.error) { return JSON.stringify({ ok: false, error: "mcp initialize 错误: " + (initResp.error.message || "unknown") }); } if (res.error) { return JSON.stringify({ ok: false, error: "mcp timeout: " + String((res.error && res.error.message) || res.error) }); } return JSON.stringify({ ok: false, error: "mcp 无回执（超时或 server 未响应）" }); }

///|
/// 非 js：无 node:child_process 同步 stdio 原语（返回空串，调用方诚实降级）
#cfg(not(target="js"))
fn ffi_mcp_stdin_stdout(req_json : String, timeout_ms : Int32) -> String {
  let _ = (req_json, timeout_ms)
  ""
}

///|
#cfg(target="js")
fn mcp_stdio_available() -> Bool {
  true
}

///|
#cfg(not(target="js"))
fn mcp_stdio_available() -> Bool {
  false
}

///|
/// 执行 mcp_tool_call 动作（同步；返回 ActionOutcome）
///
///   - transport：v1.0 仅 stdio（sse/http 可诊断 Err，诚实标注）
///   - 白名单：server 程序进 allowed_programs（ExecPolicy::allows，与
///     command 同一套 wildcard_match 语义；拒绝 → 「策略拒绝:」可诊断错误）
///   - args JSON 与 server_args 均按 §7 占位符展开；**不经 shell**（argv 直传）
///   - 非 js 目标：诚实降级（不伪装成功）
///
/// exit_code 语义：0=工具调用成功；-1=失败（协议错误/超时/降级/白名单拒绝）。
pub fn run_mcp_action(
  spec : @config.ActionSpec,
  ev : @watch.FsEvent,
  policy : @rt.ExecPolicy,
  watch_dir : String,
  watch_id : String,
) -> ActionOutcome {
  // 1) transport：v1.0 仅实现 stdio
  let transport = match spec.transport {
    Some(t) if t != "" => t
    _ => "stdio"
  }
  if transport != "stdio" {
    return ActionOutcome::new(
      "mcp_tool_call",
      false,
      -1,
      "",
      "mcp_tool_call transport=" +
        transport +
        " 未实现（v1.0 仅实现 stdio；sse/http 待后续 EP）",
    )
  }
  // 2) 诚实降级：非 js 目标无同步 stdio spawn 原语
  if !mcp_stdio_available() {
    return ActionOutcome::new(
      "mcp_tool_call",
      false,
      -1,
      "",
      "mcp_tool_call stdio 传输当前目标不可用（wasm/native 无同步 stdio spawn 原语）：已诚实降级，不伪装成功",
    )
  }
  // 3) 必填字段
  let prog = match spec.server {
    Some(s) if s != "" => s
    _ =>
      return ActionOutcome::new(
        "mcp_tool_call", false, -1, "", "mcp_tool_call 动作缺少必填字段 server",
      )
  }
  let tool = match spec.target {
    Some(t) if t != "" => t
    _ =>
      return ActionOutcome::new(
        "mcp_tool_call", false, -1, "", "mcp_tool_call 动作缺少必填字段 tool",
      )
  }
  // 4) 白名单（与 command 执行同一门；单一事实源 ExecPolicy）
  if !policy.allows("cli:" + prog) {
    return ActionOutcome::new(
      "mcp_tool_call",
      false,
      -1,
      "",
      "策略拒绝: 程序 '" + prog + "' 不在 allowed_programs 白名单中",
    )
  }
  // 5) §7 占位符展开：args JSON + server_args（渲染后 args 必须仍是合法 JSON object）
  let args_raw = match spec.mcp_args_json {
    Some(a) => a
    None => "{}"
  }
  let (args_rendered, warns_a) = render_placeholders(args_raw, ev, watch_dir, watch_id)
  for w in warns_a {
    println("[warn] " + w)
  }
  let args_j = @json.parse(args_rendered) catch {
    _ =>
      return ActionOutcome::new(
        "mcp_tool_call",
        false,
        -1,
        "",
        "mcp args 占位符展开后不是合法 JSON object: " + args_rendered,
      )
  }
  match args_j {
    Object(_m) => ()
    _ =>
      return ActionOutcome::new(
        "mcp_tool_call",
        false,
        -1,
        "",
        "mcp args 占位符展开后不是合法 JSON object: " + args_rendered,
      )
  }
  let argv : Array[String] = []
  argv.push(prog)
  let sa_raw : Array[String] = match spec.server_args {
    Some(a) => a
    None => []
  }
  for sa in sa_raw {
    let (r, warns) = render_placeholders(sa, ev, watch_dir, watch_id)
    for w in warns {
      println("[warn] " + w)
    }
    argv.push(r)
  }
  // 6) JSON-RPC 帧（单一事实源 mcp_call_request）
  let (_rid1, init_frame) = match mcp_call_request(1, "initialize", None) {
    Some(t) => t
    None =>
      return ActionOutcome::new(
        "mcp_tool_call", false, -1, "", "mcp initialize 帧构造失败（内部错误）",
      )
  }
  let notif_frame = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
  let params =
    "{\"name\":\"" +
    escape_json_string(tool) +
    "\",\"arguments\":" +
    args_rendered +
    "}"
  let (_rid2, call_frame) = match mcp_call_request(2, "tools/call", Some(params)) {
    Some(t) => t
    None =>
      return ActionOutcome::new(
        "mcp_tool_call", false, -1, "", "mcp tools/call 帧构造失败（args 非法）",
      )
  }
  // 7) stdio 桥请求 JSON
  let timeout_ms = if spec.timeout_ms > 0 {
    spec.timeout_ms
  } else {
    5000
  }
  let argv_json = @json.Json::stringify(
    @json.Json::array(argv.map(fn(a) { @json.Json::string(a) })),
  )
  let req_json =
    "{\"argv\":" +
    argv_json +
    ",\"initialize\":\"" +
    escape_json_string(init_frame) +
    "\",\"initialized\":\"" +
    escape_json_string(notif_frame) +
    "\",\"call\":\"" +
    escape_json_string(call_frame) +
    "\",\"timeout\":" +
    timeout_ms.to_string() +
    "}"
  let out = ffi_mcp_stdin_stdout(req_json, timeout_ms)
  let j = @json.parse(out) catch {
    _ =>
      return ActionOutcome::new(
        "mcp_tool_call", false, -1, "", "mcp 桥响应解析失败: " + out,
      )
  }
  match j {
    { "ok": True, "result": String(r), .. } =>
      ActionOutcome::new("mcp_tool_call", true, 0, r, "")
    { "ok": False, "error": String(e), .. } =>
      ActionOutcome::new(
        "mcp_tool_call", false, -1, "", "mcp 工具调用失败: " + e,
      )
    _ =>
      ActionOutcome::new(
        "mcp_tool_call", false, -1, "", "mcp 桥响应结构意外: " + out,
      )
  }
}
