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

`embed-provider-guard` fires `.graph-hooks/core/embed-provider.sh` and `embed-health.sh`
directly (no dispatcher involved) against a fresh scratch copy per scenario, with synthetic
env vars and a hand-seeded `.code-review-graph/graph.db`. Every scenario's ambient environment
is scrubbed of real `CRG_*`/cloud-key vars first, so the check is deterministic regardless of
what the grading machine happens to have exported — offline, no network, no real credentials.

Usage:
    python3 grade.py <produced-project-dir> [eval_id] [--out grading.json]

`eval_id` is one of the ids in evals/evals.json (no-agents-md | fresh-wired | all-wired |
copilot-primary-wired | both-wired | graph-search-behavior | embed-provider-guard). With no
eval_id, only the verifier-wrap assertion runs. Exits 0 iff nothing failed.
"""

import hashlib
import json
import os
import shutil
import sqlite3
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
        cwd=str(repo),
        input=json.dumps(payload),
        capture_output=True,
        text=True,
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
        return [
            gc.expectation(
                "graph hooks dispatcher present for behavior test",
                False,
                f"{GRAPH_HOOKS_DIR}/hook.sh missing",
            )
        ]

    exps: list[gc.Expectation] = []

    session = _fire_hook(target, "claude", "sessionstart", {})
    ctx = _context(session)
    exps.append(
        gc.expectation(
            "session start injects a graph cheatsheet (CRG + graphify + routing tools)",
            bool(session)
            and "CRG" in ctx
            and "graphify" in ctx
            and "semantic_search_nodes_tool" in ctx,
            f"additionalContext: {ctx[:200]!r}" if session else NO_HOOK_OUTPUT,
        )
    )

    read_out = _fire_hook(
        target,
        "claude",
        "pretool-read",
        {"tool_input": {"file_path": "src/billing.ts"}},
    )
    ctx = _context(read_out)
    exps.append(
        gc.expectation(
            "reading a source file is nudged toward the graph instead of reading one-by-one",
            bool(read_out)
            and ("semantic_search_nodes_tool" in ctx or "graphify" in ctx),
            f"additionalContext: {ctx[:200]!r}" if read_out else NO_HOOK_OUTPUT,
        )
    )

    _reset_slot(target)
    bypass_out = _fire_hook(
        target,
        "claude",
        "pretool-shell",
        {
            "tool_input": {
                "command": "grep -rn calculateInvoiceTotal src/ --graph-tried"
            }
        },
    )
    exps.append(
        gc.expectation(
            "--graph-tried bypass is honored (no steering, even with a graph hit available)",
            bypass_out is None,
            (
                "no output (bypassed)"
                if bypass_out is None
                else f"unexpected output: {json.dumps(bypass_out)[:200]}"
            ),
        )
    )

    md_out = _fire_hook(
        target,
        "claude",
        "pretool-shell",
        {"tool_input": {"command": "grep -rn calculateInvoiceTotal README.md"}},
    )
    exps.append(
        gc.expectation(
            "grep against non-code files (.md) is never intercepted",
            md_out is None,
            (
                "no output (ignored)"
                if md_out is None
                else f"unexpected output: {json.dumps(md_out)[:200]}"
            ),
        )
    )

    _reset_slot(target)
    first = _fire_hook(
        target,
        "claude",
        "pretool-shell",
        {"tool_input": {"command": "grep -rn calculateInvoiceTotal src/"}},
    )
    first_ctx = _context(first)
    exps.append(
        gc.expectation(
            "first grep for a real symbol is pre-answered from the graph and still allowed",
            bool(first)
            and "calculateInvoiceTotal" in first_ctx
            and "src/billing.ts" in first_ctx
            and _decision(first) != "block",
            f"additionalContext: {first_ctx[:200]!r}" if first else NO_HOOK_OUTPUT,
        )
    )

    second = _fire_hook(
        target,
        "claude",
        "pretool-shell",
        {"tool_input": {"command": "grep -rn calculateInvoiceTotal src/"}},
    )
    exps.append(
        gc.expectation(
            "repeating the same grep is BLOCKED once the graph already answered it",
            _decision(second) == "block",
            (
                f"second grep output: {json.dumps(second)[:200]}"
                if second
                else NO_HOOK_OUTPUT
            ),
        )
    )
    _reset_slot(target)

    # A miss must be tested in a throwaway copy: the miss itself consumes the one-shot
    # allowance, and doing that against `target` would poison the assertions above on rerun.
    miss_copy = Path(tempfile.mkdtemp(prefix="sgh-miss-"))
    try:
        shutil.copytree(target, miss_copy, dirs_exist_ok=True)
        _reset_slot(miss_copy)
        miss = _fire_hook(
            miss_copy,
            "claude",
            "pretool-shell",
            {"tool_input": {"command": "grep -rn totallyMissingSymbolXyz src/"}},
        )
        miss_ctx = _context(miss)
        exps.append(
            gc.expectation(
                "a first-time miss still allows the grep, pointing at the graph tool for next time",
                bool(miss)
                and _decision(miss) != "block"
                and (
                    "graphify" in miss_ctx or "semantic_search_nodes_tool" in miss_ctx
                ),
                f"additionalContext: {miss_ctx[:200]!r}" if miss else NO_HOOK_OUTPUT,
            )
        )
    finally:
        _reset_slot(miss_copy)
        shutil.rmtree(miss_copy, ignore_errors=True)

    return exps


# ---- embed-provider-guard --------------------------------------------------------------------
# Regression coverage for the embed-provider fixes: resolve() no longer infers a cloud provider
# from an ambient API key, embed-health.sh reports unknown provider names and the vulnerable
# "cloud key + no explicit provider" consent case instead of staying silent, and the tier label
# reports the recorded model rather than a vendor name guessed from a port number.
#
# Every scenario below fires the fixture's OWN copies of embed-provider.sh / embed-health.sh
# (installed under .graph-hooks/core, not the skill's source copy) directly — no dispatcher, no
# hook.sh involved — against a throwaway copy of the fixture, so mutating embed.env / graph.db
# for one scenario can never leak into another.
EMBED_CFG = ".code-review-graph/embed.env"
EMBED_DB = ".code-review-graph/graph.db"

# Real-shaped-looking env vars a scenario might legitimately need (an OpenAI-compatible trio, a
# cloud API key) are obviously-synthetic placeholders, never anything that could pass for a real
# credential. Every ambient var of the same name is also scrubbed from the subprocess env below,
# so a real key exported on the grading machine can never leak into — or skew — a result.
_AMBIENT_SCRUB = (
    "CRG_EMBEDDING_PROVIDER",
    "CRG_EMBEDDING_MODEL",
    "CRG_OPENAI_BASE_URL",
    "CRG_OPENAI_API_KEY",
    "CRG_OPENAI_MODEL",
    "GOOGLE_API_KEY",
    "MINIMAX_API_KEY",
    "VOYAGE_API_KEY",
)


def _embed_scratch(target: Path) -> Path:
    """A fresh throwaway copy of `target` for one embed-provider-guard scenario."""
    tmp = Path(tempfile.mkdtemp(prefix="sgh-embed-"))
    dest = tmp / "repo"
    shutil.copytree(target, dest)
    return dest


def _write_embed_env(repo: Path, content: str) -> None:
    cfg = repo / EMBED_CFG
    cfg.parent.mkdir(parents=True, exist_ok=True)
    cfg.write_text(content, encoding="utf-8")


def _seed_embeddings_db(repo: Path, rows: list[str]) -> None:
    """(Re)write `.code-review-graph/graph.db`'s embeddings table to hold exactly `rows`."""
    db = repo / EMBED_DB
    db.parent.mkdir(parents=True, exist_ok=True)
    db.unlink(missing_ok=True)
    conn = sqlite3.connect(str(db))
    conn.execute("CREATE TABLE embeddings (provider TEXT)")
    conn.executemany("INSERT INTO embeddings VALUES (?)", [(r,) for r in rows])
    conn.commit()
    conn.close()


def _drop_embeddings_db(repo: Path) -> None:
    (repo / EMBED_DB).unlink(missing_ok=True)


def _run_embed_script(
    repo: Path, script: str, *args: str, extra_env: dict | None = None
) -> subprocess.CompletedProcess:
    """Run `.graph-hooks/core/<script>` with a scrubbed ambient env plus `extra_env`."""
    env = dict(os.environ)
    for key in _AMBIENT_SCRUB:
        env.pop(key, None)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", str(repo / GRAPH_HOOKS_DIR / "core" / script), *args],
        cwd=str(repo),
        capture_output=True,
        text=True,
        env=env,
    )


def grade_embed_provider_guard(target: Path) -> list[gc.Expectation]:
    """Fire embed-provider.sh / embed-health.sh with synthetic env/config and assert what they
    DECIDE — proving the two fixed defects (silent cloud-key inference, a stale hand-copied
    provider allow-list, a vendor name guessed from a port) cannot come back."""
    core = target / GRAPH_HOOKS_DIR / "core"
    if (
        not (core / "embed-provider.sh").is_file()
        or not (core / "embed-health.sh").is_file()
    ):
        return [
            gc.expectation(
                "embed-provider.sh and embed-health.sh present for behavior test",
                False,
                f"{GRAPH_HOOKS_DIR}/core/{{embed-provider.sh,embed-health.sh}} missing",
            )
        ]

    exps: list[gc.Expectation] = []

    # 0. The scripts under test must be the ones the skill currently ships.
    #
    # Every other fixture in this repo that carries these two files drifted: at the time this case
    # was written, 9 of the 10 still held the pre-fix embed-provider.sh, cloud-key inference and
    # all. A behavioral case graded directly against a frozen fixture would keep reporting PASS
    # against code the skill no longer ships — the eval equivalent of the silent rot this whole
    # case exists to catch. In the normal flow the produced workspace is installed from source and
    # this is trivially true; graded directly, it is the only thing standing between this fixture
    # and the same fate.
    for name in ("embed-provider.sh", "embed-health.sh"):
        shipped = (
            REPO
            / "skills/engineering/setup-graph-hooks/scripts/graph-hooks/core"
            / name
        )
        same = shipped.is_file() and shipped.read_bytes() == (core / name).read_bytes()
        exps.append(
            gc.expectation(
                f"{name} under test matches the skill's shipped copy",
                same,
                (
                    "identical to skill source"
                    if same
                    else f"{name} differs from {shipped} — fixture is stale, results below are about old code"
                ),
            )
        )

    # 1-2. An ambient cloud key alone must never select a provider (the silent-egress defect).
    for key in ("GOOGLE_API_KEY", "MINIMAX_API_KEY"):
        repo = _embed_scratch(target)
        out = _run_embed_script(
            repo, "embed-provider.sh", extra_env={key: "fake-not-a-real-key"}
        )
        exps.append(
            gc.expectation(
                f"ambient {key} alone does not select a provider",
                out.returncode == 0 and out.stdout.strip() == "",
                f"stdout: {out.stdout.strip()!r}",
            )
        )
        shutil.rmtree(repo.parent, ignore_errors=True)

    # 3-4. An explicit CRG_EMBEDDING_PROVIDER is honoured verbatim.
    for provider in ("voyage", "google"):
        repo = _embed_scratch(target)
        _write_embed_env(repo, f"CRG_EMBEDDING_PROVIDER={provider}\n")
        out = _run_embed_script(repo, "embed-provider.sh")
        exps.append(
            gc.expectation(
                f"explicit CRG_EMBEDDING_PROVIDER={provider} is honoured",
                out.returncode == 0 and out.stdout.strip() == provider,
                f"stdout: {out.stdout.strip()!r}",
            )
        )
        shutil.rmtree(repo.parent, ignore_errors=True)

    # 5. A complete CRG_OPENAI_* trio is still inferred with no explicit provider set.
    repo = _embed_scratch(target)
    _write_embed_env(
        repo,
        "CRG_OPENAI_BASE_URL=http://localhost:1234/v1\n"
        "CRG_OPENAI_API_KEY=fake-not-a-real-key\n"
        "CRG_OPENAI_MODEL=fake-embed-model\n",
    )
    out = _run_embed_script(repo, "embed-provider.sh")
    exps.append(
        gc.expectation(
            "a complete CRG_OPENAI_* trio is still inferred as openai",
            out.returncode == 0 and out.stdout.strip() == "openai",
            f"stdout: {out.stdout.strip()!r}",
        )
    )
    shutil.rmtree(repo.parent, ignore_errors=True)

    # 6. An unrecognised provider name is REPORTED by embed-health.sh, not silently dropped.
    # Dropped graph.db keeps this scenario isolated from the drift check below -- an unknown
    # provider is still an unknown provider whether or not a graph happens to exist yet.
    repo = _embed_scratch(target)
    _drop_embeddings_db(repo)
    _write_embed_env(repo, "CRG_EMBEDDING_PROVIDER=totally-not-a-provider\n")
    out = _run_embed_script(
        repo,
        "embed-health.sh",
        extra_env={"CRG_EMBEDDING_PROVIDER": "totally-not-a-provider"},
    )
    lines = [line for line in out.stdout.splitlines() if line.strip()]
    exps.append(
        gc.expectation(
            "an unknown CRG_EMBEDDING_PROVIDER name is reported by embed-health.sh",
            out.returncode == 0 and any(line.startswith("unknown") for line in lines),
            f"stdout lines: {lines!r}",
        )
    )
    shutil.rmtree(repo.parent, ignore_errors=True)

    # 7. graph.db present + ambient cloud key + no explicit provider -> the consent notice fires.
    # embed-health.sh:33 exits early with neither a graph.db nor an embed.env present (a repo that
    # never opted in has nothing to be wrong about) -- that early exit is correct and untouched;
    # the consent notice is reachable only once a graph exists, which this scenario provides.
    repo = _embed_scratch(target)
    _seed_embeddings_db(repo, [])
    out = _run_embed_script(
        repo, "embed-health.sh", extra_env={"GOOGLE_API_KEY": "fake-not-a-real-key"}
    )
    lines = [line for line in out.stdout.splitlines() if line.strip()]
    exps.append(
        gc.expectation(
            "graph.db + ambient cloud key + no explicit provider raises a consent notice",
            out.returncode == 0 and any(line.startswith("consent") for line in lines),
            f"stdout lines: {lines!r}",
        )
    )
    shutil.rmtree(repo.parent, ignore_errors=True)

    # 8. A clean, never-configured repo with no graph stays completely silent.
    repo = _embed_scratch(target)
    _drop_embeddings_db(repo)
    out = _run_embed_script(repo, "embed-health.sh")
    exps.append(
        gc.expectation(
            "a clean repo with nothing configured and no graph emits no output",
            out.returncode == 0 and out.stdout.strip() == "",
            f"stdout: {out.stdout.strip()!r}",
        )
    )
    shutil.rmtree(repo.parent, ignore_errors=True)

    # 9. The tier label reports the recorded MODEL, never a vendor guessed from a port number.
    # The shipped fixture already carries this exact row; reseed explicitly anyway so the
    # assertion does not depend on what the fixture happens to ship.
    repo = _embed_scratch(target)
    _seed_embeddings_db(repo, ["openai:text-embedding-qwen3@http://localhost:1234"])
    out = _run_embed_script(repo, "embed-provider.sh", "--tier")
    tier = out.stdout.strip()
    exps.append(
        gc.expectation(
            "--tier reports the model, never a vendor name guessed from the port",
            out.returncode == 0
            and tier == "custom text-embedding-qwen3"
            and "lmstudio" not in tier,
            f"stdout: {tier!r}",
        )
    )
    shutil.rmtree(repo.parent, ignore_errors=True)

    # 10. A correctly-configured cloud provider must not be misreported as drifting: `want` used
    # to be empty for any provider whose identity cannot be reconstructed from the write-side
    # config alone (any cloud provider but openai), making `have != want` true even when the
    # graph and the config agree -- a false positive on a healthy repo.
    repo = _embed_scratch(target)
    _seed_embeddings_db(repo, ["google:text-embedding-004"])
    _write_embed_env(repo, "CRG_EMBEDDING_PROVIDER=google\n")
    out = _run_embed_script(
        repo, "embed-health.sh", extra_env={"GOOGLE_API_KEY": "fake-not-a-real-key"}
    )
    exps.append(
        gc.expectation(
            "a correctly-configured cloud provider produces no drift false positive",
            out.returncode == 0 and out.stdout.strip() == "",
            f"stdout: {out.stdout.strip()!r}",
        )
    )
    shutil.rmtree(repo.parent, ignore_errors=True)

    return exps


def grade(target: Path, eval_id: str | None) -> list[gc.Expectation]:
    """Grade in an isolated copy when `target` is nested in a larger repo.

    verify-graph-hooks.sh, git_diff_empty, and the graph hooks all resolve the git toplevel; a
    fixture inside x442-skills would otherwise be graded against x442-skills. isolated_git_target
    relocates it to its own git root first (no-op when it already is one).
    """
    gc.pre_state_hint(HERE, eval_id)
    graded, cleanup = gc.isolated_git_target(target)
    if graded != Path(target).resolve():
        print(
            f"[grade] isolated fixture to its own git root: {graded}", file=sys.stderr
        )
    try:
        return _grade(graded, eval_id)
    finally:
        cleanup()


# Warnings a correctly wired fixture still legitimately emits, so no_findings_at can assert the
# rest. Keep this list SHORT and justified -- every entry is a check nobody is watching any more.
ADVISORY_OK = {
    # Fixture-shaped, not install-shaped: the fixtures carry no committed git hook, and the
    # graders run them without building a CRG or graphify graph first.
    "git.post_commit.missing",
    "graph.built",
    "graphify.built",
}


def _grade(target: Path, eval_id: str | None) -> list[gc.Expectation]:
    if eval_id == "no-agents-md":
        # Precondition case: the skill must refuse and fabricate nothing. The verifier is NOT
        # the source of truth here (it grades a wired repo), so assert the negatives directly.
        return [
            gc.no_fabrication(target, "AGENTS.md"),
            gc.no_fabrication(target, GRAPH_HOOKS_DIR),
        ]
    if eval_id == "graph-search-behavior":
        return [gc.run_verify_script(VERIFY, target)] + grade_graph_search_behavior(
            target
        )
    if eval_id == "embed-provider-guard":
        # Purpose-built behavioral fixture, not a fully wired repo (no hook.sh, no per-tool
        # config) -- it exists only to fire embed-provider.sh / embed-health.sh directly, so
        # verify-graph-hooks.sh (which grades overall wiring) does not apply here.
        return grade_embed_provider_guard(target)

    exps = [gc.run_verify_script(VERIFY, target)]
    # The advisory half of the verifier. An AGENTS.md block that predates the search-tier ladder
    # or the search_mode honesty rule, a payload stamp that no longer matches, an un-excluded
    # .code-review-graph/ -- all WARNINGS, none of which move the exit code, so run_verify_script
    # above passes whether they fired or not. These are precisely the "installed once, never
    # refreshed" drifts this skill exists to prevent, so assert them on the --json channel.
    findings = gc.verify_findings(VERIFY, target)
    exps.append(gc.finding(findings, "payload.version", "pass"))
    exps.append(gc.finding(findings, "block.search_tier", "pass"))
    exps.append(gc.finding(findings, "block.search_mode", "pass"))
    exps.append(gc.no_findings_at(findings, "warn", ignore=ADVISORY_OK))
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
        exps.append(
            gc.not_contains(
                target,
                CLAUDE_CONFIG,
                "Stop",
                label="claude config has no end-of-turn Stop hook (copilot owns refresh)",
            )
        )
        exps.append(gc.git_diff_empty(target))
    return exps


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
