# P3 方案 B + ExecPolicy 显式 allowlist 完成报告

> 日期：2026-11-17
> 范围：任务 #15（P3 方案 B：TTL 做实 + 诚实降级）、任务 #16（ExecPolicy 显式 allowlist）
> 口径：结论来自本机实测，门禁数字逐项核对；状态声明 = 代码真实。

---

## 1. 结论

两项任务全部落地并通过跨目标全门禁：

1. **P3 方案 B**：TTL 语义做实（到期判定 / `product.expired` 生命周期事件 / 追踪表移除 / JSONL 持久化往返），trash 与加密在 README 中诚实降级为"规划中"；
2. **ExecPolicy 显式 allowlist**：白名单由配置 `allowed_programs` 显式声明，不再从规则 `argv[0]` 自动收集；空名单 = 默认拒绝任意命令（安全默认）。

门禁：check 0 errors / native·js·wasm 各 96 测试 0 failed / e2e PASS / `RESULT: PASS`。

---

## 2. 交付明细

### 2.1 P3 方案 B（任务 #15）

| 能力 | 落点 | 语义 |
|------|------|------|
| 到期判定 | `action/action.mbt::expired_records` | `now - created >= ttl*1e9`；`ttl<=0` 不过期；边界 `age==ttl` 视为到期 |
| 清理 + 事件 | `action/action.mbt::cleanup_expired` | 打印结构化 `product.expired` 事件，移除追踪记录；**不删/不移文件** |
| 持久化 | `action/action.mbt::save/load` | JSONL 格式，重启后不丢 TTL 状态；损坏行跳过不崩溃 |
| 诚实降级 | `README.md` | TTL ✅；trash 🚧（需 rx native `mkdir_p`/`rename`）；加密 🚧 |

测试：`action/p3_ttl_test.mbt`（6 例：未到期/已到期/边界/ttl≤0/cleanup 计数/trash 降级）、
`action/p3_persist_native_test.mbt`（2 例：save-load 往返、文件不存在返回空表）、
`action/action.internal_test.mbt`（沿用既有 5 例）。

### 2.2 ExecPolicy 显式 allowlist（任务 #16）

| 环节 | 文件 | 变更 |
|------|------|------|
| 配置模型 | `config/model.mbt` | `Config.allowed_programs : Array[String]`（默认 `[]`） |
| loader 解析 | `config/loader.mbt` | 解析新字段；加载时对"规则含 command 但程序不在白名单"给警告 |
| 白名单来源 | `scheduler/scheduler.mbt::allowed_programs` | 返回 `config.allowed_programs`，不再从 argv 自动收集 |
| 策略构造 | `action/action.mbt::build_policy` | 程序名 → `cli:<prog>` 条目；空名单 ⇒ 无命令可执行 |
| 调用点 | `cmd/main/main.mbt`（2 处） | `build_policy(@scheduler.allowed_programs(cfg))` |
| 测试 | `scheduler/scheduler_test.mbt` | 新增 2 例：显式名单不含 argv 程序、空名单安全默认 |
| 规则文件 | `basic-rules.json` / `demo-rules.json` | 补 `allowed_programs: ["cmd"]` |
| 文档 | `README.md` / `config-schema.md` / `tests/harness/README.md` | 同步为显式白名单口径 |

---

## 3. 本轮修复的关键缺陷

**现象**：门禁 `test-js` / `test-wasm` 各 FAIL（failed: 3）；native 96 全过、e2e PASS。

**根因**：`action/p3_persist_native_test.mbt` 头部注释声称"已用 `moon.pkg options.targets` 门控 native 专属"，
但 `action/moon.pkg` 实际未配置 `targets`。该文件 save/load 测试调用 `@mon.fs_write_atomic / fs_read_text`
（native C FFI），在 js/wasm 下返回 Err，触发 `assert_true(false)`。因 `moon test -p <pkg>` 连带跑依赖链，
该失败在 action 及依赖它的包中重复计为 3 次。

**修复**：比照 `tests/probe/moon.pkg` 写法，在 `action/moon.pkg` 补：
```
targets: { "p3_persist_native_test.mbt": [ "native" ] }
```
js/wasm 下 action 测试由 15 → 13（2 个 native 专属测试被正确排除），failed 归零。

---

## 4. 门禁证据表（最终，2026-11-17 复跑）

| 步骤 | 命令 | 结果 | 说明 |
|------|------|------|------|
| check | `moon check --target native` | **PASS** | 0 errors（1923 ms） |
| test-native | `moon test --target native` | **PASS** | 本项目用例 96 个，failed 0（21823 ms） |
| test-js | `moon test --target js` | **PASS** | 96 用例，failed 0（21253 ms） |
| test-wasm | `moon test --target wasm` | **PASS** | 96 用例，failed 0（18837 ms） |
| e2e | `bash tests/harness/run.sh basic` | **PASS** | 双进程 basic 全绿（含字段断言，10321 ms） |
| **汇总** | `bash scripts/test_all.sh` | **RESULT: PASS** | 退出码 0 |

测试数演进：73（P0）→ 87（P1）→ 96（P3 + allowlist，+9）。

---

## 5. 文档同步（状态声明 = 代码真实）

| 文件 | 变更 |
|------|------|
| `workbuddy/plan/p1-completion-report.md` | 顶部加状态更新标注：`allowed_programs` 已改显式白名单，历史快照正文不改写 |
| `tests/harness/README.md` | deny-command 状态由"规划中（P1）"改为"能力已实现（显式 allowlist）；场景脚本待补" |
| `README.md` | TTL ✅ / trash 🚧 / 加密 🚧 诚实降级（本批次前已落，复核一致） |
| `workbuddy/plan/config-schema.md` | `allowed_programs` 显式白名单口径（复核一致） |

**范围纪律**：格式化仅涉及本批次变更的 `.mbt` 文件，未整仓格式化；
清理了根目录 3 个 0 字节误创建空文件（"口径：…" / "日期：…" / "触发：…"）。

---

## 6. 任务状态

- 任务 #15（P3 方案 B）：completed
- 任务 #16（ExecPolicy 显式 allowlist）：completed

**已知未决（不在本轮范围）**：
1. trash 物理回收需 rx native 提供 `mkdir_p` / `rename` FFI（js-only 不可用于 native）；
2. 加密待评估复用 rx rhop 加密原语；
3. deny-command harness 场景脚本待补（能力已实现，缺场景固化）；
4. atomgit 镜像 0.4.4 补推仍需 PAT 凭证（环境问题，非代码）。
