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
    # hooks.sh lives under scripts/; fall back to the flat path for a pre-restructure board. Raise
    # rather than returning "" when neither exists: empty output means ALLOW, so a missing hooks.sh
    # would make every gate assertion pass vacuously.
    hk = Path(target) / HD / "scripts/hooks.sh"
    if not hk.is_file():
        hk = Path(target) / HD / "hooks.sh"
    if not hk.is_file():
        raise FileNotFoundError(f"hooks.sh not found under {Path(target) / HD}")
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
    e.append(gc.expectation("handoff new creates a doc", (doc / "bt-handoff.md").is_file(),
                            f"bt-handoff.md exists: {(doc / 'bt-handoff.md').is_file()}"))

    _handoff(target, "claim", "bt", "on it", session="sess-AAA")
    lease = _lease(target, "bt-handoff")
    e.append(gc.expectation("claim writes session= into the lease (defect #1 fixed)",
                            "session=sess-AAA" in lease, f"lease: {lease!r}"))

    deny = _hook(target, "pretool-edit", {"tool_input": {"file_path": str(doc / "bt-handoff.md")}}, session="sess-BBB")
    e.append(gc.expectation("pretool gate DENIES a non-holder editing the doc",
                            '"permissionDecision": "deny"' in deny, f"out: {deny[:120]!r}"))
    allow = _hook(target, "pretool-edit", {"tool_input": {"file_path": str(doc / "bt-handoff.md")}}, session="sess-AAA")
    e.append(gc.expectation("pretool gate ALLOWS the holder (empty output)",
                            allow == "", f"out: {allow[:120]!r}"))

    r = _handoff(target, "release", "bt", "--status", "done")
    e.append(gc.expectation("done is REFUSED without --verified-by",
                            r.returncode != 0, f"exit {r.returncode}: {r.stderr.strip()[:100]}"))
    r = _handoff(target, "release", "bt", "--status", "done", "--verified-by", "manual: bt.js:1")
    e.append(gc.expectation("done with --verified-by archives the doc",
                            r.returncode == 0 and (doc / "archive/bt-handoff.md").is_file(),
                            f"exit {r.returncode}; archived: {(doc / 'archive/bt-handoff.md').is_file()}"))

    _handoff(target, "new", "blk", "--title", "Blocker")
    _handoff(target, "new", "dep", "--title", "Dependent")
    _handoff(target, "claim", "dep")
    r = _handoff(target, "release", "dep", "--status", "blocked")
    e.append(gc.expectation("blocked is REFUSED without --blocked-on",
                            r.returncode != 0, f"exit {r.returncode}"))
    _handoff(target, "claim", "dep")
    _handoff(target, "release", "dep", "--status", "blocked", "--blocked-on", "blk")
    dep_txt = (doc / "dep-handoff.md").read_text()
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
    _force_expiry(target, "aband-handoff")
    _hook(target, "sessionstart", {})
    e.append(gc.expectation("sessionstart auto-reaps an expired lease",
                            not (doc / ".locks/aband-handoff").exists(),
                            "lock present: %s" % (doc / ".locks/aband-handoff").exists()))

    # auto-touch: the holder's lease TTL is renewed on posttool-edit
    _handoff(target, "new", "live", "--title", "Live work")
    _handoff(target, "claim", "live", session="sess-AAA")
    _force_expiry(target, "live-handoff")
    _hook(target, "posttool-edit", {"tool_response": {"filePath": str(Path(target) / "src/app.js")}}, session="sess-AAA")
    exp = ""
    for ln in _lease(target, "live-handoff").splitlines():
        if ln.startswith("expires="):
            exp = ln.split("=", 1)[1]
    e.append(gc.expectation("posttool auto-touches the holder's lease (TTL renewed)",
                            exp.isdigit() and int(exp) > 100000, f"expires={exp}"))

    # verify: safe-by-default — a doc's verify: command is NOT executed without opt-in
    _handoff(target, "new", "vt", "--title", "Verify task")
    # inject a verify: command that leaves a marker FILE only if actually executed
    # (printing the command text must NOT count as running it)
    vt = doc / "vt-handoff.md"
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
    refdoc = doc / "refdoc-handoff.md"
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
                            rr.returncode == 0 and (doc / "archive/refdoc-handoff.md").is_file(),
                            f"exit {rr.returncode}; archived: {(doc / 'archive/refdoc-handoff.md').is_file()}"))
    # import brings an existing file onto the board as standalone
    src = Path(target) / "IMPORT_ME.md"
    src.write_text("# Imported\n\nbody\n")
    _handoff(target, "import", str(src), "--id", "imported", "--standalone")
    imp = doc / "imported-handoff.md"
    e.append(gc.expectation("import lands a file typed as standalone",
                            imp.is_file() and "type: standalone" in imp.read_text(),
                            f"exists: {imp.is_file()}"))

    # --- id casing: every id is folded to a lowercase-kebab slug --------------------------
    _handoff(target, "new", "RBAC Gap", "--title", "Caps and a space")
    slug = doc / "rbac-gap-handoff.md"
    e.append(gc.expectation("new slugifies a spaced, capitalized id",
                            slug.is_file(), f"rbac-gap-handoff.md exists: {slug.is_file()}"))
    e.append(gc.expectation("no non-conforming filename is created",
                            not list(doc.glob("RBAC*")),
                            f"stray: {[p.name for p in doc.glob('RBAC*')]}"))
    r = _handoff(target, "new", "RBAC_Gap", "--title", "Underscore spelling")
    e.append(gc.expectation("a differently-spelled id collides instead of forking the doc",
                            r.returncode != 0 and "already exists" in (r.stdout + r.stderr),
                            f"exit {r.returncode}: {(r.stdout + r.stderr).strip()[:100]}"))
    r = _handoff(target, "claim", "RBAC-GAP", "case-insensitive lookup")
    e.append(gc.expectation("claim resolves an id given in the wrong case",
                            r.returncode == 0 and (doc / ".locks/rbac-gap-handoff").exists(),
                            f"exit {r.returncode}; lock: {(doc / '.locks/rbac-gap-handoff').exists()}"))
    _handoff(target, "release", "rbac-gap", "--status", "open")
    e.append(gc.expectation("the generated Activity block is markdownlint-clean (blank line after the heading)",
                            "## Activity\n\n- " in slug.read_text(),
                            f"tail: {slug.read_text()[-120:]!r}"))
    r = _handoff(target, "new", "!!!")
    e.append(gc.expectation("an id with nothing alphanumeric is REJECTED",
                            r.returncode != 0 and not (doc / "-handoff.md").exists(),
                            f"exit {r.returncode}; '-handoff.md' created: {(doc / '-handoff.md').exists()}"))

    # legacy fallback: a doc named by a PRE-slug install must stay reachable, not be re-created
    legacy = doc / "Legacy_Doc-handoff.md"
    legacy.write_text("---\nid: Legacy_Doc-handoff\ntitle: Pre-slug doc\ntype: coordination\n"
                      "status: open\nseverity: low\ncreated: 2026-01-01\nupdated: 2026-01-01\n---\n\n## Context\n")
    r = _handoff(target, "claim", "Legacy_Doc", "picking up legacy work")
    e.append(gc.expectation("claim falls back to a pre-slug filename instead of inventing a slug",
                            r.returncode == 0 and (doc / ".locks/Legacy_Doc-handoff").exists()
                            and not (doc / "legacy-doc-handoff.md").exists(),
                            f"exit {r.returncode}; lock: {(doc / '.locks/Legacy_Doc-handoff').exists()}; "
                            f"invented: {(doc / 'legacy-doc-handoff.md').exists()}"))
    r = _handoff(target, "release", "Legacy_Doc", "--status", "done", "--verified-by", "grader")
    e.append(gc.expectation("a pre-slug doc still archives on done",
                            r.returncode == 0 and (doc / "archive/Legacy_Doc-handoff.md").is_file(),
                            f"exit {r.returncode}; archived: {(doc / 'archive/Legacy_Doc-handoff.md').is_file()}"))

    # --- template rendering must survive arbitrary --title/--note text ---------------------
    # These were rendered with `sed "s|PLACEHOLDER_NOTE|$note|"`, so a `|` in the value closed the
    # expression early. The redirect had already truncated the file, so the doc landed ZERO BYTES
    # while the command still reported success. `&` is the other trap: sed expands it to the match.
    _handoff(target, "new", "meta1", "--title", "Fix A & B", "--note", "a|b broke the render")
    m1 = doc / "meta1-handoff.md"
    e.append(gc.expectation("a '|' in --note does not produce an empty doc",
                            m1.is_file() and m1.stat().st_size > 0,
                            f"size: {m1.stat().st_size if m1.is_file() else 'absent'}"))
    e.append(gc.expectation("'|' and '&' survive verbatim into the frontmatter",
                            "note: a|b broke the render" in m1.read_text()
                            and "title: Fix A & B" in m1.read_text(),
                            f"frontmatter: {m1.read_text()[:160]!r}"))
    _handoff(target, "new", "meta2", "--standalone", "--title", "Ref | doc")
    _handoff(target, "new", "meta3", "--orchestrator", "--children", "meta1", "--title", "Bundle | x")
    e.append(gc.expectation("standalone and orchestrator templates render the same way",
                            (doc / "meta2-handoff.md").stat().st_size > 0
                            and "title: Ref | doc" in (doc / "meta2-handoff.md").read_text()
                            and (doc / "meta3-handoff.md").stat().st_size > 0
                            and "title: Bundle | x" in (doc / "meta3-handoff.md").read_text(),
                            f"standalone: {(doc / 'meta2-handoff.md').stat().st_size}; "
                            f"orchestrator: {(doc / 'meta3-handoff.md').stat().st_size}"))

    # --- --blocked-on is validated: an unclosable blocker deadlocks silently ---------------
    _handoff(target, "new", "bo1", "--title", "Blocked one")
    _handoff(target, "new", "bo2", "--title", "Blocked two")
    _handoff(target, "new", "boref", "--standalone", "--title", "Reference blocker")
    _handoff(target, "claim", "bo1")
    r = _handoff(target, "release", "bo1", "--status", "blocked", "--blocked-on", "no-such-thing")
    e.append(gc.expectation("blocked on a NONEXISTENT handoff is REFUSED (nothing would close it)",
                            r.returncode != 0 and "blocked_on:" not in (doc / "bo1-handoff.md").read_text(),
                            f"exit {r.returncode}: {r.stderr.strip()[:110]}"))
    r = _handoff(target, "release", "bo1", "--status", "blocked", "--blocked-on", "bo1")
    e.append(gc.expectation("blocked on ITSELF is REFUSED", r.returncode != 0,
                            f"exit {r.returncode}: {r.stderr.strip()[:110]}"))
    r = _handoff(target, "release", "bo1", "--status", "blocked", "--blocked-on", "external: vendor ticket")
    e.append(gc.expectation("an external: blocker is still accepted unvalidated",
                            r.returncode == 0 and "external: vendor ticket" in (doc / "bo1-handoff.md").read_text(),
                            f"exit {r.returncode}"))
    # a standalone doc IS a legal blocker, and retiring it must announce the dependent — the retire
    # path is newer than the unblock feature and originally skipped surface_unblocked entirely
    _handoff(target, "claim", "bo2")
    _handoff(target, "release", "bo2", "--status", "blocked", "--blocked-on", "boref")
    r = _handoff(target, "release", "boref", "--status", "done")
    e.append(gc.expectation("retiring a standalone SURFACES the handoff blocked on it",
                            r.returncode == 0 and "bo2-handoff" in r.stdout,
                            f"exit {r.returncode}; stdout: {r.stdout.strip()[:160]!r}"))

    # --- orchestrator: a bundle index whose progress is DERIVED, never stored -------------
    _handoff(target, "new", "kid-a", "--title", "Child A")
    _handoff(target, "new", "kid-b", "--title", "Child B")
    # third child is deliberately NOT filed — a bundle is often planned before every unit exists
    _handoff(target, "new", "bundle", "--orchestrator", "--children", "kid-a,kid-b,kid-c",
             "--title", "The bundle")
    orch = doc / "bundle-handoff.md"
    e.append(gc.expectation("new --orchestrator writes type + canonicalized children",
                            orch.is_file() and "type: orchestrator" in orch.read_text()
                            and "kid-a-handoff" in orch.read_text(),
                            f"exists: {orch.is_file()}"))
    r = _handoff(target, "claim", "bundle")
    e.append(gc.expectation("claim REFUSES an orchestrator (its children are the work)",
                            r.returncode != 0, f"exit {r.returncode}: {r.stderr.strip()[:80]}"))
    allow = _hook(target, "pretool-edit", {"tool_input": {"file_path": str(orch)}}, session="sess-ZZZ")
    e.append(gc.expectation("pretool gate ALLOWS editing an orchestrator with no lease",
                            allow == "", f"out: {allow[:120]!r}"))
    lst = _handoff(target, "list").stdout
    e.append(gc.expectation("list counts an unfiled child (MISSING), never as progress",
                            "0/3 done" in lst and "kid-c-handoff (MISSING)" in lst,
                            f"list: {lst[lst.find('Orchestrator'):][:220]!r}"))
    # INDEX.md is the generated board humans and AGENTS.md point at; it must agree with `list`.
    # An orchestrator leaking into the Open table reads as an unclaimed task with no lease.
    _handoff(target, "index")
    idx = (doc / "INDEX.md").read_text()
    open_table = idx.split("## Orchestrators")[0]
    e.append(gc.expectation("INDEX.md keeps orchestrators OUT of the Open work table",
                            "bundle-handoff.md" not in open_table,
                            f"open section: {open_table[open_table.find('## Open'):][:220]!r}"))
    e.append(gc.expectation("INDEX.md renders bundle progress derived from the children",
                            "## Orchestrators" in idx and "0/3 done" in idx
                            and "kid-c-handoff (MISSING)" in idx,
                            f"orch section: {idx[idx.find('## Orchestrators'):][:220]!r}"))
    r = _handoff(target, "release", "bundle", "--status", "done")
    e.append(gc.expectation("bundle done is REFUSED while children are outstanding",
                            r.returncode != 0 and not (doc / "archive/bundle-handoff.md").exists(),
                            f"exit {r.returncode}: {r.stderr.strip()[:100]}"))
    for kid in ("kid-a", "kid-b"):
        _handoff(target, "claim", kid)
        _handoff(target, "release", kid, "--status", "done", "--verified-by", "grader")
    _handoff(target, "new", "kid-c", "--title", "Child C")
    _handoff(target, "claim", "kid-c")
    _handoff(target, "release", "kid-c", "--status", "done", "--verified-by", "grader")
    lst = _handoff(target, "list").stdout
    e.append(gc.expectation("progress tracks children with no edit to the orchestrator doc",
                            "3/3 done" in lst, f"list: {lst[lst.find('Orchestrator'):][:200]!r}"))
    r = _handoff(target, "release", "bundle", "--status", "done")
    e.append(gc.expectation("bundle closes once every child is done",
                            r.returncode == 0 and (doc / "archive/bundle-handoff.md").is_file(),
                            f"exit {r.returncode}; archived: {(doc / 'archive/bundle-handoff.md').is_file()}"))
    return e


def grade_layout_migration(target):
    """A board installed FLAT (machinery beside the docs) must migrate to scripts/ + templates/.

    Installs, flattens the result back to the pre-restructure layout (including the old hook command
    path in settings.json), then re-installs and asserts the migration converged: machinery moved,
    nothing left at the root, hook commands rewritten, and — the real regression risk — no duplicated
    hook groups, since "handoff/scripts/hooks.sh" does not contain the old "handoff/hooks.sh" marker.
    """
    e = []
    hd = Path(target) / HD
    settings = Path(target) / CLAUDE_CFG

    _install(target, "--primary", "claude")

    # flatten it back to the old layout
    (hd / "scripts/hooks.sh").rename(hd / "hooks.sh")
    for tmpl in sorted((hd / "templates").glob("*.md")):  # every template, not a hardcoded pair
        tmpl.rename(hd / tmpl.name)
    (hd / "scripts").rmdir()
    (hd / "templates").rmdir()
    settings.write_text(settings.read_text().replace("handoff/scripts/hooks.sh", "handoff/hooks.sh"))
    e.append(gc.expectation("test setup: board is flat again before the migration run",
                            (hd / "hooks.sh").is_file() and not (hd / "scripts").exists(),
                            f"flat hooks.sh: {(hd / 'hooks.sh').is_file()}"))

    # re-install: this is the migration
    r = _install(target, "--primary", "claude")
    e.append(gc.expectation("installer succeeds on a flat board", r.returncode == 0,
                            f"exit {r.returncode}: {r.stderr.strip()[:120]}"))
    e.append(gc.expectation("hooks.sh moved into scripts/",
                            (hd / "scripts/hooks.sh").is_file() and not (hd / "hooks.sh").exists(),
                            f"scripts/hooks.sh: {(hd / 'scripts/hooks.sh').is_file()}; "
                            f"stale root copy: {(hd / 'hooks.sh').exists()}"))
    e.append(gc.expectation("templates moved into templates/",
                            (hd / "templates/handoff-doc-template.md").is_file()
                            and not (hd / "handoff-doc-template.md").exists(),
                            f"templates/: {(hd / 'templates/handoff-doc-template.md').is_file()}; "
                            f"stale root copy: {(hd / 'handoff-doc-template.md').exists()}"))
    e.append(gc.expectation("the handoff CLI stays at the board root", (hd / "handoff").is_file(),
                            f"handoff at root: {(hd / 'handoff').is_file()}"))

    cfg = json.loads(settings.read_text())
    cmds = [h.get("command", "") for groups in cfg.get("hooks", {}).values()
            for g in groups for h in g.get("hooks", [])]
    e.append(gc.expectation("every hook command points at the new scripts/hooks.sh path",
                            cmds and all("handoff/scripts/hooks.sh" in c for c in cmds),
                            f"commands: {cmds}"))
    e.append(gc.expectation("no duplicated hook groups (old marker was recognized as ours)",
                            len(cmds) == 4, f"{len(cmds)} hook entries: {cmds}"))

    # the migrated board must still WORK, not merely look right
    _handoff(target, "new", "post-migration", "--title", "After the move")
    doc = hd / "post-migration-handoff.md"
    e.append(gc.expectation("handoff new still scaffolds from the moved template",
                            doc.is_file() and "## Context" in doc.read_text(),
                            f"doc: {doc.is_file()}"))
    deny = _hook(target, "pretool-edit", {"tool_input": {"file_path": str(hd / "INDEX.md")}},
                 session="sess-ZZZ")
    e.append(gc.expectation("hooks.sh resolves the board root from scripts/ (gate still fires)",
                            '"permissionDecision": "deny"' in deny, f"out: {deny[:120]!r}"))
    e.append(gc.run_verify_script(VERIFY, target))
    return e


def grade_cross_repo(_target):
    """Two sibling repos sharing ONE parent board — the shared-board identity regression guard.

    Builds parent/{repo-a,repo-b} + a shared parent/handoff board, installs cross-repo in both, and
    asserts the shared board never bakes one repo's identity (the spec's install-A-then-B flip).
    Self-contained (ignores the passed fixture); cleans up its own temp tree.
    """
    import os
    import shutil
    import tempfile

    e = []
    parent = Path(tempfile.mkdtemp(prefix="handoff-xrepo-"))

    def sh(args, cwd, env_extra=None):
        return subprocess.run(args, cwd=str(cwd), capture_output=True, text=True,
                              env={**os.environ, **(env_extra or {})})

    try:
        board = parent / "handoff"
        repos = {}
        for name in ("repo-a", "repo-b"):
            r = parent / name
            r.mkdir()
            sh(["git", "init", "-q"], r)
            sh(["git", "config", "user.email", "t@t.t"], r)
            sh(["git", "config", "user.name", "t"], r)
            (r / "AGENTS.md").write_text("# AGENTS.md\n")
            sh(["git", "add", "-A"], r)
            sh(["git", "commit", "-qm", "init"], r)
            repos[name] = r

        def install(r):
            return sh(["bash", str(SETUP), str(r), "--tools", "claude", "--primary", "claude",
                       "--topology", "cross-repo", "--handoff-dir", "../handoff"], r)

        for name, r in repos.items():
            res = install(r)
            e.append(gc.expectation(f"installer succeeds cross-repo in {name}", res.returncode == 0,
                                    f"exit {res.returncode}: {res.stderr.strip()[:120]}"))

        cfg = (board / "config").read_text() if (board / "config").is_file() else ""
        e.append(gc.expectation("shared config omits REPO_NAME (no last-writer clobber)",
                                "REPO_NAME=" not in cfg and "TOPOLOGY=cross-repo" in cfg, f"config={cfg!r}"))

        for name, r in repos.items():
            s = (r / ".claude/settings.json").read_text()
            e.append(gc.expectation(f"{name} hook command carries its own HANDOFF_REPO={name}",
                                    f"HANDOFF_REPO={name} " in s, f"present: {('HANDOFF_REPO=' + name) in s}"))
            a = (r / "AGENTS.md").read_text()
            e.append(gc.expectation(f"{name} AGENTS.md advertises the shared path (../handoff), not .agents/handoff",
                                    "../handoff/handoff" in a and ".agents/handoff" not in a,
                                    f"xrepo path: {'../handoff/handoff' in a}; leaked default: {'.agents/handoff' in a}"))
            gi = (r / ".gitignore").read_text() if (r / ".gitignore").is_file() else ""
            e.append(gc.expectation(f"{name} .gitignore has no inert .locks/ entry",
                                    ".locks/" not in gi, f"gitignore={gi!r}"))

        # Re-run A: B's identity and the shared config must NOT flip (the exact spec repro).
        install(repos["repo-a"])
        s_b = (repos["repo-b"] / ".claude/settings.json").read_text()
        cfg2 = (board / "config").read_text()
        e.append(gc.expectation("re-installing repo-a leaves repo-b's identity intact",
                                "HANDOFF_REPO=repo-b " in s_b and "REPO_NAME=" not in cfg2,
                                f"b-intact: {'HANDOFF_REPO=repo-b ' in s_b}; cfg-neutral: {'REPO_NAME=' not in cfg2}"))

        # audience routing: sessionstart in repo-b surfaces only its own docs.
        ho, hk = board / "handoff", board / "scripts/hooks.sh"
        sh(["bash", str(ho), "new", "task-a", "--audience", "repo-a", "--title", "A task"], board, {"HANDOFF_REPO": "repo-a"})
        sh(["bash", str(ho), "new", "task-b", "--audience", "repo-b", "--title", "B task"], board, {"HANDOFF_REPO": "repo-b"})
        # simulate repo-b's baked hook command env (setup wires both HANDOFF_REPO + HANDOFF_HDPATH)
        ss = subprocess.run(["bash", str(hk), "--kind", "sessionstart", "--tool", "claude"],
                            cwd=str(repos["repo-b"]), input='{"session_id":"s"}',
                            capture_output=True, text=True,
                            env={**os.environ, "HANDOFF_REPO": "repo-b", "HANDOFF_HDPATH": "../handoff"}).stdout
        e.append(gc.expectation("sessionstart in repo-b surfaces only its own audience (routing works)",
                                "task-b" in ss and "task-a" not in ss, f"ss={ss[:160]!r}"))
        e.append(gc.expectation("sessionstart hint uses the shared board path, not .agents/handoff",
                                "../handoff/handoff claim" in ss and ".agents/handoff" not in ss,
                                f"xrepo hint: {'../handoff/handoff claim' in ss}"))

        # CLI guard: `new` on a shared board with no identity must refuse rather than default.
        r_noid = sh(["bash", str(ho), "new", "orphan", "--title", "no identity"], board)
        e.append(gc.expectation("cross-repo `new` without --audience/HANDOFF_REPO is refused",
                                r_noid.returncode != 0, f"exit {r_noid.returncode}: {r_noid.stderr.strip()[:100]}"))
        return e
    finally:
        shutil.rmtree(parent, ignore_errors=True)


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
        exps.append(gc.file_exists(target, f"{HD}/scripts/hooks.sh"))
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
        exps.append(gc.file_exists(target, f"{HD}/legacy-open-handoff.md"))
        exps.append(gc.file_exists(target, f"{HD}/archive/legacy-done-handoff.md"))
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

    if eval_id == "layout-migration":
        return grade_layout_migration(target)

    if eval_id == "cross-repo":
        return grade_cross_repo(target)

    return [gc.run_verify_script(VERIFY, target)]


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
