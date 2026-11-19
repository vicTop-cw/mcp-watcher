# Server Test-Mode 协议（已实现 · 本文件为契约口径）

> 本文件定义"server"——即 mcp-watcher daemon 在测试模式下的启动约定、就绪哨兵、
> 结果落盘格式与停止方式。协议已在 P0 实现并跑通双进程验收（见 `../run.sh`），
> `trigger.py` / `verify.py` 直接对接。
>
> **实测校正**：实际子命令为 `run`（非下表曾写的 `run --test`），规则文件用 `--rules`；
> 结果字段由 scheduler 的 `ExecRecord` 结构化写入（非日志解析）。其余约定与本文一致。

## 1. 启动参数（契约）

```
mcp-watcher run
  --rules       <FILE>       # 规则配置（必填，校验不通过则拒绝启动）
  --watch-dir   <DIR>        # 被监听目录（必填，可覆盖规则文件里的 watch_dir）
  --results     <FILE.jsonl> # 触发结果写入此 JSONL（test-mode 落盘）
  --ready       <SENTINEL>   # 就绪哨兵文件（监听建立后创建）
  --stop-after  <N>          # 落盘 N 条真实执行记录后进程级退出（native exit）
  --debounce-ms <N>          # 覆盖去抖时长（P1 接入去抖链后生效）
```

> 可执行文件是 `mcp-watcher`（产物 `_build/native/debug/build/cmd/main/main.exe`），
> 子命令 `run` 不加 `--once`——`--once` 走的是不写 JSONL 的前台分支。

## 2. 就绪哨兵（Ready Sentinel）

- server 完成监听后端初始化（rx `watch_folder_native` 已订阅、EventBus 已注册规则）后，
  **创建** `--ready` 指定的哨兵文件（空文件即可）。
- trigger / 编排脚本轮询该文件存在后才开始制造事件，避免"事件早于监听"的竞态。
- server 退出前删除哨兵文件。

## 3. 结果 JSONL 格式（每行一个 JSON 对象）

```json
{
  "rule_id": "cleanup",
  "event": "create",
  "path": "/abs/watch/scratch.tmp",
  "action_type": "command",
  "exit": 0,
  "stdout": "...",
  "stderr": "",
  "ts": 1699790000123
}
```

字段说明：

| 字段 | 含义 |
|------|------|
| `rule_id` | 命中的规则 id（与场景 `expect.rule_id` 对拍） |
| `event` | 事件类型：`create` / `modify` / `delete` / `rename` |
| `path` | 触发文件的绝对路径 |
| `action_type` | 实际执行的动作：`command` / `mcp_tool_call` / `webhook` / `internal` |
| `exit` | command 动作的进程退出码（其它动作可省略或填 0） |
| `stdout` / `stderr` | command 动作的输出（截断到安全长度） |
| `ts` | 触发时刻（毫秒，真实墙钟） |

> 注意：server 只记录"真实触发的规则 + 实际 action 结果"，不记录未发生的事；
> `verify.py` 据此做子集/严格对拍。

## 4. 停止方式

- 收到 `SIGTERM` / `SIGINT`：刷新结果文件、删除就绪哨兵、退出。
- 或 `--stop-after N` 达到条数后自动优雅退出（推荐 CI 使用）。

## 5. 与 rx 的对接点（实现期）

- 监听：`monitor.watch_folder_native`（`Observable[WatchEvent]`，R2）。
- 派发：`EventBus.publish("create.*.tmp", event)`（R4），规则 `event_name` 用 `<事件类型>.<glob>`。
- 时间：`debounce_real` / `real_interval`（R1）驱动去抖与 cron。
- 命令：`run_command` + `ExecPolicy`（R3）执行 command action 并收集 `exit`/`stdout`。
