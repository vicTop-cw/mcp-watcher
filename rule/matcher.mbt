// ============================================================================
// rule · 两层匹配算法（与 design-spec §4 对齐）
//
// Layer1：事件类型 + glob 匹配（exclude 优先于 patterns）。
// Layer2：条件 AND（本期为单条件原子，完整组合见 rx all_of）。
// 纯逻辑、无外部依赖，可直接单测。
// ============================================================================

///|
/// 模式匹配：不含 '/' 的模式按文件名匹配（如 "*.md"）；含 '/' 的模式按整路径匹配
fn pattern_match(pattern : String, path : String) -> Bool {
  if pattern.contains("/") {
    @util.glob_match(pattern, path)
  } else {
    @util.glob_match(pattern, @util.basename(path))
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
