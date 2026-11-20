---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: 9f2a11add43fbf12a546606fb2b962ab_5cadd502e4d511f1a9b8525400f8a581
    ReservedCode1: ZXwWoDLoD1oRwOLJPtNUuORw50MkIyXeVLDj+JLOC263eSFFn8uzbNjLGFcPY02UfbfGNiuVnqEMDzErvz6gK04LlRFdynakCv+Y0EwR0gOh8vuktQV/RMPHdfEdnCkvYe16T2C3cy3p18dWa95+y2jLtP9FIcINkm2giQqs24DO94F6zxVeUXRN0yc=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: 9f2a11add43fbf12a546606fb2b962ab_5cadd502e4d511f1a9b8525400f8a581
    ReservedCode2: ZXwWoDLoD1oRwOLJPtNUuORw50MkIyXeVLDj+JLOC263eSFFn8uzbNjLGFcPY02UfbfGNiuVnqEMDzErvz6gK04LlRFdynakCv+Y0EwR0gOh8vuktQV/RMPHdfEdnCkvYe16T2C3cy3p18dWa95+y2jLtP9FIcINkm2giQqs24DO94F6zxVeUXRN0yc=
---

# mcp-watcher 使用说明（USAGE）

> mcp-watcher 是面向 AI 工作区的**自治运行时**：你（或 AI）用一份声明式规则描述"当什么发生，做什么"，它就在后台常驻、沉默地执行。本文件面向使用者，从安装构建到规则编写、CLI 用法、双门禁配置与常见问题。

## 1. 简介与定位

mcp-watcher 不是"通用的文件监控触发器"，而是带**产物生命周期语义**的动作系统：临时文件何时清理（TTL）、过期文件如何进回收站（trash）、Agent 跑出的中间产物如何被安全回收（command + 双门禁）。规则文件变更后可热重载，守护进程不停机。

定位语：**让 AI 工作区自己照顾自己，而不占用你和 Agent 的每一轮对话。**

## 2. 安装与构建

### 2.1 环境要求

- MoonBit 工具链（本项目实测版本：`0.1.20261104`）
- 依赖：`vicTop-cw/RX-MBT@0.4.6`、`moonbitlang/async@0.22.9`（构建时自动拉取，见 `moon.mod`）

### 2.2 构建

```bash
cd E:\IDEProjects\AI\mcp-watcher   # 或你的 clone 目录
moon build --target native
```

产物路径：

```
_build/native/debug/build/cmd/main/main.exe
```

也可直接通过 moon 运行：

```bash
moon run cmd/main -- validate --rules .mcp-watch.json
moon run cmd/main -- run --rules .mcp-watch.json --watch-dir .
```

> 版本以 `moon.mod` 声明为准（当前 0.2.1）。CLI `help` 输出的版本号已收敛到共享常量源 `util/version.mbt` 的 `APP_VERSION`，与 `moon.mod` 保持一致。

## 3. 规则文件：`.mcp-watch.json`

规则文件是 JSON DSL（schema_version = 1）。默认文件名 `.mcp-watch.json`，可用 `--rules` 指定其他路径。

### 3.1 最小示例

```json
{
  "schema_version": 1,
  "watch_id": "demo",
  "watch_dir": ".",
  "recursive": true,
  "debounce_ms": 100,
  "allowed_programs": ["cmd"],
  "rules": [
    {
      "id": "cleanup",
      "events": ["create"],
      "patterns": ["*.tmp"],
      "exclude": ["keep.tmp"],
      "actions": [
        { "kind": "command", "argv": ["cmd", "/c", "echo", "cleanup"] }
      ]
    }
  ]
}
```

### 3.2 顶层字段说明

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `schema_version` | int | 必填 | 当前为 `1`；校验 fail-closed |
| `watch_id` | string | 必填 | 监控实例 id，用于 pidfile / 占位符 `{watch_id}` |
| `watch_dir` | string | "" | 监控根目录；可用 CLI `--watch-dir` 覆盖 |
| `recursive` | bool | true | 是否递归监控子目录 |
| `debounce_ms` | int | 0 | 事件去抖毫秒数；>0 时同时作为热重载窗口 |
| `allowed_programs` | array\<string\> | []（空=不执行任何命令） | **命令白名单**。command 动作只放行此处声明的 argv[0]；为空时任何命令都不执行（安全默认） |
| `extensions` | object | — | 扩展位占位（EP-07 v1.0 预留） |
| `rules` | array\<Rule\> | 必填 | 规则表，按 `priority` 降序执行 |

### 3.3 Rule 字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 规则唯一 id（热重载按 id 分派 live 版本） |
| `events` | array\<string\> | `create` / `modify` / `delete` / `rename` / `attrib` / `all` |
| `patterns` | array\<string\> | glob 模式（如 `*.tmp`、`**/*.log`） |
| `exclude` | array\<string\> | 排除模式，**优先于** patterns 匹配 |
| `conditions` | array\<object\> | 条件（AND 语义）：`age_seconds` / `file_size_gt` / `file_size_lt` / `mime_contains` / `not_modified_for` / `custom_script` |
| `priority` | int | 优先级，数值大者先执行（`from_priority` 映射 Critical/High/Medium/Low/Debug） |
| `stop_after` | bool | once 语义：命中一次后本规则退场 |
| `guard` | object? | 守卫门配置（§5.1），动作执行前准入 |
| `actions` | array\<Action\> | 动作组，按顺序执行 |

### 3.4 Action 字段

```json
{
  "kind": "command",
  "argv": ["cmd", "/c", "echo", "cleanup"],
  "acceptance": {
    "expect_exit": 0,
    "stdout_contains": ["cleanup"],
    "stdout_not_contains": [],
    "stderr_not_contains": ["error"],
    "artifact_glob": ["*.out"]
  }
}
```

| 字段 | 说明 |
|---|---|
| `kind` | 动作类型：`command`（已落地） / `mcp_tool_call`（EP-01 扩展位，返回可诊断错误） / `webhook`（EP-01 扩展位） / `internal`（EP-01a：`reload_config` / `pause_watch` / `resume_watch` / `log_event`） |
| `argv` | 命令参数数组（**只走 argv，绝不走 shell**；`argv[0]` 必须在 `allowed_programs` 白名单内） |
| `acceptance` | 验收门配置（§5.2），仅 command 有效 |

### 3.5 变量占位符

| 占位符 | 说明 |
|---|---|
| `{file.path}` | 触发文件的完整绝对路径 |
| `{file.name}` | 触发文件名（不含目录） |
| `{file.dir}` | 触发文件所在目录 |
| `{file.ext}` | 文件扩展名（不含点） |
| `{file.size}` | 文件大小（字节） |
| `{file.mtime}` | 文件最后修改时间 |
| `{event.type}` | 事件类型（create / modify / delete / rename / attrib） |
| `{watch_dir}` | 监控根目录 |
| `{watch_id}` | 监控实例 id |

## 4. CLI 子命令

所有子命令统一入口为构建出的 `main.exe`（或 `moon run cmd/main -- ...`）。

### 4.1 validate — 校验规则

```bash
./main.exe validate --rules .mcp-watch.json
```

- 退出码 0 = 校验通过；1 = 失败（fail-closed，输出具体错误）
- 通过时打印规则数 / watch_dir / recursive / debounce_ms / 规则摘要

### 4.2 start — 启动守护进程（写 pidfile）

```bash
./main.exe start --rules .mcp-watch.json --watch-dir .
```

- 校验配置 → 检查 pidfile（`<watch_dir>/.mcp-watch.pid`，已存在则拒绝重复启动）→ 写入 pidfile → 提示成功
- pidfile 中 pid 为时间戳占位（当前无法取真实 pid）
- 注意：`start` 仅登记状态；实际监控由 `run` 承担

### 4.3 status — 查看状态

```bash
./main.exe status --rules .mcp-watch.json --watch-dir .
```

- 读取并解析 pidfile，显示 watch_id / pid / 运行状态
- pidfile 不存在 → "未运行"

### 4.4 run — 后台自治运行

```bash
./main.exe run --rules .mcp-watch.json --watch-dir .
```

test-mode 参数（对齐 `tests/harness/server_contract.md`）：

| 参数 | 说明 |
|---|---|
| `--results <FILE.jsonl>` | 执行结果 JSONL 落盘（ExecRecord：rule_id / event / path / action_type / exit_code / stdout / stderr） |
| `--ready <SENTINEL>` | 就绪哨兵文件（先创建，避免事件早于监听的竞态） |
| `--stop-after <N>` | 触发 N 条结果后退出（并删除哨兵） |
| `--debounce-ms <N>` | 覆盖配置里的去抖时长 |
| `--once` | 前台运行一次，日志直出 stdout（`run --once`） |

示例（对应 e2e 场景）：

```bash
./main.exe run --rules scenarios/basic.json --watch-dir .watch \
  --results .results.jsonl --ready .ready --stop-after 2
```

### 4.5 reload — 热重载规则

```bash
./main.exe reload --rules .mcp-watch.json
```

- 重新解析规则文件并报告规则数；失败时保留旧规则表并输出错误
- 守护进程侧同时支持**文件变更自动热重载**（EP-01d：`fire_rules_reload`，坏 JSON 回退旧规则表并记日志）

### 4.6 stop — 停止守护进程（P1 待实现）

```bash
./main.exe stop
```

- **当前为待实现状态**：输出提示并指导手动删除 pidfile 清理状态
- 真正终止守护进程属 P1 计划；目前停止常驻进程请直接结束 `main.exe` 进程

### 4.7 help

```bash
./main.exe help
```

打印完整用法与子命令列表。

## 5. 双门禁配置（schema v1.1 · PLAN-gates.md）

双门禁 = **动作准入（前）+ 产物有效性（后）**。全部纯函数判定、零新依赖、不引入重试循环；v1.0 规则（无这两个字段）行为逐位不变。

### 5.1 guard — 守卫门（动作执行前）

| 字段 | 说明 |
|---|---|
| `guard.argv` | 守卫命令参数数组（必非空；与 command 同走白名单校验，绝不走 shell） |
| `guard.on_fail` | `skip`：记 `guard_fail` 事件跳过本次动作（规则存活）；`stop`：记事件并停止本规则后续处理 |

```json
{
  "guard": { "argv": ["cmd", "/c", "test", "-e", ".ready"], "on_fail": "skip" }
}
```

红线：guard 不做组合逻辑（需要 AND/OR 的守卫用条件层组合）。

### 5.2 acceptance — 验收门（动作执行后）

| 字段 | 说明 |
|---|---|
| `expect_exit` | 期望退出码（不匹配 → accepted=false） |
| `stdout_contains` | stdout 必须包含全部子串（AND） |
| `stdout_not_contains` | stdout 不得包含任一子串 |
| `stderr_not_contains` | stderr 不得包含任一子串 |
| `artifact_glob` | 相对 watch_dir 至少命中 1 个文件（相对路径模式） |

失败处置：`accepted=false` 保留真实 exit 与输出原文，触发 `product.invalid` 进入既有 TTL/trash 回收流，**不做自动重试**（重试留给上层）。

## 6. 常见问题（FAQ）

### 6.1 我配了规则但 run 收不到事件？

**已知缺陷（2026-11-20 定位）**：rx 的 `watch_folder_native` 轮询循环使用线程级 `Sleep()`，MoonBit 协作式 async 单线程下首个 watch 订阅任务会独占执行线程。当**规则文件目录不在 `watch_dir` 覆盖范围内**时，守护进程会补监控规则文件目录（第二个 watch 任务），该任务永不获得调度，导致 `watch_dir` 事件收不到。

**规避**：把规则文件放在 `watch_dir` 内部（或其子目录下），避免触发补监控；或先用 `validate` + `run --once` 前台验证规则与事件链路。

### 6.2 为什么命令没执行？

检查 `allowed_programs`：command 动作只放行此处声明的 argv[0]，**空列表 = 不执行任何命令**（安全默认）。白名单外的命令会被 ExecPolicy 拒绝，并在结果记录中落 `exit_code=-1` + 拒绝原因。

### 6.3 加密（encrypt）怎么用？

**当前为诚实降级**：rx 的 Fernet 原语是 `extern "js"`（node:crypto），native/wasm 下加密返回空串；本项返回可诊断错误，**绝不写空密文破坏产物**。待 rx 补 native crypto FFI 后可做实。

### 6.4 wasm-gc 目标能构建吗？

暂不能。`moon test --target wasm-gc` 因 RX-MBT monitor 的 fs_* 符号未绑定而编译失败（[4021]/[4032]，relay.mbt / transport_local.mbt / watch.mbt）。属依赖侧缺口；当前支持 native（Windows 内核事件）与 js（fs.watch）双后端。

### 6.5 stop 之后守护进程还在？

`stop` 子命令待实现（P1）。当前请直接结束 `main.exe` 进程，并手动删除 `<watch_dir>/.mcp-watch.pid` 清理状态。

### 6.6 结果记录去哪了？

`run --results <FILE.jsonl>` 时执行结果以 JSONL 落盘（每行一条 ExecRecord）；不指定时仅输出日志。守护进程内日志轮转上限 1000 条，避免内存无限增长。

### 6.7 规则热重载不生效？

热重载按规则 `id` 分派 live 版本：改 id 等于新增规则（旧订阅 no-op），删规则需通过 reload 提交。守护进程在规则文件变更后自动加载（EP-01d）；也可手动 `reload --rules`。坏 JSON 会回退旧规则表并记录错误。

## 7. 更多资料

- 总体设计：`workbuddy/plan/design-spec.md`
- 配置契约：`workbuddy/plan/config-schema.md`
- 双门禁设计：`PLAN-gates.md`
- 双进程集成测试物料：`tests/harness/README.md`、`tests/harness/server_contract.md`
- 申报材料：`competition/项目申报书.md`
*（内容由AI生成，仅供参考）*
