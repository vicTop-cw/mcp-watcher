# 计划治理流程（mcp-watcher）

本目录（`fist-mbt/plans/`）是 mcp-watcher 的**计划治理中枢**，沿用兄弟项目 rx-mbt 的 FIST 方法论：
所有计划从提案到归档走一条固定链路，保证"谁决定、何时决定、决定什么"可追溯。

## 流程：提案 → 定案 → 执行 → 归档

1. **提案（Proposal）**：在 `plans/` 新建 `NNNN-<slug>-proposal.md`，用 `_template-proposal.md` 起稿，YAML 头 `status: draft`。
2. **定案（Decision）**：`human_steward` 审阅后，补全 YAML 头 4 字段（`decided_by`/`decided_at`/`decision`），状态置 `decided`，落定到 `plans/decisions/`。
3. **执行（Execution）**：拆解子任务推进，执行汇报放 `fist-mbt/reports/`（`YYYY-MM-DD-<任务名>-report.md`）。
4. **归档（Archive）**：执行完毕、结论沉淀后移入 `plans/archived/`，状态 `archived`。

## 4 条硬规则

- **规则 1 · YAML 头 4 字段**：每份计划顶部须含 `status`/`decided_by`/`decided_at`/`decision`，缺一即未定案，不得进入执行。
- **规则 2 · plans/ 专放计划**：只放提案/定案/归档，不放执行汇报与源代码。
- **规则 3 · reports/ 只放执行汇报**：不放计划、不放源代码、不放临时笔记。
- **规则 4 · 定案权仅 human_steward**：只有 `human_steward` 可置 `decided`/`archived`；agent/leader 只可提案与执行。

## 占位模板

- 提案模板：本目录 `_template-proposal.md`（与 rx-mbt 同款）
- 执行汇报模板：后续在 `reports/_template-report.md` 建立
- 规范文档模板：`docs/_template-standard.md`
