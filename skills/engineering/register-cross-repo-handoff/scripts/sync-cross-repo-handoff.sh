#!/usr/bin/env bash
# sync-cross-repo-handoff.sh — stand up a multi-group cross-repo handoff fleet from a manifest.
#
#   sync-cross-repo-handoff.sh --scope <dir> [--from <dir>] \
#       [--tools claude,gemini,copilot] [--primary claude|none] [--dry-run] [--prune]
#
# Resolves the .handoff-repos.json cascade (resolve.py), then, reusing setup-handoff.sh:
#   1. scaffolds each distinct board as a STANDALONE board (--board-only), owned by no repo;
#  1b. projects the manifest into each board as repos.json, so the board's own CLI can resolve a
#      handoff's `audience` to a real repo (attested by that repo's root commit) instead of guessing;
#   2. wires each member repo to its board + section (cross-repo topology, --group);
#   3. splices the cross-repo-handoff AGENTS.md block into each member (render.py);
#   4. records a state ledger so --prune can report members that have left scope.
#
# Idempotent: setup-handoff and render.py byte-compare before writing, so a second run leaves every
# repo's `git status` clean. --dry-run prints the plan and writes nothing.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVE="$SKILL_DIR/scripts/manifest/resolve.py"
RENDER="$SKILL_DIR/scripts/manifest/render.py"
REGISTRY="$SKILL_DIR/scripts/manifest/registry.py"
BLOCK_TMPL="$SKILL_DIR/assets/agents-cross-repo-handoff.md"
SETUP_HANDOFF="$(cd "$SKILL_DIR/../setup-handoff" 2> /dev/null && pwd)/scripts/setup-handoff.sh"

die() {
  echo "sync-cross-repo-handoff: $*" >&2
  exit 1
}
note() { echo "$*"; }

SCOPE="" FROM="" TOOLS="claude" PRIMARY="none" DRYRUN=0 PRUNE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --scope)
      SCOPE="${2:-}"
      shift 2
      ;;
    --from)
      FROM="${2:-}"
      shift 2
      ;;
    --tools)
      TOOLS="${2:-}"
      shift 2
      ;;
    --primary)
      PRIMARY="${2:-none}"
      shift 2
      ;;
    --dry-run)
      DRYRUN=1
      shift
      ;;
    --prune)
      PRUNE=1
      shift
      ;;
    *) die "unknown arg: $1" ;;
  esac
done
[ -n "$SCOPE" ] || die "usage: sync-cross-repo-handoff.sh --scope <dir> [--from <dir>] [--tools ...] [--primary ...] [--dry-run] [--prune]"
[ -d "$SCOPE" ] || die "no such scope dir: $SCOPE"
[ -f "$SETUP_HANDOFF" ] || die "setup-handoff.sh not found at $SETUP_HANDOFF (is the setup-handoff skill present?)"
command -v python3 > /dev/null 2>&1 || die "python3 is required"
[ "$PRIMARY" != "none" ] && ! command -v python3 > /dev/null 2>&1 \
  && die "--primary $PRIMARY needs python3 for the enforcement gate"
[ -n "$FROM" ] || FROM="$SCOPE"

# --- resolve the cascade once; reuse the JSON for both the plan and the AGENTS.md render ----------
RESOLVED="$(mktemp)"
trap 'rm -f "$RESOLVED"' EXIT
if ! python3 "$RESOLVE" --scope "$SCOPE" --from "$FROM" > "$RESOLVED"; then
  # resolve returns non-zero when a declared repo is missing; surface the errors, keep going with the
  # repos that DO resolve (a typo in one entry must not block the rest of the fleet).
  python3 - "$RESOLVED" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for e in d.get("errors", []):
    print(f"  [error] {e}", file=sys.stderr)
PY
fi
# surface warnings + shadow/tombstone reports
python3 - "$RESOLVED" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for w in d.get("warnings", []):
    print(f"  [warn] {w}")
for s in d.get("shadowed", []):
    print(f"  [shadow] group {s['group']} overridden by the {s['by_layer']} layer (was {s['was_layer']})")
for t in d.get("tombstones", []):
    print(f"  [tombstone] group {t['group']} removed by the {t['layer']} layer")
PY

# --- emit a shell-parseable plan (bash never parses JSON) -----------------------------------------
# BOARD<TAB>path<TAB>groups_csv<TAB>layout<TAB>remote
# MEMBER<TAB>group<TAB>board<TAB>board_groups_csv<TAB>layout<TAB>alias<TAB>audience<TAB>repo<TAB>exists<TAB>has_agents
PLAN="$(
  python3 - "$RESOLVED" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
boards = {b["path"]: b for b in d["boards"]}
for b in d["boards"]:
    print("\t".join(["BOARD", b["path"], ",".join(sorted(b["groups"])), d["layout"], b.get("remote", "")]))
for g in d["groups"]:
    bg = ",".join(sorted(boards[g["board"]]["groups"]))
    for m in g["members"]:
        print("\t".join([
            "MEMBER", g["group"], g["board"], bg, g["layout"], m["alias"], m["audience"],
            m["path"], "1" if m["exists"] else "0", "1" if m["has_agents_md"] else "0",
        ]))
PY
)"

RC=0
run() { # echo + run, or just echo under --dry-run
  if [ "$DRYRUN" = 1 ]; then
    note "  would: $*"
  else
    "$@"
  fi
}

# --- 1. scaffold each distinct board (standalone) ------------------------------------------------
note "== boards =="
while IFS=$'\t' read -r kind path groups layout remote; do
  [ "$kind" = "BOARD" ] || continue
  note "board $path (groups: $groups, layout: $layout${remote:+, remote: $remote})"
  # --remote is passed through, not applied here: setup-handoff owns the board's git substrate, so
  # the init/remote/.gitignore decisions live in ONE place rather than being re-derived per caller.
  # A board with no declared remote is still git-initialised; it just says so.
  if [ -n "$remote" ]; then
    run bash "$SETUP_HANDOFF" --board-only "$path" --groups "$groups" --layout "$layout" --remote "$remote"
  else
    run bash "$SETUP_HANDOFF" --board-only "$path" --groups "$groups" --layout "$layout"
  fi
done <<< "$PLAN"

# --- 1b. project the manifest into each board as repos.json --------------------------------------
# The board's `handoff` CLI cannot resolve the cascade for itself: it ships inside the member repos
# (and inside a repo-less shared board), so it can reach neither this skill's resolver nor --scope.
# The manifest's owner therefore writes the ANSWER down where the CLI can read it, and `handoff
# export` resolves a cross-repo brief's target repo from that file instead of guessing a sibling
# directory by name. registry.py owns the projection so this and the verifier cannot disagree.
note "== board repo registries =="
while IFS=$'\t' read -r kind path groups layout remote; do
  [ "$kind" = "BOARD" ] || continue
  if [ "$DRYRUN" = 1 ]; then
    note "  would: write $path/repos.json"
    continue
  fi
  if python3 "$REGISTRY" --resolved "$RESOLVED" --board "$path" --write; then
    :
  else
    note "  [error] could not write $path/repos.json"
    RC=1
  fi
done <<< "$PLAN"

# --- 2. wire each member repo + 3. render its AGENTS.md block ------------------------------------
note "== members =="
while IFS=$'\t' read -r kind group board bgroups layout alias audience repo exists has_agents; do
  [ "$kind" = "MEMBER" ] || continue
  if [ "$exists" != 1 ]; then
    note "  [skip] $group/$alias — $repo is not on disk"
    RC=1
    continue
  fi
  if [ "$has_agents" != 1 ]; then
    note "  [skip] $group/$alias — $repo has no AGENTS.md (run initial-project there first)"
    RC=1
    continue
  fi
  note "wire $group/$alias ($repo) -> $board"
  run bash "$SETUP_HANDOFF" "$repo" --tools "$TOOLS" --primary "$PRIMARY" \
    --topology cross-repo --handoff-dir "$board" \
    --group "$group" --groups "$bgroups" --layout "$layout"
  # the path this repo uses to reach the board (matches setup-handoff's own HDPATH)
  board_rel="$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))' "$board" "$repo")"
  if [ "$DRYRUN" = 1 ]; then
    python3 "$RENDER" --file "$repo/AGENTS.md" --template "$BLOCK_TMPL" \
      --group "$group" --self "$alias" --board-rel "$board_rel" --dry-run < "$RESOLVED"
  else
    python3 "$RENDER" --file "$repo/AGENTS.md" --template "$BLOCK_TMPL" \
      --group "$group" --self "$alias" --board-rel "$board_rel" < "$RESOLVED" || RC=1
  fi
done <<< "$PLAN"

# --- 4. state ledger (for --prune drift reporting) ----------------------------------------------
LEDGER="$SCOPE/.agents/cross-repo-handoff-state.json"
if [ "$DRYRUN" != 1 ]; then
  mkdir -p "$SCOPE/.agents"
  python3 - "$RESOLVED" "$LEDGER" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
members = [{"group": g["group"], "alias": m["alias"], "path": m["path"], "board": g["board"]}
           for g in d["groups"] for m in g["members"] if m["exists"]]
prev = {}
try:
    prev = json.load(open(sys.argv[2]))
except Exception:
    pass
out = {"version": 1, "scope": d["scope"],
       "members": sorted(members, key=lambda m: (m["group"], m["alias"])),
       "boards": [b["path"] for b in d["boards"]]}
# report members that were wired before but have left scope (advisory — sync does not unwire)
cur = {(m["group"], m["alias"]) for m in members}
for m in prev.get("members", []):
    if (m["group"], m["alias"]) not in cur:
        print(f"  [prune] {m['group']}/{m['alias']} left scope — remove its handoff hooks manually "
              f"in {m['path']} (.claude/settings.json) if it should no longer coordinate.", file=sys.stderr)
json.dump(out, open(sys.argv[2], "w"), indent=2)
open(sys.argv[2], "a").write("\n")
PY
fi

if [ "$DRYRUN" = 1 ]; then
  note "sync-cross-repo-handoff: dry run — no changes written"
else
  note "sync-cross-repo-handoff: done (ledger: $LEDGER)"
fi
exit $RC
