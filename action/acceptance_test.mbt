// ============================================================================
// action · 验收门纯函数验证（schema v1.1 · PLAN-gates.md §一）
//
// acceptance_check 是纯函数（字符串包含 + 调用方提供的 artifact_hit），
// 三目标均可单测。artifact_glob_hit 的真实目录枚举见
// acceptance_native_test.mbt（native 专属）。
//
// 验收用例映射（最少集）：
//   1. exit 0 + stdout_contains 命中   → accepted=true
//   2. exit 0 + stdout_not_contains 命中 → accepted=false
//   3. exit 0 + artifact_glob 无命中    → accepted=false（artifact_hit=false 注入）
// ============================================================================

///|
/// 默认验收规格（expect_exit=0，其余全空）
fn acc0() -> @config.AcceptanceSpec {
  @config.AcceptanceSpec::new(0, [], [], [], None)
}

///|
/// 用例1：exit 0 + stdout_contains 命中 → accepted=true
test "acceptance_check: exit0 + stdout_contains hit => accepted" {
  let acc = @config.AcceptanceSpec::new(0, ["DONE"], [], [], None)
  let res = @action.acceptance_check(acc, 0, "TASK DONE ok", "", None)
  assert_true(res.accepted)
  assert_eq(res.reason, "")
}

///|
/// stdout_contains 是 AND 语义：每一项都必须命中
test "acceptance_check: stdout_contains requires all items" {
  let acc = @config.AcceptanceSpec::new(0, ["A", "B"], [], [], None)
  let res = @action.acceptance_check(acc, 0, "only A here", "", None)
  assert_false(res.accepted)
  let res2 = @action.acceptance_check(acc, 0, "A and B", "", None)
  assert_true(res2.accepted)
}

///|
/// 用例2：exit 0 + stdout_not_contains 命中 → accepted=false
test "acceptance_check: exit0 + stdout_not_contains hit => rejected" {
  let acc = @config.AcceptanceSpec::new(0, [], ["ERROR"], [], None)
  let res = @action.acceptance_check(acc, 0, "looks ok but ERROR", "", None)
  assert_false(res.accepted)
  assert_true(res.reason.contains("ERROR"))
}

///|
/// stderr_not_contains 命中 → accepted=false
test "acceptance_check: stderr_not_contains hit => rejected" {
  let acc = @config.AcceptanceSpec::new(0, [], [], ["panic"], None)
  let res = @action.acceptance_check(acc, 0, "ok", "thread 'main' panicked", None)
  assert_false(res.accepted)
  assert_true(res.reason.contains("panic"))
}

///|
/// 用例3：exit 0 + artifact_glob 无命中（artifact_hit=false）→ accepted=false
test "acceptance_check: artifact glob no hit => rejected" {
  let acc = @config.AcceptanceSpec::new(0, [], [], [], Some("output/*.json"))
  let res = @action.acceptance_check(acc, 0, "", "", Some(false))
  assert_false(res.accepted)
  assert_true(res.reason.contains("artifact"))
}

///|
/// artifact_glob 命中（artifact_hit=true）→ accepted=true
test "acceptance_check: artifact glob hit => accepted" {
  let acc = @config.AcceptanceSpec::new(0, [], [], [], Some("output/*.json"))
  let res = @action.acceptance_check(acc, 0, "", "", Some(true))
  assert_true(res.accepted)
}

///|
/// expect_exit 缺省 0，实际 1 → accepted=false
test "acceptance_check: expect_exit mismatch => rejected" {
  let res = @action.acceptance_check(acc0(), 1, "", "", None)
  assert_false(res.accepted)
  assert_true(res.reason.contains("expect_exit"))
}

///|
/// expect_exit=1 与实际 1 匹配 → accepted=true
test "acceptance_check: expect_exit=1 matches => accepted" {
  let acc = @config.AcceptanceSpec::new(1, [], [], [], None)
  let res = @action.acceptance_check(acc, 1, "", "", None)
  assert_true(res.accepted)
}

///|
/// 多项失败累积进 reason（一次报全，不做重试）
test "acceptance_check: multiple failures accumulate" {
  let acc = @config.AcceptanceSpec::new(0, ["DONE"], ["ERROR"], [], None)
  let res = @action.acceptance_check(acc, 1, "ERROR here", "", None)
  assert_false(res.accepted)
  assert_true(res.reason.contains("expect_exit"))
  assert_true(res.reason.contains("ERROR"))
}
