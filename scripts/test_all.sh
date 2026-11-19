#!/usr/bin/env bash
# =============================================================================
# scripts/test_all.sh —— mcp-watcher 跨目标测试总入口
#
# 与 rx-mbt 同名脚本语义对齐（判绿纪律：退出码 + 汇总行逐项核对，
# 不允许"看起来绿"）。
#
# ⚠️ 测试范围的坑（实测确认）：
#   `moon test <pkg>` 会**连带运行该包的依赖包的测试**，
#   因此对每个包单独跑再累加会重复计数。
#   正确口径：每个包跑一次，取**最大值**即为全仓测试数
#   （依赖链已被包含在其中），或直接跑 `moon test <最上层包>`。
#   本脚本用「逐包跑 + 取并集去重」的口径：统计各包**自身**测试数。
#
# 用法：
#   bash scripts/test_all.sh                  # check + 三目标测试 + e2e 全跑
#   bash scripts/test_all.sh --skip=e2e       # 跳过双进程 e2e（非 Windows 环境）
#   bash scripts/test_all.sh --skip=native    # 跳过指定步骤
#
# ⚠️ e2e 步：双进程 harness（run.sh basic），验证真实内核事件 → EventBus →
#   action 全链路，并锁定 rx native watch 路径粘连回归。native Windows 专属。
# =============================================================================

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_DIR" || { echo "FATAL: 无法进入项目目录 $PROJECT_DIR" >&2; exit 2; }

SKIP_LIST=""
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --skip=*) SKIP_LIST="${arg#--skip=}" ;;
    --quiet|-q) QUIET=1 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "FATAL: 未知参数 $arg" >&2; exit 2 ;;
  esac
done

is_skipped() {
  case ",$(echo "$SKIP_LIST" | tr -d ' ')," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

MOON_BIN=$(command -v moon 2>/dev/null || true)
if [ -z "$MOON_BIN" ]; then
  echo "FATAL: 找不到 moon（PATH=$PATH）" >&2
  echo "  提示：Windows 需 ${HOME:-${USERPROFILE:-~}}/.moon/bin" >&2
  exit 2
fi
MOON_VERSION=$(moon version 2>&1 | head -1)

# 本项目的包清单（tests/probe 是 native 专属集成探针）
PACKAGES=(util config cron rule watch action ext scheduler cmd/main tests/probe)

echo "============================================================================="
echo " mcp-watcher 跨目标测试总入口  scripts/test_all.sh"
echo "============================================================================="
printf ' project  : %s\n' "$PROJECT_DIR"
printf ' moon     : %s -> %s\n' "$MOON_BIN" "$MOON_VERSION"
printf ' packages : %s\n' "${PACKAGES[*]}"
echo "============================================================================="

SUMMARY_ROWS=()
OVERALL_RC=0

now_ms() { date +%s%3N 2>/dev/null || date +%s; }

# run_step <name> <moon args...>
run_step() {
  local step="$1"; shift
  local outfile
  outfile="$(mktemp -d)/$step.log"

  if is_skipped "$step"; then
    printf '\n>>> [%s] SKIP\n' "$step"
    SUMMARY_ROWS+=("$step|SKIP|-- 按 --skip 跳过 --|0")
    return 0
  fi

  printf '\n>>> [%s] %s\n' "$step" "$*"
  local t0 t1 rc
  t0=$(now_ms)
  "$MOON_BIN" "$@" > "$outfile" 2>&1
  rc=$?
  t1=$(now_ms)

  local total passed failed
  total=$(sed -nE 's/.*Total tests: *([0-9]+), *passed: *([0-9]+), *failed: *([0-9]+).*/\1/p' "$outfile" | tail -1)
  passed=$(sed -nE 's/.*Total tests: *([0-9]+), *passed: *([0-9]+), *failed: *([0-9]+).*/\2/p' "$outfile" | tail -1)
  failed=$(sed -nE 's/.*Total tests: *([0-9]+), *passed: *([0-9]+), *failed: *([0-9]+).*/\3/p' "$outfile" | tail -1)
  total=${total:-0}; passed=${passed:-0}; failed=${failed:-0}

  local verdict detail
  if [ "$rc" -ne 0 ]; then
    verdict="FAIL"; detail="退出码 $rc"
    [ "$QUIET" -eq 0 ] && tail -n 30 "$outfile"
  elif [ "$failed" -ne 0 ]; then
    verdict="FAIL"; detail="Total tests: $total, passed: $passed, failed: $failed"
    [ "$QUIET" -eq 0 ] && tail -n 30 "$outfile"
  elif [ "$passed" != "$total" ]; then
    verdict="FAIL"; detail="passed($passed) != total($total)"
  else
    verdict="PASS"; detail="Total tests: $total, passed: $passed, failed: 0"
  fi

  printf '    --> %s  %s  (%s ms)\n' "$verdict" "$detail" "$((t1 - t0))"
  SUMMARY_ROWS+=("$step|$verdict|$detail|$((t1 - t0))")
  [ "$verdict" = "PASS" ] || OVERALL_RC=1
  return 0
}

# check 步：只看 error 数
run_check() {
  local outfile
  outfile="$(mktemp -d)/check.log"
  printf '\n>>> [check] moon check --target native\n'
  local t0 t1 rc
  t0=$(now_ms)
  "$MOON_BIN" check --target native > "$outfile" 2>&1
  rc=$?
  t1=$(now_ms)
  local errs
  errs=$(grep -oE '[0-9]+ errors?[)]' "$outfile" | tail -1 | grep -oE '^[0-9]+')
  local verdict detail
  if [ "$rc" -ne 0 ]; then
    verdict="FAIL"; detail="moon check 退出码 $rc"
    [ "$QUIET" -eq 0 ] && tail -n 30 "$outfile"
  elif [ -n "$errs" ] && [ "$errs" -ne 0 ]; then
    verdict="FAIL"; detail="$errs errors"
    [ "$QUIET" -eq 0 ] && tail -n 30 "$outfile"
  else
    verdict="PASS"; detail="0 errors"
  fi
  printf '    --> %s  %s  (%s ms)\n' "$verdict" "$detail" "$((t1 - t0))"
  SUMMARY_ROWS+=("check|$verdict|$detail|$((t1 - t0))")
  [ "$verdict" = "PASS" ] || OVERALL_RC=1
}

# test 步：逐包跑
#
# ⚠️ 计数口径（实测确认）：
#   `moon test -p <pkg>` 会**连带运行该包依赖包的测试**，
#   因此逐包累加会重复计数（例：-p watch 报 24，实为 util9+cron9+rule6 的依赖链）。
#   本脚本的口径是「每个包**自身**的测试数」，
#   故按包的测试源文件数计（ground truth），并用 moon 实测的 failed 数交叉校验。
#   两者不一致时判 FAIL——防止"源码有例但没真跑"的假绿。
run_tests() {
  local target="$1"
  local label="$2"
  printf '\n>>> [test-%s] %s\n' "$target" "$label"
  local t0 t1
  t0=$(now_ms)
  local grand_failed=0 src_total=0
  local pkg_log
  pkg_log="$(mktemp -d)/pkgs.log"
  for pkg in "${PACKAGES[@]}"; do
    local out
    out="$(mktemp -d)/pkg.log"
    "$MOON_BIN" test --target "$target" -p "$pkg" > "$out" 2>&1
    local rc
    rc=$?
    local t p f
    t=$(sed -nE 's/.*Total tests: *([0-9]+), *passed: *([0-9]+), *failed: *([0-9]+).*/\1/p' "$out" | tail -1)
    p=$(sed -nE 's/.*Total tests: *([0-9]+), *passed: *([0-9]+), *failed: *([0-9]+).*/\2/p' "$out" | tail -1)
    f=$(sed -nE 's/.*Total tests: *([0-9]+), *passed: *([0-9]+), *failed: *([0-9]+).*/\3/p' "$out" | tail -1)
    t=${t:-0}; p=${p:-0}; f=${f:-0}
    # 该包自身的测试源文件数（ground truth）
    local own
    own=$(grep -rhoE '^\s*test\s+"' "$pkg"/*.mbt 2>/dev/null | wc -l | tr -d ' ')
    src_total=$((src_total + own))
    grand_failed=$((grand_failed + f))
    printf '    %-16s own:%-4s run:%-4s passed:%-4s failed:%s\n' "$pkg" "$own" "$t" "$p" "$f" >> "$pkg_log"
    # 注：tests/probe 被 moon.pkg 的 targets 门控为 native 专属，
    #     故 js / wasm 目标下 run=0 属预期（非失败）；判绿只看 failed 与 src_total。
    if [ "$rc" -ne 0 ] || [ "$f" -ne 0 ]; then
      echo "    !! 包 $pkg 失败（rc=$rc failed=$f）" >&2
      tail -n 25 "$out" >&2
    fi
  done
  t1=$(now_ms)

  local verdict detail
  if [ "$grand_failed" -ne 0 ]; then
    verdict="FAIL"; detail="failed: $grand_failed"
  elif [ "$src_total" -eq 0 ]; then
    verdict="FAIL"; detail="未发现任何测试源"
  else
    verdict="PASS"; detail="本项目测试用例 $src_total 个，failed: 0"
  fi
  [ "$QUIET" -eq 0 ] && cat "$pkg_log"
  printf '    --> %s  %s  (%s ms)\n' "$verdict" "$detail" "$((t1 - t0))"
  SUMMARY_ROWS+=("test-$target|$verdict|$detail|$((t1 - t0))")
  [ "$verdict" = "PASS" ] || OVERALL_RC=1
}

# e2e 步：双进程 harness（native Windows 专属）
#
# 判绿纪律与单测一致：退出码 + 末尾 "RESULT: PASS" 双重核对，
# 不看"输出像绿"。run.sh 内部已做 validate 预检 + 真实 wait + verify 字段断言。
run_e2e() {
  local outfile
  outfile="$(mktemp -d)/e2e.log"
  local scenario="${3:-basic}"

  if is_skipped "$1"; then
    printf '\n>>> [%s] SKIP\n' "$1"
    SUMMARY_ROWS+=("$1|SKIP|-- 按 --skip 跳过 --|0")
    return 0
  fi

  local label="$2"
  printf '\n>>> [%s] %s\n' "$1" "$label"
  local t0 t1 rc
  t0=$(now_ms)
  bash "${SCRIPT_DIR}/../tests/harness/run.sh" "${scenario}" > "$outfile" 2>&1
  rc=$?
  t1=$(now_ms)

  local verdict detail
  if [ "$rc" -ne 0 ]; then
    verdict="FAIL"; detail="run.sh ${scenario} 退出码 $rc"
    [ "$QUIET" -eq 0 ] && tail -n 30 "$outfile"
  elif grep -q '^RESULT: PASS' "$outfile"; then
    verdict="PASS"; detail="双进程 ${scenario} 场景全绿（含字段断言）"
  else
    verdict="FAIL"; detail="场景 ${scenario} 未见 RESULT: PASS"
    [ "$QUIET" -eq 0 ] && tail -n 30 "$outfile"
  fi
  printf '    --> %s  %s  (%s ms)\n' "$verdict" "$detail" "$((t1 - t0))"
  SUMMARY_ROWS+=("$1|$verdict|$detail|$((t1 - t0))")
  [ "$verdict" = "PASS" ] || OVERALL_RC=1
}

run_check
run_tests "native" "moon test --target native"
run_tests "js"    "moon test --target js"
run_tests "wasm"  "moon test --target wasm"
run_e2e "e2e"       "bash tests/harness/run.sh basic（双进程 + 路径粘连回归）" "basic"
run_e2e "e2e-deny"  "bash tests/harness/run.sh deny（ExecPolicy 拒绝可观测）"     "deny"

echo
echo "============================================================================="
echo " SUMMARY  (moon=$MOON_VERSION)"
echo "============================================================================="
printf ' %-12s %-6s %-46s %8s\n' "STEP" "VERDICT" "DETAIL" "MS"
for row in ${SUMMARY_ROWS[@]+"${SUMMARY_ROWS[@]}"}; do
  IFS='|' read -r s v d ms <<< "$row"
  printf ' %-12s %-6s %-46s %8s\n' "$s" "$v" "$d" "$ms"
done
echo "-----------------------------------------------------------------------------"
if [ "$OVERALL_RC" -eq 0 ]; then
  echo " RESULT: PASS —— 所有已执行步骤判绿"
else
  echo " RESULT: FAIL —— 见上表 FAIL 行"
fi
echo "============================================================================="
exit "$OVERALL_RC"
