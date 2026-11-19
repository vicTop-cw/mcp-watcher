// action/trash_stub.mbt —— trash 降级 stub（js / wasm）
//
// js 目标：moonbitlang/async 的 @fs 无 mkdir/rename 符号（实测编译失败）。
// wasm 目标：fs API 虽可编译但为 unimplemented（运行时抛错）。
// 故两目标保留同步 no-op 语义，明确返回"规划中"提示，不伪装成功。

///|
/// trash 降级：不删、不移文件，返回可诊断的 Err（明确"当前目标不支持"）。
pub async fn trash_file(path : String, watch_dir : String) -> Result[Unit, String] {
  let _ = path
  let _ = watch_dir
  Err("trash 物理回收在当前目标不可用（需 native fs API）：已降级为逻辑过期")
}
