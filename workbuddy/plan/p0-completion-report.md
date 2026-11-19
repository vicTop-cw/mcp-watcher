# mcp-watcher P0 接入层完成报告

> 日期：2026-11-17
> 范围：P0（接入层）+ 双进程端到端验收闭环
> 事实口径：所有结论均来自本机实测，门禁数字逐项核对，不引用历史记忆。
> 前置文档：`workbuddy/plan/development-plan.md`（P0 定义与验收标准）

---

## 1. 结论摘要

P0 五项代码任务此前已全部落地；本轮完成的是**此前从未跑通的端到端验收闭环**。
经修复 6 处确定性缺陷后，`bash tests/harness/run.sh p0-smoke` 全绿：
真实 server 进程监听真实目录、独立 trigger 进程制造文件事件、
命中规则后 command 动作受白名单约束实际执行、结果以真实字段落盘 JSONL、
`--stop-after` 真正终止进程。**P0 验收标准达成。**

---

## 2. 门禁证据表

| 步骤 | 命令 | 判据 | 实测结果 | 判定 |
|------|------|------|----------|------|
| 静态检查 | `moon check` | 0 errors | 0 errors（23 warnings，非阻断） | PASS |
| native 测试 | `moon test --target native` | 全绿 | 73 用例，failed 0 | PASS |
| js 测试 | `moon test --target js` | 全绿 | 73 用例，failed 0 | PASS |
| wasm 测试 | `moon test --target wasm` | 全绿 | 73 用例，failed 0 | PASS |
| 全量门禁 | `bash scripts/test_all.sh` | RESULT: PASS | RESULT: PASS | PASS |
| 端到端 | `bash tests/harness/run.sh p0-smoke` | RESULT: PASS | 结果 1 条，全部期望命中 | PASS |

> 门禁在两处跑过：结构化记录改动后一次、本批次文件 `moon fmt` 后复跑一次，均 PASS。
> 格式化范围严格限定本批次变更的 `cmd/main/main.mbt`、`scheduler/scheduler.mbt`，
> 未做整仓格式化（本项目非 cargo 项目，遵循开发计划 §3 的范围纪律）。

---

## 3. P0 任务完成度

| 任务（development-plan §P0） | 状态 | 落点 / 证据 |
|------------------------------|------|-------------|
| `watch/backend.mbt` 去占位，接入 `@mon.watch_folder` | 已完成 | `RxBackend` + `#cfg` 三目标分流；native 用 `watch_folder_native(recursive~)` |
| `watch/event.mbt` 对齐 `WatchKind → EventType` | 已完成 | `from_rx_event`：Created→Create / Modified→Modify / Removed→Delete |
| `action/action.mbt` 接 command 走 `@rt.run_command` + `ExecPolicy` | 已完成 | `run_command_action`：payload JSON 走 argv 数组，`build_policy` 白名单 |
| 依赖声明固化 `moon.mod` | 已完成 | `vicTop-cw/RX-MBT@0.4.4` registry 依赖（P0 时 0.4.3，修复路径粘连后升级，见 §10） |
| CLI 骨架 start/status/validate/run --once | 已完成 | `cmd/main/main.mbt`，另含 run(test-mode)/reload/stop(预留) |
| **双进程端到端验收** | **本轮达成** | `tests/harness/run.sh p0-smoke` PASS |

---

## 4. 端到端验收实测证据

### 4.1 运行链路（run.sh p0-smoke 输出摘录）

```
=== 预检规则文件 ===   ✓ 规则校验通过（1 条 cleanup 规则）
=== 启动 server（test-mode，run 非 once） ===
=== 等待服务器就绪 ===   服务器已就绪（PID=559）
=== 运行触发器（独立进程） ===
[trigger] -> {'op': 'create', 'path': '...\.watch\scratch.tmp'}
=== 等待服务器优雅退出（stop-after） ===
[success] rule_action command event=create:...\scratch.tmp exit_code=0
  已达到 stop-after=1，退出
服务器已退出
=== 验证结果 ===
场景: p0-smoke   结果条数: 1
PASS  全部期望命中
RESULT: PASS
```

### 4.2 真实结果落盘（`.results.jsonl`）

```json
{"rule_id":"cleanup","event":"create","path":"E:/IDEProjects/AI/mcp-watcher/tests/harness/.watch\\scratch.tmp","action_type":"command","exit":0,"stdout":"cleanup\r\n","stderr":"","ts":1794880113788}
```

字段全部来自真实执行，非日志字符串猜测：
`rule_id`/`event`/`action_type`/`exit`/`stdout` 与 `cmd /c echo cleanup` 的实际结果一致。
进程无残留（ps 检查无 main.exe），就绪哨兵退出时已删除。

---

## 5. 本轮发现并修复的缺陷

| # | 缺陷 | 影响 | 修复 |
|---|------|------|------|
| 1 | `run.sh` 二进制路径写死 `./target/native/debug/mcp-watcher` | server 根本无法启动 | 改为从 moon.work 工作区推导真实产物路径 `_build/native/debug/build/cmd/main/main.exe` |
| 2 | `run.sh` 用位置参数调 `trigger.py`/`verify.py`，脚本要求命名参数 | argparse 报错退出 | 改用 `--dir/--scenario`、`--results/--scenario` |
| 3 | `run.sh` 传 `--once`，走 `cmd_run_once`（不写 JSONL、不建哨兵） | test-mode 链路失效 | 去掉 `--once`，走 `run → run_daemon` 完整 test-mode |
| 4 | `RULES_FILE` 指向场景文件 `basic.json`（无规则字段） | validate 直接失败 | 规则文件与场景文件分离，新增 `basic-rules.json`；默认 `p0-smoke` 用 `demo-rules.json` |
| 5 | `append_file` 用 `fs_write_atomic` 覆盖写 | JSONL 多条结果互相覆盖，只留最后一条 | 改为读-改-写真追加（`fs_read_text` + `fs_write_atomic`） |
| 6 | `--stop-after` 只打印+删哨兵，watch 订阅无限循环不退出 | `wait` 永久挂死 | native 用 C `exit` 进程级退出；wasm/js 用 stub 保三目标可编译 |
| 7 | 结果 `rule_id`/`action_type` 从共享 log 字符串猜测 | 与真实命中规则错位，字段失真 | scheduler 新增结构化 `ExecRecord`，动作执行后写入真实字段；main 用增量游标消费落盘 |

---

## 6. 依赖侧缺陷（§10 已修复闭环）

**rx-mbt 0.4.3 native 监控路径粘连 bug**（已定位到源码行）：
`monitor/watch_native_stubs.c` 在 `watch_thread` 中用 `WideCharToMultiByte` 把
完整路径转成 UTF-8 后，**未显式写 `full[fname_len] = '\0'`**；
`buf_push()` 随后用 `strlen(full)` 计算长度，读到栈上残留字节。
表现：连续创建多文件时，后一文件路径会粘连前一文件的扩展名
（实测 `keep.md` 被报成 `keep.md.tmp`），导致规则误命中。

- 影响：多文件连续创建场景（basic）的结果对拍不可靠。
- 规避：P0 默认场景 `p0-smoke` 采用单文件串行创建，对齐 P0 验收原话
  （"一条真实 FsEvent + 一次受白名单约束的 command 执行"）。
- 归属：rx 依赖侧缺陷，原在 registry 0.4.3。**已于同日修复并发布 0.4.4，
  mcp-watcher 已升级依赖，basic 场景恢复为默认且验证通过。详见 §10。**

---

## 7. 本批次变更文件

| 文件 | 变更 |
|------|------|
| `cmd/main/main.mbt` | `exit_process`(native/wasm/js 分流)、`append_file` 真追加、`run_daemon` 增量游标落盘、`result_json_from_record` 替换猜测式 `result_json`、两处 `attach_rules` 接 records |
| `scheduler/scheduler.mbt` | 新增 `ExecRecord` 结构 + `new`、`attach_rules` 增 records 出参并写入真实执行记录、`run_scheduler` 配套 |
| `tests/harness/run.sh` | 产物路径、命名参数、去 `--once`、规则/场景分离、validate 预检、真实 `wait` |
| `tests/harness/scenarios/p0-smoke.json` | 新增：单事件 P0 验收场景 |
| `tests/harness/scenarios/basic-rules.json` | 新增：basic 双规则配置（供后续场景） |

> `demo-rules.json` 为既有文件，未改动，仅被 p0-smoke 复用。

---

## 8. Git 状态

项目目录 `E:/IDEProjects/AI/mcp-watcher` **不是 git 仓库**（无 `.git`），
无法提供 commit hash / working tree 状态。本轮不初始化 git（超出授权范围）。
变更以文件系统落盘为准，文件清单见 §7。

---

## 9. 下一步建议

1. P1：规则内核去抖链 + 条件组合 + once 语义接入（rx `debounce_real`）。
2. ~~rx 修复路径粘连 bug 并发布 0.4.4~~ → **已完成，见 §10**。
3. 将 `stop`/`reload` 从预留完善为可用子命令。

---

## 10. 后续更新：路径粘连 bug 修复闭环（同日）

用户授权"修复已知情况"后，对 §6 的依赖侧缺陷完成完整修复闭环。

### 10.1 修复内容（rx 0.4.4）

`monitor/watch_native_stubs.c` 纵深两层修复：
1. 第 142 行 `WideCharToMultiByte` 后显式写 `full[fname_len] = '\0'`，并做长度边界夹取；
2. `buf_push()` 签名增加 `uint32_t path_len` 显式参数，不再用 `strlen(full)`，
   调用点传 `(uint32_t)fname_len`。

### 10.2 修复有效性铁证

| 项 | 修复前 | 修复后 |
|----|--------|--------|
| 第二条事件路径 | `keep.md.tmp`（粘连） | `keep.md`（正确） |
| 命中规则 | cleanup（误命中 `*.tmp`） | md-modify（正确命中 `*.md`） |
| `bash run.sh basic` | FAIL | **PASS** |

修复后 basic 场景真实 JSONL：
```json
{"rule_id":"cleanup","event":"create","path":"...\\scratch.tmp","action_type":"command","exit":0,"stdout":"cleanup\r\n",...}
{"rule_id":"md-modify","event":"modify","path":"...\\keep.md","action_type":"command","exit":0,"stdout":"md-modify\r\n",...}
```

### 10.3 门禁证据表（rx 0.4.4）

| 步骤 | 结果 |
|------|------|
| `moon check` | 0 errors |
| native | 645/645 passed |
| js | 888/888 passed |
| wasm | 638/638 passed |
| `bash scripts/test_all.sh` | RESULT: PASS（4 步全绿） |

### 10.4 发布与升级

| 动作 | 结果 |
|------|------|
| rx 版本 `0.4.3 → 0.4.4`，CHANGELOG 新增条目 | 完成 |
| git commit | `2b90d39 fix(monitor): 修复 native watch 路径粘连 bug，发布 0.4.4` |
| `moon publish` | 成功（Server status 200 OK） |
| `git push github main` | 成功（`1e63f0a..2b90d39`） |
| `git push origin main`（atomgit） | **失败：HTTP Basic 密码认证已禁用，需 personal access token**（凭证问题，非代码问题；待用户处理） |
| mcp-watcher `moon add --upgrade ...@0.4.4` | 成功，缓存已拉取修复版 C 文件 |
| `run.sh` 默认场景 `p0-smoke → basic`；stop-after 改按 `expect` 长度动态取值 | 完成 |

> 注：`origin`（atomgit）推送失败不影响 GitHub 主远程与 moon registry；
> 两个权威分发渠道均已更新成功。atomgit 镜像待用户更新凭证后补推。
