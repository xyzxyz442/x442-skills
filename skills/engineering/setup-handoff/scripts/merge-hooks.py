#!/usr/bin/env python3
"""Merge the handoff hooks into a tool's settings JSON, without clobbering other keys.

Idempotent: every handoff hook command contains the marker ``handoff/hooks.sh``. On each
run we first drop every existing handoff-managed group, then add the current set — so a
re-run, or a change of primary tool, converges instead of duplicating.

Env (set by setup-handoff.sh):
  HANDOFF_HDPATH   path tools use to reach hooks.sh (e.g. ".agents/handoff")
  HANDOFF_TOOL     claude | gemini | copilot
  HANDOFF_PRIMARY  "1" for the hard-enforcement primary, else "0"

Usage:
  merge-hooks.py <settings.json>            # wire hooks for HANDOFF_TOOL
  merge-hooks.py <settings.json> --add-dir  # add the handoff dir to additionalDirectories (claude)

No eval, no network — reads/writes one JSON file. Claude's schema is wired precisely;
Gemini/Copilot use their documented event names on a best-effort basis (the AGENTS.md
routing block is the behavioral guarantee for non-primary tools).
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

MARKER = "handoff/hooks.sh"


def load(path: Path) -> dict:
    if path.is_file():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            raise SystemExit(f"merge-hooks: {path} is not valid JSON; refusing to overwrite")
    return {}


def dump(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def command(hdpath: str, tool: str, kind: str) -> str:
    # Claude expands $CLAUDE_PROJECT_DIR; keep the path anchored so cwd never matters.
    if tool == "claude":
        return f'bash "$CLAUDE_PROJECT_DIR/{hdpath}/hooks.sh" --kind {kind} --tool claude'
    return f'bash {hdpath}/hooks.sh --kind {kind} --tool {tool}'


def strip_managed(groups: list) -> list:
    """Drop any hook group that contains a handoff-managed command."""
    out = []
    for g in groups or []:
        hooks = g.get("hooks", []) if isinstance(g, dict) else []
        if any(MARKER in (h.get("command", "")) for h in hooks):
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


def wire(path: Path, hdpath: str, tool: str, primary: bool) -> None:
    data = load(path)
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        hooks = {}
    schema = SCHEMAS.get(tool)
    if not schema:
        raise SystemExit(f"merge-hooks: unknown tool {tool}")
    events = list(schema["soft"])
    if primary:
        events += schema["hard"]
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


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    path = Path(argv[0])
    hdpath = os.environ.get("HANDOFF_HDPATH", ".agents/handoff")
    if "--add-dir" in argv:
        add_dir(path, hdpath)
        return 0
    tool = os.environ.get("HANDOFF_TOOL", "claude")
    primary = os.environ.get("HANDOFF_PRIMARY", "0") == "1"
    wire(path, hdpath, tool, primary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
