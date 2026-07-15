#!/usr/bin/env python3
"""Grader for the x442-setup-project-tooling skill.

Wraps the skill's bundled verify-project-tooling.sh and adds the per-eval assertions a verifier
cannot make (idempotency, post-state markers). Read-only and LLM-free.

Pre-state vs post-state (same split as setup-graph-hooks' fresh-wired)
----------------------------------------------------------------------
- `scaffolded` is a post-state: a fully wired Node/TS project. Directly gradeable — verify passes
  and the tree stays clean (idempotent).
- `fresh` is a pre-state INPUT: a bare Node project. Grading the raw fixture fails by design (the
  tooling is not there yet); an agent runs setup-project-tooling, and the produced dir is re-graded
  to 0 failed.

The target is isolated to its own git root before grading, because verify-project-tooling.sh
resolves the git toplevel (falling back to $PWD) — a fixture nested inside x442-skills would
otherwise be graded against x442-skills. See grade_common.isolated_git_target.

Usage:
    python3 grade.py <produced-project-dir> [eval_id] [--out grading.json]

`eval_id` is one of the ids in evals/evals.json (scaffolded | fresh). With no eval_id, only the
verifier-wrap assertion runs. Exits 0 iff nothing failed.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "lib"))
import grade_common as gc  # noqa: E402

REPO = gc.repo_root(HERE)
VERIFY = REPO / "skills/engineering/setup-project-tooling/scripts/verify-project-tooling.sh"

COMMITLINT_CONFIG = "commitlint.config.mjs"
EDITORCONFIG = ".editorconfig"


def grade(target: Path, eval_id: str | None) -> list[gc.Expectation]:
    """Grade in an isolated copy when `target` is nested in a larger repo.

    verify-project-tooling.sh and git_diff_empty resolve the git toplevel; a fixture inside
    x442-skills would otherwise be graded against x442-skills.
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
    if eval_id == "scaffolded":
        # Post-state: verify green AND the tree stays clean (re-running the skill changes nothing).
        exps.append(gc.git_diff_empty(target))
        exps.append(gc.file_exists(target, COMMITLINT_CONFIG))
        exps.append(gc.file_exists(target, EDITORCONFIG))
    elif eval_id == "fresh":
        # Pre-state: the post-scaffold markers must appear. Both fail on the raw fixture by design.
        exps.append(gc.file_exists(target, COMMITLINT_CONFIG))
    return exps


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
