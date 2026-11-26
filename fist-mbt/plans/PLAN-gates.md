# PLAN · 双门禁（守卫门 + 验收门）— schema v1.1 增量提案（2026-11-19）

> - 日期：2026-11-19
> - 状态：计划（owner 2026-11-19 指令落盘，交由 AtomCode 统帅任务以 fist-mbt 流程实现）
> - 定位：强化「产物生命周期语义而非裸命令」支柱——动作准入（前）+ 产物有效性（后）双门禁。
>   纯增量字段，schema v1.0 规则完全兼容；排在 EP-01（mcp_tool_call/webhook/internal）之前实施。

## 一、验收门（acceptance，先做——堵「假绿」）

### 动机
`run_command_action` 现行成败判定仅 `exit_code == 0`（action/action.mbt），stdout/stderr 捕获但只存不查，
exit 0 但产出无效即假绿放行。fist-mbt 账本 BUG-143 同族教训。

### schema v1.1 增量（ActionSpec 可选字段）

```json
{
  "type": "command",
  "cmd": "agent-cli",
  "args": ["--run"],
  "acceptance": {
    "expect_exit": 0,
    "stdout_contains": ["DONE"],
    "stdout_not_contains": ["ERROR", "Traceback"],
    "stderr_not_contains": ["panic"],
    "artifact_glob": "output/*.json"
  }
}
```

### 语义与验收

| 字段 | 类型 | 缺省 | 判定 |
|------|------|------|------|
| `expect_exit` | int | 0 | exit_code == expect_exit |
| `stdout_contains` | array\<string\> | [] | stdout 包含每一项（AND） |
| `stdout_not_contains` | array\<string\> | [] | stdout 不含任何一项 |
| `stderr_not_contains` | array\<string\> | [] | stderr 不含任何一项 |
| `artifact_glob` | string | 无 | 相对 watch_dir 下 glob 至少命中 1 个文件 |

- 验收不过 ⇒ `ActionOutcome.accepted=false`（保留真实 exit_code 与输出原文），并触发
  `product.invalid` 生命周期事件 → 进入既有 TTL/trash 回收流，**不做自动重试**（重试留给上层，如 fist-mbt saga）。
- 验收用例（最少集）：
  1. exit 0 + stdout_contains 命中 → accepted=true；
  2. exit 0 + stdout_not_contains 命中 → accepted=false 且 product.invalid 事件在位；
  3. exit 0 + artifact_glob 无命中 → accepted=false；
  4. 无 acceptance 字段 → 行为与 v1.0 完全一致（向后兼容锁）；
  5. `validate` 子命令对未知 acceptance 字段报 schema 错（fail-closed）。

## 二、守卫门（guard，后做——执行前环境准入）

### schema v1.1 增量（Rule 可选字段）

```json
{
  "id": "agent-run",
  "guard": { "argv": ["test", "-z", "{{workdir}}/.agent.lock"], "on_fail": "skip" },
  "actions": [{ "type": "command", "cmd": "agent-cli", "args": ["--run"] }]
}
```

### 语义与验收

- guard 是一条**必须 exit 0** 的命令（复用 `run_command` + ExecPolicy 白名单，argv 同样进白名单校验）；
  通过才执行 actions，不通过按 `on_fail`（`skip` 记事件跳过 / `stop` 记事件并停止本规则后续处理）。
- 变量占位符沿用 schema §7（`{{workdir}}` 等）。
- **不做组合逻辑**：需要 AND/OR 的守卫用条件层组合，guard 保持单命令——防止长成规则里套规则的策略引擎。
- 验收用例（最少集）：
  1. guard exit 0 → actions 正常执行；
  2. guard 非 0 + on_fail=skip → actions 零执行、guard_fail 事件在位；
  3. guard 程序不在 allowed_programs → 加载期警告 + 运行期拒绝（与 command 同策略）；
  4. 无 guard 字段 → v1.0 行为不变（向后兼容锁）。

## 三、实施顺序与红线

1. **acceptance** → 2. **guard** → 3. **EP-01**（既有 PLAN-ep01-actions.md 顺位不变）。
4. 红线：门禁检查全部为纯函数（字符串包含 + glob 存在性），零新依赖；不引入重试循环、不引入策略引擎。
5. 文档面：`workbuddy/plan/config-schema.md` 升 v1.1 并登记字段；README 四大支柱补「双门禁」一节。
6. 全量验证：`moon check` + 既有测试无回归 + 新增用例全绿 + `validate` CLI 对新字段正反两向对拍。

## 四、下游协同（非阻塞备忘）

- 守卫门 ↔ fist-mbt `audit_execute_gate`（执行前拦截）、验收门 ↔ Omega 强验证（执行后判定）语义同族；
  EP-01c 打通后，门禁结果可作为 FIST 派单验收证据直连军需官闭环。
- 加密动作转正仍等 rx-mbt R1（native AES-GCM），与本计划互不阻塞。
