/// FTS5 关键词检索 + 过滤条件 AND 组合（vector-index-design §6）
///
/// 关键词策略：FTS5 MATCH 命中 + path LIKE '%kw%' 兜底（CJK 分词局限，并集去重）；
///   过滤条件（type/ext/size/mtime）全部 AND 拼接，参数化 bind。
use @sqlite

pub struct SearchOptions {
  keyword : String
  node_type : String // "file" | "dir" | "" 不限
  ext : String // 小写，不含点
  min_size : Int64
  max_size : Int64 // 0 = 不限
  mtime_after : Int64 // 0 = 不限
  mtime_before : Int64 // 0 = 不限
  limit : Int // <=0 表示不限（SQLite LIMIT -1）
}

/// 执行检索，返回 Node 列表（ORDER BY path）
pub fn search(db : @sqlite.Database, opts : SearchOptions) -> Array[Node] {
  let (sql, binds) = build_sql(opts)
  let stmt = db.prepare(sql)
  if stmt is None {
    return []
  }
  let st = stmt.unwrap()
  var i = 1
  for b in binds {
    let _ = st.bind(i, b)
    i = i + 1
  }
  let out : Array[Node] = []
  while st.step() {
    out.push(read_node(st))
  }
  st.finalize()
  out
}

fn read_node(st : @sqlite.Statement) -> Node {
  let p = bytes_to_str(st.column_text(1))
  let r = bytes_to_str(st.column_text(2))
  let par = st.column_text(3)
  let parent = if par.length() == 0 { None } else { Some(bytes_to_str(par)) }
  let dep = match st.column(4) {
    @sqlite.SqlValue::Int(x) => x
    _ => 0
  }
  let ty = bytes_to_str(st.column_text(5))
  let size = int64_col(st, 6)
  let mtime = int64_col(st, 7)
  let ctime = int64_col(st, 8)
  let ext = bytes_to_str(st.column_text(9))
  { path: p, rel_path: r, parent: parent, depth: dep, node_type: ty, size: size, mtime: mtime, ctime: ctime, ext: ext }
}

fn int64_col(st : @sqlite.Statement, idx : Int) -> Int64 {
  match st.column(idx) {
    @sqlite.SqlValue::Int64(v) => v
    @sqlite.SqlValue::Int(v) => v.to_int64()
    _ => 0L
  }
}

/// 构造查询 SQL 与参数
fn build_sql(opts : SearchOptions) -> (String, Array[@sqlite.SqlValue]) {
  let binds : Array[@sqlite.SqlValue] = []
  var where : Array[String] = []
  if opts.keyword != "" {
    // FTS5 MATCH（参数化）
    where.push("(rowid IN (SELECT rowid FROM fs_fts WHERE fs_fts MATCH ?) OR path LIKE ?)")
    binds.push(@sqlite.SqlValue::Text(fts_query(opts.keyword).as_bytes()))
    binds.push(@sqlite.SqlValue::Text(("%" + opts.keyword + "%").as_bytes()))
  }
  if opts.node_type != "" {
    where.push("type = ?")
    binds.push(@sqlite.SqlValue::Text(opts.node_type.as_bytes()))
  }
  if opts.ext != "" {
    where.push("ext = ?")
    binds.push(@sqlite.SqlValue::Text(opts.ext.as_bytes()))
  }
  if opts.min_size > 0L {
    where.push("size >= ?")
    binds.push(@sqlite.SqlValue::Int64(opts.min_size))
  }
  if opts.max_size > 0L {
    where.push("size <= ?")
    binds.push(@sqlite.SqlValue::Int64(opts.max_size))
  }
  if opts.mtime_after > 0L {
    where.push("mtime >= ?")
    binds.push(@sqlite.SqlValue::Int64(opts.mtime_after))
  }
  if opts.mtime_before > 0L {
    where.push("mtime <= ?")
    binds.push(@sqlite.SqlValue::Int64(opts.mtime_before))
  }
  let where_sql = if where.length() == 0 { "1=1" } else { where.join(" AND ") }
  let limit = if opts.limit <= 0 { -1 } else { opts.limit }
  binds.push(@sqlite.SqlValue::Int(limit))
  let sql = "SELECT rowid, path, rel_path, parent, depth, type, size, mtime, ctime, ext FROM fs_nodes WHERE " + where_sql + " ORDER BY path LIMIT ?"
  (sql, binds)
}

/// FTS5 查询串：按空白拆 token，每 token 双引号包裹（短语），AND 连接；
///   token 内双引号替换为空格（防语法注入）。
fn fts_query(kw : String) -> String {
  let tokens = kw.split(" ")
  let parts : Array[String] = []
  for t in tokens {
    let clean = t.replace("\"", " ")
    let trimmed = clean.trim()
    if trimmed != "" {
      parts.push("\"" + trimmed + "\"")
    }
  }
  if parts.length() == 0 {
    "\"" + kw + "\""
  } else {
    parts.join(" AND ")
  }
}
