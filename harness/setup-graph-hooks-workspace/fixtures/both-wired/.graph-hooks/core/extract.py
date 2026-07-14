#!/usr/bin/env python3
# extract.py — pull a field out of ANY tool's hook stdin payload, protocol-aware.
#
#   extract.py --tool <name> --field <command|readtarget>
#
# Half of the per-tool protocol table (the other half is emit.py). Reads the tool's
# hook JSON on stdin and prints the requested field as plain text — which the behavior
# cores consume without knowing which tool produced it.
#
# The container of tool arguments differs by tool:
#   Claude / Gemini / Antigravity -> "tool_input"   (snake_case)
#   GitHub Copilot                -> "toolArgs"      (camelCase)
# Extraction is shape-tolerant (it tries both, then top level), so a contract drift in
# one tool degrades to "no match" rather than a crash. --tool is accepted for clarity
# and future per-tool divergence.
import argparse
import json
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tool", default="")
    ap.add_argument("--field", required=True, choices=["command", "readtarget"])
    args = ap.parse_args()

    try:
        payload = json.loads(sys.stdin.read())
    except Exception:
        return 0
    if not isinstance(payload, dict):
        return 0

    ti = payload.get("tool_input")
    if ti is None:
        ti = payload.get("toolArgs")
    if ti is None:
        ti = payload
    if not isinstance(ti, dict):
        return 0

    if args.field == "command":
        print(ti.get("command", "") or "")
    elif args.field == "readtarget":
        parts = [
            str(ti.get("file_path") or ""),
            str(ti.get("pattern") or ""),
            str(ti.get("path") or ""),
        ]
        print(" ".join(p for p in parts if p))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
