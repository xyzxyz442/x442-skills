#!/usr/bin/env python3
"""Grader for the x442-delegate-handoff skill.

delegate-handoff is a discipline over `handoff export`/`handoff import --result` — it ships no
scripts of its own. This grader confirms the environment is sound (wraps setup-handoff's verifier
once, same as run-handoff's grader) and then drives the board's own installed `handoff` binary
exactly as the discipline prescribes, asserting the produced artifacts: a brief whose
`repo_root_commit` matches the target repo, a doc stamped `delegated_to` with a held lease, a
clean import that leaves `status` untouched and `review: pending`, and — the sharp assertion —
that every hostile brief is refused AND leaves the target doc byte-identical. Read-only and
LLM-free; all mutation happens in an isolated temp copy (see isolated_git_target).

Usage:
    python3 grade.py <produced-project-dir> [eval_id] [--out grading.json]

eval_id in {export-single | export-bundle | import-clean | import-hostile | unwired}.
Default (no eval_id, or an unrecognized one) is export-single.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "lib"))
import grade_common as gc  # noqa: E402

REPO = gc.repo_root(HERE)
VERIFY = REPO / "skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh"
HD = ".agents/handoff"
TO = "Acme Contracting"  # the delegate every fixture's briefs were exported --to


def _handoff(target, *args):
    ho = Path(target) / HD / "handoff"
    return subprocess.run(["bash", str(ho), *args], cwd=str(target), capture_output=True, text=True)


def _frontmatter(path: Path) -> dict:
    fm = {}
    if not path.is_file():
        return fm
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---":
        return fm
    for ln in lines[1:]:
        if ln == "---":
            break
        if ":" in ln:
            k, _, v = ln.partition(":")
            fm[k.strip()] = v.strip()
    return fm


def _root_commit(target: Path) -> str:
    proc = subprocess.run(
        ["git", "-C", str(target), "rev-list", "--max-parents=0", "HEAD"],
        capture_output=True, text=True,
    )
    lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
    return lines[-1] if lines else ""


def _restamp_repo_root(brief_path: Path, root: str) -> None:
    """Re-stamp a pre-baked brief's repo_root_commit to match the isolated copy's real HEAD.

    isolated_git_target relocates a nested fixture into a FRESH `git init` + one commit (see its
    docstring) so the bundled verify-*.sh grades the fixture, not the outer x442-skills repo. That
    mints a brand-new root-commit SHA every run. A brief baked at fixture-BUILD time cannot predict
    that SHA, so without this the repo guard would refuse EVERY pre-exported brief as "a different
    repository" -- not because of the defect the fixture is meant to exercise, but purely because
    of how the harness isolates fixtures. Re-stamping to what a live `export` against THIS isolated
    copy would have produced routes each import to the refusal it is actually testing (unfilled,
    secret) instead of an accidental, harness-induced repo mismatch. Never called for the
    wrong-repo hostile brief, whose entire point is a mismatched identity.
    """
    text = brief_path.read_text(encoding="utf-8")
    text = re.sub(r"(?m)^repo_root_commit:.*$", f"repo_root_commit: {root}", text, count=1)
    brief_path.write_text(text, encoding="utf-8")


def _lease_held(doc_dir: Path, id_: str) -> bool:
    return (doc_dir / ".locks" / id_).is_dir()


def grade(target, eval_id):
    graded, cleanup = gc.isolated_git_target(target)
    if graded != Path(target).resolve():
        print(f"[grade] isolated fixture to its own git root: {graded}", file=sys.stderr)
    try:
        return _grade(graded, eval_id)
    finally:
        cleanup()


def _grade(target: Path, eval_id):
    doc_dir = target / HD

    if eval_id == "unwired":
        # Pre-state: no .agents/handoff installed at all. There is no CLI to drive, so this is
        # graded on the environment check alone -- the A/B baseline the post-state cases below
        # are compared against. A wired board (any of the other four fixtures) always has
        # .agents/handoff, so this single failed expectation is the whole story: 0/1 -> 0.00.
        return [gc.run_verify_script(VERIFY, target)]

    exps = [gc.run_verify_script(VERIFY, target)]  # environment sanity, as run-handoff's grader does

    if eval_id == "export-bundle":
        r = _handoff(target, "export", "release-hardening", "--to", TO)
        exps.append(gc.expectation("export succeeds on an orchestrator", r.returncode == 0,
                                    f"exit {r.returncode}: {(r.stdout + r.stderr).strip()[-300:]}"))
        cover_rel = f"{HD}/briefs/release-hardening-handoff.cover.md"
        exps.append(gc.file_exists(target, cover_rel))
        root = _root_commit(target)
        for cid in ("auth-flow-handoff", "payment-flow-handoff", "notif-flow-handoff"):
            brief = doc_dir / "briefs" / f"{cid}.brief.md"
            fm = _frontmatter(brief)
            exps.append(gc.expectation(f"{cid}: brief was produced", brief.is_file(), str(brief)))
            exps.append(gc.expectation(
                f"{cid}: brief's repo_root_commit matches the target repo",
                fm.get("repo_root_commit") == root and bool(root),
                f"want {root!r}, got {fm.get('repo_root_commit')!r}"))
            doc_fm = _frontmatter(doc_dir / f"{cid}.md")
            exps.append(gc.expectation(f"{cid}: doc carries delegated_to",
                                        doc_fm.get("delegated_to") == TO,
                                        f"delegated_to={doc_fm.get('delegated_to')!r}"))
            exps.append(gc.expectation(f"{cid}: doc holds a lease", _lease_held(doc_dir, cid),
                                        f"lock dir present: {_lease_held(doc_dir, cid)}"))
            exps.append(gc.contains(target, cover_rel, cid, label=f"cover lists {cid}"))
        return exps

    if eval_id == "import-clean":
        brief = doc_dir / "briefs" / "rate-limit-fix-handoff.brief.md"
        _restamp_repo_root(brief, _root_commit(target))
        doc = doc_dir / "rate-limit-fix-handoff.md"
        r = _handoff(target, "import", "--result", str(brief))
        exps.append(gc.expectation("import --result succeeds", r.returncode == 0,
                                    f"exit {r.returncode}: {(r.stdout + r.stderr).strip()[-300:]}"))
        fm = _frontmatter(doc)
        # The load-bearing assertion: import never writes status. The executor's claim lands in
        # result_claimed; done stays a reviewer action taken after reproducing evidence.
        exps.append(gc.expectation("status is STILL open after import (import never closes it)",
                                    fm.get("status") == "open", f"status={fm.get('status')!r}"))
        exps.append(gc.expectation("review is pending", fm.get("review") == "pending",
                                    f"review={fm.get('review')!r}"))
        exps.append(gc.expectation("result_claimed records the executor's claim",
                                    fm.get("result_claimed") == "done",
                                    f"result_claimed={fm.get('result_claimed')!r}"))
        exps.append(gc.expectation("result_from records the reporter", fm.get("result_from") == TO,
                                    f"result_from={fm.get('result_from')!r}"))
        exps.append(gc.contains(target, f"{HD}/rate-limit-fix-handoff.md", "token-bucket refill math",
                                 label="Result body was spliced into the doc"))
        return exps

    if eval_id == "import-hostile":
        root = _root_commit(target)
        # (id, refusal substring, restamp repo_root_commit to the live root first?)
        cases = [
            ("hostile-unfilled-handoff", "not filled in", True),
            ("hostile-wrong-repo-handoff", "different repository", False),
            # The RULE the scanner names, not a phrase from the message wrapper: the refusal is
            # now shared across every write path (ADR 0005), so the rule id is the stable part.
            ("hostile-secret-handoff", "aws-access-key-id", True),
        ]
        for id_, msg, do_restamp in cases:
            brief = doc_dir / "briefs" / f"{id_}.brief.md"
            doc = doc_dir / f"{id_}.md"
            if do_restamp:
                _restamp_repo_root(brief, root)
            before = doc.read_text(encoding="utf-8")
            r = _handoff(target, "import", "--result", str(brief))
            out = r.stdout + r.stderr
            exps.append(gc.expectation(f"{id_} is refused ({msg!r})",
                                        r.returncode != 0 and msg in out,
                                        f"exit {r.returncode}: {out.strip()[-200:]}"))
            after = doc.read_text(encoding="utf-8")
            # The sharp assertion: a refusal that printed the right message but still mutated the
            # doc is a FAILED refusal. Only a before/after byte comparison catches that.
            exps.append(gc.expectation(f"{id_} refusal leaves the doc byte-identical",
                                        before == after,
                                        "unchanged" if before == after else "doc MUTATED by a refused import"))
        return exps

    # default: export-single, against the `exportable` fixture
    id_ = "tenant-switch-handoff"
    root = _root_commit(target)
    r = _handoff(target, "export", "tenant-switch", "--to", TO)
    exps.append(gc.expectation("export succeeds", r.returncode == 0,
                                f"exit {r.returncode}: {(r.stdout + r.stderr).strip()[-300:]}"))
    brief = doc_dir / "briefs" / f"{id_}.brief.md"
    fm = _frontmatter(brief)
    exps.append(gc.file_exists(target, f"{HD}/briefs/{id_}.brief.md"))
    exps.append(gc.expectation("brief's repo_root_commit matches the target repo",
                                fm.get("repo_root_commit") == root and bool(root),
                                f"want {root!r}, got {fm.get('repo_root_commit')!r}"))
    doc_fm = _frontmatter(doc_dir / f"{id_}.md")
    exps.append(gc.expectation("doc carries delegated_to", doc_fm.get("delegated_to") == TO,
                                f"delegated_to={doc_fm.get('delegated_to')!r}"))
    exps.append(gc.expectation("doc holds a lease", _lease_held(doc_dir, id_),
                                f"lock dir present: {_lease_held(doc_dir, id_)}"))
    exps.append(gc.expectation("status untouched by export", doc_fm.get("status") == "open",
                                f"status={doc_fm.get('status')!r}"))
    return exps


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
