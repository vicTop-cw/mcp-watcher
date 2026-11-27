/// 全量 walk 建库（显式栈，避免深目录栈溢出；断点/增量校验，vector-index-design §5.2）
///
/// P0 断点语义：
///   - 分批事务（每批提交并写 meta.walk_state = 当前目录）
///   - 中断重跑以 INSERT OR REPLACE 幂等覆盖（不产生重复节点）
///   - 已有库且 meta.walk_state = "done"、节点数 > 0 时跳过全量，直接进入增量

pub struct WalkResult {
  dirs : Int64
  files : Int64
}

priv struct WalkItem {
  dir : String
  rel : String
  depth : Int
}

/// 清空旧索引（rebuild / 首次建库）
fn clear_index(db : @sqlite.Database) -> Unit {
  let _ = db.exec("DELETE FROM fs_fts")
  let _ = db.exec("DELETE FROM fs_nodes")
}

const WALK_BATCH : Int = 512

/// 全量 walk；返回目录/文件计数
pub fn full_walk(
  db : @sqlite.Database,
  watch_dir : String,
  cfg : @config.IndexConfig,
  db_path : String,
) -> WalkResult {
  clear_index(db)
  let _ = txn_begin(db)
  let mut dirs = 0L
  let mut files = 0L
  let mut batch = 0
  let stack : Array[WalkItem] = [{ dir: watch_dir, rel: ".", depth: 0 }]
  while stack.length() > 0 {
    let item = stack.pop().unwrap()
    let d = normalize_slash(item.dir)
    let rel = item.rel
    let depth = item.depth
    // 防自噬 / 排除在入栈时已检查；此处再查自身（watch_dir 本身不排除）
    let items = list_dir(d)
    for it in items {
      let is_dir = it.has_suffix("/")
      let name = if is_dir { it[0:it.length() - 1].to_owned() } else { it }
      let child = d + "/" + name
      let child_rel = if rel == "." { name } else { rel + "/" + name }
      if should_skip(cfg, db_path, child, child_rel, is_dir) {
        continue
      }
      let info = stat_path(child)
      match info {
        None => continue
        Some(i) => {
          if i.is_dir {
            let _ = upsert_node(
              db, child, child_rel, Some(d), depth + 1, "dir", 0L, i.mtime, i.ctime, ""
            )
            stack.push({ dir: child, rel: child_rel, depth: depth + 1 })
            dirs = dirs + 1L
          } else {
            let _ = upsert_node(
              db, child, child_rel, Some(d), depth + 1, "file", i.size, i.mtime,
              i.ctime, ext_of(child),
            )
            files = files + 1L
          }
          batch = batch + 1
          if batch >= WALK_BATCH {
            let _ = txn_commit(db)
            set_meta(db, "walk_state", d)
            let _ = txn_begin(db)
            batch = 0
          }
        }
      }
    }
  }
  let _ = txn_commit(db)
  set_meta(db, "walk_state", "done")
  set_meta(db, "node_count", (dirs + files).to_string())
  { dirs: dirs, files: files }
}
