// ============================================================================
// action · 守卫门（schema v1.1 · PLAN-gates.md §二）纯逻辑 / 跨目标验证
//
// 守卫门是一条**必须 exit 0** 的单命令（复用 run_command + ExecPolicy 白名单）；
// 不做组合逻辑——AND/OR 守卫用条件层组合，防止长成规则里套规则的策略引擎。
//
// 真实命令验证见 guard_native_test.mbt（native 专属）。
// ============================================================================

///|
fn gk_ev() -> @watch.FsEvent {
  @watch.FsEvent::new(@config.EventType::Create, "C:/tmp/guard.tmp", false, 0, 0)
}

///|
/// run_guard：程序不在白名单 → passed=false，reason 含策略拒绝（与 command 同策略）
test "run_guard: policy denial => not passed" {
  let guard_spec = @config.GuardSpec::new(["agent-cli", "--probe"], "skip")
  let policy = @action.build_policy([]) // 空白名单 = 拒绝一切（安全默认）
  let res = @action.run_guard(guard_spec, gk_ev(), policy)
  assert_false(res.passed)
  assert_true(res.reason.contains("策略拒绝"))
}

///|
/// GuardResult 结构：通过时 reason 为空
test "GuardResult: new shapes" {
  let ok = @action.GuardResult::new(true, "")
  assert_true(ok.passed)
  assert_eq(ok.reason, "")
  let fail = @action.GuardResult::new(false, "some reason")
  assert_false(fail.passed)
  assert_eq(fail.reason, "some reason")
}
