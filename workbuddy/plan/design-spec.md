# mcp-watcher 详细设计决议（MoonBit 实现）

> 本文件是《设计稿 v0.1-draft》（docx）的延续与落地决议。前者为概念草案，本文件决定"怎么实现"。
> 决策权：由 Amp 自主裁定（用户授权"你来决定后面的设计"）。所有标记为 **【决议】** 的条目即最终设计，后续实现以本文件为准。
> 文档格式：Markdown（取代 docx，作为项目权威设计文档）。`config-schema.md` 为配套的配置契约。

## 0. 范围与原则

- 本版只决定 v1.0 参赛所需的设计；未来能力一律通过扩展位（EP-01~EP-12）接入，不在核心里开洞。
- 单一真源：本 md + `config-schema.md` 为权威；docx 草案仅作概念留存。
- 门禁纪律沿用项目惯例：状态声明 = 代码真实；每批改动做范围 diff 审计 + 全门禁回归；仅格式化本批变更文件，禁整仓 `moon fmt`。

## 1. 工程与构建（MoonBit）

**【决议】** 使用 MoonBit 官方工具链，`moon` 构建，目标 `native`，产出单二进制 `mcp-watch`，零运行期依赖。

- 根 `moon.mod.json`：`{ "name": "mcp-watcher", "version": "0.1.0" }`
- 包（`moon.pkg.json`）按模块划分，与草案 3.2 一致：`cli` / `config` / `watch` / `rule` / `action` / `ext` / `util`。
- 构建：`moon build --target native`，产物 `target/native/release/build/mcp-watcher`。
- 三平台后端在**编译期**择一编译（非运行期分支）：
  - Linux x86_64 → inotify（libc FFI）
  - macOS arm64 / x86_64 → FSEvents（CoreFoundation FFI）
  - Windows x86_64 → ReadDirectoryChangesW（Win32 FFI）
- **【决议】** 文件系统监听通过 MoonBit `@ffi` 调用平台系统 API，封装在 `watch/backend_*.mbt`（每平台一个）。不引入运行期轮询。

## 2. 核心类型（config + watch）

```moonbit
// config/model.mbt —— 示意，最终以实现期 MoonBit 语法为准
struct Config {
  schema_version: Int
  watch_id: String
  watch_dir: String
  recursive: Bool
  debounce_ms: Int
  extensions: List[ExtensionDecl]
  rules: Array[Rule]
} derive(Show, @json)

struct Rule {
  id: String
  events: Array[EventType]
  patterns: Array[String]
  exclude: Array[String]
  condition: Option[ConditionSpec]
  actions: Array[ActionSpec]
  stop_after: Bool          // EP-06 预留字段，v1.0 默认 false、忽略
} derive(Show, @json)

enum EventType { Create; Modify; Delete; Rename; Attrib; All } derive(@json)

// watch/event.mbt
struct FsEvent {
  event_type: EventType
  path: String              // 绝对路径
  is_dir: Bool
  mtime: Int
  size: Int
}
```

**【决议】** JSON 解析统一用 MoonBit `@json` derive + `from_json`，零手写 parser；字段级错误由 derive 上抛，语义层校验由 validator 负责（见 §3）。

## 3. 配置加载与校验

流程（`config/loader.mbt` + `config/validator.mbt`）：

1. 读文件 → `Json` → `Config::from_json`；语法错直接返回 `ConfigError::Parse`。
2. 校验 `schema_version`：v1 直读；未来 v2+ 走 `schema_migration`（EP-09）。
3. 语义校验（**累积式**，非空错误列表）：
   - `watch_id` 非空且不与本机运行实例冲突；
   - `watch_dir` 存在；
   - 每条 `Rule`：`id` 唯一、`events` 非空、`patterns` 非空、`actions` 非空；
   - glob 语法合法；`condition` 字段合法；action `type` 为已知类型或已注册（EP-01）；
   - `debounce_ms` ≥ 0。
4. 通过 → `Ok(Config)`；否则 `Err(ConfigError(errors: List[String]))`。

**【决议】** 校验为累积式（一次性报告全部问题），便于用户一次改完配置，而非改一处报一处。

## 4. 两层匹配算法（rule/matcher.mbt）

```
for each FsEvent ev:
  rel = relative_path(ev.path, watch_dir)
  for each Rule r in rules (按配置顺序):
    if ev.event_type ∉ r.events and All ∉ r.events: continue
    if any(exclude glob matches rel): continue
    if not any(pattern glob matches rel): continue
    if r.condition present and not eval_condition(r.condition, ev): continue
    emit match(r, ev)
    if r.stop_after: break          // EP-06
```

- glob 工具（`util/glob.mbt`）：支持 `**`；编译期预编译 pattern 提升匹配速度。
- condition 求值：`Condition` trait（EP-02）；`custom_script` 走逃生舱——spawn 脚本、退出码 0 = 通过。
- 同一事件可命中多条规则并顺序执行，除非 `stop_after`。
- `exclude` 优先级高于 `patterns`（先排除再匹配）。

## 5. 去重与合并（rule/debounce.mbt）

**【决议】** 按"路径"键做定时器合并（v1.0 颗粒度为路径；规则级合并列为 EP-06 后续）：

- 事件到达 → 以 `path` 为键重置 debounce 定时器（取全局或本规则 `debounce_ms`）。
- 定时器触发 → 取窗口内最后一次事件类型，发出合并事件交给 matcher；同一窗口多次事件只匹配一次，抵御编辑器原子保存产生的事件风暴。
- 定时器用最小堆 / 时间轮实现，避免每事件一个线程。

## 6. 动作分发（action/dispatcher.mbt）

```moonbit
trait Action {
  name(Self) -> String
  execute(Self, ctx: ActionContext) -> Result[Unit, ActionError]
}
```

- Dispatcher 顺序执行 `actions`，每个动作构造对应 `Action` 实例（内置动作即实现该 trait 的 struct）。
- `on_error` 决定 `continue` / `stop`（默认 stop 本规则剩余动作，继续下一条规则）。
- `command`：`Process.spawn` + `timeout_ms`，捕获 stdout/stderr，非零退出按 `on_error` 处理。
- `mcp_tool_call`：`Transport` trait 抽象（EP-05），v1.0 实现 `stdio` / `sse` / `http`。
- `webhook`：HTTP 客户端 POST/GET。
- `internal`：`reload_config` / `pause_watch` / `resume_watch` / `log_event`。
- `dry_run`（EP-12）：全局或规则级，开启时只 log 不执行任何副作用。

## 7. 扩展位落地（ext/）

**【决议·重要】** v1.0 采用 **编译期 trait + 注册表** 模式，**非运行期动态加载**。理由（诚实标注）：

- 单二进制 native 程序的动态插件加载（dlopen/.so 或 WASM）在 MoonBit native 下尚不成熟、风险高；
- 更稳的方案：扩展 = 实现 trait + 在 `main` / `registry` 注册 + 重编译；AI 与社区可贡献，但走构建链路；
- EP-07 `extensions:` 配置键 v1.0 **声明并解析，但仅做校验/占位**；真正的动态加载列为 v1.x 能力（当前不可达，理论下限 = 编译期注册）。

注册表：

```moonbit
struct Registry {
  actions:    Map[String, (ActionSpec) -> Action]            // 类型名 -> 工厂
  conditions: Map[String, ConditionSpec -> Condition]
  contexts:   List[ContextProvider]
  backends:   Map[String, () -> WatcherBackend]
  transports: Map[String, () -> Transport]
}
```

- 内置项在 `registry.builtin()` 注册；扩展项由 `main` 追加（对应 EP-01/02/03/04/05）。
- 生命周期钩子 EP-08：`pre_match` / `post_match` / `pre_action` / `post_action` / `on_error` / `on_reload` 以可选回调列表挂在 Engine 上，默认空；v1.0 至少 `on_reload` / `on_error` 生效（用于审计与可观测）。

## 8. 热重载（watch/engine.mbt）

机制：

- Engine 始终额外监听配置文件自身路径（独立于用户规则）；事件 `modify` → 触发 reload。
- reload：`loader.load(new_bytes)`；
  - 合法 → 原子替换 `Arc<RwLock<RuleTable>>`，监听不中断；
  - 非法 → 记 error + 保留旧表，**绝不退出**（设计哲学"永不因配置错崩溃"）。
- 配置被删：保留旧表并告警（避免自杀式卸载）。
- EP-08 `on_reload` 钩子在替换前后触发。

## 9. CLI（cli.mbt）

| 命令 | 行为 | 实现要点 |
|------|------|----------|
| `mcp-watch start /path` | 后台启动，返回 pid | 写 pidfile `watch_dir/.mcp-watch.pid`；已存在则拒绝重复启动 |
| `mcp-watch stop /path` | 停止 | 读 pidfile → SIGTERM，超时兜底 SIGKILL |
| `mcp-watch status` | 列出实例 | 扫描 pidfile / 注册表，显示 watch_id + pid + 存活 |
| `mcp-watch run /path` | 前台运行 | 调试，日志直出 stdout |
| `mcp-watch validate <file>` | 校验 | 跑 loader + validator，打印错误列表 |

**【决议】** 不做全局 daemon；每项目一进程。Windows 后台用 `CreateProcess` 分离，Unix 用 double-fork / nohup 等价。简单 = 可靠，一个项目挂了不影响其他。

## 10. 日志与可观测（util/log + EP-10）

- 结构化日志（级别 + 时间戳 + `rule_id` + 事件）；`audit_sink` 抽象（file / stdout，webhook 预留）。
- `internal` 的 `log_event` 写审计；敏感动作（加密 / 告警）强制审计行。

## 11. 测试与门禁

门禁（全绿才允许推送 / 参赛）：

| 项 | 命令 / 标准 |
|----|-------------|
| 构建 | `moon build --target native` 零错 |
| 单测 | `moon test` 全过 |
| 格式 | `moon fmt` 仅本批变更文件（禁整仓） |
| 静态 | moon 警告清零（等价 clippy） |
| 契约 | 每个 EP 的 trait 接口契约测试（自定义 Action / Condition 可注册并执行） |
| 集成 | 两层匹配 + 热重载 + 三后端行为一致 |
| 安全 | dry-run 零副作用；command 带 timeout + on_error |

**【决议】** 沿用 Tnr 铁律：测试计数单一真源（`check_test_count` 实测一致）；状态声明 = 代码真实，声称口径与实测不一致时如实标注差额。

## 12. 演进路线（决定版）

| 阶段 | 交付 | 门禁 |
|------|------|------|
| v0.1 | 单目录监控 + command + debounce + 三后端桩 | 构建 + 单测 + 匹配单测 |
| v0.2 | condition 子系统 + 热重载 + dry-run（EP-12） | + 热重载集成测试 |
| v0.3 | mcp_tool_call + webhook + Registry / EP-07 占位 | + 动作契约测试 |
| v0.4 | custom_script condition + glob `**`（EP-02） | + condition 测试 |
| v0.5 | 多实例 status + 变量 / 遥测扩展（EP-03/10/11） | + 跨实例测试 |
| v1.0 | 参赛版 + 完整文档 + 全门禁 | 全绿 |

**原则：先关后开**——v1.0 交付所有扩展位的接口与默认实现，具体扩展模块按路线逐步开放，避免一次性暴露未稳定能力。
