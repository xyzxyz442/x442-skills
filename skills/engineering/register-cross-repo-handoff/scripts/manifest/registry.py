#!/usr/bin/env python3
# registry.py — project a resolved cascade into ONE board's repos.json, the file the board's
# `handoff` CLI reads to answer "which repo does this handoff's `audience` mean?".
#
#   registry.py --resolved <resolve.py-output.json> --board <dir> [--write | --check]
#
# Why the projection exists at all: the payload CLI ships INSIDE the member repos and inside a
# repo-less shared board. It can reach neither this skill (to run resolve.py) nor the cascade's
# --scope, so it cannot resolve `.handoff-repos.json` for itself. The manifest's owner therefore
# writes the answer down where the CLI can read it. Before this file existed, `handoff export`
# guessed the target by sibling directory name and a same-named-but-unrelated sibling made a brief
# record that unrelated repo's REAL root commit under a fully confident preflight.
#
# Every entry is ATTESTED with the target's root commit as of this projection, and the CLI
# re-checks that attestation against the live repo. A path that no longer holds the repo it was
# declared for — a moved checkout, a hand-edited manifest, a registry never re-synced — fails closed
# to "unverified" instead of stamping a confident SHA for the wrong repo.
#
# A member with no attestable root commit (not on disk, not a git repo, no commits) gets NO entry:
# an unattestable entry would be exactly the guess this replaces.
#
# --write emits the file (atomically, and only when the bytes differ, so a no-op re-sync leaves
# `git status` clean); --check compares without writing and exits 1 on drift. Both go through
# build(), so the sync and the verifier can never disagree about what the file should contain.
import argparse
import json
import os
import sys

FILENAME = "repos.json"


def build(resolved: dict, board: str) -> "tuple[str, list[str]]":
    """(file contents, warnings) for one board's repos.json."""
    board = os.path.realpath(board)
    entries: list = []
    warnings: list = []
    by_audience: dict = {}

    for g in resolved["groups"]:
        if os.path.realpath(g["board"]) != board:
            continue
        for m in g["members"]:
            where = "%s/%s" % (g["group"], m["alias"])
            if not m.get("root_commit"):
                reason = ("not on disk" if not m.get("exists")
                          else "not a git repo" if not m.get("is_git")
                          else "has no commits")
                warnings.append(
                    "no identity recorded for %s (%s) — cross-repo briefs targeting it will "
                    "render as unverified" % (where, reason))
                continue
            # Keyed by (group, audience), matching how the CLI resolves: a handoff only ever acts
            # within its caller's section, so two groups sharing one board may each have their own
            # "api" without either becoming ambiguous. A clash INSIDE one group is the real defect.
            by_audience.setdefault((g["group"], m["audience"]), []).append(where)
            entries.append({
                "group": g["group"],
                "alias": m["alias"],
                "audience": m["audience"],
                # Relative to the BOARD dir, so a committed board stays portable across machines.
                # The reader joins it back onto its own location, never onto a cwd.
                "path": os.path.relpath(m["path"], board),
                "rootCommit": m["root_commit"],
            })

    for (group, aud), wheres in sorted(by_audience.items()):
        if len(wheres) > 1:
            warnings.append(
                "audience %r is claimed twice inside group %r (%s) — `handoff export` refuses to "
                "pick between them and degrades to unverified; give them distinct audiences"
                % (aud, group, ", ".join(sorted(wheres))))

    # No timestamp and no scope path anywhere in the payload: a re-projection that changes nothing
    # must be byte-identical, or every board with a registry shows up dirty on each run.
    body = {"version": 1, "repos": sorted(entries, key=lambda e: (e["group"], e["alias"]))}
    return json.dumps(body, indent=2) + "\n", warnings


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--resolved", required=True, help="resolve.py output, or - for stdin")
    ap.add_argument("--board", required=True)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = ap.parse_args()

    src = sys.stdin if args.resolved == "-" else open(args.resolved)
    with src as fh:
        resolved = json.load(fh)

    want, warnings = build(resolved, args.board)
    dest = os.path.join(os.path.realpath(args.board), FILENAME)
    for w in warnings:
        print("%s: %s" % (dest, w), file=sys.stderr)

    try:
        with open(dest) as fh:
            have = fh.read()
    except OSError:
        have = None

    n = len(json.loads(want)["repos"])
    if args.check:
        if have is None:
            print("%s: missing — cross-repo briefs cannot resolve their target repo and will "
                  "render as unverified; re-run the sync" % dest)
            return 1
        if have != want:
            print("%s: drift from the manifest — re-run the sync" % dest)
            return 1
        print("%s: matches the manifest (%d repo(s))" % (dest, n))
        return 0

    if have == want:
        print("%s (%d repo(s), unchanged)" % (dest, n))
        return 0
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(want)
    os.replace(tmp, dest)
    print("%s (%d repo(s))" % (dest, n))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
