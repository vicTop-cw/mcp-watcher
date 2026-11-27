// index 包 native 回归网（防自噬 / 全量建库 / 增量事件 / FTS5 组合过滤 / meta）
//
// 全部使用真实 SQLite 与真实目录，测试结束清理，
// 避免把“设计承诺”留在 README 里却没有回归网。

///|
fn enabled_cfg() -> @config.IndexConfig {
  {
    enabled: true,
    db_path: "",
    include_glob: [],
    exclude: [],
    embed: @config.EmbedConfig::new(),
  }
}

///|
fn mk_opts(
  keyword : String,
  node_type : String,
  ext : String,
  min_size : Int64,
  max_size : Int64,
  limit : Int,
) -> @index.SearchOptions {
  {
    keyword,
    node_type,
    ext,
    min_size,
    max_size,
    mtime_after: 0L,
    mtime_before: 0L,
    limit,
  }
}

///|
fn lines_contains(lines : Array[String], needle : String) -> Bool {
  for line in lines {
    if line == needle {
      return true
    }
  }
  false
}

///|
async fn setup_base(name : String) -> String {
  let cwd = @env.current_dir().unwrap()
  let base = cwd + "/index/." + name
  let _ = @fs.rmdir(base, recursive=true, allow_missing=true) catch { _ => () }
  let _ = @fs.mkdir(base, recursive=true, allow_exist=true)
  base
}

///|
async test "exclude: db itself, WAL/SHM and builtin dirs are skipped" {
  let base = setup_base("index-test-exclude")
  defer (@fs.rmdir(base, recursive=true, allow_missing=true) catch { _ => () })
  let cfg = enabled_cfg()
  let dbp = base + "/.mcp-watch-index.db"
  let file = base + "/keep.md"
  assert_true(@index.should_skip(cfg, dbp, dbp, ".mcp-watch-index.db", false))
  assert_true(@index.should_skip(cfg, dbp, dbp + "-wal", ".mcp-watch-index.db-wal", false))
  assert_true(@index.should_skip(cfg, dbp, dbp + "-shm", ".mcp-watch-index.db-shm", false))
  assert_true(@index.should_skip(cfg, dbp, base + "/.git", ".git", true))
  assert_true(@index.should_skip(cfg, dbp, base + "/.mcp-watcher-trash", ".mcp-watcher-trash", true))
  assert_true(@index.should_skip(cfg, dbp, base + "/node_modules", "node_modules", true))
  assert_true(@index.should_skip(cfg, dbp, base + "/temp", "temp", true))
  assert_false(@index.should_skip(cfg, dbp, file, "keep.md", false))
}

///|
async test "schema: init and meta round-trip" {
  let db = @sqlite.Database::open(":memory:").unwrap()
  defer db.close()
  @index.init_schema(db)
  assert_true(@index.meta_schema_version() == "1")
  @index.set_meta(db, "walk_state", "done")
  assert_true(@index.get_meta(db, "walk_state") == Some("done"))
  assert_true(@index.node_count(db) == 0L)
}

///|
async test "full_walk: build index and query with combined filters" {
  let base = setup_base("index-test-walk")
  defer (@fs.rmdir(base, recursive=true, allow_missing=true) catch { _ => () })
  let _ = @fs.mkdir(base + "/sub", recursive=true, allow_exist=true)
  let _ = @fs.mkdir(base + "/.git", recursive=true, allow_exist=true)
  let _ = @fs.mkdir(base + "/.mcp-watcher-trash", recursive=true, allow_exist=true)
  @fs.write_file(base + "/note.md", "x")
  @fs.write_file(base + "/sub/detail.rs", "xy")
  @fs.write_file(base + "/.git/config", "hidden")
  @fs.write_file(base + "/.mcp-watcher-trash/old.tmp", "hidden")
  match @index.open_index(base, enabled_cfg(), true) {
    Err(_) => assert_true(false)
    Ok(h) => {
      assert_true(@index.node_count(h.db) == 3L)
      let st = @index.status_lines(h)
      assert_true(lines_contains(st, "index.walk_state=done"))
      let note = @index.search(h.db, mk_opts("note", "file", "md", 0L, 0L, 10))
      assert_true(note.length() == 1)
      assert_true(note[0].rel_path == "note.md")
      let rust = @index.search(h.db, mk_opts("detail", "file", "rs", 2L, 10L, 10))
      assert_true(rust.length() == 1)
      assert_true(rust[0].rel_path == "sub/detail.rs")
      let dirs = @index.search(h.db, mk_opts("", "dir", "", 0L, 0L, 10))
      assert_true(dirs.length() == 1)
      assert_true(dirs[0].rel_path == "sub")
      let too_big = @index.search(h.db, mk_opts("detail", "file", "rs", 3L, 0L, 10))
      assert_true(too_big.length() == 0)
      @index.close(h)
    }
  }
}

///|
async test "apply_event: create modify delete keep index in sync" {
  let base = setup_base("index-test-events")
  defer (@fs.rmdir(base, recursive=true, allow_missing=true) catch { _ => () })
  @fs.write_file(base + "/seed.md", "x")
  match @index.open_index(base, enabled_cfg(), true) {
    Err(_) => assert_true(false)
    Ok(h) => {
      assert_true(@index.node_count(h.db) == 1L)
      @fs.write_file(base + "/new.md", "x")
      @index.apply_event(
        h,
        @watch.FsEvent::new(@config.EventType::Create, base + "/new.md", false, 0, 1),
      )
      assert_true(@index.node_count(h.db) == 2L)
      @fs.write_file(base + "/new.md", "xy")
      @index.apply_event(
        h,
        @watch.FsEvent::new(@config.EventType::Modify, base + "/new.md", false, 0, 2),
      )
      assert_true(@index.node_count(h.db) == 2L)
      // --- 临时诊断（跑完即删） ---
      let mut diag = ""
      let st_t = h.db.prepare(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      )
      if st_t is Some(s) {
        while s.step() {
          diag = diag + bytes_to_str(s.column_text(1)) + "|"
        }
        s.finalize()
      }
      let (dsql, _db) = build_sql(mk_opts("new.md", "", "", 0L, 0L, 0))
      let dprep = match h.db.prepare(dsql) {
        Some(_) => "ok"
        None => "prepare-none"
      }
      println("DIAG tables=" + diag + " prep=" + dprep + " sql=" + dsql)
      let hit = @index.search(h.db, mk_opts("new.md", "", "", 0L, 0L, 0))
      assert_true(hit.length() == 1)
      @index.apply_event(
        h,
        @watch.FsEvent::new(@config.EventType::Delete, base + "/new.md", false, 0, 0),
      )
      assert_true(@index.node_count(h.db) == 1L)
      let gone = @index.search(h.db, mk_opts("new.md", "", "", 0L, 0L, 0))
      assert_true(gone.length() == 0)
      @index.close(h)
    }
  }
}
