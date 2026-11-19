// ============================================================================
// condition_test —— Layer2 条件组合黑盒测试
// 覆盖：原子条件、all(AND)、any(OR)、not(取反)、嵌套组合、空组合语义。
// ============================================================================

///|
fn mk_ev(path : String, size : Int32) -> @watch.FsEvent {
  @watch.FsEvent::new(@config.EventType::Create, path, false, 0, size)
}

///|
fn cond(kind : String, expr : String) -> @config.ConditionSpec {
  @config.ConditionSpec::new(kind, expr)
}

///|
test "原子：size_gt 命中" {
  let c = Some(cond("size_gt", "100"))
  assert_true(@rule.condition_matches(c, mk_ev("a.tmp", 101)))
  assert_false(@rule.condition_matches(c, mk_ev("a.tmp", 100)))
}

///|
test "原子：name_contains 命中" {
  let c = Some(cond("name_contains", ".tmp"))
  assert_true(@rule.condition_matches(c, mk_ev("C:/tmp/a.tmp", 1)))
  assert_false(@rule.condition_matches(c, mk_ev("C:/tmp/a.md", 1)))
}

///|
test "无条件：恒真" {
  assert_true(@rule.condition_matches(None, mk_ev("a", 0)))
}

///|
test "all：两个条件都满足才命中" {
  let expr = "[{\"kind\":\"size_gt\",\"expr\":\"100\"},{\"kind\":\"name_contains\",\"expr\":\".tmp\"}]"
  let c = Some(cond("all", expr))
  assert_true(@rule.condition_matches(c, mk_ev("a.tmp", 101)))
  assert_false(@rule.condition_matches(c, mk_ev("a.md", 101)))
  assert_false(@rule.condition_matches(c, mk_ev("a.tmp", 50)))
}

///|
test "any：任一条件满足即命中" {
  let expr = "[{\"kind\":\"size_gt\",\"expr\":\"100\"},{\"kind\":\"name_contains\",\"expr\":\".tmp\"}]"
  let c = Some(cond("any", expr))
  assert_true(@rule.condition_matches(c, mk_ev("a.tmp", 1)))
  assert_true(@rule.condition_matches(c, mk_ev("a.md", 101)))
  assert_false(@rule.condition_matches(c, mk_ev("a.md", 1)))
}

///|
test "not：对单条件取反" {
  let expr = "{\"kind\":\"name_contains\",\"expr\":\".bak\"}"
  let c = Some(cond("not", expr))
  assert_true(@rule.condition_matches(c, mk_ev("a.tmp", 1)))
  assert_false(@rule.condition_matches(c, mk_ev("a.bak", 1)))
}

///|
test "嵌套：all(any(...), not(...))" {
  // (size>100 或 名字含 .tmp) 且 名字不含 .bak
  // 用 Json::stringify 构造内层字符串，避免手工转义出错
  let any_children = @json.Json::array([
    @json.Json::object({
      "kind": @json.Json::string("size_gt"),
      "expr": @json.Json::string("100"),
    }),
    @json.Json::object({
      "kind": @json.Json::string("name_contains"),
      "expr": @json.Json::string(".tmp"),
    }),
  ])
  let inner_any = @json.Json::stringify(
    @json.Json::object({
      "kind": @json.Json::string("any"),
      "expr": @json.Json::string(@json.Json::stringify(any_children)),
    }),
  )
  let inner_not = @json.Json::stringify(
    @json.Json::object({
      "kind": @json.Json::string("not"),
      "expr": @json.Json::string(
        @json.Json::stringify(
          @json.Json::object({
            "kind": @json.Json::string("name_contains"),
            "expr": @json.Json::string(".bak"),
          }),
        ),
      ),
    }),
  )
  let outer = "[" + inner_any + "," + inner_not + "]"
  let c = Some(cond("all", outer))
  assert_true(@rule.condition_matches(c, mk_ev("a.tmp", 1)))
  assert_true(@rule.condition_matches(c, mk_ev("a.md", 101)))
  assert_false(@rule.condition_matches(c, mk_ev("a.tmp.bak", 1)))
  assert_false(@rule.condition_matches(c, mk_ev("a.md", 1)))
}

///|
test "空 all 恒真 / 空 any 恒假（继承 rx 语义）" {
  let all_empty = Some(cond("all", "[]"))
  let any_empty = Some(cond("any", "[]"))
  assert_true(@rule.condition_matches(all_empty, mk_ev("a", 0)))
  assert_false(@rule.condition_matches(any_empty, mk_ev("a", 0)))
}

///|
test "非法 JSON expr 容错：all 空数组恒真，不崩溃" {
  let c = Some(cond("all", "not-json"))
  assert_true(@rule.condition_matches(c, mk_ev("a", 0)))
}
