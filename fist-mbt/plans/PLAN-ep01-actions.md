# PLAN · EP-01 扩展位收口 + 完善度实测（2026-11-18）

> 本文是 2026-11-18 实测记录：哪些已完善、哪些仍缺、按什么顺序收。
> Schema 权威：`workbuddy/plan/config-schema.md` v1.0。

## 一、实测完成度（@ mcp-watcher 0.1.0）

| 能力 | 状态 | 证据 |
|------|------|------|
| 声明式规则（JSON DSL v1.0） | ✅ | `config/loader.mbt` + schema 权威文件 |
| TTL 产物追踪 | ✅ | `action/action.mbt` ProductTracker register/cleanup/save/load |
| trash（native） | ✅ | `action/trash_native.mbt`；js/wasm 诚实降级 |
| command（白名单） | ✅ | `run_command_action` + ExecPolicy 显式 `allowed_programs` |
| cron 解析 | ✅ | `cron/cron.mbt`：parse/matches/next_after 全套 |
| 真实时钟调度 | ✅ | `scheduler/scheduler.mbt`（real clock 注入 + run_once） |
| 热重载 | 🚧 | `reload_config` + CLI `reload` 子命令在位；**缺规则文件变更自动触发** |
| 产物加密 | 🚧 降级 | `encrypt_file` 返回可诊断 Err，等 rx-mbt R1 native crypto |
| `mcp_tool_call` | ❌ EP-01 | 返回可诊断错误 |
| `webhook` | ❌ EP-01 | 同上 |
| `internal` | ⚠️ 半 | `op: reload_config/pause_watch/resume_watch/log_event` schema 已定义，动作注册表未建立 |

## 二、EP-01 收口计划（建议顺序）

### EP-01a · `internal` 内置动作（先做，零外部依赖）

- 建动作注册表：`op` 四枚举直连 scheduler 既有函数（`reload_config` 复用 `scheduler.mbt:290`）。
- 验收：规则内触发 reload/暂停/恢复/记日志各 1 条 e2e；`log_event` 落 LifecycleEvent。

### EP-01b · `webhook`（次做，依赖面最小）

- POST/GET + 超时 + 变量占位符替换（`{{path}}`/`{{event}}` 等，按 schema §7）。
- 复用 rx 响应式算子做失败退避（debounce_real + 重试上限）；native 轨 HTTP 走轻量 socket FFI 或先 js-only 诚实降级（与 trash 同款策略）。

### EP-01c · `mcp_tool_call`（最后，价值最大——打通「watcher 触发 → fist-mbt 派单」）

- stdio transport 优先：spawn `server_cmd`、JSON-RPC `tools/call`、回执超时判定。
- 安全：server 命令同样进 `allowed_programs` 白名单；args 只做 schema §7 占位符替换，不经过 shell。
- 验收：对 fist-mbt 发一条 `publish`（发布整理任务到 `quartermaster` 命名空间）e2e 全绿——这是「军需官角色自治化」的最后一块拼图。

### EP-01d · 热重载自动化（顺手项）

- 规则文件本身纳入被监听面：`modify` on `.mcp-watch.json` → 防抖 → `reload_config`（复用 EP-01a 的 internal 通道），实现「不停机热更新」的产品承诺。

## 三、上游依赖

- 加密转正：等 `rx-mbt/PLAN-2026-11-18-gap-audit.md` R1（native AES-GCM）。
- EP-01c 的首测对端：fist-mbt 军需官角色（见 fist-mbt `docs/plans/2026-11-18-quartermaster-role-plan.md`）。
