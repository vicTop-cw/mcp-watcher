// ============================================================================
// action · 验收门真实验证（native 专属 · PLAN-gates.md §一）
//
// 真实 cmd 命令 + 真实 fs 枚举，覆盖：
//   - artifact_glob_hit：真实目录 glob 存在性（命中 / 无命中 / ** 跨段）
//   - run_command_action：验收不过保留真实 exit_code 与输出原文
//   - 非零退出码：带 acceptance 时恢复真实退出码（rx 非零走 on_error 通道）
//   - run_action 契约：验收不过 → Ok(outcome) 且 accepted=false（堵假绿）
//   - 无 acceptance 字段 → v1.0 行为不变（向后兼容锁）
// ============================================================================

///|
fn quiet_acc() -> @config.LoggingConfig {
  { enabled: false, log_dir: "", log_file: "mcp-watcher.log" }
}

///|
fn mk_ev_acc() -> @watch.FsEvent {
  @watch.FsEvent::new(
    @config.EventType::Create,
    "C:/tmp/acceptance.tmp",
    false,
    0,
    0,
  )
}

///|
/// artifact_glob_hit：命中（output/*.json）
async test "artifact_glob_hit: hits real file" {
  let base = "E:/IDEProjects/AI/mcp-watcher/action/.acceptance-test-hit"
  let _ = @fs.mkdir(base + "/output", recursive=true, allow_exist=true)
  defer (@fs.rmdir(base, recursive=true, allow_missing=true) catch { _ => () })
  @fs.write_file(base + "/output/result.json", "{}")
  assert_true(@action.artifact_glob_hit(base, "output/*.json"))
}

///|
/// artifact_glob_hit：无命中（目录下无匹配文件）
async test "artifact_glob_hit: no hit when file absent" {
  let base = "E:/IDEProjects/AI/mcp-watcher/action/.acceptance-test-miss"
  let _ = @fs.mkdir(base, recursive=true, allow_exist=true)
  defer (@fs.rmdir(base, recursive=true, allow_missing=true) catch { _ => () })
  assert_false(@action.artifact_glob_hit(base, "output/*.json"))
}

///|
/// artifact_glob_hit：** 跨段命中；不匹配扩展名 → 无命中
async test "artifact_glob_hit: ** crosses segments" {
  let base = "E:/IDEProjects/AI/mcp-watcher/action/.acceptance-test-nested"
  let _ = @fs.mkdir(base + "/sub", recursive=true, allow_exist=true)
  defer (@fs.rmdir(base, recursive=true, allow_missing=true) catch { _ => () })
  @fs.write_file(base + "/sub/deep.txt", "x")
  assert_true(@action.artifact_glob_hit(base, "**/*.txt"))
  assert_false(@action.artifact_glob_hit(base, "**/*.json"))
}

///|
/// 用例1（真实命令）：exit 0 + stdout_contains 命中 → accepted=true
test "run_command_action: acceptance pass on real command" {
  let spec = @config.ActionSpec::new(
    "command",
    Some(["cmd", "/c", "echo", "DONE"]),
    None,
    None,
    Some(@config.AcceptanceSpec::new(0, ["DONE"], [], [], None)),
  )
  let policy = @action.build_policy(["cmd"])
  let outcome = @action.run_command_action(spec, mk_ev_acc(), policy, "C:/tmp")
  assert_true(outcome.ok)
  assert_true(outcome.accepted)
  assert_eq(outcome.exit_code, 0)
}

///|
/// 用例2（真实命令）：stdout_not_contains 命中 → accepted=false，
/// 且保留真实 exit_code 与输出原文
test "run_command_action: acceptance fail keeps real exit and output" {
  let spec = @config.ActionSpec::new(
    "command",
    Some(["cmd", "/c", "echo", "DONE"]),
    None,
    None,
    Some(@config.AcceptanceSpec::new(0, [], ["DONE"], [], None)),
  )
  let policy = @action.build_policy(["cmd"])
  let outcome = @action.run_command_action(spec, mk_ev_acc(), policy, "C:/tmp")
  assert_false(outcome.accepted)
  assert_eq(outcome.exit_code, 0) // 保留真实退出码
  assert_true(outcome.stdout.contains("DONE")) // 保留输出原文
}

///|
/// 向后兼容锁：无 acceptance 字段 → v1.0 行为（非零退出 ok=false、exit_code=-1）
test "run_command_action: v1.0 behavior without acceptance" {
  let spec = @config.ActionSpec::new(
    "command",
    Some(["cmd", "/c", "exit", "1"]),
    None,
    None,
    None,
  )
  let policy = @action.build_policy(["cmd"])
  let outcome = @action.run_command_action(spec, mk_ev_acc(), policy, "C:/tmp")
  assert_false(outcome.ok)
  assert_eq(outcome.exit_code, -1)
  assert_false(outcome.accepted)
  // v1.0 错误文本格式（exec_error_text 映射，中文）
  assert_true(outcome.stderr.contains("退出码 1"))
}

///|
/// 非零退出 + acceptance：恢复真实退出码 1（expect_exit=1 → accepted）
test "run_command_action: nonzero exit recovers real code with acceptance" {
  let spec = @config.ActionSpec::new(
    "command",
    Some(["cmd", "/c", "exit", "1"]),
    None,
    None,
    Some(@config.AcceptanceSpec::new(1, [], [], [], None)),
  )
  let policy = @action.build_policy(["cmd"])
  let outcome = @action.run_command_action(spec, mk_ev_acc(), policy, "C:/tmp")
  assert_eq(outcome.exit_code, 1)
  assert_true(outcome.accepted)

  // expect_exit 缺省 0 → 不通过
  let spec2 = @config.ActionSpec::new(
    "command",
    Some(["cmd", "/c", "exit", "1"]),
    None,
    None,
    Some(@config.AcceptanceSpec::new(0, [], [], [], None)),
  )
  let outcome2 = @action.run_command_action(spec2, mk_ev_acc(), policy, "C:/tmp")
  assert_eq(outcome2.exit_code, 1)
  assert_false(outcome2.accepted)
}

///|
/// run_action 契约：验收不过 → Ok(outcome) 且 accepted=false（堵假绿）
test "run_action: acceptance fail returns Ok with accepted=false" {
  let spec = @config.ActionSpec::new(
    "command",
    Some(["cmd", "/c", "echo", "BAD"]),
    None,
    None,
    Some(@config.AcceptanceSpec::new(0, ["GOOD"], [], [], None)),
  )
  let policy = @action.build_policy(["cmd"])
  match @action.run_action(spec, mk_ev_acc(), policy, quiet_acc(), "C:/tmp") {
    Ok(o) => {
      assert_false(o.accepted)
      assert_eq(o.exit_code, 0)
    }
    Err(_) => assert_true(false)
  }
}

///|
/// run_action 契约：验收通过 → Ok 且 accepted=true
test "run_action: acceptance pass returns Ok with accepted=true" {
  let spec = @config.ActionSpec::new(
    "command",
    Some(["cmd", "/c", "echo", "GOOD"]),
    None,
    None,
    Some(@config.AcceptanceSpec::new(0, ["GOOD"], [], [], None)),
  )
  let policy = @action.build_policy(["cmd"])
  match @action.run_action(spec, mk_ev_acc(), policy, quiet_acc(), "C:/tmp") {
    Ok(o) => assert_true(o.accepted)
    Err(_) => assert_true(false)
  }
}

///|
/// run_action 向后兼容锁：无 acceptance、非零退出 → Err（v1.0 不变）
test "run_action: v1.0 nonzero exit still Err" {
  let spec = @config.ActionSpec::new(
    "command",
    Some(["cmd", "/c", "exit", "1"]),
    None,
    None,
    None,
  )
  let policy = @action.build_policy(["cmd"])
  match @action.run_action(spec, mk_ev_acc(), policy, quiet_acc(), "C:/tmp") {
    Ok(_) => assert_true(false)
    // v1.0 错误文本格式（exec_error_text 映射，中文）
    Err(e) => assert_true(e.contains("退出码 1"))
  }
}
