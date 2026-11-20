// ============================================================================
// matcher_test —— rule 两层匹配黑盒测试（仅使用公共 API）
// 覆盖：事件类型 + glob 命中、事件类型不符、exclude 优先、Layer2 条件、派发。
// ============================================================================

///|
fn mk_rule(
  id : String,
  events : Array[String],
  patterns : Array[String],
  exclude : Array[String],
  condition : @config.ConditionSpec?,
) -> @config.Rule {
  let action = @config.ActionSpec::new(
    "command",
    Some(["echo", "hi"]),
    None,
    None,
    None,
  )
  @config.Rule::new(
    id,
    events,
    patterns,
    exclude,
    condition,
    [action],
    false,
    0,
    None,
  )
}

///|
fn mk_event(
  t : @config.EventType,
  path : String,
  size : Int32,
) -> @watch.FsEvent {
  @watch.FsEvent::new(t, path, false, 0, size)
}

///|
test "两层匹配：事件类型 + glob 命中" {
  let rule = mk_rule("r1", ["create"], ["*.tmp"], [], None)
  let ev = mk_event(@config.EventType::Create, "C:/tmp/x.tmp", 10)
  assert_true(@rule.matches_event(rule, ev))
}

///|
test "两层匹配：事件类型不符则不命中" {
  let rule = mk_rule("r1", ["create"], ["*.tmp"], [], None)
  let ev = mk_event(@config.EventType::Modify, "C:/tmp/x.tmp", 10)
  assert_false(@rule.matches_event(rule, ev))
}

///|
test "两层匹配：all 事件类型通配" {
  let rule = mk_rule("r1", ["all"], ["*.tmp"], [], None)
  let ev = mk_event(@config.EventType::Delete, "C:/tmp/x.tmp", 10)
  assert_true(@rule.matches_event(rule, ev))
}

///|
test "exclude 优先于 patterns" {
  let rule = mk_rule("r2", ["create"], ["*.tmp"], ["keep.tmp"], None)
  let excluded = mk_event(@config.EventType::Create, "C:/tmp/keep.tmp", 10)
  let kept = mk_event(@config.EventType::Create, "C:/tmp/drop.tmp", 10)
  assert_false(@rule.matches_event(rule, excluded))
  assert_true(@rule.matches_event(rule, kept))
}

///|
test "Layer2 条件：size_gt" {
  let cond = @config.ConditionSpec::new("size_gt", "100")
  let rule = mk_rule("r3", ["create"], ["*.tmp"], [], Some(cond))
  let big = mk_event(@config.EventType::Create, "C:/tmp/big.tmp", 200)
  let small = mk_event(@config.EventType::Create, "C:/tmp/small.tmp", 50)
  assert_true(@rule.matches_event(rule, big))
  assert_false(@rule.matches_event(rule, small))
}

///|
test "派发：返回全部命中规则" {
  let r1 = mk_rule("r1", ["create"], ["*.tmp"], [], None)
  let r2 = mk_rule("r2", ["modify"], ["*.tmp"], [], None)
  let ev = mk_event(@config.EventType::Create, "C:/tmp/x.tmp", 10)
  let hit = @rule.dispatch([r1, r2], ev)
  assert_eq(hit.length(), 1)
  assert_eq(hit[0].id, "r1")
}

///|
test "EP-03：大小写不敏感（盘上 casing 与规则书写 casing 不一致）" {
  // 盘上真实目录名 .Fist-Mbt，规则书写 .fist-mbt（Windows 大小写不敏感语义）
  let rule = mk_rule("r3", ["modify"], [".fist-mbt/data/fist-self-tidy.db*"], [], None)
  let ev = mk_event(
    @config.EventType::Modify,
    "E:/IDEProjects/AI/FIST-Mbt/.Fist-Mbt/data/fist-self-tidy.db-wal",
    10,
  )
  assert_true(@rule.matches_event(rule, ev))
}

///|
test "EP-03：相对模式匹配绝对路径（前缀自动补 **/ 吸收根段）" {
  let rule = mk_rule("r4", ["modify"], [".fist-mbt/data/*.db*"], [], None)
  let ev = mk_event(
    @config.EventType::Modify,
    "E:/IDEProjects/AI/FIST-Mbt/.fist-mbt/data/fist-self-tidy.db",
    10,
  )
  assert_true(@rule.matches_event(rule, ev))
}

///|
test "EP-03：已带 **/ 的模式不重复补前缀 + exclude 同样大小写不敏感" {
  let rule = mk_rule(
    "r5",
    ["modify"],
    ["**/.fist-mbt/data/*.db*"],
    [".fist-mbt/data/*.db-shm"],
    None,
  )
  let hit = mk_event(
    @config.EventType::Modify,
    "E:/IDEProjects/AI/FIST-Mbt/.Fist-Mbt/data/fist-self-tidy.db-wal",
    10,
  )
  let excluded = mk_event(
    @config.EventType::Modify,
    "E:/IDEProjects/AI/FIST-Mbt/.Fist-Mbt/data/fist-self-tidy.db-shm",
    10,
  )
  assert_true(@rule.matches_event(rule, hit))
  assert_false(@rule.matches_event(rule, excluded))
}

///|
test "EP-03：basename 分支大小写不敏感（BACKLOG.md 类规则回归）" {
  let rule = mk_rule("r6", ["modify"], ["backlog.md"], [], None)
  let ev = mk_event(
    @config.EventType::Modify,
    "E:/IDEProjects/AI/FIST-Mbt/BACKLOG.md",
    10,
  )
  assert_true(@rule.matches_event(rule, ev))
}
