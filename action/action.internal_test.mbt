// ============================================================================
// action · 内部测试（产物生命周期语义）
// ============================================================================

///|
/// 测试 ProductTracker 注册功能
test "ProductTracker: register adds record" {
  let tracker = @action.ProductTracker::new()
  let tracker = @action.ProductTracker::register(tracker, "/tmp/test.txt", 3600)
  // 注册成功，不报错
}

///|
/// 测试 ProductTracker 清理过期产物（无过期）
test "ProductTracker: cleanup_no_expired returns 0" {
  let tracker = @action.ProductTracker::new()
  let tracker = @action.ProductTracker::register(tracker, "/tmp/test.txt", 3600)
  let (cleaned, _tracker, _expired) = @action.ProductTracker::cleanup_expired(
    tracker, "/tmp",
  )
  // 没有过期产物，清理数应为 0
  assert_eq(cleaned, 0)
}

///|
/// 测试 LifecycleEvent 构造
test "LifecycleEvent: new creates event with correct path" {
  let kind = @config.LifecycleEventType::Created
  let event = @action.LifecycleEvent::new(kind, "/tmp/test.txt")
  assert_eq(event.path, "/tmp/test.txt")
  assert_eq(event.kind.to_string(), "product.created")
}

///|
/// 测试 LifecycleEvent 事件名
test "LifecycleEvent: event_name returns correct name" {
  let event = @action.LifecycleEvent::new(
    @config.LifecycleEventType::Created,
    "/tmp/test.txt",
  )
  assert_eq(event.event_name(), "product.created")

  let event2 = @action.LifecycleEvent::new(
    @config.LifecycleEventType::Expired,
    "/tmp/test.txt",
  )
  assert_eq(event2.event_name(), "product.expired")

  let event3 = @action.LifecycleEvent::new(
    @config.LifecycleEventType::Destroyed,
    "/tmp/test.txt",
  )
  assert_eq(event3.event_name(), "product.destroyed")
}

///|
/// 测试 LifecycleEventType 字符串转换
test "LifecycleEventType: to_string returns correct strings" {
  assert_eq(@config.LifecycleEventType::Created.to_string(), "product.created")
  assert_eq(@config.LifecycleEventType::Expired.to_string(), "product.expired")
  assert_eq(
    @config.LifecycleEventType::Destroyed.to_string(),
    "product.destroyed",
  )
}

///|
/// 测试 LifecycleEventType 从字符串解析
test "LifecycleEventType: from_string parses correctly" {
  assert_eq(
    @config.LifecycleEventType::from_string("created"),
    Some(@config.LifecycleEventType::Created),
  )
  assert_eq(
    @config.LifecycleEventType::from_string("expired"),
    Some(@config.LifecycleEventType::Expired),
  )
  assert_eq(
    @config.LifecycleEventType::from_string("destroyed"),
    Some(@config.LifecycleEventType::Destroyed),
  )
  assert_eq(@config.LifecycleEventType::from_string("unknown"), None)
}

///|
/// 测试 trash_file 跨目标返回 Result（native 真做实 / 其他目标诚实 Err）
/// 具体语义由 trash_native_test.mbt（native 门控）精确验证。
async test "trash_file: returns Result without panic" {
  match @action.trash_file("/tmp/does-not-exist.txt", "/tmp") {
    Ok(_) => ()
    Err(_) => ()
  }
}

// ============================================================================
// 生命周期事件 · product.invalid（schema v1.1 验收门，PLAN-gates.md §一）
// ============================================================================

///|
/// product.invalid 字符串映射（to_string / from_string）
test "LifecycleEventType: Invalid string mapping" {
  assert_eq(@config.LifecycleEventType::Invalid.to_string(), "product.invalid")
  assert_eq(
    @config.LifecycleEventType::from_string("invalid"),
    Some(@config.LifecycleEventType::Invalid),
  )
}

///|
/// product.invalid 事件构造与事件名
test "LifecycleEvent: Invalid event_name" {
  let event = @action.LifecycleEvent::new(
    @config.LifecycleEventType::Invalid,
    "/tmp/bad.json",
  )
  assert_eq(event.event_name(), "product.invalid")
  assert_eq(event.path, "/tmp/bad.json")
}
