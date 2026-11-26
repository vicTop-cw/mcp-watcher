// ============================================================================
// index · fts_query 单元测试（T0r167 F2 回归）
//
// fts_query 契约：token 逐一双引号包裹（FTS5 短语）AND 连接；
//   token 内双引号替换为空格（防语法注入 / 畸形表达式）。
// T0r167 F2：原 fallback（清洗后 keyword 为空）把**原始** keyword 重新包裹，
//   奇数引号时产出奇数引号畸形表达式（FTS5 "unterminated string"），
//   整条检索静默失败（LIKE 兜底也失效）。
// 修复：fallback 同样走引号清洗 → 合法空短语（FTS5 匹配零行，
//   字面匹配由 build_sql 的 LIKE '%kw%' 兜底承担）。
//
// 纯函数、无 IO、无 SQLite 依赖（包本身 native-only，随 native 门执行）。
// ============================================================================

test "fts_query: 普通关键词 → 引号短语 + AND" {
  assert_true(fts_query("hello") == "\"hello\"")
  assert_true(fts_query("a b") == "\"a\" AND \"b\"")
}

test "fts_query: token 内双引号被清洗（防注入）" {
  assert_true(fts_query("a\"b c") == "\"a b\" AND \"c\"")
}

test "fts_query: 纯引号关键词（奇数）→ 合法空短语，不再畸形" {
  // 1 / 3 / 5 个引号：原实现分别产出 3 / 5 / 7 个引号（奇数，
  // FTS5 "unterminated string"，实测 sqlite 3.50.4/3.54.1 同款行为）
  assert_true(fts_query("\"") == "\"\"")
  assert_true(fts_query("\"\"\"") == "\"\"")
  assert_true(fts_query("\"\"\"\"\"") == "\"\"")
}

test "fts_query: 纯引号关键词（偶数）→ 同样降级为空短语" {
  assert_true(fts_query("\"\"") == "\"\"")
}

test "fts_query: 空白 / 空白+引号 → 空短语" {
  assert_true(fts_query("   ") == "\"\"")
  assert_true(fts_query(" \" \" ") == "\"\"")
}
