#!/usr/bin/env python3
# portable-mcp.py — strip the machine-local paths `code-review-graph install` writes into the
# repo-level MCP configs, so the committed entry works on every checkout, not only this one.
#
#   .graph-hooks/portable-mcp.py [repo]            rewrite in place, print what changed
#   .graph-hooks/portable-mcp.py [repo] --check    report only: one "path<TAB>message" per finding
#   .graph-hooks/portable-mcp.py --selftest
#
# CRG's installer builds every server entry with `cwd` set to the absolute repo root it ran in
# (`_build_server_entry` in code_review_graph/skills.py), and falls back to the absolute path of
# its own interpreter as `command` when uvx is not on PATH. Three of the files it writes live in
# the repo and are normally committed — .mcp.json, .gemini/settings.json, .vscode/mcp.json — so the
# first commit after registering publishes one developer's home directory, and every teammate's
# server is pointed at a path that does not exist on their machine.
#
# Neither value is needed. `code-review-graph serve` with no cwd resolves the repo from the
# directory the client launched it in, walking up to the nearest .git (find_project_root), which is
# what a repo-level config means anyway. VS Code is the exception worth keeping explicit: it has a
# portable spelling, ${workspaceFolder}, so that file gets the variable instead of losing the key.
#
# Rewrites ONLY the code-review-graph entry — other servers in the same file are the user's — and
# only a cwd that resolves to THIS repo. A cwd pointing elsewhere is reported, never rewritten:
# that is a different defect (the server answers for another codebase) and embed-health.sh owns it.
# Writes only when the bytes change, so a re-run leaves `git status --porcelain` empty.
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

SERVER = "code-review-graph"
WORKSPACE_VAR = "${workspaceFolder}"
# (path, top-level key, how a repo-root cwd is written portably: None = drop the key)
MCP_FILES = (
    (".mcp.json", "mcpServers", None),
    (".gemini/settings.json", "mcpServers", None),
    (".vscode/mcp.json", "servers", WORKSPACE_VAR),
)


def _same_dir(a: str, b: str) -> bool:
    return os.path.realpath(os.path.expanduser(a)) == os.path.realpath(b)


def normalize(srv: dict, root: str, cwd_as, have_crg: bool):
    """Return (changes, leftovers) for one server entry, mutating srv in place."""
    changes, leftovers = [], []

    cwd = srv.get("cwd")
    if isinstance(cwd, str) and "${" not in cwd:
        if not os.path.isabs(os.path.expanduser(cwd)):
            pass  # relative: already portable
        elif _same_dir(cwd, root):
            if cwd_as is None:
                del srv["cwd"]
                changes.append("dropped machine-local cwd")
            else:
                srv["cwd"] = cwd_as
                changes.append("cwd -> %s" % cwd_as)
        else:
            leftovers.append("cwd %s points outside this repo — left as is" % cwd)

    # The interpreter fallback: <abs python> -m code_review_graph serve. Only rewrite it when the
    # console script is on PATH here, so the rewritten entry is at least known to start on this
    # machine; otherwise say so and leave a working entry alone.
    command, args = srv.get("command"), srv.get("args")
    if (
        isinstance(command, str)
        and os.path.isabs(command)
        and isinstance(args, list)
        and args[:2] == ["-m", "code_review_graph"]
    ):
        if have_crg:
            srv["command"], srv["args"] = SERVER, args[2:]
            changes.append("command %s -> %s" % (command, SERVER))
        else:
            leftovers.append(
                "command is the absolute interpreter path %s — install the %s console script "
                "(pipx install code-review-graph), then re-run" % (command, SERVER)
            )
    return changes, leftovers


def _git_ignored(root: str, path: str) -> bool:
    try:
        return (
            subprocess.run(
                ["git", "-C", root, "check-ignore", "-q", path],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode
            == 0
        )
    except OSError:
        return False


def _load(path: str):
    """Return (raw, doc); doc is None when the file is not plain JSON."""
    try:
        with open(path, encoding="utf-8") as f:
            raw = f.read()
    except OSError:
        return "", None
    try:
        return raw, json.loads(raw)
    except ValueError:
        return raw, None


def _report(rel: str, changes, leftovers, out) -> int:
    for msg in changes:
        print("%s\t%s would be %s" % (rel, SERVER, msg), file=out)
    for msg in leftovers:
        print("%s\t%s" % (rel, msg), file=out)
    return len(changes) + len(leftovers)


def _apply(path: str, rel: str, raw: str, doc: dict, changes, leftovers, out) -> None:
    if changes:
        new = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
        if new != raw:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
        print("  ~ %s: %s" % (rel, "; ".join(changes)), file=out)
    for msg in leftovers:
        print("  ! %s: %s" % (rel, msg), file=out)


def run(root: str, check: bool, have_crg: bool, out=sys.stdout) -> int:
    findings = 0
    for rel, top, cwd_as in MCP_FILES:
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            continue
        raw, doc = _load(path)
        if doc is None:
            # JSONC (comments, trailing commas) is legal in some of these files. Rewriting it through
            # json.dumps would drop the comments, so leave it and say what to change by hand.
            if SERVER in raw:
                findings += _report(
                    rel,
                    [],
                    ["not plain JSON — check its %s entry by hand" % SERVER],
                    out,
                )
            continue
        srv = (doc.get(top) or {}).get(SERVER) if isinstance(doc, dict) else None
        if not isinstance(srv, dict):
            continue

        changes, leftovers = normalize(srv, root, cwd_as, have_crg)
        if not check:
            _apply(path, rel, raw, doc, changes, leftovers, out)
        elif (changes or leftovers) and not _git_ignored(root, rel):
            # An ignored file never leaves this machine, so a local path in it leaks nothing.
            findings += _report(rel, changes, leftovers, out)
    return findings


def selftest() -> int:
    failures = []

    def expect(cond, what):
        if not cond:
            failures.append(what)

    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.realpath(tmp)
        os.makedirs(os.path.join(root, ".vscode"))
        os.makedirs(os.path.join(root, ".gemini"))
        subprocess.run(["git", "init", "-q", root], check=True)
        entry = {
            "command": "uvx",
            "args": [SERVER, "serve"],
            "cwd": root,
            "type": "stdio",
        }
        other = {"command": "other-server", "cwd": root}
        docs = {
            ".mcp.json": {"mcpServers": {SERVER: dict(entry), "other": dict(other)}},
            ".vscode/mcp.json": {"servers": {SERVER: dict(entry)}},
            ".gemini/settings.json": {
                "hooks": {"x": 1},
                "mcpServers": {
                    SERVER: {
                        "command": "/opt/py/bin/python3",
                        "args": ["-m", "code_review_graph", "serve"],
                        "cwd": "/somewhere/else",
                    }
                },
            },
        }
        for rel, doc in docs.items():
            with open(os.path.join(root, rel), "w") as f:
                json.dump(doc, f, indent=2)

        def load(rel):
            with open(os.path.join(root, rel)) as f:
                return json.load(f)

        sink = open(os.devnull, "w")
        expect(
            run(root, check=True, have_crg=True, out=sink) == 4,
            "--check counts every finding",
        )
        expect("cwd" in load(".mcp.json")["mcpServers"][SERVER], "--check never writes")

        run(root, check=False, have_crg=True, out=sink)
        mcp = load(".mcp.json")["mcpServers"]
        expect("cwd" not in mcp[SERVER], ".mcp.json cwd dropped")
        expect(mcp[SERVER]["command"] == "uvx", "a portable command is left alone")
        expect(mcp["other"]["cwd"] == root, "another server's entry is never touched")
        expect(
            load(".vscode/mcp.json")["servers"][SERVER]["cwd"] == WORKSPACE_VAR,
            ".vscode/mcp.json cwd becomes ${workspaceFolder}",
        )
        gem = load(".gemini/settings.json")
        expect(
            gem["mcpServers"][SERVER]["cwd"] == "/somewhere/else",
            "a foreign cwd is reported, not rewritten",
        )
        expect(
            gem["mcpServers"][SERVER]["command"] == SERVER,
            "interpreter fallback -> console script",
        )
        expect(
            gem["mcpServers"][SERVER]["args"] == ["serve"],
            "interpreter args trimmed to the subcommand",
        )
        expect(gem["hooks"] == {"x": 1}, "unrelated keys survive")

        before = {rel: open(os.path.join(root, rel)).read() for rel in docs}
        run(root, check=False, have_crg=True, out=sink)
        after = {rel: open(os.path.join(root, rel)).read() for rel in docs}
        expect(before == after, "a second run is byte-stable")
        expect(
            run(root, check=True, have_crg=True, out=sink) == 1,
            "only the foreign cwd remains",
        )

        with open(os.path.join(root, ".gitignore"), "w") as f:
            f.write(".gemini/\n")
        expect(
            run(root, check=True, have_crg=True, out=sink) == 0,
            "an ignored file is not reported",
        )
        sink.close()

    for what in failures:
        print("FAIL: %s" % what)
    print("portable-mcp selftest: %d failed" % len(failures))
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("repo", nargs="?", default=".")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    try:
        root = subprocess.run(
            ["git", "-C", a.repo, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        print("not a git repository: %s" % a.repo, file=sys.stderr)
        return 2
    run(os.path.realpath(root), a.check, shutil.which(SERVER) is not None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
