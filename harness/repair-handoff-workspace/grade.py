#!/usr/bin/env python3
"""Grader for the x442-repair-handoff skill.

repair-handoff ships no verifier of its own — by design its success condition is that
setup-handoff's verify-setup-handoff.sh goes green again AND the board's own state reconciles.
So this grader wraps THAT verifier and adds the board-state assertions it structurally cannot
make: a verifier sees one repo's end state, with no notion of a lease that outlived its doc or
an index that no longer matches the docs beside it. Read-only and LLM-free.

Pre-state vs post-state (same split as repair-graph-hooks)
----------------------------------------------------------
- `healthy` is a post-state: a fully wired board. Repair is a no-op, so this case is directly
  gradeable — verify passes, the stamp matches, and the tree stays clean.
- `stale-stamp` / `orphaned-lease` / `missing-index` are repair TARGETS: their fixtures are
  drifted INPUTS. Grading the raw fixture fails or warns by design; an agent runs repair-handoff,
  and the produced dir is then re-graded.
- `not-wired` is a refusal case: success is that NOTHING was fabricated.

The target is isolated to its own git root before grading, because verify-setup-handoff.sh (and
the git-clean check) resolve the git toplevel — a fixture nested inside x442-skills would
otherwise be graded against x442-skills. See grade_common.isolated_git_target.

Usage:
    python3 grade.py <produced-project-dir> [eval_id] [--out grading.json]

`eval_id` is one of the ids in evals/evals.json (healthy | stale-stamp | orphaned-lease |
missing-index | not-wired). With no eval_id, only the verifier-wrap assertion runs. Exits 0 iff
nothing failed.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "lib"))
import grade_common as gc  # noqa: E402

REPO = gc.repo_root(HERE)
# repair's success is measured by setup-handoff's verifier — repair ships none of its own.
VERIFY = REPO / "skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh"
SHIPPED_STAMP = REPO / "skills/engineering/setup-handoff/scripts/payload.version"

BOARD = ".agents/handoff"
INDEX = f"{BOARD}/INDEX.md"
STAMP = f"{BOARD}/.version"
ORPHAN_LOCK = f"{BOARD}/.locks/deleted-doc-handoff"
SAMPLE_DOC = f"{BOARD}/sample-repair-handoff.md"


def _shipped_version() -> str:
    """The version setup-handoff currently ships, as the stamp's second field."""
    try:
        return SHIPPED_STAMP.read_text().split()[1]
    except (OSError, IndexError):
        return ""


def stamp_current(root: Path) -> gc.Expectation:
    """The installed payload stamp matches what the skill ships.

    Read here rather than inferred from the verifier's summary line: a drift warning does not
    fail the verifier (a behind-but-working board still works), so the summary alone cannot
    distinguish a repaired board from a stale one.
    """
    want = _shipped_version()
    path = root / STAMP
    try:
        got = path.read_text().split()[1]
    except (OSError, IndexError):
        return gc.expectation("payload stamp matches the shipped version", False, f"{STAMP} unreadable or malformed")
    return gc.expectation(
        "payload stamp matches the shipped version",
        bool(want) and got == want,
        f"installed v{got}, skill ships v{want or '?'}",
    )


def path_absent(root: Path, rel: str, label: str) -> gc.Expectation:
    """Nothing exists at `rel` — used for both the cleared orphan and the refusal case."""
    p = root / rel
    return gc.expectation(label, not p.exists(), "absent" if not p.exists() else f"{rel} still present")


def grade(target: Path, eval_id: str | None) -> list[gc.Expectation]:
    gc.pre_state_hint(HERE, eval_id)
    # The refusal case has no board to verify and must not be isolated into one — grade the
    # untouched directory directly, or a git init would itself count as fabrication.
    if eval_id == "not-wired":
        # AGENTS.md is part of this fixture, so its presence proves nothing either way — the only
        # thing that can be fabricated here is the board itself.
        return [
            path_absent(target, BOARD, "no handoff board was fabricated"),
            path_absent(target, f"{BOARD}/handoff", "no handoff CLI was fabricated"),
            path_absent(target, INDEX, "no handoff index was fabricated"),
        ]
    graded, cleanup = gc.isolated_git_target(target)
    if graded != Path(target).resolve():
        print(f"[grade] isolated fixture to its own git root: {graded}", file=sys.stderr)
    try:
        return _grade(graded, eval_id)
    finally:
        cleanup()


def _grade(target: Path, eval_id: str | None) -> list[gc.Expectation]:
    exps = [gc.run_verify_script(VERIFY, target)]
    if eval_id == "healthy":
        # Repair must not touch a healthy board: verify green, stamp current, tree still clean.
        exps.append(stamp_current(target))
        exps.append(gc.git_diff_empty(target))
    elif eval_id == "stale-stamp":
        # Post-repair, the board carries the version the skill ships.
        exps.append(stamp_current(target))
    elif eval_id == "orphaned-lease":
        # Post-repair, the orphan is gone AND no doc was destroyed getting there.
        exps.append(path_absent(target, ORPHAN_LOCK, "orphaned lock directory cleared"))
        exps.append(gc.file_exists(target, SAMPLE_DOC))
    elif eval_id == "missing-index":
        # Post-repair, the generated index is back and names the surviving doc.
        exps.append(gc.file_exists(target, INDEX))
        exps.append(gc.contains(target, INDEX, "sample-repair-handoff"))
    return exps


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
