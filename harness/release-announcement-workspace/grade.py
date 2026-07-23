#!/usr/bin/env python3
"""Grader for the x442-release-announcement skill.

The first text-output grader in this harness. The skill ships no scripts, so there is no
verify-*.sh to wrap (evals.json omits `verify_script`; nothing in lib/ reads it) — the
produced announcement prose is graded directly against the skill's own `## Rules` and
`## Verification` sections (skills/productivity/release-announcement/SKILL.md). Read-only
and LLM-free; nothing is mutated, so no git isolation is needed.

The produced dir is the fixture project with an `ANNOUNCEMENT.md` added; the other files
(`CHANGELOG.md`, `package.json`, `README.md`) are the inputs every announcement claim must
trace back to. Emoji are never graded: AGENTS.md's "no emojis" rule governs skill content,
not the announcements a skill generates.

Usage:
    python3 grade.py <produced-project-dir> [eval_id] [--out grading.json]

eval_id ∈ {github-release | announcement-good | violations}. All ids share one grading
contract; the id only selects the pre-state hint.
"""

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "lib"))
import grade_common as gc  # noqa: E402

ANNOUNCE = "ANNOUNCEMENT.md"
VERSION = "1.3.0"
UPGRADE = "npm install acme-relay@1.3.0"
COMPARE = "compare/v1.2.0...v1.3.0"
UPSTREAM = "gunn-private-lab"
MARKETING = ("excited to announce", "game-changing", "supercharged")
OVERCLAIM = "enforced by the server"


def _input_corpus(target: Path) -> str:
    """Concatenated text of every input file — the pool announcement numbers must trace to."""
    parts = []
    for p in sorted(target.iterdir()):
        if p.is_file() and p.name != ANNOUNCE and p.suffix in {".md", ".json"}:
            parts.append(p.read_text(encoding="utf-8", errors="replace"))
    return "\n".join(parts)


def grade(target, eval_id):
    gc.pre_state_hint(HERE, eval_id)
    target = Path(target)
    path = target / ANNOUNCE
    exists = path.is_file()
    text = path.read_text(encoding="utf-8", errors="replace") if exists else ""
    low = text.lower()

    def check(label, passed, evidence):
        if not exists:
            return gc.expectation(label, False, f"{ANNOUNCE} missing")
        return gc.expectation(label, passed, evidence)

    exps = [gc.file_exists(target, ANNOUNCE)]

    # Structure — from the skill's `## Structure` section.
    lines = [ln for ln in text.splitlines() if ln.strip()]
    title = lines[0] if lines else ""
    exps.append(check(f"structure: title line names the version ({VERSION})",
                      title.startswith("# ") and VERSION in title, f"title: {title[:80]!r}"))
    body = text.splitlines()[1:] if lines else []
    lede = [ln for ln in _until_heading(body) if ln.strip()]
    exps.append(check("structure: a lede paragraph follows the title",
                      bool(lede), f"{len(lede)} prose line(s) before the first section"))
    exps.append(check("structure: a highlights section exists",
                      "highlight" in low, f"'highlight' present: {'highlight' in low}"))
    exps.append(check("structure: Get-it block carries the copy-pasteable upgrade command",
                      UPGRADE in text, f"{UPGRADE!r} present: {UPGRADE in text}"))
    link = COMPARE in text or "CHANGELOG.md" in text
    exps.append(check("structure: links the compare range or the full changelog",
                      link, f"compare range or CHANGELOG.md link present: {link}"))

    # Rules — from the skill's `## Rules` section; labels name the rule broken.
    found = [m for m in MARKETING if m in low]
    exps.append(check("rule: no marketing language",
                      not found, f"marketing phrases found: {found or 'none'}"))
    exps.append(check("rule: the non-public upstream is not named",
                      UPSTREAM not in low, f"{UPSTREAM!r} present: {UPSTREAM in low}"))
    exps.append(check("rule: no destructive command in the upgrade block",
                      "rm -rf" not in text, f"'rm -rf' present: {'rm -rf' in text}"))
    exps.append(check("rule: the status promotion (experimental -> stable) is stated",
                      "stable" in low, f"'stable' present: {'stable' in low}"))
    exps.append(check("rule: advisory rate limiting is not overstated as server-enforced",
                      OVERCLAIM not in low, f"{OVERCLAIM!r} present: {OVERCLAIM in low}"))
    corpus = _input_corpus(target)
    runs = sorted(set(re.findall(r"\d+", text)))
    invented = [r for r in runs if r not in corpus]
    exps.append(check("rule: no invented numbers (every digit run traces to the inputs)",
                      not invented,
                      f"invented: {invented}" if invented
                      else f"all {len(runs)} digit run(s) trace to the inputs"))
    return exps


def _until_heading(lines):
    for ln in lines:
        if ln.startswith("#"):
            return
        yield ln


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
