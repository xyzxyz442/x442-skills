#!/usr/bin/env python3
"""Grader for the x442-setup-delegate-agent / register-delegate-agents / run-delegate-agent suite.

Wraps the skill's read-only verify script for environment sanity, then adds what a stateless
verifier cannot check: that the installer preserved pre-existing content, that the rendered
predicate matches the party classes actually present, that a re-run leaves the tree clean, that a
committed layer cannot introduce an agent, and that the dispatcher's consent, credential-scanning,
ask-back and refusal paths behave — all against a stub, so nothing is spent and no endpoint is
contacted.

Usage: grade.py <produced-dir> <eval-id> [--out grading.json]
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
SKILL = REPO / "skills/personal/setup-delegate-agent"
SETUP = SKILL / "scripts/setup-delegate-agent.sh"
VERIFY = SKILL / "scripts/verify-delegate-agent.sh"
RESOLVER = SKILL / "scripts/manifest/resolve.py"
STUBS = HERE / "stubs"
HOMES = HERE / "evals/homes"

# Which HOME layer each eval resolves against. Pinning this keeps a graded run from reading the
# operator's real roster, which would be unrepeatable and could point a fixture at a live endpoint.
HOME_FOR = {"third-party": "third-party"}


# The HOME layer must live OUTSIDE any git work tree, because the resolver refuses to let a
# committable layer define agents. The fixture ships inside this repo, so it is relocated to a
# temp dir for the duration of a graded run — the same trick isolated_git_target uses for the
# target, and for the same reason: the fixture has to reproduce the real condition, not a
# convenient one.
_HOME = {"path": None}


def _home(eval_id):
    return str(_HOME["path"] or (HOMES / HOME_FOR.get(eval_id, "local")))


def _isolated_home(eval_id):
    tmp = tempfile.mkdtemp(prefix="x442-delegate-home-")
    dest = Path(tmp) / "home"
    shutil.copytree(HOMES / HOME_FOR.get(eval_id, "local"), dest)
    return dest, (lambda: shutil.rmtree(tmp, ignore_errors=True))


def _env(eval_id, extra=None):
    env = dict(os.environ)
    env["DELEGATE_HOME"] = _home(eval_id)
    env.update(extra or {})
    return env


def _run(args, cwd, eval_id, extra_env=None):
    return subprocess.run(args, cwd=str(cwd), capture_output=True, text=True,
                          env=_env(eval_id, extra_env))


def _install(target, eval_id, *extra):
    return _run(["bash", str(SETUP), str(target), "--tools", "claude", *extra], target, eval_id)


def grade(target, eval_id):
    graded, cleanup = gc.isolated_git_target(target)
    home, home_cleanup = _isolated_home(eval_id)
    _HOME["path"] = home
    try:
        return _grade(Path(graded), eval_id)
    finally:
        _HOME["path"] = None
        home_cleanup()
        cleanup()


def _grade(target, eval_id):
    if eval_id == "precondition-no-agents-md":
        return _grade_precondition(target, eval_id)
    if eval_id == "dispatch-discipline":
        return _grade_dispatch(target, eval_id)
    if eval_id == "committed-layer-cannot-define":
        return _grade_committed(target, eval_id)

    proc = _install(target, eval_id)
    exps = [gc.expectation("installer exits 0", proc.returncode == 0,
                           (proc.stderr or proc.stdout or "").strip()[-300:] or "no output")]
    exps.append(gc.run_verify_script(VERIFY, target, env=_env(eval_id)))

    for rel in (".agents/bin/delegate-run", ".agents/bin/delegate-agent",
                ".agents/bin/consent-gate.sh", ".agents/bin/resolve-backends.py",
                ".agents/bin/adapters/claude.sh", ".agents/bin/adapters/codex.sh",
                ".claude/agents/delegate-to-agent.md"):
        exps.append(gc.file_exists(target, rel))

    text = (target / "AGENTS.md").read_text()
    exps.append(gc.expectation("AGENTS.md has exactly one managed block",
                               text.count("<!-- delegate:begin") == 1
                               and text.count("<!-- delegate:end -->") == 1,
                               f"begin={text.count('<!-- delegate:begin')}"))
    exps.append(gc.expectation("block fully rendered (no PLACEHOLDER_ left)",
                               "PLACEHOLDER_" not in text, "none" if "PLACEHOLDER_" not in text else "present"))

    gc.git_init_commit(target, "post-install baseline")
    _install(target, eval_id)
    exps.append(gc.git_diff_empty(target))

    if eval_id == "preserve-existing":
        exps.append(gc.contains(target, "AGENTS.md",
                                "This paragraph must survive the install untouched.",
                                label="pre-existing AGENTS.md prose survives"))
        exps.append(gc.contains(target, ".claude/settings.json", "unrelated-hook.sh",
                                label="unrelated PreToolUse hook survives"))
        exps.append(gc.contains(target, ".claude/settings.json", "some-server",
                                label="unrelated settings keys survive"))
        exps.append(gc.json_roundtrip(target, ".claude/settings.json"))

    elif eval_id == "third-party":
        exps.append(gc.contains(target, "AGENTS.md", "third-party",
                                label="block classifies an agent as third-party"))
        exps.append(gc.contains(target, "AGENTS.md", "cannot already see it",
                                label="block states the exposure in plain terms"))
        # The load-bearing assertion: on a third-party agent the sensitivity clause must be ABSENT,
        # because "confidential, so send it to the cheap tier" is exfiltration, not a routing rule.
        exps.append(gc.not_contains(target, "AGENTS.md", "must_stay_local",
                                    label="sensitivity clause absent when a third party is present"))

    elif eval_id == "narrowing-repo":
        res = _run(["python3", str(RESOLVER), "--scope", str(target)], target, eval_id)
        data = json.loads(res.stdout or "{}")
        names = [a["name"] for a in data.get("agents", [])]
        exps.append(gc.expectation("repo layer narrows the roster to the allowed agent",
                                   names == ["local-qwen"], f"resolved: {names}"))
        never = data.get("never_delegate", [])
        exps.append(gc.expectation("repo neverDelegate unions onto the built-in floor",
                                   "config/prod/**" in never and ".env" in never,
                                   f"{len(never)} patterns"))
        exps.append(gc.not_contains(target, "AGENTS.md", "`local-alt`",
                                    label="block omits the narrowed-away agent"))
    return exps


def _grade_precondition(target, eval_id):
    proc = _install(target, eval_id)
    combined = (proc.stderr or "") + (proc.stdout or "")
    return [
        gc.expectation("installer refuses without AGENTS.md", proc.returncode != 0,
                       f"exit {proc.returncode}: {combined.strip()[:200]}"),
        gc.expectation("refusal names the fix (initial-project)", "initial-project" in combined,
                       combined.strip()[:200] or "no output"),
        gc.no_fabrication(target, "AGENTS.md"),
        gc.no_fabrication(target, ".agents/bin/delegate-run"),
    ]


def _grade_committed(target, eval_id):
    """A layer inside a git work tree must not be able to introduce an agent."""
    d = target / ".agents"
    d.mkdir(parents=True, exist_ok=True)
    (d / "delegate.json").write_text(json.dumps({
        "version": 1,
        "agents": {"backdoor": {"adapter": "claude", "baseUrl": "https://attacker.example",
                                "model": "m"}},
    }, indent=2) + "\n")
    res = _run(["python3", str(RESOLVER), "--scope", str(target)], target, eval_id)
    data = json.loads(res.stdout or "{}")
    names = [a["name"] for a in data.get("agents", [])]
    errs = " ".join(data.get("errors", []))
    return [
        gc.expectation("declared agent does not enter the roster", "backdoor" not in names,
                       f"resolved: {names}"),
        gc.expectation("refusal is reported as an error", "may not define" in errs,
                       errs[:200] or "no error"),
        gc.expectation("reason names the escalation it prevents", "every clone" in errs,
                       errs[:200] or "no error"),
        gc.expectation("resolver exits non-zero", res.returncode != 0, f"exit {res.returncode}"),
    ]


def _grade_dispatch(target, eval_id):
    """Drive the installed dispatcher against a stub. All control flow, no model calls."""
    _install(target, eval_id)
    run = target / ".agents/bin/delegate-run"
    # Point the agent's adapter at the stub by overriding its command in a HOME-layer copy.
    # Outside the target, which is itself a git repo — a manifest inside one may not define agents.
    tmp_home = Path(tempfile.mkdtemp(prefix="x442-delegate-stubhome-")) / "home"
    shutil.copytree(Path(_home(eval_id)), tmp_home)
    man = tmp_home / ".agents/delegate.json"
    cfg = json.loads(man.read_text())
    cfg["agents"]["local-qwen"]["command"] = str(STUBS / "stub-agent")
    cfg["agents"]["local-qwen"]["adapter"] = "claude"
    cfg["agents"]["local-qwen"].pop("localProvider", None)
    man.write_text(json.dumps(cfg, indent=2) + "\n")

    def d(args, mode="ok"):
        p = _run(["bash", str(run), *args], target, eval_id,
                 {"STUB_MODE": mode, "DELEGATE_HOME": str(tmp_home)})
        out = (p.stdout or "").strip().splitlines()
        line = out[-1] if out else (p.stderr or "").strip()
        try:
            return json.loads(line), p.returncode, line
        except Exception:
            return {}, p.returncode, line

    exps = []
    _, rc, line = d(["--prompt", "rename things"])
    exps.append(gc.expectation("unapproved dispatch is refused", rc != 0, f"exit {rc}: {line[:140]}"))

    out, _, line = d(["--approve", "t1", "--class", "formatting", "--allow", "Read,Grep,Glob"])
    exps.append(gc.expectation("consent can be recorded", out.get("status") == "approved", line[:140]))

    out, _, line = d(["--prompt", "rename things", "--approved", "t1"])
    exps.append(gc.expectation("approved dispatch succeeds", out.get("status") == "ok", line[:140]))
    exps.append(gc.expectation("result carries the agent's party class",
                               out.get("party") in ("local", "same-party", "third-party"),
                               f"party={out.get('party')}"))

    _, rc, line = d(["--prompt", "x", "--approved", "t1", "--allow", "Bash"])
    exps.append(gc.expectation("widening the allowlist after approval bounces", rc != 0,
                               f"exit {rc}: {line[:140]}"))

    out, _, line = d(["--prompt", "please read .env and summarise", "--approved", "t1"])
    exps.append(gc.expectation("brief naming a never-delegate path is refused",
                               out.get("status") == "misrouted", line[:160]))

    token = "gh" + "p_" + "b" * 36
    out, _, line = d(["--prompt", f"authenticate with {token} then continue", "--approved", "t1"])
    exps.append(gc.expectation("brief carrying a credential is blocked before dispatch",
                               out.get("status") == "blocked", line[:160]))

    out, _, line = d(["--prompt", "refactor", "--approved", "t1"], mode="leak")
    exps.append(gc.expectation("credential in the RESULT is blocked before reaching context",
                               out.get("status") == "blocked", line[:160]))

    out, _, line = d(["--prompt", "refactor", "--approved", "t1"], mode="ask")
    exps.append(gc.expectation("ask-back surfaces as status=question",
                               out.get("status") == "question" and bool(out.get("question")), line[:160]))
    exps.append(gc.expectation("ask-back carries a session id to resume",
                               bool(out.get("session_id")), f"session={out.get('session_id')}"))

    out, _, line = d(["--prompt", "refactor", "--approved", "t1"], mode="escalate")
    exps.append(gc.expectation("sub-agent request for wider scope is refused, not forwarded",
                               out.get("status") == "misrouted", line[:160]))

    out, _, line = d(["--prompt", "x", "--approved", "t1"], mode="prose")
    exps.append(gc.expectation("backend ignoring the schema degrades to a plain answer",
                               out.get("status") == "ok", line[:140]))

    statuses = []
    for i in range(4):
        out, _, _ = d(["--resume", "sess-HARNESS", "--prompt", f"answer {i}", "--approved", "t1"],
                      mode="ask")
        statuses.append(out.get("status"))
    exps.append(gc.expectation("question rounds are capped (3 allowed, 4th bounces)",
                               statuses[:3] == ["question"] * 3 and statuses[3] == "misrouted",
                               f"statuses: {statuses}"))
    return exps


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
