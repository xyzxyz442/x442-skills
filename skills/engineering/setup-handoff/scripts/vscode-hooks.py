#!/usr/bin/env python3
# vscode-hooks.py — point VS Code chat at this skill's Claude-format hooks (ADR 0024).
#
#   vscode-hooks.py --repo DIR --copilot-file REL --claude yes|no --covered yes|no --apply
#   vscode-hooks.py --repo DIR --copilot-file REL --claude yes|no --covered yes|no --check
#   vscode-hooks.py --selftest
#
# VS Code chat reads .github/hooks/*.json always, and the Claude-format files (.claude/settings.json,
# settings.local.json, ~/.claude/settings.json) only while chat.useClaudeHooks is on. Its
# chat.hookFilesLocations can switch off one file
# (https://code.visualstudio.com/docs/copilot/customization/hooks). When a repo commits
# Claude-format hooks, VS Code should run those, and the Copilot file should stay for Copilot CLI and
# the cloud agent, which reads nothing else.
#
#   --claude yes   this skill committed Claude-format hooks -> chat.useClaudeHooks: true
#   --covered yes  ...and they cover every hook kind in REL (Copilot is not the primary)
#                  -> REL: false in chat.hookFilesLocations. Otherwise our false is removed.
#
# Only REL is touched, never another file's entry, so setup-graph-hooks and setup-handoff cannot
# switch off each other's hooks. A true on REL is the user's and is left alone. A .vscode/settings.json
# that is JSONC is never rewritten (it would lose its comments): --apply prints what to add, exit 3.
# --check prints one "<ok|warn|fail> <finding-id> <message>" line and always exits 0.
#
# Ships byte-identical in setup-graph-hooks and setup-handoff; the selftest compares the two.
#
# Self-test:  python3 vscode-hooks.py --selftest
import argparse
import json
import os
import shutil
import sys
import tempfile

SETTINGS = ".vscode/settings.json"
USE_CLAUDE = "chat.useClaudeHooks"
LOCATIONS = "chat.hookFilesLocations"


class Unreadable(Exception):
    """The settings file exists but is not strict JSON (VS Code accepts JSONC)."""


def load(repo: str) -> dict:
    """The parsed settings, {} when absent. Raises Unreadable for JSONC or a non-object."""
    path = os.path.join(repo, SETTINGS)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise Unreadable(str(e)) from e
    if not isinstance(data, dict):
        raise Unreadable("top level is not an object")
    return data


def wanted(current: dict, rel: str, claude: bool, covered: bool) -> dict:
    """`current` with our two settings brought in line; every other key untouched."""
    out = dict(current)
    if claude:
        out[USE_CLAUDE] = True
    locs = out.get(LOCATIONS)
    locs = dict(locs) if isinstance(locs, dict) else None
    if claude and covered:
        locs = locs or {}
        locs[rel] = False
    elif locs is not None and locs.get(rel) is False:
        # Ours to take back: only a false can have come from us, and keeping it would leave this
        # file's hooks off in VS Code with nothing standing in for them.
        del locs[rel]
    if locs is not None:
        if locs:
            out[LOCATIONS] = locs
        else:
            out.pop(LOCATIONS, None)
    return out


def apply(repo: str, rel: str, claude: bool, covered: bool) -> int:
    """Write the settings when they change. 0 on success, 3 when the file is not strict JSON."""
    try:
        current = load(repo)
    except Unreadable:
        print(
            f"vscode-hooks: {SETTINGS} is not plain JSON (comments?) — left untouched. Add by hand:",
            file=sys.stderr,
        )
        print(json.dumps(wanted({}, rel, claude, covered), indent=2), file=sys.stderr)
        return 3
    new = wanted(current, rel, claude, covered)
    if new == current:
        return 0
    path = os.path.join(repo, SETTINGS)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(new, indent=2) + "\n")
    return 0


def check(repo: str, rel: str, claude: bool, covered: bool) -> str:
    """One finding line: "<ok|warn|fail> <id> <message>"."""
    try:
        s = load(repo)
    except Unreadable:
        return f"warn vscode.unreadable {SETTINGS} is not plain JSON — confirm by hand that chat.useClaudeHooks is true and {rel} is false in chat.hookFilesLocations"
    locs = s.get(LOCATIONS) if isinstance(s.get(LOCATIONS), dict) else {}
    off = locs.get(rel) is False
    use = s.get(USE_CLAUDE) is True
    present = os.path.isfile(os.path.join(repo, rel))
    if off and not (claude and covered):
        return f"fail vscode.copilot_off_uncovered {rel} is switched off in VS Code but the committed Claude-format hooks do not cover it — teammates lose these hooks in VS Code chat; re-run the installer"
    if claude and present and not use:
        return f"warn vscode.claude_hooks_off chat.useClaudeHooks is not on, so VS Code chat runs {rel} instead of the committed Claude-format hooks; re-run the installer"
    if claude and covered and present and use and not off:
        return f"warn vscode.double_run VS Code chat runs both the Claude-format hooks and {rel}; re-run the installer to switch {rel} off there"
    return f"ok vscode.hook_source VS Code chat hook source matches ADR 0024 for {rel}"


def main(argv: list) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--copilot-file", required=True)
    ap.add_argument("--claude", choices=["yes", "no"], required=True)
    ap.add_argument("--covered", choices=["yes", "no"], required=True)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    claude, covered = a.claude == "yes", a.covered == "yes"
    if a.check:
        print(check(a.repo, a.copilot_file, claude, covered))
        return 0
    return apply(a.repo, a.copilot_file, claude, covered)


def _selftest() -> int:
    tmp = tempfile.mkdtemp(prefix="vscode-hooks-")
    graph = ".github/hooks/graph.json"
    try:

        def fresh(copilot: bool = False) -> str:
            d = tempfile.mkdtemp(dir=tmp)
            if copilot:
                os.makedirs(os.path.join(d, ".github/hooks"))
                open(os.path.join(d, graph), "w").close()
            return d

        def write(repo: str, data) -> None:
            os.makedirs(os.path.join(repo, ".vscode"), exist_ok=True)
            with open(os.path.join(repo, SETTINGS), "w") as f:
                f.write(data if isinstance(data, str) else json.dumps(data, indent=2))

        def read(repo: str) -> str:
            with open(os.path.join(repo, SETTINGS)) as f:
                return f.read()

        # Covered: Claude-format hooks on, and only OUR Copilot file switched off.
        r = fresh()
        assert apply(r, graph, claude=True, covered=True) == 0
        s = load(r)
        assert s["chat.useClaudeHooks"] is True, s
        assert s["chat.hookFilesLocations"] == {graph: False}, s

        # Every other key survives -- the user's, and the other skill's switch.
        r = fresh()
        write(
            r,
            {
                "editor.tabSize": 2,
                "chat.hookFilesLocations": {
                    "custom/hooks": True,
                    ".github/hooks/handoff.json": False,
                },
            },
        )
        apply(r, graph, claude=True, covered=True)
        s = load(r)
        assert s["editor.tabSize"] == 2, s
        assert s["chat.hookFilesLocations"] == {
            "custom/hooks": True,
            ".github/hooks/handoff.json": False,
            graph: False,
        }, s

        # Not covered (Copilot is the primary): our earlier false comes out, and an empty map with it.
        r = fresh()
        write(r, {"chat.hookFilesLocations": {graph: False}})
        apply(r, graph, claude=True, covered=False)
        s = load(r)
        assert "chat.hookFilesLocations" not in s, s
        assert s["chat.useClaudeHooks"] is True, s

        # A true the user set on our file is theirs: never removed, never flipped.
        r = fresh()
        write(r, {"chat.hookFilesLocations": {graph: True}})
        apply(r, graph, claude=False, covered=False)
        assert load(r)["chat.hookFilesLocations"] == {graph: True}

        # JSONC (comments, trailing comma) is refused untouched: rewriting would drop the comments.
        r = fresh()
        raw = '{\n  // mine\n  "editor.tabSize": 2,\n}\n'
        write(r, raw)
        assert apply(r, graph, claude=True, covered=True) == 3
        assert read(r) == raw

        # A re-run with nothing to change does not rewrite the file.
        r = fresh()
        apply(r, graph, claude=True, covered=True)
        before = os.stat(os.path.join(r, SETTINGS)).st_mtime_ns
        assert apply(r, graph, claude=True, covered=True) == 0
        assert os.stat(os.path.join(r, SETTINGS)).st_mtime_ns == before

        # A repo that does not wire Claude gets no .vscode/settings.json from us.
        r = fresh()
        apply(r, graph, claude=False, covered=False)
        assert not os.path.exists(os.path.join(r, SETTINGS))

        # check: the teammate regression -- our Copilot file off with no committed Claude twin.
        r = fresh(copilot=True)
        write(
            r,
            {"chat.useClaudeHooks": True, "chat.hookFilesLocations": {graph: False}},
        )
        got = check(r, graph, claude=False, covered=False)
        assert got.startswith("fail vscode.copilot_off_uncovered"), got

        # check: Claude committed and covering, but VS Code still reads only the Copilot file.
        r = fresh(copilot=True)
        got = check(r, graph, claude=True, covered=True)
        assert got.startswith("warn vscode.claude_hooks_off"), got

        # check: both on, Copilot file not switched off -> every hook runs twice in VS Code.
        r = fresh(copilot=True)
        write(r, {"chat.useClaudeHooks": True})
        got = check(r, graph, claude=True, covered=True)
        assert got.startswith("warn vscode.double_run"), got

        # check: the applied state is ok, and JSONC is a warning rather than a crash.
        r = fresh(copilot=True)
        apply(r, graph, claude=True, covered=True)
        got = check(r, graph, claude=True, covered=True)
        assert got.startswith("ok vscode.hook_source"), got
        r = fresh(copilot=True)
        write(r, "{ // x\n}")
        got = check(r, graph, claude=True, covered=True)
        assert got.startswith("warn vscode.unreadable"), got

        # check: no Copilot file of ours, nothing switched -> nothing to judge.
        r = fresh()
        got = check(r, graph, claude=True, covered=True)
        assert got.startswith("ok vscode.hook_source"), got

        # The two shipped copies must not drift: each skill installs on its own, so each carries
        # one, and a fix to either has to reach both.
        here = os.path.realpath(__file__)
        for sibling in (
            os.path.join(
                os.path.dirname(here),
                "../../../setup-handoff/scripts/vscode-hooks.py",
            ),
            os.path.join(
                os.path.dirname(here),
                "../../setup-graph-hooks/scripts/config/vscode-hooks.py",
            ),
        ):
            sibling = os.path.realpath(sibling)
            if sibling != here and os.path.isfile(sibling):
                with open(here, "rb") as a, open(sibling, "rb") as b:
                    assert a.read() == b.read(), f"{sibling} differs from {here}"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("vscode-hooks.py selftest: OK")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    raise SystemExit(main(sys.argv[1:]))
