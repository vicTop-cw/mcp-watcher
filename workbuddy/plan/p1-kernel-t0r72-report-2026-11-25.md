# T0r72 · mcp-watcher P1「规则内核与派发」落地报告

- 任务：T0r72（namespace=autoplan，project_dir="."）
- 执行身份：codearts
- 日期：2026-11-25
- 目标仓真身：`E:/IDEProjects/AI/mcp-watcher`（version 0.2.3，HEAD b1773aa，依赖 RX-MBT@0.4.6）
- 需求真源：`workbuddy/plan/development-plan.md` §P1（L117–128）

---

## 一、结论

§P1 的五项内核能力**主体已在目标仓落地**，本轮以最小改动补齐唯一实质缺口，并按验收口径新增总线级测试锁定。

| 项 | 落地位置 | 本轮动作 |
|---|---|---|
| EventBus[FsEvent] 封装 | rx 自带 `@rx.EventBus[T]`；`EventBus[T]{ registry : TriggerRegistry[T] }` | 无（既有） |
| Layer1 匹配接 `rule/matcher.mbt` | `scheduler/scheduler.mbt` 的 `fire()` 经 `matcher.matches_event` 走类型/glob/exclude | 无（既有） |
| Layer2 条件编译 `@rx.all_of/any_of/not_` | `rule/condition.mbt` → `rule.matcher` 组合谓词 | 无（既有） |
| debounce_real 去抖链 | `watch/backend.mbt::subscribe_watch_multi(..., debounce_ms~)`：`if debounce_ms > 0L { source.debounce_real(debounce_ms) } else { source }` | 无（既有） |
| **priority/stop_after 落 TriggerRegistry** | `bus.subscribe(...)` 原先**未传** `priority`；once 靠 `executed_rules` 手记账 | **补 `priority=rule.priority`**（本轮唯一代码改动） |

关键修正：`TriggerRegistry` **不是需要新建的类型**——它是 rx 自带类型且已被 `EventBus` 内含；缺的是**把 `Rule.priority` 下传给 `subscribe`**。原实现只在 `attach_rules` 内预排序 + `executed_rules` 手工记账，priority 语义没有真正落到 TriggerRegistry。

---

## 二、证据（当轮实测读数）

命令均在 `E:/IDEProjects/AI/mcp-watcher` 下直接执行；判绿只认汇总行。

| 面 | 命令 | 读数 |
|---|---|---|
| scheduler（改后） | `moon test --target native scheduler` | **`Total tests: 48, passed: 48, failed: 0.`** rc=0 |
| scheduler（基线，改动前） | 同上 | `Total tests: 42, passed: 42, failed: 0.` |
| rule（回归） | `moon test --target native rule` | `Total tests: 19, passed: 19, failed: 0.` |
| watch（回归） | `moon test --target native watch` | `Total tests: 0, passed: 0, failed: 0.` |
| 格式门（可落盘比对） | 副本 `moon fmt` 后与工作树逐字 diff | 两文件 **diff 0 行** |

新增 6 例（`scheduler/scheduler_test.mbt`）：

1. `P1 命中：patterns + 事件类型通过 → 规则执行`
2. `P1 不命中：patterns 不符 → 规则不执行`
3. `P1 排除：exclude 命中 → 即使 patterns 命中也不执行`
4. `P1 条件失败：Layer1 命中但 Layer2 谓词为假 → 不执行`（含反向对照：同规则条件满足必执行，防恒假绿）
5. `P1 once：stop_after 规则同一事件 publish 两次只执行一次`
6. `P1 优先级：Rule.priority 落到 TriggerRegistry，高优先先执行`

验收口径覆盖：用户口径「命中 / 不命中 / 排除 / 条件失败 / once」五路 = 计划 §P1 的四类路径 + once，等价对应。第 6 例是 priority 缺口的**归因锁**（注册序故意低优先在前，只有 priority 真下传才会 high→low）。

夹具口径：动作统一用 `internal log_event`（message 只取受支持占位符 `{file.path}`），断言一律读 `ExecRecord.rule_id` 与 records 条数——不依赖子进程（command 在 js/wasm 下不可靠），三目标语义一致。

> 踩坑留档：`{rule_id}` **不是**受支持占位符（清单见 `action/action.mbt::render_placeholders`），初版夹具用它会产出空 stdout 造成假红，已改为读 `ExecRecord.rule_id`。

---

## 三、改动清单（精确到 hunk）

### 1. `scheduler/scheduler.mbt`（+7 行 / −3 行）

```diff
@@ -194,3 +198,7 @@ pub fn attach_rules(
-      let _ = bus.subscribe(ev_name, fn(ev : @rx.TriggerEvent[@watch.FsEvent]) {
-        fire(ev.payload)
-      })
+      // P1：priority 落到 TriggerRegistry（rx 派发时按 priority 降序、同优先保持
+      // 注册序）；规则表自身的预排序只决定注册序 tie-break，不再是唯一依据。
+      let _ = bus.subscribe(
+        ev_name,
+        fn(ev : @rx.TriggerEvent[@watch.FsEvent]) { fire(ev.payload) },
+        priority=rule.priority,
+      )
```

同文件另有 4 个 hunk 属**他人未提交的 P3 WIP**（`tracked~`/`lifecycle_bus~`/`lifecycle_events~` 参数贯通），非本任务产物，未触碰。

### 2. `scheduler/scheduler_test.mbt`（单 hunk 追加，L204 起 +202 行）

即上述 6 例 + `mk_ev` / `mk_log_rule` / `mk_kernel_bus` 三个辅助。

### 未做（刻意）

- **未跑整仓 `moon fmt`**：本机 `moon fmt <路径>` 会把整份文件重排（实测使 scheduler.mbt 从 4 个 hunk 膨胀到 27 个），违反最小改动。改为在副本上验证格式，确认我的代码块本身已符合 `moon fmt`（diff 0 行）。本机 `moon fmt --check` 回 rc=127（`git diff --no-index` 失败，BUG-388 同族工具链缺陷），故以副本比对为等价面。
- **未 `git commit`**：本任务交付面是 FIST 接力棒，且工作树含他人 P3 WIP，局部提交会扫入非本任务内容。

---

## 四、缺口与风险

1. **js / wasm 目标当前无法作为验收通道（阻塞归属：他人未跟踪 WIP）**
   `moon test --target js scheduler` → rc=1，`Error: [4032]` / `[4024]`，错误点集中在未跟踪文件 `action/crypto.mbt:39/40/74`（引用仅 native 门控的 `@rhop.RhopCipherAesGcmNative`，`rhop/moon.pkg` 把 `cipher_gcm.mbt` 门控为 `["native"]`），另涉 `action.mbt` / `trash_stub.mbt` / `webhook.mbt`。
   `git ls-files action/crypto.mbt` = 0（未跟踪）。
   **本轮不修**：属 P3 领域、且是他人未提交工作，改动会越过本任务边界。验收以 native 门禁为准。
2. **once 语义仍为「订阅保留 + `executed_rules` 拦截」，未改用 rx 原生 `once~`**
   原因：scheduler 侧 once 含 guard 退场/热重载语义，交给 rx 自动 unregister 会改变重挂载行为（回归面），故只补 priority，不动 once 实现路径。若要求严格对齐 §P1 字面「once 落 TriggerRegistry」，需先确认热重载口径。
3. **`watch` 包 0 例**：debounce_real 链只有集成层覆盖，无该包的独立用例（既有状态，未新增）。

---

## 五、建议入档位置

- 本报告：`E:/IDEProjects/AI/mcp-watcher/workbuddy/plan/p1-kernel-t0r72-report-2026-11-25.md`
- 缺陷线索（js 目标 crypto.mbt 门控）建议登记到 `workbuddy/plan/known-issues-2026-11-23.md`（本轮未改该文件）
- 进度口径：`workbuddy/plan/development-plan.md` 头部「当前实际进度」仍写 P1 未开工，与 `p1-completion-report.md` 并存，属既有自述滞后，建议由后续收口统一。

---

## 六、来源

- `workbuddy/plan/development-plan.md` §P1（L117–128）
- `workbuddy/plan/p1-completion-report.md`（2026-11-17 历史落地记录）
- `workbuddy/plan/known-issues-2026-11-23.md`
- rx 权威源码（解压缓存 RX-MBT@0.4.6）：`rx/trigger.mbt`、`rx/trigger_test.mbt`、`rhop/moon.pkg`
- 当轮实测日志：`temp/t0r72-native-final2.log`、`temp/t0r72-native-rule-final.log`、`temp/t0r72-js-after.log`
