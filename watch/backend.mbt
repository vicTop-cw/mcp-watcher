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
#cfg(not(any(target="native", target="js")))
pub struct PlaceholderBackend {}

///|
#cfg(not(any(target="native", target="js")))
pub extend PlaceholderBackend with WatchSource::{watch}

///|
#cfg(not(any(target="native", target="js")))
pub impl WatchSource for PlaceholderBackend with fn watch(
  self : PlaceholderBackend,
  path : String,
  recursive : Bool,
) -> Result[Unit, WatchError] {
  let _ = (self, recursive)
  // 走降级版 rx_probe_backend：构造一个立即 on_error 的 Observable，
  // 既表达「当前目标无监控能力」，也让降级分支保持可达（避免死代码告警）。
  let probe : @rx.Observable[@mon.WatchEvent, @mon.WatchError] = rx_probe_backend(
    path,
  )
  let _ = probe
  Err(
    WatchError::Unsupported(
      "watch 后端在当前目标不可用（rx monitor 仅提供 js / native 后端）",
    ),
  )
}

///|
/// rx 后端：委托给 rx monitor 的事件驱动实现
#cfg(any(target="native", target="js"))
pub struct RxBackend {}

///|
#cfg(any(target="native", target="js"))
pub extend RxBackend with WatchSource::{watch}

///|
#cfg(any(target="native", target="js"))
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

// ---------------------------------------------------------------------------
// 多根合并（方案 B · P0 缺陷修复）
//
// 背景：rx 的 watch_folder_native 订阅闭包是**同步阻塞**的（轮询循环内
// Sleep()，永不 yield）。MoonBit 协作式 async 单线程下，with_task_group
// 同时 spawn 多个 watch 任务时，**第一个被调度的任务永久独占执行线程**，
// 其余 watch 任务永远得不到调度（run_daemon 双 watch 缺陷根因）。
//
// 方案 B：不依赖 rx 侧改造，在本包内把「多个监控根」合并为**单个监控任务**
// （取公共祖先目录为唯一 watch 根），事件按 path 前缀过滤投递，等价闭环。
// 入口：
//   · subscribe_watch_multi / spawn_watch_task_multi —— 多根版（run_daemon 用）
//   · subscribe_watch / spawn_watch_task —— 单根版（保持既有签名，委托多根版）
// ---------------------------------------------------------------------------

///|
/// 路径归一：反斜杠转正斜杠、去掉末尾斜杠（Windows 兼容）
fn normalize_slash(p : String) -> String {
  let s = p.replace_all(old="\\", new="/")
  let mut out = s
  while out.has_suffix("/") && out.length() > 1 {
    out = out[:out.length() - 1].to_owned()
  }
  out
}

///|
/// 按 '/' 切分归一化后的路径段
fn split_slash_normalized(p : String) -> Array[String] {
  let out : Array[String] = []
  for sv in normalize_slash(p).split("/") {
    out.push(sv.to_owned())
  }
  out
}

///|
/// 路径是否在根目录之下（含根本身）
pub fn path_under(p : String, root : String) -> Bool {
  let r = normalize_slash(root)
  let q = normalize_slash(p)
  q == r || q.has_prefix(r + "/")
}

///|
/// 路径是否在任一根目录之下
pub fn path_under_any(p : String, roots : Array[String]) -> Bool {
  for r in roots {
    if path_under(p, r) {
      return true
    }
  }
  false
}

///|
/// 多个根的公共祖先目录（None = 无公共前缀，例如跨盘符）
pub fn common_root(roots : Array[String]) -> String? {
  if roots.length() == 0 {
    return None
  }
  let segs : Array[Array[String]] = []
  for r in roots {
    segs.push(split_slash_normalized(r))
  }
  let base = segs[0]
  let common : Array[String] = []
  let mut i = 0
  while i < base.length() {
    let seg = base[i]
    let mut all_match = true
    for other in segs {
      if i >= other.length() || other[i] != seg {
        all_match = false
        break
      }
    }
    if !all_match {
      break
    }
    common.push(seg)
    i = i + 1
  }
  if common.length() == 0 {
    None
  } else {
    Some(common.join("/"))
  }
}

///|
/// 订阅 rx 监控源（多根合并版 · 方案 B）
///
/// 语义：
///   1. 对 roots 求公共祖先，作为**唯一** watch 根（单监控任务）；
///   2. 事件到达后按 path_under_any 过滤，只投递属于任一监控根的事件。
///
/// 无公共前缀（如跨盘符）时降级为只监控第一个根，并打印警告。
pub fn subscribe_watch_multi(
  roots : Array[String],
  recursive : Bool,
  bus : @rx.EventBus[FsEvent],
  debounce_ms~ : Int64,
  paused~ : Ref[Bool] = Ref::Ref(false),
) -> Unit {
  if roots.length() == 0 {
    return
  }
  let watch_root = match common_root(roots) {
    Some(r) => r
    None => {
      // 降级：只监控第一个根（事件可达性受限，如实提示）
      println(
        "⚠️ 监控根无公共前缀（跨盘符？），仅监控第一个根：" +
        roots[0],
      )
      roots[0]
    }
  }
  let source = rx_watch_source(watch_root, recursive)
  // 去抖在订阅链上做（development-plan §2 修正 #2）：
  // debounce_real 需要真实时钟驱动，且会合并连续事件，只发最后一个。
  let obs = if debounce_ms > 0L {
    source.debounce_real(debounce_ms)
  } else {
    source
  }
  let _ = obs.subscribe_on_next(fn(ev : @mon.WatchEvent) {
    // 方案 B 事件过滤：只投递属于任一监控根的事件
    if !path_under_any(ev.path, roots) {
      return
    }
    let fe = from_rx_event(ev)
    // EP-01a 暂停门控：paused 期间事件不投递（resume 后恢复）
    if !paused.val {
      bus.publish(event_name(fe), fe)
    }
  })
}

///|
/// 订阅 rx 监控源，把 `FsEvent` 投递到事件总线
///
/// ⚠️ **本函数是阻塞的**（rx 的订阅闭包同步阻塞）。
///    调用方**必须**放在独立的后台 async 任务里（见 `spawn_watch_task`）。
///
/// 单根版：委托多根合并版（roots=[path]）。
///
/// 参数：
///   path        - 监控目录
///   recursive   - 是否递归子目录
///   bus         - 事件总线（泛型类型跨包引用需完整类型标注）
///   debounce_ms - 去抖时长（毫秒，0 = 不去抖）
///   paused      - 暂停门控（EP-01a；pause_watch 置 true 后事件不投递规则引擎，
///                 resume_watch 恢复；内核级监控持续，暂停期事件被丢弃）
pub fn subscribe_watch(
  path : String,
  recursive : Bool,
  bus : @rx.EventBus[FsEvent],
  debounce_ms~ : Int64,
  paused~ : Ref[Bool] = Ref::Ref(false),
) -> Unit {
  subscribe_watch_multi([path], recursive, bus, debounce_ms~, paused~)
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
/// EP-03 修复：rx 的 js watch_folder 只挂单层（FFI 无 recursive），js daemon
/// 传 recursive=true 时改走本仓递归实现（watcher_js_rec.mbt），子目录事件
/// 不再丢失。
#cfg(target="js")
fn rx_watch_source(
  path : String,
  recursive : Bool,
) -> @rx.Observable[@mon.WatchEvent, @mon.WatchError] {
  if recursive {
    watch_folder_recursive(path)
  } else {
    @mon.watch_folder(path)
  }
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
/// 启动后台监控任务（多根合并版 · **P0 核心入口**）
///
/// 语义：在独立 async 任务中订阅 rx 的 `watch_folder`（取 roots 公共祖先
/// 为唯一 watch 根，事件按路径过滤），把 `FsEvent` 投递到给定的 `EventBus`。
/// **调用方不应直接 subscribe**（会阻塞）。
///
/// 并发模型：用 `moonbitlang/async` 的 TaskGroup 承载后台任务，
/// 任务组退出时自动取消并回收（符合「常驻守护、优雅停机」语义）。
///
/// 参数：
///   roots     - 监控根集合（方案 B：合并为单个监控任务）
///   recursive - 是否递归子目录
///   bus       - 事件总线（泛型类型跨包引用需完整类型标注）
///
/// ⚠️ 调用方必须保证自己也在 async 上下文中调用本函数，
///    否则后台任务没有事件循环驱动。
pub async fn spawn_watch_task_multi(
  roots : Array[String],
  recursive : Bool,
  bus : @rx.EventBus[FsEvent],
  debounce_ms~ : Int64,
  paused~ : Ref[Bool] = Ref::Ref(false),
) -> Unit {
  @async.with_task_group(fn(group : @async.TaskGroup) {
    let _ = group.spawn(fn() {
      subscribe_watch_multi(roots, recursive, bus, debounce_ms~, paused~)
    })
  })
}

///|
/// 启动后台监控任务（单根版）
///
/// 保持既有签名不变，委托多根版（roots=[path]）。
pub async fn spawn_watch_task(
  path : String,
  recursive : Bool,
  bus : @rx.EventBus[FsEvent],
  debounce_ms~ : Int64,
  paused~ : Ref[Bool] = Ref::Ref(false),
) -> Unit {
  spawn_watch_task_multi([path], recursive, bus, debounce_ms~, paused~)
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
