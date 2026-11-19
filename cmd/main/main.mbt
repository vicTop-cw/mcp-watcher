// ============================================================================
// cmd/main · CLI 入口
//
// 子命令：
//   validate   校验 .mcp-watch.json 规则（语义校验 + 汇总）
//   run        后台自治运行（守护进程主体）
//   status     观测运行状态
//   stop       终止守护进程（预留）
//   start      启动守护进程（写 pidfile）
//
// run 支持 test-mode 参数（对齐 tests/harness/server_contract.md）：
//   --watch-dir <DIR>        被监听目录
//   --rules <FILE>           规则配置文件
//   --results <FILE.jsonl>   结果 JSONL 落盘
//   --ready <SENTINEL>       就绪哨兵文件
//   --stop-after <N>         触发 N 条后退出
//   --once                   前台运行一次，日志直出 stdout
//
// 四大支柱：后台常驻沉默自治 / 声明式规则系统 / 热重载 / 产物生命周期语义。
// ============================================================================

///|
/// 解析后的命令行参数
#derive(Eq, Debug)
pub(all) struct CliArgs {
  /// 子命令（validate / run / status / stop / start / reload / help）
  command : String
  /// 规则配置文件路径
  rules : String
  /// 被监听目录
  watch_dir : String
  /// 结果 JSONL 路径
  results : String
  /// 就绪哨兵文件路径
  ready : String
  /// 触发多少条后停止（-1 = 不限）
  stop_after : Int64
  /// 去抖时长覆盖（-1 = 用配置值）
  debounce_ms : Int64
  /// 前台单次运行模式
  once : Bool
}

///|
pub extend CliArgs with Eq::{not_equal, equal}

///|
pub extend CliArgs with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 构造 CLI 参数
pub fn CliArgs::new() -> CliArgs {
  {
    command: "help",
    rules: ".mcp-watch.json",
    watch_dir: "",
    results: "",
    ready: "",
    stop_after: -1L,
    debounce_ms: -1L,
    once: false,
  }
}

///|
/// 解析命令行参数
pub fn parse_args(argv : Array[String]) -> CliArgs {
  let out = CliArgs::new()
  // ⚠️ @env.args() 的 args[0] 是**可执行文件路径**，子命令从 args[1] 起
  let cmd = if argv.length() > 1 { argv[1] } else { "help" }
  let command = cmd
  let mut rules = out.rules
  let mut watch_dir = out.watch_dir
  let mut results = out.results
  let mut ready = out.ready
  let mut stop_after = out.stop_after
  let mut debounce_ms = out.debounce_ms
  let mut once = false
  let i = Ref::Ref(2)
  while i.val < argv.length() {
    let a = argv[i.val]
    if a == "--rules" && i.val + 1 < argv.length() {
      rules = argv[i.val + 1]
      i.val = i.val + 2
    } else if a == "--watch-dir" && i.val + 1 < argv.length() {
      watch_dir = argv[i.val + 1]
      i.val = i.val + 2
    } else if a == "--results" && i.val + 1 < argv.length() {
      results = argv[i.val + 1]
      i.val = i.val + 2
    } else if a == "--ready" && i.val + 1 < argv.length() {
      ready = argv[i.val + 1]
      i.val = i.val + 2
    } else if a == "--stop-after" && i.val + 1 < argv.length() {
      stop_after = @string.parse_int64(argv[i.val + 1]) catch { _ => -1L }
      i.val = i.val + 2
    } else if a == "--debounce-ms" && i.val + 1 < argv.length() {
      debounce_ms = @string.parse_int64(argv[i.val + 1]) catch { _ => -1L }
      i.val = i.val + 2
    } else if a == "--once" {
      once = true
      i.val = i.val + 1
    } else {
      i.val = i.val + 1
    }
  }
  { command, rules, watch_dir, results, ready, stop_after, debounce_ms, once, }
}

///|
/// 退出码
const EXIT_SUCCESS = 0

///|
const EXIT_FAILURE = 1

///|
/// 终止当前进程（native：C exit，保证 stop-after 后守护进程真正退出）
///
/// 为什么需要：rx 的 watch 订阅是同步阻塞的无限循环，dispose 只在订阅循环
/// 返回后才生效，无法从外部停止。test-mode 的 --stop-after 要真正结束进程，
/// 只能在结果落盘后调用进程级 exit。
///
/// wasm / js：无真实文件监控（rx monitor 在这两个目标不发内核事件），
/// 不会走到 stop-after 分支；这里提供 no-op stub 保证三目标可编译。
#cfg(target="native")
extern "C" fn exit_process(code : Int32) = "exit"

///|
#cfg(not(target="native"))
fn exit_process(code : Int32) -> Unit {
  let _ = code
  ()
}

///|
/// 守护进程 pidfile 路径（相对于 watch_dir）
pub fn pidfile_path(watch_dir : String) -> String {
  if watch_dir == "" {
    ".mcp-watch.pid"
  } else {
    watch_dir + "/.mcp-watch.pid"
  }
}

///|
/// 解析 pidfile 内容
#derive(Eq, Debug)
pub(all) struct PidInfo {
  /// 监控实例 id
  watch_id : String
  /// 进程 id
  pid : Int32
}

///|
pub extend PidInfo with Eq::{not_equal, equal}

///|
pub extend PidInfo with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 解析 pidfile 内容
pub fn parse_pidfile(content : String) -> Result[PidInfo, String] {
  let mut watch_id = ""
  let mut pid = 0
  for line_view in content.split("\n") {
    let line = line_view.to_owned()
    let trimmed = line.trim()
    if trimmed == "" {
      continue
    }
    let parts : Array[String] = []
    for sv in trimmed.split("=") {
      parts.push(sv.to_owned())
    }
    if parts.length() == 2 {
      let key = parts[0].trim()
      let val = parts[1].trim()
      if key == "watch_id" {
        watch_id = val.to_owned()
      } else if key == "pid" {
        match @util.parse_int(val.to_owned()) {
          Some(p) => pid = p
          None => return Err("pidfile 中 pid 格式无效")
        }
      }
    }
  }
  if watch_id == "" {
    return Err("pidfile 缺少 watch_id")
  }
  if pid == 0 {
    return Err("pidfile 缺少 pid")
  }
  Ok({ watch_id, pid, })
}

///|
/// 构造 pidfile 内容
pub fn pidfile_content(watch_id : String, pid : Int32) -> String {
  "watch_id=" + watch_id + "\npid=" + pid.to_string() + "\n"
}

///|
/// 守护进程主体（async）
///
/// test-mode 下把结果写 JSONL；非 test-mode 走标准输出。
pub async fn run_daemon(cfg : @config.Config, args : CliArgs) -> Unit {
  @rx.install_real_clock()
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])
  let policy = @action.build_policy(@scheduler.allowed_programs(cfg))
  // EP-01a：internal 动作上下文（reload_config 复用 CLI reload 通道；
  // paused 门控共享给 watch 订阅）
  let state = @scheduler.WatcherState::new(args.rules, cfg.watch_id, cfg.watch_dir)
  let reg = @scheduler.build_internal_registry(state)
  let n = @scheduler.attach_rules(
    cfg.rules,
    bus,
    policy,
    cfg.watch_dir,
    cfg.logging,
    log,
    records,
    watch_id=cfg.watch_id,
    registry=reg,
  )
  println("  已注册订阅：" + n.to_string())

  // 创建就绪哨兵文件（test-mode）
  if args.ready != "" {
    match write_file(args.ready, "") {
      Ok(_) => println("  就绪哨兵已创建：" + args.ready)
      Err(e) => println("  创建就绪哨兵失败：" + e)
    }
  }

  let count = Ref::Ref(0L)
  // 事件落盘（test-mode）：规则订阅先注册，故本回调执行时真实记录已写入
  // records。用增量游标逐条落盘，保证每行对应一次真实的 rule+action 执行。
  if args.results != "" {
    let _ = write_file(args.results, "")
    let cursor = Ref::Ref(0)
    let _ = bus.subscribe("*.*", fn(ev : @rx.TriggerEvent[@watch.FsEvent]) {
      let _ = ev
      let all = records.val
      while cursor.val < all.length() {
        let line = result_json_from_record(all[cursor.val])
        append_file(args.results, line)
        cursor.val = cursor.val + 1
        count.val = count.val + 1L
        if args.stop_after >= 0L && count.val >= args.stop_after {
          println(
            "  已达到 stop-after=" +
            args.stop_after.to_string() +
            "，退出",
          )
          // 优雅退出：刷新（append_file 已是同步写）、删除就绪哨兵、终止进程
          // rx watch 订阅无法从外部停止，必须进程级退出
          if args.ready != "" {
            let _ = @mon.fs_remove(args.ready)
          }
          exit_process(EXIT_SUCCESS)
        }
      }
    })
  }
  // 后台监控任务（rx 订阅同步阻塞，必须放独立 async 任务）
  @async.with_task_group(fn(group : @async.TaskGroup) {
    let _ = group.spawn(fn() {
      @watch.spawn_watch_task(
        cfg.watch_dir,
        cfg.recursive,
        bus,
        debounce_ms=cfg.debounce_ms.to_int64(),
        paused=state.paused,
      )
    })
    // 等待任务完成（stop-after 触发时，watch 任务会自然结束）
  })
  // 退出前删除就绪哨兵文件
  if args.ready != "" {
    let _ = @mon.fs_remove(args.ready)
  }
}

///|
/// 由真实执行记录构造结果 JSONL 行（对齐 server_contract.md §3）
///
/// 所有字段直接取自 scheduler 在动作真正执行后写入的 ExecRecord：
/// rule_id / event / path / action_type / exit / stdout / stderr 均为真实值，
/// 不再从日志字符串猜测。
pub fn result_json_from_record(r : @scheduler.ExecRecord) -> String {
  let obj = @json.Json::object({
    "rule_id": @json.Json::string(r.rule_id),
    "event": @json.Json::string(r.event),
    "path": @json.Json::string(r.path),
    "action_type": @json.Json::string(r.action_type),
    "exit": @json.Json::number(r.exit_code.to_double()),
    "stdout": @json.Json::string(r.stdout),
    "stderr": @json.Json::string(r.stderr),
    "ts": @json.Json::number(@rx.real_now().to_double()),
  })
  @json.Json::stringify(obj) + "\n"
}

///|
/// 读文件（返回内容或错误文本）
pub fn read_file(path : String) -> Result[String, String] {
  let r = @mon.fs_read_text(path)
  match r {
    Ok(s) => Ok(s)
    Err(e) => Err(fs_error_text(e))
  }
}

///|
/// 把 rx 的 FsError 转成可读文本
pub fn fs_error_text(e : @mon.FsError) -> String {
  match e {
    @mon.FsError::NotFound => "NotFound"
    @mon.FsError::Io => "Io"
    @mon.FsError::OutOfMemory => "OutOfMemory"
  }
}

///|
/// 写文件
pub fn write_file(path : String, content : String) -> Result[Unit, String] {
  let r = @mon.fs_write_atomic(path, content)
  match r {
    Ok(_) => Ok(())
    Err(e) => Err(fs_error_text(e))
  }
}

///|
/// 追加文件（读-改-写实现真追加）
///
/// rx 的 @mon 包只提供 fs_write_atomic（覆盖写），没有 append API。
/// 这里先读回现有内容再拼接写回，保证 JSONL 多条结果不会互相覆盖。
pub fn append_file(path : String, content : String) -> Unit {
  let old = match @mon.fs_read_text(path) {
    Ok(s) => s
    Err(_) => ""
  }
  let _ = @mon.fs_write_atomic(path, old + content)
}

///|
/// 检查文件是否存在（通过尝试读取）
pub fn file_exists(path : String) -> Bool {
  match read_file(path) {
    Ok(_) => true
    Err(_) => false
  }
}

// ============================================================================
// 子命令实现
// ============================================================================

///|
async fn main {
  let argv = @env.args()
  let args = parse_args(argv)
  match args.command {
    "validate" => {
      let code = cmd_validate(args)
      if code == EXIT_SUCCESS {
        ()
      } else {
        ()
      }
    }
    "run" => if args.once { cmd_run_once(args) } else { cmd_run(args) }
    "status" => cmd_status(args)
    "stop" => cmd_stop(args)
    "start" => {
      let code = cmd_start(args)
      if code == EXIT_SUCCESS {
        ()
      } else {
        ()
      }
    }
    "reload" => {
      let code = cmd_reload(args)
      if code == EXIT_SUCCESS {
        ()
      } else {
        ()
      }
    }
    _ => cmd_help()
  }
}

///|
fn cmd_help() -> Unit {
  println("mcp-watcher · AI 工作区自治运行时 (v0.1.0)")
  println("========================================================")
  println("四大支柱：")
  println(
    "  1) 后台常驻、沉默自治（不占用 Agent 的一轮对话）",
  )
  println(
    "  2) 声明式规则系统（非程序员能写、AI 能自己写）",
  )
  println("  3) 热重载（规则变了不停机）")
  println(
    "  4) 产物生命周期语义（TTL / trash / 加密，不是泛泛的跑命令）",
  )
  println("")
  println("用法：")
  println("  mcp-watcher validate --rules <FILE>")
  println("  mcp-watcher start --rules <FILE> --watch-dir <DIR>")
  println("  mcp-watcher run --rules <FILE> --watch-dir <DIR> [--once]")
  println("  mcp-watcher status")
  println("  mcp-watcher reload --rules <FILE>")
  println("  mcp-watcher stop")
  println("")
  println(
    "run 的 test-mode 参数（对齐 tests/harness/server_contract.md）：",
  )
  println("  --results <FILE.jsonl>   结果 JSONL 落盘")
  println("  --ready <SENTINEL>       就绪哨兵文件")
  println("  --stop-after <N>         触发 N 条后退出")
  println("  --debounce-ms <N>        去抖时长覆盖")
  println("  --once                   前台运行一次，日志直出 stdout")
  println("")
  println("设计文档：README.md · workbuddy/plan/*")
}

///|
/// validate 子命令：跑 loader + validator，返回退出码 0/1
///
/// 退出码：
///   0 - 校验通过
///   1 - 校验失败
fn cmd_validate(args : CliArgs) -> Int32 {
  let text = read_file(args.rules)
  match text {
    Err(e) => {
      println(
        "✗ 读取规则文件失败：" + args.rules + "（" + e + "）",
      )
      return EXIT_FAILURE
    }
    Ok(content) =>
      match @config.Config::from_json(content) {
        Err(e) => {
          println("✗ 规则校验失败：\n" + e)
          return EXIT_FAILURE
        }
        Ok(cfg) => {
          println("✓ 规则校验通过")
          println("  规则数：" + cfg.rules.length().to_string())
          println(
            "  watch_dir：" +
            (if cfg.watch_dir == "" { "(未设置)" } else { cfg.watch_dir }),
          )
          println("  recursive：" + cfg.recursive.to_string())
          println("  debounce_ms：" + cfg.debounce_ms.to_string())
          for r in cfg.rules {
            println(
              "  - " +
              r.id +
              " events=[" +
              r.events.join(",") +
              "] patterns=[" +
              r.patterns.join(",") +
              "] actions=" +
              r.actions.length().to_string(),
            )
          }
          return EXIT_SUCCESS
        }
      }
  }
}

///|
/// start 子命令：写 pidfile，拒绝重复启动
///
/// 退出码：
///   0 - 启动成功
///   1 - 启动失败（pidfile 已存在、配置错误等）
fn cmd_start(args : CliArgs) -> Int32 {
  // 1. 读取并校验配置
  let text = read_file(args.rules)
  match text {
    Err(e) => {
      println(
        "✗ 读取规则文件失败：" + args.rules + "（" + e + "）",
      )
      return EXIT_FAILURE
    }
    Ok(content) =>
      match @config.Config::from_json(content) {
        Err(e) => {
          println("✗ 规则校验失败：\n" + e)
          return EXIT_FAILURE
        }
        Ok(cfg) => {
          // 2. 确定 watch_dir
          let watch_dir = if args.watch_dir == "" {
            cfg.watch_dir
          } else {
            args.watch_dir
          }
          if watch_dir == "" {
            println(
              "✗ 未指定监控目录（--watch-dir 或配置里的 watch_dir）",
            )
            return EXIT_FAILURE
          }
          // 3. 检查 pidfile 是否已存在
          let pidfile = pidfile_path(watch_dir)
          if file_exists(pidfile) {
            // 尝试读取现有 pidfile
            match read_file(pidfile) {
              Ok(content) =>
                match parse_pidfile(content) {
                  Ok(info) => {
                    // 无法检查进程是否存活，直接拒绝
                    println(
                      "✗ 守护进程已在运行（watch_id=" +
                      info.watch_id +
                      "）",
                    )
                    println(
                      "  如需重新启动，请先执行：mcp-watcher stop",
                    )
                    return EXIT_FAILURE
                  }
                  Err(_) =>
                    // pidfile 格式无效，覆盖
                    println("⚠ pidfile 格式无效，覆盖后重新启动")
                }
              Err(_) =>
                // 无法读取，覆盖
                println("⚠ 无法读取 pidfile，覆盖后重新启动")
            }
          }
          // 4. 写 pidfile
          // 注意：无法获取真实 pid，使用时间戳作为占位
          let ts = @rx.real_now().to_int()
          let content = pidfile_content(cfg.watch_id, ts)
          match write_file(pidfile, content) {
            Ok(_) => {
              println("✓ 守护进程启动成功")
              println("  watch_id：" + cfg.watch_id)
              println("  watch_dir：" + watch_dir)
              println("  pidfile：" + pidfile)
              println("  规则数：" + cfg.rules.length().to_string())
              println("")
              println(
                "  提示：如需停止守护进程，执行：mcp-watcher stop",
              )
              return EXIT_SUCCESS
            }
            Err(e) => {
              println(
                "✗ 写入 pidfile 失败：" + pidfile + "（" + e + "）",
              )
              return EXIT_FAILURE
            }
          }
        }
      }
  }
}

///|
/// status 子命令：扫描 pidfile，显示状态
fn cmd_status(args : CliArgs) -> Unit {
  // 1. 读取并解析配置（用于显示 watch_id 等信息）
  let text = read_file(args.rules)
  let cfg = match text {
    Err(e) => {
      println("无法读取规则文件：" + args.rules + "（" + e + "）")
      return
    }
    Ok(content) =>
      match @config.Config::from_json(content) {
        Err(e) => {
          println("✗ 规则校验失败：\n" + e)
          return
        }
        Ok(c) => c
      }
  }
  // 2. 确定 watch_dir
  let watch_dir = if args.watch_dir == "" {
    cfg.watch_dir
  } else {
    args.watch_dir
  }
  if watch_dir == "" {
    println(
      "✗ 未指定监控目录（--watch-dir 或配置里的 watch_dir）",
    )
    return
  }
  // 3. 扫描 pidfile
  let pidfile = pidfile_path(watch_dir)
  println("mcp-watcher 状态")
  println("  规则文件：" + args.rules)
  println("  watch_dir：" + watch_dir)
  println("  pidfile：" + pidfile)

  if !file_exists(pidfile) {
    println("  状态：未运行（pidfile 不存在）")
    println("  提示：执行 'mcp-watcher start' 启动守护进程")
  } else {
    match read_file(pidfile) {
      Ok(content) =>
        match parse_pidfile(content) {
          Ok(info) => {
            println("  watch_id：" + info.watch_id)
            println("  pid：" + info.pid.to_string())
            println("  状态：已启动（无法检查进程存活）")
            println("  提示：执行 'mcp-watcher stop' 停止守护进程")
          }
          Err(e) => println("  状态：pidfile 格式错误 - " + e)
        }
      Err(e) => println("  状态：无法读取 pidfile - " + e)
    }
  }
  // 4. 显示配置摘要
  println("")
  println("  配置摘要：")
  println("    规则数  ：" + cfg.rules.length().to_string())
  println(
    "    事件源  ：rx monitor（native ReadDirectoryChangesW / js fs.watch）",
  )
  println("    派发    ：rx EventBus（规则内核）")
  println(
    "    执行    ：rx run_command + ExecPolicy（白名单，argv 不走 shell）",
  )
}

///|
/// stop 子命令：终止守护进程
fn cmd_stop(args : CliArgs) -> Unit {
  let _ = args
  println(
    "stop 子命令待实现（需要守护进程 pid 文件；P1 接入）",
  )
  println("  提示：手动删除 pidfile 可清理状态")
}

///|
/// reload 子命令：热重载配置
///
/// 退出码：
///   0 - 重载成功
///   1 - 重载失败
fn cmd_reload(args : CliArgs) -> Int32 {
  let result = @scheduler.reload_config(args.rules)
  if result.ok {
    println("✓ 热重载成功")
    println("  规则数：" + result.rule_count.to_string())
    return EXIT_SUCCESS
  } else {
    println("✗ 热重载失败：" + result.error)
    return EXIT_FAILURE
  }
}

///|
/// run 子命令：后台自治运行
async fn cmd_run(args : CliArgs) -> Unit {
  let text = read_file(args.rules)
  let cfg = match text {
    Err(e) => {
      println(
        "✗ 读取规则文件失败：" + args.rules + "（" + e + "）",
      )
      return
    }
    Ok(content) =>
      match @config.Config::from_json(content) {
        Err(e) => {
          println("✗ 规则校验失败：\n" + e)
          return
        }
        Ok(c) => c
      }
  }
  // 命令行覆盖 watch_dir
  let watch_dir = if args.watch_dir == "" {
    cfg.watch_dir
  } else {
    args.watch_dir
  }
  if watch_dir == "" {
    println(
      "✗ 未指定监控目录（--watch-dir 或配置里的 watch_dir）",
    )
    return
  }
  let cfg2 = if args.debounce_ms >= 0L {
    cfg.with_watch_dir(watch_dir).with_debounce_ms(args.debounce_ms.to_int())
  } else {
    cfg.with_watch_dir(watch_dir)
  }
  println("mcp-watcher 启动")
  println("  watch_dir：" + cfg2.watch_dir)
  println("  规则数  ：" + cfg2.rules.length().to_string())
  // 就绪哨兵（先建，避免事件早于监听的竞态）
  if args.ready != "" {
    let _ = write_file(args.ready, "")
    println("  就绪哨兵：" + args.ready)
  }
  run_daemon(cfg2, args)
}

///|
/// run --once 子命令：前台运行一次，日志直出 stdout
///
/// 语义：
///   - 启动监控任务
///   - 等待第一条事件
///   - 执行匹配规则
///   - 打印日志到 stdout
///   - 退出
async fn cmd_run_once(args : CliArgs) -> Unit {
  // 1. 读取并校验配置
  let text = read_file(args.rules)
  let cfg = match text {
    Err(e) => {
      println(
        "✗ 读取规则文件失败：" + args.rules + "（" + e + "）",
      )
      return
    }
    Ok(content) =>
      match @config.Config::from_json(content) {
        Err(e) => {
          println("✗ 规则校验失败：\n" + e)
          return
        }
        Ok(c) => c
      }
  }
  // 2. 确定 watch_dir
  let watch_dir = if args.watch_dir == "" {
    cfg.watch_dir
  } else {
    args.watch_dir
  }
  if watch_dir == "" {
    println(
      "✗ 未指定监控目录（--watch-dir 或配置里的 watch_dir）",
    )
    return
  }
  println("mcp-watcher 单次运行模式")
  println("  watch_dir：" + watch_dir)
  println("  规则数  ：" + cfg.rules.length().to_string())
  println("  按 Ctrl+C 退出")
  println("")

  // 3. 构建执行策略
  let policy = @action.build_policy(@scheduler.allowed_programs(cfg))

  // 4. 启动监控任务（异步）
  @rx.install_real_clock()
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  let log : Ref[Array[String]] = Ref::Ref([])
  let records : Ref[Array[@scheduler.ExecRecord]] = Ref::Ref([])

  // EP-01a：internal 动作上下文（与 run_daemon 同款接线）
  let state = @scheduler.WatcherState::new(args.rules, cfg.watch_id, watch_dir)
  let reg = @scheduler.build_internal_registry(state)

  // 挂载规则
  let n = @scheduler.attach_rules(
    cfg.rules,
    bus,
    policy,
    watch_dir,
    cfg.logging,
    log,
    records,
    watch_id=cfg.watch_id,
    registry=reg,
  )
  println("  已注册订阅：" + n.to_string())

  // 订阅事件并打印日志
  let _ = bus.subscribe("*.*", fn(ev : @rx.TriggerEvent[@watch.FsEvent]) {
    let fe = ev.payload
    println("[" + fe.event_type.to_string() + "] " + fe.path)
    for msg in log.val {
      println("  " + msg)
    }
  })

  // 启动监控
  @async.with_task_group(fn(group : @async.TaskGroup) {
    let _ = group.spawn(fn() {
      @watch.spawn_watch_task(
        watch_dir,
        cfg.recursive,
        bus,
        debounce_ms=cfg.debounce_ms.to_int64(),
        paused=state.paused,
      )
    })
  })
}
