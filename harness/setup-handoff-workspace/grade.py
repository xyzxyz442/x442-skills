#!/usr/bin/env python3
"""Grader for the x442-setup-handoff skill.

Wraps the skill's bundled verify-setup-handoff.sh and adds the assertions a read-only
verifier cannot make: precondition refusal, from-scratch wiring, idempotency (re-run →
empty diff), legacy migration, and a full script-behavior suite that DRIVES the installed
`handoff` + `hooks.sh` to prove every protocol improvement. Read-only and LLM-free — it runs
bash scripts, never an LLM or the network. All mutation happens inside an isolated temp copy.

Usage:
    python3 grade.py <produced-project-dir> [eval_id] [--out grading.json]

eval_id ∈ {no-agents-md | fresh | claude-wired | advisory-wired | legacy-install |
script-behavior}. Exits 0 iff nothing failed.
"""

import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "lib"))
import grade_common as gc  # noqa: E402

REPO = gc.repo_root(HERE)
SKILL = REPO / "skills/engineering/setup-handoff"
SETUP = SKILL / "scripts/setup-handoff.sh"
VERIFY = SKILL / "scripts/verify-setup-handoff.sh"
DETECT = SKILL / "scripts/detect-handoff.sh"

HD = ".agents/handoff"
CLAUDE_CFG = ".claude/settings.json"


def _run(args, cwd, env_extra=None):
    import os
    env = {**os.environ, **(env_extra or {})}
    return subprocess.run(args, cwd=str(cwd), capture_output=True, text=True, env=env)


def _install(target, *extra):
    return _run(["bash", str(SETUP), str(target), "--tools", "claude", *extra], target)


def _handoff(target, *args, session="sess-AAA", allow_verify=False):
    ho = Path(target) / HD / "handoff"
    env = {"HANDOFF_SESSION_ID": session}
    if allow_verify:
        env["HANDOFF_ALLOW_VERIFY_CMD"] = "1"
    return _run(["bash", str(ho), *args], target, env)


def _hook(target, kind, payload, session="sess-AAA"):
    hk = Path(target) / HD / "hooks.sh"
    p = subprocess.run(
        ["bash", str(hk), "--kind", kind, "--tool", "claude"],
        cwd=str(target), input=json.dumps({"session_id": session, **payload}),
        capture_output=True, text=True,
    )
    return p.stdout.strip()


def _lease(target, hid):
    f = Path(target) / HD / ".locks" / hid / "owner"
    return f.read_text() if f.is_file() else ""


def _force_expiry(target, hid, epoch="100"):
    f = Path(target) / HD / ".locks" / hid / "owner"
    lines = [ln for ln in f.read_text().splitlines() if not ln.startswith("expires=")]
    lines.append(f"expires={epoch}")
    f.write_text("\n".join(lines) + "\n")


def grade_script_behavior(target):
    e = []
    doc = Path(target) / HD

    _handoff(target, "new", "bt", "--title", "Backend task")
    e.append(gc.expectation("handoff new creates a doc", (doc / "bt.md").is_file(),
                            f"bt.md exists: {(doc / 'bt.md').is_file()}"))

    _handoff(target, "claim", "bt", "on it", session="sess-AAA")
    lease = _lease(target, "bt")
    e.append(gc.expectation("claim writes session= into the lease (defect #1 fixed)",
                            "session=sess-AAA" in lease, f"lease: {lease!r}"))

    deny = _hook(target, "pretool-edit", {"tool_input": {"file_path": str(doc / "bt.md")}}, session="sess-BBB")
    e.append(gc.expectation("pretool gate DENIES a non-holder editing the doc",
                            '"permissionDecision": "deny"' in deny, f"out: {deny[:120]!r}"))
    allow = _hook(target, "pretool-edit", {"tool_input": {"file_path": str(doc / "bt.md")}}, session="sess-AAA")
    e.append(gc.expectation("pretool gate ALLOWS the holder (empty output)",
                            allow == "", f"out: {allow[:120]!r}"))

    r = _handoff(target, "release", "bt", "--status", "done")
    e.append(gc.expectation("done is REFUSED without --verified-by",
                            r.returncode != 0, f"exit {r.returncode}: {r.stderr.strip()[:100]}"))
    r = _handoff(target, "release", "bt", "--status", "done", "--verified-by", "manual: bt.js:1")
    e.append(gc.expectation("done with --verified-by archives the doc",
                            r.returncode == 0 and (doc / "archive/bt.md").is_file(),
                            f"exit {r.returncode}; archived: {(doc / 'archive/bt.md').is_file()}"))

    _handoff(target, "new", "blk", "--title", "Blocker")
    _handoff(target, "new", "dep", "--title", "Dependent")
    _handoff(target, "claim", "dep")
    r = _handoff(target, "release", "dep", "--status", "blocked")
    e.append(gc.expectation("blocked is REFUSED without --blocked-on",
                            r.returncode != 0, f"exit {r.returncode}"))
    _handoff(target, "claim", "dep")
    _handoff(target, "release", "dep", "--status", "blocked", "--blocked-on", "blk")
    dep_txt = (doc / "dep.md").read_text()
    e.append(gc.expectation("blocked_on is recorded in the doc",
                            "blocked_on: blk" in dep_txt, "blocked_on present: %s" % ("blocked_on: blk" in dep_txt)))
    _handoff(target, "claim", "blk")
    r = _handoff(target, "release", "blk", "--status", "done", "--verified-by", "done")
    e.append(gc.expectation("closing the blocker surfaces the dependent as unblocked",
                            "dep" in r.stdout and "unblocked" in r.stdout.lower(),
                            f"stdout: {r.stdout.strip()[:160]!r}"))
    ss = _hook(target, "sessionstart", {})
    e.append(gc.expectation("sessionstart flags the dependent UNBLOCKED",
                            "UNBLOCKED" in ss, f"ctx has UNBLOCKED: {'UNBLOCKED' in ss}"))

    # auto-reap: an expired lease is cleared at sessionstart
    _handoff(target, "new", "aband", "--title", "Abandoned")
    _handoff(target, "claim", "aband")
    _force_expiry(target, "aband")
    _hook(target, "sessionstart", {})
    e.append(gc.expectation("sessionstart auto-reaps an expired lease",
                            not (doc / ".locks/aband").exists(),
                            "lock present: %s" % (doc / ".locks/aband").exists()))

    # auto-touch: the holder's lease TTL is renewed on posttool-edit
    _handoff(target, "new", "live", "--title", "Live work")
    _handoff(target, "claim", "live", session="sess-AAA")
    _force_expiry(target, "live")
    _hook(target, "posttool-edit", {"tool_response": {"filePath": str(Path(target) / "src/app.js")}}, session="sess-AAA")
    exp = ""
    for ln in _lease(target, "live").splitlines():
        if ln.startswith("expires="):
            exp = ln.split("=", 1)[1]
    e.append(gc.expectation("posttool auto-touches the holder's lease (TTL renewed)",
                            exp.isdigit() and int(exp) > 100000, f"expires={exp}"))

    # verify: safe-by-default — a doc's verify: command is NOT executed without opt-in
    _handoff(target, "new", "vt", "--title", "Verify task")
    # inject a verify: command that leaves a marker FILE only if actually executed
    # (printing the command text must NOT count as running it)
    vt = doc / "vt.md"
    marker = Path(target) / "VERIFY_RAN"
    txt = vt.read_text().replace("status: open", f"status: open\nverify: touch {marker}", 1)
    vt.write_text(txt)
    _handoff(target, "claim", "vt")
    r = _handoff(target, "release", "vt", "--status", "done", "--verified-by", "z", "--run-verify")
    e.append(gc.expectation("verify: command is NOT auto-run without the install opt-in",
                            not marker.exists(),
                            f"marker present: {marker.exists()}; stdout: {r.stdout.strip()[:100]!r}"))

    # --- handoff types: standalone/isolated is gate-exempt --------------------------------
    _handoff(target, "new", "refdoc", "--standalone", "--title", "Reference")
    refdoc = doc / "refdoc.md"
    e.append(gc.expectation("new --standalone writes type: standalone",
                            refdoc.is_file() and "type: standalone" in refdoc.read_text(),
                            f"exists: {refdoc.is_file()}"))
    # the crux: a NON-holder may edit a standalone doc — the pretool gate allows it (empty out)
    allow = _hook(target, "pretool-edit", {"tool_input": {"file_path": str(refdoc)}}, session="sess-ZZZ")
    e.append(gc.expectation("pretool gate ALLOWS editing a standalone doc with no lease",
                            allow == "", f"out: {allow[:120]!r}"))
    # claim refuses a standalone (it is not claimable work)
    rc = _handoff(target, "claim", "refdoc", session="sess-ZZZ")
    e.append(gc.expectation("claim REFUSES a standalone handoff",
                            rc.returncode != 0, f"exit {rc.returncode}: {rc.stderr.strip()[:80]}"))
    # standalone retire: done archives WITHOUT --verified-by
    rr = _handoff(target, "release", "refdoc", "--status", "done")
    e.append(gc.expectation("standalone release --status done archives without --verified-by",
                            rr.returncode == 0 and (doc / "archive/refdoc.md").is_file(),
                            f"exit {rr.returncode}; archived: {(doc / 'archive/refdoc.md').is_file()}"))
    # import brings an existing file onto the board as standalone
    src = Path(target) / "IMPORT_ME.md"
    src.write_text("# Imported\n\nbody\n")
    _handoff(target, "import", str(src), "--id", "imported", "--standalone")
    imp = doc / "imported.md"
    e.append(gc.expectation("import lands a file typed as standalone",
                            imp.is_file() and "type: standalone" in imp.read_text(),
                            f"exists: {imp.is_file()}"))
    return e


def grade(target, eval_id):
    gc.pre_state_hint(HERE, eval_id)
    graded, cleanup = gc.isolated_git_target(target)
    if graded != Path(target).resolve():
        print(f"[grade] isolated fixture to its own git root: {graded}", file=sys.stderr)
    try:
        return _grade(graded, eval_id)
    finally:
        cleanup()


def _grade(target, eval_id):
    if eval_id == "no-agents-md":
        r = _install(target, "--primary", "claude")
        return [
            gc.expectation("installer REFUSES without AGENTS.md", r.returncode != 0,
                           f"exit {r.returncode}: {r.stderr.strip()[:120]}"),
            gc.no_fabrication(target, "AGENTS.md"),
            gc.no_fabrication(target, HD),
        ]

    if eval_id == "fresh":
        r = _install(target, "--primary", "claude")
        exps = [gc.expectation("installer succeeds on a fresh repo", r.returncode == 0,
                               f"exit {r.returncode}: {r.stderr.strip()[:120]}")]
        exps.append(gc.run_verify_script(VERIFY, target))
        exps.append(gc.contains(target, "AGENTS.md", "handoff:begin"))
        exps.append(gc.file_exists(target, f"{HD}/handoff"))
        exps.append(gc.file_exists(target, f"{HD}/hooks.sh"))
        return exps

    if eval_id == "claude-wired":
        exps = [gc.run_verify_script(VERIFY, target)]
        exps.append(gc.contains(target, CLAUDE_CFG, "pretool-edit",
                                label="claude config has the hard-enforcement pretool deny gate"))
        # idempotency: a clean re-run must leave nothing dirty
        _install(target, "--primary", "claude")
        exps.append(gc.git_diff_empty(target))
        return exps

    if eval_id == "advisory-wired":
        exps = [gc.run_verify_script(VERIFY, target)]
        exps.append(gc.not_contains(target, CLAUDE_CFG, "pretool-edit",
                                    label="advisory config has NO pretool deny gate"))
        return exps

    if eval_id == "legacy-install":
        r = _install(target, "--primary", "claude", "--migrate", ".claude/handoff")
        exps = [gc.expectation("migration installer succeeds", r.returncode == 0,
                               f"exit {r.returncode}: {r.stderr.strip()[:120]}")]
        exps.append(gc.file_exists(target, f"{HD}/legacy-open.md"))
        exps.append(gc.file_exists(target, f"{HD}/archive/legacy-done.md"))
        exps.append(gc.no_fabrication(target, ".claude/handoff"))  # legacy dir moved away
        exps.append(gc.contains(target, f"{HD}/handoff", "session=",
                                label="migrated handoff script writes session= (defect #1 fixed)"))
        exps.append(gc.run_verify_script(VERIFY, target))
        return exps

    if eval_id == "detect":
        out = subprocess.run(["bash", str(DETECT), str(target)],
                             capture_output=True, text=True).stdout
        return [
            gc.expectation("detects the legacy install location", "FOUND .claude/handoff" in out, out[:200]),
            gc.expectation("classifies it as a legacy tool-path install", "kind=legacy-toolpath" in out, out[:200]),
            gc.expectation("flags the defective (pre-session=) version", "version=legacy" in out, out[:200]),
            gc.expectation("counts its docs", "docs=2" in out, out[:200]),
            gc.expectation("suggests migrating to current/parent/specific",
                           "UPGRADE + MIGRATE" in out and "parent-level" in out and "specific location" in out, out[:300]),
            gc.expectation("reports one install detected", "Detected: 1 install" in out, out[-120:]),
        ]

    if eval_id == "custom-location":
        r = _install(target, "--primary", "claude", "--handoff-dir", ".claude/handoff")
        exps = [gc.expectation("installer succeeds with a custom --handoff-dir", r.returncode == 0,
                               f"exit {r.returncode}: {r.stderr.strip()[:120]}")]
        exps.append(gc.file_exists(target, ".claude/handoff/handoff"))
        exps.append(gc.no_fabrication(target, ".agents/handoff"))  # used the custom location, not the default
        exps.append(gc.contains(target, ".gitignore", ".claude/handoff/.locks/",
                                label="gitignore excludes the custom board's .locks/"))
        exps.append(gc.run_verify_script(VERIFY, target))
        return exps

    if eval_id == "script-behavior":
        return grade_script_behavior(target)

    return [gc.run_verify_script(VERIFY, target)]


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
