// ============================================================================
// glob_test —— util.glob 黑盒测试（仅使用公共 API）
// 覆盖：扩展名模式、单段不跨目录、** 跨段、通配边界、basename、整数解析。
// ============================================================================

///|
test "glob_match：扩展名模式按文件名匹配" {
  assert_true(@util.glob_match("*.md", "foo.md"))
  assert_true(@util.glob_match("*.md", "a.b.md"))
  assert_false(@util.glob_match("*.md", "foo.txt"))
}

///|
test "glob_match：单段模式不跨目录" {
  assert_false(@util.glob_match("*.md", "dir/foo.md"))
}

///|
test "glob_match：** 跨段匹配" {
  assert_true(@util.glob_match("**/*.tmp", "a/b/c.tmp"))
  assert_true(@util.glob_match("src/**/*.tmp", "src/a/b/c.tmp"))
  assert_false(@util.glob_match("src/**/*.tmp", "lib/a/c.tmp"))
}

///|
test "glob_match：精确模式" {
  assert_true(@util.glob_match("keep.tmp", "keep.tmp"))
  assert_false(@util.glob_match("keep.tmp", "keep.tmpx"))
}

///|
test "basename：取路径末段" {
  assert_eq(@util.basename("a/b/c.md"), "c.md")
  assert_eq(@util.basename("c.md"), "c.md")
}

///|
test "parse_int：正负与非法" {
  assert_eq(@util.parse_int("42"), Some(42))
  assert_eq(@util.parse_int("-7"), Some(-7))
  assert_eq(@util.parse_int("x"), None)
}
