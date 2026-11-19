# rx-mbt 基座独立验证报告

> **状态说明（2026-11-17）**：本文是 **2026-11-15 的历史验证快照**，正文中的
> `0.4.2`、`moon.work 接入`、`待提交/待发布` 等表述均为当时事实，**现已过时**。
> 当前：rx 已发布 registry **0.4.4**（含 native watch 路径粘连修复，commit `2b90d39`），
> mcp-watcher 已切 registry 依赖。见 `p0-completion-report.md` §10。
> 保留正文原文以存证，不做改写。

> 验证对象：`E:\IDEProjects\AI\rx-mbt`（模块名 `vicTop-cw/RX-MBT`）
> 验证目的：确认兄弟项目基座任务（R1~R4）真实完成、无回归，可作为 mcp-watcher 的核心依赖
> 验证方式：**独立复现 + HEAD 基线对照**，不采信既有审计文档的结论
> 验证日期：2026-11-15
> 结论：**基座功能完整，但存在 3 处缺陷，已修复并复验全绿。**

---

## 0. 一句话结论

| 项目 | 结论 |
|------|------|
| R1 真实时钟 | ✅ 已实现可用（`rx/ops_time_real.mbt`） |
| R2 原生文件监控 | ✅ 已实现可用（`monitor/watcher_native.mbt`，Windows `ReadDirectoryChangesW`） |
| R3 命令执行 Observable | ✅ 已实现可用（`rhop_task/task_exec.mbt`，C FFI `moonbit_cmd_run`） |
| R4 EventBus / 条件组合子 | ✅ 已实现可用（`rx/trigger.mbt`、`rx/ops_conditions.mbt`） |
| 四步门禁 | ✅ 修复后 **PASS / PASS / PASS / PASS** |
| 跨包可消费性 | ⚠️ **存在阻塞性缺陷，已修复并用探针验证通过** |
| 发布状态 | ❌ **全部基座工作未提交、未发布**（阻断项，需用户决策） |

---

## 1. 门禁证据（修复后实测）

命令：`cd E:/IDEProjects/AI/rx-mbt && bash scripts/test_all.sh`

| 步骤 | 判定 | 明细 | 耗时 |
|------|------|------|------|
| check | **PASS** | 0 errors | 3767 ms |
| wasm | **PASS** | Total tests: 662, passed: 662, failed: 0 | 4035 ms |
| js | **PASS** | Total tests: 912, passed: 912, failed: 0 | 36315 ms |
| native | **PASS** | Total tests: 673, passed: 673, failed: 0 | 4737 ms |

**RESULT: PASS —— 所有已执行步骤判绿（4 步）**

### 1.1 归因方法：用 HEAD 基线做对照

首次跑门禁的结果是 **check FAIL / wasm FAIL / js FAIL / native PASS**，与既有审计文档
`ISSUES-mcp-watcher-gap-audit.md`（2026-11-15 09:48 记录 native 646/645/1 红）**不一致**。

为判定这是「基座遗留问题」还是「基座引入的回归」，我用 `git worktree` 拉出 HEAD
（`785144d release: rx-mbt v0.4.1`）到独立目录跑同一门禁：

| 步骤 | HEAD 基线 | 工作区（修复前） | 判定 |
|------|-----------|------------------|------|
| check | PASS 0 errors | FAIL（7 errors） | **回归** |
| wasm | PASS 615/615 | FAIL（编译错误） | **回归** |
| js | PASS 860/860 | FAIL（编译错误） | **回归** |
| native | — | PASS 645/645 | — |

结论明确：**基座改造引入了 3 处回归**，不是历史遗留。

---

## 2. 发现并修复的 3 处缺陷

### 缺陷 1（编译级·7 errors）· wasm 目标缺 fs 原语

**现象**：`moon check --target wasm` 报 7 处 `The value identifier fs_read_text is unbound`
（分布：`rhop/relay.mbt:123,169`、`rhop/transport_local.mbt:66,71,153,173`、`rhop/watch.mbt:184`）。

**根因**：基座把 rhop 的文件系统原语抽到了 `rhop/rhop_fs_native.mbt`，并在
`rhop/moon.pkg` 里用 `targets` 门控为 **native 独占**：

```
"rhop_fs_native.mbt": [ "native" ],
```

而 `transport_local.mbt` 里原有的 js 分支被**删除**（原本有 `#cfg(not(target="js"))`
的 wasm 占位实现）。结果 wasm 目标下 `fs_read_text` / `fs_remove` / `fs_exists`
三者皆无定义。

**修复**：`rhop/moon.pkg` 把该文件放开到 wasm（该文件本身已内置
`#cfg(not(target="native"))` 的桩实现，无需额外代码）：

```
"rhop_fs_native.mbt": [ "native", "wasm" ],
```

**验证**：`moon check --target wasm` 从 7 errors → **0 errors**。

---

### 缺陷 2（编译级·1 error）· extern "C" 误纳 wasm

**现象**：`moon check --target wasm` 报 `extern "C" is unsupported in wasm backend`
（`rhop_task/task_exec.mbt:386`）。

**根因**：R3 的 C FFI 声明用了过宽的门控：

```moonbit
#cfg(not(target="js"))          // ← 这会把 wasm 一并纳入
extern "c" fn moonbit_cmd_run(...) -> Bytes = "moonbit_cmd_run"
```

MoonBit 的 wasm 后端不支持 extern "C"，因此该门控在 wasm 下必然编译失败。

**修复**：把 C FFI 精确门控到 native，并为 wasm 单独补一个可诊断的 Err 桩：

```moonbit
#cfg(target="native")
extern "c" fn moonbit_cmd_run(...) -> Bytes = "moonbit_cmd_run"

#cfg(target="native")
fn run_cli(...) -> Result[(Int32, String, String), String] { /* C FFI 实现 */ }

#cfg(target="wasm")
fn run_cli(...) -> Result[(Int32, String, String), String] {
  Err("rhop_task: CLI 执行在 wasm 目标不可用（无子进程能力；native/js 可用）")
}
```

> 注：`run_command` 本身不含 extern C，保留 `#cfg(not(target="js"))` 即可三目标通用。

**验证**：wasm 0 errors，且 native/js 行为不变。

---

### 缺陷 3（可用性级·阻断）· 泛型类型跨包不可见

**现象**：从 mcp-watcher 引用 rx 的泛型类型时报错：

```
Error: [4021] Value EventBus not found in package `rx`.
```

**根因（两层）**：

1. **rx 侧可见性**：`rx/trigger.mbt` 里 `EventBus` / `TriggerEvent` / `TriggerRegistry` /
   `Trigger` 声明为 `pub struct` —— 在 MoonBit 里 `pub` **仅包内可见**，
   跨包需 `pub(all)`。同族缺陷还存在于 `monitor` 包的 `WatchEvent` / `FsError` /
   `FileStat`。因为 rx 的测试全在包内（`rx/event_bus_test.mbt` 等），
   这个缺陷**从未被 rx 自己的门禁发现**。

2. **MoonBit 语法约束**：泛型类型跨包引用**必须带完整类型标注**，
   直接写 `@rx.EventBus[Int]::new()` 会被解析为「值 `EventBus`」而非类型构造器。
   正确写法：

   ```moonbit
   let bus : @rx.EventBus[Int] = @rx.EventBus::new()   // ✅
   let bus = @rx.EventBus[Int]::new()                    // ❌ Value EventBus not found
   ```

   非泛型类型无此限制（`@rx.CurrentThreadScheduler::new()` 可直接用）。

**修复**：

| 文件 | 变更 |
|------|------|
| `rx/trigger.mbt` | `TriggerEvent` / `Trigger` / `TriggerRegistry` / `EventBus` → `pub(all) struct` |
| `monitor/watch_event.mbt` | `WatchEvent` → `pub(all) struct` |
| `monitor/fs_native.mbt` | `FsError` → `pub(all) enum`，`FileStat` → `pub(all) struct` |

> `rhop_task` 的 `ExecPolicy` / `ExecResult` / `CommandResult` / `ExecError`
> 原本已是 `pub(all)`，无需改动。`rhop` 包其余类型属历史遗留、且不在
> mcp-watcher 消费范围，按范围纪律**未改动**。

**验证**：新增探针测试（`mcp-watcher/util/probe_test.mbt` +
`mcp-watcher/tests/probe/r2_r3_probe_test.mbt`）覆盖 R1~R4 真实调用，
**673/673 全绿**。

---

## 3. 接入方式验证：moon.work（不依赖发布）

### 3.1 为什么必须用本地机制

| 方案 | 可行性 | 说明 |
|------|--------|------|
| `moon add vicTop-cw/RX-MBT` | ❌ 不可行 | registry 上最新只有 **0.4.1**（2026-11-12 发布），**不含 R1~R4**。且基座全部未提交、未发布 |
| `moon.mod` 内联 `path` | ❌ 语法不支持 | 新版 `moon.mod` 已废弃内联 path 依赖写法（`moon.mod` 解析报 `unexpected token :`） |
| **`moon.work` 成员机制** | ✅ **可用** | 官方推荐方式。workspace 内按模块名解析，`@version` 部分被忽略 |

### 3.2 实际配置

`E:\IDEProjects\AI\moon.work`（两仓库的共同父目录）：

```toml
members = [
  "mcp-watcher",
  "rx-mbt",
]
```

`mcp-watcher/moon.mod`：

```toml
name = "mcp-watcher"
version = "0.1.0"

import {
  "vicTop-cw/RX-MBT@0.4.2",
}
```

解析结果确认（`moon tree`）：

```
mcp-watcher@0.1.0 (local E:\IDEProjects\AI\mcp-watcher) [workspace member]:
└─ vicTop-cw/RX-MBT -> vicTop-cw/RX-MBT@0.4.2 (local E:\IDEProjects\AI\rx-mbt) [workspace member]
   └─ moonbitlang/async -> moonbitlang/async@0.22.9
```

---

## 4. R1~R4 消费形态实测（探针证据）

### 4.1 R1 · 真实时钟

```moonbit
@rx.install_real_clock()
let now = @rx.real_now()   // epoch 毫秒
@rx.uninstall_real_clock()
```

**语义要点**：`real_now()` 在**未调用 `install_real_clock()` 时**返回默认虚拟时钟值
（占位语义，保证既有确定性测试不受影响）。这是设计而非缺陷，调用方必须先注入。

### 4.2 R2 · 原生文件监控

```moonbit
let obs = @mon.watch_folder(dir)   // Observable[WatchEvent, WatchError]
```

**关键约束（架构硬约束）**：native 后端的订阅闭包是**同步阻塞**的
（`ReadDirectoryChangesW` 事件 + 轮询循环都在 `subscribe_fn` 内），
**一旦 subscribe 就会占住当前线程**直到 Subscription 被 dispose。

因此：
- mcp-watcher 运行时**必须在后台 async 任务中 subscribe**，否则事件循环被监控源独占；
- 单元测试**不可直接 subscribe**（会挂死）——真实事件验证必须走双进程集成测试。

### 4.3 R3 · 命令执行

```moonbit
let policy = @rt.ExecPolicy::default()          // 默认只放行 action:/handler:
let obs = @rt.run_command(policy, payload)      // Observable[CommandResult, ExecError]
```

白名单语义确认：默认拒绝 `cli:echo`，策略拒绝时走 `on_error`（可诊断错误），非静默成功。

### 4.4 R4 · EventBus

```moonbit
let bus : @rx.EventBus[Int] = @rx.EventBus::new()
let _ = bus.subscribe("demo.*", fn(ev : @rx.TriggerEvent[Int]) { ... })
bus.publish("demo.hit", 5)
```

### 4.5 rx 订阅 API 形状

| 用途 | API |
|------|-----|
| 完整控制 | `Observable::subscribe(Observer)` — 需显式构造 `Observer::new(next, error, complete)` |
| 单回调便捷 | `Observable::subscribe_on_next(fn)` / `subscribe_on_error(fn)` / `subscribe_on_completed(fn)` |
| 取消订阅 | `Subscription::dispose()`（**不是** `unsubscribe()`） |

---

## 5. 阻断项：基座全部未提交、未发布

```
$ git log --oneline -1
785144d release: rx-mbt v0.4.1 (adapt moon 0.1.20261104)

$ git status --porcelain | wc -l
100        # 47 个已修改文件 + 大量未跟踪文件
```

| 类别 | 内容 |
|------|------|
| 已修改（未提交） | `rx/trigger.mbt`、`rx/ops_conditions.mbt`、`rx/ops_time_real.mbt`、`monitor/watcher_native.mbt`、`rhop_task/task_exec.mbt`、`rhop/*`、`moon.mod`（版本已 bump 到 **0.4.2**）等 47 个文件 |
| 未跟踪（未入库） | `monitor/watch_native_stubs.c`、`monitor/fs_native*.mbt`、`rhop/rhop_fs_native*`、`rx/event_bus_test.mbt`、`rx/ops_time_real_test.mbt`、`tests/harness/`、`docs/`、`PLAN-mcp-watcher-apis.md` 等 |
| 卫生问题 | 仓库根目录散落数十个 `*.txt` 运行日志；`monitor/fs_native_wbtest.mbt.bak` 备份文件 |
| 陈旧文档 | `ISSUES-mcp-watcher-gap-audit.md`（称 R2/R3 未实现、native 红）与 `TEST_REPORT.md` 已与代码不符 |

**影响**：mcp-watcher 若通过 registry 引入 rx，拿到的是 **0.4.1**（无 R1~R4）；
只有走 §3 的 `moon.work` 本地机制才能用上基座。**若要发布给评审/参赛，必须先把
基座提交 + push + `moon publish`（版本 0.4.2）。**

---

## 6. 本次对 rx 的改动清单（4 处，均已复验）

| # | 文件 | 改动 | 性质 |
|---|------|------|------|
| 1 | `rhop/moon.pkg` | `rhop_fs_native.mbt` 门控 `[native]` → `[native, wasm]` | 修复回归 |
| 2 | `rhop_task/task_exec.mbt` | extern "C" 门控 `#cfg(not(target="js"))` → `#cfg(target="native")`；新增 `#cfg(target="wasm")` 的 `run_cli` Err 桩 | 修复回归 |
| 3 | `rx/trigger.mbt` | 4 个触发器类型 → `pub(all) struct` | 修复可用性缺陷 |
| 4 | `monitor/watch_event.mbt`、`monitor/fs_native.mbt` | `WatchEvent` / `FsError` / `FileStat` → `pub(all)` | 修复可用性缺陷 |

> 改动范围纪律：仅触及基座 R1~R4 直接相关的文件，未做整仓格式化，
> `rhop` 包的历史遗留类型可见性问题（`RhopConfig` / `Executor` 等）**记录但未改动**。

---

## 7. 复验命令（可重放）

```bash
# rx-mbt 四步门禁
cd E:/IDEProjects/AI/rx-mbt && bash scripts/test_all.sh

# mcp-watcher 三目标编译 + 测试
cd E:/IDEProjects/AI/mcp-watcher
moon check --target wasm   && moon check --target native && moon check --target js
moon test  --target native   # 673/673
```

---

## 8. 遗留事项（需用户决策，非本报告可决）

1. **基座提交与发布** —— 是否由 AI 执行 `git add/commit/push` + `moon publish`（0.4.2）？
   发布后 mcp-watcher 可改用 registry 依赖，免去 `moon.work` 耦合。
2. **仓库卫生** —— 根目录 `*.txt` 日志清理、`*.bak` 删除、`docs/` `tests/` 是否入库。
3. **陈旧文档刷新** —— `ISSUES-mcp-watcher-gap-audit.md` / `TEST_REPORT.md` 与实际代码不符，需重写或标注作废。
4. **rhop 历史类型可见性** —— 是否统一提升为 `pub(all)`（当前 mcp-watcher 不消费，暂未动）。
5. **`moon.work` 放置位置** —— 现放在两仓库共同父目录 `E:\IDEProjects\AI\`，
   该目录另有 14 个项目，成员表只列了 2 个，暂无冲突；但若父目录被清理则接入失效。
