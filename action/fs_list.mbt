// ============================================================================
// action · fs_list —— 同步目录枚举（验收门 artifact_glob 存在性检查）
//
// PLAN-gates.md §一 红线：门禁检查 = 纯函数（字符串包含 + glob 存在性），
// 零新依赖。枚举部分为本包自带的薄同步 FFI（与 rx monitor 的 native-stub
// 同范式，不引入任何新外部依赖）。
//
// 目标支持（诚实标注）：
//   - native：真做实（C FFI FindFirstFileW / readdir）
//   - js / wasm：无同步 fs API（@fs.walk 是 async，而动作执行路径是同步的
//     订阅回调，无法驱动）→ list_dir_entries 返回 None，artifact_glob
//     判"无命中"——与本项目"native 做实、其他目标诚实降级"范式一致
// ============================================================================

///|
/// 列举单个目录（非递归）：条目名，目录带 "/" 后缀。
/// 目录不存在或枚举失败返回 None。
///
/// 注意（native）：底层 C 桩在失败时也返回空字节，MoonBit 侧无法区分
/// "空目录"与"失败"以外的第三种状态——对门禁语义无影响（空目录 = 无命中）。
#cfg(target="native")
pub fn list_dir_entries(dir : String) -> Array[String]? {
  let raw = watcher_list_dir_raw(@utf8.encode(dir))
  let len = raw.length()
  if len == 0 {
    return None
  }
  let parsed = @json.parse(@utf8.decode_lossy(raw)) catch {
    _ => return None
  }
  let out : Array[String] = []
  match parsed {
    @json.Array(items) =>
      for it in items {
        match it {
          @json.String(s) => out.push(s)
          _ => ()
        }
      }
    _ => ()
  }
  Some(out)
}

///|
/// js / wasm：诚实降级（无同步 fs，见文件头说明）
#cfg(not(target="native"))
pub fn list_dir_entries(dir : String) -> Array[String]? {
  let _ = dir
  None
}

///|
#cfg(target="native")
#owned(dir)
extern "c" fn watcher_list_dir_raw(dir : Bytes) -> Bytes = "moonbit_watcher_list_dir"

// ============================================================================
// artifact_glob 存在性检查
// ============================================================================

///|
/// artifact_glob 存在性检查：watch_dir 下是否存在至少 1 个文件命中 glob
///
/// 纯逻辑核心是 @util.glob_match（三目标可单测）；本函数只做同步目录枚举
/// （IO）与相对路径拼装，递归走查、命中即短路。
///
/// 语义（PLAN-gates.md §一）：`artifact_glob` 为相对 watch_dir 的 glob，
/// 至少命中 1 个文件才算通过。
pub fn artifact_glob_hit(watch_dir : String, glob : String) -> Bool {
  let base = strip_trailing_slash(watch_dir)
  if base == "" {
    return false
  }
  let hit = Ref::Ref(false)
  walk_entries(base, "", glob, hit)
  hit.val
}

///|
/// 去掉末尾的所有 "/"（防止拼出双斜杠空段）
fn strip_trailing_slash(p : String) -> String {
  let mut s = p
  while s.has_suffix("/") {
    s = s[0:s.length() - 1].to_owned()
  }
  s
}

///|
/// 递归枚举：对每个普通文件做 glob 匹配；命中即短路返回
fn walk_entries(
  dir_abs : String,
  rel : String,
  glob : String,
  hit : Ref[Bool],
) -> Unit {
  let entries = match list_dir_entries(dir_abs) {
    Some(e) => e
    None => return
  }
  for name in entries {
    if hit.val {
      return
    }
    let is_dir = name.has_suffix("/")
    let bare = if is_dir {
      name[0:name.length() - 1].to_owned()
    } else {
      name
    }
    if bare == "" {
      continue
    }
    let rel2 = if rel == "" { bare } else { rel + "/" + bare }
    if is_dir {
      walk_entries(dir_abs + "/" + bare, rel2, glob, hit)
    } else if @util.glob_match(glob, rel2) {
      hit.val = true
    }
  }
}
