// ============================================================================
// watch · 文件系统事件类型（与 rx WatchEvent 思路对齐；native 后端待接入）
// ============================================================================

///|
/// 监控错误
#derive(Eq, Debug)
pub(all) enum WatchError {
  /// 路径不存在
  NotFound(String)
  /// 平台不支持（native 后端占位时）
  Unsupported(String)
  /// IO 错误
  Io(String)
}

///|
pub extend WatchError with Eq::{not_equal, equal}

///|
pub extend WatchError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 构造「路径不存在」错误
pub fn WatchError::not_found(path : String) -> WatchError {
  WatchError::NotFound(path)
}

///|
/// 构造「IO 错误」
pub fn WatchError::io(msg : String) -> WatchError {
  WatchError::Io(msg)
}

///|
/// 文件系统事件（mcp-watcher 内部统一事件模型）
#derive(Eq, Debug)
pub(all) struct FsEvent {
  /// 事件类型
  event_type : @config.EventType
  /// 绝对路径
  path : String
  /// 是否目录
  is_dir : Bool
  /// 修改时间（秒）
  mtime : Int32
  /// 大小（字节）
  size : Int32
}

///|
pub extend FsEvent with Eq::{not_equal, equal}

///|
pub extend FsEvent with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 构造文件系统事件
pub fn FsEvent::new(
  event_type : @config.EventType,
  path : String,
  is_dir : Bool,
  mtime : Int32,
  size : Int32,
) -> FsEvent {
  { event_type, path, is_dir, mtime, size, }
}
