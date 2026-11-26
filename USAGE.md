# mcp-watcher 使用说明（USAGE）

> mcp-watcher 是面向 AI 工作区的**自治运行时**：你（或 AI）用一份声明式规则描述"当什么发生，做什么"，它就在后台常驻、沉默地执行。本文件面向使用者，从安装构建到规则编写、CLI 用法、双门禁配置与常见问题。

## 1. 简介与定位

mcp-watcher 不是"通用的文件监控触发器"，而是带**产物生命周期语义**的动作系统：临时文件何时清理（TTL）、过期文件如何进回收站（trash）、Agent 跑出的中间产物如何被安全回收（command + 双门禁）。规则文件变更后可热重载，守护进程不停机。

定位语：**让 AI 工作区自己照顾自己，而不占用你和 Agent 的每一轮对话。**

## 2. 安装与构建

### 2.1 环境要求

- MoonBit 工具链（本项目实测版本：`0.1.20261104`）
- 依赖：`vicTop-cw/RX-MBT@0.4.6`、`moonbitlang/async@0.22.9`、`moonbitlang/x@0.5.5`（构建时自动拉取，见 `moon.mod`）

### 2.2 构建

```bash
cd <mcp-watcher 仓库根目录>   # 替换为你的 clone 路径
moon build --target native cmd/main   # 只构建最终可执行文件；勿整包 build（库包 link flags 会报缺 main）
```

产物路径（单仓库独立构建）：

```
_build/native/debug/build/cmd/main/main.exe
```

> 若仓库处于 moon workspace（如 `E:\IDEProjects\AI\moon.work`）内构建，`_build/` 会落在 workspace 根目录下，实际产物为 `<workspace根>/_build/native/debug/build/cmd/main/main.exe`。

也可直接通过 moon 运行：

```bash
moon run cmd/main -- validate --rules .mcp-watch.json
moon run cmd/main -- run --rules .mcp-watch.json --watch-dir .
```

> 版本以 `moon.mod` 声明为准（当前 0.2.4）。CLI `help` 输出的版本号已收敛到共享常量源 `util/version.mbt` 的 `APP_VERSION`，与 `moon.mod` 保持一致。

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

### 3.2.1 index 索引配置（schema v1.1 可选段 · native）

索引默认关闭（缺省等价 v1.0 行为）。开启后由 `index` 包用 SQLite FTS5 建立**工作区文件/文件夹元数据索引**（路径、类型、大小、mtime、ext），随文件事件增量更新，供 `search` 只读检索。设计详见 `workbuddy/plan/vector-index-design.md`。

```json
{
  "index": {
    "enabled": true,
    "db_path": "",
    "include": ["*.md", "*.json"],
    "exclude": [".git", "node_modules"],
    "embed": { "enabled": false, "model": "" }
  }
}
```

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `index.enabled` | bool | false | 是否开启索引；关闭时 `search` 不可用 |
| `index.db_path` | string | "" | SQLite 库绝对路径；空 = `<watch_dir>/.mcp-watch-index.db`；不得指向系统目录（fail-closed） |
| `index.include` | array\<string\> | [] | glob 白名单，空 = 不限 |
| `index.exclude` | array\<string\> | [] | glob 黑名单，与内置排除取并集（防自噬：db 文件与 `.mcp-watcher-trash` 自动排除） |
| `index.embed` | object | {enabled:false,model:""} | 向量召回 P1 占位：P0 仅解析不生效，`get_embedding` 当前恒空。**当前不是向量数据库**，仅是 FTS5 元数据 + 关键词检索 |

> 重要：当前索引是 **FTS5 全文/元数据检索**，不是向量相似度检索。关键词检索采用 FTS5 MATCH + `path LIKE` 兜底（并集去重，缓解 CJK 分词局限），过滤条件 type/ext/size/mtime 为 AND 组合。向量召回（embedding 列）为 P1 扩展位，未实现。

### 3.3 Rule 字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 规则唯一 id（热重载按 id 分派 live 版本） |
| `events` | array\<string\> | 文件事件 `create` / `modify` / `delete` / `rename` / `attrib` / `all`；或 interval 触发源 `interval:<ms>`（EP-03b，最小 1000ms，走真实时钟定时发射，可与其他事件类型混用） |
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
| `kind` | 动作类型：`command`（已落地） / `internal`（EP-01a：`reload_config` / `pause_watch` / `resume_watch` / `log_event`，已落地） / `mcp_tool_call`（EP-01c：stdio 桥仅 js 落地，native/wasm 返回可诊断错误） / `webhook`（EP-01 扩展位） |
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
| `{event.type}` | 事件类型（create / modify / delete / rename / attrib / interval） |
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

### 4.7 search — 工作区索引检索（native）

```bash
./main.exe search <watch_dir> --keyword "report" --ext md --limit 20
```

- `watch_dir` 是**位置参数**（必填）：配置从 `<watch_dir>/.mcp-watch.json` 读取，必须 `index.enabled=true` 且索引库已由服务建成，否则报错退出；
- 索引为 SQLite FTS5 **元数据检索**（非向量），随文件事件增量更新；输出为匹配节点（路径/类型/大小/mtime/ext）；
- 全部过滤条件为 AND 组合。

| 参数 | 说明 |
|---|---|
| `--keyword <kw>` | 关键词（FTS5 MATCH + `path LIKE` 兜底，并集去重） |
| `--type <file\|dir>` | 节点类型过滤 |
| `--ext <ext>` | 扩展名（小写、不含点） |
| `--min-size` / `--max-size` | 字节大小区间 |
| `--mtime-after` / `--mtime-before` | mtime 区间（毫秒时间戳） |
| `--limit <n>` | 返回条数（<=0 不限） |
| `--format <text\|jsonl>` | 输出格式 |
| `--db <path>` | 显式指定索引库（优先于配置 db_path） |

### 4.8 help

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

**已落地（三目标可编译，native 真做实）**：`encrypt_file` / `decrypt_file` 复用 rx rhop 的
纯 MoonBit AES-256-GCM 密码臂（PBKDF2-HMAC-SHA256 派生密钥，固定 salt，100000 轮）。
密文带魔数前缀 `MBPWCRYPT1 aes-256-gcm `，格式为 `base64(iv):base64(tag):base64(ct)`。

密钥解析优先级（显式 key > 环境变量 `MCP_WATCHER_CRYPT_KEY` > 内置默认口令），
即 `resolve_password()`。`decrypt_file` 对错误密钥 / 篡改密文经 GCM tag 认证失败，
返回可诊断 Err，**不会把坏数据写成明文覆盖产物**；往返满足
`decrypt_file ∘ encrypt_file = 恒等`（由 native 门控测试验证）。

### 6.4 wasm-gc 目标能构建吗？

暂不能。`moon test --target wasm-gc` 因 RX-MBT monitor 的 fs_* 符号未绑定而编译失败（[4021]/[4032]，relay.mbt / transport_local.mbt / watch.mbt）。属依赖侧缺口；当前支持 native（Windows 内核事件）与 js（fs.watch）双后端。

### 6.5 stop 之后守护进程还在？

`stop` 子命令待实现（P1）。当前请直接结束 `main.exe` 进程，并手动删除 `<watch_dir>/.mcp-watch.pid` 清理状态。

### 6.6 结果记录去哪了？

`run --results <FILE.jsonl>` 时执行结果以 JSONL 落盘（每行一条 ExecRecord）；不指定时仅输出日志。守护进程内日志轮转上限 1000 条，避免内存无限增长。

### 6.7 规则热重载不生效？

热重载按规则 `id` 分派 live 版本：改 id 等于新增规则（旧订阅 no-op），删规则需通过 reload 提交。守护进程在规则文件变更后自动加载（EP-01d）；也可手动 `reload --rules`。坏 JSON 会回退旧规则表并记录错误。

### 6.8 search 提示"索引未启用"或"索引库不存在"？

`search` 要求 `<watch_dir>/.mcp-watch.json` 中 `index.enabled=true`，且索引库已由服务启动时建立（默认 `<watch_dir>/.mcp-watch-index.db`）。当前无独立 rebuild 子命令，库损坏时删除库文件并重启服务重建。索引仅 native 可用（依赖 sqlite native stub）。

### 6.9 这是向量数据库吗？能做语义相似度搜索吗？

不是。当前是 **SQLite FTS5 全文/元数据索引**：存文件夹与文件的路径、类型、大小、mtime、ext，按关键词 + 过滤条件检索。`embedding` 列与向量召回是 P1 扩展位（`index.embed` 仅解析不生效，`get_embedding` 当前恒空），**未实现语义向量搜索**。设计与扩展路径见 `workbuddy/plan/vector-index-design.md`。

## 7. 更多资料

- 总体设计：`workbuddy/plan/design-spec.md`
- 配置契约：`workbuddy/plan/config-schema.md`
- 双门禁设计：`PLAN-gates.md`
- 工作区索引与向量召回扩展位：`workbuddy/plan/vector-index-design.md`
- 双进程集成测试物料：`tests/harness/README.md`、`tests/harness/server_contract.md`
- 申报材料：`competition/项目申报书.md`

## 8. 门禁读数（2026-11-23 本机实测）

| 项 | 读数 |
|---|---|
| `moon check --target native` | 0 errors / 82 warnings |
| `moon test --target native` | 本项目用例 292 个，failed: 0（含 sqlite 47/47、index 4/4） |
| `moon test --target js` | 本项目用例 292 个，failed: 0 |
| `moon test --target wasm` | 本项目用例 292 个，failed: 0 |
| `tests/harness/run.sh basic` | `RESULT: PASS`（双进程 + 路径粘连回归） |
| `tests/harness/run.sh deny` | `RESULT: PASS`（ExecPolicy 拒绝可观测） |
| `moon test --target wasm-gc` | 编译失败（RX-MBT fs_* 未绑定，依赖侧缺口） |
