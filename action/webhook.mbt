// ============================================================================
// action/webhook.mbt —— EP-01b · webhook 动作（HTTP 通知）
//
// schema §5：url（必）/ method（GET|POST，默认 POST）/ headers / body（§7 占位符）
//            / timeout_ms（缺省 5000）。
//
// 目标策略（诚实降级，与 trash 同款）：
//   - js：真实 HTTP（node:http/https；经 execFileSync 子进程桥获得同步语义）
//   - wasm/native：无 node:http → run_webhook_action 返回可诊断 Err（不伪装成功）
//
// 退避（纯函数、可单测）：webhook_backoff_delay_ms —— 确定性、有界（8000ms 封顶）、
//   无 I/O。v1 默认单发、不自动重试（红线：无重试循环；重试留给上层，如 fist-mbt saga）。
// ============================================================================

///|
/// webhook 缺省 HTTP 方法（schema 缺省语义）
const DEFAULT_WEBHOOK_METHOD = "POST"

///|
/// 退避调度常量：基数 500ms、封顶 8000ms、attempt 归一上限 6
const WEBHOOK_BACKOFF_BASE_MS = 500
const WEBHOOK_BACKOFF_CAP_MS = 8000
const WEBHOOK_BACKOFF_MAX_ATTEMPT = 6

///|
/// HTTP 成功状态码区间 [200, 300)（2xx 判定，RFC 9110 语义）
const HTTP_STATUS_OK_MIN = 200
const HTTP_STATUS_OK_EXCLUSIVE_MAX = 300

///|
/// 构造 HTTP 桥请求 JSON（字段顺序与键名与 ffi 桥契约逐位一致）
pub fn webhook_request_json(
  url : String,
  http_method : String,
  headers_json : String?,
  body : String?,
  timeout_ms : Int32,
) -> String {
  let headers = match headers_json {
    Some(h) if h != "" => h
    _ => "{}"
  }
  let b = match body {
    Some(x) => x
    None => ""
  }
  "{\"method\":\"" +
    escape_json_string(http_method) +
    "\",\"url\":\"" +
    escape_json_string(url) +
    "\",\"headers\":" +
    headers +
    ",\"body\":\"" +
    escape_json_string(b) +
    "\",\"timeout\":" +
    timeout_ms.to_string() +
    "}"
}

///|
/// 失败退避调度（纯函数：确定性、有界、无 I/O）
///
/// 指数退避：base 500ms × 2^attempt，封顶 8000ms；负 attempt 归一到首档。
/// 本函数**只计算调度**，不真正 sleep/重试（红线：无重试循环；是否应用由上层决定）。
pub fn webhook_backoff_delay_ms(attempt : Int32) -> Int32 {
  let base = WEBHOOK_BACKOFF_BASE_MS
  let cap = WEBHOOK_BACKOFF_CAP_MS
  let n = if attempt > WEBHOOK_BACKOFF_MAX_ATTEMPT {
    WEBHOOK_BACKOFF_MAX_ATTEMPT
  } else {
    if attempt < 0 { 0 } else { attempt }
  }
  let mut d = base
  let mut i = 0
  while i < n {
    d = d * 2
    i = i + 1
  }
  if d > cap { cap } else { d }
}

///|
/// js：经子进程桥同步发 HTTP（node:http/https；execFileSync 阻塞至完成）
#cfg(target="js")
extern "js" fn ffi_wh_http(req_json : String, timeout_ms : Int32) -> String =
  #| (reqJson, timeout) => { const cp = process.getBuiltinModule("node:child_process"); const script='const fs=process.getBuiltinModule("node:fs");const req=JSON.parse(fs.readFileSync(0,"utf8"));const finish=(o)=>{process.stdout.write(JSON.stringify(o));};const lib=process.getBuiltinModule(String(req.url).startsWith("https:")?"node:https":"node:http");try{const r=lib.request(req.url,{method:req.method,headers:req.headers||{},timeout:req.timeout||3000},(res)=>{const chunks=[];res.on("data",(c)=>chunks.push(c));res.on("end",()=>finish({ok:true,status:res.statusCode,body:Buffer.concat(chunks).toString("utf8")}));});r.on("timeout",()=>{try{r.destroy();}catch(_e){}finish({ok:false,error:"http timeout"});});r.on("error",(e)=>finish({ok:false,error:String((e&&e.message)||e)}));if(req.body){r.write(Buffer.from(String(req.body),"utf8"));}r.end();}catch(e){finish({ok:false,error:String((e&&e.message)||e)});}'; try { const out = cp.execFileSync(process.execPath, ["-e", script], { input: String(reqJson), encoding: "utf8", timeout: Number(timeout) + 5000, stdio: ["pipe", "pipe", "pipe"] }); return String(out); } catch (e) { const out = (e && e.stdout) ? String(e.stdout) : ""; if (out) { return out; } return JSON.stringify({ ok: false, error: String((e && e.message) || e) }); } }

///|
/// 非 js：无 node:http（返回空串；调用方据 wh_http_available 提前诚实降级）
#cfg(not(target="js"))
fn ffi_wh_http(req_json : String, timeout_ms : Int32) -> String {
  let _ = (req_json, timeout_ms)
  ""
}

///|
/// 当前目标是否具备 HTTP 能力（js=true；wasm/native=false）
#cfg(target="js")
fn wh_http_available() -> Bool {
  true
}

///|
#cfg(not(target="js"))
fn wh_http_available() -> Bool {
  false
}

///|
/// 执行 webhook 动作（同步；返回 ActionOutcome）
///
///   - url / body 均按 schema §7 占位符展开（解析失败 → 空串 + warning，不中断）
///   - js：真实请求；2xx→ok，非 2xx / 传输失败→ok=false（保留状态码/错误）
///   - wasm/native：诚实降级（ok=false + 可诊断原因，不伪装成功）
///
/// exit_code 语义：HTTP 状态码（2xx/非 2xx）；传输失败/降级为 -1。
pub fn run_webhook_action(
  spec : @config.ActionSpec,
  ev : @watch.FsEvent,
  watch_dir : String,
  watch_id : String,
) -> ActionOutcome {
  let url_raw = match spec.url {
    Some(u) => u
    None =>
      return ActionOutcome::new(
        "webhook", false, -1, "", "webhook 动作缺少必填字段 url",
      )
  }
  let mth = match spec.http_method {
    Some(m) if m != "" => m
    _ => DEFAULT_WEBHOOK_METHOD
  }
  let body_raw = match spec.body {
    Some(b) => b
    None => ""
  }
  let timeout_ms = if spec.timeout_ms > 0 {
    spec.timeout_ms
  } else {
    @config.DEFAULT_ACTION_TIMEOUT_MS
  }
  // §7 占位符展开（url + body）
  let (url, warns_u) = render_placeholders(url_raw, ev, watch_dir, watch_id)
  let (body, warns_b) = render_placeholders(body_raw, ev, watch_dir, watch_id)
  for w in warns_u {
    println("[warn] " + w)
  }
  for w in warns_b {
    println("[warn] " + w)
  }
  // 诚实降级：非 js 目标无 HTTP 能力
  if !wh_http_available() {
    return ActionOutcome::new(
      "webhook",
      false,
      -1,
      "",
      "webhook HTTP 当前目标不可用（wasm/native 无 node:http）：已诚实降级，不伪装成功",
    )
  }
  let req_json = webhook_request_json(
    url, mth, spec.headers_json, Some(body), timeout_ms,
  )
  let out = ffi_wh_http(req_json, timeout_ms)
  let j = @json.parse(out) catch {
    _ =>
      return ActionOutcome::new(
        "webhook", false, -1, "", "webhook 响应解析失败: " + out,
      )
  }
  match j {
    { "ok": True, "status": Number(st, ..), "body": String(b), .. } => {
      let status = st.to_int()
      let ok = status >= HTTP_STATUS_OK_MIN && status < HTTP_STATUS_OK_EXCLUSIVE_MAX
      if ok {
        ActionOutcome::new("webhook", true, status, b, "")
      } else {
        ActionOutcome::new(
          "webhook", false, status, "", "webhook 非 2xx 响应: " + b,
        )
      }
    }
    { "ok": False, "error": String(e), .. } =>
      ActionOutcome::new(
        "webhook", false, -1, "", "webhook 请求失败: " + e,
      )
    _ =>
      ActionOutcome::new(
        "webhook", false, -1, "", "webhook 响应结构意外: " + out,
      )
  }
}
