#!/usr/bin/env python3
"""Grader for the x442-repair-graph-hooks skill.

repair-graph-hooks ships no verifier of its own — by design its success condition is that
setup-graph-hooks' verify-graph-hooks.sh goes green again. So this grader wraps THAT verifier and
adds one targeted assertion per case that the specific drift is gone. Read-only and LLM-free.

Pre-state vs post-state (same split as setup-graph-hooks' fresh-wired)
----------------------------------------------------------------------
- `healthy` is a post-state: a fully wired repo. Repair is a no-op, so this case is directly
  gradeable — verify passes and the tree stays clean.
- `broken-json` / `missing-core` are repair TARGETS: their fixtures are drifted INPUTS. Grading
  the raw fixture fails by design (the drift is still there); an agent runs repair-graph-hooks,
  and the produced dir is then re-graded to 0 failed.

The target is isolated to its own git root before grading, because verify-graph-hooks.sh (and the
git-clean check) resolve the git toplevel — a fixture nested inside x442-skills would otherwise be
graded against x442-skills. See grade_common.isolated_git_target.

Usage:
    python3 grade.py <produced-project-dir> [eval_id] [--out grading.json]

`eval_id` is one of the ids in evals/evals.json (healthy | broken-json | missing-core). With no
eval_id, only the verifier-wrap assertion runs. Exits 0 iff nothing failed.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "lib"))
import grade_common as gc  # noqa: E402

REPO = gc.repo_root(HERE)
# repair's success is measured by setup-graph-hooks' verifier — repair ships none of its own.
VERIFY = REPO / "skills/engineering/setup-graph-hooks/scripts/verify-graph-hooks.sh"

CLAUDE_CONFIG = ".claude/settings.local.json"
GREP_STEER = ".graph-hooks/core/grep-steer.sh"


def grade(target: Path, eval_id: str | None) -> list[gc.Expectation]:
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
        # Repair must not touch a healthy repo: verify green AND the tree still clean.
        exps.append(gc.git_diff_empty(target))
    elif eval_id == "broken-json":
        # Post-repair, the Claude config must parse again.
        exps.append(gc.json_roundtrip(target, CLAUDE_CONFIG))
    elif eval_id == "missing-core":
        # Post-repair, the deleted core behavior must be reinstalled.
        exps.append(gc.file_exists(target, GREP_STEER))
    return exps


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
