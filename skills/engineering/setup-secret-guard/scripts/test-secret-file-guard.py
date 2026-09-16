#!/usr/bin/env python3
"""Regression tests for the PreToolUse guard's read-rewrite half.

Run: python3 test-secret-file-guard.py   (exit 0 = pass)

The guard is load-bearing and SILENT when it fails: a read it does not rewrite is
not denied, it is simply allowed, and the value reaches the transcript. So the
assertion here is deliberately coarse -- "this command cannot run as written" --
rather than checking for a specific decision. Any of rewrite / ask / deny is a
pass; a bare allow-with-no-change on a credential read is the bug.

Every fixture is synthetic. Nothing here touches a real credential file.
"""

import json
import os
import subprocess
import sys
import tempfile

GUARD = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "payload", "secret-file-guard.py"
)


def decide(cmd, cwd):
    p = subprocess.run(
        [sys.executable, GUARD],
        text=True,
        capture_output=True,
        input=json.dumps(
            {"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": cwd}
        ),
    )
    if p.returncode != 0:
        raise AssertionError(f"guard crashed: {p.stderr}")
    if not p.stdout.strip():
        return "allow", None
    out = json.loads(p.stdout)["hookSpecificOutput"]
    return out["permissionDecision"], out.get("updatedInput", {}).get("command")


def protected(cmd, cwd):
    """True when the credential read cannot reach the transcript as written."""
    decision, updated = decide(cmd, cwd)
    if decision in ("deny", "ask"):
        return True
    return bool(updated and "redact-view" in updated)


# Prefixes that put a REDACTABLE verb with a flag earlier in the same command.
# This is the shape that regressed: the flag-value sub-pattern was `\S+`, which is
# not bounded by shell separators, so `head -20 /etc/passwd` swallowed `; cat .env`
# and the credential read became that match's "path" -- never rewritten, never
# reported. See secret-guard-compound-cat-bypass-handoff.
PREFIXES = [
    ("head-flag-in-pipe", "ps aux | grep node | head -20"),
    ("head-n-in-pipe", "ps aux | grep node | head -n 20"),
    ("head-flag-and-file", "head -20 /etc/passwd"),
    ("tail-n-and-file", "tail -n 5 /etc/passwd"),
    ("head-c-and-file", "head -c 100 /etc/passwd"),
    ("nl-flag-and-file", "nl -ba /etc/passwd"),
    ("no-redactable-verb", "git log --oneline -5"),
    ("quoted-echo", 'echo "=== section ==="'),
]
SEPARATORS = [("and", " && "), ("semi", "; "), ("or", " || "), ("newline", "\n")]
READS = [
    ("cat-relative", "cat .env"),
    ("cat-absolute", "cat {d}/.env"),
    ("head-absolute", "head {d}/.env"),
    ("cat-quoted", 'cat ".env"'),
]


def main():
    failures = []
    checked = 0
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, ".env"), "w") as fh:
            fh.write(
                "NODE_ENV=development\n"
                "AUTH0_CLIENT_SECRET=FAKEfake0123456789abcdefFAKEfake\n"
            )

        # Baseline: a bare read must be protected, or nothing below means anything.
        for name, read in READS:
            cmd = read.format(d=d)
            checked += 1
            if not protected(f"cd {d} && {cmd}", d):
                failures.append(f"baseline/{name}: {cmd!r} ran raw")

        for pname, prefix in PREFIXES:
            for sname, sep in SEPARATORS:
                for rname, read in READS:
                    cmd = f"cd {d}{sep}{prefix}{sep}{read.format(d=d)}"
                    checked += 1
                    if not protected(cmd, d):
                        failures.append(
                            f"compound/{pname}/{sname}/{rname}: credential read "
                            f"reached the transcript unredacted"
                        )

        # A command that reads nothing secret must still pass through untouched,
        # or the guard is just noise people switch off.
        for cmd in (
            f"cd {d} && head -20 /etc/passwd",
            "ps aux | grep node | head -n 20",
            f"ls -la {d}",
        ):
            checked += 1
            decision, updated = decide(cmd, d)
            if decision in ("deny", "ask") or (updated and "redact-view" in updated):
                failures.append(f"false-positive: {cmd!r} was interfered with")

    print(f"{checked} cases checked, {len(failures)} failed")
    for f in failures:
        print(f"  FAIL  {f}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
