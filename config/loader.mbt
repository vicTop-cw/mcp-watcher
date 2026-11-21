// ============================================================================
// config · 解析与校验（手动提取，与 rx-mbt 同范式；累积式校验）
// ============================================================================

///|
/// 规则冲突提示的「优先级差异较大」阈值（硬编码收敛 · 2026-11-20）
/// 优先级差绝对值 >= 该值时，冲突汇总会追加排序建议提示
const PRIORITY_DIFF_ADVICE_THRESHOLD = 50

///|
/// 取 JSON 对象里的字段
fn jget(v : Json, key : String) -> Json? {
  match v {
    Object(m) => m.get(key)
    _ => None
  }
}

///|
/// JSON 值 → 字符串
fn jstr(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// JSON 值 → 布尔
fn jbool(v : Json?) -> Bool? {
  match v {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
/// JSON 值 → 整数（JSON 数字为 Double，转 Int）
fn jint(v : Json?) -> Int32? {
  match v {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
/// JSON 值 → 字符串数组
fn jstr_array(v : Json?) -> Array[String] {
  let out : Array[String] = []
  match v {
    Some(Array(items)) =>
      for it in items {
        match it {
          String(s) => out.push(s)
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// 解析条件规格
fn parse_condition(v : Json?) -> ConditionSpec? {
  match v {
    Some(Object(m)) => {
      let kind = match jstr(m.get("kind")) {
        Some(k) => k
        None => ""
      }
      let expr = match jstr(m.get("expr")) {
        Some(e) => e
        None => ""
      }
      Some({ kind, expr, })
    }
    _ => None
  }
}

///|
/// 严格字符串数组解析（fail-closed：非字符串元素 / 非数组一律报错）
fn parse_str_array(v : Json, field : String) -> Result[Array[String], String] {
  match v {
    Array(items) => {
      let out : Array[String] = []
      for it in items {
        match it {
          String(s) => out.push(s)
          _ => return Err(field + " 必须是字符串数组")
        }
      }
      Ok(out)
    }
    _ => Err(field + " 必须是字符串数组")
  }
}

///|
/// 解析验收门规格（schema v1.1  fail-closed  PLAN-gates.md §一 验收用例5）
///
/// 未知字段 / 类型错一律报 schema 错；无该字段 → None（v1.0 行为不变）。
fn parse_acceptance(v : Json?) -> Result[AcceptanceSpec?, String] {
  match v {
    Some(Object(m)) => {
      // fail-closed：只允许已知字段
      for key in m.keys() {
        let known = key == "expect_exit" || key == "stdout_contains" || key == "stdout_not_contains" || key == "stderr_not_contains" || key == "artifact_glob"
        if !known {
          return Err("acceptance 含未知字段: " + key)
        }
      }
      let mut expect_exit = DEFAULT_EXPECT_EXIT
      match m.get("expect_exit") {
        Some(Number(n, ..)) => expect_exit = n.to_int()
        Some(_) => return Err("acceptance.expect_exit 必须是整数")
        None => ()
      }
      let stdout_contains = match m.get("stdout_contains") {
        Some(arr) => match parse_str_array(arr, "acceptance.stdout_contains") {
          Ok(a) => a
          Err(e) => return Err(e)
        }
        None => []
      }
      let stdout_not_contains = match m.get("stdout_not_contains") {
        Some(arr) => match parse_str_array(arr, "acceptance.stdout_not_contains") {
          Ok(a) => a
          Err(e) => return Err(e)
        }
        None => []
      }
      let stderr_not_contains = match m.get("stderr_not_contains") {
        Some(arr) => match parse_str_array(arr, "acceptance.stderr_not_contains") {
          Ok(a) => a
          Err(e) => return Err(e)
        }
        None => []
      }
      let artifact_glob = match m.get("artifact_glob") {
        Some(String(s)) => Some(s)
        Some(_) => return Err("acceptance.artifact_glob 必须是字符串")
        None => None
      }
      Ok(
        Some(
          {
            expect_exit,
            stdout_contains,
            stdout_not_contains,
            stderr_not_contains,
            artifact_glob,
          },
        ),
      )
    }
    _ => Ok(None)
  }
}

///|
/// ASCII 大写（MoonBit core 无公开 case API；字符字面量映射，仅处理 a-z）
fn upper_ascii(s : String) -> String {
  let mut out = ""
  for ch in s {
    out = out + upper_char(ch).to_string()
  }
  out
}

///|
/// ASCII 小写（MoonBit core 无公开 case API；字符字面量映射，仅处理 A-Z）
fn lower_ascii(s : String) -> String {
  let mut out = ""
  for ch in s {
    out = out + lower_char(ch).to_string()
  }
  out
}

///|
/// 单字符大写（字面量映射，不依赖 Char 构造 API）
fn upper_char(c : Char) -> Char {
  match c {
    'a' => 'A'
    'b' => 'B'
    'c' => 'C'
    'd' => 'D'
    'e' => 'E'
    'f' => 'F'
    'g' => 'G'
    'h' => 'H'
    'i' => 'I'
    'j' => 'J'
    'k' => 'K'
    'l' => 'L'
    'm' => 'M'
    'n' => 'N'
    'o' => 'O'
    'p' => 'P'
    'q' => 'Q'
    'r' => 'R'
    's' => 'S'
    't' => 'T'
    'u' => 'U'
    'v' => 'V'
    'w' => 'W'
    'x' => 'X'
    'y' => 'Y'
    'z' => 'Z'
    _ => c
  }
}

///|
/// 单字符小写（字面量映射，不依赖 Char 构造 API）
fn lower_char(c : Char) -> Char {
  match c {
    'A' => 'a'
    'B' => 'b'
    'C' => 'c'
    'D' => 'd'
    'E' => 'e'
    'F' => 'f'
    'G' => 'g'
    'H' => 'h'
    'I' => 'i'
    'J' => 'j'
    'K' => 'k'
    'L' => 'l'
    'M' => 'm'
    'N' => 'n'
    'O' => 'o'
    'P' => 'p'
    'Q' => 'q'
    'R' => 'r'
    'S' => 's'
    'T' => 't'
    'U' => 'u'
    'V' => 'v'
    'W' => 'w'
    'X' => 'x'
    'Y' => 'y'
    'Z' => 'z'
    _ => c
  }
}

///|
/// 解析动作规格
fn parse_action(v : Json) -> Result[ActionSpec, String] {
  match v {
    Object(m) => {
      let kind = match jstr(m.get("kind")) {
        Some(k) => k
        None =>
          match jstr(m.get("type")) {
            Some(t) => t
            None => return Err("动作缺少 kind/type")
          }
      }
      let argv = match m.get("argv") {
        Some(Array(items)) => {
          let a : Array[String] = []
          for it in items {
            match it {
              String(s) => {
                if s == "" {
                  return Err("动作 argv 元素不能为空")
                }
                a.push(s)
              }
              _ => ()
            }
          }
          Some(a)
        }
        _ => None
      }
      let target = jstr(m.get("target"))
      let body = jstr(m.get("body"))
      let ttl = match jint(m.get("ttl")) {
        Some(t) => t
        None => DEFAULT_TTL_SECONDS
      }
      let cleanup = match jstr(m.get("cleanup")) {
        Some(c) => c
        None => "trash"
      }
      let acceptance = match parse_acceptance(m.get("acceptance")) {
        Ok(a) => a
        Err(e) => return Err(e)
      }
      // 验收门只对 command 动作有语义（fail-closed）
      if kind != "command" {
        match acceptance {
          Some(_) =>
            return Err(
              "acceptance 字段仅 command 动作可用（当前 kind=" + kind + "）",
            )
          None => ()
        }
      }
      // EP-01a：internal 的 op/message 解析（fail-closed）
      let op = jstr(m.get("op"))
      let message = jstr(m.get("message"))
      if kind == "internal" {
        match op {
          Some(o) if o != "" => ()
          _ => return Err("internal 动作缺少必填字段 op")
        }
      } else {
        match (op, message) {
          (Some(_), _) =>
            return Err(
              "op 字段仅 internal 动作可用（当前 kind=" + kind + "）",
            )
          (None, Some(_)) =>
            return Err(
              "message 字段仅 internal 动作可用（当前 kind=" + kind + "）",
            )
          _ => ()
        }
      }
      // EP-01b/c：webhook / mcp_tool_call 字段（fail-closed；schema §5）
      // ⚠️ 按 kind 解析：command 动作的 schema 字段也叫 `args`，若不分 kind，
      //    v1.0 command 的 `args` 会漏进 mcp_args_json（破坏向后兼容）。
      let url = if kind == "webhook" {
        jstr(m.get("url"))
      } else {
        None
      }
      let method_raw = if kind == "webhook" {
        jstr(m.get("method"))
      } else {
        None
      }
      let headers_json = if kind == "webhook" {
        match m.get("headers") {
          Some(hj) => Some(@json.Json::stringify(hj))
          None => None
        }
      } else {
        None
      }
      // timeout_ms 为通用字段（command/webhook/mcp 均可用），不分 kind 解析
      let timeout_ms = match jint(m.get("timeout_ms")) {
        Some(t) => t
        None => 5000
      }
      let server = if kind == "mcp_tool_call" {
        jstr(m.get("server"))
      } else {
        None
      }
      let mcp_args_json = if kind == "mcp_tool_call" {
        match m.get("args") {
          Some(aj) => Some(@json.Json::stringify(aj))
          None => None
        }
      } else {
        None
      }
      // server_args：server 命令行参数（EP-01c）；mcp 专属字段（fail-closed，同 op/message 策略）
      let server_args : Array[String]? =
        match (kind, m.get("server_args")) {
          ("mcp_tool_call", Some(v)) =>
            match parse_str_array(v, "mcp_tool_call.server_args") {
              Ok(a) => Some(a)
              Err(e) => return Err(e)
            }
          ("mcp_tool_call", None) => Some([])
          (_, Some(_)) =>
            return Err(
              "server_args 字段仅 mcp_tool_call 动作可用（当前 kind=" +
              kind + "）",
            )
          (_, None) => None
        }
      let transport_raw = if kind == "mcp_tool_call" {
        jstr(m.get("transport"))
      } else {
        None
      }
      let mcp_tool = if kind == "mcp_tool_call" {
        jstr(m.get("tool"))
      } else {
        None
      }
      let mut http_method = method_raw
      let mut target_final = target
      let mut transport_final : String? = None
      if kind == "webhook" {
        match url {
          Some(u) if u != "" => ()
          _ => return Err("webhook 动作缺少必填字段 url（或为空）")
        }
        http_method = match method_raw {
          Some(mr) => {
            let up = upper_ascii(mr)
            if up == "GET" || up == "POST" {
              Some(up)
            } else {
              return Err("webhook.method 必须是 GET 或 POST（当前: " + mr + "）")
            }
          }
          None => Some("POST")
        }
      }
      if kind == "mcp_tool_call" {
        match server {
          Some(s) if s != "" => ()
          _ =>
            return Err(
              "mcp_tool_call 动作缺少必填字段 server（或为空）",
            )
        }
        match mcp_tool {
          Some(t) if t != "" => target_final = Some(t)
          _ =>
            return Err(
              "mcp_tool_call 动作缺少必填字段 tool（或为空）",
            )
        }
        transport_final = match transport_raw {
          Some(tr) => {
            let tl = lower_ascii(tr)
            if tl == "stdio" || tl == "sse" || tl == "http" {
              Some(tl)
            } else {
              return Err("mcp_tool_call.transport 必须是 stdio/sse/http（当前: " + tl + "）")
            }
          }
          None => Some(DEFAULT_MCP_TRANSPORT)
        }
      }
      Ok({
        kind,
        argv,
        target: target_final,
        body,
        ttl,
        cleanup,
        acceptance,
        op,
        message,
        url,
        http_method,
        headers_json,
        timeout_ms,
        server,
        mcp_args_json,
        server_args,
        transport: transport_final,
      })
    }
    _ => Err("动作必须是 JSON 对象")
  }
}

///|
/// 解析守卫门规格（schema v1.1  fail-closed  PLAN-gates.md §二）
///
/// 未知字段 / 空 argv / 非法 on_fail 一律报 schema 错；无该字段 → None
/// （v1.0 行为不变）。
fn parse_guard(v : Json?) -> Result[GuardSpec?, String] {
  match v {
    Some(Object(m)) => {
      // fail-closed：只允许已知字段
      for key in m.keys() {
        if key != "argv" && key != "on_fail" {
          return Err("guard 含未知字段: " + key)
        }
      }
      let argv = match m.get("argv") {
        Some(Array(items)) => {
          let a : Array[String] = []
          for it in items {
            match it {
              String(s) => {
                if s == "" {
                  return Err("guard.argv 元素不能为空")
                }
                a.push(s)
              }
              _ => return Err("guard.argv 必须是字符串数组")
            }
          }
          a
        }
        _ => return Err("guard.argv 必须是非空字符串数组")
      }
      if argv.length() == 0 {
        return Err("guard.argv 不能为空")
      }
      let on_fail = match jstr(m.get("on_fail")) {
        Some(f) => f
        None => DEFAULT_GUARD_ON_FAIL
      }
      if on_fail != "skip" && on_fail != "stop" {
        return Err("guard.on_fail 必须是 \"skip\" 或 \"stop\"")
      }
      Ok(Some({ argv, on_fail, }))
    }
    _ => Ok(None)
  }
}

///|
/// 解析单条规则
fn parse_rule(v : Json) -> Result[Rule, String] {
  match v {
    Object(m) => {
      let id = match jstr(m.get("id")) {
        Some(x) => x
        None => ""
      }
      let events = jstr_array(m.get("events"))
      // 验证事件类型（EP-03b：interval:<ms> 触发源放行，间隔下限 INTERVAL_MIN_MS）
      for e in events {
        if e.has_prefix("interval:") {
          match (try Ok(@string.parse_int64(e[9:].to_owned())) catch { err => Err(err) }) {
            Ok(ms) =>
              if ms < INTERVAL_MIN_MS {
                return Err(
                  "规则 " +
                  id +
                  ": interval 触发间隔过小 '" +
                  e +
                  "'（下限 " +
                  INTERVAL_MIN_MS.to_string() +
                  "ms）",
                )
              }
            Err(_) =>
              return Err("规则 " + id + ": interval 毫秒数非法 '" + e + "'")
          }
          continue
        }
        match EventType::from_string(e) {
          Some(_) => ()
          None =>
            return Err("规则 " + id + ": 无效的事件类型 '" + e + "'")
        }
      }
      let patterns = jstr_array(m.get("patterns"))
      // 验证 glob 模式（非空）
      for p in patterns {
        if p == "" {
          return Err("规则 " + id + ": 空的 glob 模式")
        }
      }
      let exclude = jstr_array(m.get("exclude"))
      let condition = parse_condition(m.get("condition"))
      let actions : Array[ActionSpec] = []
      match m.get("actions") {
        Some(Array(items)) =>
          for it in items {
            match parse_action(it) {
              Ok(a) => actions.push(a)
              Err(e) => return Err("规则 " + id + ": " + e)
            }
          }
        _ => ()
      }
      let stop_after = match jbool(m.get("stop_after")) {
        Some(b) => b
        None => false
      }
      let priority = match jint(m.get("priority")) {
        Some(p) => p
        None => PRIORITY_MEDIUM_MIN
      }
      let guard_spec = match parse_guard(m.get("guard")) {
        Ok(g) => g
        Err(e) => return Err("规则 " + id + ": " + e)
      }
      Ok({
        id,
        events,
        patterns,
        exclude,
        condition,
        actions,
        stop_after,
        priority,
        guard_spec,
      })
    }
    _ => Err("规则必须是 JSON 对象")
  }
}

///|
/// 解析日志配置
fn parse_logging_config(v : Json?) -> LoggingConfig {
  match v {
    Some(Object(m)) => {
      let enabled = match jbool(m.get("enabled")) {
        Some(b) => b
        None => true
      }
      let log_dir = match jstr(m.get("log_dir")) {
        Some(d) => d
        None => ""
      }
      let log_file = match jstr(m.get("log_file")) {
        Some(f) => f
        None => DEFAULT_LOG_FILE
      }
      { enabled, log_dir, log_file, }
    }
    _ => LoggingConfig::new()
  }
}

///|
/// 检测两个模式数组是否有重叠
fn has_overlap(patterns1 : Array[String], patterns2 : Array[String]) -> Bool {
  for p1 in patterns1 {
    for p2 in patterns2 {
      if p1 == p2 {
        return true
      }
    }
  }
  false
}

///|
/// 检测两个事件数组是否有重叠
fn has_event_overlap(events1 : Array[String], events2 : Array[String]) -> Bool {
  for e1 in events1 {
    for e2 in events2 {
      if e1 == "all" || e2 == "all" || e1 == e2 {
        return true
      }
    }
  }
  false
}

///|
/// 检测规则冲突（警告级别，不阻止配置加载）
///
/// 冲突类型：
///   1. 模式重叠：两个规则匹配同一个文件模式
///   2. 事件类型冲突：两个规则监听相同事件类型
///   3. 优先级冲突：高优先级规则会先执行
///   4. 动作冲突：两个规则执行相同动作
fn detect_conflicts(rules : Array[Rule]) -> Array[String] {
  let conflicts : Array[String] = []
  let n = rules.length()
  for i in 0..<n {
    for j in (i + 1)..<n {
      let r1 = rules.at(i)
      let r2 = rules.at(j)

      // 检测模式重叠
      if has_overlap(r1.patterns, r2.patterns) {
        // 检测事件类型冲突
        if has_event_overlap(r1.events, r2.events) {
          conflicts.push(
            "⚠️ 规则冲突: '" +
            r1.id +
            "' 与 '" +
            r2.id +
            "' 有重叠的模式和事件类型",
          )

          // 检测优先级差异
          if r1.priority != r2.priority {
            let level1 = PriorityLevel::from_priority(r1.priority)
            let level2 = PriorityLevel::from_priority(r2.priority)
            let higher = if r1.priority > r2.priority { r1.id } else { r2.id }
            let lower = if r1.priority > r2.priority { r2.id } else { r1.id }
            let higher_level = if r1.priority > r2.priority {
              level1
            } else {
              level2
            }
            let lower_level = if r1.priority > r2.priority {
              level2
            } else {
              level1
            }

            conflicts.push(
              "   📊 优先级: '" +
              higher +
              "' (" +
              higher_level.to_string() +
              ") 会先执行 '" +
              lower +
              "' (" +
              lower_level.to_string() +
              ")",
            )

            // 如果优先级差异较大，给出建议
            let diff = r1.priority - r2.priority
            if diff.abs() >= PRIORITY_DIFF_ADVICE_THRESHOLD {
              conflicts.push(
                "   💡 建议: 优先级差异较大 (" +
                diff.abs().to_string() +
                " 点)，确认是否期望此顺序",
              )
            }
          } else {
            conflicts.push(
              "   ⚠️ 注意: 两个规则优先级相同，执行顺序不确定",
            )
          }

          // 检测动作冲突
          if has_same_actions(r1.actions, r2.actions) {
            conflicts.push(
              "   🔄 动作冲突: 两个规则执行相同动作，可能产生重复效果",
            )
          }
        }
      }

      // 检测 exclude 冲突
      if has_exclude_conflict(r1, r2) {
        conflicts.push(
          "⚠️ 排除冲突: '" +
          r1.id +
          "' 的 exclude 可能影响 '" +
          r2.id +
          "' 的匹配",
        )
      }
    }
  }
  conflicts
}

///|
/// 检测两个规则是否有相同动作
fn has_same_actions(
  actions1 : Array[ActionSpec],
  actions2 : Array[ActionSpec],
) -> Bool {
  for a1 in actions1 {
    for a2 in actions2 {
      if a1.kind == a2.kind {
        // 对于 command 动作，检查 argv 是否相同
        if a1.kind == "command" {
          match (a1.argv, a2.argv) {
            (Some(argv1), Some(argv2)) =>
              if argv1.length() == argv2.length() {
                let mut same = true
                for k in 0..<argv1.length() {
                  if argv1.at(k) != argv2.at(k) {
                    same = false
                    break
                  }
                }
                if same {
                  return true
                }
              }
            _ => ()
          }
        } else {
          return true
        }
      }
    }
  }
  false
}

///|
/// 检测 exclude 冲突
fn has_exclude_conflict(r1 : Rule, r2 : Rule) -> Bool {
  // 如果 r1 的 patterns 匹配 r2 的 exclude，则可能有冲突
  for p in r1.patterns {
    for e in r2.exclude {
      if p == e {
        return true
      }
    }
  }
  false
}

///|
/// 从 JSON 文本解析配置
pub fn Config::from_json(text : String) -> Result[Config, String] {
  let j = @json.parse(text) catch {
    _ => return Err("配置 JSON 解析失败")
  }
  let schema_version = match jint(jget(j, "schema_version")) {
    Some(v) => v
    None => 1
  }
  let watch_id = match jstr(jget(j, "watch_id")) {
    Some(v) => v
    None => ""
  }
  let watch_dir = match jstr(jget(j, "watch_dir")) {
    Some(v) => v
    None => ""
  }
  let recursive = match jbool(jget(j, "recursive")) {
    Some(b) => b
    None => true
  }
  let debounce_ms = match jint(jget(j, "debounce_ms")) {
    Some(v) => v
    None => 0
  }
  let rules : Array[Rule] = []
  match jget(j, "rules") {
    Some(Array(items)) =>
      for it in items {
        match parse_rule(it) {
          Ok(r) => rules.push(r)
          Err(e) => return Err(e)
        }
      }
    _ => ()
  }
  let allowed_programs = jstr_array(jget(j, "allowed_programs"))
  let extensions = jstr_array(jget(j, "extensions"))
  let logging = parse_logging_config(jget(j, "logging"))
  let cfg = {
    schema_version,
    watch_id,
    watch_dir,
    recursive,
    debounce_ms,
    rules,
    allowed_programs,
    extensions,
    logging,
  }
  validate_config(cfg)
}

///|
/// 累积式校验：一次性报告全部问题
fn validate_config(cfg : Config) -> Result[Config, String] {
  let errs : Array[String] = []
  let warns : Array[String] = []
  // schema_version 校验：必须 >= 1
  if cfg.schema_version < 1 {
    errs.push(
      "schema_version 必须 >= 1，当前值: " +
      cfg.schema_version.to_string(),
    )
  }
  // watch_id 非空校验
  if cfg.watch_id == "" {
    errs.push("watch_id 不能为空")
  }
  // watch_dir 非空校验
  if cfg.watch_dir == "" {
    errs.push("watch_dir 不能为空")
  }

  // 至少一条规则
  if cfg.rules.length() == 0 {
    errs.push("至少需要一条规则")
  }
  // 每条规则字段完整性校验
  let ids : Map[String, Int32] = Map([], capacity=0)
  for r in cfg.rules {
    if r.id == "" {
      errs.push("规则缺少 id")
    }
    if r.events.length() == 0 {
      errs.push("规则 " + r.id + " 缺少 events")
    }
    if r.patterns.length() == 0 {
      errs.push("规则 " + r.id + " 缺少 patterns")
    }
    if r.actions.length() == 0 {
      errs.push("规则 " + r.id + " 缺少 actions")
    }
    match ids.get(r.id) {
      Some(_) => errs.push("规则 id 重复: " + r.id)
      None => ids[r.id] = 1
    }
  }
  // debounce_ms 非负校验
  if cfg.debounce_ms < 0 {
    errs.push("debounce_ms 不能为负")
  }
  // 显式 allowlist 校验（警告级别）：command 动作引用的程序必须在白名单中。
  // 安全默认：白名单为空 ⇒ 所有 command 都会被 ExecPolicy 拒绝，这里提示用户。
  for r in cfg.rules {
    for a in r.actions {
      if a.kind == "command" {
        match a.argv {
          Some(argv) if argv.length() > 0 => {
            let prog = argv[0]
            if !cfg.allowed_programs.contains(prog) {
              warns.push(
                "⚠️ 安全: 规则 '" +
                r.id +
                "' 的 command 程序 '" +
                prog +
                "' 不在 allowed_programs 白名单中，运行时将被 ExecPolicy 拒绝",
              )
            }
          }
          _ => ()
        }
      }
      // mcp server 程序同样进白名单校验（与 command/guard 同策略，EP-01c）
      if a.kind == "mcp_tool_call" {
        match a.server {
          Some(prog) if prog != "" =>
            if !cfg.allowed_programs.contains(prog) {
              warns.push(
                "⚠️ 安全: 规则 '" +
                r.id +
                "' 的 mcp server 程序 '" +
                prog +
                "' 不在 allowed_programs 白名单中，运行时将被拒绝",
              )
            }
          _ => ()
        }
      }
    }
    // guard 程序同样进白名单校验（与 command 同策略，PLAN-gates.md §二 用例3）
    match r.guard_spec {
      Some(g) => {
        let prog = g.argv[0]
        if !cfg.allowed_programs.contains(prog) {
          warns.push(
            "⚠️ 安全: 规则 '" +
            r.id +
            "' 的 guard 程序 '" +
            prog +
            "' 不在 allowed_programs 白名单中，运行时将被 ExecPolicy 拒绝",
          )
        }
      }
      None => ()
    }
  }
  // 规则冲突检测（警告级别）
  let conflicts = detect_conflicts(cfg.rules)
  for c in conflicts {
    warns.push(c)
  }
  if errs.length() == 0 {
    // 如果有警告，输出警告信息
    if warns.length() > 0 {
      println("")
      println("⚠️  配置警告:")
      for w in warns {
        println("  " + w)
      }
      println("")
    }
    Ok(cfg)
  } else {
    Err("配置校验失败:\n" + errs.join("\n"))
  }
}

///|
/// 公开校验入口：对已解析的 Config 做累积式校验
///
/// 用法：
///   let cfg = Config::from_json(text)?
///   validate(cfg)?
pub fn validate(cfg : Config) -> Result[Config, String] {
  validate_config(cfg)
}

///|
/// 默认配置（测试 / 占位用）
pub fn Config::default() -> Config {
  {
    schema_version: DEFAULT_SCHEMA_VERSION,
    watch_id: "",
    watch_dir: "",
    recursive: DEFAULT_RECURSIVE,
    debounce_ms: DEFAULT_DEBOUNCE_MS,
    rules: [],
    allowed_programs: [],
    extensions: [],
    logging: LoggingConfig::new(),
  }
}

///|
/// 复制一份配置并覆盖监控目录
///
/// 跨包无法构造结构体字面量（`@pkg.Type{..}` 不支持），
/// 故用伴生函数完成「派生配置」这类操作。
pub fn Config::with_watch_dir(self : Config, dir : String) -> Config {
  {
    schema_version: self.schema_version,
    watch_id: self.watch_id,
    watch_dir: dir,
    recursive: self.recursive,
    debounce_ms: self.debounce_ms,
    rules: self.rules,
    allowed_programs: self.allowed_programs,
    extensions: self.extensions,
    logging: self.logging,
  }
}

///|
/// 复制一份配置并覆盖去抖时长
pub fn Config::with_debounce_ms(self : Config, ms : Int32) -> Config {
  {
    schema_version: self.schema_version,
    watch_id: self.watch_id,
    watch_dir: self.watch_dir,
    recursive: self.recursive,
    debounce_ms: ms,
    rules: self.rules,
    allowed_programs: self.allowed_programs,
    extensions: self.extensions,
    logging: self.logging,
  }
}

///|
/// 从 JSON 文件解析配置
///
/// 参数：
///   path - JSON 文件路径
///
/// 返回：配置或错误
