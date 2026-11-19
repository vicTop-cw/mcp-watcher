// ============================================================================
// util · glob 匹配（路径级，支持 '*' 单段 / '**' 跨段）+ 简易整数解析
//
// 设计来源：rx-mbt 的 event_matches（按 '.' 分段通配）思路，这里改为按 '/'
// 分段的文件路径通配，用于 mcp-watcher 的 patterns / exclude 匹配。
// 纯逻辑、无外部依赖，可直接单测。
// ============================================================================

///|
/// 路径归一：反斜杠转正斜杠（Windows 兼容）
fn normalize(p : String) -> String {
  p.replace_all(old="\\", new="/")
}

///|
/// 按 '/' 切分为路径段
fn split_slash(p : String) -> Array[String] {
  let out : Array[String] = []
  for sv in normalize(p).split("/") {
    out.push(sv.to_owned())
  }
  out
}

///|
/// 段内通配匹配：'*' 匹配段内任意字符（不含 '/'）
pub fn segment_match(pat : String, seg : String) -> Bool {
  // 无通配符：必须完全相等（否则 "keep.tmp" 会误命中 "keep.tmpx"）
  if !pat.contains("*") {
    return pat == seg
  }
  let starts_with_star = pat.has_prefix("*")
  let ends_with_star = pat.has_suffix("*")
  let raw = pat.split("*")
  let chunks : Array[String] = []
  for sv in raw {
    let c = sv.to_owned()
    if c != "" {
      chunks.push(c)
    }
  }
  if chunks.length() == 0 {
    return true
  }
  let n = chunks.length()
  let mut rest = seg
  let mut pi = 0
  while pi < n {
    let c = chunks[pi]
    if pi == 0 && !starts_with_star {
      if !rest.has_prefix(c) {
        return false
      }
      rest = rest[c.length():].to_owned()
    } else if pi == n - 1 && !ends_with_star {
      if !rest.has_suffix(c) {
        return false
      }
    } else {
      match rest.find(c) {
        None => return false
        Some(idx) => rest = rest[idx + c.length():].to_owned()
      }
    }
    pi = pi + 1
  }
  true
}

///|
/// 取路径末段（文件名）
pub fn basename(p : String) -> String {
  let segs = split_slash(p)
  if segs.length() == 0 {
    return ""
  }
  segs[segs.length() - 1]
}

///|
/// 路径级 glob 匹配：'*' 匹配单个路径段，'**' 匹配零到多个段
pub fn glob_match(pattern : String, name : String) -> Bool {
  let pat = split_slash(pattern)
  let parts = split_slash(name)
  let plen = pat.length()
  let nlen = parts.length()
  let mut pi = 0
  let mut ni = 0
  let mut star_p = -1
  let mut star_n = -1
  while ni < nlen {
    if pi < plen {
      let p = pat[pi]
      if p == "**" {
        star_p = pi
        star_n = ni
        pi = pi + 1
      } else if p == "*" {
        pi = pi + 1
        ni = ni + 1
      } else if segment_match(p, parts[ni]) {
        pi = pi + 1
        ni = ni + 1
      } else if star_p != -1 {
        star_n = star_n + 1
        pi = star_p + 1
        ni = star_n
      } else {
        return false
      }
    } else if star_p != -1 {
      star_n = star_n + 1
      pi = star_p + 1
      ni = star_n
    } else {
      return false
    }
  }
  while pi < plen {
    if pat[pi] != "**" {
      return false
    }
    pi = pi + 1
  }
  true
}

///|
/// 简易有符号整数解析（避免依赖字符串→整数 API 的不确定性）
pub fn parse_int(s : String) -> Int32? {
  let a = s.to_array()
  let n = a.length()
  if n == 0 {
    return None
  }
  let mut sign = 1
  let mut i = 0
  if a[0] == '-' {
    sign = -1
    i = 1
  } else if a[0] == '+' {
    i = 1
  }
  let mut val = 0
  while i < n {
    let ch = a[i]
    if ch < '0' || ch > '9' {
      return None
    }
    val = val * 10 + (ch.to_int() - '0'.to_int())
    i = i + 1
  }
  Some(sign * val)
}
