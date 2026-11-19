// ============================================================================
// rule/condition.mbt —— Layer2 条件编译（接入 rx all_of / any_of / not_）
//
// 把声明式 ConditionSpec 编译为 rx EventBus 条件过滤器可直接使用的
// `(TriggerEvent[FsEvent]) -> Bool`。
//
// 支持的 kind（向后兼容）：
//   原子：size_gt / name_contains          （与 matcher.condition_eval 语义一致）
//   组合：all / any / not
//     - all / any 的 expr 是子条件 JSON 数组字符串，如
//       '[{"kind":"size_gt","expr":"100"},{"kind":"name_contains","expr":".tmp"}]'
//     - not 的 expr 是单个子条件 JSON 对象字符串，如
//       '{"kind":"name_contains","expr":".bak"}'
//
// 组合器直接消费 rx 的 @rx.all_of / @rx.any_of / @rx.not_，
// 语义与 rx 侧保持单一真值（空 all 恒真、空 any 恒假，继承 rx 实现）。
// ============================================================================

///|
/// 从 Json 对象解析一个 ConditionSpec（内部复用，容错：缺字段用空串）
fn condition_from_json(v : @json.Json) -> @config.ConditionSpec {
  match v {
    @json.Json::Object(m) => {
      let kind = match m.get("kind") {
        Some(@json.Json::String(k)) => k
        _ => ""
      }
      let expr = match m.get("expr") {
        Some(@json.Json::String(e)) => e
        _ => ""
      }
      @config.ConditionSpec::new(kind, expr)
    }
    _ => @config.ConditionSpec::new("", "")
  }
}

///|
/// 解析子条件数组字符串
fn parse_children(expr : String) -> Array[@config.ConditionSpec] {
  let out : Array[@config.ConditionSpec] = []
  let parsed = @json.parse(expr) catch { _ => return out }
  match parsed {
    @json.Json::Array(arr) =>
      for v in arr {
        out.push(condition_from_json(v))
      }
    _ => ()
  }
  out
}

///|
/// 编译单个原子条件为 TriggerEvent 谓词
fn compile_atom(
  c : @config.ConditionSpec,
) -> (@rx.TriggerEvent[@watch.FsEvent]) -> Bool {
  fn(ev : @rx.TriggerEvent[@watch.FsEvent]) -> Bool {
    let fe = ev.payload
    if c.kind == "size_gt" {
      match @util.parse_int(c.expr) {
        Some(threshold) => fe.size > threshold
        None => false
      }
    } else if c.kind == "name_contains" {
      fe.path.contains(c.expr)
    } else if c.kind == "" {
      // 空条件（缺 kind）视为恒真，与 matcher.condition_eval 的默认分支一致
      true
    } else {
      // 未知 kind：保守起见恒真（不阻断事件），与 matcher 的默认分支一致
      true
    }
  }
}

///|
/// 把 ConditionSpec 编译为 rx EventBus 条件过滤器
///
/// 无条件（None）返回恒真。组合条件通过 rx 的 all_of / any_of / not_ 实现，
/// 保证与 rx 侧语义单一真值。
pub fn compile_condition(
  cond : @config.ConditionSpec?,
) -> (@rx.TriggerEvent[@watch.FsEvent]) -> Bool {
  match cond {
    None => fn(_ev : @rx.TriggerEvent[@watch.FsEvent]) { true }
    Some(c) =>
      if c.kind == "all" {
        let children = parse_children(c.expr)
        let preds : Array[(@rx.TriggerEvent[@watch.FsEvent]) -> Bool] = []
        for child in children {
          preds.push(compile_condition(Some(child)))
        }
        @rx.all_of(preds)
      } else if c.kind == "any" {
        let children = parse_children(c.expr)
        let preds : Array[(@rx.TriggerEvent[@watch.FsEvent]) -> Bool] = []
        for child in children {
          preds.push(compile_condition(Some(child)))
        }
        @rx.any_of(preds)
      } else if c.kind == "not" {
        let child = condition_from_json(
          @json.parse(c.expr) catch {
            _ => @json.Json::object({})
          },
        )
        @rx.not_(compile_condition(Some(child)))
      } else {
        compile_atom(c)
      }
  }
}

///|
/// 便捷重载：直接对 FsEvent 求值（供 matcher / 单测使用，不经过 EventBus）
pub fn condition_matches(
  cond : @config.ConditionSpec?,
  fe : @watch.FsEvent,
) -> Bool {
  let te : @rx.TriggerEvent[@watch.FsEvent] = {
    name: "",
    payload: fe,
    id: 0L,
    at: 0L,
  }
  compile_condition(cond)(te)
}
