// ============================================================================
// config · 声明式规则 DSL 模型（与 config-schema.md 契约对齐）
//
// 这是"声明式规则系统"支柱的数据骨架：事件 + glob + 条件 + 动作。
// 解析采用手动提取（与 rx-mbt 一致），不使用 @json derive，规避派生不确定性。
// ============================================================================

// ----------------------------------------------------------------------------
// 共享默认值常量（硬编码收敛 · 2026-11-20 排查修复）
// DSL 缺省语义见 config-schema.md；值保持向后兼容，只收敛字面量。
// ----------------------------------------------------------------------------

///|
/// ActionSpec.ttl 缺省（秒；0 = 永久不过期）
pub const DEFAULT_TTL_SECONDS = 0

///|
/// ActionSpec.cleanup 缺省（产物回收模式：trash / none）
pub const DEFAULT_CLEANUP_MODE = "trash"

///|
/// webhook / mcp_tool_call / internal 动作超时缺省（毫秒）
pub const DEFAULT_ACTION_TIMEOUT_MS = 5000

///|
/// mcp_tool_call.transport 缺省
pub const DEFAULT_MCP_TRANSPORT = "stdio"

///|
/// guard.on_fail 缺省（守卫不过时的处理：skip / stop）
pub const DEFAULT_GUARD_ON_FAIL = "skip"

///|
/// acceptance.expect_exit 缺省（期望退出码）
pub const DEFAULT_EXPECT_EXIT = 0

///|
/// LoggingConfig.log_file 缺省
pub const DEFAULT_LOG_FILE = "mcp-watcher.log"

///|
/// 优先级分档阈值（有业务语义，见 PriorityLevel 注释）
const PRIORITY_CRITICAL_MIN = 100
const PRIORITY_HIGH_MIN = 50
const PRIORITY_MEDIUM_MIN = 0
const PRIORITY_LOW_MIN = -50

///|
/// Config 顶层默认值（Config::default / 规则文件缺省字段）
const DEFAULT_SCHEMA_VERSION = 1
const DEFAULT_RECURSIVE = true
const DEFAULT_DEBOUNCE_MS = 0

///|
/// EP-03b：interval 触发源（events 条目 "interval:<ms>"）最小触发间隔（毫秒）。
/// 下限防误配亚秒级定时器风暴；loader 校验与 scheduler 取值共用此常量。
pub const INTERVAL_MIN_MS : Int64 = 1000

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
  /// EP-03b：interval 触发源合成事件类型——不来自文件系统，仅由
  /// @rx.interval 定时发射；from_string 不收裸 "interval"（间隔必须带
  /// ":ms" 后缀，见 loader 校验）
  Interval
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
  /// 产物无效（验收门不过，schema v1.1；PLAN-gates.md §一）
  Invalid
  /// 人工/规则记日志（EP-01a internal op log_event）
  Logged
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
    Invalid => "product.invalid"
    Logged => "product.logged"
  }
}

///|
/// 生命周期事件类型 ← 字符串
pub fn LifecycleEventType::from_string(s : String) -> LifecycleEventType? {
  match s {
    "created" => Some(Created)
    "expired" => Some(Expired)
    "destroyed" => Some(Destroyed)
    "invalid" => Some(Invalid)
    "logged" => Some(Logged)
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
    Interval => "interval"
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
/// 验收门规格（schema v1.1  ActionSpec 可选字段  PLAN-gates.md §一）
///
/// 全部缺省时等价于 v1.0 的 `exit_code == 0` 判定。
/// 字段语义（与计划文档逐条对齐）：
///   - expect_exit：exit_code == expect_exit
///   - stdout_contains：stdout 包含每一项（AND）
///   - stdout_not_contains：stdout 不含任何一项
///   - stderr_not_contains：stderr 不含任何一项
///   - artifact_glob：相对 watch_dir 的 glob，至少命中 1 个文件
#derive(Eq, Debug)
pub(all) struct AcceptanceSpec {
  /// 期望退出码（缺省 0）
  expect_exit : Int32
  /// stdout 必须包含每一项（AND）
  stdout_contains : Array[String]
  /// stdout 不得包含任何一项
  stdout_not_contains : Array[String]
  /// stderr 不得包含任何一项
  stderr_not_contains : Array[String]
  /// 相对 watch_dir 的 glob（无 = 不做该检查）
  artifact_glob : String?
}

///|
pub extend AcceptanceSpec with Eq::{not_equal, equal}

///|
pub extend AcceptanceSpec with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 构造验收门规格
pub fn AcceptanceSpec::new(
  expect_exit : Int32,
  stdout_contains : Array[String],
  stdout_not_contains : Array[String],
  stderr_not_contains : Array[String],
  artifact_glob : String?,
) -> AcceptanceSpec {
  {
    expect_exit,
    stdout_contains,
    stdout_not_contains,
    stderr_not_contains,
    artifact_glob,
  }
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
  /// 验收门（schema v1.1，仅 command 动作；None = v1.0 行为不变）
  acceptance : AcceptanceSpec?
  /// internal 动作的 op 名（EP-01a；internal 必选，其余 kind 禁止携带）
  op : String?
  /// internal log_event 的日志消息（支持 schema §7 占位符；仅 internal）
  message : String?
  /// webhook: 目标 URL（schema §5；运行时按 §7 占位符展开）
  url : String?
  /// webhook: GET / POST（缺省 POST；解析层已归一为大写）
  /// 注：字段名 http_method（method 为 MoonBit 保留字）
  http_method : String?
  /// webhook: 附加请求头（原始 JSON object 文本；None = 无附加头）
  headers_json : String?
  /// webhook / mcp_tool_call: 超时（毫秒，缺省 5000）
  timeout_ms : Int32
  /// mcp_tool_call: server 程序名（进 allowed_programs 白名单）
  server : String?
  /// mcp_tool_call: 工具调用 args（原始 JSON object 文本；运行时按 §7 占位符展开）
  mcp_args_json : String?
  /// mcp_tool_call: server 命令行参数（EP-01c；spawn argv = [server] + server_args，不走 shell）
  server_args : Array[String]?
  /// mcp_tool_call: transport stdio / sse / http（缺省 stdio）
  transport : String?
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
  acceptance : AcceptanceSpec?,
) -> ActionSpec {
  {
    kind, argv, target, body, ttl: DEFAULT_TTL_SECONDS, cleanup: DEFAULT_CLEANUP_MODE,
    acceptance, op: None, message: None,
    url: None, http_method: None, headers_json: None, timeout_ms: DEFAULT_ACTION_TIMEOUT_MS,
    server: None, mcp_args_json: None, server_args: None, transport: None,
  }
}

///|
/// 构造 webhook 动作规格（EP-01b · schema §5）
pub fn ActionSpec::new_webhook(
  url : String,
  http_method : String?,
  headers_json : String?,
  body : String?,
  timeout_ms : Int32,
) -> ActionSpec {
  {
    kind: "webhook",
    argv: None,
    target: None,
    body,
    ttl: DEFAULT_TTL_SECONDS,
    cleanup: DEFAULT_CLEANUP_MODE,
    acceptance: None,
    op: None,
    message: None,
    url: Some(url),
    http_method,
    headers_json,
    timeout_ms,
    server: None,
    mcp_args_json: None,
    server_args: None,
    transport: None,
  }
}

///|
/// 构造 mcp_tool_call 动作规格（EP-01c · schema §5；tool 复用 target 字段）
pub fn ActionSpec::new_mcp(
  server : String,
  tool : String,
  mcp_args_json : String?,
  server_args : Array[String]?,
  timeout_ms : Int32,
) -> ActionSpec {
  {
    kind: "mcp_tool_call",
    argv: None,
    target: Some(tool),
    body: None,
    ttl: DEFAULT_TTL_SECONDS,
    cleanup: DEFAULT_CLEANUP_MODE,
    acceptance: None,
    op: None,
    message: None,
    url: None,
    http_method: None,
    headers_json: None,
    timeout_ms,
    server: Some(server),
    mcp_args_json,
    server_args,
    transport: Some(DEFAULT_MCP_TRANSPORT),
  }
}

///|
/// 构造 internal 动作规格（EP-01a）
pub fn ActionSpec::new_internal(op : String, message : String?) -> ActionSpec {
  {
    kind: "internal",
    argv: None,
    target: None,
    body: None,
    ttl: DEFAULT_TTL_SECONDS,
    cleanup: DEFAULT_CLEANUP_MODE,
    acceptance: None,
    op: Some(op),
    message,
    url: None,
    http_method: None,
    headers_json: None,
    timeout_ms: DEFAULT_ACTION_TIMEOUT_MS,
    server: None,
    mcp_args_json: None,
    server_args: None,
    transport: None,
  }
}

///|
/// 守卫门规格（schema v1.1  Rule 可选字段  PLAN-gates.md §二）
///
/// guard 是一条**必须 exit 0** 的单命令（复用 run_command + ExecPolicy 白名单，
/// argv 同样进白名单校验，不走 shell）。通过才执行 actions；不通过按 on_fail：
///   - "skip"（缺省）：记 guard_fail 事件并跳过本次动作，规则存活
///   - "stop"：记 guard_fail 事件并停止本规则后续处理（规则退场）
///
/// **不做组合逻辑**：需要 AND/OR 的守卫用条件层组合，guard 保持单命令——
/// 防止长成规则里套规则的策略引擎（红线）。
#derive(Eq, Debug)
pub(all) struct GuardSpec {
  /// guard 命令 argv（白名单校验同 command 动作；绝不 shell 拼接）
  argv : Array[String]
  /// 失败处理："skip"（缺省）/ "stop"
  on_fail : String
}

///|
pub extend GuardSpec with Eq::{not_equal, equal}

///|
pub extend GuardSpec with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 构造守卫门规格
pub fn GuardSpec::new(argv : Array[String], on_fail : String) -> GuardSpec {
  { argv, on_fail, }
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
  /// 守卫门（schema v1.1，执行前环境准入；None = v1.0 行为不变）
  /// 注：JSON 键为 "guard"；本字段名用 guard_spec（guard 为 MoonBit 保留字）
  guard_spec : GuardSpec?
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
  if priority >= PRIORITY_CRITICAL_MIN {
    Critical
  } else if priority >= PRIORITY_HIGH_MIN {
    High
  } else if priority >= PRIORITY_MEDIUM_MIN {
    Medium
  } else if priority >= PRIORITY_LOW_MIN {
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
  guard_spec : GuardSpec?,
) -> Rule {
  {
    id,
    events,
    patterns,
    exclude,
    condition,
    actions,
    stop_after,
    priority,
    guard_spec,
  }
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
  { enabled: true, log_dir: "", log_file: DEFAULT_LOG_FILE, }
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
