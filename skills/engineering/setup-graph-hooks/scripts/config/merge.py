#!/usr/bin/env python3
# merge.py — merge a rendered hook config (read from stdin) into a tool's native settings
# file, replacing only the top-level keys the renderer produced (e.g. "hooks", "version")
# and preserving everything else the user already had. Round-trips JSON; never sed-splices.
#
#   render.py --tool gemini --primary claude | merge.py --file .gemini/settings.json
import argparse
import json
import os
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    args = ap.parse_args()

    try:
        rendered = json.load(sys.stdin)
    except Exception as e:  # noqa: BLE001
        print(f"merge: invalid rendered JSON: {e}", file=sys.stderr)
        return 1
    if not isinstance(rendered, dict):
        print("merge: rendered config is not an object", file=sys.stderr)
        return 1

    target: dict = {}
    if os.path.exists(args.file):
        try:
            with open(args.file) as f:
                loaded = json.load(f)
            target = loaded if isinstance(loaded, dict) else {}
        except Exception:  # noqa: BLE001
            print(f"merge: existing {args.file} is not valid JSON — left untouched", file=sys.stderr)
            return 2

    for k, v in rendered.items():
        target[k] = v

    os.makedirs(os.path.dirname(args.file) or ".", exist_ok=True)
    with open(args.file, "w") as f:
        json.dump(target, f, indent=2)
        f.write("\n")
    print(args.file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
