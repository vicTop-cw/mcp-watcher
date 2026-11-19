# mcp-watcher · 复用 rx 的计划与测试规划（本期仅设计）

> 配套：`design-spec.md`（总体决议）、`config-schema.md`（配置契约）、`rx-mbt-dependency.md`（依赖决策）、`../rx-mbt/PLAN-mcp-watcher-apis.md`（rx 增资计划）。
> **本期范围声明（用户决议）**：mcp-watcher 本项目**只做设计与规划，不进入实现**。rx-mbt 侧按计划增资；本文件把"mcp-watcher 如何复用 rx 新增 API"与"双进程集成测试规划"落到纸面，作为后续实现的蓝图。
> 格式：Markdown。

---

## 1. 复用蓝图（基于 rx 增资计划）

rx 按计划新增 R1~R4 后，mcp-watcher 的组件几乎全部架在响应式原语上：

| mcp-watcher 组件 | 复用 rx（计划后） | 备注 |
|------------------|------------------|------|
| 文件监听后端 | `monitor.watch_folder_native`（R2，`Observable[WatchEvent]`） | 替换 design-spec §1 里"自建 @ffi 后端"——改为复用 rx 的 native 后端（同是 @ffi，集中维护） |
| 规则派发内核 | `EventBus` / `TriggerRegistry`（R4） | 事件名约定 `<事件类型>.<glob>`，如 `create.*.md` |
| 时间 / 去抖 | `real_interval` / `debounce_real`（R1） | cron 调度、连续 modify 合并 |
| `command` action | `run_command` + `ExecPolicy`（R3） | 白名单 + argv 不走 shell |
| Layer2 条件 AND | `all_of` 条件组合子（R4） | condition 字段求值 |
| action 管线扇出 | `Observable` 链式 `map/flat_map/filter` | 一事件多动作 |

**mcp-watcher 仍需自建（非响应式原语）**：
- `config`：`@json` derive 解析 + 累积式语义校验（design-spec §3）。
- `cli`：start / stop / status / run / validate（design-spec §9）。
- 规则 DSL 语义、`variables` 占位展开、dry-run、遥测、`extensions:` 占位（EP-07）。
- 扩展位注册表（EP-01~EP-12 的"注册"机制）与热重载编排（`Arc<RwLock<RuleTable>>`）。
- **cron 表达式解析**（`cron.next_after`，纯逻辑）——领域相关，留在 mcp-watcher，rx 只提供 `real_interval` 驱动原语。

---

## 2. 目标架构（设计稿，复用视角）

```
  ┌─────────────── 事件源 ───────────────┐
  │  rx.watch_folder_native (R2)          │   fs 事件 Observable[WatchEvent]
  │  rx.real_interval 驱动 cron 调度 (R1)  │   cron 事件（合成 name="cron.<id>"）
  └───────────────┬──────────────────────┘
                  │  WatchEvent / 合成事件
                  ▼
        ┌──────────────────────────┐
        │  rx.EventBus (R4)         │  事件名 glob 匹配 + condition(all_of) + 优先级
        │  publish(name, payload)   │
        └──────────────┬───────────┘
                       │ 命中规则 → handler
                       ▼
        ┌──────────────────────────┐
        │  action 管线 (Observable)  │  map/flat_map/filter
        │  command / mcp / webhook   │
        └──────────────┬───────────┘
                       │
          ┌────────────┴────────────┐
          ▼                         ▼
   rx.run_command (R3)         mcp_tool_call / webhook
   (ExecPolicy 白名单)          (mcp-watcher 自建 client)
```

**关键洞察**：fs 事件与 cron 事件在 `EventBus` 汇合，共享 condition / action / 扩展位（EP-01~EP-12）。只差"事件源"一个分支。

---

## 3. 测试规划 · 双进程集成测试（核心约束）

### 3.1 为什么必须是"一个服务器开着，另一个程序去触发"

mcp-watcher 是**事件驱动 daemon**，其真值只能由"外部进程制造真实的文件系统事件"来验证：
- 单进程内造事件只能证明内存逻辑，证明不了内核/FFI 通路（inotify/FSEvents/ReadDirectoryChangesW）。
- 只有"server 进程在监听 ↔ trigger 进程在写文件"这一对真实进程，才能端到端验证：**内核事件 → rx Observable → EventBus 派发 → action 执行** 全链路。
- 这也是对 rx R2 native 后端的唯一可信验收方式（见 rx 计划 §3 阶段 4）。

### 3.2 双进程契约（物料落地于 `tests/harness/`）

| 角色 | 是什么 | 职责 |
|------|--------|------|
| **Server** | mcp-watcher daemon 的 test-mode（设计级，本期不实现） | 启动后监听某 tmp 目录；把"触发到的规则 + 实际 action 结果"以 **JSONL** 写入结果文件；收到停止信号后退出 |
| **Trigger** | 独立程序（`tests/harness/trigger.py`，**已实现、可运行**） | 按场景脚本对 tmp 目录执行 create/modify/delete/rename，驱动 server |
| **Verify** | `tests/harness/verify.py` | 读 server 结果 JSONL，与场景期望对拍，输出 PASS/FAIL |
| **Scenario** | `tests/harness/scenarios/*.json` | 声明"trigger 做什么 + 期望 server 触发哪些规则/动作" |

**运行时序**：
```
1. 启动 server（test-mode，监听 $TMP/watch，结果写 $TMP/results.jsonl）
2. 等待 server 就绪（就绪哨兵文件 / 端口 / 轮询）
3. 运行 trigger.py --dir $TMP/watch --scenario basic.json
4. 等待动作收敛（或 server 输出"done"）
5. 运行 verify.py --results $TMP/results.jsonl --scenario basic.json
6. 停止 server，清理 tmp
```

**Server test-mode 协议（P0 已实现并验收）**：详见 `tests/harness/server_contract.md` 与 `tests/harness/run.sh` —— 启动参数、就绪哨兵、结果 JSONL 字段（`rule_id` / `event` / `path` / `action_type` / `exit` / `stdout` / `stderr` / `ts`）、停止方式。结果字段由 scheduler 的 `ExecRecord` 结构化写入；双进程 basic / p0-smoke 场景均 PASS。

### 3.3 覆盖范围（场景清单）

| 场景 | 验证点 |
|------|--------|
| basic（create→期望 command 删除） | fs 事件到达、glob 匹配、command 白名单放行 |
| exclude-priority | `exclude` 优先于 `patterns`、多规则优先级 |
| debounce | 连续 modify 合并为一次 action |
| cron | `real_interval` 驱动 `cron.next_after` 触发 |
| deny-command | `ExecPolicy` 拒绝未授权程序 |
| rename / delete | 事件类型覆盖 |

---

## 4. 本期交付物清单（设计 + 物料）

| 文件 | 性质 |
|------|------|
| `../rx-mbt/PLAN-mcp-watcher-apis.md` | rx 增资计划（已注入 rx 项目） |
| `workbuddy/plan/reuse-and-test-plan.md` | 本文：复用蓝图 + 测试规划 |
| `tests/harness/README.md` | 双进程测试契约与运行说明 |
| `tests/harness/server_contract.md` | server test-mode 协议（设计级） |
| `tests/harness/trigger.py` | **具体可运行**的触发程序（Python3，跨平台） |
| `tests/harness/verify.py` | 结果对拍脚本 |
| `tests/harness/scenarios/basic.json` | 示例场景 |

> 注：`trigger.py` 与 `verify.py` 不依赖 mcp-watcher 是否已实现——trigger 只做文件变更，verify 只做"结果 vs 期望"对拍，二者现在即可使用；server 待 mcp-watcher 进入实现期后补齐。

## 5. 门禁纪律（沿用）

- 状态声明 = 代码真实；本期为设计阶段，所有"可用/通过"表述须标注为"设计/规划"，不得声称已实现。
- 后续实现期：rx 增资每阶段单测进 `TEST_REPORT`；mcp-watcher `moon test --target native` 绿；`moon fmt` 仅格式化本批变更文件。
