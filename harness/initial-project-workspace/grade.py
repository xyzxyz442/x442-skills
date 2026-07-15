#!/usr/bin/env python3
"""Grader for the x442-initial-project skill.

Wraps the skill's bundled verify-initial-project.sh (the single source of truth for "wired
correctly") and adds the per-eval assertions a verifier can't make — it only ever sees the
end state of one repo, so it cannot know the repo was already wired (idempotency) or that a
line predates the run (preserve-existing). Read-only and LLM-free.

Usage:
    python3 grade.py <produced-project-dir> [eval_id] [--out grading.json]

`eval_id` is one of the ids in evals/evals.json (nest-new | nest-existing | ts-library).
With no eval_id, only the verifier-wrap assertion runs. Prints grading.json to stdout, and
also writes it when --out is given. Exits 0 iff nothing failed.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "lib"))
import grade_common as gc  # noqa: E402

REPO = gc.repo_root(HERE)
VERIFY = REPO / "skills/engineering/initial-project/scripts/verify-initial-project.sh"

# A distinctive line from the nest-existing fixture's pre-existing CLAUDE.md notes. It must
# survive the skill's edit — that is the preserve-existing-content check.
NEST_EXISTING_NOTE = "orders-ingest-v2"


def grade(target: Path, eval_id: str | None) -> list[gc.Expectation]:
    """Grade in an isolated copy when `target` is nested in a larger repo.

    verify-initial-project.sh and git_diff_empty resolve the git toplevel; a fixture inside
    x442-skills would otherwise be graded against x442-skills. isolated_git_target relocates it to
    its own git root first (no-op when it already is one).
    """
    gc.pre_state_hint(HERE, eval_id)
    graded, cleanup = gc.isolated_git_target(target)
    if graded != Path(target).resolve():
        print(f"[grade] isolated fixture to its own git root: {graded}", file=sys.stderr)
    try:
        return _grade(graded, eval_id)
    finally:
        cleanup()


def _grade(target: Path, eval_id: str | None) -> list[gc.Expectation]:
    exps = [gc.run_verify_script(VERIFY, target)]
    if eval_id == "nest-new":
        # Fresh app, no AI config: the skill creates AGENTS.md and wires Claude to it.
        exps.append(gc.contains(target, "AGENTS.md", "Coding guidelines"))
        exps.append(gc.contains(target, "CLAUDE.md", "@AGENTS.md"))
    elif eval_id == "nest-existing":
        # Existing CLAUDE.md notes: AGENTS.md created, import added, notes preserved.
        exps.append(gc.file_exists(target, "AGENTS.md"))
        exps.append(gc.contains(target, "CLAUDE.md", "@AGENTS.md"))
        exps.append(gc.contains(target, "CLAUDE.md", NEST_EXISTING_NOTE,
                                label="CLAUDE.md preserves the existing service notes"))
    elif eval_id == "ts-library":
        # Already fully wired: re-running must change nothing.
        exps.append(gc.git_diff_empty(target))
    return exps


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
