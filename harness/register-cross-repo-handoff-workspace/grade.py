#!/usr/bin/env python3
"""Grader for the x442-register-cross-repo-handoff skill.

Wraps the skill's bundled verify-cross-repo-handoff.sh and adds the per-eval assertions a verifier
cannot make. Read-only and LLM-free.

Why this grader RUNS the skill (sync), like register-cross-repo-graph's grader
------------------------------------------------------------------------------
A synced fleet cannot ship as a static fixture: its post-state embeds absolute, machine-specific
paths (board paths, the wired hook commands, the AGENTS.md block). So the fixtures ship only the
PORTABLE inputs (a workspace with a relative-path .handoff-repos.json + stub member repos, each with
an AGENTS.md), and this grader manufactures the machine-specific state hermetically:

  * copy the fixture into a throwaway sandbox and `git init` each member repo,
  * point `$HOME` at a throwaway dir (so no user-layer ~/.agents/handoff-repos.json leaks in),
  * run the skill's own deterministic, LLM-free sync-cross-repo-handoff.sh,
  * then run the verifier under the same sandboxed `$HOME`.

The fleet case is exercised under BOTH layouts (subfolder + prefix) — the same fixture, its manifest
`layout` rewritten in the sandbox — so both code paths are graded.

Usage:
    python3 grade.py <fixture-dir> [eval_id] [--out grading.json]

`eval_id` is one of the ids in evals/evals.json (not-configured | fleet). With no eval_id, the
verifier-wrap assertion runs against <fixture-dir> in place. Exits 0 iff nothing failed.
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
SKILL = REPO / "skills/engineering/register-cross-repo-handoff"
VERIFY = SKILL / "scripts/verify-cross-repo-handoff.sh"
SYNC = SKILL / "scripts/sync-cross-repo-handoff.sh"

MEMBERS = ("api", "web", "kubernetes", "monolith")

# Legacy KEY=value board config -> the handoff.json key each name became. Only the keys a board ever
# wrote are mapped, matching the payload's own resolver (payload/config.sh).
_LEGACY_BOARD_KEYS = {
    "TOPOLOGY": "topology", "REPO_NAME": "repoName",
    "HANDOFF_GROUPS": "groups", "HANDOFF_GROUP_LAYOUT": "groupLayout",
}


def _read_json(path: Path) -> dict:
    """Parse a JSON object, or {} when absent/unreadable. Callers assert on the VALUES — never on
    the {} itself, which is exactly how the pre-consolidation filenames went unnoticed here."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _board_config(board: Path) -> dict:
    """One board's effective config, resolved the way the payload resolves it.

    A board written by the current installer carries `handoff.json`; older ones carry `config.json`
    or the legacy KEY=value `config`, and the newest present wins. Keep this agreeing with
    skills/engineering/setup-handoff/scripts/payload/config.sh — it has now been wrong twice, once
    per rename, and each time the symptom was a correctly scaffolded board reading as "missing"
    rather than a failure that named the filename.
    """
    cfg: dict = {}
    legacy = board / "config"
    if legacy.is_file():
        for line in legacy.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            if key in _LEGACY_BOARD_KEYS:
                cfg[_LEGACY_BOARD_KEYS[key]] = val.strip().strip('"').strip("'")
    # Newest last: each generation's file overrides the one before it, as the resolver does.
    for name in ("config.json", "handoff.json"):
        js = board / name
        if not js.is_file():
            continue
        try:
            cfg.update(json.loads(js.read_text(encoding="utf-8")))
        except ValueError:
            return {}
    return cfg


def _groups_csv(cfg: dict) -> str:
    """`groups` as a sorted csv — handoff.json stores a list, the legacy file a csv string."""
    groups = cfg.get("groups") or []
    if isinstance(groups, str):
        groups = [g for g in groups.split(",") if g]
    return ",".join(sorted(str(g) for g in groups))


def _member_group(repo: Path) -> str:
    """The section a member repo resolves to. It lives in the repo's own .agents/handoff.json
    (written by merge-hooks.py), NOT baked into the hook command as HANDOFF_GROUP=<group> — that
    literal was deliberately removed so a rename cannot strand a stale copy inside a tool config."""
    for name in ("handoff.json", "handoff.config.json"):  # current first, then the pre-consolidation name
        js = repo / ".agents" / name
        if not js.is_file():
            continue
        try:
            return str(json.loads(js.read_text(encoding="utf-8")).get("group") or "")
        except ValueError:
            return ""
    return ""


def _sandbox_home(base: Path) -> dict:
    """Env with a redirected $HOME so the user-layer manifest (~/.agents/handoff-repos.json) and any
    real board state never leak into the graded run. The rest of the environment is inherited."""
    home = base / "home"
    (home / ".agents").mkdir(parents=True)
    return {**os.environ, "HOME": str(home)}


def _run_verify(scope: Path, env: dict) -> tuple[subprocess.CompletedProcess, gc.Expectation]:
    proc = subprocess.run(["bash", str(VERIFY), "--scope", str(scope)],
                          capture_output=True, text=True, env=env)
    m = gc._SUMMARY_RE.search(proc.stdout)
    summary = m.group(0) if m else "(no Summary line)"
    failed = int(m.group(3)) if m else None
    passed = proc.returncode == 0 and failed == 0
    exp = gc.expectation("verify-cross-repo-handoff.sh passes", passed, f"{summary} (exit {proc.returncode})")
    return proc, exp


def grade_not_configured(fixture: Path) -> list:
    """A workspace with no .handoff-repos.json: cross-repo is not opted in, which is not a failure.
    The verifier must report 'not configured' and exit 0, never FAIL / exit 1."""
    sandbox = Path(tempfile.mkdtemp(prefix="x442-xrh-nc-"))
    try:
        work = sandbox / "work"
        shutil.copytree(fixture, work, symlinks=True)
        env = _sandbox_home(sandbox)  # guarantees no user-layer manifest makes it "configured"
        proc, summary_exp = _run_verify(work, env)
        not_configured = "not configured" in proc.stdout and proc.returncode == 0
        return [
            summary_exp,
            gc.expectation(
                "an unconfigured workspace is a clean skip (exit 0), not a FAIL",
                not_configured,
                f"exit {proc.returncode}; 'not configured' in output: {'not configured' in proc.stdout}",
            ),
        ]
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def _grade_fleet_layout(fixture: Path, layout: str) -> list:
    """Sync + verify the fleet fixture under one layout, in a hermetic sandbox. Every expectation is
    prefixed with the layout so a failure names which code path broke."""
    tag = f"[{layout}]"
    sandbox = Path(tempfile.mkdtemp(prefix=f"x442-xrh-{layout}-"))
    try:
        work = sandbox / "work"
        shutil.copytree(fixture, work, symlinks=True)
        # rewrite the manifest's layout for this pass
        manifest = work / ".handoff-repos.json"
        m = json.loads(manifest.read_text(encoding="utf-8"))
        m["layout"] = layout
        manifest.write_text(json.dumps(m, indent=2) + "\n", encoding="utf-8")
        for name in MEMBERS:
            gc.git_init_commit(work / name, f"{name} baseline")

        env = _sandbox_home(sandbox)
        sync = subprocess.run(
            ["bash", str(SYNC), "--scope", str(work), "--tools", "claude", "--primary", "claude"],
            capture_output=True, text=True, env=env,
        )
        last = (sync.stdout or sync.stderr).strip().splitlines()[-1] if (sync.stdout or sync.stderr).strip() else "no output"
        exps = [gc.expectation(f"{tag} sync-cross-repo-handoff.sh completes (exit 0)", sync.returncode == 0, last)]

        _, summary_exp = _run_verify(work, env)
        summary_exp["text"] = f"{tag} {summary_exp['text']}"
        exps.append(summary_exp)

        # boards scaffolded with the right group facts
        shared_cfg = _board_config(work / ".agents/handoff")
        legacy_cfg = _board_config(work / ".agents/handoff-legacy")
        exps.append(gc.expectation(
            f"{tag} shared board config records both co-located groups + layout",
            _groups_csv(shared_cfg) == "auth-suite,infra" and shared_cfg.get("groupLayout") == layout,
            f"groups={_groups_csv(shared_cfg) or 'unset'} layout={shared_cfg.get('groupLayout') or 'unset'}"
            if shared_cfg else "missing",
        ))
        exps.append(gc.expectation(
            f"{tag} legacy group is on its own separate board",
            _groups_csv(legacy_cfg) == "legacy",
            f"groups={_groups_csv(legacy_cfg) or 'unset'}" if legacy_cfg else "missing",
        ))

        # each member wired to its own section (AGENTS.md block + HANDOFF_GROUP in the hook command)
        for name, group in (("api", "auth-suite"), ("kubernetes", "infra"), ("monolith", "legacy")):
            agents = (work / name / "AGENTS.md").read_text(encoding="utf-8")
            block_ok = "cross-repo-handoff:begin" in agents and f"`{group}` section" in agents
            exps.append(gc.expectation(
                f"{tag} {name} AGENTS.md block scoped to {group}", block_ok,
                f"block present + names {group}: {block_ok}",
            ))
            # Wired and scoped are separate facts: the hook command invokes the board, and the
            # member's own config names its section.
            settings = work / name / ".claude/settings.json"
            hook_ok = settings.is_file() and "/scripts/hooks.sh" in settings.read_text()
            exps.append(gc.expectation(
                f"{tag} {name} hooks invoke the board", hook_ok,
                f"handoff hook in settings.json: {hook_ok}",
            ))
            got_group = _member_group(work / name)
            exps.append(gc.expectation(
                f"{tag} {name} resolves to section {group}", got_group == group,
                f".agents/handoff.json group={got_group or 'unset'}",
            ))

        # ledger recorded
        # The ledger moved INSIDE the workspace's own handoff.json, under `_generated`, when every
        # layer was consolidated onto one filename. Asserting the file's existence is no longer the
        # question — `_generated.members` is, since an empty or absent block means --prune has
        # nothing to compare against and drift reporting silently does nothing.
        ledger = _read_json(work / ".agents/handoff.json").get("_generated") or {}
        # Keyed on PATH, not alias: an alias is the manifest's short name for a repo (`k8s` for
        # `kubernetes/`) and comparing it to a directory name asserts a coincidence, not a fact.
        got_paths = sorted({os.path.basename(str(m.get("path", "")).rstrip("/"))
                            for m in ledger.get("members") or []})
        exps.append(gc.expectation(
            f"{tag} ledger records every member under _generated",
            got_paths == sorted(MEMBERS),
            f"members={got_paths or 'unset'}",
        ))

        # idempotency: commit the FIRST sync's output as the baseline, then re-sync and assert every
        # member repo's git status is clean (the second sync changed nothing).
        for name in MEMBERS:
            gc.git_init_commit(work / name, "post-sync baseline")
        subprocess.run(
            ["bash", str(SYNC), "--scope", str(work), "--tools", "claude", "--primary", "claude"],
            capture_output=True, text=True, env=env,
        )
        for name in MEMBERS:
            e = gc.git_diff_empty(work / name)
            e["text"] = f"{tag} {name}: {e['text']}"
            exps.append(e)
        return exps
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def grade_fleet(fixture: Path) -> list:
    exps = []
    for layout in ("subfolder", "prefix"):
        exps.extend(_grade_fleet_layout(fixture, layout))
    return exps


def grade(target: Path, eval_id: str | None) -> list:
    gc.pre_state_hint(HERE, eval_id)
    if eval_id == "not-configured":
        return grade_not_configured(target)
    if eval_id == "fleet":
        return grade_fleet(target)
    # Default: wrap the verifier against `target` in place (its own scope).
    proc = subprocess.run(["bash", str(VERIFY), "--scope", str(target)], capture_output=True, text=True)
    m = gc._SUMMARY_RE.search(proc.stdout)
    summary = m.group(0) if m else "(no Summary line)"
    failed = int(m.group(3)) if m else None
    return [gc.expectation("verify-cross-repo-handoff.sh passes",
                           proc.returncode == 0 and failed == 0, f"{summary} (exit {proc.returncode})")]


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
