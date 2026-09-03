#!/usr/bin/env python3
# render.py — single source of per-tool hook CONFIG (the install-time analog of emit.py).
#
#   render.py --tool <claude|gemini|copilot|antigravity> --primary <tool|none>
#
# Prints the native config object for the tool on stdout. The installer merges it into
# that tool's settings file (Claude/Gemini) or writes it as the whole file (Copilot/
# Antigravity). The end-of-turn refresh (`endturn`) is emitted ONLY when this tool is the
# chosen --primary refresh owner, so multiple wired tools never duplicate the graph build.
#
# Per-tool config schema + event names (sources cited in SKILL.md):
#   Claude Code   .claude/settings*.json  events Stop / PreToolUse(matcher) / SessionStart
#   Gemini CLI    .gemini/settings.json   events AfterAgent / BeforeTool(regex) / SessionStart, timeouts in ms
#   GitHub Copilot .github/hooks/graph.json version:1, events agentStop / preToolUse / sessionStart,
#                  command hooks use a "bash" SCRIPT PATH -> per-kind wrappers in .graph-hooks/copilot/
#   Antigravity   .agents/hooks.json  UNVERIFIED — emitted as an inert example, not activated.
#
# Self-test:  python3 render.py --selftest
import argparse
import json
import sys

# Inline resolver: find .graph-hooks/hook.sh repo-first (via the tool's project-dir env var
# when set, else git root, else PWD), then $HOME. Kept byte-identical across installs so
# Claude Code de-dupes it across user/project/local scopes. Tools that take a script PATH
# instead of a command string (Copilot) use the per-kind wrappers and skip this.
RESOLVE = (
    'R="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"; '
    'H="$R/.graph-hooks/hook.sh"; [ -f "$H" ] || H="$HOME/.graph-hooks/hook.sh"; '
    '[ -f "$H" ] && bash "$H"'
)


def cmd(tool: str, kind: str) -> str:
    return f'{RESOLVE} --tool {tool} --kind {kind} || true'


def claude(primary: bool) -> dict:
    hooks: dict = {
        "PostToolUse": [],
        "PreToolUse": [
            {"matcher": "Bash", "hooks": [
                {"type": "command", "command": cmd("claude", "pretool-shell"), "timeout": 6}]},
            {"matcher": "Read|Glob", "hooks": [
                {"type": "command", "command": cmd("claude", "pretool-read")}]},
        ],
        "SessionStart": [
            {"hooks": [
                {"type": "command", "command": cmd("claude", "sessionstart"), "timeout": 10}]},
        ],
    }
    if primary:
        hooks["Stop"] = [
            {"hooks": [
                {"type": "command", "command": cmd("claude", "endturn"), "timeout": 5}]},
        ]
    return {"hooks": hooks}


def gemini(primary: bool) -> dict:
    before = [
        {"matcher": "run_shell_command", "hooks": [
            {"type": "command", "command": cmd("gemini", "pretool-shell"), "timeout": 6000}]},
        {"matcher": "read_file|read_many_files|glob", "hooks": [
            {"type": "command", "command": cmd("gemini", "pretool-read"), "timeout": 6000}]},
    ]
    hooks: dict = {
        "BeforeTool": before,
        "SessionStart": [
            {"hooks": [
                {"type": "command", "command": cmd("gemini", "sessionstart"), "timeout": 10000}]},
        ],
    }
    if primary:
        hooks["AfterAgent"] = [
            {"hooks": [
                {"type": "command", "command": cmd("gemini", "endturn"), "timeout": 5000}]},
        ]
    return {"hooks": hooks}


def copilot(primary: bool) -> dict:
    base = ".graph-hooks/copilot"
    hooks: dict = {
        "preToolUse": [
            {"type": "command", "bash": f"{base}/pretool-shell.sh", "timeoutSec": 6},
            {"type": "command", "bash": f"{base}/pretool-read.sh", "timeoutSec": 6},
        ],
        "sessionStart": [
            {"type": "command", "bash": f"{base}/sessionstart.sh", "timeoutSec": 10},
        ],
    }
    if primary:
        hooks["agentStop"] = [
            {"type": "command", "bash": f"{base}/endturn.sh", "timeoutSec": 5},
        ]
    return {"version": 1, "hooks": hooks}


def antigravity(primary: bool) -> dict:
    # UNVERIFIED contract — emitted as an inert .example only; the installer never activates
    # it. Best-effort mirror of the Claude/Gemini snake_case-in / permissionDecision-out shape
    # reported by secondary sources. TODO(antigravity-hooks): confirm against a live install.
    hooks: dict = {
        "_UNVERIFIED": "Antigravity hook contract is not yet confirmed; do not activate as-is.",
        "PreToolUse": [
            {"matcher": "run_command", "hooks": [
                {"type": "command", "command": cmd("antigravity", "pretool-shell")}]},
        ],
        "SessionStart": [
            {"hooks": [
                {"type": "command", "command": cmd("antigravity", "sessionstart")}]},
        ],
    }
    if primary:
        hooks["Stop"] = [
            {"hooks": [
                {"type": "command", "command": cmd("antigravity", "endturn")}]},
        ]
    return {"hooks": hooks}


RENDERERS = {
    "claude": claude,
    "gemini": gemini,
    "copilot": copilot,
    "antigravity": antigravity,
}


# The event each tool fires at end of turn. The single-refresh-owner invariant is stated once,
# here, so the selftest below asserts it per tool instead of restating four event names.
ENDTURN_EVENT = {
    "claude": "Stop",
    "gemini": "AfterAgent",
    "copilot": "agentStop",
    "antigravity": "Stop",
}


def _selftest() -> int:
    """python3 render.py --selftest

    The single-refresh-owner invariant is the whole reason --primary exists: N wired tools must
    trigger ONE graph build per turn, not N. verify-graph-hooks.sh asserts it against an installed
    repo, which means it can only ever catch it after a real install, on one machine, for whatever
    combination that repo happens to have. These are the same assertion over every tool and every
    primary, in milliseconds.
    """
    for tool, renderer in RENDERERS.items():
        ev = ENDTURN_EVENT[tool]

        owner = renderer(True)["hooks"]
        assert ev in owner and owner[ev], f"{tool} as primary must own the end-of-turn refresh"
        assert "endturn" in json.dumps(owner[ev]), f"{tool} primary {ev} must run the endturn kind"

        bystander = renderer(False)["hooks"]
        assert not bystander.get(ev), f"{tool} not primary must NOT own the end-of-turn refresh"
        assert "endturn" not in json.dumps(bystander), \
            f"{tool} not primary must emit no endturn hook anywhere ({ev} is not the only way in)"

        # The read-side hooks are cheap and every wired tool gets them, primary or not — dropping
        # them for bystanders would silently un-steer every tool but one.
        # Every wired tool keeps the cheap read-side hooks whether or not it owns the refresh;
        # dropping them for bystanders would silently un-steer every tool but one. (Only the
        # shell + session hooks are universal — antigravity has no read matcher — and the
        # equality below covers the rest.)
        for kind in ("pretool-shell", "sessionstart"):
            assert kind in json.dumps(bystander), f"{tool} not primary still needs {kind}"

        # Whatever else differs, the ONLY difference between owner and bystander is the endturn
        # event. Anything else diverging means --primary is changing more than refresh ownership.
        assert {k: v for k, v in owner.items() if k != ev} == \
               {k: v for k, v in bystander.items() if k != ev}, \
            f"{tool}: --primary changed more than the {ev} event"

    # main()'s primary test is string equality, so a --primary naming an unwired tool leaves every
    # renderer a bystander — "none" and a typo both mean the git post-commit hook is the only owner.
    for primary in ("none", "not-a-tool", ""):
        owners = [t for t in RENDERERS if primary == t]
        assert owners == [], f"--primary {primary!r} must name no owner, got {owners}"

    print("render (graph-hooks config) selftest OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tool", required=True, choices=list(RENDERERS))
    ap.add_argument("--primary", default="none")
    args = ap.parse_args()
    is_primary = args.primary == args.tool
    print(json.dumps(RENDERERS[args.tool](is_primary), indent=2))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    raise SystemExit(main())
