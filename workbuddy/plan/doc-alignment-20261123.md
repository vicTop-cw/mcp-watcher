# 申报书重写 + 文档即实现校准记录

> 更新（2026-11-23 第二轮）：用户给出新的 8 项申报要求，并明确"一页以内、不要使用 AI 编写、不能留有 AIGC 和 AI 水印"。已据此重写申报书为 8 项结构，删除 AIGC front-matter；硬检查 8 项章节齐全、零水印、两份 MD5 一致。commits 曾实测为总 27、feat/fix 14、合并提交 0、无空提交。
>
> 更新（2026-11-23 第三轮）：用户要求去掉提交数据陈述（项目仍在开发中，数字会变）。第 8 项改为仅保留 GitHub 仓库链接，标题简化为"GitHub 仓库"。复核：无提交数据残留、8 项齐全、零水印、两份一致，52 行。下方 §1 的"样本 4 段结构/AIGC front-matter"描述已被取代，仅作历史记录。

---

> 日期：2026-11-23
> 触发：用户"按 AI/申报书样本.txt 重写申报书（不宜冗长）；README/USAGE 同步，遵循文档即实现"
> 口径：所有数字取自本次本机实测，不引述历史结论。

---

## 1. 结论

- 申报书按样本 4 段结构重写，正文约 3.4KB（样本 2.8KB 量级），两份（根目录 / `competition/`）内容一致、MD5 相同，均保留赛事要求的 AIGC front-matter。
- README / USAGE 按当前代码与实测读数校准，消除过期数字（0.4.4、191/191、222/222 当前值化）与夸大声明（index 明确为 FTS5 元数据索引，非向量数据库）。
- 交叉核验：7 个 CLI 子命令、5 个 index 配置字段、4 个关键 API、版本双源均"声明 = 代码"。

## 2. 本次实测门禁（真值源）

| 项 | 读数 |
|---|---|
| `moon check` | 0 errors / 30 warnings |
| `moon test --target js` | 203/203（Total tests: 203, passed: 203, failed: 0） |
| `moon test --target native` | 暂不可跑：工作区未提交 `sqlite/sqlite_test.mbt:390` 用 `[Int,Text,Double]` 构造只读类型 [4036]（编译错误，非此前申报书所称"MSVC 链接失败"） |
| `moon test --target wasm-gc` | 编译失败（RX-MBT fs_* 未绑定，依赖侧缺口，历史结论） |
| 版本 | 0.2.3（moon.mod ≡ util/version.mbt::APP_VERSION） |
| commits | 26 |

## 3. 申报书变更要点

按 `E:/IDEProjects/AI/申报书样本.txt` 的结构：基本信息（6 项）/ 项目简介 / 核心功能范围 / 移植或参考说明。
- 参赛者信息沿用原申报书（陈旺 / 271390645@qq.com / GitHub 链接）；
- "是否为移植项目：否"，如实标注非零依赖（RX-MBT@0.4.6 + async@0.22.9 + x@0.5.5）；
- 核心功能范围按当前实现重写，含 FTS5 索引、双门禁、mcp_tool_call 仅 js、interval 触发源；
- 参考说明诚实列降级项：加密 native 不可做实、mcp 仅 js、webhook 扩展位、wasm-gc 未达成、stop 待实现。

## 4. README 变更要点

- 支柱 4 状态表扩充：internal 已落地、mcp_tool_call 仅 js、webhook 扩展位、工作区索引（FTS5/非向量）；
- 架构表加 `index`/`sqlite` 包；自治闭环图加索引节点；
- "当前状态"门禁读数改为本次实测（check 0 errors/30 warnings、js 203/203、native 编译错误说明、版本 0.2.3、依赖 0.4.6）；
- 快速开始加 `search <watch_dir> --keyword` 示例，并标注"位置参数 + 需 index.enabled + FTS5 非向量"；
- 文档索引加 vector-index-design、PLAN-gates；修正过期交叉引用（申报书 §11 → 本文/USAGE §8）。

## 5. USAGE 变更要点

- action kind 表：internal 已落地、mcp_tool_call 仅 js、webhook 扩展位；
- 新增 §3.2.1 index 配置（真实字段 enabled/db_path/include/exclude/embed，注明 FTS5 非向量、embed 恒空）；
- 新增 §4.7 search 子命令（位置参数 watch_dir + --keyword/--type/--ext/--min-size/--max-size/--mtime-*/--limit/--format/--db，均经代码核实），原 help 顺延为 §4.8；
- FAQ 加 §6.8（search 索引未启用/库不存在）、§6.9（不是向量数据库）；
- §7 更多资料加 vector-index-design；新增 §8 门禁读数表。

## 6. 未改动 / 保留

- 历史读数 222/222（native @ 2026-11-20）在 README/USAGE 中明确标注为"历史"，非当前值，保留供追溯；
- 未改任何代码，仅文档；未提交 git（工作区原有未提交改动保持原样）。
