#!/usr/bin/env python3
# splice.py — the AGENTS.md managed-block splice for setup-delegate-agent, as an importable pure
# function so it can carry assertions.
#
#   Self-test:  python3 splice.py --selftest
#
# This lived as eight lines inside setup-delegate-agent.sh's rendering heredoc, which is why it
# silently carried the same separator defect as its three siblings for four copies: a string
# function inside a heredoc cannot be imported, cannot be unit tested, and nothing in this repo
# could have caught it. Only the splice moved out — the block rendering stays in the installer,
# where it reads the resolved cascade. See agents-md-splice-audit-handoff.
#
# Splice rules (a string splice, never sed) mirror setup-handoff's splice-agents-block.py:
#   - exactly one begin/end pair  -> replace the span
#   - no markers                  -> append after one blank line at EOF
#   - unbalanced / duplicated     -> refuse (ValueError; the installer exits 1, a human fixes it)
import sys

BEGIN = "<!-- delegate:begin"
END = "<!-- delegate:end -->"


def splice(existing: str, block: str) -> str:
    n_begin, n_end = existing.count(BEGIN), existing.count(END)
    if n_begin != n_end or n_begin > 1:
        raise ValueError(
            f"malformed managed block in AGENTS.md ({n_begin} begin / {n_end} end markers) — fix by hand"
        )
    block = block.rstrip("\n") + "\n"
    if n_begin == 0:
        if not existing.strip():
            return block
        sep = (
            ""
            if existing.endswith("\n\n")
            else ("\n" if existing.endswith("\n") else "\n\n")
        )
        return existing + sep + block
    head = existing[: existing.index(BEGIN)]
    tail = existing[existing.index(END) + len(END) :]
    rest = tail.lstrip("\n")
    # The separator is owned HERE, not by the tail. The installer used to return
    # `text[j:].lstrip("\n")` bare, so no blank line survived between this block and whatever
    # followed it — and in a repo that also ran setup-graph-hooks or setup-handoff, what follows
    # is another managed block. Every re-run then flipped that line back and forth, so the
    # installer's "a second run leaves git status clean" promise was false there.
    return head + block + ("\n" + rest if rest else "")


def _selftest() -> int:
    """python3 splice.py --selftest

    The same cases setup-handoff's splice-agents-block.py asserts. The four splices in this suite
    are declared to mirror each other; asserting each copy separately is what makes that true
    rather than aspirational.
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

    # A rendered block ending in a trailing blank line must not widen the gap on every run.
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

    print("splice (delegate) selftest OK")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    print(
        __doc__ or "splice.py is imported by setup-delegate-agent.sh; try --selftest",
        file=sys.stderr,
    )
    sys.exit(2)
