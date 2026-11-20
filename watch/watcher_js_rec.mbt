// ============================================================================
// watch · js 递归监控源（EP-03 修复）
//
// 缺陷：rx monitor 的 js `watch_folder` 只挂单层 fs.watch（FFI 不带
// recursive 选项），js daemon 的 `recursive` 配置在 rx_watch_source 被丢弃
// ——子目录（如 .fist-mbt/data/*.db）永远收不到事件。
//
// 本文件在 mcp-watcher 侧补齐：自带 recursive FFI（node fs.watch
// {persistent:true, recursive:true}，Windows/macOS 支持；Linux 不支持
// recursive 时启动失败 → Observable 报错，可诊断）。
//
// 设计约束（沿用 rx monitor 同款模式，实测可行）：
//   - 句柄注册表走独立命名空间 __mcpw_watch_*，不与 rx 的 __rxmbt_watch_*
//     共享（两套订阅各自 dispose，互不干扰）。
//   - recursive 模式下 fs.watch 的 filename 携带相对子路径（Windows 下为
//     反斜杠），统一归一为 "/"，供上层 glob 匹配。
//   - extern "js" 声明在非 js 目标仅作声明不链接（rx watcher_js.mbt 同款，
//     native 构建已验证可行）；调用点被 #cfg(target="js") 守住。
// ============================================================================

///|
/// js 递归监控整个文件夹（子目录变更也触发）。
fn watch_folder_recursive(
  path : String,
) -> @rx.Observable[@mon.WatchEvent, @mon.WatchError] {
  @rx.Observable::new(fn(
    observer : @rx.Observer[@mon.WatchEvent, @mon.WatchError],
  ) -> @rx.Subscription {
    let id = ffi_watch_start_rec(path, fn(id, kind_tag, ts, raw, fname) {
      let _ = id
      let full = if fname == "" {
        path
      } else {
        join_rel(path, fname)
      }
      let kind = match kind_tag {
        0 => @mon.WatchKind::Created
        1 => @mon.WatchKind::Modified
        2 => @mon.WatchKind::Removed
        _ => @mon.WatchKind::Other
      }
      observer.on_next({ path: full, kind, timestamp: ts, raw, })
    })
    if id < 0L {
      let err = ffi_watch_last_error_rec()
      observer.on_error(@mon.WatchError::NotFound(err))
      return @rx.Subscription::empty()
    }
    @rx.Subscription::new(fn() { ffi_watch_stop_rec(id) })
  })
}

///|
/// 拼接监控根路径与回调给出的相对文件名（"/" 分隔，与 rx join_path 同款）。
fn join_rel(root : String, rel : String) -> String {
  if root.has_suffix("/") || root.has_suffix("\\") {
    root + rel
  } else {
    root + "/" + rel
  }
}

// ---------------------------------------------------------------------------
// FFI：node fs.watch（recursive）封装
// 回调签名与 rx monitor 一致：(watcherId, kindTag, timestampMs, raw, filename)
//   kindTag: 0=Created 1=Modified 2=Removed 3=Other
//   filename: 相对监控根的路径，"\" 已归一为 "/"（根级事件为 ""）
// ---------------------------------------------------------------------------

///|
extern "js" fn ffi_watch_start_rec(
  path : String,
  cb : (Int64, Int64, Int64, String, String) -> Unit,
) -> Int64 =
  #| (path, cb) => { const G = globalThis; if (G.__mcpw_watch_err === undefined) { G.__mcpw_watch_err = ""; } if (G.__mcpw_watch_reg === undefined) { G.__mcpw_watch_reg = new Map(); G.__mcpw_watch_seq = 0; } try { const id = G.__mcpw_watch_seq++; const fs = process.getBuiltinModule("node:fs"); const pathMod = process.getBuiltinModule("node:path"); const sep = pathMod.sep; const watcher = fs.watch(path, { persistent: true, recursive: true }, (et, fn) => { const rel = (fn === null) ? "" : String(fn).replace(/\\/g, "/"); let target = path; if (rel !== "") { target = (path.endsWith("/") || path.endsWith("\\")) ? (path + rel) : (path + sep + rel); } let kind = 3; if (et === "change") { kind = 1; } else if (fs.existsSync(target)) { kind = 0; } else { kind = 2; } cb(BigInt(id), BigInt(kind), BigInt(Date.now()), et, rel); }); G.__mcpw_watch_reg.set(id, watcher); return BigInt(id); } catch (e) { G.__mcpw_watch_err = String(e && e.message || e); return BigInt(-1); } }

///|
/// 停止并释放递归 watcher 句柄（key 用 Number(id) 归一，防 BigInt 不等）。
extern "js" fn ffi_watch_stop_rec(id : Int64) -> Unit =
  #| (id) => { const G = globalThis; if (G.__mcpw_watch_reg === undefined) { return; } const key = Number(id); const w = G.__mcpw_watch_reg.get(key); if (w !== undefined) { try { w.close(); } catch (_e) {} G.__mcpw_watch_reg.delete(key); } }

///|
extern "js" fn ffi_watch_last_error_rec() -> String =
  #| () => { const G = globalThis; return (G.__mcpw_watch_err === undefined) ? "" : G.__mcpw_watch_err; }
