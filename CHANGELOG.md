# CHANGELOG

版本约定：`moon.mod` / `util/version.mbt`（`APP_VERSION`）/ 本文件三处同步。

## v0.2.4 — 2026-11-27（bug 修复发布 · T0r167 源码审计）

### Fixed

- **gate（假绿根治，三层根因）**：`scripts/test_all.sh` 逐包判绿的包级构建
  失败从未被捕获，js / wasm 轨在多数包退出非零、0 例真跑的情况下仍报 "PASS"。
  实测确认三层根因并逐层修复：
  ① **rc 捕获失效（真凶）**：原代码 `local rc` 位于 moon 命令**之后**，
  `rc=$?` 读到的是 `local` 自身的退出状态（恒 0）——包级 `rc≠0` 从未进入判定；
  现将 `local rc` 移至命令前。
  ② **判定口径**：包级失败（`rc≠0` 或 `failed≠0`）计入判定并判 FAIL；预期
  跳过以**包自身 moon.pkg 声明** `supported_targets="native"`（sqlite / index /
  cmd/main）或无测试源（own=0）为权威——不按 moon 的 "do not support target
  backend" 输出文本判（实测该文本与构建缓存状态相关：部分状态下
  `moon test -p` 对整个模块做目标校验、连带跨目标包报"目标不支持"，按文本判
  会把 action / cron 等 js 构建失败误当预期跳过）。
  ③ **计数口径**：修正 grep 漏计 `async test "..."` 形态的测试声明（原口径只
  匹配行首 `test "`）。
  回归证据：修复前逐包实测 `moon test --target js -p {action,cron,rule,
  scheduler}` 均 rc=1（crypto 构建错）而门禁判 PASS；修复后 js / wasm 轨如实判
  FAIL（包级失败: 4，根因见 Known），native 全量门保持全绿。
- **gate（--skip 对 test 步无效）**：`run_tests` 此前未接入 `is_skipped`，
  `--skip=js` / `--skip=wasm` 静默无效（实测：带 skip 参数 test-js 仍完整
  执行 ~43s）——"native 全量门"口径无法按文档口径单独执行。现 test 步支持
  `--skip=js` / `--skip=test-js` 双口径跳过。
- **index（FTS5 畸形表达式 / 静默假阴性）**：`fts_query` 两处缺陷——
  ① token 清洗用 `String::replace`（仅替换首个匹配），token 内含多个引号时
  残留引号 → 非配平 FTS5 表达式（"unterminated string"，整条检索静默 0 命中）；
  ② 清洗后为空的 keyword（纯引号 / 纯空白）走 fallback 把**原始** keyword
  重新包裹，奇数引号同样产出畸形表达式。修复：清洗改 `replace_all` 全量；
  fallback 直接返回合法空短语（FTS5 匹配零行，原始 keyword 的字面匹配由
  `build_sql` 的 `LIKE '%kw%'` 兜底承担）。新增 `index/fts_query_test.mbt`
  5 例纯函数回归（含 1/2/3/5 引号、空白+引号、注入形态）。
- **cli（validate 退出码）**：`validate` 子命令此前丢弃 `cmd_validate`
  返回值，进程恒 rc=0，与文档口径「0=通过 / 1=失败」不符。现已接通
  `@env.exit`（与 `search` 分支同模式）。回归：非法配置 rc=1、合法配置 rc=0。
- **cli（search 位置参数）**：文档口径 `mcp-watch search <watch_dir>`
  的位置参数被 `parse_args` 静默丢弃，恒报「缺少 watch_dir 位置参数」。
  现 search 命令下首个非旗标 token 作为 watch_dir（不吞未知旗标，
  `--watch-dir` 旗标口径向后兼容）。新增 `cmd/main/cli_args_test.mbt`
  5 例回归（位置参数、旗标混排、旗标兼容、未知旗标不吞、他命令不受影响）。

### Toolchain

- moon 0.1.20261104 适配：`String::replace` 签名改为具名参数
  （`old~` / `new~`），仓内调用点同步迁移（本工具链下旧位置参数形态
  不可编译，属发布前置条件）。

### Absorbed（工作区在制改动随本次发布落库）

本 release 提交吸收工作区既有的在制实现（门禁全量验证通过，属同一
绿色状态；如需拆分独立提交可由 owner 指示后 reset 重切）：

- P3 产物生命周期：TTL 追踪表（JSONL 持久化）、分桶可恢复回收站、
  生命周期事件总线（`product.created/expired/destroyed/invalid/logged`）。
- P3 产物加密：AES-256-GCM（`MBPWCRYPT1` 自描述格式，native 真做实）。
- index 包转正与 sqlite 链接修正（vendor 化 sqlite3，link flags 逐包声明）。
- 门禁 / e2e harness 增强（逐包计数口径、双进程 harness、native PATH 修正）。
- 文档对齐（README / USAGE / workbuddy/plan 计划文档）。

### Known

- **js / wasm 门禁如实 FAIL（既有外部阻塞）**：`action/crypto.mbt` 依赖的
  `@rhop.RhopCipherAesGcmNative` 在 RX-MBT@0.4.6 中仅 native 目标门控，
  导致 js / wasm 轨涉及 action 依赖链的包构建失败。本地 RX-MBT 0.4.7 已
  放开门控但未发布。验收口径为 **native 全量门**（check + native 测试 +
  e2e basic/deny），与 T0r163 口径一致。
- `stop` 子命令待实现（pidfile 以时间戳占位 pid，无法定位存活进程）——
  已列台账，属 P1 设计项。
