# mcp-watcher · AI 工作区自治运行时

> 一句话定位：**让 AI 工作区自己照顾自己，而不占用你和 Agent 的每一轮对话。**

mcp-watcher 不是一个"通用的文件监控触发器"。它是面向 AI 工作区的**自治运行时（Autonomous Runtime）**：你（或 AI 自己）用一份声明式规则描述"当什么发生，做什么"，它就在后台常驻、沉默地执行，并在规则改变时不停机热更新。

---

## 为什么不是"通用文件触发器"

通用文件触发器只回答"文件变了 → 跑命令"。而 AI 工作区的真实诉求是**产物的生命周期治理**——临时文件何时清理、敏感产物如何加密、过期文件如何进回收站、Agent 跑出的中间产物如何被安全回收。mcp-watcher 把"事件"当作触发器，把"动作"当作**生命周期语义**而非裸命令。

---

## 四大产品支柱

### 1. 后台常驻、沉默自治（不占用 Agent 的一轮对话）
- 作为独立进程后台运行，启动后与你的对话 / Agent 完全解耦。
- Agent 不必为了"等一个文件生成"而空转一轮对话；规则在守护进程里自行完成。
- 通过 `status` 可观测、`stop` 可终止，但**默认不打扰**。

### 2. 声明式规则系统（非程序员能写、AI 能自己写）
- 规则是 JSON DSL：事件 + glob + 条件 + 动作，可读、可审查、可版本化（见 `workbuddy/plan/config-schema.md`）。
- 非程序员照例能写；AI 在运行期也能**自己生成并热加载**规则（例如"把 >10MB 的日志压缩归档"）。
- 不是脚本、不是 cron 行——是一份机器与人类可共同维护的"工作区宪法"。

### 3. 热重载（规则变了不停机）
- 规则文件变更后，守护进程在**不重启、不丢状态**的前提下加载新规则表（设计见 `workbuddy/plan/design-spec.md` 热重载章节）。
- 新规则立即生效、旧规则平滑退出，保证自治不中断。

### 4. 产物生命周期语义（不是泛泛的"跑命令"）
动作（action）是**有语义的**，而非裸 shell。当前实现状态（诚实标注）：

| 能力 | 状态 | 说明 |
|------|------|------|
| **TTL** | ✅ 已落地 | 产物注册追踪表（可持久化）；到期判定 + `product.expired` 生命周期事件 + 追踪表移除 |
| **trash**（回收站） | ✅ native 已做实 / 🚧 其他目标降级 | native 用 `moonbitlang/async/fs` 的 `mkdir`/`rename` 真实移入 `<watch_dir>/.trash/<name>.<ts>`（零新增 C FFI）；js/wasm 无此 API，诚实返回"不支持" |
| **加密** | 🚧 明确降级（不可做实） | rx 的 Fernet 原语是 `extern "js"`（node:crypto），native/wasm 加密返回空串；本项返回可诊断 Err，**绝不写空密文破坏产物**，待 rx 补 native crypto FFI |
| command | ✅ 已落地 | argv 数组执行，ExecPolicy **显式白名单**（规则不会自动放行命令）；拒绝事件现已落结果记录、可 e2e 对拍 |
| mcp_tool_call / webhook / internal | 🚧 扩展位 EP-01 | 返回可诊断错误 |

> 设计取舍详见 `workbuddy/plan/p3-feasibility.md`（历史定位）。trash 后续发现
> `moonbitlang/async@0.22.9`（rx 0.4.4 传递依赖）在 native 提供 `mkdir`/`rename` C stub，
> 实测可做实，故由"规划中"升级为"native 已做实"；加密因底层依赖 node:crypto
> 无法在 native 做实，维持诚实降级。两条路径均以实测为准，不把 no-op 包装成已实现。

#### 双门禁（schema v1.1 · PLAN-gates.md）

支柱 4 的强化：**动作准入（前）+ 产物有效性（后）**。全部纯函数判定、零新依赖、
不引入重试循环；v1.0 规则（无这两个字段）行为逐位不变。

| 门禁 | 位置 | 判定 | 失败处置 |
|------|------|------|----------|
| **guard**（守卫门） | 动作执行前 | 单命令必须 exit 0（argv 与 command 同走白名单校验，绝不走 shell） | `on_fail=skip`：记 `guard_fail` 事件跳过本次动作（规则存活）；`on_fail=stop`：记事件并停止本规则后续处理 |
| **acceptance**（验收门） | 动作执行后 | `expect_exit` / `stdout_contains`(AND) / `stdout_not_contains` / `stderr_not_contains` / `artifact_glob`（相对 watch_dir 至少命中 1 文件） | `accepted=false`（保留真实 exit 与输出原文），触发 `product.invalid` 进入既有 TTL/trash 回收流，**不做自动重试**（重试留给上层） |

红线：guard 不做组合逻辑（需要 AND/OR 的守卫用条件层组合），防止长成规则里
套规则的策略引擎。字段契约见 `workbuddy/plan/config-schema.md` §5.1 / §5.2。

---

## 自治闭环

```
   声明式规则 (.mcp-watch.json)
            │
            ▼
   ┌──────────────────┐
   │  watch 后端        │  inotify / FSEvents / ReadDirectoryChangesW
   └────────┬─────────┘
            ▼
   ┌──────────────────┐
   │  rule 两层匹配     │  事件类型 + glob → exclude 优先 → 条件(AND)
   └────────┬─────────┘
            ▼
   ┌──────────────────┐
   │  action 生命周期   │  TTL✅ / trash(native✅) / 加密🚧 / command✅ / mcp🚧 / webhook🚧
   └──────────────────┘
            │
            ▼
      自治结果（落盘 / 回写 / 通知），全程无需 Agent 介入
```

---

## 架构（脚手架，详见 `fist-mbt/plans/`）

| 包 | 职责 |
|----|------|
| `config`    | 规则 DSL 模型 + JSON 解析 + 累积式校验 |
| `watch`     | 文件系统事件源（后端扩展点 EP-01） |
| `rule`      | 两层匹配算法（事件+glob、exclude 优先、条件 AND） |
| `action`    | 生命周期动作（TTL✅ / trash native✅·其他🚧 / 加密🚧 / command✅…）扩展点 EP-01 |
| `ext`       | 扩展位注册表（EP-01~EP-12） |
| `cron`      | cron 表达式解析与下次触发计算（纯逻辑、可测） |
| `scheduler` | 事件源 + cron 合并的主循环（已接入 rx EventBus；含 guard/acceptance 双门禁与热重载接线） |
| `cmd/main`  | CLI 入口（validate/start/status/run/reload/help；stop 为 P1） |

> 实现期将复用兄弟项目 **rx-mbt**（响应式内核：EventBus / 真实时钟 / 原生监控 / 命令 Observable），详见 `rx-mbt/PLAN-mcp-watcher-apis.md`。

---

## 当前状态

- ✅ 产品定位与四大支柱（本文）
- ✅ 详细设计决议 `workbuddy/plan/design-spec.md`、配置契约 `config-schema.md`、rx 依赖决策 `rx-mbt-dependency.md`、复用与测试规划 `reuse-and-test-plan.md`
- ✅ **项目架构已落地**（本仓库包结构与核心类型）：`config`/`watch`/`rule`/`action`/`ext`/`cron`/`scheduler`/`cmd/main` 八个包 + `moon.mod`；提案与执行汇报见 `fist-mbt/plans/`、`fist-mbt/reports/`
  - 门禁（2026-11-20 实测）：`moon check` 0 errors（36 条 Warning）；`moon test --target native` **222/222**；`moon test --target js` **191/191**；wasm-gc 编译失败（RX-MBT fs_* 未绑定，依赖侧缺口）；双进程 e2e 存在守护进程监控缺陷（见 `USAGE.md` §6.1），事件可达性已由 RX-MBT 探针证明。
- ✅ 已完成：接入 rx-mbt 0.4.4（R1~R4）、CLI 子命令（validate/start/status/run/reload）、TTL 生命周期动作、trash 物理回收（native）、command + ExecPolicy 白名单、双门禁 guard/acceptance（schema v1.1）、热重载（EP-01d）、internal 动作四 op（EP-01a）、双进程集成测试物料（`tests/harness/`）
- 🚧 规划中：加密（rx 无 native Fernet，见 `workbuddy/plan/p3-feasibility.md`）、mcp_tool_call/webhook 扩展位（EP-01）、守护进程监控缺陷修复（P1）、CLI stop 子命令（P1）

---

## 快速开始

```bash
moon build --target native

# 产物：_build/native/debug/build/cmd/main/main.exe
./_build/native/debug/build/cmd/main/main.exe validate --rules .mcp-watch.json      # 校验规则
./_build/native/debug/build/cmd/main/main.exe run --rules .mcp-watch.json --watch-dir .   # 后台自治运行
./_build/native/debug/build/cmd/main/main.exe status --rules .mcp-watch.json --watch-dir .   # 观测
./_build/native/debug/build/cmd/main/main.exe reload --rules .mcp-watch.json        # 热重载
```

> 完整使用说明（规则文件写法、字段说明、双门禁配置、FAQ）见 `USAGE.md`。
> 已知限制：`stop` 子命令待实现（P1）；规则文件目录不在 `watch_dir` 内时 `run` 存在监控缺陷（见 `USAGE.md` §6.1）。

---

## 设计文档索引

- `workbuddy/plan/design-spec.md` — 总体设计决议
- `workbuddy/plan/config-schema.md` — 配置契约
- `workbuddy/plan/rx-mbt-dependency.md` — 依赖决策
- `workbuddy/plan/reuse-and-test-plan.md` — 复用与测试规划
- `rx-mbt/PLAN-mcp-watcher-apis.md` — rx 增资计划
- `tests/harness/README.md` — 双进程集成测试物料
- `fist-mbt/plans/2026-11-12-architecture-proposal.md` — 本项目架构提案（FIST）
- `competition/项目申报书.md` — 项目申报材料（验收读数见申报书 §11）

## 使用文档

- `USAGE.md` — 安装构建 / 规则编写 / CLI 用法 / 双门禁配置 / 常见问题
