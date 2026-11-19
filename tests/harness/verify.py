#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mcp-watcher 集成测试 · 对拍程序（Verify）
=======================================
职责：读取 server 写出的结果 JSONL，与场景中的 expect 比对，输出 PASS/FAIL。

结果 JSONL：每行一个 JSON 对象（字段来自 scheduler 的 ExecRecord，真实执行写入）：
  {"rule_id":"cleanup","event":"create","path":"...\\scratch.tmp",
   "action_type":"command","exit":0,"stdout":"cleanup\\r\\n","stderr":"",
   "ts":1794882456711}

用法：
  python3 verify.py --results <results.jsonl> --scenario <scenario.json> [--strict]

  --strict：要求结果集与期望完全一致（不允许出现期望之外的额外结果）。
退出码：PASS=0，FAIL=1。

断言强度（2026-11-17 加强）：
  - 必填字段完整性：每条结果必须含 rule_id/event/path/action_type/exit/stdout/stderr，
    缺失即 FAIL（防止"结果落盘但字段是猜测值"的结构缺陷复发）。
  - 精确字段：rule_id / event / action_type / exit 完全一致。
  - 子串字段：path（Windows 分隔符 / 绝对路径差异）、stdout / stderr（允许包含断言）。
    期望值用 {"$contains": "..."} 显式声明子串语义，否则默认精确。
"""
import argparse
import json
import sys
from pathlib import Path

REQUIRED_FIELDS = ("rule_id", "event", "path", "action_type", "exit", "stdout", "stderr")
EXACT_KEYS = ("rule_id", "event", "action_type", "exit")


def load_results(path: Path):
    if not path.exists():
        raise SystemExit(f"[verify] 结果文件不存在: {path}")
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        rows.append(json.loads(line))
    return rows


def _basename(path: str) -> str:
    """取路径的文件名部分，兼容 Windows \\ 与 POSIX / 分隔符。"""
    return path.replace("\\", "/").rsplit("/", 1)[-1]


def field_matches(actual, expected) -> bool:
    """支持精确与 {"$contains": s} 两种断言。"""
    if isinstance(expected, dict) and "$contains" in expected:
        return isinstance(actual, str) and expected["$contains"] in actual
    return actual == expected


def match(result: dict, exp: dict) -> bool:
    for key, want in exp.items():
        if key == "rule_id" or key == "event" or key == "action_type" or key == "exit":
            if not field_matches(result.get(key), want):
                return False
        elif key == "path":
            # path 比较文件名部分（basename），容忍绝对路径前缀与 \ / 分隔符差异。
            # 用精确相等而非子串：这是路径粘连 bug 的检测点——
            # 期望 keep.md 时，粘连后的 keep.md.tmp 必须判 FAIL。
            actual = result.get("path")
            base = _basename(actual) if isinstance(actual, str) else None
            if not field_matches(base, want):
                return False
        elif key == "stdout" or key == "stderr":
            if not field_matches(result.get(key), want):
                return False
        # 其它未知 key 忽略（场景文件可能带注释性字段）
    return True


def check_schema(results) -> list:
    """返回结构缺陷描述列表。"""
    defects = []
    for i, r in enumerate(results):
        missing = [k for k in REQUIRED_FIELDS if k not in r]
        if missing:
            defects.append(f"第 {i+1} 条结果缺字段 {missing}: {json.dumps(r, ensure_ascii=False)}")
    return defects


def main(argv=None):
    ap = argparse.ArgumentParser(description="mcp-watcher 集成测试对拍")
    ap.add_argument("--results", required=True, help="server 写出的结果 JSONL")
    ap.add_argument("--scenario", required=True, help="场景 JSON 文件")
    ap.add_argument("--strict", action="store_true",
                    help="要求结果集与期望完全一致（无多余）")
    args = ap.parse_args(argv)

    results = load_results(Path(args.results))
    scenario = json.loads(Path(args.scenario).read_text(encoding="utf-8"))
    expects = scenario.get("expect", [])

    defects = check_schema(results)
    unmatched = list(expects)
    extra = []
    for r in results:
        hit = None
        for i, e in enumerate(unmatched):
            if match(r, e):
                hit = i
                break
        if hit is not None:
            unmatched.pop(hit)
        else:
            extra.append(r)

    ok = (not defects) and (not unmatched) and (not args.strict or not extra)
    print("=" * 56)
    print(f"场景: {scenario.get('name', '?')}   结果条数: {len(results)}")
    if defects:
        print("FAIL  结果结构缺陷:")
        for d in defects:
            print("   ! " + d)
    if not unmatched:
        print("PASS  全部期望命中")
    else:
        print("FAIL  未命中期望:")
        for e in unmatched:
            print("   - " + json.dumps(e, ensure_ascii=False))
    if extra:
        print("INFO 额外结果:")
        for r in extra:
            print("   + " + json.dumps(r, ensure_ascii=False))
    print("=" * 56)
    print("RESULT: " + ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
