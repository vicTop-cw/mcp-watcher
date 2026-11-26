---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: 9f2a11add43fbf12a546606fb2b962ab_d0653624e61811f1a9b8525400f8a581
    ReservedCode1: i24tYW6N4GDzFoViKXmQLtJgKgtE+/RzfwU1WoGI1o8O/8Z0Vfb+0TRAjdO4I9bHl4m3LaCFW6x+jpjIsC2b0eVqbK+3W+zx9eigQpJdOzweERpe7bL1qjVvPrgoVF5TtT7Vi8wIBHcJhQtK+1S1mHkkOafN1BTKqxk3hLAKSk7jdz/Zzzzv09zUX1o=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: 9f2a11add43fbf12a546606fb2b962ab_d0653624e61811f1a9b8525400f8a581
    ReservedCode2: i24tYW6N4GDzFoViKXmQLtJgKgtE+/RzfwU1WoGI1o8O/8Z0Vfb+0TRAjdO4I9bHl4m3LaCFW6x+jpjIsC2b0eVqbK+3W+zx9eigQpJdOzweERpe7bL1qjVvPrgoVF5TtT7Vi8wIBHcJhQtK+1S1mHkkOafN1BTKqxk3hLAKSk7jdz/Zzzzv09zUX1o=
---


# mcp-watcher 索引/检索功能设计计划稿（vector-index-design）

> 状态：计划稿（plan，未实施） · 落盘：`workbuddy/plan/vector-index-design.md`
> 日期：2026-11-22 · 目标版本：0.2.1 之后的索引能力增量
> 体例依据：`design-spec.md` / `config-schema.md`（字段表、决议标记、章节编号风格一致）

---



---


## 0. 范围与原则

> 本文件是 mcp-watcher「索引/检索功能」的**设计计划稿**（plan，非实现）。
> 承诺：只产出设计与排期，不改任何源码；实施需经用户确认后按 §7 分期执行。
> 体例对齐：`design-spec.md`（总体决议）与 `config-schema.md`（配置契约）。

**【决议】** 本文档为索引/检索功能的权威设计计划；与既有 plan 文档的关系：

| 文档 | 状态 | 说明 |
|------|------|------|
| `design-spec.md` | 有效 | 总体决议；本文在其「扩展位」体系内新增索引能力 |
| `config-schema.md` | 有效 | 配置契约；§4 在其 v1.1 基础上扩展 `index` 段，逐位不变 |
| `development-plan.md` | 有效 | 既有分期（P0~P4 规则引擎）；本文分期与其正交、可并行 |
| `rx-mbt-dependency.md` | 参考 | §2 缺陷修复涉及 rx 侧改动，需联动评估 |

**范围边界（不做什么）**：

1. **不读文件内容**：索引仅采集文件夹与文件的元数据（路径、大小、时间戳、类型等），不做正文解析、不做内容摘要。
2. **不动既有规则引擎语义**：`rules` / `actions` / `guard` / `acceptance` 的 v1.0 / v1.1 行为逐位不变；索引为新增正交能力。
3. **不改既有 CLI 语义**：`start / stop / status / run / validate / reload / help` 保持现状，仅新增 `search` 子命令（§6）。
4. **不引入运行期轮询**：与 design-spec 一致，索引更新复用事件流（增量），全量 walk 仅发生在启动建库阶段。

**术语约定**：

| 术语 | 含义 |
|------|------|
| 元数据索引 | 只含文件夹/文件的属性信息，不含正文内容 |
| 全量 walk | 服务启动时递归扫描 watch_dir，一次性构建索引库 |
| 增量管线 | 订阅既有事件流，把 create/modify/delete/rename 同步进索引库 |
| 防自噬 | 索引库自身及其临时文件不得被索引/被排除规则误扫 |
| FTS5 | SQLite 全文检索虚拟表，用于文件名/路径分词倒排 |



---


## 1. 背景与目标

### 1.1 背景

mcp-watcher 当前的能力是「事件 → 规则 → 动作」：监控目录变化并执行声明式动作。它**不回答查询问题**——当 AI（或人类）需要了解"这个项目目录里有哪些文件、它们的层级关系、最近改了什么"时，没有可复用的检索入口。

目标场景：

- AI 助手要回答"mcp-watcher 项目下有哪些 `.mbt` 文件？"——需要按扩展名/路径过滤。
- AI 助手要回答"最近 24 小时改了哪些文件？"——需要按 mtime 过滤。
- AI 助手要回答"路径里包含 `plan` 的文件有哪些？"——需要按路径分词全文检索。

这些查询的共同特征是：**只依赖元数据，不依赖正文内容**。因此可以建立一份"元数据索引"数据库，随文件系统变动实时维护，成为 AI 检索的统一入口。

### 1.2 目标

**【决议】** 为 mcp-watcher 新增索引/检索能力，目标定义如下：

| 目标 | 量化口径 | 验收参照 |
|------|----------|----------|
| 元数据索引 | 覆盖 watch_dir 下全部文件夹与文件（排除规则除外），不读内容 | §5 全量 walk 建库测试 |
| 实时更新 | 文件 create/modify/delete/rename 后，索引库随事件流同步（去抖语义与规则引擎一致） | §5 增量管线测试 |
| 可检索 | 支持关键词（FTS5）+ 过滤条件（type/ext/size/time）+ 结构化输出 | §6 CLI search 测试 |
| 可扩展向量 | 元数据表预留 embedding 列，P1 启用向量召回 | §3.3 / §7 P1 |
| 不破坏既有行为 | v1.0/v1.1 规则行为逐位不变、向后兼容 | §4 / §7 门禁 |

### 1.3 与既有事件流的关系（复用点）

索引更新的实时性**复用 mcp-watcher 既有事件流**，不另起监控：

| 既有组件 | 复用方式 |
|----------|----------|
| `watch/backend.mbt` 的 `spawn_watch_task` | 索引增量管线在同一 `@async.with_task_group` 内再订阅一份总线事件（或复用同一 `bus` 的旁路订阅） |
| `@rx.EventBus[FsEvent]` 事件命名 `<event_type>.*` | 增量管线按事件类型分流：create→insert、modify→update、delete→delete、rename→迁移 |
| 去抖链 `debounce_real` | 索引更新与规则派发共用同一事件流，去抖语义一致 |
| `Config` / `Config::from_json` | 新增 `index` 段（§4），随配置热重载校验 |

> 注意：索引更新属于「旁路消费」，不改变事件在规则引擎中的语义；若规则引擎因 `stop-after` 提前退出，索引同步不受影响（二者正交）。

### 1.4 非目标（明确排除）

- 不做正文全文索引（PDF/DOCX 等内容的倒排不属本次范围）。
- 不做自然语言语义搜索（P1 之前的 P0 仅关键词/过滤）。
- 不做跨机器分布式索引（单机 SQLite 库）。



---


## 2. 前置缺陷修复（实时性地基）

### 2.1 缺陷现象与根因

**现象**：当规则文件（`.mcp-watch.json`）位于 `cfg.watch_dir` 之外时，`run_daemon` 会补第二个监控任务（`cmd/main/main.mbt` L373-391，`rules_file_dir` 不在 `dir_covers` 范围内时补监控）；双目录探针实测：**仅先启动的目录事件到达，另一目录事件零到达**，即第二个 watch 永不获得调度，导致其目录的事件无人监听。

**根因**：rx `watch_folder_native` 的轮询循环使用**线程级 `Sleep()`**（`moonbit_sleep_ms`，`fs_native_stubs.c`）。MoonBit 协作式 async 单线程下，**首个被调度的 watch 订阅任务永久独占执行线程**——线程级阻塞不会让出事件循环，后续 watch 任务（包括补监控的第二个 watch）永远得不到调度。

**规避现状**：规则文件放 watch_dir 内可绕过（无第二 watch）；但这只是规避，一旦配置合法地指向外部规则文件，实时性即失效。

### 2.2 可选修复方案与取舍

| 方案 | 做法 | 优点 | 缺点 | 归属 |
|------|------|------|------|------|
| **A：async 级 sleep** | 把 rx native watcher 轮询循环中的线程级 `Sleep()` 改为 async 级等待（`@async` sleep，让出事件循环），使多个 watch 订阅任务可并发调度 | 根治：任意数量 watch 均可并行；对上层透明 | 需改 rx 依赖侧（RX-MBT）；依赖升级与回归测试成本 | rx 侧（依赖） |
| **B：单监控任务合并** | 本项目内不再 spawn 第二个 watch：若规则文件目录不在 watch_dir 内，把规则文件目录**并入主监控**（一个 watch 任务覆盖多个根目录，事件进同一 bus 由路径匹配过滤） | 本项目内可自主闭环，不依赖 rx 升级；立即修复 | 监控根从单一 watch_dir 变为多根集合，需在 `subscribe_watch` / 事件过滤层支持多根；语义上"第二根目录"事件与 watch_dir 事件同流 | 本项目 |

**取舍结论（P0）**：优先落地**方案 B**——改动面在本项目、可独立验收、不阻塞索引功能；方案 A 作为 rx 侧根治选项**并行评估**（若 rx 发布支持 async sleep 的版本，则切换为单 watch 语义 + rx 原生多 watch，方案 B 的多根合并逻辑仍可作为兼容层保留）。

### 2.3 验收方式

修复验收（双目录探针）：

1. 构造规则文件位于 watch_dir 之外的配置（目录 A 为 watch_dir，目录 B 为规则文件所在目录）。
2. 分别在 A、B 创建事件文件。
3. 断言：A、B 两目录的事件均进入 `bus` 并被记录（results/索引均可观测），且 `moon check` 0 errors、native/js 测试全绿。

新增测试用例（`tests/`）：

- `multi-root-watch`：双根目录事件均到达（原生 harness 双进程复刻）。
- 回归：`p0-smoke` / `basic` 场景不因缺陷修复行为改变而失败。



---


## 3. index 包架构

### 3.1 包划分与依赖

新增 `index` 包（`index/moon.pkg.json`），依赖 `@sqlite`（SQLite FFI 封装，native 目标；js 目标走 sql.js 封装或 P0 保持 native 优先）。包内模块：

| 模块 | 职责 |
|------|------|
| `index/db.mbt` | SQLite 连接管理、建库、事务封装 |
| `index/schema.mbt` | 建表 DDL、FTS5 虚拟表、索引、迁移版本 |
| `index/walk.mbt` | 全量 walk 建库（含断点/增量校验，见 §5） |
| `index/upsert.mbt` | 事件增量：insert / update / delete / rename |
| `index/query.mbt` | FTS5 关键词检索 + 过滤条件组合 |
| `index/exclude.mbt` | 排除规则（目录/扩展名/自身防自噬） |
| `index/embed.mbt` | embedding 列读写接口（P1 扩展位，P0 仅占位） |

### 3.2 SQLite 元数据表（核心表 `fs_nodes`）

**【决议】** 单表承载全部元数据，主键为绝对路径（规范化，Windows 反斜杠转 `/` 统一）：

| 字段 | 类型 | 必填 | 默认 | 约束 |
|------|------|------|------|------|
| `path` | TEXT | 是 | — | 主键；规范化绝对路径（/ 分隔） |
| `rel_path` | TEXT | 是 | — | 相对 watch_dir 的路径；watch_dir 自身为 "." |
| `parent` | TEXT | 是 | — | 父目录 path；根目录的父为 NULL |
| `depth` | INTEGER | 是 | — | 根=0，逐层 +1 |
| `type` | TEXT | 是 | — | "file" \| "dir" |
| `size` | INTEGER | 否 | 0 | 文件字节数；dir 恒 0 |
| `mtime` | INTEGER | 否 | 0 | Unix 时间戳（秒） |
| `ctime` | INTEGER | 否 | 0 | Unix 时间戳（秒）；变更时间 |
| `ext` | TEXT | 否 | "" | 小写扩展名（不含点）；dir 恒 "" |
| `embedding` | BLOB | 否 | NULL | **P1 扩展位**：向量字节流；P0 恒 NULL |

配套索引：

- `idx_parent` ON `parent`
- `idx_type_ext` ON `type, ext`
- `idx_mtime` ON `mtime`（时间范围过滤）

层级元数据（parent / depth / rel_path）在 insert 与 rename 时**同事务维护**（见 §3.5），保证 `parent` 始终指向已存在的目录节点；目录节点删除时级联处理（§5.3）。

### 3.3 FTS5 倒排（文件名/路径分词）

**【决议】** 使用 SQLite FTS5 虚拟表 `fs_fts`，对**文件名与路径**分词（不含正文）：

```sql
CREATE VIRTUAL TABLE fs_fts USING fts5(
  path,          -- 规范化绝对路径
  name,          -- 末段文件名/目录名
  rel_path,      -- 相对路径
  content='fs_nodes', content_rowid='rowid'
);
-- rowid 需在 fs_nodes 中以 INTEGER PRIMARY KEY 形式提供
```

- **分词**：FTS5 默认 unicode61 分词器；路径以 `/` 分隔天然成词，文件名按非字母数字切分。对中文路径，P0 提供 `tokenize = 'unicode61 remove_diacritics 0'` 并补充 `path LIKE` 回退（FTS5 对 CJK 分词的局限以 LIKE 兜底，见 §6.2）。
- **一致性**：`fs_fts` 采用 external-content 模式，由 `fs_nodes` 触发器同步（`fs_nodes_ai / fs_nodes_ad / fs_nodes_au`），与元数据同事务。
- **查询入口**：关键词命中路径/文件名即返回对应 `rowid`，再 join `fs_nodes` 取完整元数据。

### 3.4 排除表与防自噬

**【决议】** 排除规则（`exclude` 配置，§4.2）+ 内置排除默认项，防自噬为**硬编码最高优先级**：

| 层级 | 规则 | 说明 |
|------|------|------|
| 内置硬编码 | `.trash` / `.git` / `node_modules` / `temp`（目录名精确匹配） | 默认跳过，不可被配置覆盖（安全底线） |
| 索引库自身 | `db_path` 指向的 SQLite 文件及其 `-wal` / `-shm` 伴生文件 | **防自噬**：索引库不得索引自己；walk 与增量均显式排除 |
| 配置 exclude | 用户 glob（可含 `**`） | 附加排除；与内置取并集 |

防自噬双保险：

1. **walk 层**：遍历时若路径 == db_path（或 db_path 前缀匹配）直接跳过。
2. **增量层**：事件路径命中 db_path 时丢弃（不写库）；即使事件系统把索引库自身改动投递进来也不产生递归写。

### 3.5 rename 原子迁移（同事务）

文件/目录 rename 事件在增量管线中映射为「删除旧路径 + 插入新路径」；为保持层级一致与 FTS 同步，**必须单事务完成**：

```sql
BEGIN;
-- 1) 更新自身路径（目录则级联更新其子节点 rel_path/parent/depth）
UPDATE fs_nodes
   SET path = substr(new_path || substr(path, length(old_path) + 1), 1, ...),
       rel_path = ...,
       parent = ...,
       depth = ...
 WHERE path = old_path OR path LIKE old_path || '/%';
-- 2) 外部内容表触发器自动同步 fs_fts
-- 3) 同事务内删除旧路径残留（若新路径已存在则先清理，见下）
COMMIT;
```

要点：

- **目录 rename**：`LIKE old_path || '/%'` 级联子节点；`depth` 差量调整（new_depth - old_depth 的常量差）。
- **冲突处理**：新路径已存在时，事务内先删除目标节点（及子节点）再迁移；冲突删除本身也会触发 FTS 同步，全在事务内原子完成。
- **失败回滚**：任一语句失败 → 整体 ROLLBACK，索引保持 rename 前状态，事件不丢失（错误计数上报，§5.4）。



---


## 4. 配置扩展（.mcp-watch.json 新增 index 段）

### 4.1 index 段字段契约

**【决议】** 顶层新增可选对象 `index`（缺省 = 不启用，完全等价于当前行为）：

| 字段 | 类型 | 必填 | 默认 | 约束 |
|------|------|------|------|------|
| `enabled` | boolean | 否 | `false` | `false` 时其余字段忽略，行为与无 index 段一致 |
| `db_path` | string | 否 | `"<watch_dir>/.mcp-watch-index.db"` | SQLite 库绝对路径；不得指向系统/受保护目录；见防自噬 |
| `include` | array\<string\> | 否 | `[]`（全部） | glob 白名单；空 = 不限 |
| `exclude` | array\<string\> | 否 | `[]` | glob 黑名单；与内置排除取并集 |
| `embed` | object | 否 | `{}` | **P1 扩展位**：`{ "enabled": false, "model": "" }`；P0 仅解析不生效 |

示例（启用索引、排除 build 产物、预留 embed）：

```json
{
  "schema_version": 1,
  "watch_id": "demo",
  "watch_dir": "E:/workspace/demo",
  "rules": [],
  "index": {
    "enabled": true,
    "db_path": "E:/workspace/demo/.index/mcp-watch.db",
    "exclude": ["build/**", "dist/**"],
    "embed": { "enabled": false, "model": "" }
  }
}
```

校验（fail-closed 保持）：

- `enabled` 非布尔、`db_path` 非字符串、`include/exclude` 非数组或元素非字符串、`embed` 非对象 → 配置校验失败，服务拒绝启动（与既有校验策略一致）。
- `db_path` 位于系统核心禁区（`C:\Windows` 等）→ 校验失败。
- `db_path` 落在 watch_dir 内 → 允许，但强制触发防自噬排除（§3.4）。

### 4.2 schema 版本升级策略（逐位不变、向后兼容）

**【决议】** **`schema_version` 保持 `1` 不变**，`index` 段作为 v1.1 显式声明的可选段加入，不升 v2。理由与规则：

1. **逐位不变红线**：v1.0 / v1.1 的所有既有字段（`watch_id` / `watch_dir` / `recursive` / `debounce_ms` / `rules` / `allowed_programs` / `extensions` / `logging` 及 Rule 全字段）**解析与行为不因 index 段存在而改变**；无 index 段的旧配置逐字节兼容。
2. **可选段语义**：`index` 缺省或 `enabled=false` 时，加载路径完全走既有逻辑（不初始化 SQLite、不产生额外文件）；`enabled=true` 才激活索引能力。
3. **未知键策略**：沿用既有 fail-closed——`index` 必须是显式声明且类型正确的键；未知/畸形键按既有规则报 schema 错误（不静默忽略）。
4. **未来升 v2**（如需要索引专属强约束时）：遵循既有 schema 演进约定，v2 解析器必须**接受 v1 配置**（仅当 v1 缺 index 段时给默认值），v1 解析器遇到 v2 的未知键走既有兼容策略；本计划稿不启动 v2 迁移。
5. **热重载**：`reload` 时 index 段变更按既有热重载语义处理——索引启用状态变更需重启生效（P0 明确：**index 配置变更不支持热切换**，避免运行中重建库的竞态；reload 时给出提示）。

### 4.3 配置与 CLI 联动

`index.enabled=true` 时，`start`/`run` 启动流程自动触发「启动建库 + 增量管线」（§5）；`status` 输出增加索引状态行（db_path / 节点数 / 最近同步时间 / 错误计数，P0 提供基础版）。



---


## 5. 启动建库与事件增量管线

### 5.1 启动即自动建库

`index.enabled=true` 时，服务启动流程（`run_daemon` / `start`）在事件监控启动**之前**完成建库，保证增量事件不丢失窗口：

1. 规范化 `watch_dir`、读取 `index` 段（enabled / db_path / include / exclude）。
2. 打开 SQLite（`db_path`；父目录不存在则创建，目录创建失败即校验失败）。
3. 执行建表 DDL（`fs_nodes` + `fs_fts` + 触发器 + 索引；`PRAGMA journal_mode=WAL`、`synchronous=NORMAL`，兼顾读写并发与性能）。
4. **全量 walk**（§5.2）→ 断点/增量校验（§5.3）。
5. 注册增量事件订阅（§5.4）。
6. 记录 `meta` 表（schema_version / walk 完成时间 / 最后同步事件序号），供 `status` 与断点续传使用。

失败策略：建库失败（SQLite 不可写、目录不可建）→ 记录诊断并**不阻塞规则引擎**（索引旁路降级：服务继续运行、`status` 显示 index=error）；这是"永不因配置错崩溃"原则在索引侧的延伸。

### 5.2 全量 walk 建库（含断点/增量校验）

walk 采用**显式栈**递归（避免深目录栈溢出），顺序：

- 目录：insert `type=dir` 节点 → 入栈子项；子项按 include/exclude 过滤（内置排除 + 配置 exclude + 防自噬）。
- 文件：`stat` 取 size/mtime/ctime → insert `type=file`。
- 层级元数据：parent/depth/rel_path 在 walk 时已知，随 insert 写入。

**断点续传**（大目录中断恢复）：

| 机制 | 说明 |
|------|------|
| `meta` 断点 | walk 按目录分批提交；每批结束后写 `meta.walk_state = last_dir` |
| 增量校验 | 已有库时（`fs_nodes` 非空），启动 walk 前先 `SELECT count(*)` 对比 `meta.walk_state`；若为"完成"态则跳过全量、直接进入增量（增量自举：以 mtime 段补扫；重建通过删除库文件后重启服务触发全量 walk） |
| 幂等 | insert 使用 `INSERT OR REPLACE`（按 path 主键），中断重跑不产生重复节点 |

### 5.3 事件增量管线

复用既有事件流：在 `run_daemon` 的 `@async.with_task_group` 内，索引模块以**旁路订阅**接入同一 `bus`（`subscribe_watch` 已把 `FsEvent` 投递到 bus），按事件类型分流：

| 事件类型 | 索引动作 | 说明 |
|----------|----------|------|
| `create` | `upsert(path)` | 若为目录且 recursive，需**子文件夹内嵌补扫**：插入目录节点后，walk 其子树（含层级元数据） |
| `modify` | `upsert(path)` | 重新 `stat` 更新 size/mtime/ctime；目录 modify 忽略 |
| `delete` | `delete(path)` | 删除节点；目录删除**级联**子节点（`path LIKE old || '/%'`，FTS 触发器同步） |
| `rename` | `rename(old, new)` | §3.5 单事务原子迁移（目录级联） |

**recursive 子文件夹内嵌与层级元数据**：

- 事件流对 recursive 子目录内新文件，native 侧会投递 create 事件；索引侧对 create 的目录节点做**子树补扫**（复用 walk 的目录遍历函数，以该目录为根），保证 parent/depth/rel_path 正确。
- 补扫同样遵守排除规则与防自噬。
- 目录 delete 级联删除子节点；后续对已删除子路径的迟到事件以 `INSERT OR REPLACE` 幂等处理。

### 5.4 同步可靠性

- **事务**：每个事件（或一批去抖合并事件）在一个事务内完成 upsert/delete/rename；失败 ROLLBACK，错误计数 +1 并记录诊断日志，不中断事件流。
- **错误计数**：`meta.error_count` 与最近错误文本，`status` 可查；超阈值（P0 默认 100）输出告警，提示删除库文件后重启服务。
- **顺序**：同一路径事件按到达顺序应用；rename 依赖 create 先行的场景由 `INSERT OR REPLACE` 幂等兜底。



---


## 6. CLI search 子命令

### 6.1 命令签名与参数

**【决议】** 新增子命令 `search`（只读查询，不修改任何文件）：

```
mcp-watch search <watch_dir> [--keyword <kw>] [--type file|dir]
             [--ext <ext>] [--min-size <bytes>] [--max-size <bytes>]
             [--mtime-after <ts>] [--mtime-before <ts>]
             [--limit <n>] [--format text|jsonl] [--db <path>]
```

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `watch_dir` | 位置参数 | 必填 | 定位配置与索引库（`<watch_dir>/.mcp-watch.json` → `index.db_path`） |
| `--keyword` | string | "" | FTS5 关键词；命中路径/文件名；空 = 全量过滤 |
| `--type` | string | "" | `file` / `dir`；空 = 不限 |
| `--ext` | string | "" | 扩展名过滤（小写，不含点；如 `mbt`） |
| `--min-size` / `--max-size` | int | 0 / 不限 | size 过滤（字节） |
| `--mtime-after` / `--mtime-before` | int | 0 / 不限 | mtime Unix 秒过滤 |
| `--limit` | int | 100 | 结果上限（防爆表） |
| `--format` | string | `text` | `text`（人类可读表格）/ `jsonl`（每行一个 JSON，供 AI/脚本） |
| `--db` | string | "" | 显式指定库路径；缺省从配置读取 |

### 6.2 查询逻辑

1. 读取配置 → 校验 `index.enabled`；未启用则报错退出（exit 2：「索引未启用，请在配置中开启 index.enabled 并启动服务」）。
2. 关键词检索：`--keyword` 非空 → 先走 FTS5：

```sql
SELECT rowid FROM fs_fts WHERE fs_fts MATCH ? ORDER BY rank;
```

- FTS5 命中后 join `fs_nodes` 取全字段；FTS5 对 CJK 分词不足时，**追加 `path LIKE '%<kw>%'` 兜底**（并集去重），保证中文路径可检索。
- `--keyword` 为空 → 直接基于 `fs_nodes` 过滤。

3. 过滤条件组合：全部条件 AND 追加：

```sql
WHERE type = ? AND ext = ? AND size BETWEEN ? AND ?
  AND mtime BETWEEN ? AND ?  -- 按传入条件拼接
ORDER BY path LIMIT ?;
```

4. 输出：`text` 以对齐表格打印（path / type / size / mtime / ext，截断超长路径）；`jsonl` 每行输出完整节点 JSON（含 rel_path/parent/depth，供 AI 直接消费）。

### 6.3 退出码与错误语义

| 码 | 含义 |
|----|------|
| 0 | 查询成功（可无命中） |
| 1 | 参数错误 / 配置校验失败 |
| 2 | 索引未启用 / 库不存在 / 库损坏 |

### 6.4 测试覆盖

- `search-keyword`：FTS5 命中、CJK 兜底命中。
- `search-filter`：type/ext/size/mtime 组合过滤。
- `search-format`：text / jsonl 输出契约断言。
- `search-exit`：未启用索引时 exit 2。



---


## 7. 分阶段实施计划

### 7.1 阶段总览与依赖

| 阶段 | 范围 | 依赖 | 验收门禁 |
|------|------|------|----------|
| **P0** | 修缺陷（方案 B）+ index 包（元数据表/FTS5/排除/rename）+ 启动建库 + 事件增量 + CLI search | 无（直接基于现有主干） | moon check 0 errors；native/js 测试全绿；双目录探针通过 |
| **P1** | embedding 列填充 + 向量召回（search --vector） | P0（列与读写接口已留） | moon check 0 errors；native/js 全绿；向量召回用例通过 |
| **P2** | MCP tool 暴露（`mcp_tool_call` 动作调用索引查询，供 AI） | P0/P1（查询入口稳定） | moon check 0 errors；native/js 全绿；MCP 集成用例通过 |

> 依赖原则：P1 只做 embedding 列写入与向量检索，不重构 P0 表结构；P2 只做暴露层，不新增查询语义。

### 7.2 P0 · 地基与基础检索（1~2 期）

| 任务 | 交付物 | 验收 |
|------|--------|------|
| 缺陷修复（方案 B） | 多根 watch 合并；`subscribe_watch` 支持多根 | 双目录探针：A/B 事件均到达；既有场景回归全绿 |
| `index` 包骨架 + SQLite 接入 | `db.mbt` / `schema.mbt`；建库 DDL | 建库单测：表/索引/FTS/触发器存在 |
| 全量 walk 建库 | `walk.mbt`；断点/增量校验；删除库文件后重启服务触发全量 | walk 单测：层级/排除/防自噬；断点续传用例 |
| 事件增量管线 | `upsert.mbt`；create/modify/delete/rename 分流 | 增量单测 + harness 双进程：改文件后库同步 |
| 排除与防自噬 | `exclude.mbt`；内置排除 + db_path 防自噬 | 防自噬用例：索引库文件不进入自身索引 |
| CLI search | `search` 子命令 + `query.mbt` | search 关键词/过滤/格式/退出码用例 |
| 门禁 | 全量测试 | moon check 0 errors；native/js 全绿；新增测试数 > 0 |

### 7.3 P1 · embedding 与向量召回（1~2 期）

| 任务 | 交付物 | 验收 |
|------|--------|------|
| embedding 列写入 | `embed.mbt` 实现：`embed(text)->BLOB` 接口 + 写入管线（P0 占位接口落地） | 列写入用例：路径/文件名向量可读写 |
| 向量召回 | `search --vector <vec>` 或 `--embed-text <text>`：KNN 召回（native 侧余弦/欧氏距离；量级小可线性扫描，量级大引入 SQLite 向量扩展评估） | 向量召回用例：top-K 顺序正确 |
| 配置 embed 段生效 | `embed.enabled=true` 时才计算/存储向量；否则列保持 NULL | 配置开关用例 |

> 说明：embedding 模型选择（本地哈希嵌入 / 预训练模型 / 外部 API）在 P1 开工时经用户确认后定稿；本计划稿仅锁定「列结构 + 接口 + 召回路径」。

### 7.4 P2 · MCP tool 暴露给 AI（1 期）

| 任务 | 交付物 | 验收 |
|------|--------|------|
| MCP tool 定义 | 注册索引查询为 MCP tool（`mcp-watcher_search`：输入 watch_dir/关键词/过滤 → 结构化 JSON 结果） | MCP 集成用例：AI 侧调用返回合法结果 |
| 权限与白名单 | 查询 tool 走既有 `allowed_programs` / 白名单约束，只读无副作用 | 安全用例：越权/写操作被拒 |

### 7.5 风险清单

| 风险 | 触发条件 | 影响 | 应对 |
|------|----------|------|------|
| wasm-gc 依赖缺口 | `moon test --target wasm-gc`（RX-MBT fs_* 值未绑定，现状 exit=1） | 三目标门禁无法全绿 | 维持既有说明：门禁以 native/js 为准，wasm-gc 缺口属依赖侧，**不在本计划修复**；index 包在 wasm-gc 目标以占位实现（无监控能力）编译通过即可 |
| 索引库自噬 | db_path 落在 watch_dir 内，事件/ walk 扫到库文件 | 索引库被自身索引 → 递归膨胀 | 硬编码防自噬排除（§3.4）+ 单测守护 |
| SQLite 依赖引入 | native 需 SQLite FFI、js 需 sql.js | 新依赖面 | P0 先 native 全量；js 目标 `index` 降级占位（`enabled=true` 报 Unsupported 或走 sql.js，P0 评估后定）；依赖锁定版本并纳入门禁 |
| rename 竞态 | 目录 rename 与子事件乱序到达 | 索引不一致 | 单事务 + 幂等 upsert + 错误计数提示重建 |
| 全量 walk 耗时 | 超大目录 | 启动慢 | 断点续传 + 分批事务 + 删库重启可控重跑 |
| index 配置热切换 | reload 变更 enabled/db_path | 运行中重建库竞态 | P0 明确 reload 不支持 index 热切换，提示重启生效（§4.3） |



---


## 8. 演进路线与门禁

### 8.1 演进路线

| 阶段 | 状态 | 交付要点 | 验收参照 |
|------|------|----------|----------|
| P0 | 计划 | 缺陷修复（方案 B）+ index 包 + 启动建库 + 增量管线 + CLI search | §7.2 |
| P1 | 计划 | embedding 列 + 向量召回 | §7.3 |
| P2 | 计划 | MCP tool 暴露给 AI | §7.4 |
| 后续（评估） | 未定 | wasm-gc 依赖缺口跟进、SQLite 向量扩展、index 热切换、跨机同步 | 视 rx 侧进展与用户决策 |

### 8.2 全局门禁（每阶段完成必须全绿）

| 门禁项 | 标准 |
|--------|------|
| `moon check` | **0 errors**（允许既有 36 warnings 基线不增加；新增代码不引入新 warning） |
| `moon test --target native` | 全绿（基线 222/222 + 新增用例） |
| `moon test --target js` | 全绿（基线 191/191 + 新增用例） |
| `moon test --target wasm-gc` | 维持现状说明（依赖侧缺口，不阻塞）；index 包在 wasm-gc 占位编译通过 |
| 代码风格 | `moon fmt` 仅格式化本批变更文件（禁止整仓全量格式化） |
| 测试新增 | 每阶段新增测试数 > 0（覆盖本阶段任务表验收列） |
| 契约 | 配置 schema 校验 / CLI 输出契约 / MCP 结果契约按 §4/§6/§7.4 断言 |

### 8.3 实施前决策点（用户确认项）

1. P0 缺陷修复采用**方案 B（单监控任务合并）**是否认可；是否同步评估 rx 侧方案 A。
2. SQLite 依赖引入方式（native FFI + js 降级占位 / js 走 sql.js）在 P0 开工时定稿。
3. P1 embedding 模型选择（本地/预训练/API）开工时确认。
4. 本计划稿仅定稿设计，**实施是否开工由用户决定**。

> 每阶段完成后按既有工作流产出技术报告（含门禁表格），保存至 `workbuddy/plan/`。
*（内容由AI生成，仅供参考）*
