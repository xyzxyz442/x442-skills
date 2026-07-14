#!/usr/bin/env python3
"""Shared, skill-agnostic grading helpers for the x442-skills eval harness.

Every assertion returns a {"text", "passed", "evidence"} dict — the evidence string
explains the verdict so a reviewer never has to re-derive it. A skill's grade.py composes
these into a grading.json. See ../../docs/harness-structure.md.

Read-only and LLM-free: these helpers inspect files and run the skill's bundled
verify-*.sh (itself read-only). They never call an LLM or hit the network, so they are safe
to run in CI or by hand.

Self-test:  python3 grade_common.py --selftest
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

Expectation = dict  # {"text": str, "passed": bool, "evidence": str}


def expectation(text: str, passed: bool, evidence: str) -> Expectation:
    """Build the canonical {text, passed, evidence} triple."""
    return {"text": text, "passed": bool(passed), "evidence": str(evidence)}


def file_exists(root: Path, rel: str) -> Expectation:
    """Pass if `root/rel` exists and is a non-empty file."""
    p = Path(root) / rel
    if not p.is_file():
        return expectation(f"{rel} exists and is non-empty", False, f"{rel} missing")
    size = p.stat().st_size
    return expectation(f"{rel} exists and is non-empty", size > 0, f"{rel} size: {size} bytes")


def contains(root: Path, rel: str, needle: str, *, label: str | None = None) -> Expectation:
    """Pass if file `root/rel` contains the literal substring `needle`."""
    text = label or f"{rel} contains {needle!r}"
    p = Path(root) / rel
    if not p.is_file():
        return expectation(text, False, f"{rel} missing")
    present = needle in p.read_text(encoding="utf-8", errors="replace")
    return expectation(text, present, f"{needle!r} present: {present}")


def not_contains(root: Path, rel: str, needle: str, *, label: str | None = None) -> Expectation:
    """Pass if file `root/rel` does NOT contain the literal substring `needle`.

    The negation of contains(). Used to assert a tool did NOT receive the end-of-turn
    refresh hook (the single-refresh-owner invariant), where a missing file is a failure
    rather than a vacuous pass.
    """
    text = label or f"{rel} lacks {needle!r}"
    p = Path(root) / rel
    if not p.is_file():
        return expectation(text, False, f"{rel} missing")
    absent = needle not in p.read_text(encoding="utf-8", errors="replace")
    return expectation(text, absent, f"{needle!r} present: {not absent}")


def no_fabrication(root: Path, rel: str) -> Expectation:
    """Pass if `root/rel` does NOT exist — used to assert the skill invented nothing.

    e.g. on the setup-graph-hooks `no-agents-md` precondition case, AGENTS.md must not be
    fabricated.
    """
    p = Path(root) / rel
    absent = not p.exists()
    return expectation(f"{rel} not fabricated", absent, f"{rel} present: {not absent}")


def json_roundtrip(root: Path, rel: str) -> Expectation:
    """Pass if `root/rel` parses as JSON."""
    p = Path(root) / rel
    if not p.is_file():
        return expectation(f"{rel} is valid JSON", False, f"{rel} missing")
    try:
        json.loads(p.read_text(encoding="utf-8"))
        return expectation(f"{rel} is valid JSON", True, "parsed OK")
    except json.JSONDecodeError as exc:
        return expectation(f"{rel} is valid JSON", False, f"parse error: {exc}")


def git_diff_empty(target: Path) -> Expectation:
    """Idempotency: a re-run must leave nothing dirty under `target`.

    A non-repo target fails rather than passing vacuously — an empty `git status` from a
    directory that isn't a repo would otherwise read as "clean".
    """
    proc = subprocess.run(
        ["git", "-C", str(target), "status", "--porcelain"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return expectation("re-run produces an empty diff", False, "target is not a git repo")
    dirty = proc.stdout.strip()
    return expectation("re-run produces an empty diff", not dirty, dirty or "working tree clean")


_SUMMARY_RE = re.compile(r"Summary:\s*(\d+)\s+passed,\s*(\d+)\s+warnings,\s*(\d+)\s+failed")


def run_verify_script(script: Path, target: Path) -> Expectation:
    """Run a skill's bundled verify-*.sh against `target` and grade it.

    Parses the script's `Summary: N passed, W warnings, F failed` line and its exit code.
    The script is read-only by contract; this only invokes it, never an LLM.
    Returns one expectation whose evidence carries the verbatim Summary line + exit code.

    A missing script fails rather than raising. A script that prints no Summary line also
    fails (`failed` stays None, so `failed == 0` is False) — a verifier that forgets its
    summary is treated as broken, not silently passed.
    """
    script, target = Path(script), Path(target)
    name = script.name
    if not script.is_file():
        return expectation(f"{name} passes", False, f"{name} not found at {script}")
    proc = subprocess.run(
        ["bash", str(script), str(target)],
        capture_output=True,
        text=True,
    )
    match = _SUMMARY_RE.search(proc.stdout)
    summary = match.group(0) if match else "(no Summary line)"
    failed = int(match.group(3)) if match else None
    passed = proc.returncode == 0 and failed == 0
    evidence = f"{summary} (exit {proc.returncode})"
    return expectation(f"{name} passes", passed, evidence)


def write_grading(out_path: Path, expectations: list[Expectation], timing: dict | None = None) -> dict:
    """Roll a list of expectations into a grading.json and write it."""
    passed = sum(1 for e in expectations if e["passed"])
    total = len(expectations)
    grading = {
        "expectations": expectations,
        "summary": {
            "pass_rate": (passed / total) if total else 0.0,
            "passed": passed,
            "failed": total - passed,
            "total": total,
        },
        "timing": timing or {},
    }
    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(grading, indent=2) + "\n", encoding="utf-8")
    return grading


def summarize(expectations: list[Expectation]) -> dict:
    """Build the same dict write_grading() writes, without touching disk.

    Lets grade.py print a grading to stdout when no --out is given.
    """
    passed = sum(1 for e in expectations if e["passed"])
    total = len(expectations)
    return {
        "expectations": expectations,
        "summary": {
            "pass_rate": (passed / total) if total else 0.0,
            "passed": passed,
            "failed": total - passed,
            "total": total,
        },
        "timing": {},
    }


def repo_root(start: Path) -> Path:
    """Walk up from `start` to the repo root — the first ancestor holding a skills/ dir."""
    return next(p for p in Path(start).resolve().parents if (p / "skills").is_dir())


def run_grader(grade_fn, argv: list[str]) -> int:
    """Shared CLI for every workspace grade.py.

        python3 grade.py <produced-project-dir> [eval_id] [--out grading.json]

    `grade_fn(target, eval_id) -> list[Expectation]`. Prints grading.json to stdout and
    also writes it when --out is given. Exits 0 iff no expectation failed.
    """
    if not argv:
        return 2
    out = None
    if "--out" in argv:
        i = argv.index("--out")
        out = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    target = Path(argv[0]).resolve()
    eval_id = argv[1] if len(argv) > 1 else None

    expectations = grade_fn(target, eval_id)
    grading = write_grading(Path(out), expectations) if out else summarize(expectations)
    print(json.dumps(grading, indent=2))
    return 0 if grading["summary"]["failed"] == 0 else 1


def _selftest() -> int:
    import tempfile

    e = expectation("sample", True, "because")
    assert set(e) == {"text", "passed", "evidence"}, e
    assert e == json.loads(json.dumps(e)), "triple must JSON round-trip"
    assert _SUMMARY_RE.search("Summary: 8 passed, 1 warnings, 0 failed").group(3) == "0"

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "AGENTS.md").write_text("# AGENTS\n@guidelines\n", encoding="utf-8")
        (root / "empty.md").write_text("", encoding="utf-8")
        (root / "cfg.json").write_text('{"a": 1}', encoding="utf-8")

        assert file_exists(root, "AGENTS.md")["passed"]
        assert not file_exists(root, "empty.md")["passed"], "empty file must fail"
        assert not file_exists(root, "nope.md")["passed"]
        assert contains(root, "AGENTS.md", "@guidelines")["passed"]
        assert not contains(root, "AGENTS.md", "absent")["passed"]
        assert not_contains(root, "AGENTS.md", "absent")["passed"]
        assert not not_contains(root, "AGENTS.md", "@guidelines")["passed"]
        assert not not_contains(root, "missing.md", "x")["passed"], "missing file must fail"
        assert no_fabrication(root, "invented.md")["passed"]
        assert not no_fabrication(root, "AGENTS.md")["passed"]
        assert json_roundtrip(root, "cfg.json")["passed"]
        assert not json_roundtrip(root, "AGENTS.md")["passed"]

        # A verifier that prints no Summary line must FAIL, not silently pass.
        bad = root / "verify-silent.sh"
        bad.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        exp = run_verify_script(bad, root)
        assert not exp["passed"], "no Summary line must fail"
        assert "(no Summary line)" in exp["evidence"], exp

        good = root / "verify-good.sh"
        good.write_text(
            "#!/usr/bin/env bash\necho 'Summary: 8 passed, 1 warnings, 0 failed'\nexit 0\n",
            encoding="utf-8")
        exp = run_verify_script(good, root)
        assert exp["passed"], exp
        assert exp["evidence"] == "Summary: 8 passed, 1 warnings, 0 failed (exit 0)", exp

        fail = root / "verify-fail.sh"
        fail.write_text(
            "#!/usr/bin/env bash\necho 'Summary: 2 passed, 0 warnings, 3 failed'\nexit 1\n",
            encoding="utf-8")
        assert not run_verify_script(fail, root)["passed"]
        assert not run_verify_script(root / "absent.sh", root)["passed"], "missing script must fail"

        # A non-repo target must fail rather than passing on an empty `git status`.
        assert not git_diff_empty(root)["passed"]

        grading = write_grading(root / "grading.json", [
            expectation("a", True, "ok"), expectation("b", False, "nope"),
        ])
        assert grading["summary"] == {"pass_rate": 0.5, "passed": 1, "failed": 1, "total": 2}
        assert (root / "grading.json").is_file()
        assert summarize([])["summary"]["pass_rate"] == 0.0, "empty must not divide by zero"

    print("grade_common selftest OK")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    print(__doc__)
