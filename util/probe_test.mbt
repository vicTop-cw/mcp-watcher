// ============================================================================
// rx 接入探针 —— 验证 mcp-watcher 对 rx-mbt 的 R1~R4 实际可消费性
//
// 关键 MoonBit 语法约束（实测确认）：
//   泛型类型跨包引用必须带**完整类型标注**，
//   直接写 `@rx.EventBus[Int]::new()` 会被解析为「值 EventBus」而报
//   "Value EventBus not found in package `rx`"。
//   正确写法：`let x : @rx.EventBus[Int] = @rx.EventBus::new()`
//
// 另：MoonBit 跨包无法直接构造结构体字面量（`@pkg.Type{..}` 不支持），
//      必须走包内构造器（`@pkg.Type::new(..)`）或包内已导出的伴生函数。
// ============================================================================

///|
/// R1 · 真实时钟：注入后 real_now 返回 epoch 毫秒
///
/// 语义要点（rx 侧设计）：real_now 在**未调用 install_real_clock 时**
/// 返回默认虚拟时钟值（占位语义，保证既有确定性测试不受影响）；
/// 必须先 install_real_clock() 才切到真实墙钟。
test "R1: install_real_clock 后 real_now 返回正的 epoch 毫秒" {
  @rx.install_real_clock()
  let now = @rx.real_now()
  assert_true(now > 1_600_000_000_000L)
  @rx.uninstall_real_clock()
}

///|
/// R4 · EventBus：发布 / 订阅闭环
test "R4: EventBus 发布订阅闭环" {
  let bus : @rx.EventBus[Int] = @rx.EventBus::new()
  let counter : Ref[Int] = Ref::Ref(0)
  let _ = bus.subscribe("demo.*", fn(ev : @rx.TriggerEvent[Int]) {
    counter.val = counter.val + ev.payload
  })
  bus.publish("demo.hit", 5)
  bus.publish("demo.hit", 7)
  assert_eq(counter.val, 12)
}

///|
/// R4 · TriggerRegistry：泛型类型可跨包实例化
test "R4: TriggerRegistry 可跨包实例化" {
  let reg : @rx.TriggerRegistry[Int] = @rx.TriggerRegistry::new()
  let seen : Ref[Int] = Ref::Ref(0)
  let _ = reg.register("a.*", fn(_ : @rx.TriggerEvent[Int]) { seen.val = seen.val + 1 })
  reg.fire("a.b", 1)
  assert_eq(seen.val, 1)
}
