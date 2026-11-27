/// 排除规则（vector-index-design §3.4）
///
/// 三级排除：
///   1. 内置硬编码目录名（.mcp-watcher-trash/.git/node_modules/temp，任意层级，不可覆盖）
///   2. 索引库自身（db_path 及其 -wal/-shm 伴生文件）——防自噬
///   3. 配置 include/exclude glob（与内置取并集；include 非空时作为白名单）

/// 内置排除目录名（精确匹配目录末段，任意层级）
fn builtin_excluded_name(name : String) -> Bool {
  name == ".mcp-watcher-trash" || name == ".git" || name == "node_modules" || name == "temp"
}

/// path 是否在 base 之下（base 自身不算；dir 语义，路径均规范化）
pub fn path_under(base : String, path : String) -> Bool {
  let b = normalize_slash(base)
  let p = normalize_slash(path)
  if p.length() <= b.length() {
    return false
  }
  p[0:b.length()].to_owned() == b && p[b.length()] == '/'
}

/// 判断是否跳过（walk 与事件补扫共用）
pub fn should_skip(
  cfg : @config.IndexConfig,
  db_path : String,
  path : String,
  rel : String,
  is_dir : Bool,
) -> Bool {
  // 1) 防自噬（最高优先级）：path 为 db_path 自身或其祖先目录（walk 不进入）
  if path == db_path {
    return true
  }
  if path_under(path, db_path) {
    return true
  }
  // 索引库伴生文件：-wal / -shm
  if path == db_path + "-wal" || path == db_path + "-shm" {
    return true
  }
  // 2) 内置目录名（目录末段）
  if is_dir && builtin_excluded_name(path_leaf(path)) {
    return true
  }
  // 3) 配置 glob：exclude 命中即排除
  for pat in cfg.exclude {
    if glob_match(pat, path) || glob_match(pat, rel) {
      return true
    }
  }
  // include 白名单（非空时，path 或 rel 至少命中一个）
  if cfg.include_glob.length() > 0 {
    let mut hit = false
    for pat in cfg.include_glob {
      if glob_match(pat, path) || glob_match(pat, rel) {
        hit = true
        break
      }
    }
    if !hit {
      return true
    }
  }
  false
}

/// 路径级 glob（* 单段、** 跨段、? 单字符；复制 util/glob 语义避免包耦合）
pub fn glob_match(pattern : String, name : String) -> Bool {
  let pat = normalize_slash(pattern)
  let s = normalize_slash(name)
  let ps = split_slash(pat)
  let ss = split_slash(s)
  match_globs(ps, 0, ss, 0)
}

fn split_slash(p : String) -> Array[String] {
  let out : Array[String] = []
  let mut start = 0
  let mut i = 0
  while i < p.length() {
    if p[i] == '/' {
      if i > start {
        out.push(p[start:i].to_owned())
      }
      start = i + 1
    }
    i = i + 1
  }
  if start < p.length() {
    out.push(p[start:p.length()].to_owned())
  }
  out
}

fn match_globs(ps : Array[String], pi : Int, ss : Array[String], si : Int) -> Bool {
  // 模式耗尽：文本也必须耗尽（除非模式以 ** 结尾并匹配剩余）
  if pi >= ps.length() {
    return si >= ss.length()
  }
  let pat = ps[pi]
  if pat == "**" {
    // ** 匹配零或多个段：尝试跳过 0..n 段
    let mut k = si
    while k <= ss.length() {
      if match_globs(ps, pi + 1, ss, k) {
        return true
      }
      k = k + 1
    }
    return false
  }
  if si >= ss.length() {
    return false
  }
  if !segment_match(pat, ss[si]) {
    return false
  }
  match_globs(ps, pi + 1, ss, si + 1)
}

/// 段内通配：* 任意字符序列（段内）、? 单字符
fn segment_match(pat : String, seg : String) -> Bool {
  seg_match(pat, 0, seg, 0)
}

fn seg_match(p : String, pi : Int, s : String, si : Int) -> Bool {
  if pi >= p.length() {
    return si >= s.length()
  }
  let c = p[pi]
  if c == '*' {
    // * 匹配零或多个字符
    let mut k = si
    while k <= s.length() {
      if seg_match(p, pi + 1, s, k) {
        return true
      }
      k = k + 1
    }
    return false
  } else if c == '?' {
    return si < s.length() && seg_match(p, pi + 1, s, si + 1)
  } else {
    if si >= s.length() || s[si] != c {
      return false
    }
    return seg_match(p, pi + 1, s, si + 1)
  }
}
