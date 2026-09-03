#!/usr/bin/env python3
# splice-agents-block.py — render the AGENTS.md handoff routing block and splice it into the
# target repo's AGENTS.md in place, touching not one byte outside the markers.
#
#   splice-agents-block.py --file <repo>/AGENTS.md --template assets/agents-handoff.md \
#                          --handoff-dir <path-the-repo-uses-to-reach-the-board> [--dry-run|--check]
#
# --check writes nothing and reports drift by exit code, so verify-setup-handoff.sh can compare the
# installed block against the asset without carrying a second copy of the marker/render semantics:
#   0 current   2 drifted   3 missing   1 malformed or unreadable
#
# Self-test:  python3 splice-agents-block.py --selftest
#
# The block is declared "managed by setup-handoff — do not edit between markers", so the installer
# owes it a rewrite on every run: before this existed the installer only injected the block when it
# was ABSENT, which meant a repo that installed once kept the old text forever and re-running the
# installer silently did nothing. See agents-block-drift-handoff.
#
# Splice rules (a string splice, never sed) mirror register-cross-repo-handoff's render.py:
#   - exactly one begin/end pair  -> replace the span
#   - no markers                  -> append after one blank line at EOF
#   - unbalanced / duplicated     -> refuse, exit 1 (a human must fix it)
# Writes only when the bytes change, so a re-run leaves `git status --porcelain` empty.
#
# The markers carry their `<!-- ` opener on purpose: `handoff:begin` alone is a substring of
# `cross-repo-handoff:begin`, so a bare match would mistake a sibling skill's block for this one.
import argparse
import sys

BEGIN = "<!-- handoff:begin"
END = "<!-- handoff:end -->"


def render(template: str, handoff_dir: str) -> str:
    return template.replace("PLACEHOLDER_HANDOFF_DIR", handoff_dir)


def splice(existing: str, block: str) -> str:
    n_begin, n_end = existing.count(BEGIN), existing.count(END)
    if n_begin != n_end or n_begin > 1:
        raise ValueError(
            f"malformed managed block in AGENTS.md ({n_begin} begin / {n_end} end markers) — fix by hand"
        )
    if n_begin == 0:
        sep = "" if existing.endswith("\n\n") else ("\n" if existing.endswith("\n") else "\n\n")
        return existing + sep + block
    head = existing[: existing.index(BEGIN)]
    tail = existing[existing.index(END) + len(END):]
    rest = tail.lstrip("\n")
    # The separator is owned HERE, not by the tail. `block` ends with exactly one "\n", so
    # returning `tail.lstrip("\n")` bare left NO blank line between this block and whatever
    # followed it. That was invisible while this was the only managed block in the file, and it
    # became a permanent one-line diff the moment a sibling skill spliced a block directly below
    # (register-cross-repo-handoff does exactly that). Each sync then flipped the line back and
    # forth, so `sync-cross-repo-handoff.sh` was never idempotent across every member repo —
    # contradicting the promise four lines up, and dirtying four repos on every re-run.
    return head + block + ("\n" + rest if rest else "")


def _selftest() -> int:
    """python3 splice-agents-block.py --selftest

    The splice is a pure function over strings, and every defect it has had was a whitespace
    invariant that no integration test could name. The fleet grader DID catch the missing blank
    line, but only as "M AGENTS.md" after a two-minute four-repo sync — which is how it went
    unexplained. These run in milliseconds and say which rule broke.
    """
    blk = BEGIN + " -->\nbody\n" + END + "\n"

    # Append at EOF, with the three shapes the existing file can end in.
    assert splice("# A\n", blk) == "# A\n\n" + blk
    assert splice("# A\n\n", blk) == "# A\n\n" + blk
    assert splice("# A", blk) == "# A\n\n" + blk
    assert splice("", blk) == "\n\n" + blk or splice("", blk).endswith(blk)

    # Replace in place, block at EOF.
    one = "# A\n\n" + BEGIN + " -->\nold\n" + END + "\n"
    assert splice(one, blk) == "# A\n\n" + blk
    assert splice(splice(one, blk), blk) == splice(one, blk), "must be idempotent"

    # THE REGRESSION: a sibling skill's managed block directly below this one. The blank line
    # between them is ours to keep — without it, each sync flipped that line and no member repo
    # of a synced fleet was ever clean after a re-run.
    sib = "<!-- cross-repo-handoff:begin -->\nx\n"
    two = "# A\n\n" + BEGIN + " -->\nold\n" + END + "\n\n" + sib
    got = splice(two, blk)
    assert got == "# A\n\n" + blk + "\n" + sib, repr(got)
    assert splice(got, blk) == got, "idempotent with a sibling block below"
    # And it holds however ragged the separator was to begin with.
    assert splice("# A\n\n" + BEGIN + " -->\nold\n" + END + "\n\n\n\n" + sib, blk) == got

    # Ordinary prose below the block gets the same one blank line.
    assert splice("# A\n\n" + BEGIN + " -->\no\n" + END + "\nprose\n", blk) \
        == "# A\n\n" + blk + "\nprose\n"

    # Malformed marker sets are refused, never guessed at.
    for bad in (BEGIN + " -->\n", END + "\n", BEGIN + " -->\n" + BEGIN + " -->\n" + END + END):
        try:
            splice(bad, blk)
        except ValueError:
            pass
        else:
            raise AssertionError(f"must refuse malformed input: {bad!r}")

    print("splice-agents-block selftest OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True, help="target repo's AGENTS.md")
    ap.add_argument("--template", required=True, help="assets/agents-handoff.md")
    ap.add_argument("--handoff-dir", required=True, help="path the repo uses to reach the board")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--check", action="store_true", help="report drift by exit code, write nothing")
    a = ap.parse_args()

    try:
        with open(a.template, encoding="utf-8") as f:
            template = f.read()
    except OSError as e:
        print(f"setup-handoff: cannot read block template: {e}", file=sys.stderr)
        return 1

    block = render(template, a.handoff_dir).strip() + "\n"

    try:
        with open(a.file, encoding="utf-8") as f:
            existing = f.read()
    except FileNotFoundError:
        existing = ""
    except OSError as e:
        print(f"setup-handoff: cannot read {a.file}: {e}", file=sys.stderr)
        return 1

    try:
        updated = splice(existing, block)
    except ValueError as e:
        print(f"setup-handoff: {e}", file=sys.stderr)
        return 1

    if a.check:
        if BEGIN not in existing:
            return 3
        return 0 if updated == existing else 2

    if updated == existing:
        print("  AGENTS.md routing block already current")
        return 0
    if a.dry_run:
        print("  AGENTS.md routing block would be updated (--dry-run)")
        return 0

    try:
        with open(a.file, "w", encoding="utf-8") as f:
            f.write(updated)
    except OSError as e:
        print(f"setup-handoff: cannot write {a.file}: {e}", file=sys.stderr)
        return 1

    print("  injected AGENTS.md routing block" if BEGIN not in existing
          else "  refreshed AGENTS.md routing block")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    sys.exit(main())
