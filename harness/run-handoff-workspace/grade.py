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

eval_id ∈ {discipline-done | discipline-blocked | discipline-secrets | discipline-restricted}.
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

# Fixture boards carry no CLI copy of their own. <board>/handoff is a small dispatcher that execs
# the CLI named by $HANDOFF_BIN (then a user-level install, then a vendored copy), so pointing it
# at the skill's payload here is what puts the binary under test in front of every fixture — and
# makes a stale committed mirror impossible. Set once, for every subprocess this grader spawns,
# including the verify script.
os.environ.setdefault("HANDOFF_BIN", str(gc.payload_cli(HERE)))


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
        fm = _frontmatter(doc / "work-handoff.md")
        exps.append(gc.expectation("doc status is blocked", fm.get("status") == "blocked", f"status={fm.get('status')}"))
        exps.append(gc.expectation("doc records blocked_on", fm.get("blocked_on") == "up-handoff", f"blocked_on={fm.get('blocked_on')}"))
        exps.append(gc.expectation("lease released", not (doc / ".locks/work-handoff").exists(),
                                   "lock present: %s" % (doc / ".locks/work-handoff").exists()))
        exps.append(gc.expectation("doc stays on the open board (not archived)",
                                   (doc / "work-handoff.md").is_file() and not (doc / "archive/work-handoff.md").exists(),
                                   "open: %s" % (doc / "work-handoff.md").is_file()))
        return exps

    if eval_id == "discipline-secrets":
        # The write-path scanner (ADR 0005). Two properties, and the second is the one that is
        # easy to ship broken: the command must REFUSE, and the board must be untouched. A gate
        # that prints a refusal after already creating the doc has not refused.
        #
        # The test credential is assembled from parts. A literal one in this file would be caught
        # by the sweep the same feature adds to the verifier, and this grader would fail its own
        # repo's check.
        aws = "AKIA" + "IOSFODNN7EXAMPLE"
        r = _handoff(target, "new", "leak", "--title", "Leaky", "--note", f"key {aws} here")
        out = r.stdout + r.stderr
        exps.append(gc.expectation(
            "new refuses a credential pasted into a flag",
            r.returncode != 0 and "aws-access-key-id" in out,
            f"exit {r.returncode}: {out.strip()[-140:]}"))
        exps.append(gc.expectation(
            "the refusal never echoes the value back", aws not in out,
            "value absent from the refusal"))
        # "Nothing was written" has to be literally true, not nearly: the doc is rendered to a
        # temp file precisely so a refusal leaves no half-created doc and no index entry.
        exps.append(gc.expectation(
            "and nothing was written", not (doc / "leak-handoff.md").exists(),
            f"leak-handoff.md present: {(doc / 'leak-handoff.md').exists()}"))

        # release carries pasted terminal output more often than any other command, and terminal
        # output is where credentials appear.
        _handoff(target, "new", "rel", "--title", "Releasable")
        _handoff(target, "claim", "rel")
        rr = _handoff(target, "release", "rel", "--status", "done",
                      "--verified-by", f"ran the suite with {aws}")
        exps.append(gc.expectation(
            "release refuses a credential in the evidence",
            rr.returncode != 0 and "aws-access-key-id" in (rr.stdout + rr.stderr),
            f"exit {rr.returncode}: {(rr.stdout + rr.stderr).strip()[-140:]}"))
        exps.append(gc.expectation(
            "and the doc is untouched — still open, not archived",
            _frontmatter(doc / "rel-handoff.md").get("status") == "open"
            and not (doc / "archive/rel-handoff.md").exists(),
            f"status={_frontmatter(doc / 'rel-handoff.md').get('status')}"))

        # The override exists because the scanner will misfire on legitimate prose. It is a
        # RECORDED decision, not a silent hole — an override that left no trace would be the
        # same as no scanner.
        rf = _handoff(target, "new", "leak", "--title", "Leaky", "--note", f"key {aws} here",
                      "--force-secret", "the vendor's own published example key")
        exps.append(gc.expectation(
            "--force-secret gets past it", rf.returncode == 0 and (doc / "leak-handoff.md").is_file(),
            f"exit {rf.returncode}"))
        body = (doc / "leak-handoff.md").read_text(encoding="utf-8") if (doc / "leak-handoff.md").is_file() else ""
        exps.append(gc.expectation(
            "and the override is recorded on the doc, naming the rule AND the reason",
            "secret-scan OVERRIDDEN" in body and "aws-access-key-id" in body
            and "vendor's own published example key" in body,
            "activity log records the override" if "secret-scan OVERRIDDEN" in body else "no override entry"))
        return exps

    if eval_id == "discipline-restricted":
        # The discipline half of `sensitivity: restricted`: an agent working the board must be
        # TOLD, at the two moments it decides what to do next. Export refusal is graded in
        # delegate-handoff's export-restricted case; this asserts the signals that reach a
        # session before it ever gets that far.
        _handoff(target, "new", "rotate", "--title", "Rotate the signing keys",
                 "--sensitivity", "restricted")
        rc = _handoff(target, "claim", "rotate")
        out = rc.stdout + rc.stderr
        exps.append(gc.expectation(
            "claim succeeds — restricted is a handling flag, not a lock",
            rc.returncode == 0 and (doc / ".locks/rotate-handoff").exists(),
            f"exit {rc.returncode}; lease held: {(doc / '.locks/rotate-handoff').exists()}"))
        exps.append(gc.expectation(
            "claim prints the handling banner", "RESTRICTED" in out,
            f"banner in output: {'RESTRICTED' in out}"))
        exps.append(gc.expectation(
            "the banner says plainly that it is NOT an access control",
            "not an access control" in out,
            "the one sentence that stops the flag being read as a permission"))
        # The session-start banner is where an agent decides what to pick up and what to hand to
        # a cheaper agent. A restricted unit reading as ordinary work there has already lost.
        hooks = doc / "scripts/hooks.sh"
        env = dict(os.environ, HANDOFF_SESSION_ID="sess-RH")
        hr = subprocess.run(["bash", str(hooks), "--kind", "sessionstart", "--tool", "claude"],
                            input='{"session_id":"sess-RH"}', cwd=str(target),
                            capture_output=True, text=True, env=env)
        exps.append(gc.expectation(
            "the session-start board marks the restricted row",
            "RESTRICTED" in hr.stdout,
            f"marker in banner: {'RESTRICTED' in hr.stdout}"))
        exps.append(gc.expectation(
            "while still naming it — the index is not redacted",
            "Rotate the signing keys" in hr.stdout,
            "title present in the session banner"))
        return exps

    # discipline-done (default)
    _handoff(target, "new", "task", "--title", "Ship the task", "--severity", "high")
    created = _frontmatter(doc / "task-handoff.md")
    exps.append(gc.expectation("filed doc has schema-valid frontmatter (id/title/status)",
                               created.get("id") == "task-handoff" and created.get("title") == "Ship the task"
                               and created.get("status") == "open",
                               f"frontmatter: {created}"))
    _handoff(target, "claim", "task")
    r = _handoff(target, "release", "task", "--status", "done", "--verified-by", "e2e green: task.e2e.ts")
    exps.append(gc.expectation("release --status done succeeds with evidence", r.returncode == 0,
                               f"exit {r.returncode}: {r.stderr.strip()[:100]}"))
    archived = doc / "archive/task-handoff.md"
    exps.append(gc.expectation("doc archived on done", archived.is_file(), f"archived: {archived.is_file()}"))
    if archived.is_file():
        fm = _frontmatter(archived)
        exps.append(gc.expectation("archived doc stamped verified_at", bool(fm.get("verified_at")),
                                   f"verified_at={fm.get('verified_at')}"))
    exps.append(gc.expectation("lease released after done", not (doc / ".locks/task-handoff").exists(),
                               "lock present: %s" % (doc / ".locks/task-handoff").exists()))
    exps.append(gc.contains(target, f"{HD}/INDEX.md", "archive/task-handoff.md",
                            label="INDEX.md regenerated and lists the archived doc"))
    return exps


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
