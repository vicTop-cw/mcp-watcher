# mcp-watcher 开发计划（基于已验证的 rx 基座）

> **状态更新（2026-11-17）**：P0 已完成并通过双进程验收；rx 基座已发布 **0.4.4**
> （含 native watch 路径粘连修复），mcp-watcher 已切 registry 依赖 `RX-MBT@0.4.4`。
> 下文 §1.2 / §4 中关于「0.4.2」「moon.work 接入」「rx 未发布」的表述均为
> **当时的排期背景，已过时**——以 `p0-completion-report.md`（含 §10 修复闭环）为准。
> 当前实际进度：P0 ✅ / P1~P3 未开工。

> 前置：`rx-baseline-verification.md`（rx 基座独立验证报告，2026-11-15）
> 本文件把「基座已验证可用」这一事实转成 mcp-watcher 的**可执行开发分期**。
> 范围声明：本项目此前决议为「只做设计与规划」；本文件是**转向实现的第一份排期**，
> 是否即刻开工由用户决定。

---

## 0. 与既有计划的关系

| 文档 | 状态 | 说明 |
|------|------|------|
| `design-spec.md` | 有效 | 总体决议（四大支柱 + EP 扩展位） |
| `config-schema.md` | 有效 | 配置契约 |
| `rx-mbt-dependency.md` | **部分作废** | 其中「rx 缺什么」已被基座完成推翻 |
| `reuse-and-test-plan.md` | **需更新** | 蓝图仍成立，但其中的 API 形态与门控假设已被实测修正 |
| `rx-baseline-verification.md` | **新增·有效** | 本文件的事实基座 |

---

## 1. 已确认的可用基座（不再假设，直接消费）

### 1.1 消费映射

| mcp-watcher 组件 | rx API（实测可用） | 关键约束 |
|------------------|--------------------|----------|
| 事件源 | `@mon.watch_folder(dir)` → `Observable[WatchEvent, WatchError]` | **订阅同步阻塞**，必须后台 async 任务订阅 |
| 事件类型 | `@mon.WatchEvent` / `@mon.WatchKind` | 已 `pub(all)`，字段可跨包读 |
| 规则派发 | `@rx.EventBus[T]` / `@rx.TriggerRegistry[T]` | **泛型跨包必须完整类型标注**：`let b : @rx.EventBus[Int] = @rx.EventBus::new()` |
| 事件载荷 | `@rx.TriggerEvent[T]` | 同上，字段可读 |
| 时间/去抖 | `@rx.install_real_clock()` / `@rx.real_now()` / `real_interval` / `debounce_real` | `real_now` **必须先 install** 才返回真实墙钟 |
| 命令执行 | `@rt.run_command(policy, payload)` → `Observable[CommandResult, ExecError]` | `ExecPolicy` 默认只放行 `action:` / `handler:` |
| 策略 | `@rt.ExecPolicy::default()` / `.allows(need)` | 白名单语义 |
| 条件组合 | `@rx.all_of` / `any_of` / `not_` | 接收 `TriggerEvent[T] -> Bool` |
| 取消订阅 | `Subscription::dispose()` | 不是 `unsubscribe()` |
| 单回调订阅 | `Observable::subscribe_on_next(fn)` 等 | 完整控制用 `subscribe(Observer)` |

### 1.2 接入方式（已切换为 registry）

**当前**：`mcp-watcher/moon.mod` 声明 `import { "vicTop-cw/RX-MBT@0.4.4" }`，
通过 `moon add --upgrade vicTop-cw/RX-MBT@0.4.4` 从公共 registry 拉取，
**不再依赖 `moon.work` 父目录**。

> 历史背景（已过时）：最初用 `moon.work`（共同父目录 `E:\IDEProjects\AI\`，
> 成员 `mcp-watcher`）做本地接入，声明 0.4.2。rx 发布 registry 后已切换，
> 父目录清理不再影响接入。

---

## 2. 目标运行时架构（含实测约束的修正）

```
┌──────────────── 常驻守护进程（后台，不占 Agent 对话轮次）────────────────┐
│                                                                        │
│  ┌── 后台 async 任务 A（事件源）──────────────────────────────────┐    │
│  │  @mon.watch_folder(dir)                                        │    │
│  │    .subscribe_on_next(ev => bus.publish(ev.kind_name, ev))     │    │  ← 必须在独立
│  │  ★ 订阅闭包同步阻塞，故 A 与主循环分离                            │    │    后台任务
│  └────────────────────────────────────────────────────────────────┘    │
│                                                                        │
│  ┌── 后台 async 任务 B（cron 源）─────────────────────────────────┐    │
│  │  cron.next_after(ts) 自行计算（领域逻辑，留本项目）              │    │
│  │  @rx.real_interval(ms) 驱动，publish("cron.<id>", ...)          │    │
│  └────────────────────────────────────────────────────────────────┘    │
│                                                                        │
│  ┌── 规则内核 ──────────────────────────────────────────────────┐    │
│  │  @rx.EventBus[FsEvent]                                       │    │
│  │    订阅按规则 id 注册；条件用 @rx.all_of / any_of / not_        │    │
│  │  规则表热重载：Arc<RwLock<RuleTable>>，换表不换总线             │    │
│  └────────────────────────────────────────────────────────────────┘    │
│                                                                        │
│  ┌── 动作执行 ──────────────────────────────────────────────────┐    │
│  │  command  → @rt.run_command(ExecPolicy, payload)              │    │
│  │  mcp/webhook/internal → 待实现（EP-01 扩展位）                 │    │
│  └────────────────────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────────────────┘
```

**相对 design-spec 的三处修正**：

1. **事件源不再自建 @ffi 后端** —— 复用 rx 的 `monitor`（Windows `ReadDirectoryChangesW`）。
   跨平台（inotify / FSEvents）留待 rx 侧扩展。
2. **去抖归属明确** —— `debounce_real` 是 rx 的 Observable 操作子，
   应在**订阅链上**做（`watch_folder(...).debounce_real(ms)`），
   而非在规则内核里手写计时器。
3. **cron 表达式的解析与推进留在本项目**（领域逻辑），
   rx 只提供 `real_interval` 驱动原语 —— 与 `reuse-and-test-plan.md` 结论一致。

---

## 3. 开发分期

每期结束时的验收门禁统一为：
`moon check --target {wasm,native,js}` 0 error + `moon test --target native` 全绿
+ 本期新增测试数 > 0。**禁止整仓 `cargo fmt` 式全量格式化**（本项目用 `moon fmt <路径>`）。

### P0 · 接入层落地（预计 1 期）

| 任务 | 产出 |
|------|------|
| `watch/backend.mbt` 去占位 | 接入 `@mon.watch_folder`，`WatchSource` trait 保留为**多后端扩展位**（EP-01），native 实现委托 rx |
| `watch/event.mbt` 对齐 | `FsEvent` 与 `@mon.WatchEvent` 的映射（`WatchKind` → 本项目 `EventType`） |
| `action/action.mbt` 接 command | `run_action` 的 `command` 分支接入 `@rt.run_command` + `ExecPolicy`；`mcp_tool_call` / `webhook` 仍返回可诊断 Err |
| 依赖声明固化 | `moon.mod` / `moon.pkg` / `moon.work` 三处一致；`util/moon.pkg`、`tests/probe/moon.pkg` 的 import 清理 |
| CLI 骨架 | `cmd/main` 子命令：`start` / `status` / `validate` / `run --once`（`reload` 随 P2） |

**验收**：启动后能对真实目录产出一条 `FsEvent`（用双进程 harness 验证），
`command` 动作能跑通一次受白名单约束的执行。

### P1 · 规则内核与派发（预计 1 期）

| 任务 | 产出 |
|------|------|
| 规则总线 | `EventBus[FsEvent]` 封装；事件名约定 `<kind>.<path-glob>` |
| Layer1 匹配 | 现有 `rule/matcher.mbt` 接到总线上（事件类型 → patterns → exclude） |
| Layer2 条件 | `ConditionSpec.expr` → 编译为 `TriggerEvent -> Bool`，用 `@rx.all_of/any_of/not_` 组合 |
| 去抖链 | 在订阅链上接 `debounce_real(config.debounce_ms)` |
| 优先级与 once | `Rule.priority` / `stop_after` 落到 `TriggerRegistry` 的 priority / once 语义 |

**验收**：单条规则命中/不命中/排除/条件失败四类路径各有测试覆盖；
`once` 语义验证（同一事件不重复触发）。

### P2 · 热重载（预计 1 期）

| 任务 | 产出 |
|------|------|
| 规则表容器 | `Arc<RwLock<RuleTable>>`（或等价可换表结构） |
| 重载触发 | 配置文件 mtime 轮询（rx 无 inotify 跨平台，用 `fs_stat` diff）→ 解析 → 语义校验 → 原子换表 |
| 校验失败不炸 | 校验失败保留旧表 + 记录诊断，**不停机**（四大支柱之一） |
| CLI | `reload` 子命令 + `status` 显示当前表版本与加载时间 |

**验收**：运行中改配置 → 无需重启即生效；故意写坏配置 → 旧规则继续工作且有明确诊断输出。

### P3 · 产物生命周期语义（预计 1~2 期）

这是与「通用文件触发器」的分水岭，必须做实：

| 任务 | 产出 |
|------|------|
| TTL 语义 | 产物带 `ttl`（到期自动清理）；清理动作可配置为 `trash`（移入回收目录）而非直接 `rm` |
| trash 实现 | 移入 `.mcp-watcher-trash/<时间戳>/`，保留可恢复窗口；用 rx `fs_write_atomic` + 目录 rename |
| 加密动作 | 产物加密（复用 rx `rhop` 的 `RhopCrypto` / `RhopEnvelope` 思路，不引入新依赖） |
| 生命周期事件 | 产物创建/到期/销毁发到 `EventBus`，可被规则订阅（产物生命周期本身成为事件源） |

**验收**：产物在 TTL 到期后进入 trash 而非消失；加密产物可被对应动作解密还原。

### P4 · 双进程集成测试（贯穿 P0~P3）

沿用既有 `tests/harness/`（`trigger.py` / `verify.py` / `scenarios/`），
把 `server_contract.md` 的服务端协议真正实现：

| 任务 | 产出 |
|------|------|
| 服务端 test-mode | `mcp-watcher start --watch-dir <dir> --results <file> --ready <file> --stop-after <n>` |
| 结果落盘 | 每条事件/动作结果写 JSONL（字段遵循 `server_contract.md`） |
| 触发端 | `trigger.py` 造事件（创建/修改/删除/重命名），独立进程 |
| 校验端 | `verify.py` 读 JSONL 断言（PASS/FAIL） |
| 场景集 | `scenarios/*.json` 覆盖：基本触发、去抖合并、exclude、cron 触发、策略拒绝、TTL 过期 |

**验收**：`bash tests/harness/run.sh` 一条命令跑完全场景，全绿。
**这是「一个服务器开着，另一个程序去做触发」这一要求的落地。**

---

## 4. 已知风险与前置

| 风险 | 影响 | 应对 |
|------|------|------|
| rx 未发布，接入依赖 `moon.work` 父目录 | 父目录被清理 → 接入失效 | 优先让 rx 发布 0.4.2，改 registry 依赖 |
| R2 订阅同步阻塞 | 若在主循环 subscribe，进程会假死 | 强制：事件源订阅放独立 async 任务；加测试守护 |
| R2 仅 Windows（`ReadDirectoryChangesW`） | 非 Windows 环境不可用 | 参赛环境是 Windows；跨平台留 rx 侧扩展 |
| rx 泛型类型跨包需完整标注 | 写法错误会报"值未找到"而非类型错误，易误判 | 已写入本文件 §1.1；代码评审检查 |
| `real_now` 需先 install | 未 install 时是虚拟时钟 | 启动流程固定调用 `install_real_clock()` |
| `moon.work` 使 rx 门禁纳入本项目 | rx 的 wasm/js 门禁会因本项目代码红 | 本项目所有包必须**三目标可编译**；native-only 代码用 `moon.pkg` 的 `targets` 门控（见 `tests/probe/moon.pkg`） |
| rx 仓库卫生差（100 项改动 / 散落日志） | 提交时易混入垃圾 | 提交前清理并按 §4 分类核对 |

---

## 5. 与既有文档的待办对齐

| 文档 | 待办 |
|------|------|
| `reuse-and-test-plan.md` | 更新其中的 API 形态（泛型标注、`dispose` 而非 `unsubscribe`、`real_now` 需 install）与门控假设 |
| `rx-baseline-verification.md` §8 | 5 项遗留事项待用户决策，其中「基座提交与发布」直接决定接入方式 |
| `../rx-mbt/ISSUES-mcp-watcher-gap-audit.md` | 已陈旧，需重写或标注作废（审计文档留在 rx 仓库内） |

---

## 6. 下一步（建议）

1. **用户决策**：rx 基座是否提交 + push + publish 0.4.2？—— 决定 mcp-watcher 用 registry 还是 `moon.work` 接入。
2. **P0 开工**：接入层落地（watch/action/CLI 骨架），同步实现服务端 test-mode（`server_contract.md` 已就位）。
3. **P0 验收**：双进程 harness 跑通第一条真实事件链路。

> 按用户既有工作流（请求变更 → 运行测试 → 修复失败 → 记录进度 → 下一步），
> 每期完成后应产出含门禁表格（测试数 / check 0 error / git 状态）的技术报告，
> 并保存至项目内 `workbuddy/plan/`。
