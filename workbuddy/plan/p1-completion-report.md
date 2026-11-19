# P1 规则内核完成报告

> 日期：2026-11-17
> 范围：development-plan §P1（去抖链 / 条件组合 / once / 优先级）
> 口径：结论来自本机实测，门禁数字逐项核对。
>
> 状态更新（2026-11-17 晚）：`allowed_programs` 语义已按后续决策改为
> **配置显式白名单**（不再从 argv[0] 自动收集）；详见 `config-schema.md`
> 与本目录安全口径。下方 §2.3 与 §6 第 3 条为当时的历史快照，正文不改写。

---

## 1. 结论

P1 三项核心能力全部落地并测试锁定：
1. **条件组合**：接入 rx `all_of`/`any_of`/`not_`，支持原子 + 嵌套组合；
2. **去抖链**：在 watch 订阅链接入 `debounce_real`（订阅链上做，非内核手写计时器）；
3. **once / 优先级**：scheduler 已有实现，本次补黑盒测试锁定语义。

新增测试 19 个（条件组合 9 + scheduler 5 + 重复计数？见门禁表），三目标全绿。

---

## 2. 交付明细

### 2.1 条件组合（`rule/condition.mbt` 新增）

`compile_condition(cond : ConditionSpec?) -> (TriggerEvent[FsEvent]) -> Bool`
把声明式条件编译为 rx EventBus 可直接消费的谓词：

| kind | 语义 | expr 格式 |
|------|------|-----------|
| `size_gt` / `name_contains` | 原子（原有） | 阈值 / 子串 |
| `all` | AND，调 `@rx.all_of` | 子条件 JSON 数组字符串 |
| `any` | OR，调 `@rx.any_of` | 子条件 JSON 数组字符串 |
| `not` | 取反，调 `@rx.not_` | 单个子条件 JSON 对象字符串 |

- 空 `all` 恒真、空 `any` 恒假——**继承 rx 实现**，语义单一真值。
- `matcher.mbt` 的 Layer2 改为统一调用 `condition_matches`，消除原 `condition_eval` 的双套语义。
- `rule/moon.pkg` 新增 `@rx` + json 依赖。

### 2.2 去抖链（`watch/backend.mbt`）

`spawn_watch_task` / `subscribe_watch` 新增 `debounce_ms~` 标注参数：
```moonbit
let obs = if debounce_ms > 0L { source.debounce_real(debounce_ms) } else { source }
```
- 去抖在**订阅链**上做，符合 development-plan §2 修正 #2（不在规则内核手写计时器）。
- 三个调用点（run_daemon / cmd_run_once / run_scheduler）显式传 `cfg.debounce_ms`。
- 需用 `@rx.install_real_clock()` 已注入真实时钟（daemon 启动时已做）。

### 2.3 once / 优先级（`scheduler/scheduler_test.mbt` 新增）

锁定既有实现的 5 个测试：
- `event_names_of` 具体事件映射 / `all` 展开五类；
- **once**：同一事件 publish 两次只执行一次；
- **非 once**：同一事件 publish 两次执行两次；
- `allowed_programs` 从 argv[0] 收集程序名（去重）。

> 测试断言用**日志条数**而非执行记录数：wasm 目标无子进程能力，command 会写 err 日志、
> native 写 ok 日志，两者都证明 handler 是否执行，三目标语义一致（避免 wasm FAIL）。

---

## 3. 门禁证据表

| 步骤 | 结果 |
|------|------|
| `moon check` | 0 errors |
| native | 87 用例，failed 0 |
| js | 87 用例，failed 0 |
| wasm | 87 用例，failed 0 |
| e2e（双进程 basic） | PASS |
| `bash scripts/test_all.sh` | RESULT: PASS |

测试数 73 → 87（+14 = 条件组合 9 + scheduler 5），三目标一致。

---

## 4. 与设计稿的偏差说明

- `design-spec.md` §5 写「去重与合并（rule/debounce.mbt）」，实际去抖落在
  `watch/backend.mbt` 订阅链（用 rx `debounce_real`）。这是 development-plan §2 已确认的修正，
  实现正确，设计稿该段为早期设想，未改写历史文档。
- 条件组合的 `all/any/not` 通过 `expr` 承载 JSON 子条件字符串，
  未引入新的 JSON schema 字段——向后兼容既有 `condition:{kind,expr}` 结构。

---

## 5. 本批次变更文件

| 文件 | 变更 |
|------|------|
| `rule/condition.mbt` | 新增：条件编译（rx all_of/any_of/not_） |
| `rule/condition_test.mbt` | 新增：9 个条件组合测试（含嵌套） |
| `rule/matcher.mbt` | Layer2 统一走 `condition_matches` |
| `rule/moon.pkg` | 新增 @rx / json 依赖 |
| `watch/backend.mbt` | 订阅链接入 `debounce_real`，新增 debounce_ms~ 参数 |
| `scheduler/scheduler.mbt` | 调用点传 debounce_ms |
| `scheduler/scheduler_test.mbt` | 新增：once/优先级/事件名 5 个测试 |
| `cmd/main/main.mbt` | 两处调用点传 debounce_ms |
| `scripts/test_all.sh` | 新增 e2e 门禁步（上一批次） |
| `tests/harness/verify.py` | 加强字段断言（上一批次） |

---

## 6. 待办 / 不在本轮范围

1. debounce 的端到端场景（连续 modify 合并）——需要在 harness 加 debounce 场景，
   依赖真实时钟驱动，留待后续。
2. cron 源接入（P2）、产物生命周期（P3，见 `p3-feasibility.md`）。
3. 推荐动作（④）：`allowed_programs` 从 argv[0] 自动收集的安全语义需产品决策。
