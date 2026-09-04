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
import os
import shutil
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
# setup-graph-hooks' installer, used by the custom-board-name case as the NEGATIVE half: it writes
# `--kind` hook commands into the very config files check_tool reads, so it is the realistic thing
# a widened pattern would wrongly claim as handoff wiring. Driving the real installer rather than a
# hand-written copy of its command shape is deliberate -- an inline copy would go stale silently and
# the guard would pass while no longer guarding anything.
GRAPH_SETUP = REPO / "skills/engineering/setup-graph-hooks/scripts/setup-graph-hooks.sh"

HD = ".agents/handoff"
# The CLI's unresolvable-id error. Asserted both ways: it must still fire for an id that really
# does not exist, and must NOT fire for one that is only in another section of a grouped board.
NO_SUCH = "no such handoff"
CLAUDE_CFG = ".claude/settings.json"

# Fixture boards carry no CLI copy of their own. <board>/handoff is a small dispatcher that execs
# the CLI named by $HANDOFF_BIN (then a user-level install, then a vendored copy), so pointing it
# at the skill's payload here is what puts the binary under test in front of every fixture. Without
# it this workspace graded whatever `handoff` happened to be installed on the machine running it —
# a green run proved the MACHINE was current, not the payload. The other three handoff workspaces
# already pinned it; this one was missed. Set once, for every subprocess this grader spawns.
os.environ.setdefault("HANDOFF_BIN", str(gc.payload_cli(HERE)))

# Legacy shell key -> camelCase JSON key. Mirrors the installer's own migration map; kept here
# rather than imported because the grader must be able to disagree with the code under test.
_LEGACY_KEYS = {
    "TOPOLOGY": "topology",
    "REPO_NAME": "repoName",
    "HANDOFF_GROUPS": "groups",
    "HANDOFF_GROUP_LAYOUT": "groupLayout",
    "HANDOFF_TTL_HOURS": "ttlHours",
    "HANDOFF_ALLOW_VERIFY_CMD": "allowVerifyCmd",
}


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
    # A None VALUE means UNSET, not "empty string". The CLI-resolution cases have to run with
    # $HANDOFF_BIN genuinely absent, and this module sets it for every other case — an empty
    # string would still be a set variable and the ladder would read it as a rung.
    env = {k: v for k, v in env.items() if v is not None}
    return subprocess.run(args, cwd=str(cwd), capture_output=True, text=True, env=env)


def _install(target, *extra):
    return _run(["bash", str(SETUP), str(target), "--tools", "claude", *extra], target)


def _handoff(target, *args, session="sess-AAA", allow_verify=False):
    ho = Path(target) / HD / "handoff"
    env = {"HANDOFF_SESSION_ID": session}
    if allow_verify:
        env["HANDOFF_ALLOW_VERIFY_CMD"] = "1"
    return _run(["bash", str(ho), *args], target, env)


def _resolved_cli(target) -> Path | None:
    """The CLI file <board>/handoff actually execs.

    The board root holds a dispatcher now, not the CLI, so a static assertion about CLI content
    has to follow the same ladder the dispatcher does ($HANDOFF_BIN, user-level install, vendored
    copy) rather than grepping the entry point. `--which` reports it; a pre-split board that does
    not know the flag falls back to the root file, which on such a board IS the CLI.
    """
    r = _run(["bash", str(Path(target) / HD / "handoff"), "--which"], target)
    for line in r.stdout.splitlines():
        if line.startswith("CLI"):
            cand = Path(line.split(None, 1)[1].strip())
            return cand if cand.is_file() else None
    root = Path(target) / HD / "handoff"
    return root if root.is_file() else None


def _hook(target, kind, payload, session="sess-AAA", env_extra=None):
    # hooks.sh lives under scripts/; fall back to the flat path for a pre-restructure board. Raise
    # rather than returning "" when neither exists: empty output means ALLOW, so a missing hooks.sh
    # would make every gate assertion pass vacuously.
    hk = Path(target) / HD / "scripts/hooks.sh"
    if not hk.is_file():
        hk = Path(target) / HD / "hooks.sh"
    if not hk.is_file():
        raise FileNotFoundError(f"hooks.sh not found under {Path(target) / HD}")
    env = {**os.environ, **(env_extra or {})}
    env = {k: v for k, v in env.items() if v is not None}
    p = subprocess.run(
        ["bash", str(hk), "--kind", kind, "--tool", "claude"],
        cwd=str(target),
        input=json.dumps({"session_id": session, **payload}),
        capture_output=True,
        text=True,
        env=env,
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


def grade_schema_forward(target):
    """Read a NEWER document, refuse to WRITE it (ADR 0003).

    These are one decision, so they are asserted together. Warn-and-proceed covers reading and
    says nothing about writing, which means an older CLI could read a schema-99 doc, release it,
    and silently drop every field it did not understand — shipping only the read half is worse
    than shipping neither. The doc here is stamped by hand at a schema no CLI will ever reach,
    which is what a member repo sees the day a teammate's board upgrades first.
    """
    e = []
    doc = Path(target) / HD

    _handoff(target, "new", "future", "--title", "Written by a newer CLI")
    _handoff(target, "new", "ordinary", "--title", "An ordinary doc")
    fut = doc / "future-handoff.md"
    text = fut.read_text(encoding="utf-8").replace("schema: 1", "schema: 99", 1)
    # A key this CLI has never heard of, to prove nothing quietly eats it on the way through.
    fut.write_text(
        text.replace("status: open", "status: open\nquantum_flux: 7", 1),
        encoding="utf-8",
    )

    listing = _handoff(target, "list")
    out = listing.stdout + listing.stderr
    e.append(
        gc.expectation(
            "a newer doc is still LISTED, not hidden",
            "future-handoff" in out,
            f"listed: {'future-handoff' in out}",
        )
    )
    e.append(
        gc.expectation(
            "with one warning naming BOTH versions",
            "is schema 99" in out and "understands 1" in out,
            f"warning: {'is schema 99' in out}",
        )
    )
    e.append(
        gc.expectation(
            "printed once, not once per doc — a wall of them teaches people to scroll",
            out.count("this CLI understands") == 1,
            f"occurrences: {out.count('this CLI understands')}",
        )
    )

    # Every mutating command. `export` is the one that used to slip through: it stamps the doc,
    # so a missing gate there is a silent write to a document this CLI cannot represent.
    for cmd, args in (
        ("claim", ("future", "try")),
        ("release", ("future", "--status", "open")),
        ("export", ("future", "--to", "Someone")),
    ):
        r = _handoff(target, cmd, *args)
        e.append(
            gc.expectation(
                f"{cmd} on a newer doc is REFUSED",
                r.returncode != 0 and "refusing to write it" in (r.stdout + r.stderr),
                f"exit {r.returncode}: {(r.stdout + r.stderr).strip()[-120:]}",
            )
        )

    e.append(
        gc.expectation(
            "the unknown field was never touched",
            "quantum_flux: 7" in fut.read_text(encoding="utf-8"),
            "quantum_flux survived",
        )
    )
    # The blast radius has to stop at the newer doc. One doc from the future must not take the
    # board down for everyone on it.
    r = _handoff(target, "claim", "ordinary", "fine")
    e.append(
        gc.expectation(
            "an ordinary doc on the same board is completely unaffected",
            r.returncode == 0 and (doc / ".locks/ordinary-handoff").exists(),
            f"exit {r.returncode}",
        )
    )

    findings = gc.verify_findings(VERIFY, target)
    e.append(
        gc.finding(
            findings,
            "doc.schema.ahead",
            "warn",
            label="verify reports the doc as ahead — a warn, since reading still works",
        )
    )
    return e


def grade_schema_board_ahead(target):
    """Refuse to CREATE on a board newer than this CLI — the gap require_writable cannot see.

    require_writable compares a doc that ALREADY EXISTS, so it covers claim/release/export and
    nothing else. `new` and plain `import` CREATE the doc and stamp it with this CLI's own
    SCHEMA_VERSION, which makes it writable by construction however far behind the CLI is. On a
    board a teammate already migrated, that files a downlevel document among current ones — and no
    later reader can tell it apart from one that genuinely predates the migration, so the next
    `migrate` "upgrades" a file that was written wrong today. The board's own stamp is the only
    thing that knows, which is why this gate reads it and the per-doc gate cannot.
    """
    e = []
    board = Path(target) / HD
    _handoff(target, "new", "ordinary", "--title", "Filed before the board moved")

    cfg = board / "handoff.json"
    d = json.loads(cfg.read_text(encoding="utf-8"))
    d["schema"] = 99
    cfg.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    r = _handoff(target, "list")
    e.append(
        gc.expectation(
            "reads still work on a board from the future",
            r.returncode == 0,
            f"exit {r.returncode}",
        )
    )

    r = _handoff(target, "new", "downlevel", "--title", "Would be stamped wrong")
    out = r.stdout + r.stderr
    e.append(
        gc.expectation(
            "new is REFUSED, naming both versions",
            r.returncode != 0 and "is schema 99" in out and "understands 1" in out,
            f"exit {r.returncode}: {out.strip()[-140:]}",
        )
    )
    e.append(
        gc.expectation(
            "and nothing was created",
            not (board / "downlevel-handoff.md").exists(),
            "downlevel-handoff.md absent",
        )
    )

    brief = Path(target) / "inbound-brief.md"
    brief.write_text("# Inbound\n\nA brief from outside the board.\n", encoding="utf-8")
    r = _handoff(target, "import", str(brief), "--id", "inbound", "--title", "Inbound")
    out = r.stdout + r.stderr
    e.append(
        gc.expectation(
            "import is REFUSED for the same reason — it creates a doc too",
            r.returncode != 0 and "is schema 99" in out,
            f"exit {r.returncode}: {out.strip()[-140:]}",
        )
    )
    e.append(
        gc.expectation(
            "and nothing was imported",
            not (board / "inbound-handoff.md").exists(),
            "inbound-handoff.md absent",
        )
    )

    # The blast radius stops at creation: a doc this CLI can represent is still fully writable.
    r = _handoff(target, "claim", "ordinary", "fine")
    e.append(
        gc.expectation(
            "an existing doc this CLI understands is still claimable",
            r.returncode == 0,
            f"exit {r.returncode}",
        )
    )
    return e


def grade_payload_downgrade(target):
    """Refuse to install OVER a newer board — the silent-downgrade bug.

    install_file byte-compares and copies; it has no notion of newer. On a shared board that means
    whoever runs the installer from the stalest checkout wins, and write_board_config then rewrites
    the stamp to match what was just installed — so the rollback leaves no trace at all, and the one
    reader that could have noticed (verify-setup-handoff.sh) blames the wrong side, telling the
    person who ran it that THEIR copy is stale.
    """
    e = []
    board = Path(target) / HD
    # Isolate the user-level CLI: this case manipulates payload stamps, and the real one is shared
    # by every board on the machine running the harness.
    env = {"XDG_DATA_HOME": str(Path(target) / ".harness-xdg")}

    cfg = board / "handoff.json"
    d = json.loads(cfg.read_text(encoding="utf-8"))
    d.setdefault("_generated", {})["payloadVersion"] = "setup-handoff 999"
    cfg.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    before = (board / "handoff").read_bytes()

    r = _run(["bash", str(SETUP), str(target), "--tools", "claude"], target, env)
    out = r.stdout + r.stderr
    e.append(
        gc.expectation(
            "installing over a newer board is REFUSED",
            r.returncode != 0 and "refusing to install" in out,
            f"exit {r.returncode}: {out.strip()[-140:]}",
        )
    )
    e.append(
        gc.expectation(
            "naming both versions, so the operator knows which side is stale",
            "v999" in out,
            f"out: {out.strip()[-140:]}",
        )
    )
    e.append(
        gc.expectation(
            "the board's CLI is byte-unchanged",
            (board / "handoff").read_bytes() == before,
            "dispatcher identical",
        )
    )
    stamp = (
        json.loads(cfg.read_text(encoding="utf-8"))
        .get("_generated", {})
        .get("payloadVersion")
    )
    e.append(
        gc.expectation(
            "and its stamp was NOT rewritten to hide the rollback",
            stamp == "setup-handoff 999",
            f"stamp: {stamp}",
        )
    )

    r = _run(
        ["bash", str(SETUP), str(target), "--tools", "claude", "--force-downgrade"],
        target,
        env,
    )
    e.append(
        gc.expectation(
            "--force-downgrade is the deliberate override",
            r.returncode == 0,
            f"exit {r.returncode}: {(r.stdout + r.stderr).strip()[-140:]}",
        )
    )
    stamp = (
        json.loads(cfg.read_text(encoding="utf-8"))
        .get("_generated", {})
        .get("payloadVersion")
    )
    e.append(
        gc.expectation(
            "and it does roll the stamp back",
            stamp != "setup-handoff 999",
            f"stamp: {stamp}",
        )
    )
    return e


def _dead_cli_env(target):
    """An environment in which NO rung of the CLI ladder resolves.

    $HANDOFF_BIN unset (this module sets it for every other case), $XDG_DATA_HOME pointed at an
    empty directory so the real user-level install on the machine running the harness cannot
    answer, and the fixture boards vendor no copy. All three rungs have to be closed at once or
    the case grades a machine that happens to have a CLI somewhere.
    """
    return {
        "HANDOFF_BIN": None,
        "XDG_DATA_HOME": str(Path(target) / ".harness-empty-xdg"),
    }


def grade_cli_unresolvable(target):
    """Fail OPEN when no CLI resolves, and never select a rung that cannot work.

    Two halves of one decision. The gate's every deny message ends in "claim it first:
    <board>/handoff claim …" — a command that does not exist on a board with no CLI. Denying
    anyway locks someone out of their own repo with an instruction they cannot follow, and the
    rational response is to delete the hook, so this one fails OPEN and says so loudly.

    That only holds if "no CLI resolves" is decided honestly. `-f` alone accepted a zero-byte
    file — an interrupted copy — and bash runs one happily: every command exited 0 having done
    nothing, so `claim` reported success while the lease stayed with its real holder, and the run
    discipline tells agents to trust that exit code. A rung that cannot work is now skipped, which
    is why the empty-$HANDOFF_BIN assertions below belong in the same case as the fail-open ones:
    a wrongly-selected rung is how the fail-open path stops being reached at all.
    """
    e = []
    board = Path(target) / HD
    dead = _dead_cli_env(target)
    Path(dead["XDG_DATA_HOME"]).mkdir(parents=True, exist_ok=True)

    # A doc held by SOMEONE ELSE. Without a live lease the gate allows the edit anyway and every
    # "allowed" assertion below would pass vacuously.
    _handoff(target, "new", "gated", "--title", "Held by another session")
    _handoff(target, "claim", "gated", "held by A", session="sess-AAA")
    doc = str(board / "gated-handoff.md")
    payload = {"tool_input": {"file_path": doc}}

    # The contrast. Same doc, same non-holder, working CLI -> DENY. This is what makes the
    # fail-open assertion mean something rather than merely observing an empty string.
    deny = _hook(target, "pretool-edit", payload, session="sess-ZZZ")
    e.append(
        gc.expectation(
            "with a CLI, the gate DENIES a non-holder editing a held doc",
            '"deny"' in deny,
            f"out: {deny[:120] or '(empty = allow)'}",
        )
    )

    allow = _hook(target, "pretool-edit", payload, session="sess-ZZZ", env_extra=dead)
    e.append(
        gc.expectation(
            "with NO CLI, the same edit is ALLOWED — the gate fails open",
            allow == "",
            f"out: {allow[:160]}",
        )
    )

    banner = _hook(target, "sessionstart", {}, session="sess-ZZZ", env_extra=dead)
    e.append(
        gc.expectation(
            "and the session banner says the lease gate is OFF",
            "LEASE GATE IS OFF" in banner,
            f"out: {banner[:160]}",
        )
    )
    e.append(
        gc.expectation(
            "naming the fix, not just the symptom",
            "setup-handoff" in banner and "HANDOFF_BIN" in banner,
            f"out: {banner[-200:]}",
        )
    )

    r = _run(["bash", str(board / "handoff"), "list"], target, dead)
    out = r.stdout + r.stderr
    e.append(
        gc.expectation(
            "the dispatcher exits 4 rather than dying as 'command not found'",
            r.returncode == 4,
            f"exit {r.returncode}",
        )
    )
    e.append(
        gc.expectation(
            "naming all three rungs it looked at",
            all(
                s in out for s in ("HANDOFF_BIN", "user-level install", "vendored copy")
            ),
            f"out: {out.strip()[:200]}",
        )
    )

    # The regression. An EMPTY $HANDOFF_BIN must not shadow the working rung below it.
    empty = Path(target) / ".harness-empty-cli"
    empty.write_bytes(b"")
    r = _run(
        ["bash", str(board / "handoff"), "claim", "gated", "steal"],
        target,
        {"HANDOFF_BIN": str(empty), "HANDOFF_SESSION_ID": "sess-ZZZ"},
    )
    out = r.stdout + r.stderr
    e.append(
        gc.expectation(
            "an EMPTY $HANDOFF_BIN is skipped, so the claim still reaches a CLI",
            r.returncode != 0,
            f"exit {r.returncode}: {out.strip()[:140]}",
        )
    )
    e.append(
        gc.expectation(
            "and the non-holder's steal is REFUSED, not silently 'succeeded'",
            "CLAIMED by" in out,
            f"out: {out.strip()[:160]}",
        )
    )
    e.append(
        gc.expectation(
            "the lease still belongs to its real holder",
            "sess-AAA" in _lease(target, "gated-handoff"),
            f"owner: {_lease(target, 'gated-handoff')[:60]}",
        )
    )

    # With every rung closed AND $HANDOFF_BIN pointing at that empty file, the diagnostic has to
    # say WHY it was rejected: the path printed is a file the reader can see sitting right there.
    r = _run(
        ["bash", str(board / "handoff"), "list"],
        target,
        {**dead, "HANDOFF_BIN": str(empty)},
    )
    out = r.stdout + r.stderr
    e.append(
        gc.expectation(
            "a rejected rung is reported as EMPTY, not merely 'looked at'",
            "EMPTY" in out,
            f"out: {out.strip()[:220]}",
        )
    )
    return e


def grade_board_override(target):
    """$HANDOFF_BOARD_PATH re-points the dispatcher at another board, visibly.

    The dispatcher's whole first job is "which board am I", answered from the directory it sits
    in. The override exists because that answer is wrong for a worktree, a shared board mounted
    elsewhere, or a harness driving one CLI across several boards. Two things have to hold, and
    only the pair is worth anything: the override must actually redirect BOTH reads and writes —
    a `list` that follows it while `new` files into the old board is worse than no override — and
    it must be VISIBLE, because a silent redirect means work lands on a board nobody is watching.
    """
    e = []
    board = Path(target) / HD

    r = _handoff(target, "--which")
    e.append(
        gc.expectation(
            "by default the board is the dispatcher's own directory",
            str(board) in r.stdout and "this board's dispatcher" in r.stdout,
            f"out: {r.stdout.strip()[:200]}",
        )
    )

    _handoff(target, "new", "on-home-board", "--title", "Filed with no override")
    e.append(
        gc.expectation(
            "and a doc files into that board",
            (board / "on-home-board-handoff.md").is_file(),
            "on-home-board-handoff.md present",
        )
    )

    # A second, real board. Copied rather than installed: the installer resolves to the git root,
    # so a nested install would land back on the first board and the case would grade nothing.
    other = Path(target) / "second-board"
    shutil.copytree(board, other)
    for junk in list(other.glob("*-handoff.md")) + [other / "INDEX.md"]:
        junk.unlink(missing_ok=True)
    shutil.rmtree(other / ".locks", ignore_errors=True)
    env = {"HANDOFF_BOARD_PATH": str(other), "HANDOFF_SESSION_ID": "sess-AAA"}

    r = _run(["bash", str(board / "handoff"), "--which"], target, env)
    e.append(
        gc.expectation(
            "the override re-points the board",
            str(other) in r.stdout,
            f"out: {r.stdout.strip()[:200]}",
        )
    )
    e.append(
        gc.expectation(
            "and says so, naming the board it overrode — never a silent redirect",
            "HANDOFF_BOARD_PATH" in r.stdout and "overriding" in r.stdout,
            f"out: {r.stdout.strip()[:200]}",
        )
    )

    r = _run(["bash", str(board / "handoff"), "list"], target, env)
    e.append(
        gc.expectation(
            "READS follow the override — the home board's doc is not listed",
            r.returncode == 0 and "on-home-board" not in r.stdout,
            f"exit {r.returncode}: {r.stdout.strip()[:200]}",
        )
    )

    r = _run(
        [
            "bash",
            str(board / "handoff"),
            "new",
            "via-override",
            "--title",
            "Filed through the override",
        ],
        target,
        env,
    )
    e.append(
        gc.expectation(
            "WRITES follow it too — a new doc lands on the overridden board",
            (other / "via-override-handoff.md").is_file(),
            f"exit {r.returncode}: {(r.stdout + r.stderr).strip()[-140:]}",
        )
    )
    e.append(
        gc.expectation(
            "and NOT on the dispatcher's own board",
            not (board / "via-override-handoff.md").exists(),
            "home board unchanged",
        )
    )
    e.append(
        gc.expectation(
            "the overridden board's index is the one regenerated",
            (other / "INDEX.md").is_file()
            and "via-override" in (other / "INDEX.md").read_text(),
            "second-board/INDEX.md names it",
        )
    )

    # The home board must still be reachable the moment the override is dropped — an override that
    # left state behind would make it a one-way door.
    r = _handoff(target, "list")
    e.append(
        gc.expectation(
            "dropping the override returns to the home board",
            "on-home-board" in r.stdout and "via-override" not in r.stdout,
            f"out: {r.stdout.strip()[:200]}",
        )
    )
    return e


def grade_script_behavior(target):
    e = []
    doc = Path(target) / HD

    _handoff(target, "new", "bt", "--title", "Backend task")
    e.append(
        gc.expectation(
            "handoff new creates a doc",
            (doc / "bt-handoff.md").is_file(),
            f"bt-handoff.md exists: {(doc / 'bt-handoff.md').is_file()}",
        )
    )

    # The grouped-board scope notice must stay invisible on a FLAT board: it keys off
    # board_is_grouped(), so a plain single-repo board has to behave exactly as it did before.
    r = _handoff(target, "list")
    e.append(
        gc.expectation(
            "flat board list stays silent on stderr (no section notice)",
            r.stderr.strip() == "",
            f"stderr: {r.stderr.strip()[:120]!r}",
        )
    )
    r = _handoff(target, "claim", "ghost-id", "x")
    e.append(
        gc.expectation(
            "flat board still reports an unknown id as no such handoff",
            NO_SUCH in r.stderr,
            f"stderr: {r.stderr.strip()[:120]!r}",
        )
    )

    _handoff(target, "claim", "bt", "on it", session="sess-AAA")
    lease = _lease(target, "bt-handoff")
    e.append(
        gc.expectation(
            "claim writes session= into the lease (defect #1 fixed)",
            "session=sess-AAA" in lease,
            f"lease: {lease!r}",
        )
    )

    deny = _hook(
        target,
        "pretool-edit",
        {"tool_input": {"file_path": str(doc / "bt-handoff.md")}},
        session="sess-BBB",
    )
    e.append(
        gc.expectation(
            "pretool gate DENIES a non-holder editing the doc",
            '"permissionDecision": "deny"' in deny,
            f"out: {deny[:120]!r}",
        )
    )
    allow = _hook(
        target,
        "pretool-edit",
        {"tool_input": {"file_path": str(doc / "bt-handoff.md")}},
        session="sess-AAA",
    )
    e.append(
        gc.expectation(
            "pretool gate ALLOWS the holder (empty output)",
            allow == "",
            f"out: {allow[:120]!r}",
        )
    )

    r = _handoff(target, "release", "bt", "--status", "done")
    e.append(
        gc.expectation(
            "done is REFUSED without --verified-by",
            r.returncode != 0,
            f"exit {r.returncode}: {r.stderr.strip()[:100]}",
        )
    )
    r = _handoff(
        target, "release", "bt", "--status", "done", "--verified-by", "manual: bt.js:1"
    )
    e.append(
        gc.expectation(
            "done with --verified-by archives the doc",
            r.returncode == 0 and (doc / "archive/bt-handoff.md").is_file(),
            f"exit {r.returncode}; archived: {(doc / 'archive/bt-handoff.md').is_file()}",
        )
    )

    _handoff(target, "new", "blk", "--title", "Blocker")
    _handoff(target, "new", "dep", "--title", "Dependent")
    _handoff(target, "claim", "dep")
    r = _handoff(target, "release", "dep", "--status", "blocked")
    e.append(
        gc.expectation(
            "blocked is REFUSED without --blocked-on",
            r.returncode != 0,
            f"exit {r.returncode}",
        )
    )
    _handoff(target, "claim", "dep")
    _handoff(target, "release", "dep", "--status", "blocked", "--blocked-on", "blk")
    dep_txt = (doc / "dep-handoff.md").read_text()
    e.append(
        gc.expectation(
            "blocked_on is recorded in the doc",
            "blocked_on: blk" in dep_txt,
            "blocked_on present: %s" % ("blocked_on: blk" in dep_txt),
        )
    )
    _handoff(target, "claim", "blk")
    r = _handoff(target, "release", "blk", "--status", "done", "--verified-by", "done")
    e.append(
        gc.expectation(
            "closing the blocker surfaces the dependent as unblocked",
            "dep" in r.stdout and "unblocked" in r.stdout.lower(),
            f"stdout: {r.stdout.strip()[:160]!r}",
        )
    )
    ss = _hook(target, "sessionstart", {})
    e.append(
        gc.expectation(
            "sessionstart flags the dependent UNBLOCKED",
            "UNBLOCKED" in ss,
            f"ctx has UNBLOCKED: {'UNBLOCKED' in ss}",
        )
    )

    # auto-reap: an expired lease is cleared at sessionstart
    _handoff(target, "new", "aband", "--title", "Abandoned")
    _handoff(target, "claim", "aband")
    _force_expiry(target, "aband-handoff")
    _hook(target, "sessionstart", {})
    e.append(
        gc.expectation(
            "sessionstart auto-reaps an expired lease",
            not (doc / ".locks/aband-handoff").exists(),
            "lock present: %s" % (doc / ".locks/aband-handoff").exists(),
        )
    )

    # auto-touch: the holder's lease TTL is renewed on posttool-edit
    _handoff(target, "new", "live", "--title", "Live work")
    _handoff(target, "claim", "live", session="sess-AAA")
    _force_expiry(target, "live-handoff")
    _hook(
        target,
        "posttool-edit",
        {"tool_response": {"filePath": str(Path(target) / "src/app.js")}},
        session="sess-AAA",
    )
    exp = ""
    for ln in _lease(target, "live-handoff").splitlines():
        if ln.startswith("expires="):
            exp = ln.split("=", 1)[1]
    e.append(
        gc.expectation(
            "posttool auto-touches the holder's lease (TTL renewed)",
            exp.isdigit() and int(exp) > 100000,
            f"expires={exp}",
        )
    )

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
    r = _handoff(
        target,
        "release",
        "vt",
        "--status",
        "done",
        "--verified-by",
        "z",
        "--run-verify",
    )
    e.append(
        gc.expectation(
            "verify: command is NOT auto-run without the install opt-in",
            not marker.exists(),
            f"marker present: {marker.exists()}; stdout: {r.stdout.strip()[:100]!r}",
        )
    )

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
    vr.write_text(
        vr.read_text().replace("status: open", f'status: open\nverify: "{cmd2}"', 1)
    )
    e.append(
        gc.expectation(
            "test setup: the doc carries the template's default empty repos list",
            "repos: []" in vr.read_text(),
            f"repos line: {[ln for ln in vr.read_text().splitlines() if ln.startswith('repos')]}",
        )
    )
    _handoff(target, "claim", "vr")
    r = _handoff(
        target,
        "release",
        "vr",
        "--status",
        "done",
        "--verified-by",
        "z",
        "--run-verify",
        allow_verify=True,
    )
    e.append(
        gc.expectation(
            "a QUOTED verify: command runs verbatim under the opt-in (quotes stripped)",
            r.returncode == 0
            and marker2.is_file()
            and marker2.read_text().strip() == "ran: yes",
            f"exit {r.returncode}; marker: {marker2.is_file()}; "
            f"stdout: {r.stdout.strip()[:100]!r}; stderr: {r.stderr.strip()[:100]!r}",
        )
    )
    e.append(
        gc.expectation(
            "the verify: run is recorded in verified_by",
            "[verify: exit 0]" in r.stdout,
            f"stdout: {r.stdout.strip()[:140]!r}",
        )
    )

    # The gate is a security boundary: a doc scoped to OTHER repos is untrusted and must never
    # auto-execute. Block-list syntax is the case that used to fail OPEN — meta() only reads the
    # key's own line, so `repos:` followed by `- other-repo` looked like "unset", i.e. local.
    for hid, repos_yaml, label in (
        ("vf", "repos: [some-other-repo]", "flow list"),
        ("vb", "repos:\n  - some-other-repo", "block list"),
    ):
        _handoff(target, "new", hid, "--title", f"Foreign {label}")
        fdoc = doc / f"{hid}-handoff.md"
        fmark = Path(target) / f"VERIFY_FOREIGN_{hid}"
        fcmd = f"""sh -c 'echo ran > {fmark}'"""
        fdoc.write_text(
            fdoc.read_text()
            .replace("repos: []", repos_yaml, 1)
            .replace("status: open", f'status: open\nverify: "{fcmd}"', 1)
        )
        _handoff(target, "claim", hid)
        r = _handoff(
            target,
            "release",
            hid,
            "--status",
            "done",
            "--verified-by",
            "z",
            "--run-verify",
            allow_verify=True,
        )
        e.append(
            gc.expectation(
                f"verify: is REFUSED for a doc scoped to another repo ({label})",
                not fmark.exists() and "was NOT run" in r.stdout,
                f"marker present: {fmark.exists()}; stdout: {r.stdout.strip()[:120]!r}",
            )
        )

    # --- handoff types: standalone/isolated is gate-exempt --------------------------------
    _handoff(target, "new", "refdoc", "--standalone", "--title", "Reference")
    refdoc = doc / "refdoc-handoff.md"
    e.append(
        gc.expectation(
            "new --standalone writes type: standalone",
            refdoc.is_file() and "type: standalone" in refdoc.read_text(),
            f"exists: {refdoc.is_file()}",
        )
    )
    # the crux: a NON-holder may edit a standalone doc — the pretool gate allows it (empty out)
    allow = _hook(
        target,
        "pretool-edit",
        {"tool_input": {"file_path": str(refdoc)}},
        session="sess-ZZZ",
    )
    e.append(
        gc.expectation(
            "pretool gate ALLOWS editing a standalone doc with no lease",
            allow == "",
            f"out: {allow[:120]!r}",
        )
    )
    # claim refuses a standalone (it is not claimable work)
    rc = _handoff(target, "claim", "refdoc", session="sess-ZZZ")
    e.append(
        gc.expectation(
            "claim REFUSES a standalone handoff",
            rc.returncode != 0,
            f"exit {rc.returncode}: {rc.stderr.strip()[:80]}",
        )
    )
    # standalone retire: done archives WITHOUT --verified-by
    rr = _handoff(target, "release", "refdoc", "--status", "done")
    e.append(
        gc.expectation(
            "standalone release --status done archives without --verified-by",
            rr.returncode == 0 and (doc / "archive/refdoc-handoff.md").is_file(),
            f"exit {rr.returncode}; archived: {(doc / 'archive/refdoc-handoff.md').is_file()}",
        )
    )
    # import brings an existing file onto the board as standalone
    src = Path(target) / "IMPORT_ME.md"
    src.write_text("# Imported\n\nbody\n")
    _handoff(target, "import", str(src), "--id", "imported", "--standalone")
    imp = doc / "imported-handoff.md"
    e.append(
        gc.expectation(
            "import lands a file typed as standalone",
            imp.is_file() and "type: standalone" in imp.read_text(),
            f"exists: {imp.is_file()}",
        )
    )

    # --- id casing: every id is folded to a lowercase-kebab slug --------------------------
    _handoff(target, "new", "RBAC Gap", "--title", "Caps and a space")
    slug = doc / "rbac-gap-handoff.md"
    e.append(
        gc.expectation(
            "new slugifies a spaced, capitalized id",
            slug.is_file(),
            f"rbac-gap-handoff.md exists: {slug.is_file()}",
        )
    )
    e.append(
        gc.expectation(
            "no non-conforming filename is created",
            not list(doc.glob("RBAC*")),
            f"stray: {[p.name for p in doc.glob('RBAC*')]}",
        )
    )
    r = _handoff(target, "new", "RBAC_Gap", "--title", "Underscore spelling")
    e.append(
        gc.expectation(
            "a differently-spelled id collides instead of forking the doc",
            r.returncode != 0 and "already exists" in (r.stdout + r.stderr),
            f"exit {r.returncode}: {(r.stdout + r.stderr).strip()[:100]}",
        )
    )
    r = _handoff(target, "claim", "RBAC-GAP", "case-insensitive lookup")
    e.append(
        gc.expectation(
            "claim resolves an id given in the wrong case",
            r.returncode == 0 and (doc / ".locks/rbac-gap-handoff").exists(),
            f"exit {r.returncode}; lock: {(doc / '.locks/rbac-gap-handoff').exists()}",
        )
    )
    _handoff(target, "release", "rbac-gap", "--status", "open")
    e.append(
        gc.expectation(
            "the generated Activity block is markdownlint-clean (blank line after the heading)",
            "## Activity\n\n- " in slug.read_text(),
            f"tail: {slug.read_text()[-120:]!r}",
        )
    )
    r = _handoff(target, "new", "!!!")
    e.append(
        gc.expectation(
            "an id with nothing alphanumeric is REJECTED",
            r.returncode != 0 and not (doc / "-handoff.md").exists(),
            f"exit {r.returncode}; '-handoff.md' created: {(doc / '-handoff.md').exists()}",
        )
    )

    # legacy fallback: a doc named by a PRE-slug install must stay reachable, not be re-created
    legacy = doc / "Legacy_Doc-handoff.md"
    legacy.write_text(
        "---\nid: Legacy_Doc-handoff\ntitle: Pre-slug doc\ntype: coordination\n"
        "status: open\nseverity: low\ncreated: 2026-01-01\nupdated: 2026-01-01\n---\n\n## Context\n"
    )
    r = _handoff(target, "claim", "Legacy_Doc", "picking up legacy work")
    e.append(
        gc.expectation(
            "claim falls back to a pre-slug filename instead of inventing a slug",
            r.returncode == 0
            and (doc / ".locks/Legacy_Doc-handoff").exists()
            and not (doc / "legacy-doc-handoff.md").exists(),
            f"exit {r.returncode}; lock: {(doc / '.locks/Legacy_Doc-handoff').exists()}; "
            f"invented: {(doc / 'legacy-doc-handoff.md').exists()}",
        )
    )
    r = _handoff(
        target, "release", "Legacy_Doc", "--status", "done", "--verified-by", "grader"
    )
    e.append(
        gc.expectation(
            "a pre-slug doc still archives on done",
            r.returncode == 0 and (doc / "archive/Legacy_Doc-handoff.md").is_file(),
            f"exit {r.returncode}; archived: {(doc / 'archive/Legacy_Doc-handoff.md').is_file()}",
        )
    )

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
    e.append(
        gc.expectation(
            "claim on an unresolvable id exits NONZERO",
            r.returncode != 0,
            f"exit {r.returncode}: {out.strip()[:120]}",
        )
    )
    e.append(
        gc.expectation(
            "claim on an unresolvable id mints NO lease",
            after == before,
            f"locks before={before} after={after}",
        )
    )
    e.append(
        gc.expectation(
            "claim on an unresolvable id emits no sed/grep error spew",
            "No such file or directory" not in out,
            f"out: {out.strip()[:160]}",
        )
    )
    e.append(
        gc.expectation(
            "an unresolvable id names its near miss on the board",
            "rbac-gap-handoff" in out,
            f"out: {out.strip()[:160]}",
        )
    )
    doc_before = slug.read_text()
    r = _handoff(
        target, "release", "rbac", "--status", "done", "--verified-by", "grader"
    )
    out = r.stdout + r.stderr
    e.append(
        gc.expectation(
            "release on an unresolvable id exits NONZERO and mutates nothing",
            r.returncode != 0
            and slug.read_text() == doc_before
            and "No such file or directory" not in out,
            f"exit {r.returncode}; real doc changed: {slug.read_text() != doc_before}; "
            f"out: {out.strip()[:120]}",
        )
    )

    # --- template rendering must survive arbitrary --title/--note text ---------------------
    # These were rendered with `sed "s|PLACEHOLDER_NOTE|$note|"`, so a `|` in the value closed the
    # expression early. The redirect had already truncated the file, so the doc landed ZERO BYTES
    # while the command still reported success. `&` is the other trap: sed expands it to the match.
    _handoff(
        target, "new", "meta1", "--title", "Fix A & B", "--note", "a|b broke the render"
    )
    m1 = doc / "meta1-handoff.md"
    e.append(
        gc.expectation(
            "a '|' in --note does not produce an empty doc",
            m1.is_file() and m1.stat().st_size > 0,
            f"size: {m1.stat().st_size if m1.is_file() else 'absent'}",
        )
    )
    e.append(
        gc.expectation(
            "'|' and '&' survive verbatim into the frontmatter",
            "note: a|b broke the render" in m1.read_text()
            and "title: Fix A & B" in m1.read_text(),
            f"frontmatter: {m1.read_text()[:160]!r}",
        )
    )
    _handoff(target, "new", "meta2", "--standalone", "--title", "Ref | doc")
    _handoff(
        target,
        "new",
        "meta3",
        "--orchestrator",
        "--children",
        "meta1",
        "--title",
        "Bundle | x",
    )
    e.append(
        gc.expectation(
            "standalone and orchestrator templates render the same way",
            (doc / "meta2-handoff.md").stat().st_size > 0
            and "title: Ref | doc" in (doc / "meta2-handoff.md").read_text()
            and (doc / "meta3-handoff.md").stat().st_size > 0
            and "title: Bundle | x" in (doc / "meta3-handoff.md").read_text(),
            f"standalone: {(doc / 'meta2-handoff.md').stat().st_size}; "
            f"orchestrator: {(doc / 'meta3-handoff.md').stat().st_size}",
        )
    )

    # --- titles are colon-free: `title:` is unquoted YAML, so a ':' in the value breaks -----
    # every frontmatter parser that reads the doc (markdown preview included)
    _handoff(target, "new", "ct", "--title", "Handoff: colon title")
    ct = (doc / "ct-handoff.md").read_text()
    e.append(
        gc.expectation(
            "a ':' in --title is folded to an em dash (YAML-safe frontmatter)",
            "title: Handoff — colon title" in ct and "title: Handoff:" not in ct,
            f"frontmatter: {ct[:120]!r}",
        )
    )
    src_colon = Path(target) / "IMPORT_COLON.md"
    src_colon.write_text("# Guide: ports\n\nbody\n")
    _handoff(target, "import", str(src_colon), "--id", "colon-import", "--standalone")
    ci = (doc / "colon-import-handoff.md").read_text()
    e.append(
        gc.expectation(
            "import folds a ':' in the H1-derived title too",
            "title: Guide — ports" in ci,
            f"frontmatter: {ci[:120]!r}",
        )
    )
    # `note:` is the other free-text value new/import write into frontmatter unquoted
    _handoff(target, "new", "cn", "--title", "Colon note", "--note", "see: foo")
    cn = (doc / "cn-handoff.md").read_text()
    e.append(
        gc.expectation(
            "a ':' in --note is folded to an em dash",
            "note: see — foo" in cn and "note: see:" not in cn,
            f"frontmatter: {cn[:160]!r}",
        )
    )

    # --- --blocked-on is validated: an unclosable blocker deadlocks silently ---------------
    _handoff(target, "new", "bo1", "--title", "Blocked one")
    _handoff(target, "new", "bo2", "--title", "Blocked two")
    _handoff(target, "new", "boref", "--standalone", "--title", "Reference blocker")
    _handoff(target, "claim", "bo1")
    r = _handoff(
        target, "release", "bo1", "--status", "blocked", "--blocked-on", "no-such-thing"
    )
    e.append(
        gc.expectation(
            "blocked on a NONEXISTENT handoff is REFUSED (nothing would close it)",
            r.returncode != 0
            and "blocked_on:" not in (doc / "bo1-handoff.md").read_text(),
            f"exit {r.returncode}: {r.stderr.strip()[:110]}",
        )
    )
    r = _handoff(target, "release", "bo1", "--status", "blocked", "--blocked-on", "bo1")
    e.append(
        gc.expectation(
            "blocked on ITSELF is REFUSED",
            r.returncode != 0,
            f"exit {r.returncode}: {r.stderr.strip()[:110]}",
        )
    )
    # "external: ..." stays the documented spelling to TYPE — but it lands in frontmatter as
    # unquoted YAML, so the value is folded on the way in and stored as "external — ...".
    r = _handoff(
        target,
        "release",
        "bo1",
        "--status",
        "blocked",
        "--blocked-on",
        "external: vendor ticket",
    )
    e.append(
        gc.expectation(
            "an external: blocker is still accepted unvalidated, stored colon-free",
            r.returncode == 0
            and "blocked_on: external — vendor ticket"
            in (doc / "bo1-handoff.md").read_text(),
            f"exit {r.returncode}",
        )
    )
    _handoff(target, "claim", "bo1")
    r = _handoff(
        target,
        "release",
        "bo1",
        "--status",
        "blocked",
        "--blocked-on",
        "external — em dash blocker",
    )
    e.append(
        gc.expectation(
            "the already-folded em-dash spelling of an external blocker is accepted too",
            r.returncode == 0
            and "blocked_on: external — em dash blocker"
            in (doc / "bo1-handoff.md").read_text(),
            f"exit {r.returncode}: {r.stderr.strip()[:110]}",
        )
    )
    # a standalone doc IS a legal blocker, and retiring it must announce the dependent — the retire
    # path is newer than the unblock feature and originally skipped surface_unblocked entirely
    _handoff(target, "claim", "bo2")
    _handoff(target, "release", "bo2", "--status", "blocked", "--blocked-on", "boref")
    r = _handoff(target, "release", "boref", "--status", "done")
    e.append(
        gc.expectation(
            "retiring a standalone SURFACES the handoff blocked on it",
            r.returncode == 0 and "bo2-handoff" in r.stdout,
            f"exit {r.returncode}; stdout: {r.stdout.strip()[:160]!r}",
        )
    )

    # --- orchestrator: a bundle index whose progress is DERIVED, never stored -------------
    _handoff(target, "new", "kid-a", "--title", "Child A")
    _handoff(target, "new", "kid-b", "--title", "Child B")
    # third child is deliberately NOT filed — a bundle is often planned before every unit exists
    _handoff(
        target,
        "new",
        "bundle",
        "--orchestrator",
        "--children",
        "kid-a,kid-b,kid-c",
        "--title",
        "The bundle",
    )
    orch = doc / "bundle-handoff.md"
    e.append(
        gc.expectation(
            "new --orchestrator writes type + canonicalized children",
            orch.is_file()
            and "type: orchestrator" in orch.read_text()
            and "kid-a-handoff" in orch.read_text(),
            f"exists: {orch.is_file()}",
        )
    )
    r = _handoff(target, "claim", "bundle")
    e.append(
        gc.expectation(
            "claim REFUSES an orchestrator (its children are the work)",
            r.returncode != 0,
            f"exit {r.returncode}: {r.stderr.strip()[:80]}",
        )
    )
    allow = _hook(
        target,
        "pretool-edit",
        {"tool_input": {"file_path": str(orch)}},
        session="sess-ZZZ",
    )
    e.append(
        gc.expectation(
            "pretool gate ALLOWS editing an orchestrator with no lease",
            allow == "",
            f"out: {allow[:120]!r}",
        )
    )
    lst = _handoff(target, "list").stdout
    e.append(
        gc.expectation(
            "list counts an unfiled child (MISSING), never as progress",
            "0/3 done" in lst and "kid-c-handoff (MISSING)" in lst,
            f"list: {lst[lst.find('Orchestrator'):][:220]!r}",
        )
    )
    # INDEX.md is the generated board humans and AGENTS.md point at; it must agree with `list`.
    # An orchestrator leaking into the Open table reads as an unclaimed task with no lease.
    _handoff(target, "index")
    idx = (doc / "INDEX.md").read_text()
    open_table = idx.split("## Orchestrators")[0]
    e.append(
        gc.expectation(
            "INDEX.md keeps orchestrators OUT of the Open work table",
            "bundle-handoff.md" not in open_table,
            f"open section: {open_table[open_table.find('## Open'):][:220]!r}",
        )
    )
    e.append(
        gc.expectation(
            "INDEX.md renders bundle progress derived from the children",
            "## Orchestrators" in idx
            and "0/3 done" in idx
            and "kid-c-handoff (MISSING)" in idx,
            f"orch section: {idx[idx.find('## Orchestrators'):][:220]!r}",
        )
    )
    r = _handoff(target, "release", "bundle", "--status", "done")
    e.append(
        gc.expectation(
            "bundle done is REFUSED while children are outstanding",
            r.returncode != 0 and not (doc / "archive/bundle-handoff.md").exists(),
            f"exit {r.returncode}: {r.stderr.strip()[:100]}",
        )
    )
    for kid in ("kid-a", "kid-b"):
        _handoff(target, "claim", kid)
        _handoff(target, "release", kid, "--status", "done", "--verified-by", "grader")
    _handoff(target, "new", "kid-c", "--title", "Child C")
    _handoff(target, "claim", "kid-c")
    _handoff(target, "release", "kid-c", "--status", "done", "--verified-by", "grader")
    lst = _handoff(target, "list").stdout
    e.append(
        gc.expectation(
            "progress tracks children with no edit to the orchestrator doc",
            "3/3 done" in lst,
            f"list: {lst[lst.find('Orchestrator'):][:200]!r}",
        )
    )
    r = _handoff(target, "release", "bundle", "--status", "done")
    e.append(
        gc.expectation(
            "bundle closes once every child is done",
            r.returncode == 0 and (doc / "archive/bundle-handoff.md").is_file(),
            f"exit {r.returncode}; archived: {(doc / 'archive/bundle-handoff.md').is_file()}",
        )
    )

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
        e.append(
            gc.expectation(
                f"release --status {status} on a {new_type} doc clears the lease it still held",
                r.returncode == 0 and not lock.exists(),
                f"exit {r.returncode}; lock present: {lock.exists()}; err: {r.stderr.strip()[:80]!r}",
            )
        )

    # The regression the fix must not cause: the coordination path already cleared its lease, and
    # every status has to keep doing so.
    _handoff(target, "new", "lease-blk", "--title", "Blocker for the lease sweep")
    for hid, args in (
        ("lease-open", ("--status", "open")),
        ("lease-blocked", ("--status", "blocked", "--blocked-on", "lease-blk")),
        (
            "lease-done",
            ("--status", "done", "--verified-by", "grader read the live code"),
        ),
    ):
        _handoff(target, "new", hid, "--title", "Coordination work")
        _handoff(target, "claim", hid)
        r = _handoff(target, "release", hid, *args)
        lock = doc / f".locks/{hid}-handoff"
        e.append(
            gc.expectation(
                f"coordination release {args[1]} still clears its lease",
                r.returncode == 0 and not lock.exists(),
                f"exit {r.returncode}; lock present: {lock.exists()}; err: {r.stderr.strip()[:80]!r}",
            )
        )

    # Catch-all over everything this suite produced: no field-by-field expectation can cover a
    # value the CLI learns to write later, and one bad line breaks the whole doc for every parser.
    offenders = sorted(
        o
        for p in [*doc.glob("*-handoff.md"), *(doc / "archive").glob("*-handoff.md")]
        for o in _fm_colon_offenders(p)
    )
    e.append(
        gc.expectation(
            "every doc this suite wrote has YAML-safe frontmatter (no bare ':' in a value)",
            not offenders,
            f"offenders: {offenders[:3]}",
        )
    )
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
    for tmpl in sorted(
        (hd / "templates").glob("*.md")
    ):  # every template, not a hardcoded pair
        tmpl.rename(hd / tmpl.name)
    (hd / "templates").rmdir()
    settings.write_text(
        settings.read_text().replace("handoff/scripts/hooks.sh", "handoff/hooks.sh")
    )
    e.append(
        gc.expectation(
            "test setup: board is flat again before the migration run",
            (hd / "hooks.sh").is_file() and not (hd / "scripts/hooks.sh").exists(),
            f"flat hooks.sh: {(hd / 'hooks.sh').is_file()}",
        )
    )

    # re-install: this is the migration
    r = _install(target, "--primary", "claude")
    e.append(
        gc.expectation(
            "installer succeeds on a flat board",
            r.returncode == 0,
            f"exit {r.returncode}: {r.stderr.strip()[:120]}",
        )
    )
    e.append(
        gc.expectation(
            "hooks.sh moved into scripts/",
            (hd / "scripts/hooks.sh").is_file() and not (hd / "hooks.sh").exists(),
            f"scripts/hooks.sh: {(hd / 'scripts/hooks.sh').is_file()}; "
            f"stale root copy: {(hd / 'hooks.sh').exists()}",
        )
    )
    e.append(
        gc.expectation(
            "templates moved into templates/",
            (hd / "templates/handoff-doc-template.md").is_file()
            and not (hd / "handoff-doc-template.md").exists(),
            f"templates/: {(hd / 'templates/handoff-doc-template.md').is_file()}; "
            f"stale root copy: {(hd / 'handoff-doc-template.md').exists()}",
        )
    )
    # The board root keeps a file called `handoff` — every wired hook command and README points
    # there — but it is now the dispatcher, and the CLI it execs is vendored under scripts/. Both
    # halves are asserted: a dispatcher with nothing to exec is a board whose lease gate is off.
    e.append(
        gc.expectation(
            "the board root keeps a `handoff` entry point",
            (hd / "handoff").is_file(),
            f"handoff at root: {(hd / 'handoff').is_file()}",
        )
    )
    e.append(
        gc.expectation(
            "and a default install vendors the CLI it dispatches to",
            (hd / "scripts/handoff-cli").is_file(),
            f"scripts/handoff-cli: {(hd / 'scripts/handoff-cli').is_file()}",
        )
    )

    cfg = json.loads(settings.read_text())
    cmds = [
        h.get("command", "")
        for groups in cfg.get("hooks", {}).values()
        for g in groups
        for h in g.get("hooks", [])
    ]
    e.append(
        gc.expectation(
            "every hook command points at the new scripts/hooks.sh path",
            cmds and all("handoff/scripts/hooks.sh" in c for c in cmds),
            f"commands: {cmds}",
        )
    )
    e.append(
        gc.expectation(
            "no duplicated hook groups (old marker was recognized as ours)",
            len(cmds) == 4,
            f"{len(cmds)} hook entries: {cmds}",
        )
    )

    # the migrated board must still WORK, not merely look right
    _handoff(target, "new", "post-migration", "--title", "After the move")
    doc = hd / "post-migration-handoff.md"
    e.append(
        gc.expectation(
            "handoff new still scaffolds from the moved template",
            doc.is_file() and "## Context" in doc.read_text(),
            f"doc: {doc.is_file()}",
        )
    )
    deny = _hook(
        target,
        "pretool-edit",
        {"tool_input": {"file_path": str(hd / "INDEX.md")}},
        session="sess-ZZZ",
    )
    e.append(
        gc.expectation(
            "hooks.sh resolves the board root from scripts/ (gate still fires)",
            '"permissionDecision": "deny"' in deny,
            f"out: {deny[:120]!r}",
        )
    )
    e.append(gc.run_verify_script(VERIFY, target))
    return e


def grade_custom_board_name(_target):
    """A board whose directory is NOT named `handoff` must resolve AND report its wired tool.

    `--handoff-dir` accepts any path, but two checks in verify-setup-handoff.sh recovered the board
    by grepping for a literal `handoff/` inside a hook command string. Point a repo at a board named
    anything else and a completely healthy install came back as `handoff not installed` plus `no
    tool hooks wired` — two hard FAILs, zero real defects. Every installer writes the default name,
    which is exactly why nothing caught it: the existing custom-location case passes
    `--handoff-dir .claude/handoff`, whose basename is still `handoff`.

    Two negative halves stop the fix from being "just widen the pattern", and they do different
    jobs. setup-graph-hooks writes its own `--kind` hook commands into these same config files, so
    coexistence is asserted both ways: wired alongside handoff it must not inflate the count, and
    wired ALONE it must still leave `tool.wired.any` failing. That pair does not by itself pin the
    pattern down — graph-hooks' dispatcher is `.graph-hooks/hook.sh`, singular, so no widening of
    `hooks\.sh` can confuse it. The check that actually discriminates is the third: a FOREIGN
    `scripts/hooks.sh` command carrying no `--kind` flag, which a bare `hooks\.sh` pattern claims
    as handoff wiring and the shape-anchored one does not. That is the hazard merge-hooks.py's
    is_managed() is written against, and the reason both halves of it are required here.

    Self-contained (ignores the passed fixture); cleans up its own temp tree.
    """
    import os
    import shutil
    import tempfile

    e = []
    parent = Path(tempfile.mkdtemp(prefix="handoff-boardname-"))

    def sh(args, cwd):
        return subprocess.run(
            args, cwd=str(cwd), capture_output=True, text=True, env=dict(os.environ)
        )

    def new_repo(name):
        r = parent / name
        r.mkdir()
        sh(["git", "init", "-q"], r)
        sh(["git", "config", "user.email", "t@t.t"], r)
        sh(["git", "config", "user.name", "t"], r)
        (r / "AGENTS.md").write_text("# AGENTS.md\n")
        return r

    def wire_graph(repo):
        return sh(
            [
                "bash",
                str(GRAPH_SETUP),
                str(repo),
                "--tools",
                "claude",
                "--primary",
                "claude",
            ],
            repo,
        )

    try:
        # --- positive: a board named `board`, with graph hooks wired alongside it ---------------
        repo = new_repo("named-board")
        graph = wire_graph(repo)
        r = sh(
            [
                "bash",
                str(SETUP),
                str(repo),
                "--tools",
                "claude",
                "--primary",
                "claude",
                "--handoff-dir",
                ".agents/board",
            ],
            repo,
        )
        e.append(
            gc.expectation(
                "installer succeeds with a --handoff-dir whose basename is not `handoff`",
                r.returncode == 0,
                f"exit {r.returncode}: {r.stderr.strip()[:160]}",
            )
        )
        e.append(gc.file_exists(repo, ".agents/board/scripts/hooks.sh"))
        e.append(
            gc.no_fabrication(repo, HD)
        )  # did not silently fall back to the default name

        proc = subprocess.run(
            ["bash", str(VERIFY), str(repo), "--json"], capture_output=True, text=True
        )
        try:
            resolved = json.loads(proc.stdout).get("board", "")
        except ValueError:
            resolved = ""
        e.append(
            gc.expectation(
                "the verifier RESOLVES a board that is not named `handoff`",
                resolved.endswith("/.agents/board"),
                f"board={resolved or '(no JSON)'}",
            )
        )
        findings = gc.verify_findings(VERIFY, repo)
        e.append(
            gc.finding(
                findings,
                "tool.wired",
                "pass",
                label="and reports the tool wired to it (the half that still grepped `handoff/`)",
            )
        )
        e.append(gc.finding(findings, "tool.primary.hard", "pass"))
        e.append(gc.no_findings_at(findings, "fail"))

        # The graph hooks land in .claude/settings.local.json, which check_tool also reads. Exactly
        # one config may be claimed as handoff wiring, and it must be the one setup-handoff wrote.
        label = "a graph-hooks config alongside it is NOT claimed as handoff wiring"
        if graph.returncode != 0:
            e.append(
                gc.skipped(label, f"setup-graph-hooks: {graph.stderr.strip()[:160]}")
            )
        else:
            claimed = [f["message"] for f in findings.get("tool.wired", [])]
            e.append(
                gc.expectation(
                    label,
                    len(claimed) == 1 and "settings.local.json" not in claimed[0],
                    f"tool.wired x{len(claimed)}: {claimed}",
                )
            )

        # --- negative: graph hooks and NOTHING else ---------------------------------------------
        # A default-named board, so resolution succeeds and the run actually reaches section 3, with
        # every handoff hook command overwritten. Widening the pattern to a bare `hooks.sh` passes
        # the positive above and fails right here.
        label = "a repo wired ONLY with setup-graph-hooks still reports no handoff tools wired"
        only = new_repo("graph-only")
        sh(
            ["bash", str(SETUP), str(only), "--tools", "claude", "--primary", "claude"],
            only,
        )
        g2 = wire_graph(only)
        graph_cfg = only / ".claude/settings.local.json"
        if g2.returncode != 0 or not graph_cfg.is_file():
            e.append(gc.skipped(label, f"setup-graph-hooks: {g2.stderr.strip()[:160]}"))
        else:
            shutil.copyfile(graph_cfg, only / ".claude/settings.json")
            e.append(
                gc.finding(
                    gc.verify_findings(VERIFY, only),
                    "tool.wired.any",
                    "fail",
                    label=label,
                )
            )

        # --- negative: a FOREIGN scripts/hooks.sh, which is what a bare `hooks\.sh` would claim ---
        # Written inline rather than driven from another installer on purpose: what is pinned here
        # is a command that is NOT ours, so unlike a copy of some tool's real output it cannot go
        # stale. No `--kind` is the whole point — that flag is handoff's own protocol.
        alien = new_repo("alien-hooks")
        sh(
            [
                "bash",
                str(SETUP),
                str(alien),
                "--tools",
                "claude",
                "--primary",
                "claude",
            ],
            alien,
        )
        (alien / ".claude/settings.json").write_text(
            json.dumps(
                {
                    "hooks": {
                        "PreToolUse": [
                            {
                                "matcher": "Edit",
                                "hooks": [
                                    {
                                        "type": "command",
                                        "command": "bash .config/somectl/scripts/hooks.sh --event pre-edit",
                                    }
                                ],
                            }
                        ]
                    }
                },
                indent=2,
            )
            + "\n"
        )
        e.append(
            gc.finding(
                gc.verify_findings(VERIFY, alien),
                "tool.wired.any",
                "fail",
                label="another tool's scripts/hooks.sh (no --kind) is NOT claimed as handoff wiring",
            )
        )
        return e
    finally:
        shutil.rmtree(parent, ignore_errors=True)


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
        return subprocess.run(
            args,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            env={**os.environ, **(env_extra or {})},
        )

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
            return sh(
                [
                    "bash",
                    str(SETUP),
                    str(r),
                    "--tools",
                    "claude",
                    "--primary",
                    "claude",
                    "--topology",
                    "cross-repo",
                    "--handoff-dir",
                    "../handoff",
                ],
                r,
            )

        for name, r in repos.items():
            res = install(r)
            e.append(
                gc.expectation(
                    f"installer succeeds cross-repo in {name}",
                    res.returncode == 0,
                    f"exit {res.returncode}: {res.stderr.strip()[:120]}",
                )
            )

        cfg = _board_json(board)
        e.append(
            gc.expectation(
                "shared config omits repoName (no last-writer clobber)",
                "repoName" not in cfg and cfg.get("topology") == "cross-repo",
                f"config={cfg!r}",
            )
        )

        for name, r in repos.items():
            rc_path = r / ".agents/handoff.json"
            rc = json.loads(rc_path.read_text()) if rc_path.is_file() else {}
            e.append(
                gc.expectation(
                    f"{name} repo config records its own identity",
                    rc.get("repo") == name,
                    f"repo config={rc!r}",
                )
            )
            s = (r / ".claude/settings.json").read_text()
            e.append(
                gc.expectation(
                    f"{name} hook command carries a --project-dir anchor, not a baked identity",
                    "--project-dir" in s and f"HANDOFF_REPO={name}" not in s,
                    f"--project-dir present: {'--project-dir' in s}; no baked identity: {(f'HANDOFF_REPO={name}') not in s}",
                )
            )
            a = (r / "AGENTS.md").read_text()
            e.append(
                gc.expectation(
                    f"{name} AGENTS.md advertises the shared path (../handoff), not .agents/handoff",
                    "../handoff/handoff" in a and ".agents/handoff" not in a,
                    f"xrepo path: {'../handoff/handoff' in a}; leaked default: {'.agents/handoff' in a}",
                )
            )
            gi = (r / ".gitignore").read_text() if (r / ".gitignore").is_file() else ""
            e.append(
                gc.expectation(
                    f"{name} .gitignore has no inert .locks/ entry",
                    ".locks/" not in gi,
                    f"gitignore={gi!r}",
                )
            )

        # Re-run A: B's identity and the shared config must NOT flip (the exact spec repro).
        install(repos["repo-a"])
        # Through the resolver, not a bare read_text(): the pre-consolidation filename made this
        # line raise FileNotFoundError and take the WHOLE cross-repo eval down — no grading.json
        # was produced at all, so the case read as "not run" rather than "failing".
        rc_b = _repo_json(repos["repo-b"])
        cfg2 = _board_json(board)
        e.append(
            gc.expectation(
                "re-installing repo-a leaves repo-b's identity intact",
                rc_b.get("repo") == "repo-b" and "repoName" not in cfg2,
                f"b-intact repo config: {rc_b!r}; cfg-neutral: {'repoName' not in cfg2}",
            )
        )

        # audience routing: sessionstart in repo-b surfaces only its own docs.
        ho, hk = board / "handoff", board / "scripts/hooks.sh"
        sh(
            [
                "bash",
                str(ho),
                "new",
                "task-a",
                "--audience",
                "repo-a",
                "--title",
                "A task",
            ],
            board,
            {"HANDOFF_REPO": "repo-a"},
        )
        sh(
            [
                "bash",
                str(ho),
                "new",
                "task-b",
                "--audience",
                "repo-b",
                "--title",
                "B task",
            ],
            board,
            {"HANDOFF_REPO": "repo-b"},
        )
        # simulate repo-b's baked hook command env (setup wires both HANDOFF_REPO + HANDOFF_HDPATH)
        ss = subprocess.run(
            ["bash", str(hk), "--kind", "sessionstart", "--tool", "claude"],
            cwd=str(repos["repo-b"]),
            input='{"session_id":"s"}',
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "HANDOFF_REPO": "repo-b",
                "HANDOFF_HDPATH": "../handoff",
            },
        ).stdout
        e.append(
            gc.expectation(
                "sessionstart in repo-b surfaces only its own audience (routing works)",
                "task-b" in ss and "task-a" not in ss,
                f"ss={ss[:160]!r}",
            )
        )
        e.append(
            gc.expectation(
                "sessionstart hint uses the shared board path, not .agents/handoff",
                "../handoff/handoff claim" in ss and ".agents/handoff" not in ss,
                f"xrepo hint: {'../handoff/handoff claim' in ss}",
            )
        )

        # CLI guard: `new` on a shared board with no identity must refuse rather than default.
        r_noid = sh(["bash", str(ho), "new", "orphan", "--title", "no identity"], board)
        e.append(
            gc.expectation(
                "cross-repo `new` without --audience/HANDOFF_REPO is refused",
                r_noid.returncode != 0,
                f"exit {r_noid.returncode}: {r_noid.stderr.strip()[:100]}",
            )
        )
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
    e.append(
        gc.expectation(
            f"{tag} list with no group in scope warns instead of looking empty",
            "no HANDOFF_GROUP is set" in r.stderr,
            f"stderr: {r.stderr.strip()[:160]!r}",
        )
    )
    e.append(
        gc.expectation(
            f"{tag} that warning is on stderr, leaving stdout the plain table",
            "HANDOFF_GROUP" not in r.stdout and r.stdout.startswith("ID"),
            f"stdout head: {r.stdout[:60]!r}",
        )
    )
    r = sh(["bash", str(ho), "list"], board, inscope)
    e.append(
        gc.expectation(
            f"{tag} no warning when a section IS in scope",
            r.stderr.strip() == "",
            f"stderr: {r.stderr.strip()[:120]!r}",
        )
    )

    # "no such handoff" for a doc that is merely in another section is actively wrong — the id is
    # real, and that message sends the reader to `list`, which is empty/foreign for the same reason.
    r = sh(["bash", str(ho), "claim", "node-drain", "x"], board, inscope)
    named = "infra section" in r.stderr and NO_SUCH not in r.stderr
    e.append(
        gc.expectation(
            f"{tag} claim on another section's id names that section",
            r.returncode != 0 and named,
            f"stderr: {r.stderr.strip()[:160]!r}",
        )
    )
    r = sh(["bash", str(ho), "claim", "node-drain", "x"], board, noscope)
    e.append(
        gc.expectation(
            f"{tag} claim with no group in scope names the section too",
            r.returncode != 0 and "infra section" in r.stderr,
            f"stderr: {r.stderr.strip()[:160]!r}",
        )
    )
    r = sh(["bash", str(ho), "claim", "totally-made-up", "x"], board, inscope)
    e.append(
        gc.expectation(
            f"{tag} a genuinely unknown id still reports no such handoff",
            NO_SUCH in r.stderr,
            f"stderr: {r.stderr.strip()[:120]!r}",
        )
    )
    return e


def grade_schema_behind(_target):
    """`doc.schema.behind` counts the LIVE section; the archive is reported on its own line.

    Two defects meet here.

    The first was a `continue` written inside a `case` arm: it was meant to skip the current-state
    check for archived docs and instead exited the whole loop iteration, so every archived
    coordination and orchestrator doc also skipped the schema count at the bottom of the loop. On a
    real board it reported "4 of 47 doc(s) predate schema 1" where the true number was 41 -- a
    drift detector hiding drift.

    The second was the fix for the first. With the count accurate, the same board reported "41 of
    49 doc(s) predate schema 1 -- run './handoff migrate'", and running it did nothing for those
    41: `migrate` walks the live section only, and all 41 were archived. An accurate number
    attached to advice that cannot act on it is its own way of teaching people to skip the section.
    So the count is now SPLIT, and `migrate` keeps its scope: archived docs are counted onto
    `board.schema.archive` (a PASS -- a closed doc keeping the shape it was closed in is not a
    to-do), and `doc.schema.behind` warns only for docs migrate can actually reach.

    The four boards are built so the FINDING ID discriminates, never the prose. Asserting the count
    would mean parsing a message, and this harness asserts on ids precisely because prose is
    reworded freely:

      * `archived-coordination` -- the only doc below schema is an archived COORDINATION doc. This
        is the board the `continue` broke: the buggy verifier never reaches its schema check, so it
        counts the doc into NOTHING and `board.schema.archive` never fires. The fixed one reports
        it there. The live section is clean either way, so `doc.schema` all-clear is not what
        separates them -- the archive line is.
      * `archived-standalone` -- the only doc below schema is an archived STANDALONE doc. It never
        enters the case arm, so both versions see it. This is the control: it proves the archive
        line is driven by the doc's LOCATION and not by its type, and that a naive fix which drops
        archived docs from the sweep entirely (rather than routing them) fails here.
      * `live-behind` -- the warn branch, and the reason this case cannot be all-clears. A live doc
        below schema must still raise `doc.schema.behind`; without this board the whole finding
        could be dead code and every other assertion here would still pass. It then runs the very
        command the warning names and asserts the all-clear, which is the assertion the second
        defect above would have failed: advice a check gives has to work when followed.
      * `all-current` -- nothing stripped anywhere, so the all-clear fires and no archive line does.
        A warn is then evidence of a real condition rather than a check that always fires.

    Self-contained; ignores the passed fixture.
    """
    import shutil
    import tempfile

    e = []
    base = Path(tempfile.mkdtemp(prefix="handoff-schema-behind-"))

    def strip_schema(doc: Path) -> bool:
        """Remove the `schema:` frontmatter line, making the doc read as pre-schema (0)."""
        if not doc.is_file():
            return False
        kept = [
            ln
            for ln in doc.read_text().splitlines(True)
            if not ln.startswith("schema:")
        ]
        doc.write_text("".join(kept))
        return True

    def scaffold(name: str) -> Path:
        """A git repo with a board installed and one live doc left at the current schema.

        The live doc matters on every board here: one where EVERYTHING is behind would warn no
        matter which branch ran, and one with no live doc at all cannot show an all-clear.
        """
        repo = base / name
        (repo / "src").mkdir(parents=True)
        (repo / "AGENTS.md").write_text("# AGENTS\n")
        (repo / "src/app.js").write_text("// app\n")
        gc.git_init_commit(repo)
        r = _run(
            ["bash", str(SETUP), str(repo), "--tools", "claude", "--primary", "claude"],
            repo,
        )
        e.append(
            gc.expectation(
                f"[{name}] install scaffolds a board",
                r.returncode == 0,
                f"exit {r.returncode}: {r.stderr.strip()[:120]}",
            )
        )
        _handoff(repo, "new", "live", "--title", "Live doc at the current schema")
        return repo

    try:
        for case, doc_args in (
            ("archived-coordination", []),
            ("archived-standalone", ["--standalone"]),
        ):
            tag = f"[{case}]"
            repo = scaffold(case)
            board = repo / HD
            _handoff(
                repo,
                "new",
                "closed",
                *doc_args,
                "--title",
                "Closed doc, later stripped",
            )
            rel = ["release", "closed", "--status", "done"]
            if not doc_args:  # a coordination doc needs evidence to close
                rel += ["--verified-by", "harness"]
            _handoff(repo, *rel)

            archived = board / "archive/closed-handoff.md"
            e.append(
                gc.expectation(
                    f"{tag} the closed doc archived",
                    archived.is_file(),
                    f"exists: {archived.is_file()}",
                )
            )
            e.append(
                gc.expectation(
                    f"{tag} its schema stamp was stripped",
                    strip_schema(archived),
                    f"stripped: {archived.is_file()}",
                )
            )
            e.append(
                gc.expectation(
                    f"{tag} the live doc still carries schema",
                    "schema:" in (board / "live-handoff.md").read_text(),
                    "live doc frontmatter",
                )
            )

            findings = gc.verify_findings(VERIFY, repo)
            # THE regression assertion. The buggy verifier does not merely miscount the archived
            # coordination doc -- it never reaches the count at all, so this id is simply absent.
            e.append(
                gc.finding(
                    findings,
                    "board.schema.archive",
                    "pass",
                    label=f"{tag} the archived doc below schema is counted onto the archive line",
                )
            )
            # ...and it is NOT folded into the live warning, whose remedy could not reach it.
            e.append(
                gc.expectation(
                    f"{tag} an archived doc alone does not raise the live behind warning",
                    "doc.schema.behind" not in findings,
                    (
                        "doc.schema.behind absent"
                        if "doc.schema.behind" not in findings
                        else f"reported: {findings['doc.schema.behind']}"
                    ),
                )
            )

        # The warn branch, and the advice it gives, end to end.
        behind = scaffold("live-behind")
        board = behind / HD
        _handoff(behind, "new", "stale", "--title", "Live doc, later stripped")
        e.append(
            gc.expectation(
                "[live-behind] the live doc's schema stamp was stripped",
                strip_schema(board / "stale-handoff.md"),
                "stripped",
            )
        )
        findings = gc.verify_findings(VERIFY, behind)
        e.append(
            gc.finding(
                findings,
                "doc.schema.behind",
                "warn",
                label="[live-behind] a live doc below schema still warns",
            )
        )
        e.append(
            gc.expectation(
                "[live-behind] the all-clear does NOT fire while a live doc is behind",
                "doc.schema" not in findings,
                (
                    "doc.schema absent"
                    if "doc.schema" not in findings
                    else f"doc.schema reported: {findings['doc.schema']}"
                ),
            )
        )
        # Run the command the warning names. Before the split this board's archived-doc equivalent
        # warned and migrate left it exactly as it was; the point of the split is that following
        # the advice now clears the finding.
        r = _handoff(behind, "migrate", "--yes")
        e.append(
            gc.expectation(
                "[live-behind] './handoff migrate' -- the command the warning names -- succeeds",
                r.returncode == 0,
                f"exit {r.returncode}: {(r.stderr or r.stdout).strip()[:160]}",
            )
        )
        findings = gc.verify_findings(VERIFY, behind)
        e.append(
            gc.finding(
                findings,
                "doc.schema",
                "pass",
                label="[live-behind] after migrating, the all-clear fires",
            )
        )

        # And the check can still pass on a board where nothing was stripped: the all-clear fires
        # and the archive line stays silent, so neither finding is one that always fires.
        clean = scaffold("all-current")
        _handoff(
            clean, "new", "closed", "--title", "Closed doc, left at the current schema"
        )
        _handoff(
            clean, "release", "closed", "--status", "done", "--verified-by", "harness"
        )
        findings = gc.verify_findings(VERIFY, clean)
        e.append(
            gc.finding(
                findings,
                "doc.schema",
                "pass",
                label="[all-current] every live doc at schema reports the all-clear",
            )
        )
        e.append(
            gc.expectation(
                "[all-current] nothing behind in the archive, so no archive line",
                "board.schema.archive" not in findings,
                (
                    "board.schema.archive absent"
                    if "board.schema.archive" not in findings
                    else f"reported: {findings['board.schema.archive']}"
                ),
            )
        )
        return e
    finally:
        shutil.rmtree(base, ignore_errors=True)


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
        return subprocess.run(
            args,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            env={**os.environ, **(env_extra or {})},
        )

    try:
        for layout in ("subfolder", "prefix"):
            tag = f"[{layout}]"
            board = base / layout
            r = sh(
                [
                    "bash",
                    str(SETUP),
                    "--board-only",
                    str(board),
                    "--groups",
                    "auth,infra",
                    "--layout",
                    layout,
                ],
                base,
            )
            e.append(
                gc.expectation(
                    f"{tag} --board-only scaffolds a standalone board",
                    r.returncode == 0,
                    f"exit {r.returncode}: {r.stderr.strip()[:100]}",
                )
            )
            cfg = _board_json(board)
            e.append(
                gc.expectation(
                    f"{tag} board config records groups + layout",
                    cfg.get("groups") == ["auth", "infra"]
                    and cfg.get("groupLayout") == layout,
                    f"config={cfg!r}",
                )
            )
            ho = board / "handoff"

            def newdoc(group, hid, title):
                return sh(
                    ["bash", str(ho), "new", hid, "--title", title],
                    board,
                    {"HANDOFF_REPO": group, "HANDOFF_GROUP": group},
                )

            newdoc("auth", "login-fix", "Login fix")
            newdoc("infra", "node-drain", "Node drain")
            newdoc(
                "infra", "login-fix", "Infra login fix"
            )  # same id, different group — must not clash

            if layout == "subfolder":
                auth_doc = board / "auth" / "login-fix-handoff.md"
                infra_doc = board / "infra" / "login-fix-handoff.md"
                auth_idx = board / "auth" / "INDEX.md"
            else:
                auth_doc = board / "auth--login-fix-handoff.md"
                infra_doc = board / "infra--login-fix-handoff.md"
                auth_idx = board / "INDEX-auth.md"
            e.append(
                gc.expectation(
                    f"{tag} same id in two groups yields two distinct docs (no clash)",
                    auth_doc.is_file() and infra_doc.is_file(),
                    f"auth: {auth_doc.is_file()}, infra: {infra_doc.is_file()}",
                )
            )
            e.append(
                gc.expectation(
                    f"{tag} each group gets its own sub-index",
                    auth_idx.is_file(),
                    f"auth sub-index: {auth_idx.is_file()}",
                )
            )
            rollup = (
                (board / "INDEX.md").read_text()
                if (board / "INDEX.md").is_file()
                else ""
            )
            e.append(
                gc.expectation(
                    f"{tag} board roll-up lists both group sections",
                    "## auth" in rollup and "## infra" in rollup,
                    f"headings: {[ln for ln in rollup.splitlines() if ln.startswith('## ')]}",
                )
            )

            # section-scoped list: auth sees only its own section
            auth_list = sh(
                ["bash", str(ho), "list"],
                board,
                {"HANDOFF_REPO": "auth", "HANDOFF_GROUP": "auth"},
            ).stdout
            e.append(
                gc.expectation(
                    f"{tag} list from auth shows only the auth section",
                    "login-fix" in auth_list and "node-drain" not in auth_list,
                    f"list: {auth_list[:200]!r}",
                )
            )

            # section-scoped edit gate: claim in auth, then a stranger session is denied editing auth's doc
            sh(
                ["bash", str(ho), "claim", "login-fix", "mine"],
                board,
                {
                    "HANDOFF_REPO": "auth",
                    "HANDOFF_GROUP": "auth",
                    "HANDOFF_SESSION_ID": "owner",
                },
            )
            hk = board / "scripts/hooks.sh"
            deny = subprocess.run(
                ["bash", str(hk), "--kind", "pretool-edit", "--tool", "claude"],
                cwd=str(board),
                input=json.dumps(
                    {
                        "session_id": "stranger",
                        "tool_input": {"file_path": str(auth_doc)},
                    }
                ),
                capture_output=True,
                text=True,
                env={**os.environ, "HANDOFF_REPO": "auth", "HANDOFF_GROUP": "auth"},
            ).stdout
            e.append(
                gc.expectation(
                    f"{tag} the edit gate denies a stranger editing a claimed section doc",
                    '"permissionDecision": "deny"' in deny,
                    f"out: {deny[:120]!r}",
                )
            )

            # --blocked-on must resolve within the SECTION. Validating against the board root (which
            # holds no docs under either layout) rejected every blocker, making `blocked` unreachable
            # on a grouped board and pushing everyone onto the "external:" escape hatch, which opts
            # out of the unblock notification entirely.
            newdoc("auth", "blk", "Blocker")
            newdoc("auth", "dep", "Dependent")
            newdoc("infra", "otherblk", "Other-section blocker")
            aenv = {"HANDOFF_REPO": "auth", "HANDOFF_GROUP": "auth"}
            r = sh(
                [
                    "bash",
                    str(ho),
                    "release",
                    "dep",
                    "--status",
                    "blocked",
                    "--blocked-on",
                    "blk",
                ],
                board,
                aenv,
            )
            e.append(
                gc.expectation(
                    f"{tag} --blocked-on resolves a blocker inside the section",
                    r.returncode == 0,
                    f"exit {r.returncode}: {r.stderr.strip()[:120]}",
                )
            )
            r = sh(
                [
                    "bash",
                    str(ho),
                    "release",
                    "dep",
                    "--status",
                    "blocked",
                    "--blocked-on",
                    "nope-not-real",
                ],
                board,
                aenv,
            )
            e.append(
                gc.expectation(
                    f"{tag} --blocked-on still refuses a blocker that does not exist",
                    r.returncode != 0,
                    f"exit {r.returncode}",
                )
            )
            r = sh(
                [
                    "bash",
                    str(ho),
                    "release",
                    "dep",
                    "--status",
                    "blocked",
                    "--blocked-on",
                    "otherblk",
                ],
                board,
                aenv,
            )
            e.append(
                gc.expectation(
                    f"{tag} --blocked-on refuses a blocker in another section",
                    r.returncode != 0,
                    f"exit {r.returncode}",
                )
            )
            r = sh(
                [
                    "bash",
                    str(ho),
                    "release",
                    "blk",
                    "--status",
                    "done",
                    "--verified-by",
                    "grader",
                ],
                board,
                aenv,
            )
            e.append(
                gc.expectation(
                    f"{tag} closing the blocker surfaces the dependent as unblocked",
                    "Now unblocked" in r.stdout,
                    f"out: {r.stdout[-160:]!r}",
                )
            )

            e.extend(_scope_notice_expectations(sh, ho, board, tag))
        return e
    finally:
        shutil.rmtree(base, ignore_errors=True)


def grade(target, eval_id):
    gc.pre_state_hint(HERE, eval_id)
    graded, cleanup = gc.isolated_git_target(target)
    if graded != Path(target).resolve():
        print(
            f"[grade] isolated fixture to its own git root: {graded}", file=sys.stderr
        )
    try:
        return _grade(graded, eval_id)
    finally:
        cleanup()


def _grade(target, eval_id):
    if eval_id == "no-agents-md":
        r = _install(target, "--primary", "claude")
        return [
            gc.expectation(
                "installer REFUSES without AGENTS.md",
                r.returncode != 0,
                f"exit {r.returncode}: {r.stderr.strip()[:120]}",
            ),
            gc.no_fabrication(target, "AGENTS.md"),
            gc.no_fabrication(target, HD),
        ]

    if eval_id == "fresh":
        r = _install(target, "--primary", "claude")
        exps = [
            gc.expectation(
                "installer succeeds on a fresh repo",
                r.returncode == 0,
                f"exit {r.returncode}: {r.stderr.strip()[:120]}",
            )
        ]
        exps.append(gc.run_verify_script(VERIFY, target))
        exps.append(gc.contains(target, "AGENTS.md", "handoff:begin"))
        exps.append(gc.file_exists(target, f"{HD}/handoff"))
        exps.append(gc.file_exists(target, f"{HD}/scripts/hooks.sh"))
        return exps

    if eval_id == "claude-wired":
        exps = [gc.run_verify_script(VERIFY, target)]
        exps.append(
            gc.contains(
                target,
                CLAUDE_CFG,
                "pretool-edit",
                label="claude config has the hard-enforcement pretool deny gate",
            )
        )
        # Idempotency: a clean re-run must leave nothing dirty. --no-vendor-cli because this
        # fixture is the BARE half of the cold-clone pair — it ships the dispatcher and no CLI
        # copy, so a default (vendoring) re-run would add scripts/handoff-cli and read as drift.
        # The flag never removes an existing copy, so this is idempotent on a vendored board too.
        _install(target, "--primary", "claude", "--no-vendor-cli")
        exps.append(gc.git_diff_empty(target))
        return exps

    if eval_id == "advisory-wired":
        exps = [gc.run_verify_script(VERIFY, target)]
        exps.append(
            gc.not_contains(
                target,
                CLAUDE_CFG,
                "pretool-edit",
                label="advisory config has NO pretool deny gate",
            )
        )
        return exps

    if eval_id == "legacy-config":
        # A board still on the sourced shell `config`, with no JSON config at all. The installer
        # must migrate it, and every value must survive: the migration is worthless if it produces
        # a well-formed file with the wrong numbers in it. ttlHours is the one that proves it,
        # because the installer's own default (4) differs from the fixture's (8) -- so a value
        # that survives cannot have come from the default path.
        before = _read_shell_config(target)
        r = _install(target, "--primary", "claude")
        exps = [
            gc.expectation(
                "installer succeeds on a legacy-config board",
                r.returncode == 0,
                f"exit {r.returncode}: {r.stderr.strip()[:120]}",
            )
        ]
        exps.append(gc.run_verify_script(VERIFY, target))
        exps.append(gc.file_exists(target, f"{HD}/handoff.json"))
        exps.append(gc.json_roundtrip(target, f"{HD}/handoff.json"))
        after = _read_json_config(target)
        for key, want in (
            ("ttlHours", before.get("ttlHours")),
            ("topology", before.get("topology")),
        ):
            if want is None:
                continue
            exps.append(
                gc.expectation(
                    f"{key} survived the shell-to-JSON migration",
                    str(after.get(key)) == str(want),
                    f"legacy {key}={want!r} -> json {key}={after.get(key)!r}",
                )
            )
        # The legacy file is SUPERSEDED, not deleted: renamed to `config.superseded` so it can
        # never be read as authoritative again while still being there to recover from if the
        # migration got a value wrong. Asserting both halves — the rename happened AND nothing was
        # destroyed — is the whole claim; asserting only that `config` still exists (what this
        # used to do) now passes exactly when the migration has NOT run.
        exps.append(gc.file_exists(target, f"{HD}/config.superseded"))
        exps.append(
            gc.expectation(
                "the superseded legacy config is no longer readable as authoritative",
                not (Path(target) / HD / "config").exists(),
                f"{HD}/config present: {(Path(target) / HD / 'config').exists()}",
            )
        )
        return exps

    if eval_id == "legacy-install":
        r = _install(target, "--primary", "claude", "--migrate", ".claude/handoff")
        exps = [
            gc.expectation(
                "migration installer succeeds",
                r.returncode == 0,
                f"exit {r.returncode}: {r.stderr.strip()[:120]}",
            )
        ]
        exps.append(gc.file_exists(target, f"{HD}/legacy-open-handoff.md"))
        exps.append(gc.file_exists(target, f"{HD}/archive/legacy-done-handoff.md"))
        exps.append(
            gc.no_fabrication(target, ".claude/handoff")
        )  # legacy dir moved away
        cli = _resolved_cli(target)
        exps.append(
            gc.expectation(
                "the migrated board runs a CLI that writes session= (defect #1 fixed)",
                bool(cli)
                and "session=" in cli.read_text(encoding="utf-8", errors="replace"),
                (
                    f"resolved CLI: {cli}"
                    if cli
                    else "no CLI resolved for the migrated board"
                ),
            )
        )
        exps.append(gc.run_verify_script(VERIFY, target))
        return exps

    if eval_id == "detect":
        out = subprocess.run(
            ["bash", str(DETECT), str(target)], capture_output=True, text=True
        ).stdout
        return [
            gc.expectation(
                "detects the legacy install location",
                "FOUND .claude/handoff" in out,
                out[:200],
            ),
            gc.expectation(
                "classifies it as a legacy tool-path install",
                "kind=legacy-toolpath" in out,
                out[:200],
            ),
            gc.expectation(
                "flags the defective (pre-session=) version",
                "version=legacy" in out,
                out[:200],
            ),
            gc.expectation("counts its docs", "docs=2" in out, out[:200]),
            gc.expectation(
                "suggests migrating to current/parent/specific",
                "UPGRADE + MIGRATE" in out
                and "parent-level" in out
                and "specific location" in out,
                out[:300],
            ),
            gc.expectation(
                "reports one install detected", "Detected: 1 install" in out, out[-120:]
            ),
        ]

    if eval_id == "custom-location":
        r = _install(target, "--primary", "claude", "--handoff-dir", ".claude/handoff")
        exps = [
            gc.expectation(
                "installer succeeds with a custom --handoff-dir",
                r.returncode == 0,
                f"exit {r.returncode}: {r.stderr.strip()[:120]}",
            )
        ]
        exps.append(gc.file_exists(target, ".claude/handoff/handoff"))
        exps.append(
            gc.no_fabrication(target, ".agents/handoff")
        )  # used the custom location, not the default
        exps.append(
            gc.contains(
                target,
                ".gitignore",
                ".claude/handoff/.locks/",
                label="gitignore excludes the custom board's .locks/",
            )
        )
        exps.append(gc.run_verify_script(VERIFY, target))
        return exps

    if eval_id == "script-behavior":
        return grade_script_behavior(target)

    if eval_id == "schema-forward":
        return grade_schema_forward(target)

    if eval_id == "schema-board-ahead":
        return grade_schema_board_ahead(target)

    if eval_id == "payload-downgrade":
        return grade_payload_downgrade(target)

    if eval_id == "cli-unresolvable":
        return grade_cli_unresolvable(target)

    if eval_id == "board-override":
        return grade_board_override(target)

    if eval_id == "layout-migration":
        return grade_layout_migration(target)

    if eval_id == "custom-board-name":
        return grade_custom_board_name(target)

    if eval_id == "cross-repo":
        return grade_cross_repo(target)

    if eval_id == "grouped-board":
        return grade_grouped_board(target)

    if eval_id == "schema-behind":
        return grade_schema_behind(target)

    return [gc.run_verify_script(VERIFY, target)]


if __name__ == "__main__":
    code = gc.run_grader(grade, sys.argv[1:])
    if code == 2:
        print(__doc__)
    sys.exit(code)
