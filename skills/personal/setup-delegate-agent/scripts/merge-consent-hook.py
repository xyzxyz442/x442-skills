#!/usr/bin/env python3
"""Merge the consent-gate hook into a tool's settings JSON, without clobbering other groups.

    merge-consent-hook.py <repo> <tool>     # wire the gate for claude | gemini | copilot
    merge-consent-hook.py --selftest        # unit-check the ownership predicate; writes nothing

This used to live inline in a setup-delegate-agent.sh heredoc. It was already ownership-aware --
it strips only groups whose command names consent-gate.sh -- but inline meant no assertion could
reach it, and the two sibling merges that answered the same question wrongly proved that an
unasserted predicate is how an installer becomes a source of data loss. See
hook-config-merge-clobber-handoff.

The file it writes is shared: on Claude, setup-handoff wires its own enforcement hooks into the
same .claude/settings.json, in the same PreToolUse event.
"""
from __future__ import annotations

import json
import pathlib
import sys

MARKER = "consent-gate.sh"

# (event, settings file). Copilot keeps its events at the top level of its own hook file; the
# others nest them under "hooks".
EVENT = {
    "claude": ("PreToolUse", ".claude/settings.json"),
    "gemini": ("BeforeTool", ".gemini/settings.json"),
    "copilot": ("preToolUse", ".github/hooks/delegate.json"),
}
MATCHER = "Bash|Read"


def command(tool: str) -> str:
    if tool == "claude":
        return f'bash "$CLAUDE_PROJECT_DIR/.agents/bin/{MARKER}" --tool {tool}'
    return f"bash .agents/bin/{MARKER} --tool {tool}"


def is_managed(group) -> bool:
    """True iff `group` carries OUR consent-gate command, never another skill's hook.

    Anything else in this file belongs to another skill or to the user -- setup-handoff's
    enforcement hooks share this event on Claude -- and rewriting it would make this installer a
    source of data loss.
    """
    if not isinstance(group, dict):
        return False
    return any(MARKER in (h.get("command") or "")
               for h in group.get("hooks", []) or [] if isinstance(h, dict))


def replace_managed(groups, ours: dict) -> list:
    """Refresh our group in the slot it already occupies; leave every other group where it is.

    Stripping ours and re-appending converges on content but never on order: setup-handoff
    appends into this same event, so each installer would walk its own group past the other's and
    dirty the tree on every run.
    """
    out, queued = [], [ours]
    for g in groups or []:
        if not is_managed(g):
            out.append(g)
        elif queued:
            out.append(queued.pop(0))
    return out + queued


def wire(repo: pathlib.Path, tool: str) -> str:
    """Write the gate into `tool`'s settings file. Returns the line to print."""
    if tool not in EVENT:
        raise SystemExit(f"  ! unknown tool {tool} — skipped")
    event, rel = EVENT[tool]
    path = repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    data = {}
    if path.exists():
        try:
            data = json.loads(path.read_text())
        except ValueError as e:
            raise SystemExit(f"  ! {rel} is not valid JSON ({e}) — refusing to rewrite it")
    hooks = data.setdefault("hooks", {}) if tool != "copilot" else data
    ours = {"matcher": MATCHER, "hooks": [{"type": "command", "command": command(tool)}]}
    hooks[event] = replace_managed(hooks.get(event, []), ours)
    new = json.dumps(data, indent=2) + "\n"
    if not path.exists() or path.read_text() != new:
        path.write_text(new)
        return f"  + {rel} ({event} consent gate)"
    return f"  = {rel} up to date"


def _selftest() -> int:
    """python3 merge-consent-hook.py --selftest

    Two halves, the same two every merge in this suite owes: ours is always recognized, and
    nobody else's ever is -- then the file-level consequence, that a re-run neither duplicates
    our group nor moves anybody else's.
    """
    import tempfile

    for tool in EVENT:
        assert is_managed({"hooks": [{"type": "command", "command": command(tool)}]}), \
            f"must recognize the gate we write for {tool}"

    for foreign in (
        {"hooks": [{"type": "command",
                    "command": 'bash "$CLAUDE_PROJECT_DIR/.agents/handoff/scripts/hooks.sh" '
                               '--kind pretool-edit --tool claude'}]},
        {"hooks": [{"type": "command", "command":
                    'H="$R/.graph-hooks/hook.sh"; bash "$H" --tool claude --kind pretool-shell'}]},
        {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash .claude/my-guard.sh"}]},
        {"hooks": [{"type": "command"}]},
        {"hooks": []},
        {},
        "not-a-dict",
    ):
        assert not is_managed(foreign), f"must NOT claim another tool's hook: {foreign!r}"

    theirs = {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash x.sh"}]}
    mine = {"matcher": MATCHER, "hooks": [{"type": "command", "command": command("claude")}]}
    assert replace_managed([theirs], mine) == [theirs, mine], "a first install appends"
    assert replace_managed([mine, theirs], mine) == [mine, theirs], "ours keeps its slot"
    assert replace_managed([theirs, mine], mine) == [theirs, mine], "and so does theirs"
    assert replace_managed([], mine) == [mine] and replace_managed(None, mine) == [mine]
    assert replace_managed(["junk", {"no": "hooks"}], mine) == ["junk", {"no": "hooks"}, mine], \
        "malformed entries are skipped, never crashed on — humans hand-edit these files"

    with tempfile.TemporaryDirectory() as tmp:
        repo = pathlib.Path(tmp)
        for tool in EVENT:
            event, rel = EVENT[tool]
            path = repo / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({"unrelated": True, "hooks": {event: [theirs]}}
                                       if tool != "copilot" else
                                       {"version": 1, event: [theirs]}, indent=2) + "\n")
            assert wire(repo, tool).startswith("  +"), f"{tool}: a first wiring writes"
            before = path.read_text()
            assert wire(repo, tool).startswith("  ="), f"{tool}: a re-run reports no change"
            assert path.read_text() == before, f"{tool}: a re-run is byte-identical"

            data = json.loads(before)
            groups = (data["hooks"] if tool != "copilot" else data)[event]
            assert theirs in groups, f"{tool}: another skill's group must survive"
            assert sum(is_managed(g) for g in groups) == 1, f"{tool}: exactly one gate, never two"

            # Another installer appends after ours; our next run must not jump the queue.
            groups.append({"hooks": [{"type": "command", "command": "bash .agents/other.sh"}]})
            path.write_text(json.dumps(data, indent=2) + "\n")
            reordered = path.read_text()
            wire(repo, tool)
            assert path.read_text() == reordered, \
                f"{tool}: a re-run must not reorder groups another installer placed around ours"

        bad = repo / ".gemini/settings.json"
        bad.write_text("{not json")
        try:
            wire(repo, "gemini")
        except SystemExit as e:
            assert "refusing to rewrite" in str(e)
        else:
            raise AssertionError("hand-broken JSON must be refused, never overwritten")
        assert bad.read_text() == "{not json", "and left exactly as it was"

    print("merge-consent-hook selftest OK")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    print(wire(pathlib.Path(sys.argv[1]), sys.argv[2]))
