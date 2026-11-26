# 已知问题清单 · 2026-11-23（修复后状态）

## 1. 范围与判读

本清单只记录**代码与实测可证**的问题，按以下四类区分：

- **真实缺陷**：代码/测试/CLI 提示与实现不一致，需修复。
- **回归缺口**：已有设计承诺但缺少自动回归网，需补测试。
- **目标限制**：当前编译/运行目标固有能力边界，不伪装为已实现。
- **后续增强**：可规划但不属于本轮“修复已知问题”的范围。

证据来源：`scripts/test_all.sh` 全量门禁（2026-11-23 最终复跑）、`moon check --target native`、源码 grep、README/USAGE 与 `rx-mbt/PLAN-2026-11-18-gap-audit.md`。

## 2. 总表

| ID | 归属 | 分类 | 优先级 | 最终状态 | 验收结果 |
|---|---|---|---|---|---|
| M-01 | mcp-watcher/sqlite | 真实缺陷 | P0 | **已修** | native 测试 47/47，三目标全量 292 用例 failed=0 |
| M-02 | mcp-watcher/index | 回归缺口 | P1 | **已修** | `index/index_native_test.mbt` 4/4，targets 门控正确 |
| M-03 | mcp-watcher/cmd | 真实缺陷 | P2 | **已修** | 误导性 `--rebuild-index` 提示已从 CLI 与设计文档移除 |
| D-01 | mcp-watcher/docs | 文档漂移 | P2 | **已修** | README/USAGE 门禁读数按最终实测同步，AI 水印清除 |
| S-01 | mcp-watcher/scripts | 真实缺陷 | P2 | **已修** | 多个 `--skip=` 参数可叠加；全量脚本与 e2e-only 均 PASS |
| B-01 | mcp-watcher/build | 工具链约束 | P2 | **已收敛** | native 构建改为 `moon build --target native cmd/main`，README/USAGE/harness 同步 |
| R-01 | rx-mbt/rhop | 目标限制 | 外部依赖 | 未修 | native crypto FFI 仍缺；mcp-watcher 诚实返回 Err，不写空密文 |
| R-02 | rx-mbt/rhop_task | 目标限制 | 外部依赖 | 未修 | native `ExecPolicy` 执行臂仍缺，不声明 native 命令执行已可用 |
| I-01 | mcp-watcher/index | 目标限制 | 后续增强 | 已标注 | `embedding` 列存在但 `get_embedding` 恒 `None`；不是向量数据库 |
| I-02 | mcp-watcher/index | 目标限制 | 后续增强 | 已标注 | FTS5 `unicode61` 对 CJK 分词弱；有 `LIKE` 兜底，无中文分词 |
| I-03 | mcp-watcher/index | 目标限制 | 已收敛 | 已标注 | index 仅 native，js/wasm 不支持已明示 |
| I-04 | mcp-watcher/index | 目标限制 | 后续增强 | 已标注 | 事件流无 rename old/new，当前 delete+create 幂等覆盖 |

## 3. 逐项说明

### M-01 · native sqlite 测试编译失败 + Windows 堆破坏（P0，已修）

- 初始现象：`moon test --target native` 出现 `Error: [4036] Cannot create values of the read-only type: Int/Text/Double/...`。
- 第一层根因：`SqlValue` 用 `pub enum` 声明，构造器对外只读；测试使用裸构造器。
- 第二层根因（更深）：`Sqlite3`/`Sqlite3Stmt` 原为空 abstract type，Windows native 下作为 GC 外部对象回传给 `sqlite3_close` 会破坏堆，测试以 `0xc0000374` 间歇崩溃。
- 其他阻塞：`sqlite/moon.pkg` 的 `linker-flags` 不是有效键；Windows 无全局 `sqlite3.lib`；测试缺 `@debug` 导入。
- 修复：
  1. `sqlite_common.mbt` 改为 `pub(all) enum SqlValue`；测试构造器全部完全限定。
  2. `sqlite_native.mbt` 的 C 指针句柄改为 `type Sqlite3 = Int64` / `type Sqlite3Stmt = Int64`，保留位精确指针；连续 20 次 close 压测无崩溃。
  3. 内置官方 SQLite 3.54.1 DLL + 导入库 + 头文件于 `sqlite/vendor/`，`stub.c` 包含本地头文件；不再依赖机器全局库。
  4. `sqlite/moon.pkg` 使用正确的 `link.native.cc-link-flags`；补 `moonbitlang/core/debug`。
  5. 所有最终可执行文件（sqlite 测试、index 测试、cmd/main）都显式带导入库；脚本把 `sqlite/vendor` 加入 PATH。
- 验收：`moon test --target native -p sqlite` 47/47；全量 native/js/wasm 292 用例 failed=0。

### M-02 · index 包缺少单元测试（P1，已修）

- 初始现象：`index/moon.pkg` 声明 `index_native_test.mbt` 门控但文件不存在。
- 新增测试并实际跑出两个真实缺陷：
  1. `index/fs_stub.c` 中 `make_json("{\"ok\":0/1}", 7)` 长度少一位（实际 8 字符），导致 `ensure_dir` 字符串比较恒失败，`open_index` 报“父目录创建失败”。
  2. C stub 用数字 `0/1` 表示 `ok`/`is_dir`，MoonBit 侧 `get_bool` 只认 JSON `true/false`，导致 `stat_path` 恒 `None`，`full_walk` 不写任何节点。
- 顺带把 index 包中旧版 MoonBit API 现代化：`use @pkg` 移除、`not` 改 `!`、`as_bytes()` 改 `@utf8.encode()`、`rindex` 改 `rev_find`、JSON 改用 `@json.parse` + `Object/Array` 模式、`StringView` 用 `to_owned()`、FFI 参数加 `#borrow`、结构类型改 `pub(all)`。
- 新增 4 个测试：防自噬、schema/meta、full_walk+组合过滤、apply_event create/modify/delete。
- 验收：`moon test --target native -p index` 4/4，无测试残留。

### M-03 · `search` 提示不存在的 `--rebuild-index`（P2，已修）

- 现象：`cmd/main/main.mbt` 注释与库不存在提示都写 `--rebuild-index`，但全仓没有该 flag。
- 修复：删除误导提示，改为“启动服务建库 / 删除库文件后重启服务”；同步改写 `cmd_search` 退出码注释与 `workbuddy/plan/vector-index-design.md` 中的相关表述。
- 验收：`cmd/` 与交付文档中已无该 flag 提示；`temp/autoplan-vector-index.md` 作为历史草稿未改。

### D-01 · 文档门禁读数与 AI 水印（P2，已修）

- README/USAGE 的门禁读数更新为最终实测：check 0 errors / 82 warnings；native/js/wasm 各 292 用例 failed=0；basic/deny e2e PASS。
- README/USAGE 的 native 构建命令改为 `moon build --target native cmd/main`。
- 删除 `USAGE.md` 顶部 AIGC front-matter 与末尾“内容由AI生成，仅供参考”；交付文档中已无 AIGC/AI 水印。
- 验收：`grep` 无 `AIGC|内容由AI|AI生成|仅供参考|ProduceID`。

### S-01 / B-01 · 门禁脚本与构建入口（本轮新发现，已修）

- S-01：`scripts/test_all.sh` 多个 `--skip=` 会互相覆盖。已改为逗号追加，`is_skipped` 可正确识别全部跳过项。
- B-01：`moon build --target native` 会为 `sqlite`/`index` 库包也生成可执行包装，link flags 导致 `LNK2019 main`。已把 README/USAGE/harness 的构建命令统一改为只构建 `cmd/main`。
- 验收：全量门禁与“跳过前四步只跑 e2e”两种调用都 PASS。

### R-01 / R-02 · rx-mbt 外部限制（不在本轮扩范围）

- 依据：`rx-mbt/PLAN-2026-11-18-gap-audit.md`。
- R-01：native crypto FFI 仍缺；Fernet 原语仅 js 可用，native 不可宣称加密。
- R-02：native `ExecPolicy` 执行臂仍缺；命令执行仅在已有 js/宿主实现中可用。
- mcp-watcher 侧维持诚实降级：加密返回可诊断 Err、不写空密文；不把限制写成已实现。

### I-01 ~ I-04 · 工作区文件检索完善度

- 已真实的完整能力：全量 walk 建库、事件增量 upsert/delete、防自噬、FTS5 关键词 + `LIKE` 兜底、`search` CLI 与过滤条件、native 4 例回归网。
- 尚不完善：`embedding` 占位（`get_embedding` 恒 `None`）、CJK 分词弱、native-only、rename 无 old/new 原子语义、无独立重建 CLI。
- 结论：**工作区文件快速检索可用，但不是向量数据库，未实现语义相似度搜索**；README/USAGE/申报书保持此表述。

## 4. 最终门禁读数（2026-11-23）

| 步骤 | 读数 |
|---|---|
| `moon check --target native` | 0 errors / 82 warnings |
| `moon test --target native` | 本项目用例 292 个，failed: 0 |
| `moon test --target js` | 本项目用例 292 个，failed: 0 |
| `moon test --target wasm` | 本项目用例 292 个，failed: 0 |
| `tests/harness/run.sh basic` | `RESULT: PASS` |
| `tests/harness/run.sh deny` | `RESULT: PASS` |
| `scripts/test_all.sh` | `RESULT: PASS —— 所有已执行步骤判绿` |

历史读数（0.4.4 时代的 222/222、203/203，以及“native 暂不可跑”）均已作废，不再引用为当前值。
