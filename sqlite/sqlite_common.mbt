// ============================================================================
// 本地 vendor 修复：daqing/sqlite@0.4.0 发布物缺失 SqlValue 枚举定义
// （sqlite_native.mbt / sqlite_js.mbt 均引用但无定义，native 目标编译报
//   Error:[4032] "The type SqlValue is undefined"）。
// 本文件补齐该类型，构造子形态与两处使用完全一致：
//   Null / Int(Int32) / Int64(Int64) / Double(Double) / Text(Bytes) / Blob(Bytes)
// ============================================================================

///|
/// SQLite 动态值：用于 bind 参数与 column 结果读取。
pub(all) enum SqlValue {
  Null
  Int(Int32)
  Int64(Int64)
  Double(Double)
  Text(Bytes)
  Blob(Bytes)
}
