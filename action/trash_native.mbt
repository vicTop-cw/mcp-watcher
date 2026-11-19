// action/trash_native.mbt —— trash 物理回收真实现（native 专属）
//
// 路径：moonbitlang/async 的 @fs 在 native 提供 mkdir/rename（有 C stub），
// 实测可用（见 action/.probe-trash 探针）。js 目标无此 API，故由
// trash_stub.mbt 门控降级。wasm 虽编译通过但 fs 为 unimplemented，一并 stub。

///|
/// 将文件移入 `<watch_dir>/.trash/<basename>.<epoch_ns>`（native 真做实）。
///
/// - 回收目录不存在则递归创建（allow_exist=true，幂等）；
/// - 目标名带纳秒时间戳，避免同名覆盖；
/// - 任一步失败返回 Err（可诊断），不吞错。
pub async fn trash_file(path : String, watch_dir : String) -> Result[Unit, String] {
  let trash_dir = watch_dir + "/.trash"
  let file_name = base_name(path)
  let stamp = Int64::to_string(@rx.real_now())
  let dest = trash_dir + "/" + file_name + "." + stamp
  try {
    @fs.mkdir(trash_dir, recursive=true, allow_exist=true)
    @fs.rename(path, dest, replace=true)
    Ok(())
  } catch {
    e => Err("trash 物理回收失败: " + e.to_string())
  }
}

///|
/// 取路径的文件名部分（兼容 \ 与 / 分隔符）。
fn base_name(path : String) -> String {
  let normalized = path.replace(old="\\", new="/")
  let parts = normalized.split("/")
  match parts.last() {
    Some(s) => s.to_string()
    None => path
  }
}
