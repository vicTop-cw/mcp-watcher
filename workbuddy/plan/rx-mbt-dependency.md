# rx-mbt 作为核心依赖的决策（mcp-watcher · v1.0）

> 配套《详细设计决议 `design-spec.md`》。本文回答三件事：(1) rx-mbt 能否作为核心依赖、还缺什么；(2) 命令调用的标准库现状；(3) cron 表达式触发怎么设计。
> 决策权：用户授权"你来决定后面的设计"，以下为**决议**，后续实现以本文 + `design-spec.md` 为准。
> 格式：Markdown（取代 docx）。

---

## 1. 结论速览

| 议题 | 决议 |
|------|------|
| rx-mbt 作为核心依赖 | **是**。`moon add vicTop-cw/RX-MBT@0.4.0`，但**只导入 `@rx` 核心 + `@rx.trigger`**，不导入 `@rx.monitor` / `@rx.rhop_task` |
| 文件系统监听 | rx 的 native 后端是占位（`Unsupported`），**mcp-watcher 自己用 `@ffi` 写 inotify/FSEvents/ReadDirectoryChangesW 后端**（与 `design-spec.md` §1 一致） |
| 命令执行标准库 | core 无 process API；能力在官方 `moonbitlang/async` 的 `@process`（native 跨平台，含 Windows）。**采用 `@process` + rx 的 `ExecPolicy` 白名单模型** |
| cron 触发 | rx 无 cron 解析；**自建 `cron` 包（纯逻辑、可测）+ 复用 `TriggerRegistry` 把 cron 事件并入同一派发管线** |
| 时间算子（debounce/throttle） | rx 是虚拟时钟；**将虚拟时钟按真实墙钟增量 `advance`**，使其等价于真实时间，从而复用 |

---

## 2. rx-mbt 现状盘点（已读源码核实）

`E:/IDEProjects/AI/rx-mbt/`（`moon.mod`：`name = "vicTop-cw/RX-MBT"`, `version = "0.4.0"`, Apache-2.0, 零外部依赖, `preferred_target = "wasm"`）。

### 2.1 可直接复用的部分

- **`rx/trigger.mbt` · `TriggerRegistry[T]`** —— 这是最值得复用的资产：
  - `event_matches(pattern, name)`：按 `.` 分段的通配匹配，支持 `*`(单段) / `**`(多段)，**不引入正则**，正好映射 mcp-watcher 的"事件名 = `<事件类型>.<glob>`"派发。
  - `register_with(event_name, handler, condition~, once~, priority~)`：条件 + 一次性 + 优先级，与我们的两层匹配（Layer1 事件+glob，Layer2 condition）天然契合。
  - `fire_at(name, payload, at)` / `fire_with_key`（幂等去重）/ `unregister` / `once` 自动注销：规则热重载（EP 相关）与去重免费获得。
  - **注意**：`fire(name, payload)` 内部取 `default_clock.now()`（虚拟时钟）。真实时间派发必须显式调用 `fire_at(name, payload, real_now_ms)`，不能用 `fire`。
- **`rx/RX-MBT.mbt` · `Observable[T,E]` / `Observer` / `Subscription`** —— action 管线（一个事件可扇出到多个 action，支持 error/complete）可直接复用。
- **`rx/ops_time.mbt` · `debounce` / `throttle` / `timeout` / `sample`** —— 算法可复用；基于 `Clock`（虚拟），见 §6.3 的"真实化"技巧。
- **`monitor/watch_event.mbt` · `WatchEvent` / `WatchKind`** —— 类型定义可参考，但 native 后端不可用，我们自建 `FsEvent`（轻量，不导入 `monitor` 包）。

### 2.2 不可用 / 需替换的部分（即"rx 还缺什么"）

| 缺口 | rx 现状 | mcp-watcher 对策 |
|------|---------|------------------|
| **G1 原生文件监控** | `monitor/watcher_native.mbt` 是占位，返回 `WatchError::Unsupported("native target 暂不支持文件监控：MoonBit core 无文件系统 API")` | 自建 `@ffi` 后端（已在 `design-spec.md` §1 决议），只复用 `WatchEvent` 类型思路 |
| **G2 真实时钟调度** | `rx/ops_time.mbt` 的 `Clock` 是**虚拟时钟**（`advance(ms)` 手动推进），无真实定时器/线程 | 用 `moonbitlang/async` 的事件循环 + `@async.sleep` 做真实定时器；虚拟时钟按墙钟增量推进以复用时间算子 |
| **G3 原生子进程** | `rhop_task/task_exec.mbt` 的 `run_cli` 是 `#cfg(target="js")` 的 `spawnSync`，非 js 返回 `Unsupported` | 用 `moonbitlang/async` 的 `@process`（native 跨平台），**借用 rx 的 `ExecPolicy` 白名单 + argv 数组、不走 shell 的安全模型** |
| **G4 cron 解析** | 完全没有 | 自建 `cron` 包（纯逻辑、确定性、可单测） |
| **G5 `fire` 用虚拟时钟** | 见 2.1 | 派发时一律 `fire_at(.., real_now_ms)` |

> 一句话：rx 给了我们**派发引擎 + 响应式管线 + 时间算子算法**，但**文件系统后端、真实定时器、原生子进程、cron 解析**这四项必须 mcp-watcher 自己补——这正是 `design-spec.md` 已规划用 `@ffi` / 自建模块覆盖的部分，二者不冲突。

---

## 3. 依赖决策（决议）

**【决议】** mcp-watcher 的依赖栈（native 单二进制，静态链接，零外部 OS 依赖）：

1. **`vicTop-cw/RX-MBT@0.4.0`** —— 仅导入：
   - `@rx`（Observable / Observer / Subscription）
   - `@rx.trigger`（`TriggerRegistry`）
   - 不导入 `@rx.monitor`、`@rx.rhop_task`（native 不可用 / js-only，避免无关代码进二进制）。
2. **`moonbitlang/async`**（官方包）—— `@process`（命令）、`@fs`（文件 I/O）、`@async`（事件循环 / TaskGroup / sleep）。
3. **平台 FFI**（`@ffi`）—— inotify / FSEvents / ReadDirectoryChangesW 监听后端。

理由：rx 是用户自研、零依赖、已发布的库，复用其派发引擎零代价且可控；async 是官方包，静态链接不破坏"单二进制零运行期依赖"目标（依赖的是 MoonBit 生态内的包，不是系统动态库）。

---

## 4. 命令调用标准库——诚实回答

- **core 标准库没有 process / 文件系统 API**（MoonBit 稳定版现状）。
- 命令执行能力在官方 **`moonbitlang/async`** 包，名为 **`@process`**，native 目标可用、跨平台（Unix + Windows）：
  - `@process.run(cmd, args)` → 退出码
  - `@process.spawn(group, cmd, args, ..)` → 后台子进程（结构化并发，随 TaskGroup 终止自动回收）
  - `@process.collect_stdout` / `collect_stderr` / `collect_output` / `collect_output_merged`
  - `@process.spawn_shell`（Unix 经 `/bin/sh -c`，Windows 经 `cmd.exe /c`）——**仅在确需 shell 时用，默认不开**
- 示例（来自官方 async 文档，native 非 Windows）：
  ```moonbit
  let (status, output) = @process.collect_output_merged("echo", ["hi"])
  ```
- **安全模型**（决议）：`command` action 的执行引擎用 `@process`，但**策略层采用 rx `rhop_task` 的 `ExecPolicy` 白名单模型**：
  - `allow : Array[String]`（`cli:<prog>` / `action:<name>` / `*`，尾部 `*` 通配）、`allow_any : Bool=false`、`timeout_sec`。
  - **一律 argv 数组 + `shell=false`**，绝不字符串拼接 shell，防注入。
  - `command` action 默认只放行白名单程序；任意命令需显式 `allow` 或 `allow_any=true`（与 `design-spec.md` §6 action 安全一致）。

> 结论：**有标准库，但不是 core，而是 `moonbitlang/async` 的 `@process`**。对 daemon 而言引入 async 是自然的（本就需要事件循环），且静态链接、零外部 OS 依赖，与单二进制目标兼容。

---

## 5. cron 表达式触发——设计（决议）

### 5.1 总原则：cron 与 fs 事件并入同一条派发管线

fs 事件和 cron 事件都只是 `TriggerRegistry` 的"事件名"，共享同一套 `condition` / `action` / 扩展位（EP-01~EP-12）。差异只在**事件源**：一个来自 FFI 监听后端，一个来自定时器。

```
        ┌─────────────┐         ┌──────────────┐
 fs事件 →│ FFI 后端     │         │ cron 调度器   │──┐
        │(inotify等)   │         │(async+sleep) │  │
        └──────┬──────┘         └──────┬───────┘  │
               │ name="create.*.md"    │ name="cron.<rule_id>"
               └───────────┬───────────┘
                           ▼
                  ┌────────────────────┐
                  │ TriggerRegistry     │  ← 复用 rx
                  │ (glob+cond+prio)    │
                  └─────────┬──────────┘
                            ▼
                  ┌────────────────────┐
                  │ Action 管线         │  ← 复用 rx Observable
                  │ (command/mcp/webhook)│
                  └────────────────────┘
```

### 5.2 `cron` 包（新建，纯逻辑、可测）

- `struct CronExpr { minute; hour; dom; month; dow }`（每字段为"集合/步进/范围"的归一表示）。
- `CronExpr::parse(s : String) -> Result[CronExpr, String]`：解析标准 5 段 `分 时 日 月 周`（支持 `*`、`*/n`、`a-b`、`a,b`，可选第 6 段秒留给 EP）。
- `next_after(self, from : Timestamp) -> Timestamp`：从 `from` 起算下一个触发时刻（标准算法：逐字段进位 + 日/周互斥择近）。
- **纯函数、确定性**：这是 Tnr 式测试门禁的落点——单测覆盖边界（`* * * * *`、月末、`2/5` 步进、周日/周一看齐）。

### 5.3 调度器（新建 `scheduler`，native，async）

- 持有 `Map[rule_id, (CronExpr, next_fire_ms)]`。
- 主循环（async）：
  1. `due = min(next_fire)`；`@async.sleep_until(due)`（或 `poll` 监听 fd 并带超时）。
  2. 醒来后，对所有到期 cron 规则：合成 `FsEvent{ event_type: Cron, path: "<rule_id>@cron", .. }`，`registry.fire_at("cron.<rule_id>", payload, real_now_ms)`。
  3. 同时消费 FFI 后端的 fs 事件：`registry.fire_at("<event_type>.<glob>", payload, real_now_ms)`。
  4. 重新计算各 cron 的 `next_fire = expr.next_after(now)`，回到 1。
- 退出：监听 `stop` 信号 / self-pipe，结束 async 主循环。

### 5.4 时间算子的"真实化"（复用 rx debounce/throttle）

- rx 的 `Clock` 是虚拟的。技巧：在 daemon 里维护墙钟，每次事件到达时调用 `default_clock.advance(real_delta_ms)`，把虚拟时钟"追上"真实时间。这样 `debounce`/`throttle` 在真实时间下也正确，无需重写算法。
- v1.0 范围：debounce 主要用于 fs 事件（同一文件连续 modify 合并）；cron 触发本身是离散的（`next_after` 已保证间隔），v1.0 不强制给 cron 套 debounce，但管线已具备该能力。

---

## 6. 对 `design-spec.md` 的修订点

| 原决议（design-spec §1/§6） | 本文修订 |
|----------------------------|----------|
| §1「文件系统监听通过 `@ffi`」 | 不变；补充：rx 的 native monitor 是占位，确认不导入 |
| §6「command action」 | 执行引擎由"自建 FFI spawn"修订为"**`@process`（async）+ `ExecPolicy` 白名单模型**"，更安全且少造轮子 |
| 扩展位 EP-01~EP-12 | 不变；cron 规则复用同一 action 管线，无需新扩展位 |
| 门禁纪律（状态=真实、累积校验） | 不变；`cron.next_after` 单测纳入门禁 |

---

## 7. 门禁 / 测试影响

- 新增 `cron` 包单测：`parse` 合法/非法、`next_after` 边界（含跨月/闰年/周日对齐），作为测试数真源的一部分。
- `TriggerRegistry` 派发：用 rx 既有的 `fire_at` + 虚拟时钟推进写集成测试，验证 fs 事件与 cron 事件走同一管线。
- `command` action：用 `@process` 跑白名单内（`echo`/`true`）与白名单外（应被 `ExecPolicy` 拒绝）的用例；确认 `shell=false`、argv 透传。
- 全门禁：`moon test --target native` 绿；`moon fmt` 仅格式化本批变更文件；clippy/Ω-gate 同 `design-spec.md` 纪律。

---

## 8. 下一步建议（待你拍板）

1. 在 mcp-watcher 根 `moon.mod.json` 加依赖：`moon add vicTop-cw/RX-MBT` + `moon add moonbitlang/async`（开发期可先用 path 依赖指向本地 `E:/IDEProjects/AI/rx-mbt`）。
2. 先落地 `cron` 包（纯逻辑、可单测），把测试门禁立起来——这是风险最低、收益最高的起点。
3. 再落地 `@process` 版 `command` action（替换 design-spec 里规划的 FFI spawn 草案）。
4. 最后接 `scheduler` + `TriggerRegistry` 把 fs / cron 两条事件源合并。
