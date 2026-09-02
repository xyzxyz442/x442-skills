#!/usr/bin/env python3
# render.py — render the AGENTS.md cross-repo-handoff block for ONE member repo and splice it into
# that repo's AGENTS.md in place, touching not one byte outside the markers.
#
#   resolve.py --scope … | render.py --file <repo>/AGENTS.md --template assets/agents-cross-repo-handoff.md \
#                 --group <g> --self <alias> --board-rel <path-the-repo-uses-to-reach-the-board> [--dry-run]
#
# The block tells this repo which shared board + section it coordinates on, and who its peers are, so
# it files handoffs with the right `audience:` and never greps a sibling checkout it should coordinate
# with instead. Rendered from the RESOLVED set (stdin), so it can never advertise a peer that is not
# actually in scope.
#
# Splice rules (a string splice, never sed) mirror register-cross-repo-graph:
#   - exactly one begin/end pair  -> replace the span
#   - no markers                  -> append after one blank line at EOF
#
# Self-test:  python3 render.py --selftest
#   - unbalanced / duplicated     -> refuse, exit 1 (a human must fix it)
#   - group no longer in scope    -> remove the block
# Writes only when the bytes change, so a re-run leaves `git status --porcelain` empty.
import argparse
import json
import os
import re
import sys

BEGIN = "<!-- cross-repo-handoff:begin"
END = "<!-- cross-repo-handoff:end -->"


def render(data: dict, template: str, group: str, board_rel: str, self_alias: str) -> str:
    g = next((x for x in data.get("groups", []) if x["group"] == group), None)
    if g is None:
        return ""
    members = sorted(g["members"], key=lambda m: m["alias"])
    rows = ["| Repo | Acts-next name (`audience:`) | What lives there |",
            "| ---- | --------------------------- | ---------------- |"]
    for m in members:
        notes = m.get("notes") or "—"
        mark = " ← this repo" if m["alias"] == self_alias else ""
        rows.append(f"| `{m['alias']}`{mark} | `{m['audience']}` | {notes} |")
    peers = [m["audience"] for m in members if m["alias"] != self_alias]
    body = template
    body = body.replace("{{GROUP}}", group)
    body = body.replace("{{LAYOUT}}", g.get("layout", "subfolder"))
    body = body.replace("{{BOARD}}", board_rel)
    body = body.replace("{{PEER_TABLE}}", "\n".join(rows))
    body = body.replace("{{PEERS}}", ", ".join(f"`{p}`" for p in peers) if peers else "— (no peers yet)")
    return re.sub(r"\n{3,}", "\n\n", body)


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
    rest = tail.lstrip("\n")
    if not block:
        # The removal path used to return `head` and DISCARD the tail outright — every byte after
        # this block's end marker, deleted, in a script whose whole contract is "touching not one
        # byte outside the markers". Unreached only because this block is appended last today; a
        # sibling skill splicing below it would have lost its block on the next un-declare.
        if not head.strip():
            return rest
        return head.rstrip("\n") + "\n" + ("\n" + rest if rest else "")
    # The separator is owned here, not by the tail — see splice-agents-block.py, which had the
    # same defect and is where it actually fired.
    block = block.rstrip("\n") + "\n"
    return head + block + ("\n" + rest if rest else "")


def _selftest() -> int:
    """python3 render.py --selftest

    Mirrors splice-agents-block.py's selftest, because the two splices are declared to mirror each
    other and both carried the same separator defect. This one additionally covers the removal
    path, which used to discard every byte after the end marker.
    """
    blk = BEGIN + " -->\nbody\n" + END + "\n"

    assert splice("# A\n", blk) == "# A\n\n" + blk
    assert splice("# A\n\n", blk) == "# A\n\n" + blk
    assert splice("# A", blk) == "# A\n\n" + blk

    one = "# A\n\n" + BEGIN + " -->\nold\n" + END + "\n"
    assert splice(one, blk) == "# A\n\n" + blk
    assert splice(splice(one, blk), blk) == splice(one, blk), "must be idempotent"

    # A sibling managed block below this one keeps its separating blank line.
    sib = "<!-- handoff:begin -->\nx\n"
    two = "# A\n\n" + BEGIN + " -->\nold\n" + END + "\n\n" + sib
    got = splice(two, blk)
    assert got == "# A\n\n" + blk + "\n" + sib, repr(got)
    assert splice(got, blk) == got, "idempotent with a sibling block below"

    # A block whose template left a trailing blank line must not widen the gap on every run.
    assert splice(two, blk + "\n") == got

    # REMOVAL keeps everything outside the markers. Returning `head` alone deleted the tail.
    assert splice(two, "") == "# A\n\n" + sib, repr(splice(two, ""))
    assert splice(one, "") == "# A\n"
    assert splice(BEGIN + " -->\no\n" + END + "\n\n" + sib, "") == sib
    assert splice("# A\n", "") == "# A\n", "no block, nothing to remove"

    for bad in (BEGIN + " -->\n", END + "\n", BEGIN + " -->\n" + BEGIN + " -->\n" + END + END):
        try:
            splice(bad, blk)
        except ValueError:
            pass
        else:
            raise AssertionError(f"must refuse malformed input: {bad!r}")

    print("render selftest OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", required=True)
    ap.add_argument("--file", required=True)
    ap.add_argument("--group", required=True)
    ap.add_argument("--self", dest="self_alias", required=True)
    ap.add_argument("--board-rel", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    data = json.load(sys.stdin)
    with open(args.template) as f:
        template = f.read()

    block = render(data, template, args.group, args.board_rel, args.self_alias)
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
        print(f"  = {args.file} cross-repo-handoff block up to date")
        return 0
    verb = "removed" if not block else ("added" if BEGIN not in existing else "updated")
    if args.dry_run:
        print(f"  would: {verb} cross-repo-handoff block in {args.file}")
        return 0
    with open(args.file, "w") as f:
        f.write(updated)
    print(f"  ~ {args.file} cross-repo-handoff block {verb}")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    raise SystemExit(main())
