// ============================================================================
// webhook_js_test —— EP-01b webhook · js 目标真实 HTTP（本地 server e2e）
//
// 仅 js 目标（moon.pkg 门控到 "js"）：extern "js" 本地 HTTP server 记录请求，
// run_webhook_action 真实发起请求并对拍 method/url/body/状态码。
// 覆盖：
//   - POST 成功（2xx）：ok=true，stdout=响应体，exit_code=HTTP 状态
//   - url/body 的 §7 占位符渲染反映到真实请求
//   - 连接被拒（未监听端口）→ 可诊断 Err（ok=false，exit_code=-1）
//
// ⚠️ 测试内的有限等待（轮询 port 文件，5s 截止）是**测试装置**的启动等待，
//    非产品重试循环（红线「无重试循环」约束的是产品路径）。
// ============================================================================

#cfg(target="js")
extern "js" fn ffi_wh_test_setup(
  port_file : String,
  log_file : String,
  resp_body : String,
) -> String =
  #| (portFile, logFile, respBody) => { const cp = process.getBuiltinModule("node:child_process"); const fs = process.getBuiltinModule("node:fs"); const script = 'const fs=require("node:fs"),http=require("node:http");const pf=process.argv[1],lf=process.argv[2],rb=process.argv[3];const srv=http.createServer((req,res)=>{const c=[];req.on("data",(d)=>c.push(d));req.on("end",()=>{const body=Buffer.concat(c).toString("utf8");fs.writeFileSync(lf,JSON.stringify({method:req.method,url:req.url,headers:req.headers,body:body}));res.writeHead(200,{"Content-Type":"text/plain"});res.end(rb);});});srv.listen(0,"127.0.0.1",()=>{fs.writeFileSync(pf,String(srv.address().port));});'; try { fs.unlinkSync(portFile); } catch (_e) {} try { fs.unlinkSync(logFile); } catch (_e) {} const child = cp.spawn(process.execPath, ["-e", script, portFile, logFile, respBody], { stdio: "ignore", detached: true, windowsHide: true }); try { child.unref(); } catch (_e) {} const start = Date.now(); while (Date.now() - start < 5000) { try { if (fs.existsSync(portFile)) { const p = fs.readFileSync(portFile, "utf8").trim(); if (p) { return JSON.stringify({ port: Number(p), pid: child.pid }); } } } catch (_e) {} const e2 = Date.now() + 15; while (Date.now() < e2) {} } return JSON.stringify({ ok: false, error: "timeout waiting for local server port" }); }

#cfg(target="js")
extern "js" fn ffi_wh_test_stop(pid : Int32) -> String =
  #| (pid) => { try { const cp = process.getBuiltinModule("node:child_process"); if (process.platform === "win32") { cp.execSync(`taskkill /F /T /PID ${Number(pid)}`, { stdio: "ignore" }); } else { process.kill(Number(pid), "SIGKILL"); } return "ok"; } catch (_e) { return String((_e && _e.message) || _e); } }

#cfg(target="js")
extern "js" fn ffi_wh_read_file(path : String) -> String =
  #| (p) => { try { return String(process.getBuiltinModule("node:fs").readFileSync(p, "utf8")); } catch (_e) { return ""; } }

///|
// ⚠️ assert_true 只能在 test 函数（签名带 error 类型）内调用（实测 4122），
// 故 helper 返回 (ok, port, pid)，断言留在测试体。
#cfg(target="js")
fn wh_setup(
  port_file : String,
  log_file : String,
  resp_body : String,
) -> (Bool, Int32, Int32) {
  let out = ffi_wh_test_setup(port_file, log_file, resp_body)
  let j = @json.parse(out) catch {
    _ => @json.Json::string("")
  }
  match j {
    { "port": Number(p, ..), "pid": Number(pid, ..) } =>
      (true, p.to_int(), pid.to_int())
    _ => (false, 0, 0)
  }
}

///|
fn mk_ev_wh(path : String) -> @watch.FsEvent {
  @watch.FsEvent::new(@config.EventType::Create, path, false, 1700000000, 2048)
}

///|
#cfg(target="js")
test "webhook js e2e: POST 本地 server 成功并回读响应体" {
  let port_file = "temp/.wh_port"
  let log_file = "temp/.wh_log.jsonl"
  let (ok, port, pid) = wh_setup(port_file, log_file, "pong")
  assert_true(ok)
  let url = "http://127.0.0.1:" + port.to_string() + "/hook"
  let spec = @config.ActionSpec::new_webhook(
    url,
    Some("POST"),
    Some("{\"Content-Type\":\"application/json\"}"),
    Some("{\"n\":\"1\"}"),
    3000,
  )
  let o = @action.run_webhook_action(spec, mk_ev_wh("/tmp/a.txt"), ".", "wid")
  assert_true(o.ok)
  assert_eq(o.exit_code, 200)
  assert_eq(o.stdout, "pong")
  // 对拍 server 实际收到的请求（单请求 → 单条 JSON）
  let text = ffi_wh_read_file(log_file)
  let j = @json.parse(text) catch {
    _ => @json.Json::string("")
  }
  match j {
    {
      "method": String(m),
      "url": String(u),
      "body": String(b),
      ..
    } => {
      assert_eq(m, "POST")
      assert_true(u.contains("/hook"))
      assert_eq(b, "{\"n\":\"1\"}")
    }
    _ => assert_true(false)
  }
  let _ = ffi_wh_test_stop(pid)
}

///|
#cfg(target="js")
test "webhook js e2e: url/body 的 §7 占位符渲染进真实请求" {
  let port_file = "temp/.wh_port2"
  let log_file = "temp/.wh_log2.jsonl"
  let (ok, port, pid) = wh_setup(port_file, log_file, "ok")
  assert_true(ok)
  let url = "http://127.0.0.1:" + port.to_string() + "/h/{file.name}"
  let spec = @config.ActionSpec::new_webhook(
    url,
    Some("POST"),
    None,
    Some("size={file.size} dir={file.dir} id={watch_id}"),
    3000,
  )
  let o = @action.run_webhook_action(
    spec,
    mk_ev_wh("/data/sub/report.txt"),
    "/data",
    "wid-9",
  )
  assert_true(o.ok)
  let text = ffi_wh_read_file(log_file)
  let j = @json.parse(text) catch {
    _ => @json.Json::string("")
  }
  match j {
    { "url": String(u), "body": String(b), .. } => {
      assert_eq(u, "/h/report.txt")
      assert_eq(b, "size=2048 dir=/data/sub id=wid-9")
    }
    _ => assert_true(false)
  }
  let _ = ffi_wh_test_stop(pid)
}

///|
#cfg(target="js")
test "webhook js e2e: 连接被拒 → 可诊断 Err（ok=false，exit_code=-1）" {
  // 端口 1 在 127.0.0.1 上无监听 → 连接被拒
  let url = "http://127.0.0.1:1/nope"
  let spec = @config.ActionSpec::new_webhook(url, Some("POST"), None, None, 1500)
  let o = @action.run_webhook_action(spec, mk_ev_wh("/tmp/a.txt"), ".", "w")
  assert_true(!o.ok)
  assert_eq(o.exit_code, -1)
  assert_true(o.stderr.length() > 0)
}
