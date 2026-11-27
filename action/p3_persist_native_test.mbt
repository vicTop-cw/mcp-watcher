// ============================================================================
// action/p3_persist_native_test.mbt —— P3 持久化往返测试（native 专属）
//
// ProductTracker::save / load 走 @mon.fs_write_atomic / fs_read_text，
// 这两个 API 依赖 native C FFI（wasm/js 无文件系统），故本文件用 moon.pkg
// options.targets 门控为 native 专属，避免非 native 目标误跑。
// ============================================================================

///|
fn mk_rec(path : String, age_sec : Int64, ttl : Int32) -> @action.ProductRecord {
  let now = @rx.real_now().to_int().to_int64()
  @action.ProductRecord::{
    path,
    created_at_ns: now - age_sec * 1_000_000_000L,
    ttl_seconds: ttl,
  }
}

///|
test "save/load 往返：追踪表持久化后恢复" {
  @rx.install_real_clock()
  let tracker : @action.ProductTracker = {
    records: [mk_rec("persist.tmp", 10L, 3600)],
  }
  let path = "tests/harness/.p3-tracker-test.jsonl"
  match tracker.save(path) {
    Err(_) => assert_true(false)
    Ok(_) => ()
  }
  let loaded = @action.ProductTracker::load(path)
  assert_eq(loaded.records.length(), 1)
  assert_eq(loaded.records[0].path, "persist.tmp")
  assert_eq(loaded.records[0].ttl_seconds, 3600)
  let _ = @mon.fs_remove(path)
}

///|
test "load：文件不存在时返回空表（不崩溃）" {
  let tracker = @action.ProductTracker::load("E:/nonexistent-dir/nope.jsonl")
  assert_eq(tracker.records.length(), 0)
}
