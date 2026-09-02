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
# The CLI's unresolvable-id error. Asserted both ways: it must still fire for an id that really
# does not exist, and must NOT fire for one that is only in another section of a grouped board.
NO_SUCH = "no such handoff"
CLAUDE_CFG = ".claude/settings.json"

# Legacy shell key -> camelCase JSON key. Mirrors the installer's own migration map; kept here
# rather than imported because the grader must be able to disagree with the code under test.
_LEGACY_KEYS = {"TOPOLOGY": "topology", "REPO_NAME": "repoName", "HANDOFF_GROUPS": "groups",
                "HANDOFF_GROUP_LAYOUT": "groupLayout", "HANDOFF_TTL_HOURS": "ttlHours",
                "HANDOFF_ALLOW_VERIFY_CMD": "allowVerifyCmd"}


def _read_shell_config(target):
    """Parse a legacy shell config into camelCase keys. Parsed, never sourced -- the grader must
    not execute a fixture's config any more than the shipped readers do."""
    path = Path(target) / HD / "config"
    out = {}
    if not path.is_file():
        return out
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        if key.strip() in _LEGACY_KEYS:
            out[_LEGACY_KEYS[key.strip()]] = val.strip().strip('"').strip("'")
    return out


def _board_json(board):
    """One board's JSON config, or {} when absent/unparseable.

    Every layer was consolidated onto `handoff.json`; `config.json` is the generation before it.
    Both are read, newest last, so a run against an older fixture still says something true.
    Callers must assert on the VALUES: a bare {} is indistinguishable from a correctly-configured
    board, which is exactly how the assertions below went on "passing" against an empty dict for a
    whole release after the rename.
    """
    cfg = {}
    for name in ("config.json", "handoff.json"):
        try:
            data = json.loads((Path(board) / name).read_text())
        except (OSError, ValueError):
            continue
        if isinstance(data, dict):
            cfg.update(data)
    return cfg


def _repo_json(repo):
    """A member repo's own handoff config (the `group` it resolves to), pre-consolidation name
    accepted as a fallback."""
    for name in ("handoff.config.json", "handoff.json"):
        try:
            data = json.loads((Path(repo) / ".agents" / name).read_text())
        except (OSError, ValueError):
            continue
        if isinstance(data, dict):
            return data
    return {}


def _read_json_config(target):
    """The board config for a single-repo target at <target>/.agents/handoff."""
    return _board_json(Path(target) / HD)


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


def _fm_colon_offenders(path):
    """Frontmatter lines whose unquoted value carries a bare ':' — i.e. invalid YAML.

    The CLI writes every frontmatter value unquoted (`key: value`), so a ':' inside a value
    reopens the line as a nested mapping and every parser that reads the doc rejects it —
    markdown preview included. There is no yaml module here (the harness is dependency-free
    by design), so match the shape the CLI can actually emit instead of parsing.
    """
    text = path.read_text()
    if not text.startswith("---\n"):
        return []
    bad = []
    for line in text.split("\n---", 1)[0].splitlines()[1:]:
        if ":" not in line:
            continue
        val = line.split(":", 1)[1].strip()
        if val[:1] in ("'", '"', "[", "{"):  # quoted or a flow collection — parses fine
            continue
        if ":" in val:
            bad.append(f"{path.name}: {line}")
    return bad


def grade_script_behavior(target):
    e = []
    doc = Path(target) / HD

    _handoff(target, "new", "bt", "--title", "Backend task")
    e.append(gc.expectation("handoff new creates a doc", (doc / "bt-handoff.md").is_file(),
                            f"bt-handoff.md exists: {(doc / 'bt-handoff.md').is_file()}"))

    # The grouped-board scope notice must stay invisible on a FLAT board: it keys off
    # board_is_grouped(), so a plain single-repo board has to behave exactly as it did before.
    r = _handoff(target, "list")
    e.append(gc.expectation("flat board list stays silent on stderr (no section notice)",
                            r.stderr.strip() == "", f"stderr: {r.stderr.strip()[:120]!r}"))
    r = _handoff(target, "claim", "ghost-id", "x")
    e.append(gc.expectation("flat board still reports an unknown id as no such handoff",
                            NO_SUCH in r.stderr, f"stderr: {r.stderr.strip()[:120]!r}"))

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
    # (printing the command text must NOT count as running it). It is QUOTED and carries a ':',
    # like any real command: unquoted it would break the doc's YAML, and quoting only works
    # because meta() strips one surrounding pair.
    vt = doc / "vt-handoff.md"
    marker = Path(target) / "VERIFY_RAN"
    cmd = f"""sh -c 'echo ran: yes > {marker}'"""
    txt = vt.read_text().replace("status: open", f'status: open\nverify: "{cmd}"', 1)
    vt.write_text(txt)
    _handoff(target, "claim", "vt")
    r = _handoff(target, "release", "vt", "--status", "done", "--verified-by", "z", "--run-verify")
    e.append(gc.expectation("verify: command is NOT auto-run without the install opt-in",
                            not marker.exists(),
                            f"marker present: {marker.exists()}; stdout: {r.stdout.strip()[:100]!r}"))

    # ...and WITH the opt-in it runs — the path that proves a quoted command survives to the shell.
    # Before meta() stripped quotes, this failed with "command not found: \"sh -c '...'\"", so a
    # command could be valid YAML or runnable but never both.
    # The doc is left exactly as `new` writes it, `repos: []` included: that empty list is what
    # doc_is_local() used to read as "belongs to another repo", making --run-verify unreachable
    # for every doc the CLI creates.
    # The opt-in moved from an appended shell line to a JSON key when the board's config became
    # config.json. Written through json so the file stays parseable — the readers now REFUSE a
    # malformed config rather than silently falling back, so a hand-appended line would not just
    # be ignored here, it would fail the whole board.
    _cfg_path = Path(target) / ".agents/handoff/handoff.json"
    _cfg = json.loads(_cfg_path.read_text())
    _cfg["allowVerifyCmd"] = True
    _cfg_path.write_text(json.dumps(_cfg, indent=2, sort_keys=True) + "\n")
    _handoff(target, "new", "vr", "--title", "Verify runs")
    vr = doc / "vr-handoff.md"
    marker2 = Path(target) / "VERIFY_RAN_OPTIN"
    cmd2 = f"""sh -c 'echo ran: yes > {marker2}'"""
    vr.write_text(vr.read_text().replace("status: open", f'status: open\nverify: "{cmd2}"', 1))
    e.append(gc.expectation("test setup: the doc carries the template's default empty repos list",
                            "repos: []" in vr.read_text(),
                            f"repos line: {[ln for ln in vr.read_text().splitlines() if ln.startswith('repos')]}"))
    _handoff(target, "claim", "vr")
    r = _handoff(target, "release", "vr", "--status", "done", "--verified-by", "z",
                 "--run-verify", allow_verify=True)
    e.append(gc.expectation("a QUOTED verify: command runs verbatim under the opt-in (quotes stripped)",
                            r.returncode == 0 and marker2.is_file()
                            and marker2.read_text().strip() == "ran: yes",
                            f"exit {r.returncode}; marker: {marker2.is_file()}; "
                            f"stdout: {r.stdout.strip()[:100]!r}; stderr: {r.stderr.strip()[:100]!r}"))
    e.append(gc.expectation("the verify: run is recorded in verified_by",
                            "[verify: exit 0]" in r.stdout, f"stdout: {r.stdout.strip()[:140]!r}"))

    # The gate is a security boundary: a doc scoped to OTHER repos is untrusted and must never
    # auto-execute. Block-list syntax is the case that used to fail OPEN — meta() only reads the
    # key's own line, so `repos:` followed by `- other-repo` looked like "unset", i.e. local.
    for hid, repos_yaml, label in (("vf", "repos: [some-other-repo]", "flow list"),
                                   ("vb", "repos:\n  - some-other-repo", "block list")):
        _handoff(target, "new", hid, "--title", f"Foreign {label}")
        fdoc = doc / f"{hid}-handoff.md"
        fmark = Path(target) / f"VERIFY_FOREIGN_{hid}"
        fcmd = f"""sh -c 'echo ran > {fmark}'"""
        fdoc.write_text(fdoc.read_text()
                        .replace("repos: []", repos_yaml, 1)
                        .replace("status: open", f'status: open\nverify: "{fcmd}"', 1))
        _handoff(target, "claim", hid)
        r = _handoff(target, "release", hid, "--status", "done", "--verified-by", "z",
                     "--run-verify", allow_verify=True)
        e.append(gc.expectation(f"verify: is REFUSED for a doc scoped to another repo ({label})",
                                not fmark.exists() and "was NOT run" in r.stdout,
                                f"marker present: {fmark.exists()}; stdout: {r.stdout.strip()[:120]!r}"))

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

    # --- an unresolvable id must HARD-fail, never half-succeed ------------------------------
    # claim/release resolve the doc inside $( ), where `die` exits only the SUBSHELL; with no
    # `set -e` the command used to sail on with an empty path — minting a lease for a doc that does
    # not exist and spraying `sed: : No such file or directory`, while still exiting 0. The `-handoff`
    # suffix fold makes this easy to hit: `rbac` -> phantom `rbac-handoff`, real doc `rbac-gap-handoff`.
    locks = doc / ".locks"
    before = sorted(p.name for p in locks.glob("*")) if locks.is_dir() else []
    r = _handoff(target, "claim", "rbac", "short id that folds to a phantom")
    out = r.stdout + r.stderr
    after = sorted(p.name for p in locks.glob("*")) if locks.is_dir() else []
    e.append(gc.expectation("claim on an unresolvable id exits NONZERO",
                            r.returncode != 0, f"exit {r.returncode}: {out.strip()[:120]}"))
    e.append(gc.expectation("claim on an unresolvable id mints NO lease",
                            after == before, f"locks before={before} after={after}"))
    e.append(gc.expectation("claim on an unresolvable id emits no sed/grep error spew",
                            "No such file or directory" not in out, f"out: {out.strip()[:160]}"))
    e.append(gc.expectation("an unresolvable id names its near miss on the board",
                            "rbac-gap-handoff" in out, f"out: {out.strip()[:160]}"))
    doc_before = slug.read_text()
    r = _handoff(target, "release", "rbac", "--status", "done", "--verified-by", "grader")
    out = r.stdout + r.stderr
    e.append(gc.expectation("release on an unresolvable id exits NONZERO and mutates nothing",
                            r.returncode != 0 and slug.read_text() == doc_before
                            and "No such file or directory" not in out,
                            f"exit {r.returncode}; real doc changed: {slug.read_text() != doc_before}; "
                            f"out: {out.strip()[:120]}"))

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

    # --- titles are colon-free: `title:` is unquoted YAML, so a ':' in the value breaks -----
    # every frontmatter parser that reads the doc (markdown preview included)
    _handoff(target, "new", "ct", "--title", "Handoff: colon title")
    ct = (doc / "ct-handoff.md").read_text()
    e.append(gc.expectation("a ':' in --title is folded to an em dash (YAML-safe frontmatter)",
                            "title: Handoff — colon title" in ct and "title: Handoff:" not in ct,
                            f"frontmatter: {ct[:120]!r}"))
    src_colon = Path(target) / "IMPORT_COLON.md"
    src_colon.write_text("# Guide: ports\n\nbody\n")
    _handoff(target, "import", str(src_colon), "--id", "colon-import", "--standalone")
    ci = (doc / "colon-import-handoff.md").read_text()
    e.append(gc.expectation("import folds a ':' in the H1-derived title too",
                            "title: Guide — ports" in ci, f"frontmatter: {ci[:120]!r}"))
    # `note:` is the other free-text value new/import write into frontmatter unquoted
    _handoff(target, "new", "cn", "--title", "Colon note", "--note", "see: foo")
    cn = (doc / "cn-handoff.md").read_text()
    e.append(gc.expectation("a ':' in --note is folded to an em dash",
                            "note: see — foo" in cn and "note: see:" not in cn,
                            f"frontmatter: {cn[:160]!r}"))

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
    # "external: ..." stays the documented spelling to TYPE — but it lands in frontmatter as
    # unquoted YAML, so the value is folded on the way in and stored as "external — ...".
    r = _handoff(target, "release", "bo1", "--status", "blocked", "--blocked-on", "external: vendor ticket")
    e.append(gc.expectation("an external: blocker is still accepted unvalidated, stored colon-free",
                            r.returncode == 0
                            and "blocked_on: external — vendor ticket" in (doc / "bo1-handoff.md").read_text(),
                            f"exit {r.returncode}"))
    _handoff(target, "claim", "bo1")
    r = _handoff(target, "release", "bo1", "--status", "blocked", "--blocked-on", "external — em dash blocker")
    e.append(gc.expectation("the already-folded em-dash spelling of an external blocker is accepted too",
                            r.returncode == 0
                            and "blocked_on: external — em dash blocker" in (doc / "bo1-handoff.md").read_text(),
                            f"exit {r.returncode}: {r.stderr.strip()[:110]}"))
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

    # --- release drops the lease on EVERY exit path --------------------------------------
    # `claim` refuses standalone and orchestrator docs, so the only way a lease lands on one is
    # reclassifying a doc claimed while it was still coordination — retiring a work item into a
    # reference doc, or promoting it into a bundle index. Both branches of cmd_release `return`
    # early and used to return BEFORE the clear_lock at the function's end, so the lease survived
    # until the TTL reap, clearable by neither `release` (it will not) nor `claim` (it refuses the
    # doc), and the board read as work-in-progress for hours.
    def _retype(hid, new_type, extra_fm=()):
        p = doc / f"{hid}-handoff.md"
        out, done = [], False
        for ln in p.read_text().splitlines():
            if not done and ln.startswith("type: "):
                out.append(f"type: {new_type}")
                out.extend(extra_fm)
                done = True
            else:
                out.append(ln)
        p.write_text("\n".join(out) + "\n")

    for hid, new_type, status, extra_fm in (
        ("conv-ref", "standalone", "open", ()),
        ("conv-retire", "standalone", "done", ()),
        ("conv-bundle", "orchestrator", "open", ("children: [kid-a-handoff]",)),
        ("conv-bundle-done", "orchestrator", "done", ("children: [kid-a-handoff]",)),
    ):
        _handoff(target, "new", hid, "--title", f"Converted to {new_type}")
        _handoff(target, "claim", hid, "claimed while still coordination")
        _retype(hid, new_type, extra_fm)
        r = _handoff(target, "release", hid, "--status", status)
        lock = doc / f".locks/{hid}-handoff"
        e.append(gc.expectation(
            f"release --status {status} on a {new_type} doc clears the lease it still held",
            r.returncode == 0 and not lock.exists(),
            f"exit {r.returncode}; lock present: {lock.exists()}; err: {r.stderr.strip()[:80]!r}"))

    # The regression the fix must not cause: the coordination path already cleared its lease, and
    # every status has to keep doing so.
    _handoff(target, "new", "lease-blk", "--title", "Blocker for the lease sweep")
    for hid, args in (
        ("lease-open", ("--status", "open")),
        ("lease-blocked", ("--status", "blocked", "--blocked-on", "lease-blk")),
        ("lease-done", ("--status", "done", "--verified-by", "grader read the live code")),
    ):
        _handoff(target, "new", hid, "--title", "Coordination work")
        _handoff(target, "claim", hid)
        r = _handoff(target, "release", hid, *args)
        lock = doc / f".locks/{hid}-handoff"
        e.append(gc.expectation(
            f"coordination release {args[1]} still clears its lease",
            r.returncode == 0 and not lock.exists(),
            f"exit {r.returncode}; lock present: {lock.exists()}; err: {r.stderr.strip()[:80]!r}"))

    # Catch-all over everything this suite produced: no field-by-field expectation can cover a
    # value the CLI learns to write later, and one bad line breaks the whole doc for every parser.
    offenders = sorted(o for p in [*doc.glob("*-handoff.md"), *(doc / "archive").glob("*-handoff.md")]
                       for o in _fm_colon_offenders(p))
    e.append(gc.expectation("every doc this suite wrote has YAML-safe frontmatter (no bare ':' in a value)",
                            not offenders, f"offenders: {offenders[:3]}"))
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

    # flatten it back to the old layout. config.sh is NOT part of the flat/scripts migration
    # (it didn't exist pre-restructure and always installs to scripts/), so scripts/ keeps it
    # and stays non-empty — only hooks.sh moves back to the board root.
    (hd / "scripts/hooks.sh").rename(hd / "hooks.sh")
    for tmpl in sorted((hd / "templates").glob("*.md")):  # every template, not a hardcoded pair
        tmpl.rename(hd / tmpl.name)
    (hd / "templates").rmdir()
    settings.write_text(settings.read_text().replace("handoff/scripts/hooks.sh", "handoff/hooks.sh"))
    e.append(gc.expectation("test setup: board is flat again before the migration run",
                            (hd / "hooks.sh").is_file() and not (hd / "scripts/hooks.sh").exists(),
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

        cfg = _board_json(board)
        e.append(gc.expectation("shared config omits repoName (no last-writer clobber)",
                                "repoName" not in cfg and cfg.get("topology") == "cross-repo", f"config={cfg!r}"))

        for name, r in repos.items():
            rc_path = r / ".agents/handoff.json"
            rc = json.loads(rc_path.read_text()) if rc_path.is_file() else {}
            e.append(gc.expectation(f"{name} repo config records its own identity",
                                    rc.get("repo") == name, f"repo config={rc!r}"))
            s = (r / ".claude/settings.json").read_text()
            e.append(gc.expectation(f"{name} hook command carries a --project-dir anchor, not a baked identity",
                                    "--project-dir" in s and f"HANDOFF_REPO={name}" not in s,
                                    f"--project-dir present: {'--project-dir' in s}; no baked identity: {(f'HANDOFF_REPO={name}') not in s}"))
            a = (r / "AGENTS.md").read_text()
            e.append(gc.expectation(f"{name} AGENTS.md advertises the shared path (../handoff), not .agents/handoff",
                                    "../handoff/handoff" in a and ".agents/handoff" not in a,
                                    f"xrepo path: {'../handoff/handoff' in a}; leaked default: {'.agents/handoff' in a}"))
            gi = (r / ".gitignore").read_text() if (r / ".gitignore").is_file() else ""
            e.append(gc.expectation(f"{name} .gitignore has no inert .locks/ entry",
                                    ".locks/" not in gi, f"gitignore={gi!r}"))

        # Re-run A: B's identity and the shared config must NOT flip (the exact spec repro).
        install(repos["repo-a"])
        # Through the resolver, not a bare read_text(): the pre-consolidation filename made this
        # line raise FileNotFoundError and take the WHOLE cross-repo eval down — no grading.json
        # was produced at all, so the case read as "not run" rather than "failing".
        rc_b = _repo_json(repos["repo-b"])
        cfg2 = _board_json(board)
        e.append(gc.expectation("re-installing repo-a leaves repo-b's identity intact",
                                rc_b.get("repo") == "repo-b" and "repoName" not in cfg2,
                                f"b-intact repo config: {rc_b!r}; cfg-neutral: {'repoName' not in cfg2}"))

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


def _scope_notice_expectations(sh, ho, board, tag):
    """A sectioned board must never read as an empty board, nor report a real id as unknown just
    because it sits in another section. This is the reachable path, not a corner one: the AGENTS.md
    block's own documented commands are typed by hand and inherit no HANDOFF_GROUP (only the tool
    hooks carry it), which is how a member repo came to read its own board as empty. Assumes the
    grouped-board scaffold, where `node-drain` exists only in the infra section."""
    e = []
    noscope = {"HANDOFF_REPO": "auth", "HANDOFF_GROUP": ""}
    inscope = {"HANDOFF_REPO": "auth", "HANDOFF_GROUP": "auth"}

    r = sh(["bash", str(ho), "list"], board, noscope)
    e.append(gc.expectation(f"{tag} list with no group in scope warns instead of looking empty",
                            "no HANDOFF_GROUP is set" in r.stderr,
                            f"stderr: {r.stderr.strip()[:160]!r}"))
    e.append(gc.expectation(f"{tag} that warning is on stderr, leaving stdout the plain table",
                            "HANDOFF_GROUP" not in r.stdout and r.stdout.startswith("ID"),
                            f"stdout head: {r.stdout[:60]!r}"))
    r = sh(["bash", str(ho), "list"], board, inscope)
    e.append(gc.expectation(f"{tag} no warning when a section IS in scope",
                            r.stderr.strip() == "", f"stderr: {r.stderr.strip()[:120]!r}"))

    # "no such handoff" for a doc that is merely in another section is actively wrong — the id is
    # real, and that message sends the reader to `list`, which is empty/foreign for the same reason.
    r = sh(["bash", str(ho), "claim", "node-drain", "x"], board, inscope)
    named = "infra section" in r.stderr and NO_SUCH not in r.stderr
    e.append(gc.expectation(f"{tag} claim on another section's id names that section",
                            r.returncode != 0 and named, f"stderr: {r.stderr.strip()[:160]!r}"))
    r = sh(["bash", str(ho), "claim", "node-drain", "x"], board, noscope)
    e.append(gc.expectation(f"{tag} claim with no group in scope names the section too",
                            r.returncode != 0 and "infra section" in r.stderr,
                            f"stderr: {r.stderr.strip()[:160]!r}"))
    r = sh(["bash", str(ho), "claim", "totally-made-up", "x"], board, inscope)
    e.append(gc.expectation(f"{tag} a genuinely unknown id still reports no such handoff",
                            NO_SUCH in r.stderr, f"stderr: {r.stderr.strip()[:120]!r}"))
    return e


def grade_grouped_board(_target):
    """A multi-group board: two groups co-located as sub-indexed sections + id collisions across
    groups, exercised under BOTH subfolder and prefix layouts. Self-contained (ignores the passed
    fixture); scaffolds boards with `setup-handoff.sh --board-only` and drives the `handoff` CLI +
    hooks.sh directly. Proves the section layer: doc placement, sub-index + roll-up generation,
    section-scoped `list`, collision-free leases, and the section-scoped edit gate."""
    import os
    import shutil
    import tempfile

    e = []
    base = Path(tempfile.mkdtemp(prefix="handoff-grouped-"))

    def sh(args, cwd, env_extra=None):
        return subprocess.run(args, cwd=str(cwd), capture_output=True, text=True,
                              env={**os.environ, **(env_extra or {})})

    try:
        for layout in ("subfolder", "prefix"):
            tag = f"[{layout}]"
            board = base / layout
            r = sh(["bash", str(SETUP), "--board-only", str(board),
                    "--groups", "auth,infra", "--layout", layout], base)
            e.append(gc.expectation(f"{tag} --board-only scaffolds a standalone board", r.returncode == 0,
                                    f"exit {r.returncode}: {r.stderr.strip()[:100]}"))
            cfg = _board_json(board)
            e.append(gc.expectation(f"{tag} board config records groups + layout",
                                    cfg.get("groups") == ["auth", "infra"] and cfg.get("groupLayout") == layout,
                                    f"config={cfg!r}"))
            ho = board / "handoff"

            def newdoc(group, hid, title):
                return sh(["bash", str(ho), "new", hid, "--title", title],
                          board, {"HANDOFF_REPO": group, "HANDOFF_GROUP": group})

            newdoc("auth", "login-fix", "Login fix")
            newdoc("infra", "node-drain", "Node drain")
            newdoc("infra", "login-fix", "Infra login fix")  # same id, different group — must not clash

            if layout == "subfolder":
                auth_doc = board / "auth" / "login-fix-handoff.md"
                infra_doc = board / "infra" / "login-fix-handoff.md"
                auth_idx = board / "auth" / "INDEX.md"
            else:
                auth_doc = board / "auth--login-fix-handoff.md"
                infra_doc = board / "infra--login-fix-handoff.md"
                auth_idx = board / "INDEX-auth.md"
            e.append(gc.expectation(f"{tag} same id in two groups yields two distinct docs (no clash)",
                                    auth_doc.is_file() and infra_doc.is_file(),
                                    f"auth: {auth_doc.is_file()}, infra: {infra_doc.is_file()}"))
            e.append(gc.expectation(f"{tag} each group gets its own sub-index", auth_idx.is_file(),
                                    f"auth sub-index: {auth_idx.is_file()}"))
            rollup = (board / "INDEX.md").read_text() if (board / "INDEX.md").is_file() else ""
            e.append(gc.expectation(f"{tag} board roll-up lists both group sections",
                                    "## auth" in rollup and "## infra" in rollup,
                                    f"headings: {[l for l in rollup.splitlines() if l.startswith('## ')]}"))

            # section-scoped list: auth sees only its own section
            auth_list = sh(["bash", str(ho), "list"], board, {"HANDOFF_REPO": "auth", "HANDOFF_GROUP": "auth"}).stdout
            e.append(gc.expectation(f"{tag} list from auth shows only the auth section",
                                    "login-fix" in auth_list and "node-drain" not in auth_list,
                                    f"list: {auth_list[:200]!r}"))

            # section-scoped edit gate: claim in auth, then a stranger session is denied editing auth's doc
            sh(["bash", str(ho), "claim", "login-fix", "mine"], board,
               {"HANDOFF_REPO": "auth", "HANDOFF_GROUP": "auth", "HANDOFF_SESSION_ID": "owner"})
            hk = board / "scripts/hooks.sh"
            deny = subprocess.run(["bash", str(hk), "--kind", "pretool-edit", "--tool", "claude"],
                                  cwd=str(board), input=json.dumps({"session_id": "stranger",
                                  "tool_input": {"file_path": str(auth_doc)}}),
                                  capture_output=True, text=True,
                                  env={**os.environ, "HANDOFF_REPO": "auth", "HANDOFF_GROUP": "auth"}).stdout
            e.append(gc.expectation(f"{tag} the edit gate denies a stranger editing a claimed section doc",
                                    '"permissionDecision": "deny"' in deny, f"out: {deny[:120]!r}"))

            # --blocked-on must resolve within the SECTION. Validating against the board root (which
            # holds no docs under either layout) rejected every blocker, making `blocked` unreachable
            # on a grouped board and pushing everyone onto the "external:" escape hatch, which opts
            # out of the unblock notification entirely.
            newdoc("auth", "blk", "Blocker")
            newdoc("auth", "dep", "Dependent")
            newdoc("infra", "otherblk", "Other-section blocker")
            aenv = {"HANDOFF_REPO": "auth", "HANDOFF_GROUP": "auth"}
            r = sh(["bash", str(ho), "release", "dep", "--status", "blocked", "--blocked-on", "blk"], board, aenv)
            e.append(gc.expectation(f"{tag} --blocked-on resolves a blocker inside the section",
                                    r.returncode == 0, f"exit {r.returncode}: {r.stderr.strip()[:120]}"))
            r = sh(["bash", str(ho), "release", "dep", "--status", "blocked", "--blocked-on", "nope-not-real"], board, aenv)
            e.append(gc.expectation(f"{tag} --blocked-on still refuses a blocker that does not exist",
                                    r.returncode != 0, f"exit {r.returncode}"))
            r = sh(["bash", str(ho), "release", "dep", "--status", "blocked", "--blocked-on", "otherblk"], board, aenv)
            e.append(gc.expectation(f"{tag} --blocked-on refuses a blocker in another section",
                                    r.returncode != 0, f"exit {r.returncode}"))
            r = sh(["bash", str(ho), "release", "blk", "--status", "done", "--verified-by", "grader"], board, aenv)
            e.append(gc.expectation(f"{tag} closing the blocker surfaces the dependent as unblocked",
                                    "Now unblocked" in r.stdout, f"out: {r.stdout[-160:]!r}"))

            e.extend(_scope_notice_expectations(sh, ho, board, tag))
        return e
    finally:
        shutil.rmtree(base, ignore_errors=True)


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

    if eval_id == "legacy-config":
        # A board still on the sourced shell `config`, with no JSON config at all. The installer
        # must migrate it, and every value must survive: the migration is worthless if it produces
        # a well-formed file with the wrong numbers in it. ttlHours is the one that proves it,
        # because the installer's own default (4) differs from the fixture's (8) -- so a value
        # that survives cannot have come from the default path.
        before = _read_shell_config(target)
        r = _install(target, "--primary", "claude")
        exps = [gc.expectation("installer succeeds on a legacy-config board", r.returncode == 0,
                               f"exit {r.returncode}: {r.stderr.strip()[:120]}")]
        exps.append(gc.run_verify_script(VERIFY, target))
        exps.append(gc.file_exists(target, f"{HD}/handoff.json"))
        exps.append(gc.json_roundtrip(target, f"{HD}/handoff.json"))
        after = _read_json_config(target)
        for key, want in (("ttlHours", before.get("ttlHours")), ("topology", before.get("topology"))):
            if want is None:
                continue
            exps.append(gc.expectation(
                f"{key} survived the shell-to-JSON migration",
                str(after.get(key)) == str(want),
                f"legacy {key}={want!r} -> json {key}={after.get(key)!r}"))
        # The legacy file is SUPERSEDED, not deleted: renamed to `config.superseded` so it can
        # never be read as authoritative again while still being there to recover from if the
        # migration got a value wrong. Asserting both halves — the rename happened AND nothing was
        # destroyed — is the whole claim; asserting only that `config` still exists (what this
        # used to do) now passes exactly when the migration has NOT run.
        exps.append(gc.file_exists(target, f"{HD}/config.superseded"))
        exps.append(gc.expectation(
            "the superseded legacy config is no longer readable as authoritative",
            not (Path(target) / HD / "config").exists(),
            f"{HD}/config present: {(Path(target) / HD / 'config').exists()}"))
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

    if eval_id == "grouped-board":
        return grade_grouped_board(target)

    return [gc.run_verify_script(VERIFY, target)]


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
