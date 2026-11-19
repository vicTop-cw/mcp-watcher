# P3 产物生命周期 · 可行性定位与决策建议

> 日期：2026-11-17
> 触发：提升方向清单第 ② 项「P3 生命周期定位」
> 口径：结论均来自对 rx 0.4.4 依赖源码与本项目代码的实测核查，不采信历史注释。
>
> **状态更新（2026-11-17 晚，实测修正）**：本文 §2/§3 对 trash 的结论
> "native 不可做实、须扩 C FFI" **仅对 `@mon`/`@rhop` 成立**，已过时。
> 后续发现 rx 0.4.4 的传递依赖 `moonbitlang/async@0.22.9` 在 native 提供
> `fs.mkdir`/`fs.rename`（有 C stub），实测可做实——已在 `action/trash_native.mbt`
> 落地物理回收（移入 `<watch_dir>/.trash/`），js/wasm 由 `trash_stub.mbt` 门控降级。
> 加密结论不变（Fernet `extern "js"`，native 做不实），已改为明确返回 Err 不伪装成功。
> 下方 §2/§3 正文保留为当时的定位快照，不改写。

---

## 1. 结论先行

P3 的三个能力（TTL 清理 / trash 回收 / 加密）**在 native 目标下均无法直接做实**，
根因是 rx 依赖缺少必要 API。但可采用**替代路径**部分实现。给出三档方案供决策，
推荐 **方案 B（诚实降级 + TTL 内存态做实）**，不建议现在为 P3 扩 rx 的 C FFI。

---

## 2. API 可行性核查（实测）

| 能力 | 需要的原语 | rx 0.4.4 实际提供 | 可行性 |
|------|-----------|-------------------|--------|
| TTL 到期判断 | 计时 + 记录 | `@rx.real_now()` ✅ + 本项目 `ProductTracker` ✅ | **可做实**（内存态） |
| trash 移入回收目录 | `mkdir_p` + `move/rename` | `@mon`: read/write/list/stat/remove（**无 mkdir/rename**）<br>`@rhop.rhop_fs_mkdir_p`/`rhop_fs_move`: **js-only**，非 js 返回 Err<br>`@rhop/rhop_fs_native.mbt`: 仅 read/write/list/stat/exists/remove | **native 不可做实** |
| 加密 | 加密算法原语 | `@rt` rhop 有 `RhopCrypto`/`RhopEnvelope` 思路，但需核查是否导出可用；本项目未引用 | **待核查，倾向于可做实** |
| 持久化追踪 | 文件读写 | `@mon.fs_write_atomic` ✅（覆盖写） | 可做实 |

### 关键事实（纠正历史注释）

`action.mbt` 原注释称"@mon 包不提供 fs_mkdir_all / fs_rename"——**准确**。
但曾以为 `rhop` 包可补足——**不成立**：`rhop_fs_mkdir_p`/`rhop_fs_move` 在
`mirror.mbt` 里是 `#cfg(target="js")`，非 js 分支直接返回
`Err("文件系统操作仅 js 目标可用")`。native 的 `rhop_fs_native.mbt` 也没有这两个操作。

---

## 3. 三档方案与权衡

| 方案 | 内容 | 优点 | 代价 / 风险 |
|------|------|------|-------------|
| **A. 全做实** | 扩 rx native C stub 增加 `mkdir_p`/`rename`，发布 0.4.5，mcp-watcher 升级后实现 trash | 能力完整，四支柱都实 | 跨仓库改动 + 再次发布 registry；C 层引入新 bug 风险（刚修过路径粘连）；周期长 |
| **B. 诚实降级 + TTL 做实**（推荐） | ① README/设计稿把 trash/加密标为"规划中"；② `ProductTracker` 的 TTL 到期判断改为真实的持久化追踪 + 到期标记（写 JSONL/日志），移入回收目录仍 no-op 但明确日志告警 | 消除"声明≠真实"；零依赖风险；TTL 核心语义落地 | trash/加密仍是缺口，但诚实标注 |
| **C. 维持现状** | 什么都不改 | 零成本 |  continua 宣称四大支柱却三个 no-op，违反"状态=代码真实"硬标准，不可接受 |

**推荐 B**：以最小风险消除最大的真实性缺口，把 P3 从"空壳支柱"变成
"TTL 已落地 + trash/加密明确规划中"。若后续确需 trash，再走方案 A 的 rx 扩展。

---

## 4. 若选方案 B 的具体动作（待授权）

1. `action.mbt`：`cleanup_expired` 到期时写一条结构化生命周期记录到日志/JSONL
   （事件名 `product.expired`），不再静默 no-op；持久化追踪用 `fs_write_atomic`。
2. `README.md` / `design-spec.md`：把"产物生命周期语义（TTL/trash/加密）"改为
   "TTL 已落地；trash/加密规划中（依赖 rx native fs API）"。
3. 补 `cleanup_expired` 的单元测试（到期/未到期/边界）。
4. 重跑全门禁 + e2e。

---

## 5. 不做什么

- 不擅自扩 rx 的 C FFI（刚发布 0.4.4，避免连续引入风险）。
- 不用 `@process.run("cmd /c move")` 绕过——引入 shell 依赖，与 argv 白名单安全模型冲突。
- 不在本轮改任何 P3 代码，等用户选方案。
