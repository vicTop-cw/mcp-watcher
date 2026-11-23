/// 事件增量管线（vector-index-design §5.3）：旁路订阅同一 bus，按事件类型分流
///
/// 事件类型 → 索引动作：
///   create  -> upsert（目录则子文件夹内嵌补扫）
///   modify  -> upsert（目录 modify 忽略）
///   delete  -> delete（级联子树）
///   rename  -> 事件流未暴露 old/new（rx 将 rename 映射为 Removed(old)+Created(new)），
///              由 delete+upsert 幂等覆盖；rename_node 单事务迁移供未来事件源/测试使用
/// 同步可靠性（§5.4）：单事件单事务；失败 ROLLBACK + 错误计数，不中断事件流。
use @watch
use @config

/// 应用单个文件事件
pub fn apply_event(h : IndexHandle, ev : @watch.FsEvent) -> Unit {
  let _ = txn_begin(h.db)
  let ok = match ev.event_type {
    @config.EventType::Create => {
      upsert_path(h.db, h.cfg, h.db_path, h.watch_dir, ev.path)
      true
    }
    @config.EventType::Modify => {
      if ev.is_dir {
        true // 目录 modify 忽略
      } else {
        upsert_path(h.db, h.cfg, h.db_path, h.watch_dir, ev.path)
        true
      }
    }
    @config.EventType::Delete => {
      delete_path(h.db, ev.path)
      true
    }
    @config.EventType::Rename => {
      true // 见上方说明：事件流无 old/new，delete+create 幂等覆盖
    }
    _ => true
  }
  if ok {
    let _ = txn_commit(h.db)
  } else {
    let _ = txn_rollback(h.db)
    record_error(h.db, "事件处理失败: " + ev.path)
  }
}
