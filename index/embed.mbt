/// embedding 列读写接口（P1 扩展位；P0 恒 NULL，仅提供能力位，见 §3.2）
use @sqlite

/// 读取 embedding（P0 恒 None）
pub fn get_embedding(_db : @sqlite.Database, _path : String) -> Bytes? {
  None
}

/// 写入 embedding（P0 不调用；接口留给 P1 向量召回）
pub fn set_embedding(db : @sqlite.Database, path : String, blob : Bytes) -> Unit {
  let stmt = db.prepare("UPDATE fs_nodes SET embedding = ? WHERE path = ?")
  if stmt is Some(st0) {
    let st = st0
    let _ = st.bind(1, @sqlite.SqlValue::Blob(blob))
    let _ = st.bind(2, @sqlite.SqlValue::Text(path.as_bytes()))
    let _ = st.execute()
    st.finalize()
  }
}
