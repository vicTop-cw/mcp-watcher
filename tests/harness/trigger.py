#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mcp-watcher 集成测试 · 触发程序（Trigger）
========================================
职责：作为"另外一个程序"，按场景脚本对目标目录做真实的文件系统变更，
      从而驱动正在监听的 mcp-watcher server 触发其规则。

设计约束（用户要求）：测试必须是「一个服务器开着，另一个程序去做触发」。
本程序就是那个"另一个程序"——它不依赖 mcp-watcher 是否已实现，
只负责制造文件系统事件。

用法：
  python3 trigger.py --dir <被监听目录> --scenario <scenario.json> [--dry-run]

依赖：仅 Python 3 标准库（pathlib / json / time / argparse），跨平台。
"""
import argparse
import json
import sys
import time
from pathlib import Path


def resolve(base: Path, rel: str) -> Path:
    p = Path(rel)
    return p if p.is_absolute() else base / p


def do_op(base: Path, op: dict, dry_run: bool) -> dict:
    kind = op.get("op")
    sleep_ms = op.get("ms") or op.get("sleep_ms")
    if kind == "sleep" or sleep_ms is not None:
        ms = int(sleep_ms if kind == "sleep" else sleep_ms)
        if not dry_run:
            time.sleep(ms / 1000.0)
        return {"op": "sleep", "ms": ms}

    path = resolve(base, op["path"])
    rec = {"op": kind, "path": str(path)}

    if kind == "create":
        content = op.get("content", "")
        if not dry_run:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        rec["bytes"] = len(content.encode("utf-8"))

    elif kind == "modify":
        content = op.get("content", "")
        append = bool(op.get("append", False))
        if not dry_run:
            path.parent.mkdir(parents=True, exist_ok=True)
            if append and path.exists():
                old = path.read_text(encoding="utf-8")
                path.write_text(old + content, encoding="utf-8")
            else:
                path.write_text(content, encoding="utf-8")
        rec["append"] = append

    elif kind == "rename":
        target = resolve(base, op["to"])
        if not dry_run:
            path.parent.mkdir(parents=True, exist_ok=True)
            target.parent.mkdir(parents=True, exist_ok=True)
            path.rename(target)
        rec["to"] = str(target)

    elif kind == "delete":
        if not dry_run and path.exists():
            path.unlink()

    elif kind == "mkdir":
        if not dry_run:
            path.mkdir(parents=True, exist_ok=True)

    elif kind == "rmdir":
        if not dry_run and path.exists():
            try:
                path.rmdir()
            except OSError:
                import shutil
                shutil.rmtree(path)

    else:
        raise SystemExit(f"[trigger] 未知 op: {kind}")
    return rec


def main(argv=None):
    ap = argparse.ArgumentParser(description="mcp-watcher 集成测试触发程序")
    ap.add_argument("--dir", required=True, help="被监听的目标目录（绝对或相对）")
    ap.add_argument("--scenario", required=True, help="场景 JSON 文件路径")
    ap.add_argument("--dry-run", action="store_true",
                    help="只打印将做什么，不真正改动文件")
    args = ap.parse_args(argv)

    scenario_path = Path(args.scenario)
    if not scenario_path.exists():
        raise SystemExit(f"[trigger] 场景文件不存在: {scenario_path}")
    scenario = json.loads(scenario_path.read_text(encoding="utf-8"))
    base = Path(args.dir)
    if not args.dry_run:
        base.mkdir(parents=True, exist_ok=True)

    print(f"[trigger] scenario={scenario.get('name', '?')} dir={base} dry_run={args.dry_run}")
    done = []
    for op in scenario.get("ops", []):
        rec = do_op(base, op, args.dry_run)
        done.append(rec)
        print(f"[trigger] -> {rec}")
    print(f"[trigger] 完成，共 {len(done)} 步操作")
    print("TRIGGER_MANIFEST:" + json.dumps(done, ensure_ascii=False))


if __name__ == "__main__":
    main()
