#!/usr/bin/env python3
# resolve.py — resolve the .graph-repos.json cascade into ONE effective set of foreign repos.
#
#   resolve.py --scope <dir> --root <git-root> [--registry <path>]
#
# Layers, applied lowest -> highest precedence (exactly CLAUDE.md's load order):
#
#   1. user     ~/.code-review-graph/graph-repos.json   (personal, this machine, not committed)
#   2. project  <root>/.graph-repos.json                (committed, team-shared)
#   3. subdir   <dir>/.graph-repos.json for each dir from <root> down to <scope>, deepest last
#
# Merge is a pure ordered overlay keyed on `alias`: a nearer layer REPLACES the whole entry
# (never a field-level merge — that would let a subdir inherit a stale `path` while overriding
# `tools`), and `{"alias": "x", "remove": true}` is a tombstone that un-inherits an alias from a
# lower layer. Every shadowed entry is reported so an override is never silent.
#
# Emits one JSON object on stdout. Read-only: this never writes anything, so both the installer
# and the verifier can call it and can never disagree about the effective set.
import argparse
import json
import os
import re
import subprocess
import sys

ALIAS_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
VALID_TOOLS = ("crg", "graphify")
MANIFEST = ".graph-repos.json"
USER_MANIFEST = os.path.join(os.path.expanduser("~"), ".code-review-graph", "graph-repos.json")
# CRG owns registry.json and watch.toml in that same directory. graph-repos.json is OURS and must
# never be confused with them; the verifier asserts registry.json still has CRG's shape.


def layer_files(scope: str, root: str) -> list[tuple[str, str, bool]]:
    """(layer-name, manifest-path, committed?) lowest precedence first."""
    out: list[tuple[str, str, bool]] = [("user", USER_MANIFEST, False)]
    out.append(("project", os.path.join(root, MANIFEST), True))
    # every directory strictly between root and scope, root -> leaf (deepest wins)
    rel = os.path.relpath(scope, root)
    if rel not in (".", ""):
        cur = root
        for part in rel.split(os.sep):
            if part in ("", os.pardir):
                continue
            cur = os.path.join(cur, part)
            out.append((os.path.relpath(cur, root), os.path.join(cur, MANIFEST), True))
    return out


def resolve_path(raw: str, manifest_dir: str) -> str:
    """expanduser -> expandvars -> resolve relative to the manifest that DECLARED it -> realpath.

    Resolving against the declaring manifest's directory (not CWD, not the repo root) is what lets
    a committed project manifest say "../acme-api" and mean the same sibling checkout on every
    teammate's machine.
    """
    p = os.path.expandvars(os.path.expanduser(raw))
    if not os.path.isabs(p):
        p = os.path.join(manifest_dir, p)
    # realpath: CRG's registry is path-keyed, so a symlinked vs real path would double-register.
    return os.path.realpath(p)


def head_commit_time(repo: str) -> int | None:
    try:
        out = subprocess.run(
            ["git", "-C", repo, "log", "-1", "--format=%ct"],
            capture_output=True, text=True, timeout=10, check=False,
        )
        return int(out.stdout.strip()) if out.returncode == 0 and out.stdout.strip() else None
    except Exception:  # noqa: BLE001
        return None


def load_layer(path: str, errors: list[str], warnings: list[str]) -> list[dict]:
    if not os.path.exists(path):
        return []
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception as e:  # noqa: BLE001
        errors.append(f"{path}: invalid JSON ({e})")
        return []
    if not isinstance(data, dict) or not isinstance(data.get("repos"), list):
        errors.append(f"{path}: expected an object with a \"repos\" array")
        return []
    if data.get("version", 1) != 1:
        warnings.append(f"{path}: unknown version {data.get('version')!r} — parsing as version 1")

    entries, seen = [], set()
    for i, e in enumerate(data["repos"]):
        where = f"{path}[{i}]"
        if not isinstance(e, dict):
            errors.append(f"{where}: not an object")
            continue
        alias = e.get("alias")
        if not isinstance(alias, str) or not ALIAS_RE.match(alias):
            errors.append(f"{where}: alias must match {ALIAS_RE.pattern} (got {alias!r})")
            continue
        if alias in seen:
            warnings.append(f"{path}: duplicate alias {alias!r} — the last one wins")
        seen.add(alias)
        if e.get("remove"):
            entries.append({"alias": alias, "remove": True})
            continue
        raw = e.get("path")
        if not isinstance(raw, str) or not raw:
            errors.append(f"{where}: {alias!r} needs a \"path\" (or \"remove\": true)")
            continue
        tools = e.get("tools", list(VALID_TOOLS))
        if not isinstance(tools, list) or not tools or any(t not in VALID_TOOLS for t in tools):
            errors.append(f"{where}: {alias!r} tools must be a non-empty subset of {list(VALID_TOOLS)}")
            continue
        entries.append({
            "alias": alias, "raw_path": raw, "tools": tools,
            "notes": e.get("notes", "") if isinstance(e.get("notes"), str) else "",
        })
    return entries


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scope", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--registry", default=os.path.join(
        os.path.expanduser("~"), ".code-review-graph", "registry.json"))
    args = ap.parse_args()

    scope = os.path.realpath(args.scope)
    root = os.path.realpath(args.root)

    errors: list[str] = []
    warnings: list[str] = []
    shadowed: list[dict] = []
    tombstones: list[dict] = []
    layers: list[dict] = []
    effective: dict[str, dict] = {}

    for name, file, committed in layer_files(scope, root):
        present = os.path.exists(file)
        layers.append({"layer": name, "file": file, "committed": committed, "present": present})
        if not present:
            continue
        mdir = os.path.dirname(file)
        for e in load_layer(file, errors, warnings):
            alias = e["alias"]
            if e.get("remove"):
                if effective.pop(alias, None) is not None:
                    tombstones.append({"alias": alias, "layer": name, "manifest": file})
                else:
                    warnings.append(f"{file}: tombstone {alias!r} removes nothing (no lower layer declares it)")
                continue
            if alias in effective:
                shadowed.append({
                    "alias": alias, "by_layer": name,
                    "was_layer": effective[alias]["layer"], "was_path": effective[alias]["path"],
                })
            path = resolve_path(e["raw_path"], mdir)
            if committed and os.path.isabs(e["raw_path"]) and not e["raw_path"].startswith("~"):
                warnings.append(
                    f"{file}: {alias!r} uses an absolute path — machine-specific in a committed "
                    f"manifest. Prefer a path relative to the manifest, or move it to the user layer."
                )
            effective[alias] = {
                "alias": alias, "path": path, "tools": e["tools"],
                "notes": e["notes"], "layer": name, "manifest": file,
            }

    # Hydrate each surviving entry with the on-disk facts the shell scripts need but must not
    # discover themselves (bash never parses JSON, and never stats a graph it might misread).
    # Emit only what a consumer actually reads: an unread field is a field that drifts, and the
    # whole point of this resolver is that the installer and the verifier cannot disagree.
    for e in effective.values():
        p = e["path"]
        db = os.path.join(p, ".code-review-graph", "graph.db")
        gj = os.path.join(p, "graphify-out", "graph.json")
        is_git = os.path.isdir(os.path.join(p, ".git")) or os.path.isfile(os.path.join(p, ".git"))
        e["exists"] = os.path.isdir(p)
        e["has_crg_db"] = os.path.isfile(db)
        e["has_gfy_json"] = os.path.isfile(gj)
        e["gfy_json"] = gj
        e["db_mtime"] = int(os.path.getmtime(db)) if e["has_crg_db"] else None
        e["gfy_mtime"] = int(os.path.getmtime(gj)) if e["has_gfy_json"] else None
        e["head_ct"] = head_commit_time(p) if e["exists"] and is_git else None
        e["writable"] = os.access(os.path.join(p, ".code-review-graph"), os.W_OK) if e["has_crg_db"] else None
        if not e["exists"]:
            errors.append(
                f"{e['manifest']}: {e['alias']!r} -> {p} does not exist "
                f"(repo moved or deleted?) — excluded from scope"
            )

    # Registry read-back. We never WRITE this file (always `code-review-graph register`), but the
    # block is rendered from what the registry actually holds, so it can never advertise an alias
    # the registry does not have.
    registry, registry_ok = [], True
    if os.path.exists(args.registry):
        try:
            with open(args.registry) as f:
                rdata = json.load(f)
            registry = rdata.get("repos", []) if isinstance(rdata, dict) else []
            if not isinstance(registry, list):
                registry, registry_ok = [], False
        except Exception:  # noqa: BLE001
            registry_ok = False

    live = [e for e in effective.values() if e["exists"]]
    json.dump({
        "scope": scope,
        "scope_rel": os.path.relpath(scope, root) if scope != root else ".",
        "root": root,
        "layers": layers,
        "effective": live,
        "dead": [e for e in effective.values() if not e["exists"]],
        "shadowed": shadowed,
        "tombstones": tombstones,
        "warnings": warnings,
        "errors": errors,
        "registry": registry,
        "registry_ok": registry_ok,
        "registry_path": args.registry,
    }, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
