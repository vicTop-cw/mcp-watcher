// ============================================================================
// webhook_test —— EP-01b webhook 动作（纯函数 + loader 解析，全目标）
//
// 覆盖（TDD 红相先写）：
//   - webhook_request_json（HTTP 桥请求 JSON 构造：method/url/headers/body/timeout）
//   - webhook_backoff_delay_ms（失败退避调度：确定性、有界、无 I/O）
//   - loader parse_action 的 webhook 字段（url 必填 / method 枚举 / headers / timeout）
//   - v1.0 向后兼容锁（command 动作不携带新字段；缺省值保持 v1.0 行为）
//
// 诚实降级（非 js 目标 run_webhook_action 返回可诊断 Err）见 webhook_native_test.mbt；
// js 目标真实 HTTP（本地 server e2e）见 webhook_js_test.mbt。
// ============================================================================

///|
test "webhook_request_json: 构造与 HTTP 桥契约一致" {
  let j = @action.webhook_request_json(
    "http://127.0.0.1:8090/hook",
    "POST",
    Some("{\"Content-Type\":\"application/json\"}"),
    Some("hi"),
    3000,
  )
  // 字段顺序与键名必须与 action/webhook.mbt 的 ffi 桥期望逐位一致
  assert_eq(
    j,
    "{\"method\":\"POST\",\"url\":\"http://127.0.0.1:8090/hook\"," +
      "\"headers\":{\"Content-Type\":\"application/json\"}," +
      "\"body\":\"hi\",\"timeout\":3000}",
  )
}

///|
test "webhook_request_json: headers 缺省回退 {}，body 缺省空串" {
  let j = @action.webhook_request_json("http://x/y", "GET", None, None, 5000)
  assert_eq(
    j,
    "{\"method\":\"GET\",\"url\":\"http://x/y\",\"headers\":{},\"body\":\"\",\"timeout\":5000}",
  )
}

///|
test "webhook_request_json: url 含引号/反斜杠时 JSON 转义" {
  let j = @action.webhook_request_json(
    "http://x/?a=\"b\"\\c",
    "POST",
    None,
    Some("x\"y"),
    1,
  )
  assert_true(j.contains("\\\"b\\\""))
  assert_true(j.contains("x\\\"y"))
}

///|
test "webhook_backoff_delay_ms: 指数退避确定性且有界（8000 封顶）" {
  assert_eq(@action.webhook_backoff_delay_ms(0), 500)
  assert_eq(@action.webhook_backoff_delay_ms(1), 1000)
  assert_eq(@action.webhook_backoff_delay_ms(2), 2000)
  assert_eq(@action.webhook_backoff_delay_ms(3), 4000)
  assert_eq(@action.webhook_backoff_delay_ms(4), 8000)
  // 封顶：更大 attempt 不再增长（有界，防忙等/无界退避）
  assert_eq(@action.webhook_backoff_delay_ms(5), 8000)
  assert_eq(@action.webhook_backoff_delay_ms(100), 8000)
  // 负 attempt 归一到首档
  assert_eq(@action.webhook_backoff_delay_ms(-3), 500)
}

// ---------------------------------------------------------------------------
// loader · webhook 动作解析（经公开入口 Config::from_json 集成测试）
// ---------------------------------------------------------------------------

///|
fn webhook_cfg_json(action_json : String) -> String {
  "{\"schema_version\":1,\"watch_id\":\"wh\",\"watch_dir\":\".\"," +
    "\"rules\":[{\"id\":\"r\",\"events\":[\"create\"],\"patterns\":[\"**/*\"]," +
    "\"actions\":[" + action_json + "]}]}"
}

///|
test "loader: 解析完整 webhook 动作（url/method/headers/timeout/body）" {
  let action =
    "{\"type\":\"webhook\",\"url\":\"http://x/hook\",\"method\":\"GET\"," +
    "\"headers\":{\"K\":\"V\"},\"body\":\"b {file.name}\",\"timeout_ms\":1234}"
  match @config.Config::from_json(webhook_cfg_json(action)) {
    Ok(cfg) => {
      let a = cfg.rules[0].actions[0]
      assert_eq(a.kind, "webhook")
      match a.url {
        Some("http://x/hook") => ()
        _ => assert_true(false)
      }
      match a.http_method {
        Some("GET") => ()
        _ => assert_true(false)
      }
      match a.headers_json {
        Some(h) => assert_true(h.contains("\"K\"") && h.contains("\"V\""))
        None => assert_true(false)
      }
      assert_eq(a.timeout_ms, 1234)
      match a.body {
        Some("b {file.name}") => ()
        _ => assert_true(false)
      }
    }
    Err(e) => assert_true(false)
  }
}

///|
test "loader: webhook 缺 url 报可诊断错误（fail-closed）" {
  let action = "{\"type\":\"webhook\",\"method\":\"POST\",\"body\":\"x\"}"
  match @config.Config::from_json(webhook_cfg_json(action)) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("url"))
  }
}

///|
test "loader: webhook 空 url 报可诊断错误" {
  let action = "{\"type\":\"webhook\",\"url\":\"\"}"
  match @config.Config::from_json(webhook_cfg_json(action)) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("url"))
  }
}

///|
test "loader: webhook 非法 method 报可诊断错误" {
  let action = "{\"type\":\"webhook\",\"url\":\"http://x\",\"method\":\"DELETE\"}"
  match @config.Config::from_json(webhook_cfg_json(action)) {
    Ok(_) => assert_true(false)
    Err(e) => assert_true(e.contains("method"))
  }
}

///|
test "loader: webhook method 缺省为 POST（schema §5 默认值）" {
  let action = "{\"type\":\"webhook\",\"url\":\"http://x\"}"
  match @config.Config::from_json(webhook_cfg_json(action)) {
    Ok(cfg) => {
      let a = cfg.rules[0].actions[0]
      match a.http_method {
        Some("POST") => ()
        _ => assert_true(false)
      }
      // timeout 缺省
      assert_eq(a.timeout_ms, 5000)
    }
    Err(_) => assert_true(false)
  }
}

///|
test "loader: v1.0 command 动作向后兼容（不携带 webhook/mcp 新字段）" {
  let json =
    "{\"schema_version\":1,\"watch_id\":\"c\",\"watch_dir\":\".\"," +
    "\"rules\":[{\"id\":\"r\",\"events\":[\"create\"],\"patterns\":[\"**/*\"]," +
    "\"actions\":[{\"type\":\"command\",\"cmd\":\"echo\",\"args\":[\"hi\"]}]}]}"
  match @config.Config::from_json(json) {
    Ok(cfg) => {
      let a = cfg.rules[0].actions[0]
      assert_eq(a.kind, "command")
      match a.url {
        None => ()
        Some(_) => assert_true(false)
      }
      match a.http_method {
        None => ()
        Some(_) => assert_true(false)
      }
      match a.headers_json {
        None => ()
        Some(_) => assert_true(false)
      }
      match a.server {
        None => ()
        Some(_) => assert_true(false)
      }
      match a.mcp_args_json {
        None => ()
        Some(_) => assert_true(false)
      }
      match a.transport {
        None => ()
        Some(_) => assert_true(false)
      }
    }
    Err(_) => assert_true(false)
  }
}
