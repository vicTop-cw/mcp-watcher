// ============================================================================
// cron_test —— cron 表达式解析与 next_after 黑盒测试（仅使用公共 API）
// 覆盖：步进/通配/区间/星期解析、非法输入、步进触发、跨月进位、每日、星期对齐。
// ============================================================================

///|
fn parse_ok(s : String) -> @cron.CronExpr {
  @cron.CronExpr::parse(s).unwrap()
}

///|
test "cron 解析：步进与通配" {
  let e = parse_ok("*/15 * * * *")
  assert_eq(e.minute, [0, 15, 30, 45])
  assert_true(e.hour.is_empty())
  assert_true(e.dom.is_empty())
  assert_true(e.month.is_empty())
  assert_true(e.dow.is_empty())
}

///|
test "cron 解析：区间与星期" {
  let e = parse_ok("0 9 * * 1")
  assert_eq(e.minute, [0])
  assert_eq(e.hour, [9])
  assert_eq(e.dow, [1])
}

///|
test "cron 解析：逗号列表与范围步进" {
  let e = parse_ok("0,30 1-3 * * *")
  assert_eq(e.minute, [0, 30])
  assert_eq(e.hour, [1, 2, 3])
}

///|
test "cron 解析：非法输入报错" {
  match @cron.CronExpr::parse("bad") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  match @cron.CronExpr::parse("60 * * * *") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
  match @cron.CronExpr::parse("* * * *") {
    Ok(_) => assert_true(false)
    Err(_) => assert_true(true)
  }
}

///|
test "cron next_after：步进到下一个刻" {
  let e = parse_ok("*/15 * * * *")
  let from = @cron.Timestamp::from_ymd(2026, 11, 12, 10, 0)
  assert_eq(
    e.next_after(from).unwrap(),
    @cron.Timestamp::from_ymd(2026, 11, 12, 10, 15),
  )
}

///|
test "cron next_after：跨月进位" {
  let e = parse_ok("0 0 1 * *")
  let from = @cron.Timestamp::from_ymd(2026, 11, 30, 23, 59)
  assert_eq(
    e.next_after(from).unwrap(),
    @cron.Timestamp::from_ymd(2026, 12, 1, 0, 0),
  )
}

///|
test "cron next_after：每日固定时刻（严格晚于 from）" {
  let e = parse_ok("30 2 * * *")
  let from = @cron.Timestamp::from_ymd(2026, 11, 12, 2, 30)
  assert_eq(
    e.next_after(from).unwrap(),
    @cron.Timestamp::from_ymd(2026, 11, 13, 2, 30),
  )
}

///|
test "cron next_after：星期对齐（周一 09:00）" {
  let e = parse_ok("0 9 * * 1")
  let from = @cron.Timestamp::from_ymd(2026, 11, 12, 8, 0)
  assert_eq(
    e.next_after(from).unwrap(),
    @cron.Timestamp::from_ymd(2026, 11, 16, 9, 0),
  )
}

///|
test "cron 星期计算：2026-11-12 是周四" {
  let t = @cron.Timestamp::from_ymd(2026, 11, 12, 0, 0)
  assert_eq(t.weekday, 4)
}
