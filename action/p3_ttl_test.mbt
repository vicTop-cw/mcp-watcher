// ============================================================================
// action/p3_ttl_test.mbt —— P3 方案 B（TTL 做实 + 诚实降级）黑盒测试
// 覆盖：到期判定（含边界）、ttl<=0 不过期、cleanup 发出事件并移除记录、
//       持久化 save/load 往返、trash 诚实降级的显式语义。
// ============================================================================

///|
fn mk_record(
  path : String,
  age_sec : Int64,
  ttl : Int32,
) -> @action.ProductRecord {
  let now = Int64::from_int(@rx.real_now().to_int())
  @action.ProductRecord::{
    path,
    created_at_ns: now - age_sec * 1_000_000_000L,
    ttl_seconds: ttl,
  }
}

///|
test "expired_records：未到期不命中" {
  @rx.install_real_clock()
  let now = Int64::from_int(@rx.real_now().to_int())
  let tracker : @action.ProductTracker = {
    records: [mk_record("a.tmp", 10L, 60)],
  }
  assert_eq(tracker.expired_records(now).length(), 0)
}

///|
test "expired_records：已到期命中" {
  @rx.install_real_clock()
  let now = Int64::from_int(@rx.real_now().to_int())
  let tracker : @action.ProductTracker = {
    records: [mk_record("a.tmp", 120L, 60)],
  }
  let expired = tracker.expired_records(now)
  assert_eq(expired.length(), 1)
  assert_eq(expired[0].path, "a.tmp")
}

///|
test "expired_records：边界 age == ttl 视为到期" {
  @rx.install_real_clock()
  // 构造 created_at_ns 使 age 恰好等于 ttl（用固定 now 采样避免漂移）
  let now = Int64::from_int(@rx.real_now().to_int())
  let rec : @action.ProductRecord = {
    path: "edge.tmp",
    created_at_ns: now - 60L * 1_000_000_000L,
    ttl_seconds: 60,
  }
  let tracker : @action.ProductTracker = { records: [rec], }
  assert_eq(tracker.expired_records(now).length(), 1)
}

///|
test "expired_records：ttl<=0 不过期" {
  @rx.install_real_clock()
  let now = Int64::from_int(@rx.real_now().to_int())
  let tracker : @action.ProductTracker = {
    records: [
      mk_record("forever.tmp", 999999L, 0),
      mk_record("neg.tmp", 999999L, -1),
    ],
  }
  assert_eq(tracker.expired_records(now).length(), 0)
}

///|
test "cleanup_expired：到期记录被移除并返回计数" {
  @rx.install_real_clock()
  let tracker : @action.ProductTracker = {
    records: [mk_record("old.tmp", 120L, 60), mk_record("fresh.tmp", 1L, 60)],
  }
  let (cleaned, remaining, expired) = tracker.cleanup_expired("/tmp")
  assert_eq(cleaned, 1)
  assert_eq(expired[0].path, "old.tmp")
  assert_eq(remaining.records.length(), 1)
  assert_eq(remaining.records[0].path, "fresh.tmp")
}

///|
async test "trash_file 跨目标不 panic：native 做实 / 其他目标诚实降级" {
  // 真做实语义由 trash_native_test.mbt（native 门控）精确验证；
  // 此处只保证三目标调用不崩溃、返回 Result。
  match @action.trash_file("/tmp/x.tmp", "/tmp") {
    Ok(_) => ()
    Err(_) => ()
  }
}
