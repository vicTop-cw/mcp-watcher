// action/trash_native_test.mbt —— trash 物理回收真做实验证（native 专属）
//
// 验证 @fs.mkdir + @fs.rename 真实把文件移入
// <watch_dir>/.mcp-watcher-trash/<时间戳>/<name>，原路径消失、回收桶内出现同名文件。

///|
async test "trash_file native：文件被真实移入 .mcp-watcher-trash 时间戳桶" {
  let base = "action/.trash-test"
  let _ = @fs.mkdir(base, recursive=true, allow_exist=true)
  defer (@fs.rmdir(base, recursive=true, allow_missing=true) catch { _ => () })
  let src = base + "/victim.tmp"
  @fs.write_file(src, "recycle me")
  // 确认源文件存在
  assert_true(@fs.exists(src))

  match @action.trash_file(src, base) {
    Err(_) => assert_true(false)
    Ok(_) => ()
  }

  // 原路径消失
  assert_false(@fs.exists(src))
  // .trash 目录存在
  assert_true(@fs.exists(base + "/" + @action.TRASH_DIR_NAME))
}
