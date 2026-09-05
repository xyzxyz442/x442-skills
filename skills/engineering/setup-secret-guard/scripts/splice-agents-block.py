#!/usr/bin/env python3
# splice-agents-block.py — splice the AGENTS.md secret-guard routing block into the target
# repo's AGENTS.md in place, touching not one byte outside the markers.
#
#   splice-agents-block.py --file <repo>/AGENTS.md --block assets/agents-secret-guard.md [--dry-run]
#
# Self-test:  python3 splice-agents-block.py --selftest
#
# This skill (setup-secret-guard) wires credential-file read redaction into a repo and injects a
# short "secrets are redacted, not blocked" note into AGENTS.md so agents know reads are routed
# through a redacting viewer instead of failing outright. The installer owes that block a rewrite
# on every run — see the splice rules below.
#
# Splice rules (a string splice, never sed) mirror setup-graph-hooks's and setup-handoff's
# splice-agents-block.py:
#   - exactly one begin/end pair  -> replace the span
#   - no markers                  -> append after one blank line at EOF
#   - unbalanced / duplicated     -> refuse, exit 1 (a human must fix it)
# The block is declared "managed by setup-secret-guard — do not edit between markers", so the
# installer owes it a rewrite on every run; an append-only guard strands every repo that installed
# an earlier revision on stale routing. Writes only when the bytes change, so a re-run leaves
# `git status --porcelain` empty.
import argparse
import sys

BEGIN = "<!-- secret-guard:begin"
END = "<!-- secret-guard:end -->"


def splice(existing: str, block: str) -> str:
    n_begin, n_end = existing.count(BEGIN), existing.count(END)
    if n_begin != n_end or n_begin > 1:
        raise ValueError(
            f"malformed managed block in AGENTS.md ({n_begin} begin / {n_end} end markers) — fix by hand"
        )
    if n_begin == 0:
        sep = (
            ""
            if existing.endswith("\n\n")
            else ("\n" if existing.endswith("\n") else "\n\n")
        )
        return (existing + sep + block) if existing.strip() else block
    head = existing[: existing.index(BEGIN)]
    tail = existing[existing.index(END) + len(END) :]
    rest = tail.lstrip("\n")
    # The separator is owned HERE, not by the tail. A bare `tail.lstrip("\n")` return leaves no
    # blank line between this block and a sibling skill's block below it — and setup-graph-hooks
    # or setup-handoff may splice exactly there. Each re-run would then flip that line, so no repo
    # wired for multiple managed blocks would ever be byte-stable.
    block = block.rstrip("\n") + "\n"
    return head + block + ("\n" + rest if rest else "")


def _selftest() -> int:
    """python3 splice-agents-block.py --selftest

    The same seven cases setup-graph-hooks's and setup-handoff's splices assert, because all three
    splices are declared to mirror each other and the divergence between them is what went
    unnoticed across earlier copies.
    """
    blk = BEGIN + " -->\nbody\n" + END + "\n"

    # Append at EOF, whichever of the three shapes the file ends in.
    assert splice("# A\n", blk) == "# A\n\n" + blk
    assert splice("# A\n\n", blk) == "# A\n\n" + blk
    assert splice("# A", blk) == "# A\n\n" + blk
    assert splice("", blk) == blk, "an empty AGENTS.md gets no leading blank lines"

    # Replace in place, block at EOF.
    one = "# A\n\n" + BEGIN + " -->\nold\n" + END + "\n"
    assert splice(one, blk) == "# A\n\n" + blk
    assert splice(splice(one, blk), blk) == splice(one, blk), "must be idempotent"

    # THE REGRESSION: a sibling skill's managed block directly below this one keeps the blank line
    # that separates them, however ragged that separator was to begin with.
    sib = "<!-- graph-hooks:begin -->\nx\n"
    two = "# A\n\n" + BEGIN + " -->\nold\n" + END + "\n\n" + sib
    got = splice(two, blk)
    assert got == "# A\n\n" + blk + "\n" + sib, repr(got)
    assert splice(got, blk) == got, "idempotent with a sibling block below"
    assert (
        splice("# A\n\n" + BEGIN + " -->\nold\n" + END + "\n\n\n\n" + sib, blk) == got
    )

    # A block whose asset ends in a trailing blank line must not widen the gap on every run.
    assert splice(two, blk + "\n") == got

    # Ordinary prose below the block gets the same one blank line.
    assert (
        splice("# A\n\n" + BEGIN + " -->\no\n" + END + "\nprose\n", blk)
        == "# A\n\n" + blk + "\nprose\n"
    )

    # Malformed marker sets are refused, never guessed at.
    for bad in (
        BEGIN + " -->\n",
        END + "\n",
        BEGIN + " -->\n" + BEGIN + " -->\n" + END + END,
    ):
        try:
            splice(bad, blk)
        except ValueError:
            pass
        else:
            raise AssertionError(f"must refuse malformed input: {bad!r}")

    print("splice-agents-block (secret-guard) selftest OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True, help="target repo's AGENTS.md")
    ap.add_argument("--block", required=True, help="assets/agents-secret-guard.md")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    try:
        with open(a.block, encoding="utf-8") as f:
            block = f.read()
    except OSError as e:
        print(f"setup-secret-guard: cannot read block asset: {e}", file=sys.stderr)
        return 1

    try:
        with open(a.file, encoding="utf-8") as f:
            existing = f.read()
    except FileNotFoundError:
        existing = ""
    except OSError as e:
        print(f"setup-secret-guard: cannot read {a.file}: {e}", file=sys.stderr)
        return 1

    try:
        updated = splice(existing, block)
    except ValueError as e:
        print(f"setup-secret-guard: {e}", file=sys.stderr)
        return 1

    if updated == existing:
        print("  = AGENTS.md routing block already current")
        return 0
    if a.dry_run:
        print("  would: refresh AGENTS.md routing block (--dry-run)")
        return 0

    try:
        with open(a.file, "w", encoding="utf-8") as f:
            f.write(updated)
    except OSError as e:
        print(f"setup-secret-guard: cannot write {a.file}: {e}", file=sys.stderr)
        return 1

    print(
        "  + AGENTS.md routing block injected"
        if BEGIN not in existing
        else "  ~ AGENTS.md routing block refreshed"
    )
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    sys.exit(main())
