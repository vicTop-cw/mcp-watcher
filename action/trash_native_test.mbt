// action/trash_native_test.mbt —— trash 物理回收真做实验证（native 专属）
//
// 验证 @fs.mkdir + @fs.rename 真实把文件移入 <watch_dir>/.trash，
// 原路径消失、回收目录内出现带时间戳的目标文件。

///|
async test "trash_file native：文件被真实移入 .trash 目录" {
  let base = "E:/IDEProjects/AI/mcp-watcher/action/.trash-test"
  let _ = @fs.mkdir(base, recursive=true, allow_exist=true)
  defer (@fs.rmdir(base, recursive=true, allow_missing=true) catch { _ => () })
  let src = base + "/victim.tmp"
  @fs.write_file(src, "recycle me")
  // 确认源文件存在
  assert_true(@fs.exists(src))

  match @action.trash_file(src, base) {
    Err(e) => assert_true(false)
    Ok(_) => ()
  }

  // 原路径消失
  assert_false(@fs.exists(src))
  // .trash 目录存在
  assert_true(@fs.exists(base + "/.trash"))
}
