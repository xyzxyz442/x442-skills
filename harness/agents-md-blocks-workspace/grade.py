#!/usr/bin/env python3
"""Grader for the shared AGENTS.md managed-block invariant.

The first **cross-skill** workspace here: it grades an invariant no single skill owns. Five
skills splice a managed block into the same AGENTS.md, through four separate implementations,
and every one of them shipped the same defect — no blank line survived between a managed block
and whatever followed it, and one of them deleted the tail outright on removal. Nothing caught
it, because every workspace grades one skill against one repo and the defect is only reachable
when two skills write the same file. See agents-md-splice-audit-handoff.

The cases are ordered by how directly they name the failure:

- `splice-selftests`            — does the assertion class even exist, in every copy?
- `sibling-blocks-stable`       — the unit-level invariant, all four implementations, one file
- `graph-removal-keeps-siblings`— the data-loss half, which is not whitespace
- `installer-sibling-blocks`    — the real installers, run for real, into one repo

Read-only with respect to the repo and LLM-free: the pure-function cases operate on strings, and
the installer case runs inside a temp copy produced by `grade_common.isolated_git_target`.

Usage:
    python3 grade.py <produced-project-dir> [eval_id] [--out grading.json]
"""

import importlib.util
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "lib"))
import grade_common as gc  # noqa: E402

REPO = gc.repo_root(HERE)
SKILLS = REPO / "skills"

# A file is a splice IMPLEMENTATION if it does the head/tail surgery, not merely if it mentions a
# marker. Matching on filename would have missed both of the copies that were hiding: one was an
# inline heredoc in a .sh, the other was prose inside a SKILL.md. Both would match here — the
# SKILL.md version called `text.find(END)`, the heredoc `text.index(END)`.
SPLICE_SIGNS = ("def splice(", ".index(END", ".find(END", ".index(BEG", ".find(BEG")
MARKER = ":end -->"

# The block asset files carry the markers as CONTENT. They are data, not implementations.
ASSET_DIRS = ("/assets/",)

GRAPH_HOOKS = SKILLS / "engineering/setup-graph-hooks"
SETUP_HANDOFF = SKILLS / "engineering/setup-handoff"


def find_splice_implementations() -> list[Path]:
    """Every file under skills/ that performs an AGENTS.md managed-block splice."""
    out = []
    for p in sorted(SKILLS.rglob("*")):
        if not p.is_file() or p.suffix not in (".py", ".sh", ".md"):
            continue
        if any(d in str(p) for d in ASSET_DIRS):
            continue
        try:
            text = p.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if MARKER in text and any(s in text for s in SPLICE_SIGNS):
            out.append(p)
    return out


def load_splice(path: Path):
    """Import a splice implementation and hand back (module, BEGIN, END), or None.

    None is a verdict, not an error: a splice that lives inline in a SKILL.md heredoc or inside a
    shell script cannot be imported, which is precisely why two of them drifted unnoticed. The
    caller records that as a failed expectation naming the file.
    """
    if path.suffix != ".py":
        return None
    try:
        spec = importlib.util.spec_from_file_location(f"splice_{abs(hash(path))}", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod, mod.BEGIN, mod.END
    except Exception:
        return None


def synthetic_block(begin: str, end: str) -> str:
    return f"{begin} (managed) -->\nbody\n{end}\n"


def between_blocks(text: str) -> list[tuple[str, str, str]]:
    """(end-marker, next-begin-marker, the raw bytes between them) for each adjacent pair.

    "Adjacent" means nothing but whitespace separates the two blocks — which is exactly the case
    the four splices got wrong, and the only one where the separator is theirs to own.
    """
    pairs = []
    for m in re.finditer(r"<!-- ([a-z-]+):end -->", text):
        rest = text[m.end():]
        nxt = re.match(r"(\s*)<!-- ([a-z-]+):begin", rest)
        if nxt:
            pairs.append((m.group(1), nxt.group(2), nxt.group(1)))
    return pairs


def _selftest_expectations() -> list[dict]:
    impls = find_splice_implementations()
    exps = [gc.expectation(
        "discovery found the AGENTS.md splice implementations",
        len(impls) >= 4,
        # An empty or short result graded as success is this repo's characteristic failure — two
        # graders once scored an empty dict 1.00. Assert the input is non-empty before grading it.
        f"{len(impls)} found: " + ", ".join(str(p.relative_to(REPO)) for p in impls),
    )]
    for p in impls:
        rel = str(p.relative_to(REPO))
        text = p.read_text(encoding="utf-8")
        if "--selftest" not in text:
            exps.append(gc.expectation(
                f"{rel} carries a --selftest", False,
                "no --selftest: this splice has no unit coverage, which is how all four copies "
                "shipped the same whitespace defect",
            ))
            continue
        r = subprocess.run([sys.executable, str(p), "--selftest"],
                           capture_output=True, text=True, timeout=60)
        exps.append(gc.expectation(
            f"{rel} --selftest passes", r.returncode == 0,
            (r.stdout.strip() or r.stderr.strip() or "no output")[-400:],
        ))
    return exps


def _sibling_expectations(agents_md: Path) -> list[dict]:
    original = agents_md.read_text(encoding="utf-8")
    head_prose = original.split("<!--", 1)[0]
    impls = find_splice_implementations()
    exps = [gc.expectation("discovery found the AGENTS.md splice implementations",
                           len(impls) >= 4, f"{len(impls)} found")]

    text = original
    loaded = []
    for p in impls:
        got = load_splice(p)
        if got is None:
            exps.append(gc.expectation(
                f"{p.relative_to(REPO)} is reachable as a testable splice", False,
                "not importable — this splice is inline in prose or shell, so no assertion can "
                "reach it; that is how it diverged from its siblings",
            ))
            continue
        loaded.append((p, got))
        mod, begin, end = got
        text = mod.splice(text, synthetic_block(begin, end))

    markers = sorted(set(re.findall(r"<!-- ([a-z-]+):begin", text)))
    exps.append(gc.expectation(
        "every splice landed its own block in the one file",
        len(markers) >= 4, f"blocks present: {', '.join(markers)}",
    ))

    pairs = between_blocks(text)
    bad = [(a, b, sep) for a, b, sep in pairs if sep != "\n\n"]
    exps.append(gc.expectation(
        "adjacent managed blocks are separated by exactly one blank line",
        pairs and not bad,
        f"{len(pairs)} adjacent pair(s); offenders: {bad!r}" if bad
        else f"{len(pairs)} adjacent pair(s), all separated by exactly one blank line",
    ))

    # THE REGRESSION, stated as a re-run: applying each splice a second time must change nothing.
    # This is what the fleet sync saw as "M AGENTS.md" on every member repo, for two minutes,
    # with nothing to say which of the two blocks moved.
    unstable = []
    for p, (mod, begin, end) in loaded:
        again = mod.splice(text, synthetic_block(begin, end))
        if again != text:
            unstable.append(str(p.relative_to(REPO)))
    exps.append(gc.expectation(
        "re-applying every splice leaves the file byte-identical",
        not unstable, f"byte-stable across a second pass of all {len(loaded)}"
        if not unstable else f"not idempotent: {', '.join(unstable)}",
    ))

    exps.append(gc.expectation(
        "the repo's own prose above the blocks survives byte-identical",
        text.startswith(head_prose), f"{len(head_prose)} leading bytes preserved: {text.startswith(head_prose)}",
    ))
    exps.append(gc.expectation(
        "the repo's own prose below the blocks survives",
        "make build" in text, "trailing build section still present" if "make build" in text
        else "trailing prose was consumed by a splice",
    ))
    return exps


def _removal_expectations(agents_md: Path) -> list[dict]:
    original = agents_md.read_text(encoding="utf-8")
    graph = SKILLS / "engineering/register-cross-repo-graph/scripts/manifest/render.py"
    got = load_splice(graph)
    if got is None:
        return [gc.expectation(
            "register-cross-repo-graph's splice is reachable as a testable function", False,
            f"{graph.relative_to(REPO)} could not be imported",
        )]
    mod, begin, end = got
    blk = synthetic_block(begin, end)

    exps = []
    # Appended at EOF (where it sits today) — removal must restore the exact original bytes.
    added = mod.splice(original, blk)
    removed = mod.splice(added, "")
    exps.append(gc.expectation(
        "removing an EOF-appended cross-repo block restores the original bytes",
        removed == original,
        "byte-identical to the pre-splice file" if removed == original
        else f"differs: {len(original)} -> {len(removed)} bytes",
    ))

    # The reachable one: the block sits ABOVE a sibling skill's block, which is what the
    # documented install chain produces. The old removal path returned the head and deleted
    # everything after the end marker — including that sibling block.
    anchor = "<!-- handoff:begin"
    assert anchor in original, "fixture must carry a sibling block"
    stacked = original.replace(anchor, blk + "\n" + anchor, 1)
    removed2 = mod.splice(stacked, "")
    exps.append(gc.expectation(
        "removing a cross-repo block ABOVE a sibling block keeps the sibling",
        removed2 == original,
        "the handoff routing block below it survived, byte-identical" if removed2 == original
        else f"TAIL LOST: {len(original)} -> {len(removed2)} bytes; "
             f"handoff block present: {anchor in removed2}",
    ))
    exps.append(gc.expectation(
        "no other managed block is disturbed by the removal",
        sorted(re.findall(r"<!-- ([a-z-]+):begin", removed2))
        == sorted(re.findall(r"<!-- ([a-z-]+):begin", original)),
        f"blocks after removal: {sorted(set(re.findall(r'<!-- ([a-z-]+):begin', removed2)))}",
    ))
    return exps


def _installer_expectations(target: Path) -> list[dict]:
    graded, cleanup = gc.isolated_git_target(target)
    try:
        agents = graded / "AGENTS.md"
        steps = [
            ["bash", str(GRAPH_HOOKS / "scripts/setup-graph-hooks.sh"), str(graded),
             "--tools", "claude", "--primary", "claude"],
            [sys.executable, str(GRAPH_HOOKS / "scripts/splice-agents-block.py"),
             "--file", str(agents), "--block", str(GRAPH_HOOKS / "assets/agents-knowledge-graph.md")],
            ["bash", str(SETUP_HANDOFF / "scripts/setup-handoff.sh"), str(graded),
             "--tools", "claude", "--primary", "claude"],
        ]
        exps = []
        for cmd in steps:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            if r.returncode != 0:
                return [gc.skipped(
                    "both installers run into one repo",
                    f"{Path(cmd[1]).name} exited {r.returncode}: "
                    f"{(r.stderr.strip() or r.stdout.strip())[-300:]}",
                )]
        after_install = agents.read_text(encoding="utf-8")
        exps.append(gc.expectation(
            "both installers wrote their block into the one AGENTS.md",
            "<!-- graph-hooks:begin" in after_install and "<!-- handoff:begin" in after_install,
            f"graph-hooks: {'<!-- graph-hooks:begin' in after_install}, "
            f"handoff: {'<!-- handoff:begin' in after_install}",
        ))
        pairs = between_blocks(after_install)
        bad = [p for p in pairs if p[2] != "\n\n"]
        exps.append(gc.expectation(
            "the installed blocks are separated by exactly one blank line",
            pairs and not bad,
            f"{len(pairs)} adjacent pair(s); offenders: {bad!r}" if bad
            else f"{[(a, b) for a, b, _ in pairs]} separated by exactly one blank line",
        ))
        # Re-run each installer. This is the assertion the suite never made: not "does the
        # installer work" but "does running the OTHER one leave this one's block alone".
        for cmd in steps:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            name = Path(cmd[1]).name
            now = agents.read_text(encoding="utf-8")
            exps.append(gc.expectation(
                f"re-running {name} leaves AGENTS.md byte-identical",
                r.returncode == 0 and now == after_install,
                "no change" if now == after_install
                else f"AGENTS.md changed on re-run ({len(after_install)} -> {len(now)} bytes)",
            ))
        return exps
    finally:
        cleanup()


def grade(target: Path, eval_id: str | None) -> list[dict]:
    gc.pre_state_hint(HERE, eval_id)
    agents_md = target / "AGENTS.md"
    if eval_id in (None, "splice-selftests"):
        exps = _selftest_expectations()
        if eval_id is not None:
            return exps
    else:
        exps = []
    if eval_id == "sibling-blocks-stable":
        return _sibling_expectations(agents_md)
    if eval_id == "graph-removal-keeps-siblings":
        return _removal_expectations(agents_md)
    if eval_id == "installer-sibling-blocks":
        return _installer_expectations(target)
    return exps


if __name__ == "__main__":
    sys.exit(gc.run_grader(grade, sys.argv[1:]))
