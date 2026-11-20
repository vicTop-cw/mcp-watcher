// ============================================================================
// cron · 表达式解析与下次触发计算（纯逻辑、可单测；mcp-watcher 自留领域逻辑）
//
// 标准 5 段：分 时 日 月 周。支持 '*' / 'a' / 'a-b' / '*/n' / 'a-b/n' / 逗号列表。
// 日期进位用 Howard Hinnant days_from_civil 标准算法（无外部依赖）。
// ============================================================================

///|
/// cron 搜索步长 / 年限等魔法数字收敛
/// 步长 60000ms = 1 分钟（cron 最小精度）；搜索上限 4 年（366 天闰年上限分钟数）。
const CRON_STEP_MS : Int64 = 60000L
const CRON_YEAR_LIMIT = 4
const CRON_ITER_LIMIT : Int = CRON_YEAR_LIMIT * 366 * 24 * 60
const CRON_NO_MATCH_MSG = " 年内无匹配 cron: "

///|
/// 时间戳（分钟精度）
#derive(Eq, Debug)
pub(all) struct Timestamp {
  year : Int32
  month : Int32
  day : Int32
  hour : Int32
  minute : Int32
  /// 星期（0=周日 .. 6=周六）
  weekday : Int32
}

///|
pub extend Timestamp with Eq::{not_equal, equal}

///|
pub extend Timestamp with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// cron 表达式（每段为允许值集合；空集合表示 '*'）
#derive(Eq, Debug)
pub(all) struct CronExpr {
  minute : Array[Int32]
  hour : Array[Int32]
  dom : Array[Int32]
  month : Array[Int32]
  dow : Array[Int32]
}

///|
pub extend CronExpr with Eq::{not_equal, equal}

///|
pub extend CronExpr with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 公历日期 → 距 1970-01-01 的天数（Hinnant 算法）
fn days_from_civil(y : Int32, m : Int32, d : Int32) -> Int32 {
  let m2 = if m > 2 { m - 3 } else { m + 9 }
  let y2 = if m > 2 { y } else { y - 1 }
  let era = (if y2 >= 0 { y2 } else { y2 - 399 }) / 400
  let yoe = y2 - era * 400
  let doy = (153 * m2 + 2) / 5 + d - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468
}

///|
/// 距 1970-01-01 的天数 → 公历日期
fn ymd_from_days(z : Int32) -> (Int32, Int32, Int32) {
  let z2 = z + 719468
  let era = (if z2 >= 0 { z2 } else { z2 - 146096 }) / 146097
  let doe = z2 - era * 146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 { mp + 3 } else { mp - 9 }
  let y_out = if m <= 2 { y + 1 } else { y }
  (y_out, m, d)
}

///|
/// 距 1970-01-01 的天数 → 星期（0=周日 .. 6=周六）
fn weekday_from_days(z : Int32) -> Int32 {
  (z + 4) % 7
}

///|
/// 时间戳 → Unix 毫秒（分钟精度）
///
/// 注意：MoonBit 的 Int 是 32 位，毫秒时间戳必须用 Int64，否则溢出。
fn cron_to_ms(t : Timestamp) -> Int64 {
  let z = days_from_civil(t.year, t.month, t.day)
  let secs = z.to_int64() * 86400L +
    t.hour.to_int64() * 3600L +
    t.minute.to_int64() * 60L
  secs * 1000L
}

///|
/// 由年月日时分构造时间戳（自动计算星期）
pub fn Timestamp::from_ymd(
  year : Int32,
  month : Int32,
  day : Int32,
  hour : Int32,
  minute : Int32,
) -> Timestamp {
  let z = days_from_civil(year, month, day)
  { year, month, day, hour, minute, weekday: weekday_from_days(z), }
}

///|
/// Unix 毫秒 → 时间戳
fn ms_to_cron(ms : Int64) -> Timestamp {
  let secs = ms / 1000L
  let z = (secs / 86400L).to_int()
  let secs_of_day = (secs % 86400L).to_int()
  let hour = secs_of_day / 3600
  let minute = secs_of_day % 3600 / 60
  let (y, m, d) = ymd_from_days(z)
  let wd = weekday_from_days(z)
  { year: y, month: m, day: d, hour, minute, weekday: wd, }
}

///|
/// 解析单个字段（min/max 为合法区间）
fn parse_field(
  field : String,
  min : Int32,
  max : Int32,
) -> Result[Array[Int32], String] {
  if field == "*" {
    return Ok([])
  }
  let out : Array[Int32] = []
  for tok_view in field.split(",") {
    let tok = tok_view.to_owned()
    let mut step = 1
    let mut base = tok
    match tok.find("/") {
      Some(idx) => {
        base = tok[:idx].to_owned()
        let step_s = tok[idx + 1:].to_owned()
        match @util.parse_int(step_s) {
          Some(v) =>
            if v < 1 {
              return Err("步长必须 >=1: " + tok)
            } else {
              step = v
            }
          None => return Err("步长非法: " + tok)
        }
      }
      None => ()
    }
    if base == "*" {
      let mut v = min
      while v <= max {
        out.push(v)
        v = v + step
      }
    } else if base.contains("-") {
      let dash : Array[String] = []
      for sv in base.split("-") {
        dash.push(sv.to_owned())
      }
      if dash.length() != 2 {
        return Err("范围非法: " + tok)
      }
      let lo = match @util.parse_int(dash[0]) {
        Some(v) => v
        None => return Err("范围下界非法: " + tok)
      }
      let hi = match @util.parse_int(dash[1]) {
        Some(v) => v
        None => return Err("范围上界非法: " + tok)
      }
      if lo > hi {
        return Err("范围下界大于上界: " + tok)
      }
      let mut v = lo
      while v <= hi {
        out.push(v)
        v = v + step
      }
    } else {
      match @util.parse_int(base) {
        Some(v) =>
          if v < min || v > max {
            return Err(
              "越界: " +
              tok +
              " 应在 " +
              min.to_string() +
              "~" +
              max.to_string(),
            )
          } else {
            out.push(v)
          }
        None => return Err("字段非法: " + tok)
      }
    }
  }
  Ok(out)
}

///|
/// 解析 cron 表达式（5 段）
pub fn CronExpr::parse(s : String) -> Result[CronExpr, String] {
  let parts = tokenize(s)
  if parts.length() != 5 {
    return Err(
      "cron 需 5 段（分 时 日 月 周），实际 " +
      parts.length().to_string() +
      " 段",
    )
  }
  let minute = match parse_field(parts[0], 0, 59) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let hour = match parse_field(parts[1], 0, 23) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let dom = match parse_field(parts[2], 1, 31) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let month = match parse_field(parts[3], 1, 12) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let dow = match parse_field(parts[4], 0, 6) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  Ok({ minute, hour, dom, month, dow, })
}

///|
/// 按空白切分并丢弃空段
fn tokenize(s : String) -> Array[String] {
  let norm = s
    .replace_all(old="\t", new=" ")
    .replace_all(old="\n", new=" ")
    .replace_all(old="\r", new=" ")
  let out : Array[String] = []
  for sv in norm.split(" ") {
    let tok = sv.to_owned()
    if tok != "" {
      out.push(tok)
    }
  }
  out
}

///|
/// 字段集合是否命中某值（空集合 = 匹配任意）
fn field_ok(set : Array[Int32], v : Int32) -> Bool {
  set.is_empty() || set.contains(v)
}

///|
/// 表达式是否命中时间戳
pub fn CronExpr::matches(self : CronExpr, t : Timestamp) -> Bool {
  field_ok(self.minute, t.minute) &&
  field_ok(self.hour, t.hour) &&
  field_ok(self.dom, t.day) &&
  field_ok(self.month, t.month) &&
  field_ok(self.dow, t.weekday)
}

///|
/// 从 from 之后（不含）计算下一个触发时刻（上限约 4 年）
pub fn CronExpr::next_after(
  self : CronExpr,
  from : Timestamp,
) -> Result[Timestamp, String] {
  let mut ms : Int64 = cron_to_ms(from) + CRON_STEP_MS
  let mut iter_count = 0
  let limit = CRON_ITER_LIMIT
  while iter_count < limit {
    let t = ms_to_cron(ms)
    if cron_matches(self, t) {
      return Ok(t)
    }
    ms = ms + CRON_STEP_MS
    iter_count = iter_count + 1
  }
  Err(CRON_YEAR_LIMIT.to_string() + CRON_NO_MATCH_MSG + cron_to_string(self))
}

///|
/// 表达式 → 字符串（用于诊断）
fn cron_matches(expr : CronExpr, t : Timestamp) -> Bool {
  expr.matches(t)
}

///|
/// 表达式 → 字符串表示
fn field_repr(set : Array[Int32]) -> String {
  if set.is_empty() {
    return "*"
  }
  set.map(fn(x) { x.to_string() }).join(",")
}

///|
/// 表达式 → 字符串
pub fn cron_to_string(expr : CronExpr) -> String {
  field_repr(expr.minute) +
  " " +
  field_repr(expr.hour) +
  " " +
  field_repr(expr.dom) +
  " " +
  field_repr(expr.month) +
  " " +
  field_repr(expr.dow)
}

///|
/// 时间戳 → 字符串（用于诊断）
pub fn Timestamp::to_string(self : Timestamp) -> String {
  self.year.to_string() +
  "-" +
  self.month.to_string() +
  "-" +
  self.day.to_string() +
  " " +
  self.hour.to_string() +
  ":" +
  self.minute.to_string() +
  " wd" +
  self.weekday.to_string()
}
