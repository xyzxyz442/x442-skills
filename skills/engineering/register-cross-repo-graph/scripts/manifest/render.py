#!/usr/bin/env python3
# render.py — render the AGENTS.md cross-repo block from the effective set and splice it into the
# file IN PLACE, touching not one byte outside the markers.
#
#   resolve.py --scope … --root … \
#     | render.py --template assets/agents-cross-repo.md --file AGENTS.md \
#                 --confirmed acme-api,acme-ds --merged acme-api [--dry-run]
#
# --confirmed / --merged are the aliases the sync script CONFIRMED after the fact: read back out of
# CRG's registry, and actually folded into the merged graph. The block is rendered from those, not
# from what we intended to register — so the block can never advertise an alias that will not
# answer.
#
# Splice rules (a string splice, never sed):
#   - exactly one begin/end pair  -> replace the span
#   - no markers                  -> append after one blank line at EOF
#   - unbalanced / duplicated     -> refuse, exit 1 (a human must fix it)
#   - empty effective set         -> remove the block (a block advertising zero repos is noise)
# Writes only when the bytes actually change, so a re-run leaves `git status --porcelain` empty.
import argparse
import json
import os
import sys

BEGIN = "<!-- cross-repo:begin"
END = "<!-- cross-repo:end -->"

GRAPHIFY_ROWS = (
    "| find a symbol across the merged graph | "
    "`graphify query '<term>' --graph graphify-out/merged-graph.json` |\n"
    "| shortest path A→B across repos  | "
    "`graphify path '<A>' '<B>' --graph graphify-out/merged-graph.json` |\n"
)


def render(data: dict, template: str, confirmed: set[str], merged: set[str]) -> str:
    listed = [e for e in data["effective"] if e["alias"] in confirmed or e["alias"] in merged]
    listed.sort(key=lambda e: e["alias"])
    if not listed:
        return ""

    rows = ["| Alias | Repo path | What lives there |", "| ----- | --------- | ---------------- |"]
    for e in listed:
        notes = e.get("notes") or "—"
        rows.append(f"| `{e['alias']}` | `{e['path']}` | {notes} |")

    body = template
    body = body.replace("{{SCOPE}}", data.get("scope_rel") or ".")
    body = body.replace("{{REPO_TABLE}}", "\n".join(rows))
    body = body.replace("{{IN_SCOPE_ALIASES}}", ", ".join(f"`{e['alias']}`" for e in listed))
    # Never advertise a tool that no in-scope repo actually uses.
    body = body.replace("{{GRAPHIFY_ROWS}}", GRAPHIFY_ROWS if merged else "")
    return body


def splice(existing: str, block: str) -> str:
    n_begin, n_end = existing.count(BEGIN), existing.count(END)
    if n_begin != n_end or n_begin > 1:
        raise ValueError(
            f"malformed managed block in AGENTS.md ({n_begin} begin / {n_end} end markers) — fix by hand"
        )
    if n_begin == 0:
        if not block:
            return existing
        sep = "" if existing.endswith("\n\n") else ("\n" if existing.endswith("\n") else "\n\n")
        return existing + sep + block
    head = existing[: existing.index(BEGIN)]
    tail = existing[existing.index(END) + len(END):]
    if not block:
        # Removing the block: collapse the blank line it left behind, keep a single trailing newline.
        return head.rstrip("\n") + "\n" if head.strip() else head
    return head + block + tail.lstrip("\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", required=True)
    ap.add_argument("--file", required=True)
    ap.add_argument("--confirmed", default="")
    ap.add_argument("--merged", default="")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    data = json.load(sys.stdin)
    confirmed = {a for a in args.confirmed.split(",") if a}
    merged = {a for a in args.merged.split(",") if a}

    with open(args.template) as f:
        template = f.read()

    block = render(data, template, confirmed, merged)
    if block and not block.endswith("\n"):
        block += "\n"

    existing = ""
    if os.path.exists(args.file):
        with open(args.file) as f:
            existing = f.read()
    elif not args.dry_run:
        print(f"render: {args.file} does not exist — run initial-project first", file=sys.stderr)
        return 1

    try:
        updated = splice(existing, block)
    except ValueError as e:
        print(f"render: {e}", file=sys.stderr)
        return 1

    if updated == existing:
        print(f"  = {args.file} cross-repo block up to date")
        return 0
    verb = "removed" if not block else ("added" if BEGIN not in existing else "updated")
    if args.dry_run:
        print(f"  would: {verb} cross-repo block in {args.file}")
        return 0
    with open(args.file, "w") as f:
        f.write(updated)
    print(f"  ~ {args.file} cross-repo block {verb}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
