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
import re
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
    "TOPOLOGY": "topology",
    "REPO_NAME": "repoName",
    "HANDOFF_GROUPS": "groups",
    "HANDOFF_GROUP_LAYOUT": "groupLayout",
}


def _read_json(path: Path) -> dict:
    """Parse a JSON object, or {} when absent/unreadable. Callers assert on the VALUES — never on
    the {} itself, which is exactly how the pre-consolidation filenames went unnoticed here.
    """
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
    literal was deliberately removed so a rename cannot strand a stale copy inside a tool config.
    """
    for name in (
        "handoff.json",
        "handoff.config.json",
    ):  # current first, then the pre-consolidation name
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
    real board state never leak into the graded run. The rest of the environment is inherited.
    """
    home = base / "home"
    (home / ".agents").mkdir(parents=True)
    return {**os.environ, "HOME": str(home)}


def _run_verify(
    scope: Path, env: dict
) -> tuple[subprocess.CompletedProcess, gc.Expectation]:
    proc = subprocess.run(
        ["bash", str(VERIFY), "--scope", str(scope)],
        capture_output=True,
        text=True,
        env=env,
    )
    m = gc._SUMMARY_RE.search(proc.stdout)
    summary = m.group(0) if m else "(no Summary line)"
    failed = int(m.group(3)) if m else None
    passed = proc.returncode == 0 and failed == 0
    exp = gc.expectation(
        "verify-cross-repo-handoff.sh passes",
        passed,
        f"{summary} (exit {proc.returncode})",
    )
    return proc, exp


def grade_not_configured(fixture: Path) -> list:
    """A workspace with no .handoff-repos.json: cross-repo is not opted in, which is not a failure.
    The verifier must report 'not configured' and exit 0, never FAIL / exit 1."""
    sandbox = Path(tempfile.mkdtemp(prefix="x442-xrh-nc-"))
    try:
        work = sandbox / "work"
        shutil.copytree(fixture, work, symlinks=True)
        env = _sandbox_home(
            sandbox
        )  # guarantees no user-layer manifest makes it "configured"
        proc, summary_exp = _run_verify(work, env)
        not_configured = "not configured" in proc.stdout and proc.returncode == 0
        # Asserted on the FINDING, not on the exit code. "Not configured" and "the verifier
        # produced nothing at all" both exit 0 with an all-zero summary; only the finding tells
        # them apart, which is the whole reason --json exists.
        findings = gc.verify_findings(VERIFY, work, env=env)
        return [
            summary_exp,
            gc.expectation(
                "an unconfigured workspace is a clean skip (exit 0), not a FAIL",
                not_configured,
                f"exit {proc.returncode}; 'not configured' in output: {'not configured' in proc.stdout}",
            ),
            gc.finding(
                findings,
                "manifest.not_configured",
                "pass",
                label="the verifier SAYS it is unconfigured, rather than merely exiting 0",
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
            [
                "bash",
                str(SYNC),
                "--scope",
                str(work),
                "--tools",
                "claude",
                "--primary",
                "claude",
            ],
            capture_output=True,
            text=True,
            env=env,
        )
        last = (
            (sync.stdout or sync.stderr).strip().splitlines()[-1]
            if (sync.stdout or sync.stderr).strip()
            else "no output"
        )
        exps = [
            gc.expectation(
                f"{tag} sync-cross-repo-handoff.sh completes (exit 0)",
                sync.returncode == 0,
                last,
            )
        ]

        _, summary_exp = _run_verify(work, env)
        summary_exp["text"] = f"{tag} {summary_exp['text']}"
        exps.append(summary_exp)

        # The advisory half. None of these change the exit code, so a grader reading only the
        # status is blind to exactly the checks most likely to rot — a board that stopped
        # projecting the manifest still exits 0 all the way to the first mis-targeted brief.
        findings = gc.verify_findings(VERIFY, work, env=env)
        for fid, label in (
            ("manifest.cascade.resolves", "the cascade resolves"),
            ("board.groups", "each board records its groups"),
            ("board.layout", "each board records its layout"),
            ("member.section", "each member resolves to its section"),
            (
                "registry.projection",
                "each board's registry still projects the manifest",
            ),
        ):
            e = gc.finding(findings, fid, "pass")
            e["text"] = f"{tag} {label}"
            exps.append(e)
        e = gc.no_findings_at(findings, "fail")
        e["text"] = f"{tag} no fail findings"
        exps.append(e)

        # boards scaffolded with the right group facts
        shared_cfg = _board_config(work / ".agents/handoff")
        legacy_cfg = _board_config(work / ".agents/handoff-legacy")
        exps.append(
            gc.expectation(
                f"{tag} shared board config records both co-located groups + layout",
                _groups_csv(shared_cfg) == "auth-suite,infra"
                and shared_cfg.get("groupLayout") == layout,
                (
                    f"groups={_groups_csv(shared_cfg) or 'unset'} layout={shared_cfg.get('groupLayout') or 'unset'}"
                    if shared_cfg
                    else "missing"
                ),
            )
        )
        exps.append(
            gc.expectation(
                f"{tag} legacy group is on its own separate board",
                _groups_csv(legacy_cfg) == "legacy",
                (
                    f"groups={_groups_csv(legacy_cfg) or 'unset'}"
                    if legacy_cfg
                    else "missing"
                ),
            )
        )

        # each member wired to its own section (AGENTS.md block + HANDOFF_GROUP in the hook command)
        for name, group in (
            ("api", "auth-suite"),
            ("kubernetes", "infra"),
            ("monolith", "legacy"),
        ):
            agents = (work / name / "AGENTS.md").read_text(encoding="utf-8")
            block_ok = (
                "cross-repo-handoff:begin" in agents and f"`{group}` section" in agents
            )
            exps.append(
                gc.expectation(
                    f"{tag} {name} AGENTS.md block scoped to {group}",
                    block_ok,
                    f"block present + names {group}: {block_ok}",
                )
            )
            # Wired and scoped are separate facts: the hook command invokes the board, and the
            # member's own config names its section.
            settings = work / name / ".claude/settings.json"
            hook_ok = settings.is_file() and "/scripts/hooks.sh" in settings.read_text()
            exps.append(
                gc.expectation(
                    f"{tag} {name} hooks invoke the board",
                    hook_ok,
                    f"handoff hook in settings.json: {hook_ok}",
                )
            )
            got_group = _member_group(work / name)
            exps.append(
                gc.expectation(
                    f"{tag} {name} resolves to section {group}",
                    got_group == group,
                    f".agents/handoff.json group={got_group or 'unset'}",
                )
            )

        # ledger recorded
        # The ledger moved INSIDE the workspace's own handoff.json, under `_generated`, when every
        # layer was consolidated onto one filename. Asserting the file's existence is no longer the
        # question — `_generated.members` is, since an empty or absent block means --prune has
        # nothing to compare against and drift reporting silently does nothing.
        ledger = _read_json(work / ".agents/handoff.json").get("_generated") or {}
        # Keyed on PATH, not alias: an alias is the manifest's short name for a repo (`k8s` for
        # `kubernetes/`) and comparing it to a directory name asserts a coincidence, not a fact.
        got_paths = sorted(
            {
                os.path.basename(str(m.get("path", "")).rstrip("/"))
                for m in ledger.get("members") or []
            }
        )
        exps.append(
            gc.expectation(
                f"{tag} ledger records every member under _generated",
                got_paths == sorted(MEMBERS),
                f"members={got_paths or 'unset'}",
            )
        )

        # idempotency: commit the FIRST sync's output as the baseline, then re-sync and assert every
        # member repo's git status is clean (the second sync changed nothing).
        for name in MEMBERS:
            gc.git_init_commit(work / name, "post-sync baseline")
        subprocess.run(
            [
                "bash",
                str(SYNC),
                "--scope",
                str(work),
                "--tools",
                "claude",
                "--primary",
                "claude",
            ],
            capture_output=True,
            text=True,
            env=env,
        )
        for name in MEMBERS:
            e = gc.git_diff_empty(work / name)
            e["text"] = f"{tag} {name}: {e['text']}"
            exps.append(e)
        return exps
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def _grade_local_wiring_member(fixture: Path) -> list:
    """A member wired with setup-handoff --local-wiring is healthy, and the fleet verifier says so.

    --local-wiring puts Claude's hooks in .claude/settings.local.json and skips the AGENTS.md block,
    recording `localWiring: true` in the member's .agents/handoff.json. The per-repo verifier honours
    that flag; the fleet verifier used to fail such a member twice and tell the operator to "re-run
    the sync" — which would commit exactly the paths the flag exists to keep out of the repo.
    """
    tag = "[local-wiring]"
    sandbox = Path(tempfile.mkdtemp(prefix="x442-xrh-localwiring-"))
    try:
        work = sandbox / "work"
        shutil.copytree(fixture, work, symlinks=True)
        for name in MEMBERS:
            gc.git_init_commit(work / name, f"{name} baseline")
        env = _sandbox_home(sandbox)
        subprocess.run(
            [
                "bash",
                str(SYNC),
                "--scope",
                str(work),
                "--tools",
                "claude",
                "--primary",
                "claude",
            ],
            capture_output=True,
            text=True,
            env=env,
        )
        local, plain = work / MEMBERS[0], work / MEMBERS[1]
        # Convert the first member to the shape --local-wiring produces.
        cfg_path = local / ".agents" / "handoff.json"
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
        cfg["localWiring"] = True
        cfg_path.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")
        (local / ".claude" / "settings.json").rename(
            local / ".claude" / "settings.local.json"
        )
        # Strip the managed block from both members; only the flagged one may pass without it.
        for repo in (local, plain):
            agents = repo / "AGENTS.md"
            text = agents.read_text(encoding="utf-8")
            text = re.sub(
                r"<!-- cross-repo-handoff:begin.*?<!-- cross-repo-handoff:end -->\n?",
                "",
                text,
                flags=re.S,
            )
            agents.write_text(text, encoding="utf-8")

        findings = gc.verify_findings(VERIFY, work, env=env)

        def levels(fid: str, member: str) -> set:
            return {
                f["level"]
                for f in findings.get(fid, [])
                if f"/{member}" in f.get("message", "")
            }

        return [
            gc.expectation(
                f"{tag} a --local-wiring member with no AGENTS.md block passes member.agents_block",
                levels("member.agents_block", MEMBERS[0]) == {"pass"},
                str(levels("member.agents_block", MEMBERS[0])),
            ),
            gc.expectation(
                f"{tag} its hooks in settings.local.json pass member.claude_hook",
                levels("member.claude_hook", MEMBERS[0]) == {"pass"},
                str(levels("member.claude_hook", MEMBERS[0])),
            ),
            gc.expectation(
                f"{tag} a member without the flag and without the block still fails",
                "fail" in levels("member.agents_block", MEMBERS[1]),
                str(levels("member.agents_block", MEMBERS[1])),
            ),
        ]
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def _run_sync(work: Path, env: dict, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(SYNC), "--scope", str(work), "--tools", "claude"]
        + ["--primary", "claude", *extra],
        capture_output=True,
        text=True,
        env=env,
    )


def _grade_flat(fixture: Path) -> list:
    """A flat board — no sections — synced as flat, and never re-laid out once it holds handoffs.

    The regression: a manifest could not say "flat", so the sync planned `--layout subfolder` for a
    flat board whose documents all sat at its root, and the resolver's error did not stop the plan.
    """
    tag = "[flat]"
    sandbox = Path(tempfile.mkdtemp(prefix="x442-xrh-flat-"))
    try:
        work = sandbox / "work"
        shutil.copytree(fixture, work, symlinks=True)
        manifest = work / ".handoff-repos.json"
        m = json.loads(manifest.read_text(encoding="utf-8"))
        # A flat board hosts one group, so this pass keeps only auth-suite.
        m["layout"] = "flat"
        m["groups"] = {"auth-suite": m["groups"]["auth-suite"]}
        manifest.write_text(json.dumps(m, indent=2) + "\n", encoding="utf-8")
        members = ("api", "web")
        for name in members:
            gc.git_init_commit(work / name, f"{name} baseline")
        env = _sandbox_home(sandbox)
        board = work / ".agents/handoff"

        sync = _run_sync(work, env)
        exps = [
            gc.expectation(
                f"{tag} sync-cross-repo-handoff.sh completes (exit 0)",
                sync.returncode == 0,
                (sync.stdout + sync.stderr).strip()[-300:],
            )
        ]
        _, summary_exp = _run_verify(work, env)
        summary_exp["text"] = f"{tag} {summary_exp['text']}"
        exps.append(summary_exp)

        cfg = _board_config(board)
        exps.append(
            gc.expectation(
                f"{tag} board config records no sections",
                cfg.get("groups") == [] and cfg.get("groupLayout") == "",
                f"groups={cfg.get('groups')!r} layout={cfg.get('groupLayout')!r}",
            )
        )
        for name in members:
            got_group = _member_group(work / name)
            exps.append(
                gc.expectation(
                    f"{tag} {name} records no section",
                    got_group == "",
                    f".agents/handoff.json group={got_group or 'unset'}",
                )
            )
            agents = (work / name / "AGENTS.md").read_text(encoding="utf-8")
            block_ok = (
                "Peers in the `auth-suite` group" in agents
                and "HANDOFF_GROUP=" not in agents
            )
            exps.append(
                gc.expectation(
                    f"{tag} {name} AGENTS.md carries the flat block",
                    block_ok,
                    f"flat block present, no HANDOFF_GROUP: {block_ok}",
                )
            )

        for name in members:
            gc.git_init_commit(work / name, "post-sync baseline")
        _run_sync(work, env)
        for name in members:
            e = gc.git_diff_empty(work / name)
            e["text"] = f"{tag} {name}: {e['text']}"
            exps.append(e)

        # Now the board holds a handoff at its root. A manifest that says anything but "flat" must
        # stop the sync — dry run included — and leave the board's config exactly as it was.
        (board / "live-work-handoff.md").write_text("---\nid: live-work-handoff\n---\n")
        before = (board / "handoff.json").read_text(encoding="utf-8")
        for lay, why in (("subfolder", "never re-lays out"), ("", '"flat"')):
            m["layout"] = lay
            manifest.write_text(json.dumps(m, indent=2) + "\n", encoding="utf-8")
            for extra in (("--dry-run",), ()):
                run = _run_sync(work, env, *extra)
                out = run.stdout + run.stderr
                mode = "dry run" if extra else "sync"
                exps.append(
                    gc.expectation(
                        f"{tag} layout {lay!r}: the {mode} refuses and plans nothing",
                        run.returncode != 0 and why in out and "would:" not in out,
                        f"exit {run.returncode}; {out.strip()[-240:]}",
                    )
                )
        exps.append(
            gc.expectation(
                f"{tag} a refused sync leaves the board config untouched",
                (board / "handoff.json").read_text(encoding="utf-8") == before,
                "handoff.json byte-identical after the refused runs",
            )
        )
        return exps
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def grade_fleet(fixture: Path) -> list:
    exps = []
    for layout in ("subfolder", "prefix"):
        exps.extend(_grade_fleet_layout(fixture, layout))
    exps.extend(_grade_flat(fixture))
    exps.extend(_grade_local_wiring_member(fixture))
    return exps


def grade(target: Path, eval_id: str | None) -> list:
    gc.pre_state_hint(HERE, eval_id)
    if eval_id == "not-configured":
        return grade_not_configured(target)
    if eval_id == "fleet":
        return grade_fleet(target)
    # Default: wrap the verifier against `target` in place (its own scope).
    proc = subprocess.run(
        ["bash", str(VERIFY), "--scope", str(target)], capture_output=True, text=True
    )
    m = gc._SUMMARY_RE.search(proc.stdout)
    summary = m.group(0) if m else "(no Summary line)"
    failed = int(m.group(3)) if m else None
    return [
        gc.expectation(
            "verify-cross-repo-handoff.sh passes",
            proc.returncode == 0 and failed == 0,
            f"{summary} (exit {proc.returncode})",
        )
    ]


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
