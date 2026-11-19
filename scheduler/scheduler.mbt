// ============================================================================
// scheduler · 调度主循环 + 规则内核（rx EventBus 接线）
//
// P0 实现期：
//   - 规则表 → rx EventBus 订阅（每条规则一个订阅，事件名按类型分派）
//   - 事件到达 → rule.dispatch 匹配 → 逐个 action 执行（走 rx run_command）
//   - 执行策略（ExecPolicy）由规则显式声明的程序名单构造（安全默认：空名单）
//
// 架构（对齐 development-plan.md §2）：
//
//   fs 事件源 ──▶ @rx.EventBus[FsEvent] ──▶ 规则订阅 ──▶ action 执行
//                        ▲
//                        └── cron 源（P2 接入）
//
// ⚠️ MoonBit 语法约束（实测确认）：
//   - rx 泛型类型跨包引用必须带完整类型标注：
//     `let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()`
//   - 闭包无法直接改外层变量，须经 `Ref` 间接赋值。
// ============================================================================

///|
/// 真实执行记录（server test-mode 结果落盘的字段来源）
///
/// 契约要求（server_contract.md §3）：只记录"真实触发的规则 + 实际 action 结果"。
/// 因此每条记录在动作真正执行后由 scheduler 写入，字段直接取自命中的 Rule、
/// 触发的 FsEvent 与 ActionOutcome，不再从日志字符串猜测。
#derive(Eq, Debug)
pub(all) struct ExecRecord {
  rule_id : String
  event : String
  path : String
  action_type : String
  exit_code : Int32
  stdout : String
  stderr : String
}

///|
pub extend ExecRecord with Eq::{not_equal, equal}

///|
pub extend ExecRecord with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn ExecRecord::new(
  rule_id : String,
  event : String,
  path : String,
  action_type : String,
  exit_code : Int32,
  stdout : String,
  stderr : String,
) -> ExecRecord {
  { rule_id, event, path, action_type, exit_code, stdout, stderr, }
}

///|
/// 规则内核：把规则表挂到 rx EventBus 上
///
/// 语义：为每条规则注册一个订阅，事件名按 `create.*` / `modify.*` / ...
/// 分派；命中后执行该规则的动作。
///
/// P1 增强：
///   - 优先级：按 Rule.priority 排序，高优先级先执行
///   - once 语义：Rule.stop_after 为 true 时，执行一次后移除该规则的订阅
///   - 去抖：使用 debounce_real 在订阅链上做去抖
///
/// 参数：
///   rules  - 规则表
///   bus   - 事件总线
///   policy - 执行策略（command 动作用）
///   watch_dir - 监控根目录（acceptance.artifact_glob 相对它解析）
///   logging_config - 日志配置
///   log   - 执行日志累加器（Ref 间接传递，闭包内无法直接改外层变量）
///   records - 真实执行记录累加器（每条动作执行后写入一条）
///
/// 返回：注册结果摘要（规则数 / 订阅数）
pub fn attach_rules(
  rules : Array[@config.Rule],
  bus : @rx.EventBus[@watch.FsEvent],
  policy : @rt.ExecPolicy,
  watch_dir : String,
  logging_config : @config.LoggingConfig,
  log : Ref[Array[String]],
  records : Ref[Array[ExecRecord]],
  registry~ : @action.InternalRegistry = @action.InternalRegistry::new(),
) -> Int32 {
  // 按优先级降序排序（高优先级先执行）
  let sorted_rules = rules
  sorted_rules.sort_by(fn(a : @config.Rule, b : @config.Rule) {
    b.priority - a.priority
  })
  let subscribed = Ref::Ref(0)
  // 记录已执行的规则（用于 once 语义）
  let executed_rules = Ref::Ref([])
  for r in sorted_rules {
    let rule = r
    // 检查是否已退场（once 语义 / guard on_fail=stop 退场）
    if executed_rules.val.contains(rule.id) {
      continue
    }
    for ev_name in event_names_of(rule) {
      let _ = bus.subscribe(ev_name, fn(ev : @rx.TriggerEvent[@watch.FsEvent]) {
        let fe = ev.payload
        // 检查是否已退场（once 语义 / guard on_fail=stop 退场）
        if executed_rules.val.contains(rule.id) {
          return
        }
        let matched = @rule.dispatch([rule], fe)
        if matched.length() > 0 {
          // 守卫门（schema v1.1）：执行前环境准入，通过才执行 actions
          let proceed = match rule.guard_spec {
            Some(g) => {
              let gr = @action.run_guard(g, fe, policy)
              if gr.passed {
                true
              } else {
                // 守卫不过：记 guard_fail 事件（可观测 + 落结果记录），
                // 按 on_fail 决策：skip 只跳过 / stop 再退场本规则
                let (skip_actions, retire) = guard_fail_decision(g.on_fail)
                log.val.push(
                  "rule " + rule.id + " guard_fail: " + gr.reason,
                )
                records.val.push(
                  ExecRecord::new(
                    rule.id,
                    fe.event_type.to_string(),
                    fe.path,
                    "guard",
                    -1,
                    "",
                    gr.reason,
                  ),
                )
                if retire {
                  executed_rules.val.push(rule.id)
                }
                !skip_actions
              }
            }
            None => true
          }
          if proceed {
            exec_actions(
              rule, fe, policy, logging_config, watch_dir, log, records, registry,
            )
            // 记录已执行（once 语义）
            if rule.stop_after {
              executed_rules.val.push(rule.id)
            }
          }
        }
      })
      subscribed.val = subscribed.val + 1
    }
  }
  subscribed.val
}

///|
/// 执行规则的动作组（schema v1.1 · 守卫门接线：仅在 guard 通过后调用）
///
/// 从 attach_rules 闭包内联代码抽出：逐动作走 run_action，结果落 log 与
/// records（字段直接取自命中规则 / 事件 / 动作结果）。
fn exec_actions(
  rule : @config.Rule,
  fe : @watch.FsEvent,
  policy : @rt.ExecPolicy,
  logging_config : @config.LoggingConfig,
  watch_dir : String,
  log : Ref[Array[String]],
  records : Ref[Array[ExecRecord]],
  registry : @action.InternalRegistry,
) -> Unit {
  for a in rule.actions {
    match @action.run_action(a, fe, policy, logging_config, watch_dir, registry=registry) {
      Ok(o) => {
        if o.accepted {
          log.val.push(
            "rule " +
            rule.id +
            " action " +
            a.kind +
            " ok exit=" +
            o.exit_code.to_string(),
          )
          // 真实执行记录：字段直接取自命中规则 / 事件 / 动作结果
          records.val.push(
            ExecRecord::new(
              rule.id,
              fe.event_type.to_string(),
              fe.path,
              a.kind,
              o.exit_code,
              o.stdout,
              o.stderr,
            ),
          )
        } else {
          // 验收不过（schema v1.1）：保留真实 exit/stdout，
          // stderr 记录验收原因（命令已真实执行，exit_code 不是 -1）
          log.val.push(
            "rule " +
            rule.id +
            " action " +
            a.kind +
            " acceptance_failed exit=" +
            o.exit_code.to_string() +
            ": " +
            o.acceptance_reason,
          )
          let note = "acceptance failed: " +
            o.acceptance_reason +
            (if o.stderr == "" { "" } else { " | exec: " + o.stderr })
          records.val.push(
            ExecRecord::new(
              rule.id,
              fe.event_type.to_string(),
              fe.path,
              a.kind,
              o.exit_code,
              o.stdout,
              note,
            ),
          )
        }
      }
      Err(e) => {
        log.val.push(
          "rule " + rule.id + " action " + a.kind + " err: " + e,
        )
        // 失败也要落结果记录（安全事件可观测）：
        // ExecPolicy 拒绝走 run_action 的 Err 分支，若不记录，
        // 则 test-mode 的 stop-after 永不触发、拒绝事件无从对拍。
        // exit_code=-1 表示"未真正执行"，stderr 携带可诊断原因。
        records.val.push(
          ExecRecord::new(
            rule.id,
            fe.event_type.to_string(),
            fe.path,
            a.kind,
            -1,
            "",
            e,
          ),
        )
      }
    }
  }
}

///|
/// 守卫门失败决策（schema v1.1 · PLAN-gates.md §二 纯函数）
///
/// 返回：(跳过本次动作, 规则退场)
///   - "skip"：只跳过本次动作，规则存活（再次事件仍触发 guard 判定）
///   - "stop"：跳过动作并让规则退场（停止本规则后续处理）
///   - 未知值：防御性按 skip 处理（解析层已 fail-closed，理论不达）
pub fn guard_fail_decision(on_fail : String) -> (Bool, Bool) {
  if on_fail == "stop" {
    (true, true)
  } else {
    (true, false)
  }
}

///|
/// 规则的事件名集合（rx EventBus 的 glob 约定）
///
/// `events` 字段含 "all" 时订阅全部类型；否则逐个订阅。
pub fn event_names_of(rule : @config.Rule) -> Array[String] {
  let names : Array[String] = []
  for e in rule.events {
    match @config.EventType::from_string(e) {
      Some(@config.EventType::All) => {
        names.push("create.*")
        names.push("modify.*")
        names.push("delete.*")
        names.push("rename.*")
        names.push("attrib.*")
        break
      }
      Some(t) => names.push(t.to_string() + ".*")
      None => ()
    }
  }
  names
}

///|
/// 调度主循环
///
/// P0 实现：启动后台 fs 监控任务 → 规则挂到 EventBus → 主线程等待。
///
/// 参数：
///   config - 运行配置
///
/// 返回：规则数与订阅数的摘要（成功）；失败时给出可诊断错误
pub async fn run_scheduler(config : @config.Config) -> Result[String, String] {
  // 真实时钟必须先注入，否则 rx 的 real_now 返回虚拟时钟占位值
  @rx.install_real_clock()
  let bus : @rx.EventBus[@watch.FsEvent] = @rx.EventBus::new()
  // 日志轮转：限制最大 1000 条，避免内存无限增长
  let log : Ref[Array[String]] = Ref::Ref([])
  // 真实执行记录累加器
  let records : Ref[Array[ExecRecord]] = Ref::Ref([])
  // 执行策略：允许清单为空（安全默认——不因配置而执行任意命令）
  let policy = @action.build_policy(allowed_programs(config))
  let n = attach_rules(
    config.rules,
    bus,
    policy,
    config.watch_dir,
    config.logging,
    log,
    records,
  )
  // 启动后台监控任务（rx 订阅同步阻塞，故必须放独立 async 任务）
  // 使用 with_task_group 管理后台任务生命周期
  @async.with_task_group(fn(group : @async.TaskGroup) {
    let _ = group.spawn(() => {
      @watch.spawn_watch_task(
        config.watch_dir,
        config.recursive,
        bus,
        debounce_ms=config.debounce_ms.to_int64(),
      )
    })
  })
  // 阻塞等待，直到任务组被取消
  // 使用一个无限循环来保持调度器运行
  while true {
    // 日志轮转：超过 1000 条时清空旧日志
    if log.val.length() > 1000 {
      log.val = []
    }
    @async.sleep(1000)
  }
  Ok("规则数 " + n.to_string() + "，订阅数 " + n.to_string())
}

///|
/// 返回配置显式声明的命令白名单（用于构造 ExecPolicy）
///
/// 安全语义（2026-11-17 修正）：白名单必须**显式声明**在配置的
/// `allowed_programs` 字段，不再从规则 argv[0] 自动收集——
/// 后者等于"规则写什么就自动放行什么"，架空白名单模型。
/// 空列表 ⇒ 安全默认：不执行任何命令。
pub fn allowed_programs(config : @config.Config) -> Array[String] {
  config.allowed_programs
}

///|
/// 一次性执行（用于测试 / 离线模式）
///
/// 守卫门语义与 attach_rules 一致：guard 不过记 guard_fail 并跳过动作
/// （单趟离线语义下 stop/skip 收敛为"跳过本规则动作"）。
///
/// 参数：
///   rules  - 规则表
///   ev     - 触发事件
///   policy - 执行策略
///   logging_config - 日志配置
///   watch_dir - 监控根目录（acceptance.artifact_glob 相对它解析）
///
/// 返回：执行日志
pub fn run_once(
  rules : Array[@config.Rule],
  ev : @watch.FsEvent,
  policy : @rt.ExecPolicy,
  logging_config : @config.LoggingConfig,
  watch_dir : String,
  registry~ : @action.InternalRegistry = @action.InternalRegistry::new(),
) -> Array[String] {
  let matched = @rule.dispatch(rules, ev)
  let log : Array[String] = []
  for r in matched {
    // 守卫门（schema v1.1）：执行前环境准入，通过才执行 actions
    let proceed = match r.guard_spec {
      Some(g) => {
        let gr = @action.run_guard(g, ev, policy)
        if gr.passed {
          true
        } else {
          // 守卫不过：记 guard_fail 并按 on_fail 决策跳过动作（run_once 单趟
          // 离线语义下 stop/skip 收敛为"跳过本规则动作"，退场无从体现）
          let (skip_actions, _retire) = guard_fail_decision(g.on_fail)
          log.push("rule " + r.id + " guard_fail: " + gr.reason)
          !skip_actions
        }
      }
      None => true
    }
    if proceed {
      for a in r.actions {
        match @action.run_action(a, ev, policy, logging_config, watch_dir, registry=registry) {
          Ok(o) =>
            if o.accepted {
              log.push(
                "rule " +
                r.id +
                " action " +
                a.kind +
                " ok exit=" +
                o.exit_code.to_string(),
              )
            } else {
              log.push(
                "rule " +
                r.id +
                " action " +
                a.kind +
                " acceptance_failed: " +
                o.acceptance_reason,
              )
            }
          Err(e) =>
            log.push("rule " + r.id + " action " + a.kind + " err: " + e)
        }
      }
    }
  }
  log
}
// ============================================================================
// P2 · 热重载
// ============================================================================

///|
/// 热重载配置
///
/// 参数：
///   rules_file - 规则配置文件路径
///
/// 返回：重载结果（成功/失败 + 规则数）
pub fn reload_config(rules_file : String) -> ReloadResult {
  match @config.Config::from_json_file(rules_file) {
    Ok(cfg) => ReloadResult::new(true, cfg.rules.length(), "")
    Err(e) => ReloadResult::new(false, 0, e)
  }
}

///|
/// 重载结果
#derive(Eq, Debug)
pub(all) struct ReloadResult {
  /// 是否成功
  ok : Bool
  /// 规则数
  rule_count : Int32
  /// 错误信息（成功时为空字符串）
  error : String
}

///|
pub extend ReloadResult with Eq::{not_equal, equal}

///|
pub extend ReloadResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 构造重载结果
pub fn ReloadResult::new(
  ok : Bool,
  rule_count : Int32,
  error : String,
) -> ReloadResult {
  { ok, rule_count, error, }
}

// ============================================================================
// EP-01a · internal 动作注册表接线（四 op 直连 scheduler 既有函数）
// ============================================================================

///|
/// 监控器运行时状态（EP-01a）：internal op 触达既有设施所需的最小上下文
///
/// 由守护进程（main run_daemon / cmd_run_once）构造一次，注册表闭包与
/// watch 订阅共享同一状态（paused 门控双端一致）。
pub struct WatcherState {
  /// 规则文件路径（reload_config op 直连既有 reload_config）
  rules_file : String
  /// 实例 id（{watch_id} 占位符展开）
  watch_id : String
  /// 监控根目录（{watch_dir} 占位符展开）
  watch_dir : String
  /// 暂停门控（pause_watch / resume_watch 翻转；watch 订阅回调据此丢弃事件）
  paused : Ref[Bool]
  /// 生命周期事件累加器（log_event op 落此；可测试断言，未来接 EventBus 发布）
  lifecycle_events : Ref[Array[@action.LifecycleEvent]]
}

///|
/// 构造监控器运行时状态（paused 缺省 false，事件流初始畅通）
pub fn WatcherState::new(
  rules_file : String,
  watch_id : String,
  watch_dir : String,
) -> WatcherState {
  {
    rules_file,
    watch_id,
    watch_dir,
    paused: Ref::Ref(false),
    lifecycle_events: Ref::Ref([]),
  }
}

///|
/// 构建 internal 动作注册表：schema 四 op 直连 scheduler 既有函数
///
///   - reload_config → 本文件既有 `reload_config`（P2 热重载通道；
///     失败时保留旧规则表语义由上层保证——本 op 只报告解析结果，不改规则表）
///   - pause_watch   → paused 门控置 true（watch 订阅停止向规则引擎投递）
///   - resume_watch  → paused 门控置 false
///   - log_event     → schema §7 占位符展开后落 LifecycleEvent（Logged）+ 可诊断日志
pub fn build_internal_registry(state : WatcherState) -> @action.InternalRegistry {
  let reg = @action.InternalRegistry::new()
  reg.register(
    "reload_config",
    fn(_spec : @config.ActionSpec, _ev : @watch.FsEvent, _d : String) {
      let r = reload_config(state.rules_file)
      if r.ok {
        @action.ActionOutcome::new(
          "internal", true, 0,
          "reload ok rules=" + r.rule_count.to_string(),
          "",
        )
      } else {
        @action.ActionOutcome::new(
          "internal", false, -1, "", "热重载失败: " + r.error,
        )
      }
    },
  )
  reg.register(
    "pause_watch",
    fn(_spec : @config.ActionSpec, _ev : @watch.FsEvent, _d : String) {
      state.paused.val = true
      @action.ActionOutcome::new("internal", true, 0, "watch paused", "")
    },
  )
  reg.register(
    "resume_watch",
    fn(_spec : @config.ActionSpec, _ev : @watch.FsEvent, _d : String) {
      state.paused.val = false
      @action.ActionOutcome::new("internal", true, 0, "watch resumed", "")
    },
  )
  reg.register(
    "log_event",
    fn(spec : @config.ActionSpec, ev : @watch.FsEvent, _d : String) {
      let msg = match spec.message {
        Some(m) => m
        None => ""
      }
      let (rendered, warns) = @action.render_placeholders(
        msg, ev, state.watch_dir, state.watch_id,
      )
      for w in warns {
        println("[warn] " + w)
      }
      let le = @action.LifecycleEvent::new_with_message(
        @config.LifecycleEventType::Logged, ev.path, rendered,
      )
      state.lifecycle_events.val.push(le)
      println(
        "[lifecycle] " +
        le.event_name() +
        " path=" +
        le.path +
        " message=" +
        le.message,
      )
      @action.ActionOutcome::new("internal", true, 0, rendered, "")
    },
  )
  reg
}
