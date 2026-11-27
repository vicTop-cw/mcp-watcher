// ============================================================================
// action/p3_lifecycle_native_test.mbt —— P3 产物生命周期验收测试（native 专属）
//
// 验收锚点：
//   1. TTL 到期 → 产物真实移入 <watch_dir>/.mcp-watcher-trash/<时间戳>/<name>
//      且原路径消失（可按桶整体还原的可恢复结构）；
//   2. 加密产物可解密还原（decrypt_file ∘ encrypt_file = 恒等），错误密钥报错；
//   3. 生命周期事件（product.expired / product.destroyed）真实上 EventBus。
//
// 依赖 @mon C FFI + @fs，故在 moon.pkg 中门控为 native 专属。
// ============================================================================

///|
fn mk_expired(
  path : String,
  age_sec : Int64,
  ttl : Int32,
) -> @action.ProductRecord {
  let now = @rx.real_now().to_int().to_int64()
  @action.ProductRecord::{
    path,
    created_at_ns: now - age_sec * 1_000_000_000L,
    ttl_seconds: ttl,
  }
}

///|
async fn reset_dir(path : String) -> Unit {
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true, allow_missing=true)
  }
  @fs.mkdir(path, recursive=true, allow_exist=true)
}

///|
fn write_sync(path : String, content : String) -> Result[Unit, String] {
  match @mon.fs_write_atomic(path, content) {
    Ok(_) => Ok(())
    Err(_) => Err("测试写文件失败: " + path)
  }
}

///|
async test "TTL 到期清扫：产物被真实移入 .mcp-watcher-trash/<时间戳>/，原路径消失" {
  @rx.install_real_clock()
  let base = "action/.p3-lifecycle-test"
  let src = base + "/old.tmp"
  let trash_root = base + "/" + @action.TRASH_DIR_NAME
  @fs.mkdir(base, recursive=true, allow_exist=true)
  let _ = write_sync(src, "ttl body")
  assert_true(@fs.exists(src))

  let tracker : @action.ProductTracker = {
    records: [mk_expired(src, 120L, 60)],
  }
  let (count, remaining) = tracker.sweep_expired_to_trash(base)
  assert_eq(count, 1)
  assert_eq(remaining.records.length(), 0)

  // 原路径消失（可恢复地移走，而非删除）
  assert_false(@fs.exists(src))
  // 回收根存在，且内部出现一个时间戳桶子目录
  assert_true(@fs.exists(trash_root))
  let buckets = @fs.readdir(trash_root)
  assert_eq(buckets.length(), 1)
  let bucket = trash_root + "/" + buckets[0]
  // 桶内保留原文件名（可按桶整体还原）
  assert_true(@fs.exists(bucket + "/old.tmp"))
  reset_dir(base)
}

///|
async test "TTL 未到期：不回收、记录保留" {
  @rx.install_real_clock()
  let base = "action/.p3-lifecycle-fresh"
  let src = base + "/fresh.tmp"
  reset_dir(base)
  let _ = write_sync(src, "still young")

  let tracker : @action.ProductTracker = {
    records: [mk_expired(src, 1L, 3600)],
  }
  let (count, remaining) = tracker.sweep_expired_to_trash(base)
  assert_eq(count, 0)
  assert_eq(remaining.records.length(), 1)
  assert_true(@fs.exists(src))
  reset_dir(base)
}

///|
async test "加密产物可解密还原：encrypt_file/decrypt_file 往返恒等" {
  let base = "action/.p3-crypto-test"
  let f = base + "/secret.txt"
  let key = "T0r74-unit-key"
  let original = "mcp-watcher P3 产物加密原文\n多行内容"

  reset_dir(base)
  let _ = write_sync(f, original)

  // 密文带魔数前缀，且与原文不同
  match @action.encrypt_file(f, Some(key)) {
    Err(_) => assert_true(false)
    Ok(n) => assert_true(n > 0L)
  }
  let ct = match @mon.fs_read_text(f) {
    Err(_) => {
      assert_true(false)
      ""
    }
    Ok(s) => s
  }
  assert_true(@action.is_encrypted_text(ct))
  assert_true(ct != original)

  // 同密钥还原为原文（验收锚点：可解密还原）
  match @action.decrypt_file(f, Some(key)) {
    Err(_) => assert_true(false)
    Ok(n) => assert_true(n > 0L)
  }
  let plain = match @mon.fs_read_text(f) {
    Err(_) => {
      assert_true(false)
      ""
    }
    Ok(s) => s
  }
  assert_eq(plain, original)

  // 错误密钥必须失败（GCM tag 认证），不得静默返回乱码
  match @action.encrypt_file(f, Some(key)) {
    Err(_) => assert_true(false)
    Ok(_) => ()
  }
  match @action.decrypt_file(f, Some("wrong-key")) {
    Ok(_) => assert_true(false)
    Err(_) => ()
  }
  reset_dir(base)
}

///|
async test "生命周期事件真实上 EventBus：product.expired / product.destroyed 被订阅捕获" {
  @rx.install_real_clock()
  let base = "action/.p3-lifecycle-bus"
  reset_dir(base)
  let bus = @action.new_lifecycle_bus()
  let events : Ref[Array[@action.LifecycleEvent]] = Ref::Ref([])
  let seen : Ref[Array[String]] = Ref::Ref([])
  let _ = bus.subscribe("product.*", fn(ev : @rx.TriggerEvent[@action.LifecycleEvent]) {
    seen.val.push(ev.payload.event_name())
  })

  // cleanup_expired 只发逻辑过期事件（不做物理回收）
  let tracker : @action.ProductTracker = {
    records: [mk_expired(base + "/gone.tmp", 999L, 60)],
  }
  let (count, _remaining, expired_recs) = tracker.cleanup_expired(
    base,
    bus=Some(bus),
    events=events,
  )
  assert_eq(count, 1)
  assert_eq(expired_recs[0].path, base + "/gone.tmp")
  assert_true(seen.val.contains("product.expired"))

  // 累加器同步记录（无总线时仍可诊断）
  assert_eq(events.val.length(), 1)
  assert_eq(events.val[0].event_name(), "product.expired")

  // sweep 路径补发 product.destroyed（真实文件，回收成功才有该事件）
  let src2 = base + "/gone2.tmp"
  let _ = write_sync(src2, "destroy me")
  let seen2 : Ref[Array[String]] = Ref::Ref([])
  let _ = bus.subscribe("product.destroyed", fn(ev : @rx.TriggerEvent[@action.LifecycleEvent]) {
    seen2.val.push(ev.payload.path)
  })
  let t2 : @action.ProductTracker = {
    records: [mk_expired(src2, 999L, 60)],
  }
  let (c2, _) = t2.sweep_expired_to_trash(base, bus=Some(bus), events=events)
  assert_eq(c2, 1)
  assert_eq(seen2.val.length(), 1)
  reset_dir(base)
}
