/// 事件增量：upsert / delete / rename（vector-index-design §5.3 / §3.5）
///
/// 约定：单节点操作在调用方提供的**事务**内完成（walk 分批事务、事件单事务）；
///   fts 同步与元数据同事务，保证原子一致。
use @sqlite
use @config
use @json

/// stat FFI 返回解析
pub struct StatInfo {
  ok : Bool
  is_dir : Bool
  size : Int64
  mtime : Int64
  ctime : Int64
}

extern "C" fn index_list_dir(path : Bytes) -> Bytes = "moonbit_index_list_dir"
extern "C" fn index_stat(path : Bytes) -> Bytes = "moonbit_index_stat"
extern "C" fn index_mkdir(path : Bytes) -> Bytes = "moonbit_index_mkdir"

/// 列目录（目录条目带 "/" 后缀）
pub fn list_dir(path : String) -> Array[String] {
  let out : Array[String] = []
  let raw = index_list_dir(path.as_bytes())
  if raw.length() == 0 {
    return out
  }
  let txt = bytes_to_str(raw)
  parse_json_str_array(txt, out)
}

/// stat 路径
pub fn stat_path(path : String) -> StatInfo? {
  let raw = index_stat(path.as_bytes())
  if raw.length() == 0 {
    return None
  }
  let txt = bytes_to_str(raw)
  let obj = @json.Json::parse(txt)
  match obj {
    Some(j) => {
      let d = j.as_object()
      if d is None {
        return None
      }
      let map = d.unwrap()
      let ok = get_bool(map, "ok")
      if not ok {
        return None
      }
      Some({
        ok: true,
        is_dir: get_bool(map, "is_dir"),
        size: get_int(map, "size"),
        mtime: get_int(map, "mtime"),
        ctime: get_int(map, "ctime"),
      } : StatInfo)
    }
    None => None
  }
}

/// 递归创建目录（父目录不存在则创建）
pub fn ensure_dir(path : String) -> Bool {
  let raw = index_mkdir(path.as_bytes())
  raw.length() > 0 && bytes_to_str(raw) == "{\"ok\":1}"
}

/// upsert 节点（已在事务内）；返回实际 rowid
pub fn upsert_node(
  db : @sqlite.Database,
  path : String,
  rel_path : String,
  parent : String?,
  depth : Int,
  node_type : String,
  size : Int64,
  mtime : Int64,
  ctime : Int64,
  ext : String,
) -> Int64 {
  // 旧 rowid（保持稳定，避免 fts 残留）
  let old_rowid = rowid_of(db, path)
  var rowid = 0L
  let parent_sql = match parent {
    Some(p) => p
    None => ""
  }
  if old_rowid is Some(v) {
    let rowid_val = v.unwrap()
    let stmt = db.prepare(
      "INSERT OR REPLACE INTO fs_nodes(rowid, path, rel_path, parent, depth, type, size, mtime, ctime, ext) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    )
    if stmt is Some(st0) {
      let st = st0
      let _ = st.bind(1, @sqlite.SqlValue::Int64(rowid_val))
      let _ = st.bind(2, @sqlite.SqlValue::Text(path.as_bytes()))
      let _ = st.bind(3, @sqlite.SqlValue::Text(rel_path.as_bytes()))
      let _ = st.bind(4, if parent is Some(p) { @sqlite.SqlValue::Text(p.as_bytes()) } else { @sqlite.SqlValue::Null })
      let _ = st.bind(5, @sqlite.SqlValue::Int(depth))
      let _ = st.bind(6, @sqlite.SqlValue::Text(node_type.as_bytes()))
      let _ = st.bind(7, @sqlite.SqlValue::Int64(size))
      let _ = st.bind(8, @sqlite.SqlValue::Int64(mtime))
      let _ = st.bind(9, @sqlite.SqlValue::Int64(ctime))
      let _ = st.bind(10, @sqlite.SqlValue::Text(ext.as_bytes()))
      let _ = st.execute()
      st.finalize()
    }
    rowid = rowid_val
    fts_upsert(db, rowid, path, rel_path)
  } else {
    let stmt = db.prepare(
      "INSERT INTO fs_nodes(path, rel_path, parent, depth, type, size, mtime, ctime, ext) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)"
    )
    if stmt is Some(st0) {
      let st = st0
      let _ = st.bind(1, @sqlite.SqlValue::Text(path.as_bytes()))
      let _ = st.bind(2, @sqlite.SqlValue::Text(rel_path.as_bytes()))
      let _ = st.bind(3, if parent is Some(p) { @sqlite.SqlValue::Text(p.as_bytes()) } else { @sqlite.SqlValue::Null })
      let _ = st.bind(4, @sqlite.SqlValue::Int(depth))
      let _ = st.bind(5, @sqlite.SqlValue::Text(node_type.as_bytes()))
      let _ = st.bind(6, @sqlite.SqlValue::Int64(size))
      let _ = st.bind(7, @sqlite.SqlValue::Int64(mtime))
      let _ = st.bind(8, @sqlite.SqlValue::Int64(ctime))
      let _ = st.bind(9, @sqlite.SqlValue::Text(ext.as_bytes()))
      let _ = st.execute()
      st.finalize()
    }
    rowid = db.last_insert_rowid()
    fts_upsert(db, rowid, path, rel_path)
  }
  rowid
}

/// 按 path 查 rowid
fn rowid_of(db : @sqlite.Database, path : String) -> Int64? {
  let stmt = db.prepare("SELECT rowid FROM fs_nodes WHERE path = ?")
  if stmt is None {
    return None
  }
  let st = stmt.unwrap()
  let _ = st.bind(1, @sqlite.SqlValue::Text(path.as_bytes()))
  if st.step() {
    let v = st.column(0)
    st.finalize()
    match v {
      @sqlite.SqlValue::Int64(x) => Some(x)
      @sqlite.SqlValue::Int(x) => Some(x.to_int64())
      _ => None
    }
  } else {
    st.finalize()
    None
  }
}

/// upsert 文件/目录（自动 stat；目录已存在则只刷新元数据）
pub fn upsert_path(
  db : @sqlite.Database,
  cfg : @config.IndexConfig,
  db_path : String,
  watch_dir : String,
  path : String,
) -> Unit {
  let info = stat_path(path)
  match info {
    None => return
    Some(i) => {
      if should_skip(cfg, db_path, path, rel_of(watch_dir, path), i.is_dir) {
        return
      }
      let rel = rel_of(watch_dir, path)
      let depth = depth_of(path) - depth_of(watch_dir)
      let parent = parent_of(path)
      let ty = if i.is_dir { "dir" } else { "file" }
      let ext = if i.is_dir { "" } else { ext_of(path) }
      let _ = upsert_node(
        db, path, rel, parent, depth, ty, i.size, i.mtime, i.ctime, ext
      )
      // 目录：子文件夹内嵌补扫（§5.3）
      if i.is_dir {
        walk_subtree(db, cfg, db_path, watch_dir, path, rel, depth)
      }
    }
  }
}

/// 删除节点（级联子树）；已在事务内
pub fn delete_path(db : @sqlite.Database, path : String) -> Unit {
  let rows = select_rows_under(db, path)
  for r in rows {
    fts_delete(db, r)
  }
  let stmt = db.prepare("DELETE FROM fs_nodes WHERE path = ? OR path LIKE ? || '/%'")
  if stmt is Some(st0) {
    let st = st0
    let _ = st.bind(1, @sqlite.SqlValue::Text(path.as_bytes()))
    let _ = st.bind(2, @sqlite.SqlValue::Text(path.as_bytes()))
    let _ = st.execute()
    st.finalize()
  }
}

/// rename 单事务原子迁移（§3.5）：调用方已 BEGIN，本函数不自行提交
pub fn rename_node(
  db : @sqlite.Database,
  watch_dir : String,
  old_path : String,
  new_path : String,
) -> Unit {
  // 冲突处理：目标已存在 → 先删除（级联），全在事务内
  delete_path(db, new_path)
  let old = normalize_slash(old_path)
  let new = normalize_slash(new_path)
  // 受影响行（自身 + 子树）
  let rows = select_under_rows(db, old)
  let delta = depth_of(new) - depth_of(old)
  for r in rows {
    let oldp = r.0
    let rel = r.1
    let depth = r.2
    let suffix = if oldp == old {
      ""
    } else {
      oldp.substring(start=old.length(), end=oldp.length())
    }
    let newp = new + suffix
    // parent 需要重算：newp 的父目录 = 上一级路径；直接按段截取
    let new_parent = parent_of(newp)
    let new_rel = rel_of(watch_dir, newp)
    let new_depth = depth + delta
    let stmt = db.prepare("UPDATE fs_nodes SET path = ?, parent = ?, rel_path = ?, depth = ? WHERE path = ?")
    if stmt is Some(st0) {
      let st = st0
      let _ = st.bind(1, @sqlite.SqlValue::Text(newp.as_bytes()))
      let _ = st.bind(2, match new_parent {
        Some(p) => @sqlite.SqlValue::Text(p.as_bytes())
        None => @sqlite.SqlValue::Null
      })
      let _ = st.bind(3, @sqlite.SqlValue::Text(new_rel.as_bytes()))
      let _ = st.bind(4, @sqlite.SqlValue::Int(new_depth))
      let _ = st.bind(5, @sqlite.SqlValue::Text(oldp.as_bytes()))
      let _ = st.execute()
      st.finalize()
    }
    // fts 同步：删除旧词条 + 插入新词条
    let rowid = rowid_of(db, oldp)
    if rowid is Some(v) {
      fts_delete(db, v.unwrap())
      fts_upsert(db, v.unwrap(), newp, new_rel)
    }
  }
}

/// 子树补扫（目录 create / 事件内嵌）；已在事务内
fn walk_subtree(
  db : @sqlite.Database,
  cfg : @config.IndexConfig,
  db_path : String,
  watch_dir : String,
  dir : String,
  rel : String,
  depth : Int,
) -> Unit {
  let items = list_dir(dir)
  for item in items {
    let is_dir = item.ends_with("/")
    let name = if is_dir { item.substring(start=0, end=item.length() - 1) } else { item }
    let child = normalize_slash(dir) + "/" + name
    let child_rel = if rel == "." { name } else { rel + "/" + name }
    if should_skip(cfg, db_path, child, child_rel, is_dir) {
      continue
    }
    let info = stat_path(child)
    match info {
      None => continue
      Some(i) => {
        let ty = if i.is_dir { "dir" } else { "file" }
        let ext = if i.is_dir { "" } else { ext_of(child) }
        let _ = upsert_node(
          db, child, child_rel, Some(dir), depth + 1, ty, i.size, i.mtime, i.ctime, ext
        )
        if i.is_dir {
          walk_subtree(db, cfg, db_path, watch_dir, child, child_rel, depth + 1)
        }
      }
    }
  }
}

/// 相对 watch_dir 的路径（watch_dir 自身为 "."）
pub fn rel_of(watch_dir : String, path : String) -> String {
  let w = normalize_slash(watch_dir)
  let p = normalize_slash(path)
  if p == w {
    return "."
  }
  if p.length() > w.length() && p.substring(start=0, end=w.length()) == w {
    if p[w.length()] == '/' {
      return p.substring(start=w.length() + 1, end=p.length())
    }
  }
  // watch_dir 外（如规则文件目录补监控）按绝对路径段转相对展示
  p
}

/// 父目录路径（根返回 None）
fn parent_of(path : String) -> String? {
  let p = normalize_slash(path)
  let idx = p.rindex('/')
  match idx {
    None => None
    Some(i) => {
      if i <= 0 {
        None
      } else {
        Some(p.substring(start=0, end=i))
      }
    }
  }
}

/// 小写扩展名（不含点；dir 调用方置 "")
fn ext_of(path : String) -> String {
  let leaf = path_leaf(path)
  let idx = leaf.rindex('.')
  match idx {
    None => ""
    Some(i) => {
      if i == 0 {
        ""
      } else {
        leaf.substring(start=i + 1, end=leaf.length()).to_lower()
      }
    }
  }
}

/// 受影响行（自身 + 子树）：(path, rel_path, depth)
fn select_under_rows(db : @sqlite.Database, path : String) -> Array[(String, String, Int)] {
  let out : Array[(String, String, Int)] = []
  let stmt = db.prepare(
    "SELECT path, rel_path, depth FROM fs_nodes WHERE path = ? OR path LIKE ? || '/%' ORDER BY depth"
  )
  if stmt is Some(st0) {
    let st = st0
    let _ = st.bind(1, @sqlite.SqlValue::Text(path.as_bytes()))
    let _ = st.bind(2, @sqlite.SqlValue::Text(path.as_bytes()))
    while st.step() {
      let p = bytes_to_str(st.column_text(0))
      let r = bytes_to_str(st.column_text(1))
      let d = match st.column(2) {
        @sqlite.SqlValue::Int(x) => x
        _ => 0
      }
      out.push((p, r, d))
    }
    st.finalize()
  }
  out
}

/// 受影响 rowid（delete 用）
fn select_rows_under(db : @sqlite.Database, path : String) -> Array[Int64] {
  let out : Array[Int64] = []
  let stmt = db.prepare(
    "SELECT rowid FROM fs_nodes WHERE path = ? OR path LIKE ? || '/%'"
  )
  if stmt is Some(st0) {
    let st = st0
    let _ = st.bind(1, @sqlite.SqlValue::Text(path.as_bytes()))
    let _ = st.bind(2, @sqlite.SqlValue::Text(path.as_bytes()))
    while st.step() {
      match st.column(0) {
        @sqlite.SqlValue::Int64(v) => out.push(v)
        @sqlite.SqlValue::Int(v) => out.push(v.to_int64())
        _ => ()
      }
    }
    st.finalize()
  }
  out
}

/// fts 同步（contentless：显式 INSERT OR REPLACE / DELETE）
fn fts_upsert(db : @sqlite.Database, rowid : Int64, path : String, rel : String) -> Unit {
  let stmt = db.prepare(
    "INSERT OR REPLACE INTO fs_fts(rowid, path, name, rel_path) VALUES(?, ?, ?, ?)"
  )
  if stmt is Some(st0) {
    let st = st0
    let _ = st.bind(1, @sqlite.SqlValue::Int64(rowid))
    let _ = st.bind(2, @sqlite.SqlValue::Text(path.as_bytes()))
    let _ = st.bind(3, @sqlite.SqlValue::Text(path_leaf(path).as_bytes()))
    let _ = st.bind(4, @sqlite.SqlValue::Text(rel.as_bytes()))
    let _ = st.execute()
    st.finalize()
  }
}

fn fts_delete(db : @sqlite.Database, rowid : Int64) -> Unit {
  let stmt = db.prepare("DELETE FROM fs_fts WHERE rowid = ?")
  if stmt is Some(st0) {
    let st = st0
    let _ = st.bind(1, @sqlite.SqlValue::Int64(rowid))
    let _ = st.execute()
    st.finalize()
  }
}

/// 解析 FFI JSON
fn get_bool(m : @json.JsonObject, key : String) -> Bool {
  match m.get(key) {
    Some(j) => j.as_bool().unwrap_or(false)
    None => false
  }
}

fn get_int(m : @json.JsonObject, key : String) -> Int64 {
  match m.get(key) {
    Some(j) => {
      match j.as_number() {
        Some(n) => n.to_int64()
        None => 0L
      }
    }
    None => 0L
  }
}

fn parse_json_str_array(txt : String, out : Array[String]) -> Array[String] {
  match @json.Json::parse(txt) {
    Some(j) => {
      match j.as_array() {
        Some(arr) => {
          for item in arr {
            match item.as_string() {
              Some(s) => out.push(s)
              None => ()
            }
          }
          out
        }
        None => out
      }
    }
    None => out
  }
}

/// Bytes -> UTF-8 String（action 包同款解码）
fn bytes_to_str(b : Bytes) -> String {
  @utf8.decode_lossy(b)
}
