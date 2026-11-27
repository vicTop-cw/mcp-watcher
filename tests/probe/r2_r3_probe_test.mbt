// ============================================================================
// R2 / R3 集成探针 —— 验证 rx-mbt 的原生监控与命令执行在 mcp-watcher 内可用
//
// 这些是 mcp-watcher「自治闭环」的硬件层依赖：
//   R2：文件事件源（watch 包的 backend 替身）
//   R3：命令执行源（action 包的 run 替身）
//
// 与 util/probe_test.mbt 的分工：
//   util  → R1/R4（纯类型与时钟，无 IO）
//   本包 → R2/R3（涉及真实 IO，需要 native 目标）
//
// rx 订阅 API 形状（实测）：
//   Observable::subscribe(Observer) —— 需显式构造 Observer
//   Observable::subscribe_on_next(fn) / subscribe_on_error(fn) —— 便捷方法
// ============================================================================

///|
/// R2 · native 监控 Observable 的构造可用性（**不订阅**）
///
/// 关键约束（实测确认）：native 后端的订阅闭包是**同步阻塞**的
/// （ReadDirectoryChangesW 事件 + 轮询循环都在 subscribe_fn 内），
/// 一旦 subscribe 就会占住当前线程直到 Subscription 被 dispose。
/// 因此：
///   1. 本测试**只构造 Observable 不订阅**——订阅形态由双进程集成测试覆盖；
///   2. mcp-watcher 运行时**必须在后台 async 任务中 subscribe**，
///      否则事件循环会被监控源独占（这是 R2 接入的架构硬约束）。
test "R2: watch_folder 可构造（订阅会阻塞，故不在此订阅）" {
  let _ = @mon.fs_write_atomic("tests/probe/.tmp_r2/keep.txt", "x")
  let obs = @mon.watch_folder("tests/probe/.tmp_r2")
  // 只验证构造成功，不 subscribe
  let _ = obs
}

///|
/// R2 · WatchEvent / FileStat 字段可跨包读取（需 pub(all)）
test "R2: FileStat 字段跨包可读" {
  let _ = @mon.fs_write_atomic("tests/probe/.tmp_r2b/keep.txt", "x")
  match @mon.fs_stat("tests/probe/.tmp_r2b/keep.txt") {
    Ok(st) => assert_true(st.size >= 0L)
    Err(_) => abort("fs_stat 应当成功")
  }
}

///|
/// R3 · 命令执行源：ExecPolicy 白名单语义
///
/// 白名单语义：默认只放行 action:/handler:；任意命令需显式加入 allow
/// 或 allow_any=true。这是 mcp-watcher「不泛泛跑命令」的安全底线。
test "R3: ExecPolicy 默认拒绝任意命令" {
  let policy = @rt.ExecPolicy::default()
  assert_false(policy.allows("cli:echo"))
  assert_true(policy.allows("action:demo"))
}

///|
/// R3 · run_command 在策略拒绝时发出可诊断错误（而非静默成功）
test "R3: run_command 策略拒绝走 on_error" {
  let policy = @rt.ExecPolicy::default()
  let payload = @json.parse("{\"argv\":[\"echo\",\"hi\"]}") catch {
    _ => abort("payload 解析失败")
  }
  let err = Ref::Ref("")
  let obs = @rt.run_command(policy, payload)
  let _ = obs.subscribe_on_error(fn(_e : @rt.ExecError) { err.val = "denied" })
  assert_true(err.val != "")
}
