#!/bin/bash
# mcp-watcher 双进程集成测试（P0 验收 · server test-mode）
#
# 用法：./run.sh [scenario]
#   scenario - 场景名（basic / demo-rules，默认 basic）
#
# 架构：一个 server 进程常驻监听，另一个 trigger 进程制造真实文件事件。
# 对齐 tests/harness/server_contract.md。
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/../.."
# native 可执行文件依赖内置 SQLite DLL
export PATH="${PROJECT_DIR}/sqlite/vendor:$PATH"
# moon.work 位于项目上一级时，native 产物可能落在工作区或项目 _build 下，
# 用 glob 兜底定位（避免硬编码绝对路径）
WORK_DIR="$(cd "${PROJECT_DIR}/.." && pwd)"
BIN=""
for cand in "${PROJECT_DIR}/_build" "${WORK_DIR}/_build"; do
  hit="$(find "${cand}" -path '*/cmd/main/*.exe' -type f 2>/dev/null | head -n1)"
  if [ -n "${hit}" ]; then BIN="${hit}"; break; fi
done

SCENARIO="${1:-basic}"
WATCH_DIR="${SCRIPT_DIR}/.watch"
SCENARIO_FILE="${SCRIPT_DIR}/scenarios/${SCENARIO}.json"
# 规则文件与场景文件分离：p0-smoke 用单规则 cleanup，basic 用双规则
case "${SCENARIO}" in
  p0-smoke) RULES_FILE="${SCRIPT_DIR}/scenarios/demo-rules.json" ;;
  basic)    RULES_FILE="${SCRIPT_DIR}/scenarios/basic-rules.json" ;;
  *)        RULES_FILE="${SCRIPT_DIR}/scenarios/${SCENARIO}-rules.json" ;;
esac
RESULTS_FILE="${SCRIPT_DIR}/.results.jsonl"
READY_FILE="${SCRIPT_DIR}/.ready"

# 清理旧文件
rm -rf "${WATCH_DIR}"
rm -f "${RESULTS_FILE}"
rm -f "${READY_FILE}"
mkdir -p "${WATCH_DIR}"

echo "=== 构建 native ==="
cd "${PROJECT_DIR}"
# 仅构建最终可执行文件：sqlite/index 库包的 link flags 会让库包自身的可执行包装失败
moon build --target native cmd/main

if [ ! -f "${BIN}" ]; then
  echo "找不到 native 产物：${BIN}"
  exit 1
fi

echo "=== 预检规则文件 ==="
"${BIN}" validate --rules "${RULES_FILE}" || exit 1

# stop-after 取场景期望条数（expect 数组长度），避免多事件场景过早退出
STOP_AFTER=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1],encoding='utf-8')).get('expect',[])))" "${SCENARIO_FILE}")
echo "=== 启动 server（test-mode，stop-after=${STOP_AFTER}） ==="
"${BIN}" run \
  --rules "${RULES_FILE}" \
  --watch-dir "${WATCH_DIR}" \
  --results "${RESULTS_FILE}" \
  --ready "${READY_FILE}" \
  --stop-after "${STOP_AFTER}" &
SERVER_PID=$!

echo "=== 等待服务器就绪 ==="
ready_ok=0
for i in $(seq 1 30); do
  if [ -f "${READY_FILE}" ]; then
    ready_ok=1
    break
  fi
  sleep 1
  if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    echo "服务器进程在就绪前已退出"
    exit 1
  fi
done
if [ "${ready_ok}" -ne 1 ]; then
  echo "服务器就绪超时"
  kill "${SERVER_PID}" 2>/dev/null || true
  exit 1
fi
echo "服务器已就绪（PID=${SERVER_PID}）"

echo "=== 运行触发器（独立进程） ==="
python3 "${SCRIPT_DIR}/trigger.py" --dir "${WATCH_DIR}" --scenario "${SCENARIO_FILE}"

echo "=== 等待服务器优雅退出（stop-after） ==="
wait "${SERVER_PID}"
echo "服务器已退出"

echo "=== 验证结果 ==="
python3 "${SCRIPT_DIR}/verify.py" --results "${RESULTS_FILE}" --scenario "${SCENARIO_FILE}"

echo "=== 测试完成 ==="
