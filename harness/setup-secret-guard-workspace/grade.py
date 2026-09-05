#!/usr/bin/env python3
"""Grader for the x442-setup-secret-guard skill.

Wraps the skill's read-only verify-secret-guard.sh (via --json for the stable finding ids) for
environment sanity, and adds what a stateless verifier structurally cannot check: that a
pre-existing file survives an install, that a re-run leaves the tree clean, that a precondition
refusal fabricates nothing, that a divergent payload file is refused and then adopted correctly
-- and, the load-bearing reason this workspace exists, that a planted synthetic credential never
appears in secret-scan's or redact-view's OUTPUT. The verifier only asserts the guard DECIDED
correctly (see its own module docstring); it deliberately never plants a real-shaped value of its
own to check against. This harness does, on fixtures under fixtures/leaks/, so the "never leaks"
property has independent coverage beyond the verifier's built-in self-test.

CRITICAL ENVIRONMENT RULE: the installer's home layer resolves against $SECRET_GUARD_HOME,
falling back to $HOME/.claude. Every subprocess this grader launches sets SECRET_GUARD_HOME
explicitly to a throwaway temp directory -- see _isolated_home() -- so nothing here can ever
read from or write to the operator's real ~/.claude.

Usage: grade.py <fixture-or-produced-dir> <eval-id> [--out grading.json]
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
SKILL = REPO / "skills/engineering/setup-secret-guard"
SETUP = SKILL / "scripts/setup-secret-guard.sh"
VERIFY = SKILL / "scripts/verify-secret-guard.sh"
PAYLOAD = SKILL / "scripts/payload"

# The stable finding ids a fully-wired home layer must report `pass` on. Asserted by id, never by
# message -- ids are the stable contract per verify-secret-guard.sh's own docstring; prose is
# reworded freely and must never be what a grader keys on.
HOME_WIRED_PASS_IDS = (
    "engine.secret_redact.py",
    "engine.secret-file-guard.py",
    "engine.redact-view",
    "engine.secret-scan",
    "payload.version",
    "payload.content",
    "payload.depersonalised",
    "engine.detects",
    "engine.no_false_positive",
    "engine.masks",
    "engine.passthrough",
    "engine.findings_quiet",
    "guard.rewrites_read",
    "guard.rewrite_runs",
    "guard.denies_extraction",
    "guard.passthrough",
    "guard.consumer_allowed",
    # The over-firing half. A guard that refuses honest commands gets switched off, so a
    # clean COMMAND matters here as much as the clean FILE the leak cases already cover.
    "guard.filter_denied",
    "guard.no_false_deny_downstream",
    "guard.no_rewrite_of_quoted_data",
    "wiring.json_valid",
    "wiring.hook",
    "wiring.deny",
    "selftest.splice-agents-block",
    "selftest.merge-settings",
)


# --------------------------------------------------------------------- home-layer isolation


def _isolated_home(seed):
    """Return (home_dir, cleanup) -- a throwaway directory used as SECRET_GUARD_HOME.

    `seed` is either a fixture/produced directory to copy in (the pre-existing home-layer
    state a case starts from) or None for a truly empty home. NEVER the real $HOME/.claude,
    and never touched in place: every eval gets its own temp copy so grading one case cannot
    leak state into another or onto the machine running the grader.
    """
    tmp = tempfile.mkdtemp(prefix="x442-secret-guard-home-")
    dest = Path(tmp) / "home"
    if seed is not None and Path(seed).is_dir():
        shutil.copytree(seed, dest)
    else:
        dest.mkdir(parents=True)
    return dest, (lambda: shutil.rmtree(tmp, ignore_errors=True))


def _env(home_dir, extra=None):
    env = dict(os.environ)
    env["SECRET_GUARD_HOME"] = str(home_dir)
    env.update(extra or {})
    return env


def _run(args, home_dir, extra_env=None):
    return subprocess.run(
        args,
        cwd=str(SKILL),
        capture_output=True,
        text=True,
        env=_env(home_dir, extra_env),
    )


def _install_home(home_dir, *extra):
    return _run(["bash", str(SETUP), "--home", *extra], home_dir)


def _install_repo(repo_dir, home_dir):
    # SECRET_GUARD_HOME is set even here though install_repo never reads it -- the repo layer
    # never resolves the engine -- purely so no invocation in this file is the one that forgot.
    return _run(["bash", str(SETUP), str(repo_dir)], home_dir)


# ------------------------------------------------------------------------------- dispatch


def grade(target, eval_id):
    if eval_id == "home-fresh":
        return _grade_home_fresh(target)
    if eval_id == "home-diverged-adopt":
        return _grade_home_diverged(target)
    if eval_id == "repo-fresh":
        return _grade_repo_fresh(target)
    if eval_id == "repo-precondition-no-agents-md":
        return _grade_repo_precondition(target)
    if eval_id == "leak-dotenv":
        return _grade_leak_dotenv(target)
    if eval_id == "leak-connection-string":
        return _grade_leak_connection_string(target)
    if eval_id == "leak-false-positive":
        return _grade_leak_false_positive(target)
    return [
        gc.expectation(
            f"eval id '{eval_id}' is recognized", False, "no grader for this id"
        )
    ]


# ---------------------------------------------------------------------------- home: fresh


def _grade_home_fresh(target):
    home, cleanup = _isolated_home(target)
    try:
        proc = _install_home(home)
        exps = [
            gc.expectation(
                "installer exits 0 on a fresh home",
                proc.returncode == 0,
                (proc.stderr or proc.stdout or "").strip()[-300:] or "no output",
            )
        ]
        for rel in (
            "scripts/secret_redact.py",
            "scripts/secret-file-guard.py",
            "bin/redact-view",
            "bin/secret-scan",
            "scripts/.secret-guard.version",
            "settings.json",
        ):
            exps.append(gc.file_exists(home, rel))
        for rel in (
            "scripts/secret-file-guard.py",
            "bin/redact-view",
            "bin/secret-scan",
        ):
            executable = os.access(home / rel, os.X_OK)
            exps.append(
                gc.expectation(
                    f"{rel} is executable", executable, "yes" if executable else "no"
                )
            )

        findings = gc.verify_findings(VERIFY, home, env=_env(home))
        for fid in HOME_WIRED_PASS_IDS:
            exps.append(gc.finding(findings, fid, "pass"))
        exps.append(gc.no_findings_at(findings, "fail"))
        exps.append(gc.run_verify_script(VERIFY, home, env=_env(home)))

        # Idempotency: re-run leaves the home tree clean.
        gc.git_init_commit(home, "post-install baseline")
        proc2 = _install_home(home)
        exps.append(
            gc.expectation(
                "re-run exits 0", proc2.returncode == 0, proc2.stdout.strip()[-200:]
            )
        )
        exps.append(gc.git_diff_empty(home))
        return exps
    finally:
        cleanup()


# ----------------------------------------------------------------- home: diverged + adopt


def _grade_home_diverged(target):
    home, cleanup = _isolated_home(target)
    try:
        marker = "LOCAL FIX: hand-edited, must not be silently overwritten"
        pre = (home / "scripts/secret_redact.py").read_text()
        exps = [
            gc.expectation(
                "fixture actually seeds a diverged secret_redact.py",
                marker in pre,
                "marker present" if marker in pre else "marker missing from fixture",
            )
        ]

        proc = _install_home(home)
        combined = (proc.stdout or "") + (proc.stderr or "")
        exps.append(
            gc.expectation(
                "installer refuses on divergence without --adopt (exit 3)",
                proc.returncode == 3,
                f"exit {proc.returncode}: {combined.strip()[-200:]}",
            )
        )
        exps.append(
            gc.expectation(
                "refusal names --adopt as the way forward",
                "--adopt" in combined,
                "mentioned" if "--adopt" in combined else "not mentioned",
            )
        )
        post = (home / "scripts/secret_redact.py").read_text()
        exps.append(
            gc.expectation(
                "the diverged file is left untouched on refusal",
                post == pre,
                "unchanged" if post == pre else "OVERWRITTEN despite refusal",
            )
        )
        exps.append(
            gc.expectation(
                "no backup is made before anything was actually overwritten",
                not (home / ".secret-guard-backup").exists(),
                (
                    "absent (correct)"
                    if not (home / ".secret-guard-backup").exists()
                    else "present too early"
                ),
            )
        )
        for rel in (
            "scripts/secret-file-guard.py",
            "bin/redact-view",
            "bin/secret-scan",
        ):
            present = (home / rel).is_file()
            exps.append(
                gc.expectation(
                    f"non-diverging {rel} is still installed despite the refusal",
                    present,
                    "installed" if present else "missing",
                )
            )

        proc2 = _install_home(home, "--adopt")
        exps.append(
            gc.expectation(
                "--adopt proceeds (exit 0)",
                proc2.returncode == 0,
                (proc2.stdout or proc2.stderr).strip()[-200:],
            )
        )
        adopted = (home / "scripts/secret_redact.py").read_bytes()
        shipped = (PAYLOAD / "secret_redact.py").read_bytes()
        exps.append(
            gc.expectation(
                "adopted file now matches the shipped payload byte for byte",
                adopted == shipped,
                f"{len(adopted)} vs {len(shipped)} bytes"
                + (" (match)" if adopted == shipped else " (DIFFER)"),
            )
        )
        backups = (
            list((home / ".secret-guard-backup").rglob("secret_redact.py"))
            if (home / ".secret-guard-backup").is_dir()
            else []
        )
        exps.append(
            gc.expectation(
                "the previous copy was backed up before being replaced",
                bool(backups),
                f"{len(backups)} backup copy(ies) found",
            )
        )
        if backups:
            exps.append(
                gc.expectation(
                    "the backed-up copy is the pre-adopt hand-edited version, not the payload",
                    backups[0].read_text() == pre,
                    (
                        "matches the hand-edited fixture"
                        if backups[0].read_text() == pre
                        else "does not match"
                    ),
                )
            )
        exps.append(
            gc.contains(
                home,
                "settings.json",
                "unrelated-hook.sh",
                label="pre-existing unrelated PreToolUse hook survives adoption",
            )
        )
        exps.append(
            gc.contains(
                home,
                "settings.json",
                "someServer",
                label="pre-existing unrelated settings.json key survives",
            )
        )
        exps.append(
            gc.contains(
                home,
                "settings.json",
                "Read(**/private.txt)",
                label="pre-existing unrelated deny rule survives",
            )
        )
        exps.append(gc.json_roundtrip(home, "settings.json"))

        findings = gc.verify_findings(VERIFY, home, env=_env(home))
        exps.append(gc.finding(findings, "payload.content", "pass"))
        exps.append(gc.no_findings_at(findings, "fail"))
        return exps
    finally:
        cleanup()


# --------------------------------------------------------------------------- repo: fresh


def _grade_repo_fresh(target):
    graded, cleanup_git = gc.isolated_git_target(target)
    home, cleanup_home = _isolated_home(None)
    try:
        proc = _install_repo(graded, home)
        exps = [
            gc.expectation(
                "installer exits 0",
                proc.returncode == 0,
                (proc.stderr or proc.stdout or "").strip()[-200:],
            )
        ]
        exps.append(gc.file_exists(graded, "AGENTS.md"))
        text = (graded / "AGENTS.md").read_text()
        n_begin = text.count("<!-- secret-guard:begin")
        n_end = text.count("<!-- secret-guard:end -->")
        exps.append(
            gc.expectation(
                "AGENTS.md has exactly one managed secret-guard block",
                n_begin == 1 and n_end == 1,
                f"begin={n_begin} end={n_end}",
            )
        )
        exps.append(
            gc.contains(
                graded,
                "AGENTS.md",
                "This paragraph must survive the secret-guard install untouched.",
                label="pre-existing AGENTS.md prose survives",
            )
        )
        exps.append(gc.file_exists(graded, ".agents/secret-guard.json"))
        exps.append(gc.json_roundtrip(graded, ".agents/secret-guard.json"))
        exps.append(gc.contains(graded, ".agents/secret-guard.json", "safe_keys"))
        exps.append(gc.contains(graded, ".agents/secret-guard.json", "paths"))

        gc.git_init_commit(graded, "post-install baseline")
        _install_repo(graded, home)
        exps.append(gc.git_diff_empty(graded))
        return exps
    finally:
        cleanup_home()
        cleanup_git()


# ------------------------------------------------------------------- repo: precondition


def _grade_repo_precondition(target):
    graded, cleanup_git = gc.isolated_git_target(target)
    home, cleanup_home = _isolated_home(None)
    try:
        proc = _install_repo(graded, home)
        combined = (proc.stderr or "") + (proc.stdout or "")
        return [
            gc.expectation(
                "installer refuses without AGENTS.md",
                proc.returncode != 0,
                f"exit {proc.returncode}: {combined.strip()[:200]}",
            ),
            gc.expectation(
                "refusal names the fix (initial-project)",
                "initial-project" in combined,
                combined.strip()[:200] or "no output",
            ),
            gc.no_fabrication(graded, "AGENTS.md"),
            gc.no_fabrication(graded, ".agents/secret-guard.json"),
        ]
    finally:
        cleanup_home()
        cleanup_git()


# ------------------------------------------------------------------------- leak cases
#
# These are the reason this workspace exists. verify-secret-guard.sh proves the guard DECIDES
# correctly using its own synthetic fixture; it deliberately never asserts on a leak because it
# runs read-only in a live environment. This harness plants a distinct, obviously-synthetic
# credential in a realistic file and checks the actual bytes of secret-scan's and redact-view's
# stdout/stderr for it -- the assertion the verifier structurally cannot make.


def _grade_leak_dotenv(target):
    home, cleanup = _isolated_home(None)
    try:
        f = Path(target) / "app.env"
        secret = "not-a-real-secret-alpha-001"
        raw = f.read_text()
        exps = [
            gc.expectation(
                "fixture actually plants the secret value",
                secret in raw,
                "planted" if secret in raw else "MISSING FROM FIXTURE",
            )
        ]
        scan = _run(["python3", str(PAYLOAD / "secret-scan"), str(f)], home)
        exps.append(
            gc.expectation(
                "secret-scan detects the credential (exit 0)",
                scan.returncode == 0,
                f"exit {scan.returncode}",
            )
        )
        scan_out = scan.stdout + scan.stderr
        exps.append(
            gc.expectation(
                "secret-scan's own output never echoes the planted value",
                secret not in scan_out,
                (
                    "absent (correct)"
                    if secret not in scan_out
                    else "LEAKED into secret-scan output"
                ),
            )
        )
        exps.append(
            gc.expectation(
                "the finding names a rule, tab-separated from the file path",
                "\t" in scan.stdout
                and scan.stdout.split("\t", 1)[0] == "credential-shaped-value",
                scan.stdout.strip()[:160] or "(no finding line)",
            )
        )
        view = _run(["python3", str(PAYLOAD / "redact-view"), str(f)], home)
        view_out = view.stdout + view.stderr
        exps.append(
            gc.expectation(
                "redact-view's output never contains the planted value",
                secret not in view_out,
                (
                    "absent (correct)"
                    if secret not in view_out
                    else "LEAKED into redact-view output"
                ),
            )
        )
        exps.append(
            gc.expectation(
                "redact-view carries a stable sha256 fingerprint in place of the value",
                "sha256:" in view.stdout,
                view.stdout.strip()[:160],
            )
        )
        exps.append(
            gc.expectation(
                "the surrounding keys and structure survive the mask",
                "SERVICE=billing" in view.stdout and "API_TIMEOUT=30" in view.stdout,
                view.stdout.strip()[:200],
            )
        )
        return exps
    finally:
        cleanup()


def _grade_leak_connection_string(target):
    home, cleanup = _isolated_home(None)
    try:
        f = Path(target) / "appsettings.json"
        secret = "not-a-real-secret-beta-002"
        raw = f.read_text()
        exps = [
            gc.expectation(
                "fixture actually plants the secret value",
                secret in raw,
                "planted" if secret in raw else "MISSING FROM FIXTURE",
            )
        ]
        scan = _run(["python3", str(PAYLOAD / "secret-scan"), str(f)], home)
        exps.append(
            gc.expectation(
                "secret-scan detects a credential embedded in a connection-string value, "
                "even though no key name in the document looks secret ('AppName', "
                "'Default', 'Logging', 'LogLevel')",
                scan.returncode == 0,
                f"exit {scan.returncode}: {scan.stdout.strip()[:160]}",
            )
        )
        scan_out = scan.stdout + scan.stderr
        exps.append(
            gc.expectation(
                "secret-scan's own output never echoes the planted value",
                secret not in scan_out,
                (
                    "absent (correct)"
                    if secret not in scan_out
                    else "LEAKED into secret-scan output"
                ),
            )
        )
        view = _run(["python3", str(PAYLOAD / "redact-view"), str(f)], home)
        view_out = view.stdout + view.stderr
        exps.append(
            gc.expectation(
                "redact-view masks the embedded credential",
                secret not in view_out,
                (
                    "absent (correct)"
                    if secret not in view_out
                    else "LEAKED into redact-view output"
                ),
            )
        )
        exps.append(
            gc.expectation(
                "redact-view carries a stable sha256 fingerprint in place of the value",
                "sha256:" in view.stdout,
                view.stdout.strip()[:200],
            )
        )
        body = (
            view.stdout.split("\n", 1)[1]
            if view.stdout.startswith("#")
            else view.stdout
        )
        try:
            json.loads(body)
            valid_json = True
        except (ValueError, IndexError):
            valid_json = False
        exps.append(
            gc.expectation(
                "the masked output is still valid JSON (structure preserved, not just blanked)",
                valid_json,
                "parses" if valid_json else "does not parse",
            )
        )
        exps.append(
            gc.expectation(
                "an unrelated value elsewhere in the document is left untouched",
                "acme-billing-service" in view.stdout,
                view.stdout.strip()[:200],
            )
        )
        return exps
    finally:
        cleanup()


def _grade_leak_false_positive(target):
    home, cleanup = _isolated_home(None)
    try:
        f = Path(target) / "config.json"
        raw_bytes = f.read_bytes()
        scan = _run(["python3", str(PAYLOAD / "secret-scan"), str(f)], home)
        exps = [
            gc.expectation(
                "an ordinary config is reported clean (exit 1)",
                scan.returncode == 1,
                f"exit {scan.returncode}: {scan.stdout.strip()[:160]}",
            )
        ]
        exps.append(
            gc.expectation(
                "no finding is printed for a clean file",
                scan.stdout.strip() == "",
                (
                    repr(scan.stdout.strip()[:160])
                    if scan.stdout.strip()
                    else "(none, correct)"
                ),
            )
        )
        view = _run(["python3", str(PAYLOAD / "redact-view"), str(f)], home)
        view_bytes = view.stdout.encode("utf-8")
        exps.append(
            gc.expectation(
                "redact-view passes the clean file through byte-identical",
                view_bytes == raw_bytes,
                (
                    "byte-identical"
                    if view_bytes == raw_bytes
                    else "REWRITTEN despite nothing to mask"
                ),
            )
        )
        return exps
    finally:
        cleanup()


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
