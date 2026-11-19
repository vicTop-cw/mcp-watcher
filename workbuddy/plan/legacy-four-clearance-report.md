# 遗留 4 项清零报告（deny 场景 / trash 做实 / 加密降级 / atomgit 补推）

> 日期：2026-11-17
> 范围：任务 #17~#20（上一轮报告 §6 列的 4 项未决）
> 口径：结论来自本机实测；状态声明 = 代码真实；门禁逐项核对。

---

## 1. 结论

4 项遗留全部处理完毕，其中 **3 项做实、1 项确认硬限制并诚实降级**：

| 项 | 结果 | 关键证据 |
|----|------|----------|
| #17 deny-command 场景 | ✅ 做实并纳入门禁 | e2e-deny PASS；期间修复"拒绝不落记录"缺陷 |
| #18 trash 物理回收 | ✅ native 做实（js/wasm 降级） | native 探针真实移文件；`trash_native_test` PASS |
| #19 产物加密 | ✅ 确认 native 不可做实 → 诚实 Err 降级 | rx Fernet `extern "js"` 源码铁证 |
| #20 atomgit 0.4.4 补推 | ✅ 推送成功 | `b77e282..2b90d39 main -> main` |

全门禁：**RESULT: PASS**（check 0 errors / 三目标各 94 测试 0 failed / e2e basic + deny 双场景 PASS）。

---

## 2. #17 deny-command 场景（含真实缺陷修复）

**新增资产**：
- `tests/harness/scenarios/deny-rules.json`：`allowed_programs: []`（安全默认），一条 `*.deny` 规则含 `cmd /c echo` command；
- `tests/harness/scenarios/deny.json`：期望 `exit=-1`、`stdout=""`、`stderr` 含"策略拒绝"；
- `scripts/test_all.sh`：`run_e2e` 支持场景参数，新增 `e2e-deny` 门禁步。

**过程中发现并修复的产品缺陷**：
- 现象：首跑 deny 场景卡在"等待服务器退出"，2 分钟不结束。
- 根因：`run_action` 把 `outcome.ok=false`（含 ExecPolicy 拒绝）转成 `Err`，
  而 scheduler 只在 `Ok` 分支写 `ExecRecord`；`cmd/main` 的 stop-after 又只随
  records 增量计数 → 拒绝事件不落记录，stop-after 永不触发。
- 修复：`scheduler/scheduler.mbt` 的 `Err` 分支也写一条 ExecRecord
  （`exit=-1, stdout="", stderr=原因`）。**拒绝事件首次可观测**，安全语义闭环：
  loader 警告 → 运行时拒绝 → 结果落盘 → e2e 对拍。

---

## 3. #18 trash 物理回收做实（native）

**可行性转折**：p3-feasibility 曾判"native 无 mkdir/rename，须扩 C FFI"——
只对 `@mon`/`@rhop` 成立。实测发现 rx 0.4.4 传递依赖 `moonbitlang/async@0.22.9`
在 native 提供 `fs.mkdir`/`fs.rename`（`src/fs/dir.c` C stub），探针验证真实移动文件成功，
**零新增 C FFI**。

**实现**（moon.pkg `targets` 分文件门控）：
| 文件 | 目标 | 行为 |
|------|------|------|
| `action/trash_native.mbt` | native | `async fn trash_file`：`<watch_dir>/.trash/<basename>.<epoch_ns>`，`mkdir(recursive,allow_exist)` + `rename(replace)`，失败返回可诊断 Err |
| `action/trash_stub.mbt` | js / wasm | 明确返回"当前目标不支持"Err（js 无 `@fs.mkdir` 符号；wasm 为 unimplemented） |
| `action/trash_native_test.mbt` | native | 真做实验证：源文件消失、`.trash` 目录出现 |
| `action/p3_ttl_test.mbt` / `action.internal_test.mbt` | 三目标 | trash 测试改 async，只验证不 panic（精确语义归 native 专属文件） |

**依赖变更**：`moon.mod` 新增 `moonbitlang/async@0.22.9`；`action/moon.pkg` 新增
`@fs`（`moonbitlang/async/fs`）。注意 `@fs.mkdir` 在 js 目标无符号，故必须分文件门控，
不能同文件调用。

---

## 4. #19 加密：硬限制确认 + 诚实降级

**铁证**（rx `rhop/crypto.mbt` 源码）：
- `fernet_encrypt_b64`：`#cfg(target="js")` 走 `extern "js"`（node:crypto）；
- 非 js 分支直接返回 `Err("Fernet 仅 js 目标可用")`；
- `encrypt_secret` 失败返回空串 `""`（native 下静默失败），`decrypt_secret` 返回可诊断 Err。

**决策**：不为此扩 rx native crypto FFI（需引入 OpenSSL 级 C 依赖，风险与 trash 的
"用现成传递依赖"完全同级不同量级；用户此前已明确选方案 B 不扩 C FFI）。

**落地**：`action/action.mbt::encrypt_file` 从"静默 `Ok(())` no-op"改为
**明确返回 Err**（"当前目标不支持……已诚实降级；不写入空密文以免破坏产物"）。
消除了"把 no-op 包装成成功"的最后一个谎言。无调用点，改动安全。

---

## 5. #20 atomgit 补推

- 旧失败原因：`origin` URL 内嵌的 oauth2 token 已失效（服务端 `HTTP Basic: Access denied`）。
- 解决：环境存在 `ATOMGIT_TOKEN`（新 PAT），用一次性的 `git push https://oauth2:${ATOMGIT_TOKEN}@... main:main`，
  不写入 `.git/config`（避免明文凭证落盘）。
- 结果：`b77e282..2b90d39  main -> main` —— 0.4.4 成功同步到 atomgit 镜像。

---

## 6. 门禁证据表（最终）

| 步骤 | 结果 | 明细 |
|------|------|------|
| check | **PASS** | 0 errors（native/js/wasm 三目标） |
| test-native | **PASS** | 94 用例，failed 0 |
| test-js | **PASS** | 94 用例，failed 0 |
| test-wasm | **PASS** | 94 用例，failed 0 |
| e2e basic | **PASS** | 双进程 + 路径粘连回归 + 字段断言 |
| e2e-deny | **PASS** | ExecPolicy 拒绝可观测 + 字段断言 |
| **汇总** | **RESULT: PASS** | 退出码 0 |

测试数 96 → 94：两个 trash 测试由"三目标通用"改为"native 专属精确验证 +
三目标不 panic"，js/wasm 各少 1，属预期收敛（native-only 能力不再重复计数）。

---

## 7. 文档同步

| 文件 | 变更 |
|------|------|
| `README.md` | trash 升级为"native 已做实 / 其他目标降级"；加密改"明确降级（不写空密文）"；command 注拒绝可观测；3 处状态摘要同步 |
| `workbuddy/plan/p3-feasibility.md` | 顶部加状态更新标注（trash 结论被后续实测修正，历史正文不改写） |
| `tests/harness/README.md` | （上一轮已更新 deny-command 状态） |

---

## 8. 任务状态与遗留

TaskList **#1~#20 全部 completed**。仍存的硬约束（已诚实标注，非"未完成"）：

1. **加密 native 做实** — 需 rx 补 native crypto FFI（OpenSSL 级 C 依赖），本轮明确不做；
2. **trash 在 js/wasm** — 无 `@fs.mkdir` 符号 / unimplemented，明确降级（非缺陷）；
3. **atomgit 旧 URL token** — 远程配置里仍是失效 token，本轮用环境 PAT 推送但未改配置；
   后续可考虑更新 `git remote set-url origin https://oauth2:${ATOMGIT_TOKEN}@...`（注意凭证安全）。
