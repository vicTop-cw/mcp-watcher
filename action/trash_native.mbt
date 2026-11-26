// action/trash_native.mbt —— trash 物理回收真实现（native 专属）
//
// 路径：moonbitlang/async 的 @fs 在 native 提供 mkdir/rename（有 C stub），
// 实测可用。js 目标无此 API，故由 trash_stub.mbt 门控降级；wasm fs 为
// unimplemented，一并 stub。
//
// P3 生命周期语义（T0r74）：回收目录由平铺 `.trash/<name>.<ts>` 改为
// **分桶可恢复**结构 `<watch_dir>/.mcp-watcher-trash/<时间戳>/<name>`——
// 每次回收独占一个以纳秒时间戳命名的子目录，据此可按桶整体还原
// （restore），避免多次同名回收互相覆盖、也便于按时间点回滚。

///|
/// 回收站根目录名（`<watch_dir>/.mcp-watcher-trash`；与 index 内置排除一致）
pub const TRASH_DIR_NAME = ".mcp-watcher-trash"
/// trash 物理回收失败错误前缀（诊断输出契约）
const TRASH_FAIL_PREFIX = "trash 物理回收失败: "

///|
/// 将文件移入 `<watch_dir>/<TRASH_DIR_NAME>/<时间戳>/<basename>`（native 真做实）。
///
/// - 每次回收生成独立的纳秒时间戳桶目录（幂等创建，允许已存在）；
/// - 桶内保留原文件名，因此同一文件的多次回收互不覆盖，可按桶还原；
/// - 任一步失败返回 Err（可诊断），不吞错。
pub async fn trash_file(path : String, watch_dir : String) -> Result[Unit, String] {
  let trash_root = watch_dir + "/" + TRASH_DIR_NAME
  let bucket = Int64::to_string(@rx.real_now())
  let file_name = base_name(path)
  try {
    @fs.mkdir(trash_root, recursive=true, allow_exist=true)
    @fs.mkdir(trash_root + "/" + bucket, recursive=true, allow_exist=true)
    @fs.rename(
      path,
      trash_root + "/" + bucket + "/" + file_name,
      replace=true,
    )
    Ok(())
  } catch {
    e => Err(TRASH_FAIL_PREFIX + e.to_string())
  }
}

///|
/// 取路径的文件名部分（兼容 \ 与 / 分隔符）。
fn base_name(path : String) -> String {
  let normalized = path.replace(old="\\", new="/")
  let parts = normalized.split("/")
  match parts.last() {
    Some(s) => s.to_owned()
    None => path
  }
}
