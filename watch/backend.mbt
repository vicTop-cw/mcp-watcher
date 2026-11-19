// ============================================================================
// watch · 事件源后端（接入 rx monitor）
//
// P0 实现期：本文件把 rx 的 `monitor.watch_folder` 封装成 mcp-watcher 的
// 事件源，保留 `WatchSource` trait 作为**多后端扩展位**（EP-01）：
//   - native 后端：rx monitor（Windows ReadDirectoryChangesW 内核事件）
//   - js 后端：rx monitor（node fs.watch）
//   - 其余目标：占位后端（返回可诊断错误）
//
// ⚠️ 关键架构约束（rx 侧实测确认）：
//   rx 的 `watch_folder` **订阅闭包是同步阻塞的**（轮询循环在 subscribe_fn 内），
//   一旦 subscribe 就会占住当前线程直到 Subscription 被 dispose。
//   ⇒ 调用方**必须在独立的后台 async 任务中 subscribe**，
//     否则事件循环会被监控源独占（mcp-watcher 的「常驻自治」直接失效）。
//   ⇒ 本文件提供 `spawn_watch_task` 封装该语义，调用方不应直接 subscribe。
//
// ⚠️ MoonBit 语法约束（实测确认）：
//   rx 的泛型类型跨包引用**必须带完整类型标注**，直接写
//   `@rx.Observable[FsEvent, WatchError]::new()` 会被解析为「值 Observable」
//   而报 "Value Observable not found in package `rx`"。
// ============================================================================

///|
/// 事件源扩展点：不同平台的监控后端
///
/// 保留为 trait 是刻意的——rx 未来可能提供 inotify / FSEvents 后端，
/// 本项目不应把「用哪个后端」写死在调用方。
pub trait WatchSource {
  fn watch(self : Self, path : String, recursive : Bool) -> Result[
    Unit,
    WatchError,
  ]
}

///|
/// 占位后端（无 rx 监控能力的目标使用）
pub struct PlaceholderBackend {}

///|
pub extend PlaceholderBackend with WatchSource::{watch}

///|
pub impl WatchSource for PlaceholderBackend with fn watch(
  self : PlaceholderBackend,
  path : String,
  recursive : Bool,
) -> Result[Unit, WatchError] {
  let _ = (self, path, recursive)
  Err(
    WatchError::Unsupported(
      "watch 后端在当前目标不可用（rx monitor 仅提供 js / native 后端）",
    ),
  )
}

///|
/// rx 后端：委托给 rx monitor 的事件驱动实现
pub struct RxBackend {}

///|
pub extend RxBackend with WatchSource::{watch}

///|
pub impl WatchSource for RxBackend with fn watch(
  self : RxBackend,
  path : String,
  recursive : Bool,
) -> Result[Unit, WatchError] {
  let _ = (self, path, recursive)
  // rx 的 watch_folder 返回 Observable 而非 Result；真正的订阅在
  // subscribe_watch 中进行（后台 async 任务），这里只做可用性检查。
  let _ = rx_probe_backend(path)
  Ok(())
}

///|
/// native/js：构造 rx 监控源（可用性探测）
#cfg(any(target="native", target="js"))
fn rx_probe_backend(
  path : String,
) -> @rx.Observable[@mon.WatchEvent, @mon.WatchError] {
  @mon.watch_folder(path)
}

///|
/// 其余目标：无 rx 监控能力
#cfg(not(any(target="native", target="js")))
fn rx_probe_backend(
  path : String,
) -> @rx.Observable[@mon.WatchEvent, @mon.WatchError] {
  let _ = path
  @rx.Observable::new(fn(
    observer : @rx.Observer[@mon.WatchEvent, @mon.WatchError],
  ) -> @rx.Subscription {
    observer.on_error(
      @mon.WatchError::Unsupported("当前目标无文件监控能力"),
    )
    @rx.Subscription::empty()
  })
}

///|
/// native / js 后端：委托给 rx monitor
#cfg(any(target="native", target="js"))
fn backend_impl(path : String, recursive : Bool) -> Result[Unit, WatchError] {
  let backend : RxBackend = RxBackend::{ }
  backend.watch(path, recursive)
}

///|
/// 其余目标：占位后端
#cfg(not(any(target="native", target="js")))
fn backend_impl(path : String, recursive : Bool) -> Result[Unit, WatchError] {
  let backend : PlaceholderBackend = PlaceholderBackend::{ }
  backend.watch(path, recursive)
}

///|
/// 便捷入口：按目标选择后端
pub fn watch_folder(
  path : String,
  recursive : Bool,
) -> Result[Unit, WatchError] {
  backend_impl(path, recursive)
}

///|
/// 把 rx 的 `WatchEvent` 映射为本项目的 `FsEvent`
///
/// 映射表：
///   rx WatchKind::Created  → EventType::Create
///   rx WatchKind::Modified → EventType::Modify
///   rx WatchKind::Removed  → EventType::Delete
///   rx WatchKind::Other    → EventType::Modify（保守默认：不漏事件）
///
/// rx 的事件不携带 mtime / size（那是 stat 的职责），故此处填 0；
/// 需要 mtime/size 的规则应改用 `stat` 动作（EP-01 扩展）而非依赖事件字段。
pub fn from_rx_event(ev : @mon.WatchEvent) -> FsEvent {
  let et = match ev.kind {
    @mon.WatchKind::Created => @config.EventType::Create
    @mon.WatchKind::Modified => @config.EventType::Modify
    @mon.WatchKind::Removed => @config.EventType::Delete
    _ => @config.EventType::Modify
  }
  FsEvent::new(et, ev.path, false, 0, 0)
}

///|
/// 事件名约定：`<事件类型>.<路径 glob 片段>`
///
/// 这是 rx EventBus 的事件名。规则内核据此把 fs 事件路由到对应规则。
pub fn event_name(ev : FsEvent) -> String {
  ev.event_type.to_string() + ".*"
}

///|
/// 订阅 rx 监控源，把 `FsEvent` 投递到事件总线
///
/// ⚠️ **本函数是阻塞的**（rx 的订阅闭包同步阻塞）。
///    调用方**必须**放在独立的后台 async 任务里（见 `spawn_watch_task`）。
///
/// 参数：
///   path        - 监控目录
///   recursive   - 是否递归子目录
///   bus         - 事件总线（泛型类型跨包引用需完整类型标注）
///   debounce_ms - 去抖时长（毫秒，0 = 不去抖）
pub fn subscribe_watch(
  path : String,
  recursive : Bool,
  bus : @rx.EventBus[FsEvent],
  debounce_ms~ : Int64,
) -> Unit {
  let source = rx_watch_source(path, recursive)
  // 去抖在订阅链上做（development-plan §2 修正 #2）：
  // debounce_real 需要真实时钟驱动，且会合并连续事件，只发最后一个。
  let obs = if debounce_ms > 0L {
    source.debounce_real(debounce_ms)
  } else {
    source
  }
  let _ = obs.subscribe_on_next(fn(ev : @mon.WatchEvent) {
    let fe = from_rx_event(ev)
    bus.publish(event_name(fe), fe)
  })
}

///|
/// native：rx 的 native 监控源（Windows ReadDirectoryChangesW 内核事件）
#cfg(target="native")
fn rx_watch_source(
  path : String,
  recursive : Bool,
) -> @rx.Observable[@mon.WatchEvent, @mon.WatchError] {
  @mon.watch_folder_native(path, recursive~)
}

///|
/// js：rx 的 js 监控源（node fs.watch）
#cfg(target="js")
fn rx_watch_source(
  path : String,
  recursive : Bool,
) -> @rx.Observable[@mon.WatchEvent, @mon.WatchError] {
  let _ = recursive
  @mon.watch_folder(path)
}

///|
/// 其余目标：无文件监控能力（返回发出 Unsupported 错误的空流）
#cfg(not(any(target="native", target="js")))
fn rx_watch_source(
  path : String,
  recursive : Bool,
) -> @rx.Observable[@mon.WatchEvent, @mon.WatchError] {
  let _ = (path, recursive)
  @rx.Observable::new(fn(
    observer : @rx.Observer[@mon.WatchEvent, @mon.WatchError],
  ) -> @rx.Subscription {
    observer.on_error(
      @mon.WatchError::Unsupported("当前目标无文件监控能力"),
    )
    @rx.Subscription::empty()
  })
}

///|
/// 启动后台监控任务（**P0 核心入口**）
///
/// 语义：在独立 async 任务中订阅 rx 的 `watch_folder`，把 `FsEvent`
/// 投递到给定的 `EventBus`。**调用方不应直接 subscribe**（会阻塞）。
///
/// 并发模型：用 `moonbitlang/async` 的 TaskGroup 承载后台任务，
/// 任务组退出时自动取消并回收（符合「常驻守护、优雅停机」语义）。
///
/// 参数：
///   path      - 监控目录
///   recursive - 是否递归子目录
///   bus       - 事件总线（泛型类型跨包引用需完整类型标注）
///
/// 返回：后台任务组（调用方在退出前应等待/取消它）
///
/// ⚠️ 调用方必须保证自己也在 async 上下文中调用本函数，
///    否则后台任务没有事件循环驱动。
pub async fn spawn_watch_task(
  path : String,
  recursive : Bool,
  bus : @rx.EventBus[FsEvent],
  debounce_ms~ : Int64,
) -> Unit {
  @async.with_task_group(fn(group : @async.TaskGroup) {
    let _ = group.spawn(fn() {
      subscribe_watch(path, recursive, bus, debounce_ms~)
    })
  })
}

///|
/// 把 rx 的 `WatchError` 映射为本项目的 `WatchError`
pub fn from_rx_error(e : @mon.WatchError) -> WatchError {
  match e {
    @mon.WatchError::NotFound(msg) => WatchError::not_found(msg)
    @mon.WatchError::Io(msg) => WatchError::io(msg)
    _ => WatchError::io("rx monitor 错误")
  }
}
