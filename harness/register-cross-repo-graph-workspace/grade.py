#!/usr/bin/env python3
"""Grader for the x442-register-cross-repo-graph skill.

Wraps the skill's bundled verify-cross-repo-graph.sh and adds the per-eval assertions a verifier
cannot make. Read-only and LLM-free.

Why this grader RUNS the skill (sync), unlike setup-graph-hooks' grader
-----------------------------------------------------------------------
A synced cross-repo repo cannot ship as a static fixture: its post-state embeds absolute,
machine-specific paths — CRG's global registry, the merged graph, and the sibling paths rendered
into the AGENTS.md block. None of that is portable across checkouts. So the fixtures ship only the
PORTABLE inputs (a consumer with a relative-path manifest, and a sibling carrying a prebuilt
graph.db), and this grader manufactures the machine-specific state hermetically:

  * copy the fixture into a throwaway sandbox and `git init` the consumer and the sibling,
  * point `$HOME` at a throwaway dir and seed its `~/.code-review-graph/registry.json` with the
    sibling already registered (so sync takes the "already registered" path and never shells out
    to the real CRG binary — the real ~/.code-review-graph is never touched),
  * run the skill's own deterministic, LLM-free `sync-cross-repo-graph.sh`,
  * then run the verifier under the same sandboxed `$HOME`.

The sibling's graph.db mtime is bumped past its HEAD commit so the resolver never flags the
advertised alias as stale — a real sibling refreshes its own graph, but a fixture committed at rest
has no commit-time skew to model.

Usage:
    python3 grade.py <fixture-dir> [eval_id] [--out grading.json]

`eval_id` is one of the ids in evals/evals.json (not-configured | single-sibling). With no
eval_id, the verifier-wrap assertion runs against <fixture-dir> in place. Exits 0 iff nothing
failed.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "lib"))
import grade_common as gc  # noqa: E402

REPO = gc.repo_root(HERE)
SKILL = REPO / "skills/engineering/register-cross-repo-graph"
VERIFY = SKILL / "scripts/verify-cross-repo-graph.sh"
SYNC = SKILL / "scripts/sync-cross-repo-graph.sh"

ALIAS = "acme-api-sib"
CROSS_REPO_STATE = ".code-review-graph/cross-repo-state.json"


def _sandbox_home(base: Path) -> tuple[Path, dict]:
    """A throwaway `$HOME` with an empty CRG dir. Env inherits the parent so `code-review-graph`
    and `graphify` on PATH still resolve; only HOME is redirected, which is what isolates the
    registry, the user-layer manifest, and the sync lock."""
    home = base / "home"
    (home / ".code-review-graph").mkdir(parents=True)
    return home, {**os.environ, "HOME": str(home)}


def _run_verify(target: Path, env: dict) -> tuple[subprocess.CompletedProcess, gc.Expectation]:
    """Run verify-cross-repo-graph.sh once; return (proc, summary-expectation).

    One run, two uses: the Summary line grades pass/fail, and the raw stdout feeds the behavioral
    assertions (so the verifier is never invoked twice)."""
    proc = subprocess.run(["bash", str(VERIFY), str(target)], capture_output=True, text=True, env=env)
    m = gc._SUMMARY_RE.search(proc.stdout)
    summary = m.group(0) if m else "(no Summary line)"
    failed = int(m.group(3)) if m else None
    passed = proc.returncode == 0 and failed == 0
    exp = gc.expectation("verify-cross-repo-graph.sh passes", passed, f"{summary} (exit {proc.returncode})")
    return proc, exp


def _block(agents_text: str) -> str:
    """The text between the cross-repo block markers (empty string if absent)."""
    begin, end = "cross-repo:begin", "cross-repo:end"
    if begin not in agents_text or end not in agents_text:
        return ""
    return agents_text.split(begin, 1)[1].split(end, 1)[0]


def grade_not_configured(fixture: Path) -> list[gc.Expectation]:
    """A wired repo with no .graph-repos.json: cross-repo is not opted in, which is not a failure.
    The verifier must [skip] and exit 0, never [FAIL]/exit 1."""
    graded, cleanup = gc.isolated_git_target(fixture)
    sandbox = Path(tempfile.mkdtemp(prefix="x442-xr-nc-"))
    try:
        _, env = _sandbox_home(sandbox)  # throwaway HOME guarantees no user-layer manifest leaks in
        proc, summary_exp = _run_verify(graded, env)
        not_configured = "not configured" in proc.stdout and proc.returncode == 0
        return [
            summary_exp,
            gc.expectation(
                "an unconfigured repo is a clean skip (exit 0), not a FAIL",
                not_configured,
                f"exit {proc.returncode}; 'not configured' in output: {'not configured' in proc.stdout}",
            ),
        ]
    finally:
        cleanup()
        shutil.rmtree(sandbox, ignore_errors=True)


def grade_single_sibling(fixture: Path) -> list[gc.Expectation]:
    """Consumer declares one sibling; the grader syncs + verifies it in a hermetic sandbox."""
    # code-review-graph IS the cross-repo mechanism: without it, sync skips the CRG path, the alias
    # never reaches the AGENTS.md block, and the case fails deep in the verifier with a confusing
    # "block drift" message. Fail fast and legibly instead — this is a real environment failure, not
    # an optional-tool skip (graphify, below, is the optional one).
    if shutil.which("code-review-graph") is None:
        return [gc.expectation(
            "code-review-graph installed (required to grade cross-repo)",
            False,
            "code-review-graph not on PATH — install it (pipx install code-review-graph) or grade "
            "on a machine that has it; without it sync cannot register the sibling",
        )]
    sandbox = Path(tempfile.mkdtemp(prefix="x442-xr-ss-"))
    try:
        work = sandbox / "work"
        shutil.copytree(fixture, work, symlinks=True)
        consumer, sibling = work / "consumer", work / "sibling"
        gc.git_init_commit(sibling, "sibling baseline")
        gc.git_init_commit(consumer, "consumer baseline")

        # Keep the advertised alias non-stale: bump graph.db past the sibling's HEAD commit time.
        db = sibling / ".code-review-graph" / "graph.db"
        if db.is_file():
            os.utime(db, None)

        home, env = _sandbox_home(sandbox)
        # Pre-seed the sandboxed registry so sync sees the sibling as already-registered and never
        # invokes the real CRG binary. The path must equal the resolver's realpath of "../sibling".
        (home / ".code-review-graph" / "registry.json").write_text(
            json.dumps({"repos": [{"alias": ALIAS, "path": str(sibling.resolve())}]}, indent=2) + "\n",
            encoding="utf-8",
        )

        # graphify graphs are BUILT in the sandbox, not committed: `graphify update` embeds the
        # build-time path, so a committed graph.json would not be portable, and merge-graphs only
        # accepts real (networkx-valid) graphs anyway. This is AST-only — no API key, no LLM.
        gfy_ok = shutil.which("graphify") is not None
        if gfy_ok:
            for repo in (sibling, consumer):
                subprocess.run(["graphify", "update", "."], cwd=str(repo),
                               capture_output=True, text=True, env=env)

        sync = subprocess.run(
            ["bash", str(SYNC), str(consumer), "--tools", "crg,graphify"],
            capture_output=True, text=True, env=env,
        )
        exps = [gc.expectation(
            "sync-cross-repo-graph.sh completes (exit 0)",
            sync.returncode == 0,
            (sync.stderr or sync.stdout).strip().splitlines()[-1] if (sync.stderr or sync.stdout).strip() else "no output",
        )]

        proc, summary_exp = _run_verify(consumer, env)
        exps.append(summary_exp)

        block = _block((consumer / "AGENTS.md").read_text(encoding="utf-8"))
        exps.append(gc.expectation(
            "AGENTS.md cross-repo block names exactly the in-scope alias",
            ALIAS in block and "In-scope aliases" in block,
            f"block names {ALIAS}: {ALIAS in block}; has routing rule: {'In-scope aliases' in block}",
        ))
        exps.append(gc.file_exists(consumer, CROSS_REPO_STATE))
        if gfy_ok:
            # graphify's per-project merged graph: sync must concatenate this repo's graph with the
            # sibling's into a merged-graph.json (a disjoint union — no cross-repo edges, by design).
            exps.append(gc.file_exists(consumer, "graphify-out/merged-graph.json"))
        else:
            # graphify is optional to the skill. Record the un-run facet as a skip rather than
            # dropping it silently, so a graphify-less machine reports reduced coverage instead of a
            # misleading full-green (summary.skipped: 1).
            print("[grade] graphify not installed — merged-graph coverage skipped", file=sys.stderr)
            exps.append(gc.skipped(
                "graphify merged graph produced",
                "graphify not installed — merged-graph coverage not exercised on this machine",
            ))
        # Behavioral proof: the verifier's end-to-end steering check answered a grep into the
        # sibling from its graph, tagged with the alias, instead of leaving it to grep.
        steered = "answered from its graph" in proc.stdout and ALIAS in proc.stdout
        exps.append(gc.expectation(
            "grep into the sibling is answered from its graph, not left to grep",
            steered,
            "steering line present" if steered else "no cross-repo steering hit in verifier output",
        ))
        return exps
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def grade(target: Path, eval_id: str | None) -> list[gc.Expectation]:
    if eval_id == "not-configured":
        return grade_not_configured(target)
    if eval_id == "single-sibling":
        return grade_single_sibling(target)
    # Default: wrap the verifier against `target` in place (isolated to its own git root).
    graded, cleanup = gc.isolated_git_target(target)
    try:
        return [gc.run_verify_script(VERIFY, graded)]
    finally:
        cleanup()


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
