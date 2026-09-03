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
#   - empty effective set         -> remove the block (a block advertising zero repos is noise),
#                                    keeping every byte after the end marker
# Writes only when the bytes actually change, so a re-run leaves `git status --porcelain` empty.
#
# Self-test:  python3 render.py --selftest
import argparse
import json
import os
import re
import sys

BEGIN = "<!-- cross-repo:begin"
END = "<!-- cross-repo:end -->"

# A standalone block, not extra rows spliced into the table above it. Prettier reformats markdown
# tables, and it rewrites a placeholder sitting inside a row into a cell of its own — which
# silently turns the rendered table into a malformed one. Keeping this self-contained, separated by
# blank lines, means the formatter has nothing to mangle in either branch.
GRAPHIFY_BLOCK = (
    "The merged graphify graph covers the in-scope repos too:\n"
    "\n"
    "| Need | Use |\n"
    "| ---- | --- |\n"
    "| find a symbol across the merged graph | "
    "`graphify query '<term>' --graph graphify-out/merged-graph.json` |\n"
    "| shortest path A→B across repos | "
    "`graphify path '<A>' '<B>' --graph graphify-out/merged-graph.json` |"
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
    body = body.replace("{{GRAPHIFY_BLOCK}}", GRAPHIFY_BLOCK if merged else "")
    # The empty branch leaves the placeholder's blank lines behind; collapse them.
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
        # The removal path used to be `head.rstrip("\n") + "\n" if head.strip() else head` — it
        # returned the head and DISCARDED the tail outright: every byte after this block's end
        # marker, deleted, by a script whose header promises "not one byte outside the markers".
        # This is the reachable one. A repo that ran the documented chain (initial-project ->
        # setup-graph-hooks -> setup-handoff) has the handoff routing block sitting directly below
        # this one, so un-declaring the repo from the graph manifest deleted it.
        if not head.strip():
            return rest
        return head.rstrip("\n") + "\n" + ("\n" + rest if rest else "")
    # The separator is owned HERE, not by the tail. `block` ends with exactly one "\n", so
    # returning `tail.lstrip("\n")` bare left NO blank line between this block and whatever
    # followed it — invisible while this was the only managed block, a permanent one-line diff
    # the moment a sibling skill spliced below it. Same defect, same fix, as
    # setup-handoff/scripts/splice-agents-block.py and register-cross-repo-handoff's render.py.
    block = block.rstrip("\n") + "\n"
    return head + block + ("\n" + rest if rest else "")


def _selftest() -> int:
    """python3 render.py --selftest

    This splice is the one the other three were copied FROM, and it kept both halves of the defect
    longest — including the tail-discarding removal, which is data loss, not whitespace. The cases
    mirror register-cross-repo-handoff's render.py, because the two are declared to mirror each
    other and a divergence between them is exactly what went unnoticed for four copies.
    """
    blk = BEGIN + " -->\nbody\n" + END + "\n"

    # Append at EOF, whichever of the three shapes the file ends in.
    assert splice("# A\n", blk) == "# A\n\n" + blk
    assert splice("# A\n\n", blk) == "# A\n\n" + blk
    assert splice("# A", blk) == "# A\n\n" + blk

    # Replace in place, block at EOF.
    one = "# A\n\n" + BEGIN + " -->\nold\n" + END + "\n"
    assert splice(one, blk) == "# A\n\n" + blk
    assert splice(splice(one, blk), blk) == splice(one, blk), "must be idempotent"

    # THE REGRESSION: a sibling skill's managed block directly below this one keeps the blank line
    # that separates them, however ragged the separator was to begin with.
    sib = "<!-- handoff:begin -->\nx\n"
    two = "# A\n\n" + BEGIN + " -->\nold\n" + END + "\n\n" + sib
    got = splice(two, blk)
    assert got == "# A\n\n" + blk + "\n" + sib, repr(got)
    assert splice(got, blk) == got, "idempotent with a sibling block below"
    assert splice("# A\n\n" + BEGIN + " -->\nold\n" + END + "\n\n\n\n" + sib, blk) == got

    # A block whose template left a trailing blank line must not widen the gap on every run.
    assert splice(two, blk + "\n") == got

    # Ordinary prose below the block gets the same one blank line.
    assert splice("# A\n\n" + BEGIN + " -->\no\n" + END + "\nprose\n", blk) \
        == "# A\n\n" + blk + "\nprose\n"

    # REMOVAL keeps every byte outside the markers. Returning `head` alone deleted the tail — and
    # the tail is a sibling skill's routing block in any repo that ran more than one skill.
    assert splice(two, "") == "# A\n\n" + sib, repr(splice(two, ""))
    assert splice(one, "") == "# A\n"
    assert splice(BEGIN + " -->\no\n" + END + "\n\n" + sib, "") == sib
    assert splice("# A\n", "") == "# A\n", "no block, nothing to remove"

    # Malformed marker sets are refused, never guessed at.
    for bad in (BEGIN + " -->\n", END + "\n", BEGIN + " -->\n" + BEGIN + " -->\n" + END + END):
        try:
            splice(bad, blk)
        except ValueError:
            pass
        else:
            raise AssertionError(f"must refuse malformed input: {bad!r}")

    print("render (cross-repo-graph) selftest OK")
    return 0


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
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    raise SystemExit(main())
