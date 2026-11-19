// ============================================================================
// mcp_test —— EP-01c mcp_tool_call（纯函数 + loader 解析，全目标）
//
// 覆盖（TDD 红相先写）：
//   - mcp_call_request（JSON-RPC 请求帧：initialize / tools/call；args 原样内嵌）
//   - mcp_response_matches（按 id 匹配回执；notification 无 id 永不匹配）
//   - mcp_parse_response（result 提取 / error 提取 / 无 result 哨兵）
//   - program_whitelisted（allowed_programs 白名单判定，与 build_policy 同源）
//   - loader mcp_tool_call 字段（server/tool 必填、transport 枚举、server_args）
//
// js 目标 stdio e2e（本地 mock MCP server）见 mcp_stdio_js_test.mbt；
// 非 js 诚实降级见 mcp_native_test.mbt。
// ============================================================================

// ---------------------------------------------------------------------------
// JSON-RPC 请求帧
// ---------------------------------------------------------------------------

///|
test "mcp_call_request: initialize 帧结构" {
  let res = @action.mcp_call_request(1, "initialize", None)
  match res {
    None => assert_true(false)
    Some((req_id, frame)) => {
      assert_eq(req_id, 1)
      assert_true(frame.contains("\"jsonrpc\":\"2.0\""))
      assert_true(frame.contains("\"id\":1"))
      assert_true(frame.contains("\"method\":\"initialize\""))
      assert_true(frame.contains("\"clientInfo\""))
    }
  }
}

///|
test "mcp_call_request: tools/call 帧内嵌渲染后 args（原样 JSON 片段）" {
  let params =
    "{\"name\":\"publish\",\"arguments\":{\"path\":\"/d/a.txt\"}}"
  let res = @action.mcp_call_request(2, "tools/call", Some(params))
  match res {
    None => assert_true(false)
    Some((req_id, frame)) => {
      assert_eq(req_id, 2)
      assert_true(frame.contains("\"method\":\"tools/call\""))
      assert_true(frame.contains("\"name\":\"publish\""))
      assert_true(frame.contains("{\"path\":\"/d/a.txt\"}"))
    }
  }
}

///|
test "mcp_call_request: 非法 params JSON 返回 None（fail-closed）" {
  match @action.mcp_call_request(
    2,
    "tools/call",
    Some("{\"name\":\"publish\",\"arguments\":{broken}"),
  ) {
    None => ()
    Some(_) => assert_true(false)
  }
}

// ---------------------------------------------------------------------------
// 回执匹配与解析
// ---------------------------------------------------------------------------

///|
test "mcp_response_matches: 按 id 精确匹配" {
  let resp = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ok\":true}}"
  assert_true(@action.mcp_response_matches(resp, 2))
  assert_true(!@action.mcp_response_matches(resp, 1))
}

///|
test "mcp_response_matches: notification（无 id）永不匹配" {
  let notif = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
  assert_true(!@action.mcp_response_matches(notif, 1))
}

///|
test "mcp_response_matches: 非 JSON 行（server 日志混杂）返回 false" {
  assert_true(!@action.mcp_response_matches("random log line", 1))
  assert_true(!@action.mcp_response_matches("", 1))
}

///|
test "mcp_parse_response: result 对象提取" {
  let resp = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}"
  match @action.mcp_parse_response(resp, request_id=2) {
    Some(r) => assert_true(r.contains("done"))
    None => assert_true(false)
  }
}

///|
test "mcp_parse_response: result 字符串提取" {
  let resp = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":\"plain\"}"
  match @action.mcp_parse_response(resp, request_id=2) {
    Some(r) => assert_eq(r, "plain")
    None => assert_true(false)
  }
}

///|
test "mcp_parse_response: error 对象提取 message" {
  let resp =
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32601,\"message\":\"tool not found\"}}"
  match @action.mcp_parse_response(resp, request_id=2) {
    Some(r) => assert_true(r.contains("tool not found"))
    None => assert_true(false)
  }
}

///|
test "mcp_parse_response: 匹配但无 result/error 返回空串哨兵" {
  let resp = "{\"jsonrpc\":\"2.0\",\"id\":2}"
  match @action.mcp_parse_response(resp, request_id=2) {
    Some(r) => assert_eq(r, "")
    None => assert_true(false)
  }
}

///|
test "mcp_parse_response: 非 JSON / 不匹配 id 返回 None" {
  match @action.mcp_parse_response("not json") {
    None => ()
    Some(_) => assert_true(false)
  }
  match @action.mcp_parse_response("{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":\"x\"}") {
    None => ()
    Some(_) => assert_true(false)
  }
}

// ---------------------------------------------------------------------------
// 白名单：runtime 门 = ExecPolicy::allows("cli:<prog>")（与 command 同一套
// wildcard_match 语义，单一事实源）；行为覆盖在 mcp_stdio_js_test.mbt 的
// run_action 接线测试（空名单拒绝 + 含 node 成功）。
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// loader · mcp_tool_call 动作解析（经公开入口 Config::from_json 集成测试）
// ---------------------------------------------------------------------------

///|
fn mcp_cfg_json(action_json : String) -> String {
  "{\"schema_version\":1,\"watch_id\":\"mc\",\"watch_dir\":\".\"," +
    "\"rules\":[{\"id\":\"r\",\"events\":[\"create\"],\"patterns\":[\"**/*\"]," +
    "\"actions\":[" + action_json + "]}]}"
}

///|
test "loader: 解析完整 mcp_tool_call 动作" {
  let action =
    "{\"type\":\"mcp_tool_call\",\"server\":\"node\",\"tool\":\"publish\"," +
    "\"args\":{\"path\":\"{file.path}\"},\"server_args\":[\"srv.mjs\"]," +
    "\"transport\":\"stdio\",\"timeout_ms\":4321}"
  match @config.Config::from_json(mcp_cfg_json(action)) {
    Ok(cfg) => {
      let a = cfg.rules[0].actions[0]
      assert_eq(a.kind, "mcp_tool_call")
      match a.server {
        Some("node") => ()
        _ => assert_true(false)
      }
      match a.target {
        Some("publish") => ()
        _ => assert_true(false)
      }
      match a.mcp_args_json {
        Some(s) => assert_true(s.contains("{file.path}"))
        None => assert_true(false)
      }
      match a.server_args {
        Some(arr) if arr.length() == 1 && arr[0] == "srv.mjs" => ()
        _ => assert_true(false)
      }
      match a.transport {
        Some("stdio") => ()
        _ => assert_true(false)
      }
      assert_eq(a.timeout_ms, 4321)
    }
    Err(_e) => assert_true(false)
  }
}

///|
test "loader: mcp_tool_call 缺 server 报错（fail-closed）" {
  let action = "{\"type\":\"mcp_tool_call\",\"tool\":\"publish\"}"
  match @config.Config::from_json(mcp_cfg_json(action)) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("server"))
  }
}

///|
test "loader: mcp_tool_call 缺 tool 报错（fail-closed）" {
  let action = "{\"type\":\"mcp_tool_call\",\"server\":\"node\"}"
  match @config.Config::from_json(mcp_cfg_json(action)) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("tool"))
  }
}

///|
test "loader: mcp_tool_call 非法 transport 报错（fail-closed）" {
  let action =
    "{\"type\":\"mcp_tool_call\",\"server\":\"node\",\"tool\":\"t\",\"transport\":\"ws\"}"
  match @config.Config::from_json(mcp_cfg_json(action)) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("transport"))
  }
}

///|
test "loader: mcp_tool_call 缺省 transport=stdio、timeout=5000、server_args=[]" {
  let action = "{\"type\":\"mcp_tool_call\",\"server\":\"node\",\"tool\":\"t\"}"
  match @config.Config::from_json(mcp_cfg_json(action)) {
    Ok(cfg) => {
      let a = cfg.rules[0].actions[0]
      match a.transport {
        Some("stdio") => ()
        _ => assert_true(false)
      }
      assert_eq(a.timeout_ms, 5000)
      match a.server_args {
        Some(arr) if arr.length() == 0 => ()
        _ => assert_true(false)
      }
    }
    Err(_) => assert_true(false)
  }
}

///|
test "loader: mcp_tool_call server_args 非字符串元素报错（fail-closed）" {
  let action =
    "{\"type\":\"mcp_tool_call\",\"server\":\"node\",\"tool\":\"t\",\"server_args\":[1]}"
  match @config.Config::from_json(mcp_cfg_json(action)) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("server_args"))
  }
}

///|
test "loader: v1.0 command 动作 server_args 漏用报错（kind 隔离）" {
  // command 动作携带 mcp 专属字段 server_args → fail-closed（与 op/message 同策略）
  let action =
    "{\"type\":\"command\",\"cmd\":\"echo\",\"args\":[\"hi\"],\"server_args\":[\"x\"]}"
  match @config.Config::from_json(mcp_cfg_json(action)) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("server_args"))
  }
}
