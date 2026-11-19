# mcp-watcher 集成测试物料 · 双进程 Harness

> 核心约束：**测试必须是一个服务器（server）开着时，另外一个程序（trigger）去做触发**。
> 单进程内造事件只能证明内存逻辑，证明不了内核/FFI 通路（inotify / FSEvents / ReadDirectoryChangesW）。
> 只有"server 在监听 ↔ trigger 在写文件"这对真实进程，才能端到端验证
> **内核事件 → rx Observable → EventBus 派发 → action 执行** 全链路。

## 角色

| 角色 | 文件 | 状态 |
|------|------|------|
| **Server** | mcp-watcher daemon 的 test-mode | ✅ 已实现（`run` 非 `--once`，见 `server_contract.md`） |
| **Trigger** | `trigger.py` | ✅ 已实现、可运行（Python3 标准库，跨平台） |
| **Verify** | `verify.py` | ✅ 已实现、可运行 |
| **Scenario** | `scenarios/*.json` | ✅ `basic.json` / `p0-smoke.json`（规则文件独立：`*-rules.json`） |

## 依赖

- Python 3.8+（仅标准库：`pathlib` / `json` / `time` / `argparse`）。
- MoonBit 工具链（构建 server native 二进制）。
- `trigger.py` / `verify.py` 只依赖标准库，本身跨平台；server 的 native 文件监控当前仅 Windows（rx monitor `ReadDirectoryChangesW`）。

## 运行流程

一条命令跑完（推荐）：

```bash
bash tests/harness/run.sh basic       # 多事件：create + modify
bash tests/harness/run.sh p0-smoke    # 单事件：P0 最小验收
```

`run.sh` 自动完成：构建 native → validate 预检规则 → 启动 server（`run` 非 `--once`）
→ 等就绪哨兵 → 跑 `trigger.py` → `wait` server 优雅退出（`--stop-after` 取场景 `expect` 条数）
→ 跑 `verify.py`。

手动分步（等价流程）：

```bash
mcp-watcher run --rules scenarios/demo-rules.json \
  --watch-dir $TMP/watch --results $TMP/results.jsonl \
  --ready $TMP/.ready --stop-after 1 &
SERVER_PID=$!
while [ ! -f $TMP/.ready ]; do sleep 0.05; done
python3 trigger.py --dir $TMP/watch --scenario scenarios/p0-smoke.json
wait $SERVER_PID
python3 verify.py --results $TMP/results.jsonl --scenario scenarios/p0-smoke.json
```

> 注意：子命令是 `run`（不是设计稿里曾写的 `run --test`），参数用 `--rules` 指定规则文件。

## 场景文件格式

```json
{
  "name": "basic",
  "description": "说明",
  "ops": [
    { "op": "create",  "path": "scratch.tmp", "content": "drop me" },
    { "op": "sleep",   "ms": 80 },
    { "op": "modify",  "path": "keep.md", "content": "\nappended", "append": true },
    { "op": "rename",  "from": "a.txt", "to": "b.txt" },
    { "op": "delete",  "path": "b.txt" },
    { "op": "mkdir",   "path": "sub" },
    { "op": "rmdir",   "path": "sub" }
  ],
  "expect": [
    { "rule_id": "cleanup", "event": "create", "action_type": "command" }
  ]
}
```

`ops` 支持：`create` / `modify`(`append`) / `rename`(`from`,`to`) / `delete` / `mkdir` / `rmdir` / `sleep`(`ms`)。
`expect` 中可用 `rule_id` / `event` / `action_type` 任意组合做子集匹配；`verify.py --strict` 要求无额外结果。

## 覆盖范围

| 场景 | 验证点 | 状态 |
|------|--------|------|
| p0-smoke | 单条真实 FsEvent + command 白名单放行 + 结果落盘 | ✅ 已覆盖 |
| basic | 多文件 create/modify + 路径正确性（**路径粘连回归网**） | ✅ 已覆盖 |
| exclude-priority | `exclude` 优先于 `patterns`、多规则优先级 | 规划中（P1） |
| debounce | 连续 modify 合并为一次 action | 规划中（P1） |
| cron | `real_interval` 驱动 `cron.next_after` 触发 | 规划中（P2） |
| deny-command | `ExecPolicy` 拒绝未授权程序 | 能力已实现（显式 allowlist，见 config-schema）；场景脚本待补 |
| rename / delete | 事件类型覆盖 | 规划中（P1） |
