#!/usr/bin/env python3
"""register-delegate-agents — manage the delegation roster in an .agents/delegate.json layer.

    register-delegate-agents.py probe
    register-delegate-agents.py list          [--scope DIR]
    register-delegate-agents.py add           --name N --adapter A [...] [--layer DIR]
    register-delegate-agents.py remove        --name N [--layer DIR]
    register-delegate-agents.py set-primary   --name N [--layer DIR]
    register-delegate-agents.py set-default   --name N [--layer DIR]
    register-delegate-agents.py allow         --names a,b [--layer DIR]
    register-delegate-agents.py never         --paths 'p1,p2'  [--layer DIR]

`probe` and `list` are read-only. Everything else edits exactly one layer's manifest and prints
what changed; the caller decides which layer, and the default is your home directory.

Refuses to write `agents` into a layer inside a git work tree — the same rule the resolver
enforces, applied at the point of writing so the error arrives before the commit rather than after.
"""

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
from urllib.request import urlopen

MANIFEST = os.path.join(".agents", "delegate.json")
ADAPTERS = ("claude", "codex", "copilot", "gemini")
# Where each known local runtime listens, and what to ask it for a model list.
LOCAL_ENDPOINTS = (
    ("lmstudio", "http://127.0.0.1:1234/v1/models"),
    ("ollama", "http://127.0.0.1:11434/api/tags"),
)


def manifest_path(layer: str) -> str:
    return os.path.join(os.path.realpath(os.path.expanduser(layer)), MANIFEST)


def in_git_worktree(d: str) -> bool:
    try:
        r = subprocess.run(
            ["git", "-C", d, "rev-parse", "--is-inside-work-tree"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return r.returncode == 0 and r.stdout.strip() == "true"
    except Exception:  # noqa: BLE001
        return False


def load(path: str) -> dict:
    if not os.path.isfile(path):
        return {"version": 1}
    try:
        return json.load(open(path))
    except Exception as e:  # noqa: BLE001
        sys.exit(f"{path}: invalid JSON ({e}) — fix it by hand before editing")


def save(path: str, data: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    # The manifest names endpoints your code is shipped to. Even without a token in it, it is not
    # something to leave group-readable on a shared machine.
    os.chmod(path, 0o600)


def cmd_probe(_args) -> int:
    """Report what could be registered, without registering anything."""
    print("agent CLIs on PATH:")
    for a in ADAPTERS:
        p = shutil.which(a)
        print(f"  {a:<9} {p or 'not installed'}")

    print("\nlocal model runtimes:")
    for name, url in LOCAL_ENDPOINTS:
        try:
            with urlopen(url, timeout=2) as r:  # noqa: S310
                body = json.loads(r.read().decode())
            ids = [
                m.get("id") or m.get("name")
                for m in (body.get("data") or body.get("models") or [])
            ]
            print(f"  {name:<9} up — {len(ids)} model(s)")
            for i in ids[:8]:
                print(f"    - {i}")
        except (OSError, socket.timeout, ValueError):
            print(f"  {name:<9} not reachable")

    print("\nexisting delegate config dirs:")
    home = os.path.expanduser("~")
    found = False
    for entry in sorted(os.listdir(home)):
        d = os.path.join(home, entry)
        if not (
            entry.startswith(".claude")
            and os.path.isfile(os.path.join(d, "settings.json"))
        ):
            continue
        # ~/.claude is the PRIMARY session's own config. Registering it as a delegate would point
        # the sub-agent at the session you are already in — same weights, same quota, no isolation.
        if entry == ".claude":
            print(f"  {d}  (primary session config — not a delegate)")
            continue
        print(f"  {d}")
        found = True
    if not found:
        print("  none")
    print("\nNothing was written. Use `add` to register one.")
    return 0


def cmd_list(args) -> int:
    here = os.path.dirname(os.path.realpath(__file__))
    resolver = os.path.join(
        here, "..", "..", "setup-delegate-agent", "scripts", "manifest", "resolve.py"
    )
    resolver = os.path.realpath(resolver)
    if not os.path.isfile(resolver):
        sys.exit(f"resolver not found at {resolver}")
    r = subprocess.run(
        [sys.executable, resolver, "--scope", args.scope],
        capture_output=True,
        text=True,
    )
    data = json.loads(r.stdout or "{}")
    print(f"scope: {data.get('scope')}")
    print(
        f"primary: {data.get('primary') or 'unset'}   default: {data.get('default') or 'none'}"
    )
    if data.get("default_reason"):
        print(f"  note: {data['default_reason']}")
    print("\nlayers (nearest last):")
    for lay in data.get("layers", []):
        kind = "committable" if lay["committable"] else "local-only"
        print(f"  {kind:<12} {lay['file']}")
    print("\neffective agents:")
    for a in data.get("agents", []):
        print(f"  {a['name']:<14} {a['adapter']:<8} {a['party']:<12} {a['model']}")
        print(
            f"  {'':<14} tools={a['allow_tools']}  rounds={a['max_question_rounds']}  "
            f"declared in {a['layer']}"
        )
    for n in data.get("narrowed", []):
        print(f"\nnarrowed: {json.dumps(n)}")
    for w in data.get("warnings", []):
        print(f"warn: {w}")
    for e in data.get("errors", []):
        print(f"error: {e}")
    return 1 if data.get("errors") else 0


def cmd_add(args) -> int:
    path = manifest_path(args.layer)
    layer_dir = os.path.dirname(os.path.dirname(path))
    if in_git_worktree(layer_dir):
        sys.exit(
            f"{path} is inside a git work tree, so it may not define agents. A committed manifest "
            f"that could add an agent would add an egress target to every clone. Register it in "
            f"your home directory (the default) or a workspace directory outside any repo, and "
            f"use `allow` here to narrow instead."
        )
    if args.adapter not in ADAPTERS:
        sys.exit(f"--adapter must be one of {', '.join(ADAPTERS)}")
    if not (args.model or args.config_dir):
        sys.exit(
            "give --model, or --config-dir pointing at a settings.json that supplies one"
        )

    data = load(path)
    agents = data.setdefault("agents", {})
    entry = {"adapter": args.adapter}
    for key, val in (
        ("model", args.model),
        ("baseUrl", args.base_url),
        ("configDir", args.config_dir),
        ("localProvider", args.local_provider),
        ("vendor", args.vendor),
        ("notes", args.notes),
    ):
        if val:
            entry[key] = val
    if args.allow_tools:
        entry["allowTools"] = args.allow_tools
    verb = "updated" if args.name in agents else "added"
    agents[args.name] = entry
    data.setdefault("primary", "claude")
    save(path, data)
    print(f"{verb} {args.name!r} in {path}")
    print(json.dumps(entry, indent=2))
    print(
        "\nRun the setup-delegate-agent skill in a repo to wire it, or `list` to see the "
        "effective roster there."
    )
    return 0


def _edit(args, mutate, describe) -> int:
    path = manifest_path(args.layer)
    data = load(path)
    mutate(data)
    save(path, data)
    print(f"{describe} in {path}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("probe")
    p = sub.add_parser("list")
    p.add_argument("--scope", default=os.getcwd())

    p = sub.add_parser("add")
    p.add_argument("--name", required=True)
    p.add_argument("--adapter", required=True)
    p.add_argument("--model")
    p.add_argument("--base-url")
    p.add_argument("--config-dir")
    p.add_argument("--local-provider")
    p.add_argument("--vendor")
    p.add_argument("--allow-tools")
    p.add_argument("--notes")
    p.add_argument("--layer", default="~")

    for name in ("remove", "set-primary", "set-default"):
        p = sub.add_parser(name)
        p.add_argument("--name", required=True)
        p.add_argument("--layer", default="~")

    p = sub.add_parser("allow")
    p.add_argument("--names", required=True)
    p.add_argument("--layer", default=".")

    p = sub.add_parser("never")
    p.add_argument("--paths", required=True)
    p.add_argument("--layer", default=".")

    args = ap.parse_args()
    if args.cmd == "probe":
        return cmd_probe(args)
    if args.cmd == "list":
        return cmd_list(args)
    if args.cmd == "add":
        return cmd_add(args)
    if args.cmd == "remove":
        return _edit(
            args,
            lambda d: d.get("agents", {}).pop(args.name, None),
            f"removed {args.name!r}",
        )
    if args.cmd == "set-primary":
        return _edit(
            args, lambda d: d.update(primary=args.name), f"primary = {args.name!r}"
        )
    if args.cmd == "set-default":
        return _edit(
            args, lambda d: d.update(default=args.name), f"default = {args.name!r}"
        )
    if args.cmd == "allow":
        names = [n.strip() for n in args.names.split(",") if n.strip()]
        return _edit(args, lambda d: d.update(allow=names), f"allow = {names}")
    if args.cmd == "never":
        paths = [p.strip() for p in args.paths.split(",") if p.strip()]
        return _edit(
            args,
            lambda d: d.update(
                neverDelegate=sorted(set(d.get("neverDelegate", [])) | set(paths))
            ),
            f"neverDelegate += {paths}",
        )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
