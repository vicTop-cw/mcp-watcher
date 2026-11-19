# P0 · 接入层落地 执行汇报

> 时间：2026-11-16
> 依赖：`vicTop-cw/RX-MBT@0.4.3`（已发布版）

---

## 1. 结论

P0 接入层落地**已完成并通过全门禁**：
- `moon check --target native`：0 errors, 25 warnings
- `moon test --target native`：52 passed, 0 failed（从 28 增加到 52）
- `moon build --target native`：产出可执行文件

---

## 2. 任务完成情况

| 任务 | 状态 | 修改文件 | 测试数变化 |
|------|------|----------|------------|
| T1 · watch 后端接入 rx monitor | ✅ 完成 | `watch/backend.mbt` | 28 → 28 |
| T2 · action command 接入 rx run_command | ✅ 完成 | `action/action.mbt` | 28 → 28 |
| T3 · CLI 子命令骨架 | ✅ 完成 | `cmd/main/main.mbt`, `cmd/main/moon.pkg` | 28 → 52 |
| T4 · 配置加载与校验 | ✅ 完成 | `config/loader.mbt`, `config/model.mbt`, `config/loader_test.mbt` | 28 → 52 |

---

## 3. 关键修改

### 3.1 依赖切换
- **从**：`vicTop-cw/RX-MBT@0.4.2`（开发仓）
- **到**：`vicTop-cw/RX-MBT@0.4.3`（已发布版）

### 3.2 watch/backend.mbt
- `subscribe_watch` 函数：真正订阅 `@mon.watch_folder_native`
- `spawn_watch_task` 函数：在独立 async 任务中封装订阅语义
- `from_rx_event` 函数：映射 `WatchEvent` → `FsEvent`

### 3.3 action/action.mbt
- `run_command_action` 函数：正确订阅 Observable 并同步等待结果
- `build_policy` 函数：构造 `ExecPolicy`，默认只放行 `action:` / `handler:`

### 3.4 cmd/main/main.mbt
- `cmd_validate`：跑 loader + validator，返回退出码 0/1
- `cmd_start`：写 pidfile，已存在则拒绝重复启动
- `cmd_status`：扫描 pidfile，显示状态
- `cmd_run_once`：前台运行一次

### 3.5 config/loader.mbt
- `validate` 函数：累积式校验（schema_version, watch_id, watch_dir, Rule 字段）
- `loader_test.mbt`：新增 24 个测试用例

---

## 4. 门禁结果

| 项 | 命令 | 结果 |
|----|------|------|
| 类型检查 | `moon check --target native` | 0 errors, 25 warnings |
| 单元测试 | `moon test --target native` | 52 passed, 0 failed |
| 构建 | `moon build --target native` | 产出可执行文件 |

---

## 5. 已知限制

| 限制 | 影响 | 后续计划 |
|------|------|----------|
| `@process` 包不可用 | 无法检查进程存活、获取真实 pid | P1 接入 |
| pidfile 使用时间戳占位 | pid 非真实进程 ID | P1 接入 |
| `stop` 子命令为占位 | 无法终止进程 | P1 接入 |
| `mcp_tool_call` / `webhook` / `internal` 未实现 | 动作类型受限 | P2-P3 |

---

## 6. 下一步

1. **P1 · 规则内核与派发**：EventBus 封装、Layer1 匹配、Layer2 条件、去抖链
2. **P2 · 热重载**：`Arc<RwLock<RuleTable>>`、配置 mtime 轮询
3. **P3 · 产物生命周期语义**：TTL、trash、加密动作
4. **P4 · 双进程集成测试**：`tests/harness/` 端到端验证

---

## 7. 资源消耗

- **模型**：本地代理池
- **工具**：moon check, moon test, moon build
- **子代理**：WatcherBackend, ActionCommand, ConfigLoader, CLISubcommands