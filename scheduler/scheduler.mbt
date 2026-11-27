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
/// 调度循环魔法数字收敛
/// LOG_ROTATE_THRESHOLD：日志超过该条数时清空（轮转）
/// MAIN_LOOP_SLEEP_MS：主循环休眠间隔（毫秒）
const LOG_ROTATE_THRESHOLD = 1000
const MAIN_LOOP_SLEEP_MS = 1000
/// 真实时钟驱动间隔（毫秒）：run_scheduler 内 spawn 的 drive_real_clock 周期
/// （EP-02a；与 cmd/main/main.mbt 同名常量同值，跨包不可见故各自定义）
const CLOCK_DRIVE_INTERVAL_MS : Int64 = 100L
/// 热重载订阅数：create.* + modify.* 两条总线订阅
const RELOAD_SUBSCRIBE_COUNT : Int32 = 2

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
  watch_id~ : String = "",
  registry~ : @action.InternalRegistry = @action.InternalRegistry::new(),
  // EP-01d 共享规则表（热重载）：Some = 按同 id 的 live 版本分派（被 reload
  // 移除的规则 no-op）；None = 静态表（v1.0 行为，位级兼容）
  rules_ref~ : Ref[Array[@config.Rule]]? = None,
  // EP-02b 已挂账 id 集（热重载增量重挂的差集依据）：Some = 每条规则挂订后
  // 追加 id；None = 不记账（位级兼容）
  attached_ids~ : Ref[Array[String]]? = None,
  // P3：产物 TTL 追踪表 + 生命周期事件出口（daemon 持有；None = 只落本地累加器）
  tracked~ : Ref[@action.ProductTracker] = Ref::Ref({ records: [] }),
  lifecycle_bus~ : @action.LifecycleBus? = None,
  lifecycle_events~ : Ref[Array[@action.LifecycleEvent]] = Ref::Ref([]),
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
    // EP-03b：共享触发体——文件事件与 interval 触发走同一 handler 链
    //（退场记账/live 分派/守卫/验收/动作全共享），仅触发来源不同。
    let fire = fn(fe : @watch.FsEvent) -> Unit {
      // 检查是否已退场（once 语义 / guard on_fail=stop 退场）
      if executed_rules.val.contains(rule.id) {
        return
      }
      // EP-01d 热重载：共享规则表存在时，取同 id 的 live 版本分派；
      // 该规则被 reload 移除 → 本订阅 no-op
      let live : @config.Rule? =
        match rules_ref {
          Some(rr) => rule_by_id(rr.val, rule.id)
          None => Some(rule)
        }
      // 此后以 live 版本分派（遮蔽原 rule；id 相同，退场记账不受影响）
      let rule = match live {
        Some(l) => l
        None => return
      }
      // interval 触发（live 规则含 interval 条目）无文件事件语义（类型/
      // 模式匹配），直达守卫/动作；热重载摘除 interval 后退化为 dispatch
      // 路径，合成事件空路径不命中 patterns，安全 no-op
      let matched = if interval_ms_of(rule) > 0L {
        true
      } else {
        @rule.dispatch([rule], fe).length() > 0
      }
      if matched {
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
            rule, fe, policy, logging_config, watch_dir, watch_id,
            log, records, registry, tracked, lifecycle_bus, lifecycle_events,
          )
          // 记录已执行（once 语义）
          if rule.stop_after {
            executed_rules.val.push(rule.id)
          }
        }
      }
    }
    for ev_name in event_names_of(rule) {
      // P1：priority 落到 TriggerRegistry（rx 派发时按 priority 降序、同优先保持
      // 注册序）；规则表自身的预排序只决定注册序 tie-break，不再是唯一依据。
      let _ = bus.subscribe(
        ev_name,
        fn(ev : @rx.TriggerEvent[@watch.FsEvent]) { fire(ev.payload) },
        priority=rule.priority,
      )
      subscribed.val = subscribed.val + 1
    }
    // EP-03b：interval 触发源——events 里的 "interval:<ms>" 条目经 EP-01d
    // 真实时钟泵驱动的 @rx.interval 发射（subscribe 即注册，回调按真实时间
    // 触发，免任务组）；合成事件空路径 + Other 类型，fire 内按 live 规则的
    // interval-ness 跳过 dispatch
    if interval_ms_of(rule) > 0L {
      let _ = @rx.interval(interval_ms_of(rule)).subscribe_on_next(fn(tick : Int64) {
        let _ = tick
        fire(@watch.FsEvent::new(@config.EventType::Interval, "", false, 0, 0))
      })
      subscribed.val = subscribed.val + 1
    }
    // EP-02b：记账已挂订 id（热重载增量重挂据此差集）
    match attached_ids {
      Some(ids) => ids.val.push(rule.id)
      None => ()
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
  watch_id : String,
  log : Ref[Array[String]],
  records : Ref[Array[ExecRecord]],
  registry : @action.InternalRegistry,
  // P3：TTL 追踪表 + 生命周期事件出口（None = 事件只落本地累加器）
  tracked : Ref[@action.ProductTracker],
  bus : @action.LifecycleBus?,
  events : Ref[Array[@action.LifecycleEvent]],
) -> Unit {
  for a in rule.actions {
    match @action.run_action(
      a, fe, policy, logging_config, watch_dir, watch_id=watch_id,
      registry=registry, tracked=tracked, bus=bus, events=events,
    ) {
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
/// EP-03b：interval 触发源毫秒数（events 里的 "interval:<ms>" 条目）。
/// 无 interval 条目或毫秒数非法返回 0；低于 INTERVAL_MIN_MS 触底到下限；
/// 多个 interval 条目取首个有效值。
pub fn interval_ms_of(rule : @config.Rule) -> Int64 {
  for e in rule.events {
    if e.has_prefix("interval:") {
      match (try Ok(@string.parse_int64(e[9:].to_owned())) catch { err => Err(err) }) {
        Ok(ms) =>
          return if ms < @config.INTERVAL_MIN_MS {
            @config.INTERVAL_MIN_MS
          } else {
            ms
          }
        Err(_) => return 0L
      }
    }
  }
  0L
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
    // EP-02a：真实时钟驱动——install_real_clock 只注入墙钟，不推进；
    // 缺驱动则 debounce_real / interval 等时间算子挂在虚拟时钟上永不触发
    let _ = group.spawn(() => {
      @rx.drive_real_clock(CLOCK_DRIVE_INTERVAL_MS)
    })
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
    // 日志轮转：超过 LOG_ROTATE_THRESHOLD 条时清空旧日志
    if log.val.length() > LOG_ROTATE_THRESHOLD {
      log.val = []
    }
    @async.sleep(MAIN_LOOP_SLEEP_MS)
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
  watch_id~ : String = "",
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
        match @action.run_action(
          a, ev, policy, logging_config, watch_dir, watch_id=watch_id,
          registry=registry,
        ) {
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
/// 读取并解析规则表（EP-01d 热切换数据源；reload_config 复用）
pub fn reload_rules(rules_file : String) -> Result[Array[@config.Rule], String] {
  match @config.Config::from_json_file(rules_file) {
    Ok(cfg) => Ok(cfg.rules)
    Err(e) => Err(e)
  }
}

///|
/// 热重载配置
///
/// 参数：
///   rules_file - 规则配置文件路径
///
/// 返回：重载结果（成功/失败 + 规则数）
pub fn reload_config(rules_file : String) -> ReloadResult {
  match reload_rules(rules_file) {
    Ok(rules) => ReloadResult::new(true, rules.length(), "")
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
  /// EP-01d 共享规则表（daemon 传 live 表；reload op 成功时热切换；
  /// attach_rules 按 id 分派 live 版本；None = 无热切换能力，仅报告）
  rules_ref : Ref[Array[@config.Rule]]?
}

///|
/// 构造监控器运行时状态（paused 缺省 false，事件流初始畅通）
pub fn WatcherState::new(
  rules_file : String,
  watch_id : String,
  watch_dir : String,
  rules_ref~ : Ref[Array[@config.Rule]]? = None,
) -> WatcherState {
  {
    rules_file,
    watch_id,
    watch_dir,
    paused: Ref::Ref(false),
    lifecycle_events: Ref::Ref([]),
    rules_ref,
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
      match reload_rules(state.rules_file) {
        Ok(rules) => {
          let count = rules.length()
          match state.rules_ref {
            Some(rr) => {
              rr.val = rules
              @action.ActionOutcome::new(
                "internal", true, 0,
                "reload ok rules=" + count.to_string() + "（规则表已热切换）",
                "",
              )
            }
            None =>
              @action.ActionOutcome::new(
                "internal", true, 0,
                "reload ok rules=" + count.to_string(),
                "",
              )
          }
        }
        Err(e) =>
          @action.ActionOutcome::new(
            "internal", false, -1, "", "热重载失败: " + e,
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

// ============================================================================
// EP-01d  rules_file 变更热重载
// ============================================================================
//
// 链路：bus(create.*/modify.*) → 路径匹配 → RulesFileDebounce（防抖状态机）
//       → @rx.timer 一次性定时器（每事件重武装；rx 无取消 API，靠「只有
//         最后武装的定时器可能满足 due」天然合并，突发至多触发一次）
//       → internal 通道 reload_config op → rules_ref 热切换。
//
// 前提：daemon 已安装并驱动真实时钟（install_real_clock + drive_real_clock，
// 见 main.mbt run_daemon）；测试走 install_real_clock_with + real_clock_tick
// 的确定性路径（见 reload_test.mbt）。

///|
/// 从规则表按 id 找规则（EP-01d 热重载；core Array 无 find，手写查找）
fn rule_by_id(rules : Array[@config.Rule], id : String) -> @config.Rule? {
  let mut i = 0
  while i < rules.length() {
    if rules[i].id == id {
      return Some(rules[i])
    }
    i = i + 1
  }
  None
}

///|
/// 规则文件变更防抖状态机（纯逻辑，假时钟可测）
pub struct RulesFileDebounce {
  pending : Ref[Bool]
  last_event : Ref[Int64]
}

///|
pub fn RulesFileDebounce::new() -> RulesFileDebounce {
  { pending: Ref::Ref(false), last_event: Ref::Ref(0L) }
}

///|
/// 记录一次 rules_file 变更事件（突发内重复记录；last_event 更新为最新）
pub fn RulesFileDebounce::record(
  self : RulesFileDebounce,
  now_ms : Int64,
) -> Unit {
  self.pending.val = true
  self.last_event.val = now_ms
}

///|
/// 是否到点触发：存在 pending 事件且静默窗口（自最新事件起）已过
pub fn RulesFileDebounce::due(
  self : RulesFileDebounce,
  now_ms : Int64,
  window_ms : Int64,
) -> Bool {
  self.pending.val && (now_ms - self.last_event.val >= window_ms)
}

///|
/// 触发后清除 pending（调用方在执行 reload 前后调用）
pub fn RulesFileDebounce::fire(self : RulesFileDebounce) -> Unit {
  self.pending.val = false
}

///|
/// 反斜杠归一为正斜杠（Windows / POSIX 两种路径形态统一比较）
fn normalize_slashes(p : String) -> String {
  let a = p.to_array()
  let n = a.length()
  let mut i = 0
  let mut out = ""
  while i < n {
    let c = a[i]
    if c == '\\' {
      out = out + "/"
    } else {
      out = out + c.to_string()
    }
    i = i + 1
  }
  out
}

///|
/// 路径匹配：归一后精确相等或「/」分段后缀匹配（覆盖「监控根相对路径」与
/// 「绝对路径」两种事件形态；不做 basename 匹配，避免异目录假阳）
pub fn rules_file_event_match(ev_path : String, rules_file : String) -> Bool {
  let a = normalize_slashes(ev_path)
  let b = normalize_slashes(rules_file)
  if a == b {
    true
  } else if a.has_suffix("/" + b) {
    true
  } else if b.has_suffix("/" + a) {
    true
  } else {
    false
  }
}

///|
/// 是否为 reload 触发事件类型（文件被写入或新出现；delete/rename 不触发）
pub fn is_reload_trigger(ev : @watch.FsEvent) -> Bool {
  match ev.event_type {
    @config.EventType::Modify | @config.EventType::Create => true
    _ => false
  }
}

///|
/// 规则文件所在目录（"a/b/rules.json" → "a/b"；"rules.json" → "."）
pub fn rules_file_dir(path : String) -> String {
  let a = normalize_slashes(path)
  let arr = a.to_array()
  let n = arr.length()
  let mut i = n
  while i > 0 {
    i = i - 1
    if arr[i] == '/' {
      let mut out = ""
      let mut j = 0
      while j < i {
        out = out + arr[j].to_string()
        j = j + 1
      }
      return out
    }
  }
  "."
}

///|
/// 外层目录是否覆盖内层目录（归一后：根「.」覆盖一切；相等；或内层为
/// 外层的「/」分段前缀）
pub fn dir_covers(outer : String, inner : String) -> Bool {
  let o = normalize_slashes(outer)
  let i2 = normalize_slashes(inner)
  if o == "." || o == "" {
    true
  } else if o == i2 {
    true
  } else if i2.has_prefix(o + "/") {
    true
  } else {
    false
  }
}

///|
/// 经 EP-01a internal 通道触发规则重载（reload_config op）；结果落 log
///（可诊断）；op 未注册 → 诊断日志（不抛异常）。
/// 返回是否热切换成功（EP-02b：增量重挂据此决定是否挂新增 id）。
pub fn fire_rules_reload(
  registry : @action.InternalRegistry,
  state : WatcherState,
  ev : @watch.FsEvent,
  log : Ref[Array[String]],
) -> Bool {
  let spec = @config.ActionSpec::new_internal("reload_config", None)
  match registry.lookup("reload_config") {
    Some(handler) => {
      let outcome = handler(spec, ev, state.watch_dir)
      if outcome.ok {
        log.val.push("rules_file reload ok: " + outcome.stdout)
        println("[reload] " + outcome.stdout)
      } else {
        log.val.push("rules_file reload err: " + outcome.stderr)
        println("[reload] ⚠️ " + outcome.stderr)
      }
      outcome.ok
    }
    None => {
      log.val.push("rules_file reload: internal op reload_config 未注册")
      println("[reload] ⚠️ internal op reload_config 未注册，跳过热重载")
      false
    }
  }
}

///|
/// 订阅 rules_file 变更热重载（EP-01d）
///
/// bus 事件（create.*/modify.*）→ 路径匹配 → 防抖状态机 record →
/// 一次性 @rx.timer（每事件重武装；无取消 API 下「只有最后武装的定时器
/// 可能满足 due」，突发至多触发一次——先前武装的定时器到点时 due 不成立
/// 而自然作废）。到点：经 internal 通道 fire reload（fire_rules_reload）。
///
/// 前提：真实时钟已安装并被驱动（daemon：install_real_clock +
/// drive_real_clock；测试：install_real_clock_with + real_clock_tick）。
///
/// 返回订阅数（2：create.* + modify.*）。
pub fn attach_rules_file_reload(
  bus : @rx.EventBus[@watch.FsEvent],
  state : WatcherState,
  registry : @action.InternalRegistry,
  window_ms : Int64,
  log : Ref[Array[String]],
  // EP-02b 热切换钩子：reload 成功后以新规则表回调（daemon 据此对新增 id
  // 增量重挂订阅，免重启生效）；None = 维持 EP-01d 行为（只切表）
  //（注意括号：((A) -> Unit)? 是可选闭包；(A) -> Unit? 是返回 Option 的闭包）
  on_rules_swapped~ : ((Array[@config.Rule]) -> Unit)? = None,
) -> Int32 {
  let d = RulesFileDebounce::new()
  let handler = fn(ev : @rx.TriggerEvent[@watch.FsEvent]) {
    let fe = ev.payload
    if state.paused.val {
      return
    }
    if !is_reload_trigger(fe) {
      return
    }
    if !rules_file_event_match(fe.path, state.rules_file) {
      return
    }
    d.record(@rx.real_now())
    let _ = @rx.timer(window_ms).subscribe_on_next(fn(_t : Int64) {
      if d.due(@rx.real_now(), window_ms) {
        d.fire()
        let ok = fire_rules_reload(registry, state, fe, log)
        // EP-02b：热切换成功 → 以新规则表回调（timer 回调在总线派发外运行，
        // 此处挂新订阅安全）
        match (ok, on_rules_swapped, state.rules_ref) {
          (true, Some(hook), Some(rr)) => hook(rr.val)
          _ => ()
        }
      }
    })
  }
  let _n1 = bus.subscribe("create.*", handler)
  let _n2 = bus.subscribe("modify.*", handler)
  RELOAD_SUBSCRIBE_COUNT
}
