// ============================================================================
// cmd/main · parse_args 单元测试（T0r167 F4 回归）
//
// F4：文档用法 `mcp-watch search <watch_dir>`（watch_dir 位置参数，
//   cmd_help 与 cmd_search 报错文案均为位置参数口径）——原 parse_args
//   无位置参数分支，静默丢弃 → cmd_search 恒报「search 缺少 watch_dir
//   位置参数」。
// 修复：search 命令下首个非旗标 token 作为 watch_dir（不吞未知旗标，
//   --watch-dir 旗标口径向后兼容）。
// ============================================================================

test "parse_args: search 位置参数 watch_dir（文档口径）" {
  let args = @main.parse_args(["mcp-watcher", "search", "E:/proj/x"])
  assert_true(args.command == "search")
  assert_true(args.watch_dir == "E:/proj/x")
}

test "parse_args: search 位置参数可后置旗标之后" {
  let args = @main.parse_args(["mcp-watcher", "search", "--keyword", "kw", "E:/proj/x"])
  assert_true(args.watch_dir == "E:/proj/x")
  assert_true(args.keyword == "kw")
}

test "parse_args: search --watch-dir 旗标仍可用（向后兼容）" {
  let args = @main.parse_args(["mcp-watcher", "search", "--watch-dir", "E:/proj/x"])
  assert_true(args.watch_dir == "E:/proj/x")
}

test "parse_args: search 未知旗标不被误吞为位置参数" {
  let args = @main.parse_args(["mcp-watcher", "search", "--bogus"])
  assert_true(args.watch_dir == "")
}

test "parse_args: validate/run 等命令不受位置参数分支影响（回归锁）" {
  let a = @main.parse_args(["mcp-watcher", "validate", "--rules", "x.json"])
  assert_true(a.command == "validate")
  assert_true(a.rules == "x.json")
  let b = @main.parse_args(["mcp-watcher", "run", "--watch-dir", "D:/w", "--once"])
  assert_true(b.command == "run")
  assert_true(b.watch_dir == "D:/w")
  assert_true(b.once)
}
