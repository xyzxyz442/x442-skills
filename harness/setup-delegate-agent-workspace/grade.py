#!/usr/bin/env python3
"""Grader for the x442-setup-delegate-agent / x442-run-delegate-agent pair.

Two layers, like every grader here. It wraps the skill's read-only `verify-delegate-agent.sh`
for environment sanity, then adds what a stateless verifier cannot check itself: that the
installer preserved pre-existing content, that the rendered predicate matches the profile's
egress class, that a re-run leaves the tree clean, and that the dispatcher's consent, ask-back,
and refusal paths actually behave — driven against a stub backend so nothing is spent and no
endpoint is contacted.

Usage: grade.py <produced-dir> <eval-id> [--out grading.json]
"""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "lib"))
import grade_common as gc  # noqa: E402

REPO = gc.repo_root(HERE)
SKILL = REPO / "skills/personal/setup-delegate-agent"
SETUP = SKILL / "scripts/setup-delegate-agent.sh"
VERIFY = SKILL / "scripts/verify-delegate-agent.sh"
STUBS = HERE / "stubs"
MANIFESTS = HERE / "evals/manifests"

# Which user-level manifest each eval resolves against. Pinning this is what keeps a graded run
# from reading the operator's real backend config — which would be unrepeatable, and could point
# a fixture at a live endpoint.
MANIFEST_FOR = {
    "remote-profile": "remote.json",
    "narrowing-repo-layer": "local.json",
}


def _env(extra=None):
    """Environment for every subprocess: stubbed PATH, pinned manifest.

    The stub `timeout` matters because stock macOS has no GNU coreutils, and without it the
    dispatcher stops at its dependency preflight — which would grade as "refused correctly"
    while testing nothing at all.
    """
    env = dict(os.environ)
    env["PATH"] = f"{STUBS}{os.pathsep}{env.get('PATH', '')}"
    env.update(extra or {})
    return env


def _manifest(eval_id):
    return str(MANIFESTS / MANIFEST_FOR.get(eval_id, "local.json"))


def _run(args, target, eval_id, extra_env=None):
    return subprocess.run(
        args, cwd=str(target), capture_output=True, text=True,
        env=_env({"DELEGATE_USER_MANIFEST": _manifest(eval_id), **(extra_env or {})}),
    )


def _install(target, eval_id, *extra):
    return _run(["bash", str(SETUP), str(target), "--tools", "claude", *extra], target, eval_id)


def _agents_text(target):
    p = Path(target) / "AGENTS.md"
    return p.read_text() if p.is_file() else ""


def grade(target, eval_id):
    graded, cleanup = gc.isolated_git_target(target)
    try:
        return _grade(Path(graded), eval_id)
    finally:
        cleanup()


def _grade(target, eval_id):  # noqa: C901
    if eval_id == "precondition-no-agents-md":
        return _grade_precondition(target, eval_id)
    if eval_id == "dispatch-discipline":
        return _grade_dispatch(target, eval_id)

    proc = _install(target, eval_id)
    exps = [gc.expectation("installer exits 0", proc.returncode == 0,
                           (proc.stderr or proc.stdout or "").strip()[-400:] or "no output")]
    exps.append(gc.run_verify_script(
        VERIFY, target, env=_env({"DELEGATE_USER_MANIFEST": _manifest(eval_id)})))

    for rel in (".agents/bin/delegate-run", ".agents/bin/delegate-agent",
                ".agents/bin/consent-gate.sh", ".agents/bin/resolve-backends.py",
                ".claude/agents/delegate-to-agent.md"):
        exps.append(gc.file_exists(target, rel))
    for rel in (".agents/bin/delegate-run", ".agents/bin/consent-gate.sh"):
        exps.append(gc.expectation(f"{rel} is executable",
                                   os.access(target / rel, os.X_OK), f"mode ok: {rel}"))

    text = _agents_text(target)
    exps.append(gc.expectation("AGENTS.md has exactly one managed block",
                               text.count("<!-- delegate:begin") == 1
                               and text.count("<!-- delegate:end -->") == 1,
                               f"begin={text.count('<!-- delegate:begin')} "
                               f"end={text.count('<!-- delegate:end -->')}"))
    exps.append(gc.expectation("block fully rendered (no PLACEHOLDER_ left)",
                               "PLACEHOLDER_" not in text,
                               "PLACEHOLDER_ present" if "PLACEHOLDER_" in text else "none"))

    # Idempotency: commit the install, run it again, demand an empty diff. A skill that rewrites
    # on every run turns `git status` into noise and hides the change that actually matters.
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

    elif eval_id == "remote-profile":
        exps.append(gc.contains(target, "AGENTS.md", "egress **remote**",
                                label="block classifies the profile as remote"))
        exps.append(gc.contains(target, "AGENTS.md", "leaves this machine",
                                label="block states that code leaves the machine"))
        # The load-bearing assertion of this whole eval: on a remote backend the sensitivity
        # clause must be absent, because "confidential, so send it to the cheap tier" is
        # exfiltration rather than a routing rule.
        exps.append(gc.not_contains(target, "AGENTS.md", "must_stay_local",
                                    label="sensitivity clause absent for a remote profile"))
        exps.append(gc.contains(target, "AGENTS.md", "sensitivity NEVER routes here",
                                label="predicate states sensitivity never routes remote"))

    elif eval_id == "narrowing-repo-layer":
        res = _run(["python3", str(SKILL / "scripts/manifest/resolve.py"),
                    "--scope", str(target), "--root", str(target)], target, eval_id)
        data = json.loads(res.stdout or "{}")
        names = [p["name"] for p in data.get("profiles", [])]
        exps.append(gc.expectation("repo layer narrows the profile set to the allowed one",
                                   names == ["lmstudio"], f"resolved: {names}"))
        never = data.get("never_delegate", [])
        exps.append(gc.expectation("repo neverDelegate patterns union onto the built-in floor",
                                   "config/prod/**" in never and ".env" in never,
                                   f"{len(never)} patterns, incl: {never[:3]} ... {never[-2:]}"))
        exps.append(gc.contains(target, "AGENTS.md", "`lmstudio`",
                                label="block names the surviving profile"))

    return exps


def _grade_precondition(target, eval_id):
    """A missing AGENTS.md must stop the install, and must not be papered over."""
    proc = _install(target, eval_id)
    combined = (proc.stderr or "") + (proc.stdout or "")
    return [
        gc.expectation("installer refuses without AGENTS.md", proc.returncode != 0,
                       f"exit {proc.returncode}: {combined.strip()[:200]}"),
        gc.expectation("refusal names the fix (initial-project)",
                       "initial-project" in combined,
                       combined.strip()[:200] or "no output"),
        gc.no_fabrication(target, "AGENTS.md"),
        gc.no_fabrication(target, ".agents/bin/delegate-run"),
        gc.no_fabrication(target, ".claude/agents/delegate-to-agent.md"),
    ]


def _grade_dispatch(target, eval_id):
    """Drive the installed dispatcher against a stub backend.

    Everything here is control flow: consent, scope, the never-delegate floor, ask-back, and the
    round cap. No real backend is involved, so a failure is a defect in the dispatcher rather
    than a flaky model.
    """
    _install(target, eval_id)
    run = target / ".agents/bin/delegate-run"
    # The stub stands in for the wrapper the installer just placed.
    shutil.copy2(STUBS / "delegate-agent", target / ".agents/bin/delegate-agent")
    (target / ".agents/bin/delegate-agent").chmod(0o755)

    def d(args, mode="ok"):
        p = _run(["bash", str(run), *args], target, eval_id, {"STUB_MODE": mode})
        line = (p.stdout or "").strip().splitlines()[-1] if p.stdout.strip() else (p.stderr or "").strip()
        try:
            return json.loads(line), p.returncode, line
        except Exception:
            return {}, p.returncode, line

    exps = []
    _, rc, line = d(["--prompt", "rename things"])
    exps.append(gc.expectation("unapproved dispatch is refused", rc != 0, f"exit {rc}: {line[:160]}"))

    out, rc, line = d(["--approve", "t1", "--class", "formatting", "--allow", "Read,Grep,Glob"])
    exps.append(gc.expectation("consent can be recorded", out.get("status") == "approved", line[:160]))

    out, rc, line = d(["--prompt", "rename things", "--approved", "t1"])
    exps.append(gc.expectation("approved dispatch succeeds", out.get("status") == "ok", line[:160]))
    exps.append(gc.expectation("result carries the profile's egress class",
                               out.get("egress") in ("local", "remote"), f"egress={out.get('egress')}"))

    _, rc, line = d(["--prompt", "x", "--approved", "t1", "--allow", "Bash"])
    exps.append(gc.expectation("widening the allowlist after approval bounces", rc != 0,
                               f"exit {rc}: {line[:160]}"))

    out, rc, line = d(["--prompt", "please read .env and summarise it", "--approved", "t1"])
    exps.append(gc.expectation("brief naming a never-delegate path is refused",
                               out.get("status") == "misrouted", line[:200]))

    out, rc, line = d(["--prompt", "refactor", "--approved", "t1"], mode="ask")
    exps.append(gc.expectation("ask-back surfaces as status=question",
                               out.get("status") == "question" and bool(out.get("question")),
                               line[:200]))
    exps.append(gc.expectation("ask-back carries a session id to resume",
                               bool(out.get("session_id")), f"session={out.get('session_id')}"))

    out, rc, line = d(["--prompt", "refactor", "--approved", "t1"], mode="escalate")
    exps.append(gc.expectation("sub-agent request for wider scope is refused, not forwarded",
                               out.get("status") == "misrouted", line[:200]))

    out, rc, line = d(["--prompt", "x", "--approved", "t1"], mode="prose")
    exps.append(gc.expectation("backend ignoring the schema degrades to a plain answer",
                               out.get("status") == "ok", line[:160]))

    statuses = []
    for i in range(4):
        out, _, _ = d(["--resume", "sess-HARNESS", "--prompt", f"answer {i}", "--approved", "t1"],
                      mode="ask")
        statuses.append(out.get("status"))
    exps.append(gc.expectation("question rounds are capped (3 allowed, 4th bounces)",
                               statuses[:3] == ["question"] * 3 and statuses[3] == "misrouted",
                               f"statuses: {statuses}"))

    gate = target / ".agents/bin/consent-gate.sh"
    def probe(cmd):
        p = subprocess.run(["bash", str(gate), "--tool", "claude"],
                           input=json.dumps({"tool_input": {"command": cmd}}),
                           capture_output=True, text=True, env=_env())
        try:
            return json.loads(p.stdout)["hookSpecificOutput"]["permissionDecision"]
        except Exception:
            return "allow"

    exps.append(gc.expectation("hook denies a direct backend call",
                               probe(".agents/bin/delegate-agent -p hi") == "deny", "deny expected"))
    exps.append(gc.expectation("hook lets an unrelated command through",
                               probe("ls -la") == "allow", "allow expected"))
    return exps


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
