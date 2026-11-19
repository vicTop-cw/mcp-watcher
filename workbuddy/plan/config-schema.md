# mcp-watcher 配置 Schema 权威定义（v1.0）

> 配套 `design-spec.md`。本文件是 `.mcp-watch.json` 的**唯一权威契约**：字段、类型、约束、校验规则、示例。
> 实现以本文件为准；`design-spec.md` 描述算法与模块，本文件描述数据结构本身。

## 1. 顶层对象

| 字段 | 类型 | 必填 | 默认 | 约束 |
|------|------|------|------|------|
| `schema_version` | `integer` | 是 | `1` | 当前仅接受 `1`；非 1 走 `schema_migration`（EP-09，v1.0 暂仅 v1） |
| `watch_id` | `string` | 是 | — | 非空；本机运行实例间需唯一 |
| `watch_dir` | `string` | 是 | — | 相对配置文件所在目录；目录须存在 |
| `recursive` | `boolean` | 否 | `true` | 是否递归监听子目录 |
| `debounce_ms` | `integer` | 否 | `0` | ≥ 0；全局去重窗口（实测：loader 默认 0，非早期草案的 300） |
| `allowed_programs` | `array<string>` | 否 | `[]` | **命令执行显式白名单**（如 `["cmd","git"]`）。默认空 = 不执行任何命令；规则含 command 但程序不在表内 → 运行时 ExecPolicy 拒绝，加载时给警告。**不从 argv 自动收集** |
| `extensions` | `array<ExtensionDecl>` | 否 | `[]` | 扩展声明（EP-07）；v1.0 仅解析校验、占位 |
| `rules` | `array<Rule>` | 是 | — | 至少一条；按数组顺序匹配与执行 |

> 安全模型（2026-11-17 修正）：白名单必须显式声明。早期"从规则 argv[0] 自动收集"
> 的语义等于"规则写什么就放行什么"，已废弃，理由见 `p3-feasibility.md` 之外的
> 安全决策说明（本次提升方向第 ④ 项）。

## 2. Rule 对象

| 字段 | 类型 | 必填 | 默认 | 约束 |
|------|------|------|------|------|
| `id` | `string` | 是 | — | 非空；同配置文件内唯一 |
| `events` | `array<EventType>` | 是 | — | 非空；元素见 §3 |
| `patterns` | `array<string>` | 是 | — | 非空；glob，支持 `**` |
| `exclude` | `array<string>` | 否 | `[]` | glob；优先级高于 `patterns` |
| `condition` | `Condition` | 否 | 恒真 | 见 §4；多个条件间为 AND |
| `actions` | `array<Action>` | 是 | — | 非空；顺序执行 |
| `stop_after` | `boolean` | 否 | `false` | EP-06 预留字段，v1.0 忽略 |

## 3. EventType（枚举）

取值：`"create"` / `"modify"` / `"delete"` / `"rename"` / `"attrib"` / `"*"`（全部）。
`events` 数组可含多个值；命中任一即视为事件类型匹配。

## 4. Condition 对象

`condition` 为对象，键即条件名，可含多个键（AND 关系）。

| 条件键 | 类型 | 语义 |
|--------|------|------|
| `age_seconds` | `integer` | 文件年龄 > N 秒 |
| `file_size_gt` | `integer` | 文件大小 > N 字节 |
| `file_size_lt` | `integer` | 文件大小 < N 字节 |
| `mime_contains` | `string` | MIME 类型包含子串 |
| `not_modified_for` | `integer` | 连续 N 秒未修改（延迟清理常用） |
| `custom_script` | `string` | 退出码 0 = 通过（逃生舱，EP-02） |

**校验规则**：条件键必须为上表之一；`age_seconds` / `file_size_*` / `not_modified_for` 须为非负整数；`custom_script` 须为可执行路径或命令。

## 5. Action 对象

`action` 为对象，必含 `type`；其余字段按 `type` 区分。

| `type` | 用途 | 关键字段 |
|--------|------|----------|
| `command` | 执行外部命令 | `cmd: string`（必）、`args: array<string>`、`cwd: string`、`env: object`、`timeout_ms: integer`、`on_error: "continue"\|"stop"`（默认 `stop`） |
| `mcp_tool_call` | 调用 MCP 工具 | `server: string`、`tool: string`、`args: object`、`transport: "stdio"\|"sse"\|"http"`（默认 `stdio`）、`timeout_ms: integer` |
| `webhook` | HTTP 通知 | `url: string`（必）、`method: "GET"\|"POST"`（默认 `POST`）、`headers: object`、`body: string`（支持变量占位符） |
| `internal` | 内置动作 | `op: "reload_config"\|"pause_watch"\|"resume_watch"\|"log_event"`（必）、`message: string`（仅 `log_event` 用） |

**校验规则**：`type` 必须为上表之一，或已在注册表注册（EP-01 自定义动作）；各 `type` 的必填字段缺失即报错；`on_error` 仅接受枚举值。

## 6. ExtensionDecl 对象（EP-07，v1.0 占位）

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `kind` | `string` | 是 | 取值 `action` / `condition` / `context` / `backend` / `transport` |
| `name` | `string` | 是 | 扩展名（预留，v1.0 不加载） |
| `path` | `string` | 否 | 扩展模块路径（预留，v1.0 忽略） |

**校验规则**：v1.0 仅校验 `kind` 枚举合法，不实际加载；解析后存入 `Config.extensions` 供未来使用（诚实标注：动态加载不可达，理论下限为编译期注册）。

## 7. 变量占位符

动作字段（`args` / `body` / `message` / `cmd` 的拼接）执行时按上下文替换：

| 变量 | 来源 |
|------|------|
| `{file.path}` | 触发文件的绝对路径 |
| `{file.name}` | 文件名 |
| `{file.dir}` | 文件所在目录 |
| `{file.ext}` | 扩展名（无扩展名时替换为空串 + warning） |
| `{file.size}` | 大小（字节） |
| `{file.mtime}` | 修改时间（Unix 秒） |
| `{event.type}` | 事件类型 |
| `{watch_dir}` | 监控根目录 |
| `{watch_id}` | 实例 ID |

解析失败（如 `{file.ext}` 对无扩展名文件）替换为空串并记 warning，不中断动作链（除非动作显式要求非空）。

## 8. 完整示例

### 示例 A — 清理（Demo 1）

```json
{
  "schema_version": 1,
  "watch_id": "cleanup-demo",
  "watch_dir": ".",
  "debounce_ms": 300,
  "rules": [
    {
      "id": "archive-stale-tmp",
      "events": ["modify", "create"],
      "patterns": ["**/*.tmp"],
      "condition": { "not_modified_for": 30 },
      "actions": [
        { "type": "command", "cmd": "mv", "args": ["{file.path}", "archive/{file.name}"] }
      ]
    }
  ]
}
```

### 示例 B — 安全（Demo 2）

```json
{
  "schema_version": 1,
  "watch_id": "secret-guard",
  "watch_dir": ".",
  "rules": [
    {
      "id": "encrypt-dotenv",
      "events": ["create", "modify"],
      "patterns": [".env", "config.json"],
      "condition": { "custom_script": "./check_password.sh {file.path}" },
      "actions": [
        { "type": "command", "cmd": "age", "args": ["--encrypt", "-o", "{file.path}.age", "{file.path}"] },
        { "type": "internal", "op": "log_event", "message": "encrypted secret: {file.path}" }
      ]
    }
  ]
}
```

### 示例 C — 自举热重载（Demo 3）

```json
{
  "schema_version": 1,
  "watch_id": "self-reload",
  "watch_dir": ".",
  "rules": [
    {
      "id": "reload-on-config-change",
      "events": ["modify"],
      "patterns": [".mcp-watch.json"],
      "actions": [ { "type": "internal", "op": "reload_config" } ]
    }
  ]
}
```

### 示例 D — dry-run 安全预览（EP-12）

```json
{
  "schema_version": 1,
  "watch_id": "dryrun-preview",
  "watch_dir": ".",
  "rules": [
    {
      "id": "preview-delete",
      "events": ["create"],
      "patterns": ["**/*.log"],
      "actions": [
        { "type": "command", "cmd": "rm", "args": ["{file.path}"], "on_error": "continue" }
      ],
      "simulate": true
    }
  ]
}
```

> `simulate: true`（规则级 dry-run，EP-12）开启时，动作只 log 不执行副作用。

## 9. 校验失败处理总览

- **语法错**（`from_json` 失败）→ `ConfigError::Parse`，拒绝加载。
- **语义错**（累积式）→ 返回错误列表，用户一次修完；`validate` 命令直接打印。
- **热重载时非法** → 保留旧规则表，记 error，进程不退出（设计哲学"永不因配置错崩溃"）。
- **变量解析失败** → 空串替换 + warning，不中断。
