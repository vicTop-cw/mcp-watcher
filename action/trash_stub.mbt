// action/trash_stub.mbt —— trash 降级 stub（js / wasm）
//
// js 目标：moonbitlang/async 的 @fs 无 mkdir/rename 符号（实测编译失败）。
// wasm 目标：fs API 虽可编译但为 unimplemented（运行时抛错）。
// 故两目标保留同步 no-op 语义，明确返回"规划中"提示，不伪装成功。
//
// P3 生命周期语义（T0r74）：回收目录口径与 trash_native.mbt 对齐为
// `<watch_dir>/.mcp-watcher-trash/<时间戳>/<name>`。

///|
/// 回收站根目录名（与 native 侧一致；供诊断/文档引用）
pub const TRASH_DIR_NAME = ".mcp-watcher-trash"

///|
/// trash 降级：不删、不移文件，返回可诊断的 Err（明确"当前目标不支持"）。
pub fn trash_file(path : String, watch_dir : String) -> Result[Unit, String] {
  let _ = path
  let _ = watch_dir
  Err("trash 物理回收在当前目标不可用（需 native fs API）：已降级为逻辑过期")
}
