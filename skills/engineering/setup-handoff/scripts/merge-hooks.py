#!/usr/bin/env python3
"""Merge the handoff hooks into a tool's settings JSON, without clobbering other keys.

Idempotent: every handoff hook command contains ``handoff/scripts/hooks.sh`` (or, on a board
wired before the layout restructure, ``handoff/hooks.sh``). On each run we first drop every
existing handoff-managed group — matching either spelling — then add the current set, so a re-run,
a change of primary tool, or a migration from the flat layout converges instead of duplicating.

Env (set by setup-handoff.sh):
  HANDOFF_HDPATH   path tools use to reach hooks.sh (e.g. ".agents/handoff")
  HANDOFF_TOOL     claude | gemini | copilot
  HANDOFF_PRIMARY  "1" for the hard-enforcement primary, else "0"

Usage:
  merge-hooks.py <settings.json>            # wire hooks for HANDOFF_TOOL
  merge-hooks.py <settings.json> --add-dir  # add the handoff dir to additionalDirectories (claude)
  merge-hooks.py <settings.json> --check    # 0 current, 2 drifted, 3 not wired; writes nothing
  merge-hooks.py --selftest                 # unit-check the managed-group predicate; writes nothing

No eval, no network — reads/writes one JSON file. Claude's schema is wired precisely;
Gemini/Copilot use their documented event names on a best-effort basis (the AGENTS.md
routing block is the behavioral guarantee for non-primary tools).
"""
from __future__ import annotations

import json
import os
import re
import shlex
import sys
from pathlib import Path

# Recognizing OUR hook group must be board-name-agnostic (a shared cross-repo board can be named
# handoff-auth, handoff-legacy, or a custom --handoff-dir) yet specific enough that strip_managed
# never deletes an UNRELATED group. So a current command is ours iff it invokes `/scripts/hooks.sh`
# AND carries handoff's own `--kind ` flag — both are present whether the path is quoted (claude:
# `…/scripts/hooks.sh" --kind`) or bare (gemini/copilot: `…/scripts/hooks.sh --kind`). Requiring BOTH
# is the guard: another tool merely living under some `scripts/hooks.sh` (without our `--kind …
# --tool …` protocol) is not touched. Neither the old name-specific "handoff/scripts/hooks.sh" (misses
# a differently-named board) nor a bare "/scripts/hooks.sh" (too broad) is safe alone.
CURRENT_PATH = "/scripts/hooks.sh"
KIND_FLAG = "--kind "
# Pre-restructure flat boards baked "<board>/hooks.sh" (no scripts/) and were always named "handoff".
LEGACY_MARKERS = ("handoff/hooks.sh",)


def is_managed(command: str) -> bool:
    """True iff `command` is one of OUR handoff hook invocations (any board name), never another tool's."""
    if CURRENT_PATH in command and KIND_FLAG in command:
        return True
    return any(m in command for m in LEGACY_MARKERS)


def load(path: Path) -> dict:
    if path.is_file():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            raise SystemExit(f"merge-hooks: {path} is not valid JSON; refusing to overwrite")
    return {}


def dump(path: Path, data: dict) -> None:
    """Write only when the DATA changed, comparing parsed JSON rather than bytes.

    The installer re-runs on every repair, and it used to rewrite each tool config
    unconditionally. In a repo that formats JSON (prettier collapses short arrays; we emit them
    expanded) that meant every single run dirtied the working tree with a diff carrying no
    semantic change -- which buries a real wiring change in noise and makes "re-run the installer"
    an unpleasant remedy. Comparing the parsed data instead of the text keeps the repo's own
    formatting and makes the install genuinely idempotent rather than idempotent-by-coincidence.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        if json.loads(path.read_text(encoding="utf-8")) == data:
            return
    except (OSError, ValueError):
        pass  # missing, unreadable, or not JSON -- fall through and write
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def command(hdpath: str, tool: str, kind: str) -> str:
    # Identity is NOT baked in here any more. It used to ride as a HANDOFF_REPO=... prefix, which
    # made normal operating configuration invisible to anyone reading the board and stale the
    # moment a repo was renamed. It now lives in the consuming repo's .agents/handoff.json
    # and hooks.sh discovers it. What the command still carries is an ANCHOR -- where the repo is,
    # never what it is configured to do -- so resolution stays deterministic instead of depending
    # on the tool's working directory.
    if tool == "claude":
        return (
            f'bash "$CLAUDE_PROJECT_DIR/{hdpath}/scripts/hooks.sh" '
            f'--kind {kind} --tool claude --project-dir "$CLAUDE_PROJECT_DIR"'
        )
    return f"bash {hdpath}/scripts/hooks.sh --kind {kind} --tool {tool}"


LEGACY_PREFIX = re.compile(r'^((?:HANDOFF_[A-Z_]+=(?:"[^"]*"|\'[^\']*\'|\S*)\s+)+)')


def parse_legacy_prefix(cmd: str) -> dict:
    """Pull the HANDOFF_*= assignments off the front of a managed hook command."""
    m = LEGACY_PREFIX.match(cmd)
    if not m:
        return {}
    out = {}
    for tok in shlex.split(m.group(1)):
        if "=" in tok:
            key, _, val = tok.partition("=")
            out[key] = val
    return out


def migrate_prefix(commands: list) -> tuple:
    """Return (repo_config, refusals). Refuses any command whose identity would change.

    A repo silently switching sections would file handoffs where nobody reads them, so a prefix
    that cannot be proven equivalent is LEFT IN PLACE rather than dropped.
    """
    found, refusals = {}, []
    for cmd in commands:
        env = parse_legacy_prefix(cmd)
        if not env:
            continue
        for key in ("HANDOFF_REPO", "HANDOFF_GROUP", "HANDOFF_HDPATH"):
            if key in env and found.setdefault(key, env[key]) != env[key]:
                refusals.append(
                    "%s differs across wired tools (%r vs %r) — leaving prefixes in place"
                    % (key, found[key], env[key])
                )
    if refusals:
        return {}, refusals
    cfg = {}
    if "HANDOFF_REPO" in found:
        cfg["repo"] = found["HANDOFF_REPO"]
    if found.get("HANDOFF_GROUP"):
        cfg["group"] = found["HANDOFF_GROUP"]
    if found.get("HANDOFF_HDPATH"):
        cfg["board"] = found["HANDOFF_HDPATH"]
    return cfg, []


def write_repo_config(repo_root: str, cfg: dict) -> None:
    """Write the consuming repo's own identity into .agents/handoff.json.

    One filename at every layer: this is the repo layer of the same cascade the board and the
    workspace manifest sit in. The predecessor, .agents/handoff.config.json, is still READ (see
    config.sh) and is carried forward here before being renamed aside, so an existing repo keeps
    its identity across the rename instead of silently filing unscoped.
    """
    path = os.path.join(repo_root, ".agents", "handoff.json")
    legacy = os.path.join(repo_root, ".agents", "handoff.config.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    existing = {}
    for src in (legacy, path):
        if os.path.isfile(src):
            try:
                with open(src) as fh:
                    loaded = json.load(fh)
                if isinstance(loaded, dict):
                    existing.update(loaded)
            except (ValueError, OSError):
                pass  # a hand-broken file must not stop the install; the writer below re-states it
    existing.update(cfg)
    with open(path, "w") as fh:
        json.dump(existing, fh, indent=2, sort_keys=True)
        fh.write("\n")
    # Renamed, never deleted — its contents are already merged above, and a `.superseded` suffix
    # is obvious and reversible where a delete is neither.
    if os.path.isfile(legacy):
        try:
            os.replace(legacy, legacy + ".superseded")
            print("  repo config moved to .agents/handoff.json "
                  "(.agents/handoff.config.json.superseded is safe to delete)")
        except OSError:
            pass


def env_repo_config() -> dict:
    """Build repo identity from setup-handoff.sh's live invocation env.

    migrate_prefix only recovers identity that already exists as a legacy prefix somewhere in
    the file -- a FRESH cross-repo install has no such prefix to recover, so without this it
    would end up with no identity anywhere (exactly the unscoped-filing failure the refusal
    guard exists to prevent). setup-handoff.sh always exports HANDOFF_REPO for a cross-repo
    install (empty for single-repo, which is why this intentionally contributes nothing there),
    plus HANDOFF_GROUP and HANDOFF_HDPATH (the board path) alongside it.
    """
    repo = os.environ.get("HANDOFF_REPO", "")
    if not repo:
        return {}
    cfg = {"repo": repo}
    grp = os.environ.get("HANDOFF_GROUP", "")
    if grp:
        cfg["group"] = grp
    hdpath_env = os.environ.get("HANDOFF_HDPATH", "")
    if hdpath_env:
        cfg["board"] = hdpath_env
    return cfg


def collect_managed_commands(data: dict) -> list:
    """Every command string from a handoff-managed hook group, across all wired events."""
    hooks = data.get("hooks")
    out = []
    if not isinstance(hooks, dict):
        return out
    for groups in hooks.values():
        for g in groups or []:
            if not isinstance(g, dict):
                continue
            for h in g.get("hooks", []) or []:
                cmd = h.get("command", "")
                if is_managed(cmd):
                    out.append(cmd)
    return out


def strip_managed(groups: list) -> list:
    """Drop any hook group that contains a handoff-managed command."""
    out = []
    for g in groups or []:
        hooks = g.get("hooks", []) if isinstance(g, dict) else []
        if any(is_managed(h.get("command", "")) for h in hooks):
            continue
        out.append(g)
    return out


# Which events each tool wires, and whether a matcher/deny applies.
# (event_name, kind, matcher_or_None). Primary adds the PreToolUse deny + Stop nag.
EDIT_MATCHER = "Edit|Write|MultiEdit"

SCHEMAS = {
    "claude": {
        "soft": [("SessionStart", "sessionstart", None), ("PostToolUse", "posttool-edit", EDIT_MATCHER)],
        "hard": [("PreToolUse", "pretool-edit", EDIT_MATCHER), ("Stop", "stop", None)],
    },
    # Gemini CLI: BeforeTool / AfterTool / SessionStart / AfterAgent (documented names).
    "gemini": {
        "soft": [("SessionStart", "sessionstart", None), ("AfterTool", "posttool-edit", EDIT_MATCHER)],
        "hard": [("BeforeTool", "pretool-edit", EDIT_MATCHER), ("AfterAgent", "stop", None)],
    },
    # GitHub Copilot: sessionStart / preToolUse / postToolUse / agentStop.
    "copilot": {
        "soft": [("sessionStart", "sessionstart", None), ("postToolUse", "posttool-edit", EDIT_MATCHER)],
        "hard": [("preToolUse", "pretool-edit", EDIT_MATCHER), ("agentStop", "stop", None)],
    },
}


def group(hdpath: str, tool: str, kind: str, matcher: str | None) -> dict:
    g: dict = {"hooks": [{"type": "command", "command": command(hdpath, tool, kind)}]}
    if matcher:
        g["matcher"] = matcher
    return g


def events_for(tool: str, primary: bool) -> list:
    """The (event, kind, matcher) triples this tool gets — soft always, hard only for the primary."""
    schema = SCHEMAS.get(tool)
    if not schema:
        raise SystemExit(f"merge-hooks: unknown tool {tool}")
    events = list(schema["soft"])
    if primary:
        events += schema["hard"]
    return events


def check(path: Path, hdpath: str, tool: str, primary: bool) -> int:
    """Compare the hook commands actually wired against the ones this skill would write now.

    A config is rewritten on every install, so it only goes stale when nobody re-runs the
    installer -- and nothing noticed, because the payload stamp covers the payload FILES, not
    the wiring written around them. That is how this repo ended up running hook commands with no
    `--project-dir` while the stamp read current. Same failure as the AGENTS.md routing block,
    same fix: compare content, not presence.

      0 current   2 drifted   3 not wired
    """
    actual = sorted(collect_managed_commands(load(path)))
    if not actual:
        return 3
    wanted = sorted(command(hdpath, tool, kind) for _ev, kind, _m in events_for(tool, primary))
    return 0 if actual == wanted else 2


def wire(path: Path, hdpath: str, tool: str, primary: bool) -> None:
    data = load(path)
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        hooks = {}
    events = events_for(tool, primary)
    # first strip ALL handoff-managed groups from every event (so dropping to advisory,
    # or switching primary, removes the old deny/stop entries)
    for ev in list(hooks.keys()):
        hooks[ev] = strip_managed(hooks[ev])
        if not hooks[ev]:
            del hooks[ev]
    for ev, kind, matcher in events:
        hooks.setdefault(ev, [])
        hooks[ev] = strip_managed(hooks[ev])
        hooks[ev].append(group(hdpath, tool, kind, matcher))
    data["hooks"] = hooks
    dump(path, data)


def add_dir(path: Path, hdpath: str) -> None:
    """Cross-repo: grant read/exec access to the shared handoff dir (Claude)."""
    data = load(path)
    dirs = data.get("permissions", {}).get("additionalDirectories")
    perms = data.setdefault("permissions", {})
    dirs = perms.setdefault("additionalDirectories", [])
    if hdpath not in dirs:
        dirs.append(hdpath)
    dump(path, data)


def _selftest() -> int:
    """python3 merge-hooks.py --selftest

    `strip_managed` decides what an installer is allowed to delete from a settings file the user
    and other skills also write. That predicate is a pure function over strings and it had no
    unit coverage; the sibling installer that answers the same question by replacing the whole
    "hooks" subtree destroys both — see hook-config-merge-clobber-handoff. These assertions pin
    the two halves that matter: ours is always recognized (whatever the board is named), and
    nobody else's ever is.
    """
    ours_claude = command("../.agents/handoff", "claude", "pretool-edit")
    ours_gemini = command(".agents/handoff", "gemini", "sessionstart")
    ours_named = command("../workspace/handoff-auth", "copilot", "stop")
    for cmd in (ours_claude, ours_gemini, ours_named):
        assert is_managed(cmd), f"must recognize our own hook: {cmd!r}"
    assert is_managed("bash handoff/hooks.sh --tool claude"), "legacy flat board must be recognized"

    # Nobody else's. A hook that merely lives under some scripts/hooks.sh, or merely says
    # "handoff", is NOT ours — deleting it would make this installer a source of data loss.
    for foreign in (
        'bash "$CLAUDE_PROJECT_DIR/.graph-hooks/hook.sh" --tool claude --kind pretool-shell',
        "bash tools/scripts/hooks.sh --stage pre-commit",
        "bash .agents/bin/consent-gate.sh --tool claude",
        "echo handoff",
        "",
    ):
        assert not is_managed(foreign), f"must NOT claim another tool's hook: {foreign!r}"

    # strip_managed removes only the groups carrying our commands, and preserves order + identity
    # of everything else — including a user's own group sitting in the same event.
    mine = {"matcher": EDIT_MATCHER, "hooks": [{"type": "command", "command": ours_claude}]}
    theirs = {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash .claude/mine.sh"}]}
    graph = {"hooks": [{"type": "command", "command":
                        'bash "$CLAUDE_PROJECT_DIR/.graph-hooks/hook.sh" --tool claude --kind endturn'}]}
    assert strip_managed([theirs, mine, graph]) == [theirs, graph], "strips ours, keeps theirs"
    assert strip_managed([theirs, graph]) == [theirs, graph], "nothing of ours, nothing removed"
    assert strip_managed([mine]) == [], "ours alone leaves an empty event"
    assert strip_managed([]) == [] and strip_managed(None) == [], "empty input is not an error"
    # Malformed entries are skipped, never crashed on: this runs against files humans hand-edit.
    assert strip_managed(["not-a-dict", {"no": "hooks"}]) == ["not-a-dict", {"no": "hooks"}]

    assert sorted(collect_managed_commands({"hooks": {"PreToolUse": [mine, theirs],
                                                      "SessionStart": [graph]}})) == [ours_claude]
    assert collect_managed_commands({}) == [] and collect_managed_commands({"hooks": []}) == []

    # A re-run must be a fixed point: wiring on top of an already-wired event replaces our group
    # rather than appending a second copy. (wire() strips before it appends; assert the pieces.)
    for tool in SCHEMAS:
        soft = events_for(tool, False)
        both = events_for(tool, True)
        assert len(both) > len(soft), f"{tool}: the primary must wire more than a bystander"
        assert soft == both[: len(soft)], f"{tool}: primary must ADD to the soft set, not reshape it"
        for ev, kind, matcher in both:
            g = group(".agents/handoff", tool, kind, matcher)
            assert strip_managed([g]) == [], f"{tool}/{kind}: we must recognize what we just wrote"
            assert ("matcher" in g) == bool(matcher), f"{tool}/{kind}: matcher presence"

    assert parse_legacy_prefix('HANDOFF_REPO=acme-api bash x/scripts/hooks.sh --kind stop') \
        == {"HANDOFF_REPO": "acme-api"}
    assert parse_legacy_prefix("bash x/scripts/hooks.sh --kind stop") == {}

    print("merge-hooks selftest OK")
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    path = Path(argv[0])
    hdpath = os.environ.get("HANDOFF_HDPATH", ".agents/handoff")
    if "--add-dir" in argv:
        add_dir(path, hdpath)
        return 0
    if "--check" in argv:
        return check(path, hdpath, os.environ.get("HANDOFF_TOOL", "claude"),
                     os.environ.get("HANDOFF_PRIMARY", "0") == "1")
    repo_root = None
    if "--repo-root" in argv:
        idx = argv.index("--repo-root")
        if idx + 1 >= len(argv):
            raise SystemExit("merge-hooks: --repo-root requires a value")
        repo_root = argv[idx + 1]
    # Extraction MUST happen before wire() (below) strips the managed hook groups -- strip_managed
    # drops the old HANDOFF_*=-prefixed commands entirely, and would take the prefixes with them.
    #
    # The refusal is ALL-OR-NOTHING for THIS file: migrate_prefix only ever sees the commands
    # collected from `path` (one file per invocation, one invocation per tool), so a conflict
    # here cannot suppress migration of a sibling tool's config, and a sibling's agreeing values
    # can never dilute a real conflict in this file into a false "no conflict". On a refusal we
    # return before wire() runs at all: no command rewrite, no prefix stripped, no --project-dir
    # anchor added, no config write. Half-migrating (anchor added, prefix gone, identity nowhere)
    # is the one outcome a re-run cannot recover from -- leaving the file exactly as it was,
    # still running its old working prefix, is what makes a later fix (or re-run once the
    # conflict is resolved by hand) safe.
    if repo_root is not None:
        commands = collect_managed_commands(load(path))
        migrated, refusals = migrate_prefix(commands)
        if refusals:
            for r in refusals:
                print(f"merge-hooks: refusing to migrate {path}: {r}", file=sys.stderr)
            print(f"merge-hooks: leaving {path} untouched -- resolve the conflict by hand, then re-run", file=sys.stderr)
            return 1
        # Live env (this run's actual installer knowledge) wins over migrated history for the
        # same key, but a migrated key the live env has no value for must survive the merge --
        # e.g. a legacy HANDOFF_GROUP recovered from history when this run carries none.
        live = env_repo_config()
        cfg = {**migrated, **live}
        if cfg:
            write_repo_config(repo_root, cfg)
    tool = os.environ.get("HANDOFF_TOOL", "claude")
    primary = os.environ.get("HANDOFF_PRIMARY", "0") == "1"
    wire(path, hdpath, tool, primary)
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    raise SystemExit(main(sys.argv[1:]))
