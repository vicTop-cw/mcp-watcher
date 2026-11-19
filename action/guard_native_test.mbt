// ============================================================================
// action · 守卫门真实命令验证（native 专属 · PLAN-gates.md §二）
//
// 真实 cmd 命令，验证 run_guard 的 exit 语义：
//   - exit 0 → passed=true
//   - 非零退出 → passed=false，reason 携带退出码
// ============================================================================

///|
fn gnk_ev() -> @watch.FsEvent {
  @watch.FsEvent::new(@config.EventType::Create, "C:/tmp/guard.tmp", false, 0, 0)
}

///|
/// run_guard：exit 0 → passed=true（守卫通过）
test "run_guard: exit 0 => passed" {
  let guard_spec = @config.GuardSpec::new(["cmd", "/c", "echo", "guard-ok"], "skip")
  let policy = @action.build_policy(["cmd"])
  let res = @action.run_guard(guard_spec, gnk_ev(), policy)
  assert_true(res.passed)
  assert_eq(res.reason, "")
}

///|
/// run_guard：非零退出 → passed=false，reason 携带真实退出码
test "run_guard: nonzero exit => not passed" {
  let guard_spec = @config.GuardSpec::new(["cmd", "/c", "exit", "1"], "skip")
  let policy = @action.build_policy(["cmd"])
  let res = @action.run_guard(guard_spec, gnk_ev(), policy)
  assert_false(res.passed)
  assert_true(res.reason.contains("退出码 1"))
}
