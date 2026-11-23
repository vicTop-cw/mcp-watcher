/// 建表 DDL 与初始化（vector-index-design §3）
///
/// fs_nodes：元数据主表，主键为规范化绝对路径（/ 分隔）；
///   rowid 为 INTEGER PRIMARY KEY AUTOINCREMENT（FTS5 外部/内容表通过 rowid 关联）。
/// fs_fts：FTS5 倒排（contentless 变体，由索引层显式同步，事务内原子，
///   与 external-content + 触发器语义等价；规避 SQLite 表达式中取末段的兼容风险）。
/// meta：索引元数据（schema_version / walk_state / node_count / error_count / last_error）。
pub fn init_schema(db : @sqlite.Database) -> Unit {
  // 兼容性：PRAGMA 失败不致命（WAL 不可用时回退 journal 默认）
  let _ = db.exec("PRAGMA journal_mode=WAL")
  let _ = db.exec("PRAGMA synchronous=NORMAL")
  let _ = db.exec(
    "CREATE TABLE IF NOT EXISTS fs_nodes (rowid INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL UNIQUE, rel_path TEXT NOT NULL, parent TEXT, depth INTEGER NOT NULL, type TEXT NOT NULL, size INTEGER NOT NULL DEFAULT 0, mtime INTEGER NOT NULL DEFAULT 0, ctime INTEGER NOT NULL DEFAULT 0, ext TEXT NOT NULL DEFAULT '', embedding BLOB)"
  )
  let _ = db.exec("CREATE INDEX IF NOT EXISTS idx_parent ON fs_nodes(parent)")
  let _ = db.exec("CREATE INDEX IF NOT EXISTS idx_type_ext ON fs_nodes(type, ext)")
  let _ = db.exec("CREATE INDEX IF NOT EXISTS idx_mtime ON fs_nodes(mtime)")
  let _ = db.exec(
    "CREATE VIRTUAL TABLE IF NOT EXISTS fs_fts USING fts5(path, name, rel_path, content='', tokenize='unicode61 remove_diacritics 0')"
  )
  let _ = db.exec(
    "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
  )
}

/// 记录内置 schema 版本（配置 schema_version 保持 1，见 §4.2）
pub fn meta_schema_version() -> String {
  "1"
}
