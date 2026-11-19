# 2026-11-12-architecture 执行汇报（mcp-watcher 架构脚手架）

> 对应计划：`fist-mbt/plans/2026-11-12-architecture-proposal.md`（状态：draft，待 human_steward 定案）
> 门禁纪律：状态声明 = 代码真实；仅格式化本批次变更文件；证据链 = 命令输出 + 文件事实。

## 1. 结论

架构脚手架**已落地并通过全门禁**：`moon check --target native` 零错误零警告，`moon test --target native` **21/21 通过**，`moon build --target native` 产出可执行文件并正常运行（exit=0，打印产品定位横幅）。

## 2. 工程结构（已落地）

```
mcp-watcher/
├── moon.mod                     # name = "mcp-watcher", version = "0.1.0"
├── README.md                    # 产品定位（AI 工作区自治运行时 · 四大支柱）
├── config/                      # 声明式规则 DSL 模型 + JSON 解析 + 累积式校验
│   ├── model.mbt                # EventType / ConditionSpec / ActionSpec / Rule / Config
│   └── loader.mbt               # 手动提取解析 + validate（累积式）
├── watch/                       # 文件系统事件源（EP-01 扩展点）
│   ├── event.mbt                # FsEvent / WatchError
│   └── backend.mbt              # trait WatchSource + 占位后端（待接 rx）
├── rule/                        # 两层匹配（事件+glob → exclude 优先 → 条件 AND）
│   └── matcher.mbt
├── action/                      # 生命周期动作（EP-01 扩展点）
│   └── action.mbt               # trait Action + run_action（占位）
├── ext/                         # 扩展位注册表（EP-01~EP-12）
│   └── registry.mbt
├── cron/                        # cron 表达式解析与 next_after（纯逻辑）
│   ├── cron.mbt
│   └── cron_test.mbt
├── util/                        # glob 匹配 + 整数解析
│   ├── glob.mbt
│   └── glob_test.mbt
├── scheduler/                   # 事件源 + cron 合并主循环（占位）
│   └── scheduler.mbt
├── cmd/main/                    # CLI 入口（pkgtype: executable）
│   └── main.mbt
├── tests/harness/               # 双进程集成测试物料（trigger / verify / 场景 / server 协议）
└── fist-mbt/plans/              # 计划治理中枢
```

包依赖方向（有向无环）：`util` ← `config` ← `watch` ← `action` ← `scheduler`；`rule` 依赖 `config`/`util`/`watch`。

## 3. 门禁证据

| 门禁 | 命令 | 结果 |
|------|------|------|
| 类型检查 | `moon check --target native` | Finished，**0 error / 0 warning** |
| 单元测试 | `moon test --target native` | **Total tests: 21, passed: 21, failed: 0** |
| 构建 | `moon build --target native` | 产出 `cmd/main/main.exe` |
| 产物运行 | `./main.exe` | exit=0，打印四大支柱横幅与子命令清单 |
| 格式化 | `moon fmt util config watch rule action ext cron scheduler cmd` | 仅格式化本批次文件（限定路径，未整仓盲刷） |

### 测试覆盖（21 项）

| 包 | 用例数 | 覆盖点 |
|----|--------|--------|
| `util` | 7 | 扩展名模式、单段不跨目录、`**` 跨段、精确模式、basename、整数解析 |
| `rule` | 6 | 事件类型+glob 命中、类型不符、all 通配、**exclude 优先**、Layer2 size_gt、派发 |
| `cron` | 8 | 步进/通配/区间/星期/逗号解析、非法输入、步进触发、**跨月进位**、每日、**星期对齐**、星期计算 |

## 4. 本轮踩坑与结论（务必沉淀，避免重复踩）

| # | 现象 | 根因 | 结论 / 规则 |
|---|------|------|-------------|
| 1 | `Cannot find import 'moonbitlang/core/map'` | `Map` 不在 `core/map`，而在 **core 内置**（`core/hashmap` 导入反而报 unused） | 用 `Map([], capacity=0)` + 索引赋值；不额外导入 |
| 2 | `Using let statement in the action part of a matching case is not allowed` | match 分支不能直接写 `let`/`for` | 分支体一律用 `{ ... }` 包裹 |
| 3 | `The mutability of 'x' is never used` 被当 **Error** | MoonBit 的 `Array::push` / Map 索引赋值是**原地**操作 | 仅真正被重新赋值的变量才写 `mut` |
| 4 | `Value ConditionSpec not found in package 'config'` | **跨包不支持结构体字面量** `@pkg.Type{..}` | 跨包一律走构造函数 `@pkg.Type::new(..)`（已为 ConditionSpec/ActionSpec/Rule/FsEvent 提供） |
| 5 | `Cannot create values of the read-only type: Create` | 枚举构造器默认包内可见 | 需跨包构造的枚举写 `pub(all) enum`；结构体字段需 `pub(all) struct` |
| 6 | `implicit_impl_as_method` 警告 | derive 出的方法被隐式提升为普通方法 | 需显式 `pub extend X with Eq::{not_equal, equal}` 与 `Debug::{to_repr}` |
| 7 | `split` 返回 `Iter[StringView]` | 与预期 `Array[String]` 不同 | 一律 `.to_owned()` 转换后使用 |
| 8 | `?` 传播语法不可用 | 当前 moon 版本未支持 | 改显式 `match ... { Ok(v) => v Err(e) => return Err(e) }` |
| 9 | `guard` 是**保留字** | 用作变量名直接解析失败 | 改名为 `iter_count` |
| 10 | **cron 时间全部落到 1970 年** | **MoonBit 的 `Int` 是 32 位**，`secs * 1000` 毫秒时间戳溢出（实测 `cron_to_ms` = -845729728） | 毫秒/时间戳一律用 **`Int64`**（`86400L` / `to_int64()`） |
| 11 | `glob_match("keep.tmp","keep.tmpx")` 误判为真 | 段内只有前缀匹配，未要求完整相等 | 无 `*` 的模式必须**完全相等** |
| 12 | 模式 `*.tmp` 命中不了子目录文件 | 单段模式按整路径匹配 | 无 `/` 的模式按 **basename** 匹配，含 `/` 才按整路径（已在 rule 层 `pattern_match` 落实） |

## 5. 本期未做（计划内）

- **rx-mbt 依赖未接入**：`watch`/`action`/`scheduler` 以 `Err("待接入 rx ...")` 占位 + trait 接缝；接入路径见 `rx-mbt/PLAN-mcp-watcher-apis.md`（R1~R4）。
- **CLI 真实子命令未实现**：入口仅打印横幅与用法；`start/stop/status/run/validate` 待实现期补齐。
- **双进程集成测试未端到端跑通**：`tests/harness/trigger.py` + `verify.py` 已冒烟通过（PASS/FAIL 退出码正确），但 **server 端（mcp-watcher test-mode）尚未实现**，故端到端链路待实现期验证。
- **热重载 / TTL / trash / 加密动作语义**：仅在模型与扩展位层面留出，未实现。
- **git 仓库未初始化**：当前 `mcp-watcher/` 非 git 仓库（`git status` 报 not a repository），是否初始化待用户决定。

## 6. 下一步（待 human_steward 定案后执行）

1. `moon add vicTop-cw/RX-MBT` + `moon add moonbitlang/async`，把 `watch`/`action`/`scheduler` 的占位换成 rx 实现（R2/R3/R4）。
2. 按 `tests/harness/server_contract.md` 实现 server test-mode，跑通"server 监听 ↔ trigger 触发"双进程端到端。
3. 补 CLI 子命令与热重载（`Arc<RwLock<RuleTable>>`）。
4. 补齐生命周期动作语义（TTL / trash / 加密），对应支柱 4。
