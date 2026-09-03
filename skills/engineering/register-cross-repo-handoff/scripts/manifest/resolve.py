#!/usr/bin/env python3
# resolve.py — resolve the .handoff-repos.json cascade into ONE effective set of groups, their
# boards, and their member repos.
#
#   resolve.py --scope <dir> [--from <dir>]
#
# Layers, applied lowest -> highest precedence (exactly CLAUDE.md's load order). Unlike the graph
# skill this anchors on --scope, NOT a git root: a handoff manifest and its boards live at a
# workspace directory that is often not a git repo (e.g. ~/Work/Projects). Member/board paths
# resolve relative to the manifest that DECLARED them, so committed relative paths are portable.
#
#   1. user     ~/.agents/handoff-repos.json          (personal, this machine, not committed)
#   2. scope    <scope>/.handoff-repos.json           (the workspace manifest — the default)
#   3. subdir   <dir>/.handoff-repos.json for each dir strictly between <scope> and <from>, deepest last
#
# Merge is a pure ordered overlay keyed on the GROUP name: a nearer layer REPLACES the whole group
# (never a field-level merge), and a group value of {"remove": true} is a tombstone that un-inherits
# the group from a lower layer. Within the winning group's repo list, a member entry with
# {"remove": true} is dropped. Every shadowed group is reported so an override is never silent.
#
# Emits one JSON object on stdout. Read-only: this never writes anything, so both the sync and the
# verifier can call it and can never disagree about the effective set.
import argparse
import json
import os
import re
import subprocess
import sys

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")  # group names and repo aliases
# ONE filename at every layer. `.agents/handoff.json` is the same file the board and each member
# repo use — the layers are told apart by WHERE they sit, not by what they are called. The old
# `.handoff-repos.json` is still read, at LOWER precedence than the file that replaced it in the
# same directory, so an existing workspace keeps resolving until its manifest is moved.
MANIFEST = os.path.join(".agents", "handoff.json")
LEGACY_MANIFEST = ".handoff-repos.json"
USER_MANIFEST = os.path.join(os.path.expanduser("~"), ".agents", "handoff.json")
LEGACY_USER_MANIFEST = os.path.join(
    os.path.expanduser("~"), ".agents", "handoff-repos.json"
)
DEFAULT_LAYOUT = "subfolder"
VALID_LAYOUTS = ("subfolder", "prefix")


def _escapes(rel: str) -> bool:
    """True when a relative path leaves the directory it was computed against."""
    return rel == os.pardir or rel.startswith(os.pardir + os.sep)


def layer_files(scope: str, frm: str) -> list[tuple[str, str, bool]]:
    """(layer-name, manifest-path, committed?) lowest precedence first.

    Each directory contributes its legacy name first and its current one second, so a directory
    holding both resolves to the current file while a directory holding only the old one keeps
    working exactly as it did.
    """
    out: list[tuple[str, str, bool]] = [
        ("user", LEGACY_USER_MANIFEST, False),
        ("user", USER_MANIFEST, False),
    ]
    out.append(("scope", os.path.join(scope, LEGACY_MANIFEST), True))
    out.append(("scope", os.path.join(scope, MANIFEST), True))
    # every directory strictly between scope and `from`, scope -> leaf (deepest wins)
    #
    # A `from` OUTSIDE the scope contributes no directory layers at all. Skipping `..` components
    # and carrying on would rebuild the tail UNDER scope, so the cascade would read manifests out
    # of a tree the caller never named, silently and with no layer marked absent.
    rel = os.path.relpath(frm, scope)
    if rel not in (".", "") and not _escapes(rel):
        cur = scope
        for part in rel.split(os.sep):
            if part in ("", os.pardir):
                continue
            cur = os.path.join(cur, part)
            name = os.path.relpath(cur, scope)
            out.append((name, os.path.join(cur, LEGACY_MANIFEST), True))
            out.append((name, os.path.join(cur, MANIFEST), True))
    return out


def resolve_path(raw: str, manifest_dir: str) -> str:
    """expanduser -> expandvars -> resolve relative to the DECLARING manifest's dir -> realpath.

    Resolving against the declaring manifest's directory (not CWD) is what lets a committed
    manifest say "../api" and mean the same sibling checkout on every teammate's machine.
    """
    p = os.path.expandvars(os.path.expanduser(raw))
    if not os.path.isabs(p):
        p = os.path.join(manifest_dir, p)
    return os.path.realpath(p)


def head_commit_time(repo: str) -> "int | None":
    try:
        out = subprocess.run(
            ["git", "-C", repo, "log", "-1", "--format=%ct"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        return (
            int(out.stdout.strip())
            if out.returncode == 0 and out.stdout.strip()
            else None
        )
    except Exception:  # noqa: BLE001
        return None


def root_commit(repo: str) -> "str | None":
    """The repo's first commit — its durable identity.

    This is what a delegation brief's preflight checks, and what the board's repos.json records so
    the payload CLI can tell "the declared path still holds the declared repo" from "the declared
    path now holds something else". Unlike a remote URL it survives renames, remote moves, and
    mirror pushes, and a fork matching it is the correct answer because a fork is the same lineage.
    """
    try:
        out = subprocess.run(
            ["git", "-C", repo, "rev-list", "--max-parents=0", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        if out.returncode != 0:
            return None
        # A repo with multiple root commits (grafted/subtree history) lists them newest first;
        # take the last for the same reason repo_root_commit() in the payload CLI does.
        lines = [ln.strip() for ln in out.stdout.splitlines() if ln.strip()]
        return lines[-1] if lines else None
    except Exception:  # noqa: BLE001
        return None


def load_layer(
    path: str, errors: list, warnings: list
) -> "tuple[dict, str | None, str | None, str | None]":
    """Return (groups, default_board_raw, default_remote, layout), or empties if absent/bad.

    groups maps name -> either {"remove": True} or {"board_raw": str|None, "repos": [entry, ...]}.
    """
    if not os.path.exists(path):
        return {}, None, None, None
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception as e:  # noqa: BLE001
        errors.append(f"{path}: invalid JSON ({e})")
        return {}, None, None, None
    if not isinstance(data, dict):
        errors.append(f"{path}: expected a JSON object")
        return {}, None, None, None
    groups_val = data.get("groups")
    if not isinstance(groups_val, dict):
        # `groups` is shared with the board layer, where it is a bare LIST of section names — the
        # same fact at lower fidelity. A list here means "this file configures a board, it does not
        # declare a fleet", which is not an error: it simply contributes no groups.
        if groups_val is not None and not isinstance(groups_val, list):
            errors.append(f'{path}: "groups" must be a map of group name -> definition')
        return {}, None, None, None
    if data.get("version", 1) != 1:
        warnings.append(
            f"{path}: unknown version {data.get('version')!r} — parsing as version 1"
        )

    layout = data.get("layout")
    if layout is not None and layout not in VALID_LAYOUTS:
        errors.append(
            f"{path}: layout must be one of {list(VALID_LAYOUTS)} (got {layout!r})"
        )
        layout = None
    default_board = data.get("board") if isinstance(data.get("board"), str) else None
    # A board's remote is what makes it SHARED rather than merely versioned (ADR 0002). It is
    # declared here rather than discovered because the scaffold has to create the board before
    # anything could be discovered from it. Committed on purpose: a remote URL is the same for
    # every member, unlike a checkout path, which is exactly the distinction schema 2 of repos.json
    # draws. Never put credentials in it — use an SSH remote or a credential helper.
    default_remote = (
        data.get("boardRemote") if isinstance(data.get("boardRemote"), str) else None
    )

    groups: dict = {}
    for gname, gval in data["groups"].items():
        where = f"{path}[groups.{gname}]"
        if not NAME_RE.match(gname):
            errors.append(f"{where}: group name must match {NAME_RE.pattern}")
            continue
        if isinstance(gval, dict) and gval.get("remove"):
            groups[gname] = {"remove": True}
            continue
        if not isinstance(gval, dict) or not isinstance(gval.get("repos"), list):
            errors.append(
                f'{where}: expected an object with a "repos" array (or "remove": true)'
            )
            continue
        board_raw = gval.get("board") if isinstance(gval.get("board"), str) else None
        remote_raw = (
            gval.get("boardRemote")
            if isinstance(gval.get("boardRemote"), str)
            else None
        )
        repos, seen = [], set()
        for i, e in enumerate(gval["repos"]):
            rwhere = f"{where}.repos[{i}]"
            if not isinstance(e, dict):
                errors.append(f"{rwhere}: not an object")
                continue
            alias = e.get("alias")
            if not isinstance(alias, str) or not NAME_RE.match(alias):
                errors.append(
                    f"{rwhere}: alias must match {NAME_RE.pattern} (got {alias!r})"
                )
                continue
            if e.get("remove"):
                continue  # within-list tombstone: exclude this member from the group
            if alias in seen:
                warnings.append(
                    f"{where}: duplicate alias {alias!r} — the last one wins"
                )
            seen.add(alias)
            raw = e.get("path")
            if not isinstance(raw, str) or not raw:
                errors.append(f'{rwhere}: {alias!r} needs a "path" (or "remove": true)')
                continue
            audience = (
                e.get("audience")
                if isinstance(e.get("audience"), str) and e.get("audience")
                else alias
            )
            repos.append(
                {
                    "alias": alias,
                    "raw_path": raw,
                    "audience": audience,
                    "notes": (
                        e.get("notes", "") if isinstance(e.get("notes"), str) else ""
                    ),
                }
            )
        groups[gname] = {
            "board_raw": board_raw,
            "remote_raw": remote_raw,
            "repos": repos,
        }
    return groups, default_board, default_remote, layout


def _selftest() -> int:
    """python3 resolve.py --selftest

    The cascade decides which repos share a board and which section each one writes to, so an
    ordering or containment bug puts a repo's handoffs in another group's section — visible only
    as "my handoff vanished", long after the sync that did it.

    Deliberately the SAME cases as the other two cascade resolvers
    (register-cross-repo-graph, setup-delegate-agent): one shared contract, so a fix to any of the
    three should be mirrored to all three. The legacy-filename case is this module's own — it is
    the only one of the three carrying a pre-rename manifest name.
    """
    import tempfile

    # --- order: user is lowest, the deepest directory is highest -----------------------------
    got = layer_files("/ws", "/ws/a/b")
    assert [n for n, _, _ in got] == [
        "user",
        "user",
        "scope",
        "scope",
        "a",
        "a",
        "a/b",
        "a/b",
    ], got

    # --- legacy filename first, current second, WITHIN each directory ------------------------
    # A directory holding both resolves to the current file; one holding only the old name keeps
    # working. That only holds if legacy sorts LOWER, never higher.
    for i in range(0, len(got), 2):
        assert got[i][1].endswith(LEGACY_MANIFEST) or got[i][1].endswith(
            os.path.basename(LEGACY_USER_MANIFEST)
        ), got[i]
        assert got[i + 1][1].endswith(MANIFEST) or got[i + 1][1].endswith(
            os.path.basename(USER_MANIFEST)
        ), got[i + 1]

    # --- committed flags: only the user layers are uncommittable -----------------------------
    assert [c for _, _, c in got[:2]] == [
        False,
        False,
    ], "user layers are never committed"
    assert all(c is True for _, _, c in got[2:]), got

    # --- from == scope contributes no directory layers ---------------------------------------
    assert [n for n, _, _ in layer_files("/ws", "/ws")] == [
        "user",
        "user",
        "scope",
        "scope",
    ]

    # --- THE REGRESSION: a `from` outside the scope fabricates nothing ------------------------
    # `..` components used to be dropped and the tail rebuilt UNDER scope, so this returned
    # /other/sibling/repo — a manifest path in a tree nobody named.
    esc = layer_files("/other/sibling", "/repo")
    assert [n for n, _, _ in esc] == ["user", "user", "scope", "scope"], esc
    assert not any("/repo" in p for _, p, _ in esc), esc

    # --- resolve_path: relative resolves against the DECLARING manifest, not CWD --------------
    with tempfile.TemporaryDirectory() as td:
        td = os.path.realpath(td)
        os.makedirs(os.path.join(td, "ws", "member"))
        os.makedirs(os.path.join(td, "ws", "acme-lib"))
        decl = os.path.join(td, "ws", "member")
        assert resolve_path("../acme-lib", decl) == os.path.join(td, "ws", "acme-lib")
        assert resolve_path(os.path.join(td, "ws"), decl) == os.path.join(td, "ws")
        assert resolve_path("~", decl) == os.path.realpath(os.path.expanduser("~"))

    print("register-cross-repo-handoff resolve selftest OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scope", required=True)
    ap.add_argument("--from", dest="frm", default=None)
    args = ap.parse_args()

    scope = os.path.realpath(args.scope)
    frm = os.path.realpath(args.frm) if args.frm else scope

    errors: list = []
    warnings: list = []
    shadowed: list = []
    tombstones: list = []
    layers: list = []
    # group name -> {"layer","manifest","board_raw","repos","default_board_raw"}
    effective: dict = {}
    layout = None
    layout_from = None

    for name, file, committed in layer_files(scope, frm):
        present = os.path.exists(file)
        layers.append(
            {"layer": name, "file": file, "committed": committed, "present": present}
        )
        if not present:
            continue
        mdir = os.path.dirname(file)
        groups, default_board_raw, default_remote_raw, lay = load_layer(
            file, errors, warnings
        )
        if lay is not None:
            layout, layout_from = lay, file  # nearest layer that sets layout wins
        for gname, gval in groups.items():
            if gval.get("remove"):
                if effective.pop(gname, None) is not None:
                    tombstones.append({"group": gname, "layer": name, "manifest": file})
                else:
                    warnings.append(
                        f"{file}: tombstone {gname!r} removes nothing (no lower layer declares it)"
                    )
                continue
            if gname in effective:
                shadowed.append(
                    {
                        "group": gname,
                        "by_layer": name,
                        "was_layer": effective[gname]["layer"],
                    }
                )
            # whole-group replacement: the nearest layer's declaration wins entirely
            effective[gname] = {
                "layer": name,
                "manifest": file,
                "manifest_dir": mdir,
                "board_raw": gval["board_raw"],
                "default_board_raw": default_board_raw,
                "remote_raw": gval.get("remote_raw"),
                "default_remote_raw": default_remote_raw,
                "repos": gval["repos"],
            }
            for r in gval["repos"]:
                if (
                    committed
                    and os.path.isabs(r["raw_path"])
                    and not r["raw_path"].startswith("~")
                ):
                    warnings.append(
                        f"{file}: {gname}/{r['alias']} uses an absolute path — machine-specific in a "
                        f"committed manifest. Prefer a path relative to the manifest."
                    )

    if layout is None:
        layout = DEFAULT_LAYOUT

    # Resolve each group's board and hydrate its members + the board itself with on-disk facts the
    # shell must not discover for itself (bash never parses JSON). Board default: the group's own
    # `board`, else the manifest's top-level `board`, else <scope>/.agents/handoff.
    groups_out = []
    boards: dict = (
        {}
    )  # resolved board path -> {"path","groups":[...],"exists","has_payload"}
    for gname, g in sorted(effective.items()):
        mdir = g["manifest_dir"]
        if g["board_raw"]:
            board = resolve_path(g["board_raw"], mdir)
        elif g["default_board_raw"]:
            board = resolve_path(g["default_board_raw"], mdir)
        else:
            board = os.path.join(scope, ".agents", "handoff")
        board = os.path.realpath(board)
        members = []
        for r in g["repos"]:
            p = resolve_path(r["raw_path"], mdir)
            is_git = os.path.isdir(os.path.join(p, ".git")) or os.path.isfile(
                os.path.join(p, ".git")
            )
            exists = os.path.isdir(p)
            members.append(
                {
                    "alias": r["alias"],
                    "audience": r["audience"],
                    "notes": r["notes"],
                    "path": p,
                    "exists": exists,
                    "is_git": is_git,
                    "has_agents_md": os.path.isfile(os.path.join(p, "AGENTS.md")),
                    "writable": os.access(p, os.W_OK) if exists else None,
                    "head_ct": head_commit_time(p) if exists and is_git else None,
                    "root_commit": root_commit(p) if exists and is_git else None,
                }
            )
            if not exists:
                errors.append(
                    f"{g['manifest']}: {gname}/{r['alias']} -> {p} does not exist — excluded"
                )
        groups_out.append(
            {
                "group": gname,
                "layer": g["layer"],
                "manifest": g["manifest"],
                "board": board,
                "layout": layout,
                "members": members,
            }
        )
        b = boards.setdefault(
            board,
            {
                "path": board,
                "groups": [],
                "remote": "",
                "exists": os.path.isdir(board),
                "has_payload": os.path.isfile(os.path.join(board, "handoff"))
                and os.path.isfile(os.path.join(board, "scripts", "hooks.sh")),
            },
        )
        b["groups"].append(gname)
        # One board, one remote. Two groups sharing a board and declaring different remotes is a
        # manifest error, not something to pick a winner for: the loser's members would be wired to
        # a board that never receives their leases.
        remote = g.get("remote_raw") or g.get("default_remote_raw") or ""
        if remote and b["remote"] and remote != b["remote"]:
            errors.append(
                f"board {board}: groups declare conflicting boardRemote values "
                f"({b['remote']!r} vs {remote!r}) — one board has one remote"
            )
        elif remote:
            b["remote"] = remote

    json.dump(
        {
            "scope": scope,
            "from": frm,
            "layout": layout,
            "layout_from": layout_from,
            "layers": layers,
            "groups": groups_out,
            "boards": sorted(boards.values(), key=lambda b: b["path"]),
            "shadowed": shadowed,
            "tombstones": tombstones,
            "warnings": warnings,
            "errors": errors,
        },
        sys.stdout,
        indent=2,
    )
    sys.stdout.write("\n")
    return 1 if errors else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    raise SystemExit(main())
