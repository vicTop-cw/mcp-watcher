/// index 包门面：打开建库 / 句柄 / 状态（vector-index-design §5.1 / §4.3）
///
/// 启动流程（run_daemon / start 在事件监控启动**前**调用 open_index 完成建库，
///   防止增量事件丢失窗口；建库失败 → 返回 Err，调用方按"索引旁路降级"处理）。

pub(all) struct IndexHandle {
  db : @sqlite.Database
  watch_dir : String
  cfg : @config.IndexConfig
  db_path : String
}

/// 解析 db_path：配置为空时默认 `<watch_dir>/.mcp-watch-index.db`
pub fn resolve_db_path(watch_dir : String, cfg : @config.IndexConfig) -> String {
  if cfg.db_path == "" {
    normalize_slash(watch_dir) + "/.mcp-watch-index.db"
  } else {
    normalize_slash(cfg.db_path)
  }
}

/// 打开/创建索引库并完成建库与全量 walk（或增量校验跳过全量）
pub fn open_index(
  watch_dir : String,
  cfg : @config.IndexConfig,
  rebuild : Bool,
) -> Result[IndexHandle, String] {
  let db_path = resolve_db_path(watch_dir, cfg)
  // 父目录不存在则创建（创建失败即校验失败）
  let parent = parent_path(db_path)
  match parent {
    Some(p) => {
      if !ensure_dir(p) {
        return Err("索引库父目录创建失败: " + p)
      }
    }
    None => ()
  }
  match @sqlite.Database::open(db_path) {
    None => Err("SQLite 打开失败: " + db_path)
    Some(db) => {
      init_schema(db)
      let state = get_meta(db, "walk_state")
      let cnt = node_count(db)
      if rebuild || state != Some("done") || cnt == 0L {
        let _ = full_walk(db, watch_dir, cfg, db_path)
        set_meta(db, "schema_version", meta_schema_version())
      }
      let h : IndexHandle = {
        db: db,
        watch_dir: watch_dir,
        cfg: cfg,
        db_path: db_path,
      }
      Ok(h)
    }
  }
}

/// 句柄状态信息（status 展示基础版，§4.3）
pub fn status_lines(h : IndexHandle) -> Array[String] {
  let state = get_meta(h.db, "walk_state").unwrap_or("unknown")
  let err = get_meta(h.db, "last_error").unwrap_or("")
  [
    "index.enabled=true",
    "index.db=" + h.db_path,
    "index.nodes=" + node_count(h.db).to_string(),
    "index.walk_state=" + state,
    "index.error_count=" + error_count(h.db).to_string(),
    if err == "" { "index.last_error=(none)" } else { "index.last_error=" + err },
  ]
}

/// 关闭句柄（SQLite close）
pub fn close(h : IndexHandle) -> Unit {
  let _ = h.db.close()
}

/// 父路径（绝对路径的上一级；根/盘符返回 None）
fn parent_path(path : String) -> String? {
  let p = normalize_slash(path)
  let idx = p.rev_find("/")
  match idx {
    None => None
    Some(i) => {
      if i <= 0 {
        None
      } else {
        Some(p[0:i].to_owned())
      }
    }
  }
}
