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
# Every entry IS its target's root commit: identity is committed, location never is (ADR 0002).
# The CLI resolves that commit to a checkout on the machine it happens to be running on and
# re-checks the attestation there. A candidate that no longer holds the repo it was declared for —
# a moved checkout, a hand-edited manifest, a registry never re-synced — fails closed to
# "unverified" instead of stamping a confident SHA for the wrong repo.
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

# ONE file on the board. The registry used to be its own `repos.json`; it is now a key inside the
# board's `handoff.json`, under `_generated` — the block the sync owns and rewrites wholesale, kept
# apart from the hand-edited keys beside it so a re-sync can never clobber somebody's `ttlHours` and
# a hand-edit can never masquerade as a projection of the manifest.
FILENAME = "handoff.json"
LEGACY_FILENAME = "repos.json"
GENERATED_KEY = "_generated"


def load_board(board: str) -> dict:
    """The board's existing handoff.json, or the shape it should have if it has none yet.

    Read rather than overwritten because everything OUTSIDE `_generated` belongs to the installer
    and to whoever hand-edits the board's policy. The sync owns exactly one key.
    """
    path = os.path.join(board, FILENAME)
    try:
        with open(path) as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def build(resolved: dict, board: str) -> "tuple[str, list[str]]":
    """(full handoff.json contents, warnings) for one board."""
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
            # Schema 2 records IDENTITY and nothing else. A path — even one relative to the
            # board — encodes the authoring machine's checkout layout, and that single field is
            # what pinned a board to one disk: "../../../../acme-lib" resolves nowhere else. The
            # root commit already sat in every entry as the attestation; it is now the whole
            # answer, and location moved to an uncommitted per-machine map (see the CLI's
            # board_repo_entry, which reads ~/.agents/handoff-locations.json and, failing that,
            # discovers the checkout and caches it). Schema 1 files still READ — their path is
            # accepted as a hint that has to prove itself against this root commit.
            entries.append({
                "group": g["group"],
                "alias": m["alias"],
                "audience": m["audience"],
                "rootCommit": m["root_commit"],
            })

    for (group, aud), wheres in sorted(by_audience.items()):
        if len(wheres) > 1:
            warnings.append(
                "audience %r is claimed twice inside group %r (%s) — `handoff export` refuses to "
                "pick between them and degrades to unverified; give them distinct audiences"
                % (aud, group, ", ".join(sorted(wheres))))

    # No timestamp and no scope path anywhere in the payload: a re-projection that changes nothing
    # must be byte-identical, or every board with a registry shows up dirty on each run. Written
    # with the same `indent=2, sort_keys=True` the installer uses, so the two writers of this file
    # cannot fight over its formatting and rewrite it on alternate runs.
    data = load_board(board)
    gen = data.get(GENERATED_KEY)
    gen = dict(gen) if isinstance(gen, dict) else {}
    # NOT `schema`: that key now belongs to the board's DOCUMENT schema, which is what triggers a
    # migration. Two meanings for one key inside one file is exactly the kind of trap this
    # consolidation was supposed to remove.
    gen["registrySchema"] = 2
    gen["repos"] = sorted(entries, key=lambda e: (e["group"], e["alias"]))
    data[GENERATED_KEY] = gen
    return json.dumps(data, indent=2, sort_keys=True) + "\n", warnings


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

    n = len(json.loads(want)[GENERATED_KEY]["repos"])
    if args.check:
        if have is None:
            print("%s: missing — cross-repo briefs cannot resolve their target repo and will "
                  "render as unverified; re-run the sync" % dest)
            return 1
        # A board still carrying the standalone registry has not been re-synced since the files were
        # consolidated. Reported as drift, which it is: the CLI prefers the consolidated key, so the
        # old file is no longer the answer to anything.
        if os.path.isfile(os.path.join(os.path.realpath(args.board), LEGACY_FILENAME)):
            print("%s: a standalone repos.json is still present beside it — re-run the sync to "
                  "consolidate, then delete repos.json" % dest)
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
    legacy = os.path.join(os.path.dirname(dest), LEGACY_FILENAME)
    if os.path.isfile(legacy):
        # Renamed, never deleted: the contents are fully represented in the file just written, and
        # a `.superseded` suffix is obvious and reversible where a delete is neither.
        try:
            os.replace(legacy, legacy + ".superseded")
            print("%s: folded into handoff.json (repos.json.superseded is safe to delete)" % legacy)
        except OSError:
            pass
    print("%s (%d repo(s))" % (dest, n))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
