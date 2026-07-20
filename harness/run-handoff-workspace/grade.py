#!/usr/bin/env python3
"""Grader for the x442-run-handoff skill.

run-handoff is a behavioral discipline over the board that setup-handoff installs — it ships
no scripts of its own. This grader confirms the environment is sound (wraps setup-handoff's
verifier once) and then drives the installed `handoff` script exactly as the discipline
prescribes, asserting the produced artifacts: a schema-valid archived doc with verified_at, a
released lease, a regenerated INDEX.md, and correct blocked/blocked_on state. Read-only and
LLM-free; all mutation happens in an isolated temp copy.

Usage:
    python3 grade.py <produced-project-dir> [eval_id] [--out grading.json]

eval_id ∈ {discipline-done | discipline-blocked}.
"""

import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "lib"))
import grade_common as gc  # noqa: E402

REPO = gc.repo_root(HERE)
VERIFY = REPO / "skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh"
HD = ".agents/handoff"


def _handoff(target, *args, session="sess-RH"):
    ho = Path(target) / HD / "handoff"
    env = {**os.environ, "HANDOFF_SESSION_ID": session}
    return subprocess.run(["bash", str(ho), *args], cwd=str(target),
                          capture_output=True, text=True, env=env)


def _frontmatter(path: Path) -> dict:
    fm = {}
    lines = path.read_text().splitlines()
    if not lines or lines[0] != "---":
        return fm
    for ln in lines[1:]:
        if ln == "---":
            break
        if ":" in ln:
            k, _, v = ln.partition(":")
            fm[k.strip()] = v.strip()
    return fm


def grade(target, eval_id):
    graded, cleanup = gc.isolated_git_target(target)
    if graded != Path(target).resolve():
        print(f"[grade] isolated fixture to its own git root: {graded}", file=sys.stderr)
    try:
        return _grade(graded, eval_id)
    finally:
        cleanup()


def _grade(target, eval_id):
    doc = Path(target) / HD
    exps = [gc.run_verify_script(VERIFY, target)]  # environment sanity

    if eval_id == "discipline-blocked":
        _handoff(target, "new", "up", "--title", "Upstream")
        _handoff(target, "new", "work", "--title", "Downstream work")
        _handoff(target, "claim", "work")
        _handoff(target, "release", "work", "--status", "blocked", "--blocked-on", "up")
        fm = _frontmatter(doc / "work.md")
        exps.append(gc.expectation("doc status is blocked", fm.get("status") == "blocked", f"status={fm.get('status')}"))
        exps.append(gc.expectation("doc records blocked_on", fm.get("blocked_on") == "up", f"blocked_on={fm.get('blocked_on')}"))
        exps.append(gc.expectation("lease released", not (doc / ".locks/work").exists(),
                                   "lock present: %s" % (doc / ".locks/work").exists()))
        exps.append(gc.expectation("doc stays on the open board (not archived)",
                                   (doc / "work.md").is_file() and not (doc / "archive/work.md").exists(),
                                   "open: %s" % (doc / "work.md").is_file()))
        return exps

    # discipline-done (default)
    _handoff(target, "new", "task", "--title", "Ship the task", "--severity", "high")
    created = _frontmatter(doc / "task.md")
    exps.append(gc.expectation("filed doc has schema-valid frontmatter (id/title/status)",
                               created.get("id") == "task" and created.get("title") == "Ship the task"
                               and created.get("status") == "open",
                               f"frontmatter: {created}"))
    _handoff(target, "claim", "task")
    r = _handoff(target, "release", "task", "--status", "done", "--verified-by", "e2e green: task.e2e.ts")
    exps.append(gc.expectation("release --status done succeeds with evidence", r.returncode == 0,
                               f"exit {r.returncode}: {r.stderr.strip()[:100]}"))
    archived = doc / "archive/task.md"
    exps.append(gc.expectation("doc archived on done", archived.is_file(), f"archived: {archived.is_file()}"))
    if archived.is_file():
        fm = _frontmatter(archived)
        exps.append(gc.expectation("archived doc stamped verified_at", bool(fm.get("verified_at")),
                                   f"verified_at={fm.get('verified_at')}"))
    exps.append(gc.expectation("lease released after done", not (doc / ".locks/task").exists(),
                               "lock present: %s" % (doc / ".locks/task").exists()))
    exps.append(gc.contains(target, f"{HD}/INDEX.md", "archive/task.md",
                            label="INDEX.md regenerated and lists the archived doc"))
    return exps


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
