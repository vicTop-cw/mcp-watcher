// ============================================================================
// action · 生命周期动作（扩展点 EP-01）
//
// 这是"产物生命周期语义"支柱的执行侧骨架：动作是有语义的（command / mcp_tool_call
// / webhook / internal），而非裸 shell。
//
// P0 实现期：
//   - `command` 分支接入 rx `run_command` + `ExecPolicy`（白名单、argv 不走 shell）；
//   - `mcp_tool_call` / `webhook` / `internal` 保留为待实现的扩展位，
//     返回**可诊断错误**而非静默成功。
//
// ⚠️ 安全模型（rx 侧设计，本项目沿用）：
//   `ExecPolicy::default()` 只放行 `action:*` / `handler:*`，
//   任意命令必须显式加入 `allow`（`cli:<prog>`）或设 `allow_any=true`。
//   ⇒ mcp-watcher 的默认配置**不会**因为一条规则而执行任意命令。
//   ⇒ 这正是"不是泛泛的跑命令"的制度化落点。
//
// ⚠️ MoonBit 语法约束（实测确认）：
//   rx 的泛型类型跨包引用必须带完整类型标注；
//   具名参数语法是 `label=value`（不是 `label~value`）。
// ============================================================================

///|
/// 动作扩展点：具体执行体
pub trait Action {
  fn run(self : Self, ev : @watch.FsEvent) -> Result[Unit, String]
}

///|
/// 动作执行结果（供遥测与测试断言）
#derive(Eq, Debug)
pub(all) struct ActionOutcome {
  /// 动作种类
  kind : String
  /// 是否成功（v1.0 语义：command 动作 exit_code == 0）
  ok : Bool
  /// 退出码（command 动作为 0；其他动作为 -1）
  exit_code : Int32
  /// 标准输出（command 动作）
  stdout : String
  /// 标准错误
  stderr : String
  /// 验收门判定（schema v1.1；无 acceptance 时等于 ok，v1.0 行为不变）
  accepted : Bool
  /// 验收失败原因（通过或无验收时为空）
  acceptance_reason : String
}

///|
pub extend ActionOutcome with Eq::{not_equal, equal}

///|
pub extend ActionOutcome with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 构造动作执行结果（v1.0 语义：accepted = ok）
pub fn ActionOutcome::new(
  kind : String,
  ok : Bool,
  exit_code : Int32,
  stdout : String,
  stderr : String,
) -> ActionOutcome {
  { kind, ok, exit_code, stdout, stderr, accepted: ok, acceptance_reason: "", }
}

///|
/// 构建 ExecPolicy：默认拒绝任意命令，只放行规则显式声明的程序
///
/// 参数：
///   allow_programs - 规则里显式允许的程序名（如 ["git", "node"]）
///
/// 语义：把程序名转成 rx 认可的 `cli:<prog>` 条目。
/// **空 allow_programs ⇒ 连一个命令都跑不了**（安全默认）。
pub fn build_policy(allow_programs : Array[String]) -> @rt.ExecPolicy {
  let allow : Array[String] = []
  for p in allow_programs {
    allow.push("cli:" + p)
  }
  @rt.ExecPolicy::new(allow, false, 60.0)
}

// ============================================================================
// 验收门（schema v1.1 · PLAN-gates.md §一：堵「假绿」）
// ============================================================================

///|
/// 验收判定结果
#derive(Eq, Debug)
pub(all) struct AcceptanceResult {
  /// 是否通过验收
  accepted : Bool
  /// 失败原因（通过时为空；多项失败累积，一次报全）
  reason : String
}

///|
pub extend AcceptanceResult with Eq::{not_equal, equal}

///|
pub extend AcceptanceResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 构造验收判定结果
pub fn AcceptanceResult::new(accepted : Bool, reason : String) -> AcceptanceResult {
  { accepted, reason, }
}

///|
/// 验收门纯函数判定（红线：纯函数——字符串包含 + 调用方注入的 artifact_hit）
///
/// 语义（与 PLAN-gates.md §一 语义表逐条对齐）：
///   - exit_code == expect_exit（缺省 0）
///   - stdout 包含 stdout_contains 每一项（AND）
///   - stdout 不含 stdout_not_contains 任何一项
///   - stderr 不含 stderr_not_contains 任何一项
///   - artifact_glob：调用方解析后注入 artifact_hit（None = 无该检查）
///
/// 多项失败一次报全（累积式，与 validate_config 同风格）；**不做自动重试**
/// （重试留给上层，如 fist-mbt saga）。
pub fn acceptance_check(
  acceptance : @config.AcceptanceSpec,
  exit_code : Int32,
  stdout : String,
  stderr : String,
  artifact_hit : Bool?,
) -> AcceptanceResult {
  let reasons : Array[String] = []
  if exit_code != acceptance.expect_exit {
    reasons.push(
      "exit_code=" +
      exit_code.to_string() +
      " != expect_exit=" +
      acceptance.expect_exit.to_string(),
    )
  }
  for s in acceptance.stdout_contains {
    if !stdout.contains(s) {
      reasons.push("stdout 缺少应含内容: " + s)
    }
  }
  for s in acceptance.stdout_not_contains {
    if stdout.contains(s) {
      reasons.push("stdout 含禁止内容: " + s)
    }
  }
  for s in acceptance.stderr_not_contains {
    if stderr.contains(s) {
      reasons.push("stderr 含禁止内容: " + s)
    }
  }
  match (acceptance.artifact_glob, artifact_hit) {
    (Some(_), Some(true)) => ()
    (Some(g), Some(false)) => reasons.push("artifact_glob 无命中: " + g)
    (Some(g), None) => reasons.push("artifact_glob 未能解析: " + g)
    (None, _) => ()
  }
  if reasons.length() == 0 {
    AcceptanceResult::new(true, "")
  } else {
    AcceptanceResult::new(false, reasons.join("; "))
  }
}

///|
/// 从 rx 非零退出错误文本恢复真实退出码与 stderr
///
/// rx 0.4.4 契约（rhop_task task_exec）：非零退出走
/// on_error(SpawnFailed("退出码 N[；stderr: S]"))，经 exec_error_text
/// 映射为 "执行失败: 退出码 N[；stderr: S]"。本函数按该固定格式解析
/// （格式与 moon.mod 锁定的 RX-MBT 0.4.4 绑定）；策略拒绝等其他错误
/// 格式返回 None（调用方保持 v1.0 的 exit_code=-1 语义）。
///
/// 注意：rx 非零路径不交付 stdout（Observable 层丢弃），本函数只能恢复
/// exit_code 与 stderr——这是 rx 侧限制，诚实标注。
pub fn parse_exit_error(text : String) -> (Int32, String)? {
  let prefix = "执行失败: 退出码 "
  if !text.has_prefix(prefix) {
    return None
  }
  let rest = text[prefix.length():].to_owned()
  let a = rest.to_array()
  let n = a.length()
  let mut i = 0
  while i < n {
    let ch = a[i]
    if ch >= '0' && ch <= '9' {
      i = i + 1
    } else {
      break
    }
  }
  if i == 0 {
    return None
  }
  match @util.parse_int(rest[0:i].to_owned()) {
    None => None
    Some(c) => {
      let tail = rest[i:].to_owned()
      let sep = "；stderr: "
      if tail.has_prefix(sep) {
        Some((c, tail[sep.length():].to_owned()))
      } else {
        Some((c, ""))
      }
    }
  }
}

// ============================================================================
// 守卫门（schema v1.1 · PLAN-gates.md §二：执行前环境准入）
// ============================================================================

///|
/// 守卫判定结果
#derive(Eq, Debug)
pub(all) struct GuardResult {
  /// 守卫是否通过（必须 exit 0）
  passed : Bool
  /// 失败原因（通过时为空）
  reason : String
}

///|
pub extend GuardResult with Eq::{not_equal, equal}

///|
pub extend GuardResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 构造守卫判定结果
pub fn GuardResult::new(passed : Bool, reason : String) -> GuardResult {
  { passed, reason, }
}

///|
/// 执行守卫门（同步等待结果）
///
/// 复用 run_command + ExecPolicy 白名单（argv 同样进白名单校验，绝不走
/// shell）；仅 exit 0 视为通过。变量占位符沿用 schema §7 机制（与 v1.0
/// command 动作一致：占位符展开未实现，argv 按字面量执行）——守卫保持
/// 单命令，不做组合逻辑（红线：防策略引擎）。
pub fn run_guard(
  guard_spec : @config.GuardSpec,
  ev : @watch.FsEvent,
  policy : @rt.ExecPolicy,
) -> GuardResult {
  let spec = @config.ActionSpec::new(
    "command",
    Some(guard_spec.argv),
    None,
    None,
    None,
  )
  // 守卫无验收语义（它自己就是门禁）；watch_dir 占位不用
  let outcome = run_command_action(spec, ev, policy, "")
  if outcome.ok {
    GuardResult::new(true, "")
  } else {
    GuardResult::new(false, outcome.stderr)
  }
}

///|
/// 执行 command 动作（同步等待结果）
///
/// 参数：
///   spec      - 动作规格（kind 必须是 "command"，argv 必须非空）
///   ev        - 触发事件（用于未来的变量占位展开）
///   policy    - 执行策略（白名单）
///   watch_dir - 监控根目录（acceptance.artifact_glob 相对它解析；无验收时不用）
///
/// 返回：动作执行结果。
///   - 无 acceptance：v1.0 行为不变（ok = exit_code == 0，accepted = ok）
///   - 有 acceptance：验收不过时 accepted=false，保留真实 exit_code 与输出原文
///     （非零退出经 parse_exit_error 从 rx on_error 文本恢复）
pub fn run_command_action(
  spec : @config.ActionSpec,
  ev : @watch.FsEvent,
  policy : @rt.ExecPolicy,
  watch_dir : String,
) -> ActionOutcome {
  let _ = ev
  let argv = match spec.argv {
    Some(a) => a
    None =>
      return ActionOutcome::new(
        "command", false, -1, "", "command 动作缺少 argv",
      )
  }
  if argv.length() == 0 {
    return ActionOutcome::new(
      "command", false, -1, "", "command 动作的 argv 为空",
    )
  }
  // argv 一律以数组传递，**绝不 shell 拼接**（rx 侧保证）
  let payload = @json.parse(payload_json(argv)) catch {
    _ =>
      return ActionOutcome::new(
        "command", false, -1, "", "command payload 构造失败",
      )
  }
  // 闭包无法直接改外层变量，须经 Ref 间接赋值
  let result : Ref[@rt.CommandResult?] = Ref::Ref(None)
  let err : Ref[String?] = Ref::Ref(None)
  let obs = @rt.run_command(policy, payload)
  let _ = obs.subscribe_on_next(fn(r : @rt.CommandResult) {
    result.val = Some(r)
  })
  let _ = obs.subscribe_on_error(fn(e : @rt.ExecError) {
    err.val = Some(exec_error_text(e))
  })
  match result.val {
    Some(r) => {
      let ok = r.exit_code == 0
      match spec.acceptance {
        None =>
          // v1.0 行为（向后兼容锁）
          ActionOutcome::new(
            "command",
            ok,
            r.exit_code,
            r.stdout,
            r.stderr,
          )
        Some(acc) => {
          let hit = match acc.artifact_glob {
            Some(g) => Some(artifact_glob_hit(watch_dir, g))
            None => None
          }
          let res = acceptance_check(acc, r.exit_code, r.stdout, r.stderr, hit)
          {
            kind: "command",
            ok,
            exit_code: r.exit_code,
            stdout: r.stdout,
            stderr: r.stderr,
            accepted: res.accepted,
            acceptance_reason: res.reason,
          }
        }
      }
    }
    None => {
      let err_text = match err.val {
        Some(e) => e
        None => "command 执行未产出结果"
      }
      match spec.acceptance {
        None =>
          // v1.0 行为（向后兼容锁）：非零退出 exit_code=-1，原因入 stderr
          ActionOutcome::new(
            "command",
            false,
            -1,
            "",
            err_text,
          )
        Some(acc) =>
          match parse_exit_error(err_text) {
            Some((code, real_stderr)) => {
              let hit = match acc.artifact_glob {
                Some(g) => Some(artifact_glob_hit(watch_dir, g))
                None => None
              }
              let res = acceptance_check(acc, code, "", real_stderr, hit)
              {
                kind: "command",
                ok: code == 0,
                exit_code: code,
                stdout: "",
                stderr: real_stderr,
                accepted: res.accepted,
                acceptance_reason: res.reason,
              }
            }
            None => {
              // 策略拒绝 / 启动失败 / 超时：无真实退出码，保持 -1
              let res = acceptance_check(acc, -1, "", err_text, None)
              {
                kind: "command",
                ok: false,
                exit_code: -1,
                stdout: "",
                stderr: err_text,
                accepted: res.accepted,
                acceptance_reason: res.reason,
              }
            }
          }
      }
    }
  }
}

///|
/// 把 argv 数组序列化为 rx `run_command` 期望的 payload JSON
///
/// 格式：`{"kind":"cli","argv":["a","b"]}`
pub fn payload_json(argv : Array[String]) -> String {
  let parts : Array[String] = []
  for a in argv {
    parts.push("\"" + escape_json_string(a) + "\"")
  }
  "{\"kind\":\"cli\",\"argv\":[" + parts.join(",") + "]}"
}

// ============================================================================
// P3 · 产物生命周期语义
// ============================================================================

///|
/// 产物追踪项（用于 TTL 清理）
///
/// 注意：当前实现为内存追踪，重启后丢失。
/// 持久化追踪需要 @mon 包提供文件读写 API。
#derive(Eq, Debug)
pub(all) struct ProductRecord {
  /// 产物路径
  path : String
  /// 创建时间（纳秒，来自 @rx.real_now()）
  created_at_ns : Int64
  /// TTL（秒）
  ttl_seconds : Int32
}

///|
pub extend ProductRecord with Eq::{not_equal, equal}

///|
pub extend ProductRecord with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 产物追踪器（内存态）
///
/// 语义：记录每个产物的创建时间，TTL 到期后触发清理。
/// 清理动作由 scheduler 在每次事件循环时检查。
pub(all) struct ProductTracker {
  /// 产物记录表
  records : Array[ProductRecord]
}

///|
/// 构造产物追踪器
pub fn ProductTracker::new() -> ProductTracker {
  { records: [], }
}

///|
/// 注册产物（创建时调用）
///
/// 参数：
///   path - 产物路径
///   ttl_seconds - TTL（秒，0 = 不过期）
///
/// 返回：产物记录
pub fn ProductTracker::register(
  tracker : ProductTracker,
  path : String,
  ttl_seconds : Int32,
) -> ProductTracker {
  if ttl_seconds > 0 {
    let record = ProductRecord::{
      path,
      created_at_ns: Int64::from_int(@rx.real_now().to_int()),
      ttl_seconds,
    }
    tracker.records.push(record)
  }
  tracker
}

///|
/// 找出所有已到期的产物记录（TTL 核心语义，可单测、可观测）
///
/// 判定：now - created_at_ns >= ttl_seconds * 1e9；ttl_seconds <= 0 视为不过期
/// （register 本就不注册这类记录，这里再兜底）。
pub fn ProductTracker::expired_records(
  tracker : ProductTracker,
  now_ns : Int64,
) -> Array[ProductRecord] {
  let out : Array[ProductRecord] = []
  for record in tracker.records {
    if record.ttl_seconds > 0 {
      let age_ns = now_ns - record.created_at_ns
      let ttl_ns = Int64::from_int(record.ttl_seconds) * 1_000_000_000
      if age_ns >= ttl_ns {
        out.push(record)
      }
    }
  }
  out
}

///|
/// 检查并清理过期产物（P3 方案 B：TTL 语义做实 + 诚实降级）
///
/// 行为：
///   1. 计算到期产物，发出结构化的 `product.expired` 生命周期事件（println 可诊断）；
///   2. 从追踪表移除到期记录，返回剩余 tracker；
///   3. **不删文件、不移动文件**——trash 依赖 rx native 缺失的 mkdir/rename API，
///      已诚实降级为"规划中"（见 workbuddy/plan/p3-feasibility.md）。
///      到期只表示"逻辑生命周期结束"，物理回收留待 rx fs API 补齐。
///
/// 返回：(到期数量, 剩余追踪器)
pub fn ProductTracker::cleanup_expired(
  tracker : ProductTracker,
  _watch_dir : String,
) -> (Int32, ProductTracker) {
  let now_ns = Int64::from_int(@rx.real_now().to_int())
  let expired = tracker.expired_records(now_ns)
  let remaining : Array[ProductRecord] = []
  for record in tracker.records {
    let is_expired = expired.any(fn(r : ProductRecord) { r.path == record.path })
    if !is_expired {
      remaining.push(record)
    }
  }
  // 发出可诊断的生命周期事件（不再静默 no-op）
  for record in expired {
    let ev = LifecycleEvent::new(
      @config.LifecycleEventType::Expired,
      record.path,
    )
    println(
      "[lifecycle] " +
      ev.event_name() +
      " path=" +
      ev.path +
      " ttl=" +
      record.ttl_seconds.to_string() +
      "s（逻辑过期；物理回收待 rx fs API）",
    )
  }
  (expired.length(), { records: remaining, })
}

///|
/// 把 rx 的 FsError 转成可读文本（action 包局部实现）
fn fs_error_text_local(e : @mon.FsError) -> String {
  match e {
    @mon.FsError::NotFound => "NotFound"
    @mon.FsError::Io => "Io"
    @mon.FsError::OutOfMemory => "OutOfMemory"
  }
}

///|
/// 持久化追踪表到 JSONL（P3 方案 B：重启后不丢失 TTL 状态）
///
/// 每行格式：{"path":"...","created_at_ns":N,"ttl_seconds":N}
pub fn ProductTracker::save(
  tracker : ProductTracker,
  path : String,
) -> Result[Unit, String] {
  let mut text = ""
  for r in tracker.records {
    let obj = @json.Json::object({
      "path": @json.Json::string(r.path),
      "created_at_ns": @json.Json::number(Int64::to_double(r.created_at_ns)),
      "ttl_seconds": @json.Json::number(r.ttl_seconds.to_double()),
    })
    text = text + @json.Json::stringify(obj) + "\n"
  }
  match @mon.fs_write_atomic(path, text) {
    Ok(_) => Ok(())
    Err(e) => Err("持久化产物追踪表失败: " + fs_error_text_local(e))
  }
}

///|
/// 从 JSONL 恢复追踪表（损坏行跳过，不崩溃）
pub fn ProductTracker::load(path : String) -> ProductTracker {
  let records : Array[ProductRecord] = []
  let text = match @mon.fs_read_text(path) {
    Ok(s) => s
    Err(_) => return { records: [], }
  }
  for line in text.split("\n") {
    let trimmed = line.trim()
    if trimmed == "" {
      continue
    }
    let parsed = @json.parse(trimmed) catch { _ => continue }
    match parsed {
      @json.Json::Object(m) => {
        let p = match m.get("path") {
          Some(@json.Json::String(s)) => s
          _ => continue
        }
        let created = match m.get("created_at_ns") {
          Some(@json.Json::Number(n)) => Int64::from_int(n.to_int())
          _ => continue
        }
        let ttl = match m.get("ttl_seconds") {
          Some(@json.Json::Number(n)) => n.to_int()
          _ => continue
        }
        records.push(ProductRecord::{
          path: p,
          created_at_ns: created,
          ttl_seconds: ttl,
        })
      }
      _ => ()
    }
  }
  { records, }
}

///|
/// 加密文件（P3 产物生命周期语义）
///
/// 参数：
///   path - 文件路径
///   key - 加密密钥（可选，未提供时使用默认密钥）
///
/// 返回：成功或失败
///
/// 诚实降级说明（实测确认，勿凭注释推翻）：
///   rx 的 RhopCrypto 底层 Fernet 原语是 `extern "js"`（node:crypto），
///   native/wasm 下加密返回空串、解密返回可诊断 Err——无法真正做实。
///   本函数明确返回 Err（"当前目标不支持"），不再静默返回 Ok 伪装成功；
///   且**绝不写入空密文**，以免破坏产物。若将来 rx 补齐 native crypto FFI，
///   可在此接入 encrypt_secret/decrypt_secret。
pub fn encrypt_file(path : String, key : String?) -> Result[Unit, String] {
  let _ = path
  let _ = key
  Err("产物加密当前目标不支持：rx Fernet 原语仅 js 可用（native/wasm 无 node:crypto），已诚实降级；不写入空密文以免破坏产物")
}

///|
/// 生命周期事件（供 EventBus 发布）
///
/// 注意：当前实现为日志输出，实际发布需要 EventBus 接入。
/// 等 scheduler 侧接入 EventBus 后，会发布到对应事件名。
#derive(Eq, Debug)
pub(all) struct LifecycleEvent {
  /// 事件类型
  kind : @config.LifecycleEventType
  /// 产物路径
  path : String
  /// 时间戳（纳秒）
  timestamp_ns : Int64
  /// 附加消息（EP-01a log_event；无消息时为空串，v1.0 事件不受影响）
  message : String
}

///|
pub extend LifecycleEvent with Eq::{not_equal, equal}

///|
pub extend LifecycleEvent with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 构造生命周期事件（message 缺省空串，向后兼容）
pub fn LifecycleEvent::new(
  kind : @config.LifecycleEventType,
  path : String,
) -> LifecycleEvent {
  {
    kind,
    path,
    timestamp_ns: Int64::from_int(@rx.real_now().to_int()),
    message: "",
  }
}

///|
/// 构造带消息的生命周期事件（EP-01a log_event 用）
pub fn LifecycleEvent::new_with_message(
  kind : @config.LifecycleEventType,
  path : String,
  message : String,
) -> LifecycleEvent {
  {
    kind,
    path,
    timestamp_ns: Int64::from_int(@rx.real_now().to_int()),
    message,
  }
}

///|
/// 生命周期事件 → 事件名（用于 EventBus 订阅）
///
/// 格式：`product.<type>`（如 `product.created`）
pub fn LifecycleEvent::event_name(self : LifecycleEvent) -> String {
  self.kind.to_string()
}

///|
/// JSON 字符串转义（最小实现：处理引号与反斜杠与控制字符）
pub fn escape_json_string(s : String) -> String {
  let out = Ref::Ref("")
  for ch in s {
    match ch {
      '"' => out.val = out.val + "\\\""
      '\\' => out.val = out.val + "\\\\"
      '\n' => out.val = out.val + "\\n"
      '\r' => out.val = out.val + "\\r"
      '\t' => out.val = out.val + "\\t"
      _ => out.val = out.val + ch.to_string()
    }
  }
  out.val
}

///|
/// 把 rx 的 `ExecError` 转成可读文本
pub fn exec_error_text(e : @rt.ExecError) -> String {
  match e {
    @rt.ExecError::PolicyDenied(msg) => "策略拒绝: " + msg
    @rt.ExecError::SpawnFailed(msg) => "执行失败: " + msg
    _ => "执行错误"
  }
}

// ============================================================================
// EP-01a · 变量占位符渲染（schema §7）
//
// 纯函数、全目标可用：internal log_event 的 message 与 EP-01b webhook 的
// url/body 复用同一机制。解析失败（未知变量 / 无扩展名）→ 空串替换 + warning，
// 不中断动作链（schema §9）。
// ============================================================================

///|
/// 路径的文件名部分（最后一个 / 或 \ 之后；无分隔符返回整串）
pub fn path_name_of(path : String) -> String {
  let a = path.to_array()
  let n = a.length()
  let mut last = -1
  for i in 0..<n {
    if a[i] == '/' || a[i] == '\\' {
      last = i
    }
  }
  if last < 0 {
    return path
  }
  let out = Ref::Ref("")
  for i in (last + 1)..<n {
    out.val = out.val + a[i].to_string()
  }
  out.val
}

///|
/// 路径的目录部分（最后一个 / 或 \ 之前；无分隔符返回空串）
pub fn path_dir_of(path : String) -> String {
  let a = path.to_array()
  let n = a.length()
  let mut last = -1
  for i in 0..<n {
    if a[i] == '/' || a[i] == '\\' {
      last = i
    }
  }
  if last < 0 {
    return ""
  }
  let out = Ref::Ref("")
  for i in 0..<last {
    out.val = out.val + a[i].to_string()
  }
  out.val
}

///|
/// 路径的扩展名（文件名最后一个点之后；无点 / 前导点（隐藏文件）/ 空扩展名 → None）
pub fn path_ext_of(path : String) -> String? {
  let a = path_name_of(path).to_array()
  let n = a.length()
  let mut last = -1
  for i in 0..<n {
    if a[i] == '.' {
      last = i
    }
  }
  if last <= 0 || last == n - 1 {
    return None
  }
  let out = Ref::Ref("")
  for i in (last + 1)..<n {
    out.val = out.val + a[i].to_string()
  }
  Some(out.val)
}

///|
/// 渲染 schema §7 变量占位符（单趟扫描，未知 `{` 按字面量保留）
///
/// 变量表（九项，无互相前缀冲突，匹配顺序无影响）：
///   {file.path} {file.name} {file.dir} {file.ext} {file.size}
///   {file.mtime} {event.type} {watch_dir} {watch_id}
///
/// 返回：(渲染结果, warning 列表)。解析失败 → 空串替换 + warning，不中断。
pub fn render_placeholders(
  template : String,
  ev : @watch.FsEvent,
  watch_dir : String,
  watch_id : String,
) -> (String, Array[String]) {
  let chars = template.to_array()
  let n = chars.length()
  let vars : Array[(String, String?)] = [
    ("{file.path}", Some(ev.path)),
    ("{file.name}", Some(path_name_of(ev.path))),
    ("{file.dir}", Some(path_dir_of(ev.path))),
    ("{file.ext}", path_ext_of(ev.path)),
    ("{file.size}", Some(ev.size.to_string())),
    ("{file.mtime}", Some(ev.mtime.to_string())),
    ("{event.type}", Some(ev.event_type.to_string())),
    ("{watch_dir}", Some(watch_dir)),
    ("{watch_id}", Some(watch_id)),
  ]
  let out = Ref::Ref("")
  let warns = Ref::Ref([])
  let mut i = 0
  while i < n {
    if chars[i] != '{' {
      out.val = out.val + chars[i].to_string()
      i = i + 1
    } else {
      let matched = Ref::Ref(false)
      for (name, value) in vars {
        if !matched.val && has_prefix_at(chars, i, name.to_array()) {
          matched.val = true
          i = i + name.length()
          match value {
            Some(v) => out.val = out.val + v
            None => {
              warns.val.push("变量解析失败，已替换为空串: " + name)
            }
          }
        }
      }
      if !matched.val {
        // 未知变量引用（{含至少一个点的标识符}）→ 空串 + warning（schema §9：
        // 变量解析失败不中断动作链）；其余 '{'（如 JSON 字面量花括号）原样保留
        match find_unknown_var_end(chars, i) {
          Some(end) => {
            let mut name = ""
            let mut k = i
            while k <= end {
              name = name + chars[k].to_string()
              k = k + 1
            }
            warns.val.push("变量解析失败，已替换为空串: " + name)
            i = end + 1
          }
          None => {
            out.val = out.val + "{"
            i = i + 1
          }
        }
      }
    }
  }
  (out.val, warns.val)
}

///|
/// 从 at 处（'{'）向前扫描：若其后是变量引用（标识符序列、至少含一个点、
/// 以 '}' 收尾）返回 '}' 的下标；否则返回 None（字面量花括号）
fn find_unknown_var_end(chars : Array[Char], at : Int32) -> Int32? {
  let n = chars.length()
  let mut j = at + 1
  let mut has_dot = false
  while j < n {
    let cj = chars[j]
    if cj == '}' {
      if has_dot {
        return Some(j)
      }
      return None
    }
    if !is_ident_char(cj) {
      return None
    }
    if cj == '.' {
      has_dot = true
    }
    j = j + 1
  }
  None
}

///|
/// 变量引用扫描用的标识符字符（字母 / 数字 / 下划线 / 点）
fn is_ident_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') ||
    c == '_' ||
    c == '.'
}

///|
/// chars 在 at 处是否以 name 开头（纯 Char 数组比较，UTF-8 安全）
fn has_prefix_at(chars : Array[Char], at : Int32, name : Array[Char]) -> Bool {
  if at + name.length() > chars.length() {
    return false
  }
  for k in 0..<name.length() {
    if chars[at + k] != name[k] {
      return false
    }
  }
  true
}

// ============================================================================
// EP-01a · internal 动作注册表
//
// schema §5 扩展位落地：`op` → handler 的运行时注册表。四个 schema 枚举 op
// （reload_config / pause_watch / resume_watch / log_event）由 scheduler 侧
// build_internal_registry 直连既有函数注册；未知 op 返回可诊断错误（fail-closed）。
// ============================================================================

///|
/// internal op 处理器：(动作规格, 触发事件, 监控根目录) → 执行结果
///
/// 注：函数类型位置不接受命名参数（仅值位置 fn 表达式允许 label），
/// 用裸类型序且必须单行（rx task_exec 的 Handler 别名同款范式）。
/// ⚠️ struct 定义字段列表**不允许尾逗号**（字面量允许）——实测踩坑。
pub type InternalOpHandler = (@config.ActionSpec, @watch.FsEvent, String) -> ActionOutcome

///|
/// internal 动作注册表（op → handler）
pub struct InternalRegistry {
  handlers : Map[String, InternalOpHandler]
}

///|
/// 构造空注册表
pub fn InternalRegistry::new() -> InternalRegistry {
  { handlers: Map([], capacity=4) }
}

///|
/// 注册一个 internal op
pub fn InternalRegistry::register(
  reg : InternalRegistry,
  op : String,
  handler : InternalOpHandler,
) -> Unit {
  reg.handlers[op] = handler
}

///|
/// 查询一个 internal op（未注册返回 None）
pub fn InternalRegistry::lookup(
  reg : InternalRegistry,
  op : String,
) -> InternalOpHandler? {
  reg.handlers.get(op)
}

///|
/// 执行 internal 动作（经注册表分派）
///
/// 返回契约（与 command 无验收分支一致）：
///   - handler 成功（outcome.ok）→ Ok(outcome)
///   - handler 失败 → Err(outcome.stderr)，由上层落「err:」日志与 -1 记录
pub fn run_internal_action(
  registry : InternalRegistry,
  spec : @config.ActionSpec,
  ev : @watch.FsEvent,
  watch_dir : String,
) -> Result[ActionOutcome, String] {
  let op = match spec.op {
    Some(o) => o
    None => return Err("internal 动作缺少必填字段 op")
  }
  match registry.lookup(op) {
    Some(handler) => {
      let outcome = handler(spec, ev, watch_dir)
      if outcome.ok {
        Ok(outcome)
      } else {
        Err(outcome.stderr)
      }
    }
    None => Err("internal op 未注册: " + op)
  }
}

///|
/// 按动作规格执行（带日志记录）
///
/// 支持的 kind：
///   - `command`      → rx run_command + ExecPolicy（已接入）
///   - `mcp_tool_call`→ 待实现（EP-01 扩展位），返回可诊断错误
///   - `webhook`      → 待实现（EP-01 扩展位），返回可诊断错误
///   - `internal`     → internal 动作注册表分派（EP-01a 已接入）
///
/// 参数：
///   spec   - 动作规格
///   ev     - 触发事件
///   policy - 执行策略（command 动作用；其他动作忽略）
///   logging_config - 日志配置（用于控制日志输出）
///   watch_dir - 监控根目录（acceptance.artifact_glob 相对它解析）
///   watch_id  - 实例 id（webhook/mcp 的 {watch_id} §7 占位符展开；缺省 ""）
///   registry - internal 动作注册表（EP-01a；缺省空注册表 ⇒ internal 报未注册）
///
/// 返回契约（v1.1）：
///   - 无 acceptance：v1.0 不变（command 成功 Ok / 失败 Err）
///   - 有 acceptance：无论过与否都返回 Ok(outcome)——验收不过是"完成了
///     判定的执行"，判定在 outcome.accepted 上；同时发出 product.invalid
///     生命周期事件（进入既有 TTL/trash 回收流的语义入口），不做自动重试
pub fn run_action(
  spec : @config.ActionSpec,
  ev : @watch.FsEvent,
  policy : @rt.ExecPolicy,
  logging_config : @config.LoggingConfig,
  watch_dir : String,
  watch_id~ : String = "",
  registry~ : InternalRegistry = InternalRegistry::new(),
) -> Result[ActionOutcome, String] {
  // 记录执行开始时间
  let start_time_ns = Int64::from_int(@rx.real_now().to_int())

  let result = match spec.kind {
    "command" => {
      let outcome = run_command_action(spec, ev, policy, watch_dir)
      match (spec.acceptance, outcome.accepted) {
        (Some(_), false) => {
          // 验收不过：发出 product.invalid 生命周期事件（可诊断日志），
          // 保留真实 exit_code 与输出原文；不做自动重试（重试留给上层）
          let inv = LifecycleEvent::new(
            @config.LifecycleEventType::Invalid,
            ev.path,
          )
          println(
            "[lifecycle] " +
            inv.event_name() +
            " path=" +
            inv.path +
            " reason=" +
            outcome.acceptance_reason,
          )
          Ok(outcome)
        }
        _ => if outcome.ok { Ok(outcome) } else { Err(outcome.stderr) }
      }
    }
    "mcp_tool_call" =>
      Err(
        "action mcp_tool_call 待实现（EP-01 动作扩展）：需要 MCP 客户端接入",
      )
    "webhook" => {
      let outcome = run_webhook_action(spec, ev, watch_dir, watch_id)
      if outcome.ok {
        Ok(outcome)
      } else {
        Err(outcome.stderr)
      }
    }
    "internal" => run_internal_action(registry, spec, ev, watch_dir)
    other => Err("未知 action kind: " + other)
  }

  // 记录执行结束时间
  let end_time_ns = Int64::from_int(@rx.real_now().to_int())

  // 如果日志启用，输出日志
  if logging_config.enabled {
    let status = match result {
      Ok(outcome) => if outcome.accepted { "success" } else { "acceptance_failed" }
      Err(_) => "failure"
    }
    let result_summary = match result {
      Ok(outcome) =>
        if outcome.accepted {
          "exit_code=" + outcome.exit_code.to_string()
        } else {
          "exit_code=" + outcome.exit_code.to_string() + " " + outcome.acceptance_reason
        }
      Err(err) => "error=" + err
    }
    let duration_ms = (end_time_ns - start_time_ns).to_int() / 1000000

    println(
      "[" +
      status +
      "] " +
      "rule_action " +
      spec.kind +
      " " +
      "event=" +
      ev.event_type.to_string() +
      ":" +
      ev.path +
      " " +
      "duration=" +
      duration_ms.to_string() +
      "ms " +
      result_summary,
    )
  }

  result
}
