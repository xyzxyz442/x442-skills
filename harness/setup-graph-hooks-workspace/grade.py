#!/usr/bin/env python3
"""Grader for the x442-setup-graph-hooks skill.

Wraps the skill's bundled verify-graph-hooks.sh and adds the per-eval assertions a verifier
cannot make: precondition refusal, idempotency empty-diff, and — for graph-search-behavior —
what the wired hooks actually DECIDE at runtime. Read-only and LLM-free.

Two caveats inherited knowingly:

- verify-graph-hooks.sh exercising the end-of-turn refresh may kick off a background graph
  update (idempotent and locked). It still makes no LLM calls. See that script's header.
- The behavioral case fires the produced project's own `.graph-hooks/hook.sh` with synthetic
  tool payloads, which touches per-repo slot files under ~/.cache/graph-steer-hook/ — the
  same cache the real hook uses for its one-allowance-per-hour anti-retry-loop logic. It
  resets the slots it depends on and cleans up the ones it creates, so a rerun in the same
  hour is deterministic.

Usage:
    python3 grade.py <produced-project-dir> [eval_id] [--out grading.json]

`eval_id` is one of the ids in evals/evals.json (no-agents-md | fresh-wired | all-wired |
copilot-primary-wired | both-wired | graph-search-behavior). With no eval_id, only the
verifier-wrap assertion runs. Exits 0 iff nothing failed.
"""

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "lib"))
import grade_common as gc  # noqa: E402

REPO = gc.repo_root(HERE)
VERIFY = REPO / "skills/engineering/setup-graph-hooks/scripts/verify-graph-hooks.sh"

STEER_CACHE = Path.home() / ".cache" / "graph-steer-hook"
GRAPH_HOOKS_DIR = ".graph-hooks"
NO_HOOK_OUTPUT = "no hook output"
COPILOT_CONFIG = ".github/hooks/graph.json"
CLAUDE_CONFIG = ".claude/settings.local.json"


def _slot_path(repo: Path) -> Path:
    """Reproduce grep-steer.sh's per-repo-per-hour allowance slot path for `repo`.

    Mirrors: KEY=md5($PWD)[:8]; SLOT=~/.cache/graph-steer-hook/first-$KEY-$(date +%Y%m%d%H).
    `repo.resolve()` matches bash's $PWD after a real chdir (both are symlink-resolved).
    """
    key = hashlib.md5(str(repo.resolve()).encode()).hexdigest()[:8]
    hour = datetime.now().strftime("%Y%m%d%H")
    return STEER_CACHE / f"first-{key}-{hour}"


def _reset_slot(repo: Path) -> None:
    """Clear `repo`'s current-hour allowance slot so the next grep is deterministically
    "first", regardless of what an earlier run in this same hour left behind."""
    _slot_path(repo).unlink(missing_ok=True)


def _fire_hook(repo: Path, tool: str, kind: str, payload: dict) -> dict | None:
    """Run the project's OWN installed `.graph-hooks/hook.sh` (the real wired artifact, not
    the skill's source copy) with a synthetic tool stdin payload; parse its JSON stdout.

    Returns None when the hook stays silent — which for a steering hook is a decision, not a
    failure: silence means "not intercepted".
    """
    hook = repo / GRAPH_HOOKS_DIR / "hook.sh"
    proc = subprocess.run(
        ["bash", str(hook), "--tool", tool, "--kind", kind],
        cwd=str(repo), input=json.dumps(payload), capture_output=True, text=True,
    )
    out = proc.stdout.strip()
    if not out:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def _decision(out: dict | None) -> str | None:
    return (out or {}).get("hookSpecificOutput", {}).get("permissionDecision")


def _context(out: dict | None) -> str:
    return (out or {}).get("hookSpecificOutput", {}).get("additionalContext", "")


def grade_graph_search_behavior(target: Path) -> list[gc.Expectation]:
    """Behavioral proof (not just wiring): with a real, small, hand-built graph present, the
    wired hooks steer grep / direct reads / session-start toward code-review-graph and
    graphify during code search, without ever false-blocking a genuine miss or an explicit
    --graph-tried bypass. Fires the dispatcher exactly as Claude Code would.
    """
    hook = target / GRAPH_HOOKS_DIR / "hook.sh"
    if not hook.is_file():
        return [gc.expectation("graph hooks dispatcher present for behavior test", False,
                               f"{GRAPH_HOOKS_DIR}/hook.sh missing")]

    exps: list[gc.Expectation] = []

    session = _fire_hook(target, "claude", "sessionstart", {})
    ctx = _context(session)
    exps.append(gc.expectation(
        "session start injects a graph cheatsheet (CRG + graphify + routing tools)",
        bool(session) and "CRG" in ctx and "graphify" in ctx and "semantic_search_nodes_tool" in ctx,
        f"additionalContext: {ctx[:200]!r}" if session else NO_HOOK_OUTPUT,
    ))

    read_out = _fire_hook(target, "claude", "pretool-read",
                          {"tool_input": {"file_path": "src/billing.ts"}})
    ctx = _context(read_out)
    exps.append(gc.expectation(
        "reading a source file is nudged toward the graph instead of reading one-by-one",
        bool(read_out) and ("semantic_search_nodes_tool" in ctx or "graphify" in ctx),
        f"additionalContext: {ctx[:200]!r}" if read_out else NO_HOOK_OUTPUT,
    ))

    _reset_slot(target)
    bypass_out = _fire_hook(target, "claude", "pretool-shell", {
        "tool_input": {"command": "grep -rn calculateInvoiceTotal src/ --graph-tried"}})
    exps.append(gc.expectation(
        "--graph-tried bypass is honored (no steering, even with a graph hit available)",
        bypass_out is None,
        "no output (bypassed)" if bypass_out is None else f"unexpected output: {json.dumps(bypass_out)[:200]}",
    ))

    md_out = _fire_hook(target, "claude", "pretool-shell",
                        {"tool_input": {"command": "grep -rn calculateInvoiceTotal README.md"}})
    exps.append(gc.expectation(
        "grep against non-code files (.md) is never intercepted",
        md_out is None,
        "no output (ignored)" if md_out is None else f"unexpected output: {json.dumps(md_out)[:200]}",
    ))

    _reset_slot(target)
    first = _fire_hook(target, "claude", "pretool-shell",
                       {"tool_input": {"command": "grep -rn calculateInvoiceTotal src/"}})
    first_ctx = _context(first)
    exps.append(gc.expectation(
        "first grep for a real symbol is pre-answered from the graph and still allowed",
        bool(first) and "calculateInvoiceTotal" in first_ctx and "src/billing.ts" in first_ctx
        and _decision(first) != "block",
        f"additionalContext: {first_ctx[:200]!r}" if first else NO_HOOK_OUTPUT,
    ))

    second = _fire_hook(target, "claude", "pretool-shell",
                        {"tool_input": {"command": "grep -rn calculateInvoiceTotal src/"}})
    exps.append(gc.expectation(
        "repeating the same grep is BLOCKED once the graph already answered it",
        _decision(second) == "block",
        f"second grep output: {json.dumps(second)[:200]}" if second else NO_HOOK_OUTPUT,
    ))
    _reset_slot(target)

    # A miss must be tested in a throwaway copy: the miss itself consumes the one-shot
    # allowance, and doing that against `target` would poison the assertions above on rerun.
    miss_copy = Path(tempfile.mkdtemp(prefix="sgh-miss-"))
    try:
        shutil.copytree(target, miss_copy, dirs_exist_ok=True)
        _reset_slot(miss_copy)
        miss = _fire_hook(miss_copy, "claude", "pretool-shell",
                          {"tool_input": {"command": "grep -rn totallyMissingSymbolXyz src/"}})
        miss_ctx = _context(miss)
        exps.append(gc.expectation(
            "a first-time miss still allows the grep, pointing at the graph tool for next time",
            bool(miss) and _decision(miss) != "block"
            and ("graphify" in miss_ctx or "semantic_search_nodes_tool" in miss_ctx),
            f"additionalContext: {miss_ctx[:200]!r}" if miss else NO_HOOK_OUTPUT,
        ))
    finally:
        _reset_slot(miss_copy)
        shutil.rmtree(miss_copy, ignore_errors=True)

    return exps


def grade(target: Path, eval_id: str | None) -> list[gc.Expectation]:
    """Grade in an isolated copy when `target` is nested in a larger repo.

    verify-graph-hooks.sh, git_diff_empty, and the graph hooks all resolve the git toplevel; a
    fixture inside x442-skills would otherwise be graded against x442-skills. isolated_git_target
    relocates it to its own git root first (no-op when it already is one).
    """
    graded, cleanup = gc.isolated_git_target(target)
    if graded != Path(target).resolve():
        print(f"[grade] isolated fixture to its own git root: {graded}", file=sys.stderr)
    try:
        return _grade(graded, eval_id)
    finally:
        cleanup()


def _grade(target: Path, eval_id: str | None) -> list[gc.Expectation]:
    if eval_id == "no-agents-md":
        # Precondition case: the skill must refuse and fabricate nothing. The verifier is NOT
        # the source of truth here (it grades a wired repo), so assert the negatives directly.
        return [
            gc.no_fabrication(target, "AGENTS.md"),
            gc.no_fabrication(target, GRAPH_HOOKS_DIR),
        ]
    if eval_id == "graph-search-behavior":
        return [gc.run_verify_script(VERIFY, target)] + grade_graph_search_behavior(target)

    exps = [gc.run_verify_script(VERIFY, target)]
    if eval_id == "fresh-wired":
        exps.append(gc.contains(target, "AGENTS.md", "graph-hooks"))
        exps.append(gc.file_exists(target, f"{GRAPH_HOOKS_DIR}/hook.sh"))
    elif eval_id == "all-wired":
        exps.append(gc.git_diff_empty(target))
    elif eval_id == "copilot-primary-wired":
        exps.append(gc.file_exists(target, COPILOT_CONFIG))
        exps.append(gc.json_roundtrip(target, COPILOT_CONFIG))
        exps.append(gc.contains(target, COPILOT_CONFIG, "agentStop"))
        exps.append(gc.no_fabrication(target, ".claude"))
        exps.append(gc.git_diff_empty(target))
    elif eval_id == "both-wired":
        exps.append(gc.file_exists(target, CLAUDE_CONFIG))
        exps.append(gc.file_exists(target, COPILOT_CONFIG))
        exps.append(gc.json_roundtrip(target, COPILOT_CONFIG))
        exps.append(gc.contains(target, COPILOT_CONFIG, "agentStop"))
        # Single-refresh-owner invariant: copilot owns end-of-turn, so claude must NOT also
        # carry a Stop hook even though it is wired.
        exps.append(gc.not_contains(target, CLAUDE_CONFIG, "Stop",
                                    label="claude config has no end-of-turn Stop hook (copilot owns refresh)"))
        exps.append(gc.git_diff_empty(target))
    return exps


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
