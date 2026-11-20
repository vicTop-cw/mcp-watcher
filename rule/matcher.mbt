// ============================================================================
// rule · 两层匹配算法（与 design-spec §4 对齐）
//
// Layer1：事件类型 + glob 匹配（exclude 优先于 patterns）。
// Layer2：条件 AND（本期为单条件原子，完整组合见 rx all_of）。
// 纯逻辑、无外部依赖，可直接单测。
// ============================================================================

///|
/// 模式匹配：不含 '/' 的模式按文件名匹配（如 "*.md"）；含 '/' 的模式按整路径匹配
///
/// EP-03 Windows 实弹发现并修复两点：
///   1. 大小写不敏感：事件路径携带盘上真实 casing（如 `.Fist-Mbt`），规则
///      书写 casing（`.fist-mbt`）与之不同但语义相同——Windows 路径本就
///      大小写不敏感，匹配统一 case-fold，杜绝整类 casing 漂移失配。
///   2. 相对模式匹配绝对路径：事件携带绝对路径，而含 '/' 的规则按仓内
///      相对路径书写（如 `.fist-mbt/data/*.db*`），glob 按段锚定会整段
///      失配——前缀自动补 `**/` 吸收根段（已带 `**/` 的模式保持原样）。
fn pattern_match(pattern : String, path : String) -> Bool {
  let pat = lower_ascii(pattern)
  let p = lower_ascii(path)
  if pat.contains("/") {
    let full = if pat.has_prefix("**/") { pat } else { "**/" + pat }
    @util.glob_match(full, p)
  } else {
    @util.glob_match(pat, @util.basename(p))
  }
}

///|
/// ASCII 小写（MoonBit core 无公开 case API；字符字面量映射，仅处理 A-Z）
fn lower_ascii(s : String) -> String {
  let mut out = ""
  for ch in s {
    out = out + lower_char(ch).to_string()
  }
  out
}

///|
/// 单字符小写（字面量映射，不依赖 Char 构造 API）
fn lower_char(c : Char) -> Char {
  match c {
    'A' => 'a'
    'B' => 'b'
    'C' => 'c'
    'D' => 'd'
    'E' => 'e'
    'F' => 'f'
    'G' => 'g'
    'H' => 'h'
    'I' => 'i'
    'J' => 'j'
    'K' => 'k'
    'L' => 'l'
    'M' => 'm'
    'N' => 'n'
    'O' => 'o'
    'P' => 'p'
    'Q' => 'q'
    'R' => 'r'
    'S' => 's'
    'T' => 't'
    'U' => 'u'
    'V' => 'v'
    'W' => 'w'
    'X' => 'x'
    'Y' => 'y'
    'Z' => 'z'
    _ => c
  }
}

///|
/// 单条规则是否命中事件
pub fn matches_event(rule : @config.Rule, ev : @watch.FsEvent) -> Bool {
  // exclude 优先：任一 exclude glob 命中 → 不匹配
  for ex in rule.exclude {
    if pattern_match(ex, ev.path) {
      return false
    }
  }
  // Layer1：事件类型
  let et = ev.event_type.to_string()
  let type_ok = rule.events.contains("all") || rule.events.contains(et)
  if !type_ok {
    return false
  }
  // Layer1：patterns（任一命中即可）
  let mut pat_ok = false
  for p in rule.patterns {
    if pattern_match(p, ev.path) {
      pat_ok = true
      break
    }
  }
  if !pat_ok {
    return false
  }
  // Layer2：条件（原子 + all/any/not 组合，统一走 rx 编译结果）
  condition_matches(rule.condition, ev)
}

///|
/// 派发：返回所有命中规则
pub fn dispatch(
  rules : Array[@config.Rule],
  ev : @watch.FsEvent,
) -> Array[@config.Rule] {
  let out : Array[@config.Rule] = []
  for r in rules {
    if matches_event(r, ev) {
      out.push(r)
    }
  }
  out
}
