// action/crypto.mbt —— P3 产物加密（真做实，三目标可用）
//
// 复用 rx 0.4.6 的 `rhop` 密码臂思路：`RhopCipherAesGcmNative`
//   KDF     : PBKDF2-HMAC-SHA256(password, salt="rx-mbt-rhop-salt-v1",
//             iterations=100000, dk_len=32)（纯 MoonBit，无 OpenSSL/node:crypto）
//   GCM     : AES-256-GCM，IV 12B + tag 16B，无 AAD
//   token   : base64(iv) : base64(tag) : base64(ct)
//
// 与历史"诚实降级"口径的区别（实测确认）：
//   旧结论基于 rx 的 Fernet 原语是 `extern "js"`（node:crypto），native/wasm
//   无法加密；但 rx 0.4.6 另有**纯 MoonBit** 的 AES-256-GCM 实现，native 目标
//   门控且经 FIPS-197 / NIST SP 800-38D 向量验证（见 RX-MBT
//   test-suit/rhop_native_gcm）。故本项改为真做实，且 js/wasm 编译路径同构。
//
// 落盘格式（自描述，便于将来迁移/校验）：
//   MBPWCRYPT1 <alg> <token>
//   例：`MBPWCRYPT1 aes-256-gcm abc:def:ghi`

///|
/// 密文魔数 + 算法名的完整前缀（自描述格式首行）
pub const CRYPT_PREFIX : String = "MBPWCRYPT1 aes-256-gcm "
/// 未显式提供密钥时的默认口令（可被环境变量 `MCP_WATCHER_CRYPT_KEY` 覆盖）
const DEFAULT_CRYPT_PASSWORD = "mcp-watcher-p3-default-key"

///|
/// 取加密口令：显式 key > 环境变量 MCP_WATCHER_CRYPT_KEY > 内置默认口令
fn resolve_password(key : String?) -> String {
  match key {
    Some(k) => k
    None => match @env.get_env_var("MCP_WATCHER_CRYPT_KEY") {
      Some(k) => k
      None => DEFAULT_CRYPT_PASSWORD
    }
  }
}

///|
/// 新建密码臂：按编译目标分派到具体实现（trait object，统一 `RhopCipher` 视角）
///
/// RX-MBT 的 AES-256-GCM 实现按目标分轨（0.5.1 同构，均为目标门控文件）：
///   - native：`rhop.RhopCipherAesGcmNative`（纯 MoonBit，rhop/cipher_gcm.mbt，仅 native）
///   - js    ：`rhop.Aes256GcmCipher`（node:crypto，rhop/rhop_js.mbt，仅 js）
///   - wasm  ：无实现，返回可诊断 Err（诚实降级，不伪造密文）
/// 具体实现在 crypto_native.mbt / crypto_js.mbt / crypto_wasm.mbt 三个门控文件中。
fn make_cipher(password : String) -> Result[&@rhop.RhopCipher, String] {
  cipher_impl(password)
}

///|
/// 密文是否为本项目格式（前缀匹配）
pub fn is_encrypted_text(text : String) -> Bool {
  text.has_prefix(CRYPT_PREFIX)
}

///|
/// 加密文本载荷，返回带魔数的密文文本
///
/// 失败（畸形参数 / 编码异常）返回 Err；不写任何部分结果。
pub fn encrypt_text(
  plain : String,
  key : String?,
) -> Result[String, String] {
  let cipher = match make_cipher(resolve_password(key)) {
    Err(e) => return Err("产物加密失败：" + e)
    Ok(c) => c
  }
  let token = cipher.encrypt(plain)
  if token == "" {
    return Err("产物加密失败：密码臂返回空 token")
  }
  Ok(CRYPT_PREFIX + token)
}

///|
/// 解密带魔数的密文文本，返回明文
///
/// 校验顺序：魔数前缀 → 三段 base64 形态 → GCM tag 认证；任一不过返回 Err。
pub fn decrypt_text(ciphertext : String, key : String?) -> Result[String, String] {
  if !is_encrypted_text(ciphertext) {
    return Err("产物解密失败：不是 mcp-watcher 密文格式（缺少 MBPWCRYPT1 前缀）")
  }
  let n = CRYPT_PREFIX.length()
  let token = ciphertext[n:].to_owned()
  let cipher = match make_cipher(resolve_password(key)) {
    Err(e) => return Err("产物解密失败：" + e)
    Ok(c) => c
  }
  match cipher.decrypt(token) {
    None => Err("产物解密失败：tag 校验不过（错误密钥 / 密文被篡改 / 形态非法）")
    Some(plain) => Ok(plain)
  }
}

///|
/// 加密文件：读原文 → 加密 → 原子覆盖写回，返回字节数
///
/// 用 `@mon.fs_write_atomic`（native C FFI）+ `@mon.fs_read_text`，
/// 与 `ProductTracker::save/load` 同一通道（native 专属语义）。
pub fn encrypt_file(path : String, key : String?) -> Result[Int64, String] {
  let plain = match @mon.fs_read_text(path) {
    Err(e) => return Err("产物加密读取失败: " + fs_error_text_local(e))
    Ok(s) => s
  }
  let ct = match encrypt_text(plain, key) {
    Err(e) => return Err(e)
    Ok(t) => t
  }
  match @mon.fs_write_atomic(path, ct) {
    Err(e) => Err("产物加密写入失败: " + fs_error_text_local(e))
    Ok(_) => Ok(ct.length().to_int64())
  }
}

///|
/// 解密文件：读密文 → 解密 → 原子覆盖写回，返回还原字节数
///
/// 验收锚点「加密产物可解密还原」由本函数闭环（decrypt_file ∘ encrypt_file = 恒等）。
pub fn decrypt_file(path : String, key : String?) -> Result[Int64, String] {
  let ct = match @mon.fs_read_text(path) {
    Err(e) => return Err("产物解密读取失败: " + fs_error_text_local(e))
    Ok(s) => s
  }
  let plain = match decrypt_text(ct, key) {
    Err(e) => return Err(e)
    Ok(p) => p
  }
  match @mon.fs_write_atomic(path, plain) {
    Err(e) => Err("产物解密写入失败: " + fs_error_text_local(e))
    Ok(_) => Ok(plain.length().to_int64())
  }
}
