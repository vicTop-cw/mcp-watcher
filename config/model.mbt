// ============================================================================
// config · 声明式规则 DSL 模型（与 config-schema.md 契约对齐）
//
// 这是"声明式规则系统"支柱的数据骨架：事件 + glob + 条件 + 动作。
// 解析采用手动提取（与 rx-mbt 一致），不使用 @json derive，规避派生不确定性。
// ============================================================================

///|
/// 事件类型（与 watch 层 FsEvent.event_type 对应）
#derive(Eq, Debug)
pub(all) enum EventType {
  Create
  Modify
  Delete
  Rename
  Attrib
  All
}

///|
/// 生命周期事件类型（产物生命周期语义）
#derive(Eq, Debug)
pub(all) enum LifecycleEventType {
  /// 产物创建
  Created
  /// 产物到期（TTL 过期）
  Expired
  /// 产物销毁（移入回收目录）
  Destroyed
}

///|
pub extend EventType with Eq::{not_equal, equal}

///|
pub extend LifecycleEventType with Eq::{not_equal, equal}

///|
pub extend LifecycleEventType with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 生命周期事件类型 → 字符串
pub fn LifecycleEventType::to_string(self : LifecycleEventType) -> String {
  match self {
    Created => "product.created"
    Expired => "product.expired"
    Destroyed => "product.destroyed"
  }
}

///|
/// 生命周期事件类型 ← 字符串
pub fn LifecycleEventType::from_string(s : String) -> LifecycleEventType? {
  match s {
    "created" => Some(Created)
    "expired" => Some(Expired)
    "destroyed" => Some(Destroyed)
    _ => None
  }
}

///|
pub extend EventType with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 事件类型 → 字符串（用于与规则 events 字段比对）
pub fn EventType::to_string(self : EventType) -> String {
  match self {
    Create => "create"
    Modify => "modify"
    Delete => "delete"
    Rename => "rename"
    Attrib => "attrib"
    All => "all"
  }
}

///|
/// 事件类型 ← 字符串（解析规则 events 字段）
pub fn EventType::from_string(s : String) -> EventType? {
  match s {
    "create" => Some(Create)
    "modify" => Some(Modify)
    "delete" => Some(Delete)
    "rename" => Some(Rename)
    "attrib" => Some(Attrib)
    "all" => Some(All)
    _ => None
  }
}

///|
/// 条件规格（Layer2 的 AND 条件原子；完整组合见 rx all_of）
#derive(Eq, Debug)
pub(all) struct ConditionSpec {
  /// 条件种类：size_gt / name_contains / ...
  kind : String
  /// 条件表达式（随 kind 解释）
  expr : String
}

///|
pub extend ConditionSpec with Eq::{not_equal, equal}

///|
pub extend ConditionSpec with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 构造条件规格
pub fn ConditionSpec::new(kind : String, expr : String) -> ConditionSpec {
  { kind, expr, }
}

///|
/// 动作规格（声明式动作；具体执行见 action 包，语义化而非裸命令）
#derive(Eq, Debug)
pub(all) struct ActionSpec {
  /// 动作种类：command / mcp_tool_call / webhook / internal
  kind : String
  /// command 的 argv（一律不走 shell）
  argv : Array[String]?
  /// mcp tool 名 / webhook url
  target : String?
  /// 原始 payload / json 文本
  body : String?
  /// 产物 TTL（秒，0 = 不过期，默认 0）
  ttl : Int32
  /// 清理动作：trash（移入回收目录）/ rm（直接删除，默认 trash）
  cleanup : String
}

///|
pub extend ActionSpec with Eq::{not_equal, equal}

///|
pub extend ActionSpec with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 构造动作规格
pub fn ActionSpec::new(
  kind : String,
  argv : Array[String]?,
  target : String?,
  body : String?,
) -> ActionSpec {
  { kind, argv, target, body, ttl: 0, cleanup: "trash", }
}

///|
/// 单条规则
#derive(Eq, Debug)
pub(all) struct Rule {
  /// 规则唯一 id
  id : String
  /// 事件类型名：create/modify/delete/rename/attrib/all
  events : Array[String]
  /// 文件 glob
  patterns : Array[String]
  /// 排除 glob（优先于 patterns）
  exclude : Array[String]
  /// Layer2 条件（AND）
  condition : ConditionSpec?
  /// 命中后要执行的动作
  actions : Array[ActionSpec]
  /// EP-06 预留：命中后是否停止后续规则
  stop_after : Bool
  /// 优先级（高优先级先执行，默认 0）
  /// 优先级范围：
  ///   - 100+ : Critical（关键规则，必须优先执行）
  ///   - 50-99 : High（高优先级规则）
  ///   - 0-49  : Medium（普通优先级规则）
  ///   - -50-(-1) : Low（低优先级规则）
  ///   - -100- : Debug（调试规则）
  priority : Int32
}

///|
/// 优先级级别
#derive(Eq, Debug)
pub(all) enum PriorityLevel {
  Critical // 100+
  High // 50-99
  Medium // 0-49
  Low // -50-(-1)
  Debug // -100-
}

///|
pub extend PriorityLevel with Eq::{not_equal, equal}

///|
pub extend PriorityLevel with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 根据优先级值获取优先级级别
pub fn PriorityLevel::from_priority(priority : Int32) -> PriorityLevel {
  if priority >= 100 {
    Critical
  } else if priority >= 50 {
    High
  } else if priority >= 0 {
    Medium
  } else if priority >= -50 {
    Low
  } else {
    Debug
  }
}

///|
/// 优先级级别 → 字符串
pub fn PriorityLevel::to_string(self : PriorityLevel) -> String {
  match self {
    Critical => "Critical"
    High => "High"
    Medium => "Medium"
    Low => "Low"
    Debug => "Debug"
  }
}

///|
/// 优先级级别 → 颜色（用于日志输出）
pub fn PriorityLevel::color(self : PriorityLevel) -> String {
  match self {
    Critical => "🔴"
    High => "🟠"
    Medium => "🟡"
    Low => "🔵"
    Debug => "⚪"
  }
}

///|
pub extend Rule with Eq::{not_equal, equal}

///|
pub extend Rule with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 构造规则
pub fn Rule::new(
  id : String,
  events : Array[String],
  patterns : Array[String],
  exclude : Array[String],
  condition : ConditionSpec?,
  actions : Array[ActionSpec],
  stop_after : Bool,
  priority : Int32,
) -> Rule {
  { id, events, patterns, exclude, condition, actions, stop_after, priority, }
}

///|
/// 日志配置
#derive(Eq, Debug)
pub(all) struct LoggingConfig {
  /// 是否启用日志（默认 true）
  enabled : Bool
  /// 日志文件目录（默认空字符串，表示使用监控目录）
  log_dir : String
  /// 日志文件名（默认 "mcp-watcher.log"）
  log_file : String
}

///|
pub extend LoggingConfig with Eq::{not_equal, equal}

///|
pub extend LoggingConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 构造日志配置（默认启用，日志文件名为 mcp-watcher.log）
pub fn LoggingConfig::new() -> LoggingConfig {
  { enabled: true, log_dir: "", log_file: "mcp-watcher.log", }
}

///|
/// 顶层配置（对应一份 .mcp-watch.json）
#derive(Eq, Debug)
pub(all) struct Config {
  /// 配置 schema 版本
  schema_version : Int32
  /// 监控实例 id
  watch_id : String
  /// 被监控目录
  watch_dir : String
  /// 是否递归
  recursive : Bool
  /// 去抖时长（毫秒）
  debounce_ms : Int32
  /// 规则表
  rules : Array[Rule]
  /// 命令执行白名单（显式声明的程序名，如 ["cmd","git"]）
  ///
  /// 安全语义（2026-11-17 修正）：默认空 = 不执行任何命令。
  /// 不再从规则 argv[0] 自动收集——"规则写什么就自动放行什么"会架空白名单。
  /// 规则含 command 动作但白名单为空时，validate_config 给出警告。
  allowed_programs : Array[String]
  /// EP-07 预留：扩展声明（占位，v1.0 仅解析不生效）
  extensions : Array[String]
  /// 日志配置
  logging : LoggingConfig
}

///|
pub extend Config with Eq::{not_equal, equal}

///|
pub extend Config with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 从文件读取并解析配置
///
/// 参数：
///   path - 配置文件路径
///
/// 返回：配置（成功）或错误信息（失败）
pub fn Config::from_json_file(path : String) -> Result[Config, String] {
  match @mon.fs_read_text(path) {
    Ok(text) => Config::from_json(text)
    Err(e) =>
      Err("读取配置文件失败: " + path + " (" + fs_error_text(e) + ")")
  }
}

///|
/// 把 rx 的 FsError 转成可读文本
fn fs_error_text(e : @mon.FsError) -> String {
  match e {
    @mon.FsError::NotFound => "NotFound"
    @mon.FsError::Io => "Io"
    @mon.FsError::OutOfMemory => "OutOfMemory"
  }
}
