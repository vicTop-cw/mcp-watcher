/// SQLite 连接管理、事务封装与 meta 表读写（vector-index-design §3.1 / §5）

/// 打开（或创建）SQLite 库；失败返回 None（调用方按"索引旁路降级"处理）
pub fn open(path : String) -> @sqlite.Database? {
  @sqlite.Database::open(path)
}

/// 事务控制（调用方保证配对；失败时错误计数由事件层上报）
/// 注：daqing/sqlite 版本间 API 名有差异，用显式 SQL 保证可移植
pub fn txn_begin(db : @sqlite.Database) -> Bool {
  db.exec("BEGIN")
}
pub fn txn_commit(db : @sqlite.Database) -> Bool {
  db.exec("COMMIT")
}
pub fn txn_rollback(db : @sqlite.Database) -> Bool {
  db.exec("ROLLBACK")
}

/// 读取 meta 值；不存在返回 None
pub fn get_meta(db : @sqlite.Database, key : String) -> String? {
  let stmt = db.prepare("SELECT value FROM meta WHERE key = ?")
  if stmt is None {
    return None
  }
  let st = stmt.unwrap()
  let _ = st.bind(1, @sqlite.SqlValue::Text(@utf8.encode(key)))
  if st.step() {
    let v = db_bytes_to_str(st.column_text(0))
    st.finalize()
    Some(v)
  } else {
    st.finalize()
    None
  }
}

/// 写入 meta（INSERT OR REPLACE）
pub fn set_meta(db : @sqlite.Database, key : String, value : String) -> Unit {
  let stmt = db.prepare("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)")
  if stmt is None {
    return
  }
  let st = stmt.unwrap()
  let _ = st.bind(1, @sqlite.SqlValue::Text(@utf8.encode(key)))
  let _ = st.bind(2, @sqlite.SqlValue::Text(@utf8.encode(value)))
  let _ = st.execute()
  st.finalize()
}

/// 错误计数 +1 并记录最近错误文本
pub fn record_error(db : @sqlite.Database, msg : String) -> Unit {
  let cur = get_meta(db, "error_count")
  let n = if cur is None { 0L } else { parse_int64(cur.unwrap()).unwrap_or(0L) }
  set_meta(db, "error_count", (n + 1L).to_string())
  set_meta(db, "last_error", msg)
}

pub fn error_count(db : @sqlite.Database) -> Int64 {
  let cur = get_meta(db, "error_count")
  if cur is None { 0L } else { parse_int64(cur.unwrap()).unwrap_or(0L) }
}

/// 节点总数（供 status 展示与增量校验对比）
pub fn node_count(db : @sqlite.Database) -> Int64 {
  let stmt = db.query("SELECT count(*) FROM fs_nodes")
  if stmt is None {
    return 0L
  }
  let st = stmt.unwrap()
  if st.step() {
    let n = st.column(0)
    st.finalize()
    match n {
      @sqlite.SqlValue::Int64(v) => v
      @sqlite.SqlValue::Int(v) => v.to_int64()
      _ => 0L
    }
  } else {
    st.finalize()
    0L
  }
}

/// Bytes -> UTF-8 String（与 upsert.mbt 的同名辅助区分）
fn db_bytes_to_str(b : Bytes) -> String {
  @utf8.decode_lossy(b)
}

fn parse_int64(s : String) -> Int64? {
  // MoonBit 无直接 to_int64? 解析；用 debug/捕获 fallback 简单实现
  let b = @utf8.encode(s)
  if b.length() == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if b[0] == 45 { // '-'
    neg = true
    i = 1
  }
  let mut v = 0L
  while i < b.length() {
    let c = b[i]
    if c < 48 || c > 57 {
      return None
    }
    v = v * 10L + (c - 48).to_int64()
    i = i + 1
  }
  if neg { Some(-v) } else { Some(v) }
}
