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
import os
import re
import shutil
import subprocess
import sys
import tempfile
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


def run_verify_script(script: Path, target: Path, *, env: dict | None = None) -> Expectation:
    """Run a skill's bundled verify-*.sh against `target` and grade it.

    Parses the script's `Summary: N passed, W warnings, F failed` line and its exit code.
    The script is read-only by contract; this only invokes it, never an LLM.
    Returns one expectation whose evidence carries the verbatim Summary line + exit code.

    A missing script fails rather than raising. A script that prints no Summary line also
    fails (`failed` stays None, so `failed == 0` is False) — a verifier that forgets its
    summary is treated as broken, not silently passed.

    `env` (when given) fully replaces the subprocess environment — used by the cross-repo
    grader to pin a throwaway `$HOME`, so a verifier that reads `~/.code-review-graph/` sees a
    sandboxed registry instead of the machine's real one.
    """
    script, target = Path(script), Path(target)
    name = script.name
    if not script.is_file():
        return expectation(f"{name} passes", False, f"{name} not found at {script}")
    proc = subprocess.run(
        ["bash", str(script), str(target)],
        capture_output=True,
        text=True,
        env=env,
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


_HARNESS_GIT_ENV = {
    "GIT_AUTHOR_NAME": "x442-harness", "GIT_AUTHOR_EMAIL": "harness@x442.local",
    "GIT_COMMITTER_NAME": "x442-harness", "GIT_COMMITTER_EMAIL": "harness@x442.local",
}


def _git_toplevel(path: Path) -> Path | None:
    """The git working-tree root that contains `path`, or None if `path` is in no repo."""
    proc = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
        capture_output=True, text=True,
    )
    return Path(proc.stdout.strip()).resolve() if proc.returncode == 0 and proc.stdout.strip() else None


def git_init_commit(path: Path, message: str = "harness baseline") -> None:
    """`git init` `path` (if needed) and commit its whole tree, honoring its .gitignore.

    Gives a fixture a clean, self-contained baseline so `git status --porcelain` reflects the
    fixture alone. Author/committer identity is forced via env so the machine's git config can
    neither block the commit (missing user.name) nor leak into it.
    """
    path = Path(path)
    if not (path / ".git").exists():
        subprocess.run(["git", "-C", str(path), "init", "-q"], check=True)
    env = {**os.environ, **_HARNESS_GIT_ENV}
    subprocess.run(["git", "-C", str(path), "add", "-A"], check=True)
    subprocess.run(
        ["git", "-C", str(path), "commit", "-q", "--allow-empty", "-m", message],
        env=env, check=True,
    )


def isolated_git_target(target: Path) -> tuple[Path, "callable"]:
    """Return `(graded_target, cleanup)` — a target the bundled verify-*.sh can grade correctly.

    The skills' `verify-*.sh` (and `git_diff_empty`) resolve the *git toplevel*, not the passed
    directory, and the graph hooks resolve their `graph.db` from that same toplevel. A fixture
    that lives inside a larger repo — this harness inside x442-skills — therefore makes every one
    of those grade the OUTER repo instead of the fixture, which is the in-git-tree leak that made
    wired fixtures score below 1.00 when run in place.

    When `target` is already its own git root, grade it in place (cleanup is a no-op). Otherwise
    copy it to a fresh temp dir and `git init` there, so the toplevel *is* the fixture. Callers
    must invoke `cleanup()` (a `finally:` is idiomatic) to remove the temp copy.
    """
    target = Path(target).resolve()
    if _git_toplevel(target) == target:
        return target, (lambda: None)
    tmp = Path(tempfile.mkdtemp(prefix="x442-iso-"))
    # .resolve(): on macOS mkdtemp hands back /var/... (a symlink to /private/var/...), while
    # `git rev-parse --show-toplevel` reports the realpath. Return the resolved path so callers
    # comparing against the toplevel (and the hooks' own path hashing) stay consistent.
    dest = (tmp / target.name).resolve()
    shutil.copytree(target, dest, symlinks=True)
    git_init_commit(dest)
    return dest, (lambda: shutil.rmtree(tmp, ignore_errors=True))


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

        # Isolation: a fixture NESTED in an outer repo must be copied out so git_diff_empty and
        # verify-*.sh see the fixture, not the outer tree. Build outer-repo/nested and dirty the
        # outer tree; the isolated copy must still be clean and be its own git root.
        outer = root / "outer"
        nested = outer / "nested"
        nested.mkdir(parents=True)
        (nested / "keep.txt").write_text("fixture\n", encoding="utf-8")
        git_init_commit(outer)
        (outer / "dirty.txt").write_text("outer tree is dirty\n", encoding="utf-8")  # outer only
        assert not git_diff_empty(nested)["passed"], "nested target must see the dirty OUTER tree"
        graded, cleanup = isolated_git_target(nested)
        try:
            assert graded != nested, "a nested target must be relocated"
            assert _git_toplevel(graded) == graded, "isolated copy must be its own git root"
            assert (graded / "keep.txt").is_file(), "isolation must preserve fixture contents"
            assert git_diff_empty(graded)["passed"], "isolated copy must be clean"
        finally:
            cleanup()
        assert not graded.exists(), "cleanup must remove the temp copy"

        # A target that is ALREADY its own git root is graded in place (no relocation).
        standalone = root / "standalone"
        standalone.mkdir()
        (standalone / "f.txt").write_text("x\n", encoding="utf-8")
        git_init_commit(standalone)
        graded2, cleanup2 = isolated_git_target(standalone)
        try:
            assert graded2 == standalone.resolve(), "own-root target must not be relocated"
        finally:
            cleanup2()

    print("grade_common selftest OK")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    print(__doc__)
