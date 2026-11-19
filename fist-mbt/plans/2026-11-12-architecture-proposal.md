---
status: draft
decided_by: ""
decided_at: ""
decision: ""
---

# 2026-11-12-architecture 计划提案（mcp-watcher 架构脚手架）

> 方法论：FIST-Mbt 计划治理（提案 → 定案 → 执行 → 归档）。本文件为**提案（draft）**，由 `human_steward` 审阅定案后方可进入执行。
> 关联：`rx-mbt/PLAN-mcp-watcher-apis.md`（rx 增资计划）、`workbuddy/plan/design-spec.md`。

## 背景

mcp-watcher 的产品定位已定稿为 **AI 工作区自治运行时**（四大支柱：后台沉默自治 / 声明式规则 / 热重载 / 产物生命周期语义），不再是通用文件触发器。
此前已完成设计文档（design-spec / config-schema / 依赖决策 / 复用测试规划）与 rx-mbt 增资计划，但**仓库尚无任何 MoonBit 代码骨架**——`moon.mod`、包结构、核心类型均未建立。
现状：`moon --version` 可用（0.1.20261104，已启用 `rr_moon_mod`/`rr_moon_pkg`，即 `moon.mod` + `moon.pkg` 新格式）；rx-mbt 已验证同一格式可用。

## 目标

1. 建立 mcp-watcher 的 MoonBit 工程骨架：`moon.mod` + 包结构（`config`/`watch`/`rule`/`action`/`ext`/`cron`/`scheduler`/`cmd/main`）。
2. 落地与四大支柱对应的核心类型与模块边界：
   - 声明式规则模型（`config`：Rule / EventType / ActionSpec / ConditionSpec）。
   - 两层匹配算法（`rule`：事件+glob、exclude 优先、条件 AND）——**纯逻辑、可单测**。
   - 生命周期动作扩展点（`action`：trait `Action`，command/mcp/webhook 待接入）。
   - 扩展位注册表（`ext`：EP-01~EP-12 注册表骨架）。
   - cron 表达式解析与下次触发（`cron`：纯逻辑、可单测，mcp-watcher 自留领域逻辑）。
   - watch 后端扩展点（`watch`：trait `WatchSource`，native 后端待接入 rx `monitor.watch_folder_native`）。
3. 提供可运行入口 `cmd/main`：打印产品定位横幅与子命令用法（start/stop/status/run/validate）。
4. `moon check`（native 目标）零错误，确立"搭架构"完成判据。

## 方案

- 工程格式：根 `moon.mod`（`name = "mcp-watcher"`，`version = "0.1.0"`）；各包 `moon.pkg`（TOML，`import` 列依赖，`cmd/main` 标 `pkgtype(kind: "executable")`）。
- 包依赖有向无环：`config`（底层，纯数据+JSON 解析）→ `watch`/`rule`/`action` 依赖 `config`；`rule` 依赖 `util`；`scheduler` 依赖全部；`cmd/main` 依赖 `config`。
- 关键纯逻辑先做对、做可测（不依赖 rx/async，保证 `moon check` 当下即绿）：
  - `util/glob.mbt`：`glob_match`（支持 `*` 段内、`**` 跨段），复用 rx `event_matches` 思路但面向路径。
  - `rule/matcher.mbt`：`Rule::matches_event`（Layer1 事件类型+glob；`exclude` 优先于 `patterns`；Layer2 条件 AND 预留）。
  - `cron/cron.mbt`：`CronExpr::parse` + `next_after`（标准 5 段；自实现 `days_from_civil` 做日期进位，不引外部库）。
- 外部依赖（rx-mbt / moonbitlang/async）**本期不接入**：watch/action/scheduler 以 `Err("待接入 rx ...")` 占位 + trait + `// TODO(fist-execute)` 标注，保证编译通过；实现期 `moon add` 后替换占位。
- 配置解析沿用 rx-mbt 的手动提取范式（`@json.parse` + `jget/jstr/jint/...` + 累积式 `validate`），不使用 `@json` derive，规避派生风险。
- CLI 入口先打印定位横幅与子命令清单（native 读文件依赖 `@fs`/async，本期不接实参读取，仅横幅）。

## 影响面

- 新增：`moon.mod`、`fist-mbt/plans/`（提案+治理 README）、`config/` `watch/` `rule/` `action/` `ext/` `cron/` `scheduler/` `cmd/main/` 各包的 `moon.pkg` 与 `.mbt` 骨架。
- 不变：既有 `workbuddy/plan/*` 设计文档、`tests/harness/*` 测试物料、`rx-mbt/PLAN-*`。
- 与 rx 增资计划的接缝：watch/action/scheduler 占位处的 `TODO(fist-execute)` 即 rx R2/R3/R4 的接入点。

## 验收标准

1. `moon check`（native）零错误、零警告（门禁纪律：状态=真实）。
2. `rule` 与 `cron` 两个纯逻辑包具备冒烟单测（`_test.mbt`）：glob 匹配、exclude 优先、cron `next_after` 边界（跨月/步进/周日对齐）。
3. `moon build --target native` 产出可执行文件，`mcp-watch`（无参）打印产品定位横幅与子命令清单、退出码 0。
4. 一份执行汇报 `fist-mbt/reports/2026-11-12-architecture-execute.md` 记录命令证据与门禁结果。

## 风险

- **风险 1｜rx 未接入导致"架构空洞"**：以 trait + 占位 + 明确 TODO 兜底，本期目标仅为骨架与可测纯逻辑，空洞是计划内。
- **风险 2｜MoonBit `@json` derive 行为不确定**：已决定**不用 derive**，改手动解析（与 rx-mbt 一致），消除该风险。
- **风险 3｜cron 日期进位错误**：用 Howard Hinnant `days_from_civil` 标准算法，并加跨月/闰年单测覆盖。
- **规避**：每个纯逻辑包配套单测，先绿后扩；rx 接入为独立执行阶段，不阻塞本期门禁。
