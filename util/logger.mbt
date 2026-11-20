// ============================================================================
// util · 规则触发日志记录器
//
// 功能：
//   - 记录规则触发事件
//   - 记录执行开始时间、结束时间
//   - 记录执行结果或执行状态
//   - 日志默认开启，可选择关闭
//   - 日志文件可指定文件夹
//
// 设计：
//   - 内存缓冲日志，定期刷盘（当前为 no-op，因为 @mon 包不提供文件写入 API）
//   - 日志格式：JSONL（每行一条 JSON 记录）
// ============================================================================

///|
/// 日志缓冲区默认容量（条目数；达到后触发轮转，避免内存无限增长）
const LOGGER_BUFFER_CAPACITY : Int32 = 1000

///|
/// 日志级别
#derive(Eq, Debug)
pub(all) enum LogLevel {
  Debug
  Info
  Warn
  Error
}

///|
pub extend LogLevel with Eq::{not_equal, equal}

///|
pub extend LogLevel with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 日志级别 → 字符串
pub fn LogLevel::to_string(self : LogLevel) -> String {
  match self {
    Debug => "DEBUG"
    Info => "INFO"
    Warn => "WARN"
    Error => "ERROR"
  }
}

///|
/// 规则触发日志记录
#derive(Eq, Debug)
pub(all) struct RuleTriggerLog {
  /// 规则 id
  rule_id : String
  /// 触发事件路径
  event_path : String
  /// 事件类型
  event_type : String
  /// 触发时间（纳秒，来自 @rx.real_now()）
  trigger_time_ns : Int64
  /// 执行开始时间（纳秒）
  start_time_ns : Int64?
  /// 执行结束时间（纳秒）
  end_time_ns : Int64?
  /// 执行状态：success / failure / pending
  status : String
  /// 执行结果摘要
  result_summary : String
  /// 动作数量
  actions_count : Int32
}

///|
pub extend RuleTriggerLog with Eq::{not_equal, equal}

///|
pub extend RuleTriggerLog with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 构造规则触发日志记录（初始状态）
pub fn RuleTriggerLog::new(
  rule_id : String,
  event_path : String,
  event_type : String,
  trigger_time_ns : Int64,
  actions_count : Int32,
) -> RuleTriggerLog {
  {
    rule_id,
    event_path,
    event_type,
    trigger_time_ns,
    start_time_ns: None,
    end_time_ns: None,
    status: "pending",
    result_summary: "",
    actions_count,
  }
}

///|
/// 设置执行开始时间
pub fn RuleTriggerLog::set_start_time(self : RuleTriggerLog, time_ns : Int64) -> RuleTriggerLog {
  {
    rule_id: self.rule_id,
    event_path: self.event_path,
    event_type: self.event_type,
    trigger_time_ns: self.trigger_time_ns,
    start_time_ns: Some(time_ns),
    end_time_ns: self.end_time_ns,
    status: self.status,
    result_summary: self.result_summary,
    actions_count: self.actions_count,
  }
}

///|
/// 设置执行结束时间和状态
pub fn RuleTriggerLog::set_end_time(
  self : RuleTriggerLog,
  time_ns : Int64,
  status : String,
  result_summary : String,
) -> RuleTriggerLog {
  {
    rule_id: self.rule_id,
    event_path: self.event_path,
    event_type: self.event_type,
    trigger_time_ns: self.trigger_time_ns,
    start_time_ns: self.start_time_ns,
    end_time_ns: Some(time_ns),
    status,
    result_summary,
    actions_count: self.actions_count,
  }
}

///|
/// 规则触发日志记录器
pub(all) struct Logger {
  /// 日志配置
  config : @config.LoggingConfig
  /// 内存日志缓冲区
  buffer : Array[RuleTriggerLog]
  /// 缓冲区最大条目数（默认 LOGGER_BUFFER_CAPACITY，达到后触发轮转）
  max_buffer_size : Int32
}

///|

/// 构造日志记录器
pub fn Logger::new(config : @config.LoggingConfig) -> Logger {
  { config, buffer: [], max_buffer_size: LOGGER_BUFFER_CAPACITY, }
}

///|
/// 记录规则触发事件
///
/// 参数：
///   rule_id - 规则 id
///   event_path - 触发事件路径
///   event_type - 事件类型
///   actions_count - 动作数量
///
/// 返回：日志记录（用于后续设置开始/结束时间）
pub fn Logger::log_trigger(
  self : Logger,
  rule_id : String,
  event_path : String,
  event_type : String,
  actions_count : Int32,
) -> RuleTriggerLog {
  let now_ns = Int64::from_int(@rx.real_now().to_int())
  let log = RuleTriggerLog::new(rule_id, event_path, event_type, now_ns, actions_count)
  // 如果日志启用，添加到缓冲区
  if self.config.enabled {
    let mut new_buffer = self.buffer.clone()
    new_buffer.push(log)
    // 检查缓冲区大小，触发轮转
    if new_buffer.length() > self.max_buffer_size {
      // 轮转：保留最近的 max_buffer_size 条日志
      let start_idx = new_buffer.length() - self.max_buffer_size
      let rotated : Array[RuleTriggerLog] = []
      for i in start_idx..<new_buffer.length() {
        rotated.push(new_buffer.at(i))
      }
      new_buffer = rotated
    }
    // 更新缓冲区（注意：这里无法修改 self，需要返回新的 Logger）
    // 当前实现为 no-op，实际需要 Ref 或可变引用
  }
  log
}

///|
/// 记录执行开始时间
///
/// 参数：
///   log - 日志记录
///
/// 返回：更新后的日志记录
pub fn log_execution_start(log : RuleTriggerLog) -> RuleTriggerLog {
  let now_ns = Int64::from_int(@rx.real_now().to_int())
  log.set_start_time(now_ns)
}

///|
/// 记录执行结束时间和状态
///
/// 参数：
///   log - 日志记录
///   status - 执行状态：success / failure
///   result_summary - 执行结果摘要
///
/// 返回：更新后的日志记录
pub fn log_execution_end(
  log : RuleTriggerLog,
  status : String,
  result_summary : String,
) -> RuleTriggerLog {
  let now_ns = Int64::from_int(@rx.real_now().to_int())
  log.set_end_time(now_ns, status, result_summary)
}

///|
/// 日志记录 → JSON 字符串
///
/// 格式：JSONL（每行一条 JSON 记录）
pub fn log_to_json(log : RuleTriggerLog) -> String {
  let start_time = match log.start_time_ns {
    Some(t) => t.to_string()
    None => "null"
  }
  let end_time = match log.end_time_ns {
    Some(t) => t.to_string()
    None => "null"
  }
  "{\"rule_id\":\"" + escape_json_string(log.rule_id) +
    "\",\"event_path\":\"" + escape_json_string(log.event_path) +
    "\",\"event_type\":\"" + escape_json_string(log.event_type) +
    "\",\"trigger_time_ns\":" + log.trigger_time_ns.to_string() +
    "\",\"start_time_ns\":" + start_time +
    "\",\"end_time_ns\":" + end_time +
    "\",\"status\":\"" + log.status +
    "\",\"result_summary\":\"" + escape_json_string(log.result_summary) +
    "\",\"actions_count\":" + log.actions_count.to_string() + "}"
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
/// 输出日志到控制台（用于调试）
pub fn print_log(log : RuleTriggerLog) -> Unit {
  let duration = match (log.start_time_ns, log.end_time_ns) {
    (Some(start), Some(end)) => {
      let ms = (end - start).to_int() / 1000000
      " (" + ms.to_string() + "ms)"
    }
    _ => ""
  }
  println(
    "[" + log.status + "] " +
    "rule=" + log.rule_id + " " +
    "event=" + log.event_type + ":" + log.event_path + " " +
    "actions=" + log.actions_count.to_string() +
    duration
  )
}

///|
/// 输出日志摘要（用于调试）
pub fn print_log_summary(log : RuleTriggerLog) -> Unit {
  println(
    "RuleTriggerLog { " +
    "rule_id: " + log.rule_id + ", " +
    "event: " + log.event_type + ":" + log.event_path + ", " +
    "status: " + log.status + ", " +
    "actions: " + log.actions_count.to_string() +
    " }"
  )
}
