#!/usr/bin/env bash
# setup-handoff.sh — install the lease-based handoff coordination protocol into a repo.
#
# Idempotent. Copies the tool-generic payload into <repo>/.agents/handoff/, writes the
# per-tool hook config for each chosen tool (merging, never clobbering), injects the
# AGENTS.md routing block, and (optionally) migrates a legacy .claude/handoff/ install.
#
# Usage:
#   setup-handoff.sh <repo> --tools claude,gemini,copilot --primary claude \
#       [--topology single-repo|cross-repo] [--handoff-dir <path>] \
#       [--group <section>] [--groups <csv>] [--layout subfolder|prefix] \
#       [--migrate <legacy-dir>] [--allow-verify-cmd]
#
#   setup-handoff.sh --board-only <path> [--groups <csv>] [--layout subfolder|prefix] [--remote <url>]
#       Scaffold a STANDALONE shared board (payload + config) at <path>, owned by no repo:
#       no per-tool wiring, no AGENTS.md edit, no git/AGENTS.md precondition. This is what
#       lets the cross-repo sync stand up a board without seeding it from a member project.
#
# The SKILL (single-repo) or the register-cross-repo-handoff sync (multi-repo) drives the
# choices; this script is the non-interactive apply step.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD="$SKILL_DIR/scripts/payload"
ASSETS="$SKILL_DIR/assets"
# Sourced for handoff_cli_home() alone — where the user-level CLI goes. The installer writes that
# path and the dispatcher, the CLI and hooks.sh all read it, so it is defined once, in the file
# they already share. config.sh defines functions and nothing else; sourcing it runs no code.
# shellcheck disable=SC1091
. "$PAYLOAD/config.sh"

die() {
  echo "setup-handoff: $*" >&2
  exit 1
}

# Guard for every value-taking flag in the arg loop below: a value that is missing (the flag was
# the last argument) or that itself looks like another flag (starts with "--") is never accepted
# silently. Unlike payload/hooks.sh's identically-shaped guard — which warns and keeps going
# because a hook must never break the caller's tool session — this is an installer, so it fails
# hard: a half-configured board is worse than a refused install. $1 is the flag being parsed, $2
# is the caller's remaining arg count ("$#" from before this flag's own shift), $3 is "${2:-}"
# (the candidate value, or empty when absent). Naming the flag explicitly is the point: the old
# unguarded code let a swallowed flag get misattributed to some later, unrelated arg.
require_value() {
  local flag="$1" argcount="$2" val="$3"
  if [ "$argcount" -lt 2 ]; then
    die "$flag needs a value (got nothing — it was the last argument)"
  fi
  case "$val" in
    --*) die "$flag needs a value (got the flag \"$val\")" ;;
  esac
}

# Copy a payload file only when changed, keeping the exec bit (defined early so --board-only can use it).
install_file() {
  local s="$1" d="$2"
  if [ ! -f "$d" ] || ! cmp -s "$s" "$d"; then cp "$s" "$d"; fi
}

# The CLI, in its three possible homes. Board and binary are separate (see payload/dispatcher):
# what every board gets is the small dispatcher at <board>/handoff, which is what all the wired
# hook commands and every README already point at. The CLI it execs comes from $HANDOFF_BIN, the
# user-level install this function writes, or the board's vendored copy — in that order.
install_cli() { # board-dir
  local b="$1" home
  install_file "$PAYLOAD/dispatcher" "$b/handoff"
  chmod +x "$b/handoff"
  if [ "$VENDOR_CLI" = "1" ]; then
    install_file "$PAYLOAD/handoff" "$b/scripts/handoff-cli"
    chmod +x "$b/scripts/handoff-cli"
  elif [ -f "$b/scripts/handoff-cli" ]; then
    # Never deleted by this installer — removing a working CLI out from under a board is not a
    # side effect an install should have. Say it is there and leave the choice to the operator.
    echo "setup-handoff: --no-vendor-cli, but $b/scripts/handoff-cli already exists — left in place; remove it yourself to finish de-vendoring."
  fi
  # User-level install: one copy per machine, upgraded on its own cadence, shared by every board.
  # Best-effort — a read-only or unset HOME is not a reason to fail an install whose board half
  # just succeeded, and the vendored copy (or $HANDOFF_BIN) still answers.
  home="$(handoff_cli_home)"
  if mkdir -p "$home" 2> /dev/null; then
    if install_file "$PAYLOAD/handoff" "$home/handoff" 2> /dev/null; then
      chmod +x "$home/handoff" 2> /dev/null || true
    else
      echo "setup-handoff: could not write the user-level CLI to $home/handoff — boards will use their vendored copy."
    fi
  else
    echo "setup-handoff: could not create $home — skipping the user-level CLI install."
  fi
}

# Writes the board's config as JSON, MERGING with whatever config.json is already there rather
# than blindly overwriting it: the installer owns WIRING facts (topology, groups, groupLayout,
# repoName). groups/groupLayout are section-routing facts a SHARED board depends on: when
# --groups/--layout are PASSED (register-cross-repo-handoff's sync always passes both), this run's
# values OVERRIDE — that is what keeps the sync authoritative. When they are ABSENT (e.g. a
# hand-typed re-run of setup-handoff.sh against an already-sectioned board), the existing values
# are PRESERVED rather than wiped, with a warning on stderr — wiping them silently would reroute
# every member repo's handoffs to the board root and break the sub-indexes. Passing an explicit
# empty value (--groups "") is a deliberate CLEAR, distinct from not passing the flag at all; see
# GROUP_LIST_SET/LAYOUT_SET below for how "flag absent" is told apart from "flag passed empty".
# ttlHours is a POLICY knob the user owns: there is no installer flag for it, so an existing value
# is preserved across every re-install and the default (4) applies only when the file doesn't
# exist yet or can't be read. allowVerifyCmd is the deliberate exception to that preservation
# rule: it is security-relevant (it lets `release --run-verify` execute a command straight out of
# a doc), so it tracks ONLY this run's --allow-verify-cmd flag — true when passed, false when
# not — and is never carried forward from a previous install. Do not "fix" this into symmetric
# preservation; the asymmetry is intentional, not an oversight.
# REPO_NAME is written ONLY for a single-repo board — a shared board must not bake one repo's
# name in, or the last installer clobbers every sibling's identity.
write_board_config() { # dest topology repo_name
  local dest="$1" topo="$2" rn="$3"
  TOPO="$topo" RN="$rn" GRPS="$GROUP_LIST" GRPS_SET="$GROUP_LIST_SET" LAY="$LAYOUT" LAY_SET="$LAYOUT_SET" ALLOW="$ALLOW_VERIFY" \
    PAYLOAD_VERSION="$(cat "$SKILL_DIR/scripts/payload.version" 2> /dev/null | head -1)" \
    SCHEMA_VERSION="$(sed -n 's/^SCHEMA_VERSION=//p' "$PAYLOAD/handoff" | head -1)" \
    python3 - "$dest" << 'PY'
import json, os, sys

dest = sys.argv[1]
existing = {}
# Seed from the file this one REPLACES before reading the destination itself, oldest name first.
# On the run that MIGRATES a board, `dest` does not exist yet — reading only `dest` meant every
# preserved-by-design value (ttlHours, groups, groupLayout) was silently reset to its default at
# the exact moment the operator was being told the config was carried forward.
for src in (os.path.join(os.path.dirname(dest), "config.json"), dest):
    if not os.path.exists(src):
        continue
    try:
        with open(src) as fh:
            loaded = json.load(fh)
        if isinstance(loaded, dict):
            existing.update(loaded)
        else:
            print(f"setup-handoff: warning: {src} is not a JSON object; discarding its contents", file=sys.stderr)
    except (json.JSONDecodeError, OSError) as exc:
        print(f"setup-handoff: warning: {src} is not valid JSON ({exc}); discarding its contents", file=sys.stderr)

# ttlHours: policy, preserved from an existing (parseable) config; allowVerifyCmd: security,
# NEVER preserved — see the comment on write_board_config above for why these differ.
ttl = existing.get("ttlHours", 4)
if not isinstance(ttl, int) or isinstance(ttl, bool):
    ttl = 4

# groups/groupLayout: flags OVERRIDE when passed (even as an explicit empty value, which CLEARS
# them); when the flag is ABSENT, preserve whatever was already in a parseable existing config
# and say so on stderr, so wiping a shared board's section routing is never silent.
def existing_str_list(key):
    val = existing.get(key)
    if isinstance(val, list) and all(isinstance(v, str) for v in val):
        return val
    return []

if os.environ.get("GRPS_SET") == "1":
    groups = [g for g in os.environ.get("GRPS", "").split(",") if g]
else:
    groups = existing_str_list("groups")
    if groups:
        print(f"setup-handoff: --groups not passed; preserved existing groups: {groups}", file=sys.stderr)

if os.environ.get("LAY_SET") == "1":
    group_layout = os.environ.get("LAY", "")
else:
    group_layout = existing.get("groupLayout", "")
    if not isinstance(group_layout, str):
        group_layout = ""
    if group_layout:
        print(f"setup-handoff: --layout not passed; preserved existing groupLayout: {group_layout!r}", file=sys.stderr)

cfg = {
    "topology": os.environ["TOPO"],
    "groups": groups,
    "groupLayout": group_layout,
    "ttlHours": ttl,
    "allowVerifyCmd": os.environ.get("ALLOW") == "1",
}

# The DOCUMENT schema, which is the only thing that triggers a migration — distinct from the
# payload version beside it, which moves on every CLI bugfix (ADR 0003). Preserved when already
# set: an installer must never claim a board's documents were migrated when they were not. A board
# with no stamp at all is schema 0, and a FRESH board is stamped current because it has no legacy
# documents to migrate.
existing_schema = existing.get("schema")
if isinstance(existing_schema, int) and not isinstance(existing_schema, bool):
    cfg["schema"] = existing_schema
elif not any(os.scandir(os.path.dirname(dest))) or not [
    f for f in os.listdir(os.path.dirname(dest)) if f.endswith("-handoff.md")
]:
    cfg["schema"] = int(os.environ.get("SCHEMA_VERSION", "1"))

# `_generated` belongs to the cross-repo sync (the repo registry) and to this installer (the
# payload stamp). It is preserved wholesale rather than rebuilt, because this installer does not
# know the fleet — clobbering it here would silently un-resolve every cross-repo brief on the
# board until somebody happened to re-run the sync.
gen = existing.get("_generated")
gen = dict(gen) if isinstance(gen, dict) else {}
pv = os.environ.get("PAYLOAD_VERSION", "").strip()
if pv:
    gen["payloadVersion"] = pv
if gen:
    cfg["_generated"] = gen
if os.environ["TOPO"] != "cross-repo":
    cfg["repoName"] = os.environ.get("RN", "")
with open(dest, "w") as fh:
    json.dump(cfg, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

REPO="" TOOLS="" PRIMARY="none" TOPOLOGY="single-repo" HANDOFF_DIR="" MIGRATE="" ALLOW_VERIFY=0
# Vendor a full copy of the CLI onto the board (default) so a cold clone with nothing but bash
# works. --no-vendor-cli is for boards that are never cloned cold — chiefly this repo's own test
# fixtures, where a committed byte-copy of a 180 KB script is 15 files to re-sync on every bugfix
# and the exact drift the split was made to end.
VENDOR_CLI=1
# GROUP_LIST, not GROUPS: `GROUPS` is a bash built-in (the user's gids), and assigning it here aborts
# the whole assignment line, leaving later vars unset under `set -u`.
GROUP="" GROUP_LIST="" LAYOUT="" BOARD_ONLY="" BOARD_REMOTE=""
# GROUP_LIST_SET/LAYOUT_SET: whether --groups/--layout were PASSED at all (any value, including
# an explicit empty string), as distinct from not passed. write_board_config needs this to tell
# "override with empty" (flag passed as "") apart from "leave alone" (flag absent) — a plain
# ${VAR:-} check on GROUP_LIST/LAYOUT can't make that distinction since both collapse to "".
GROUP_LIST_SET="" LAYOUT_SET=""
[ $# -gt 0 ] || die "usage: setup-handoff.sh <repo> --tools <list> --primary <tool|none> [opts] | --board-only <path> [--groups <csv>] [--layout ...] [--remote <url>]"
# --board-only is a distinct mode (no <repo> positional): scaffold a standalone board and exit.
if [ "$1" = "--board-only" ]; then
  BOARD_ONLY="${2:-}"
  [ -n "$BOARD_ONLY" ] || die "--board-only needs a path"
  shift 2
else
  REPO="$1"
  shift
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --tools)
      require_value --tools "$#" "${2:-}"
      TOOLS="${2:-}"
      shift 2
      ;;
    --primary)
      require_value --primary "$#" "${2:-}"
      PRIMARY="${2:-none}"
      shift 2
      ;;
    --topology)
      require_value --topology "$#" "${2:-}"
      TOPOLOGY="${2:-single-repo}"
      shift 2
      ;;
    --handoff-dir)
      require_value --handoff-dir "$#" "${2:-}"
      HANDOFF_DIR="${2:-}"
      shift 2
      ;;
    --no-vendor-cli)
      VENDOR_CLI=0
      shift
      ;;
    --group)
      require_value --group "$#" "${2:-}"
      GROUP="${2:-}"
      shift 2
      ;;
    --groups)
      require_value --groups "$#" "${2:-}"
      GROUP_LIST="${2:-}"
      GROUP_LIST_SET=1
      shift 2
      ;;
    --layout)
      require_value --layout "$#" "${2:-}"
      LAYOUT="${2:-}"
      LAYOUT_SET=1
      shift 2
      ;;
    --migrate)
      require_value --migrate "$#" "${2:-}"
      MIGRATE="${2:-}"
      shift 2
      ;;
    --remote)
      require_value --remote "$#" "${2:-}"
      BOARD_REMOTE="${2:-}"
      shift 2
      ;;
    --allow-verify-cmd)
      ALLOW_VERIFY=1
      shift
      ;;
    *) die "unknown arg: $1" ;;
  esac
done
[ -n "$LAYOUT" ] && { case "$LAYOUT" in subfolder | prefix) ;; *) die "bad --layout: $LAYOUT (use subfolder|prefix)" ;; esac }

# Legacy config names are READ (see config.sh) but no longer WRITTEN. Once the consolidated file
# exists, the old one is renamed aside rather than deleted: nothing here removes a file a user may
# have hand-edited, and a `.superseded` suffix is both obvious and reversible. Readers ignore it.
supersede_legacy() { # path reason
  local f="$1" why="$2"
  [ -f "$f" ] || return 0
  mv "$f" "$f.superseded" 2> /dev/null || return 0
  echo "setup-handoff: $why — renamed $(basename "$f") to $(basename "$f").superseded (safe to delete)"
}

# --- the board's own git substrate (ADR 0002) -------------------------------------------
# A STANDALONE shared board is git-initialised non-optionally. It is the board of record: it holds
# documents that exist nowhere else, and one that was never a repository has no history, no blame,
# and no recovery — a board in exactly that state was found holding 193 irreplaceable documents.
# A nested board is left alone; its history belongs to the repo that contains it.
#
# The remote is what makes it SHARED rather than merely versioned, and the two are worth telling
# apart out loud: a versioned board still coordinates exactly one machine.
board_write_gitignore() { # board-dir
  local b="$1" gi="$b/.gitignore" t
  t="$(mktemp)" || return 0
  # `.locks/` is ephemeral machine state on a local-only board and shared state of record on a
  # remote-backed one, so the rule is derived from the remote rather than assumed. Rewritten on
  # every run, because a board that gains a remote later must stop ignoring its leases — the CLI
  # repairs the same file on the claim path for a board that gains one between installs.
  [ -f "$gi" ] && grep -vxF '.locks/' "$gi" > "$t"
  if [ -z "$(git -C "$b" remote 2> /dev/null)" ]; then
    printf '.locks/\n' >> "$t"
  fi
  if [ -s "$t" ] || [ -f "$gi" ]; then
    cmp -s "$t" "$gi" 2> /dev/null || cat "$t" > "$gi"
  fi
  rm -f "$t"
}

# Clone-if-absent, so a teammate who runs the sync ends up on the SAME board rather than a fresh
# empty one. That second board is not merely redundant: its history is unrelated to the real one, so
# its first push is rejected as a non-fast-forward, and the obvious "fix" — forcing it — erases the
# board everyone else is using. Bootstrapping is what stops that from ever being the situation.
board_bootstrap() { # board-dir remote-url
  local b="$1" url="$2" top
  [ -n "$url" ] || return 0
  top="$(git -C "$b" rev-parse --show-toplevel 2> /dev/null || true)"
  if [ -n "$top" ] && [ "$(cd "$top" 2> /dev/null && pwd -P)" = "$(cd "$b" 2> /dev/null && pwd -P)" ]; then
    return 0 # the board is already here and already a repository
  fi
  # Only into an absent or empty directory. Cloning over an existing board is a merge decision, and
  # a merge decision is a repair job — not something an installer gets to make on its own.
  if [ -d "$b" ] && [ -n "$(ls -A "$b" 2> /dev/null)" ]; then
    echo "setup-handoff: $b already holds files but is not a git repository — not cloning $url over it."
    echo "  Move it aside, or clone the board yourself and re-run."
    return 0
  fi
  mkdir -p "$(dirname "$b")"
  if git clone --quiet "$url" "$b" 2> /dev/null; then
    echo "setup-handoff: cloned the board from $url into $b"
  else
    echo "setup-handoff: could not clone $url — scaffolding a new board at $b instead."
    echo "  If that remote already holds a board, sort this out BEFORE pushing: two unrelated"
    echo "  histories cannot merge, and forcing one over the other erases the board."
  fi
}

# The board's own machinery has to be IN the board's history, or it is not really there. A board
# scaffolded and left uncommitted looks fine locally and is empty to everyone who clones it; worse,
# it has no commits at all, so its branch is unborn and the first `claim` reports something
# confusing about HEAD instead of doing its job.
#
# Only the files this installer just wrote. Documents are not swept in: someone may have one open,
# and committing it under an install's message would be both a lie and a surprise.
board_commit_payload() { # board-dir
  local b="$1" f
  for f in handoff README.md handoff.json .gitignore scripts templates; do
    [ -e "$b/$f" ] && git -C "$b" add -- "$b/$f" 2> /dev/null
  done
  git -C "$b" diff --cached --quiet 2> /dev/null && return 0 # nothing of ours changed
  git -C "$b" commit --quiet -m "handoff: install board machinery" 2> /dev/null || {
    echo "setup-handoff: could not commit the board machinery in $b (is git identity configured?)"
    return 0
  }
  echo "setup-handoff: committed the board machinery"
  [ -n "$(git -C "$b" remote 2> /dev/null)" ] || return 0
  # Best effort. An unreachable remote at install time is normal (offline, or the remote is not
  # created yet); the board is committed either way and the next claim pushes.
  git -C "$b" push --quiet -u "$(git -C "$b" remote | head -1)" HEAD 2> /dev/null \
    && echo "setup-handoff: pushed the board to its remote" \
    || echo "setup-handoff: the board is committed but not pushed — push it when the remote is reachable."
}

board_ensure_git() { # board-dir [remote-url]
  local b="$1" url="${2:-}" top
  top="$(git -C "$b" rev-parse --show-toplevel 2> /dev/null || true)"
  # Physical paths on both sides: git reports the physical toplevel (see the CLI's board_is_repo).
  if [ -z "$top" ] || [ "$(cd "$top" 2> /dev/null && pwd -P)" != "$(cd "$b" && pwd -P)" ]; then
    # Either nothing above it is a repository, or the repository above it is somebody else's —
    # a board owned by no repo must own itself, not borrow a parent's history and remote.
    git -C "$b" init --quiet || die "could not git init the board at $b"
    echo "setup-handoff: git-initialised the board at $b (the board of record needs history)"
  fi
  if [ -n "$url" ] && [ -z "$(git -C "$b" remote 2> /dev/null)" ]; then
    git -C "$b" remote add origin "$url" \
      && echo "setup-handoff: added remote origin $url"
  fi
  board_write_gitignore "$b"
  board_commit_payload "$b"
  if [ -z "$(git -C "$b" remote 2> /dev/null)" ]; then
    echo "setup-handoff: this board has NO REMOTE — it is versioned, but still reaches one machine."
    echo "  Leases stay machine-local until it has one:"
    echo "    git -C $b remote add origin <url> && git -C $b push -u origin HEAD"
  fi
}

# --- --board-only: scaffold a standalone shared board, owned by no repo -----------------
# Copies the payload + writes a cross-repo config (with any group facts), then exits. No per-tool
# wiring, no AGENTS.md edit, no git/AGENTS.md precondition — the board is a plain directory the
# cross-repo sync stands up before it wires the member repos that point at it. Idempotent.
if [ -n "$BOARD_ONLY" ]; then
  case "$BOARD_ONLY" in /*) HDEST="$BOARD_ONLY" ;; *) HDEST="$(pwd)/$BOARD_ONLY" ;; esac
  # Before anything is written: if a remote is declared and no board is here yet, this machine is
  # JOINING an existing board, not creating one. The payload install below is byte-comparing and
  # idempotent, so it lands cleanly on top of whatever the clone brought.
  board_bootstrap "$HDEST" "$BOARD_REMOTE"
  mkdir -p "$HDEST/scripts" "$HDEST/templates" "$HDEST/archive" "$HDEST/briefs"
  install_cli "$HDEST"
  install_file "$PAYLOAD/hooks.sh" "$HDEST/scripts/hooks.sh"
  install_file "$PAYLOAD/config.sh" "$HDEST/scripts/config.sh"
  install_file "$PAYLOAD/README.md" "$HDEST/README.md"
  install_file "$ASSETS/handoff-doc-template.md" "$HDEST/templates/handoff-doc-template.md"
  install_file "$ASSETS/handoff-standalone-template.md" "$HDEST/templates/handoff-standalone-template.md"
  install_file "$ASSETS/handoff-orchestrator-template.md" "$HDEST/templates/handoff-orchestrator-template.md"
  install_file "$ASSETS/handoff-brief-template.md" "$HDEST/templates/handoff-brief-template.md"
  chmod +x "$HDEST/scripts/hooks.sh"
  write_board_config "$HDEST/handoff.json" cross-repo ""
  supersede_legacy "$HDEST/config.json" "board config now lives in handoff.json"
  supersede_legacy "$HDEST/.version" "the payload stamp now lives in handoff.json"
  board_ensure_git "$HDEST" "$BOARD_REMOTE"
  echo "setup-handoff: scaffolded standalone board at $HDEST (topology=cross-repo${GROUP_LIST:+, groups=$GROUP_LIST}${LAYOUT:+, layout=$LAYOUT})"
  exit 0
fi

# --- preconditions --------------------------------------------------------------------
REPO="$(cd "$REPO" 2> /dev/null && git rev-parse --show-toplevel 2> /dev/null)" \
  || die "not a git working tree: refusing to install (run initial-project first)"
[ -f "$REPO/AGENTS.md" ] || die "no AGENTS.md at repo root — run initial-project first; not fabricating it here"
case "$TOPOLOGY" in single-repo | cross-repo) ;; *) die "bad --topology: $TOPOLOGY" ;; esac

# --- preflight: hard enforcement needs python3 ----------------------------------------
# The primary tool's deny gate parses the hook payload with python3. Refuse to designate
# a hard-enforcement primary unless python3 is present, so breakage is caught NOW, not
# silently at runtime. (Non-primary/advisory wiring has no deny, so it is exempt.)
if [ "$PRIMARY" != "none" ]; then
  command -v python3 > /dev/null 2>&1 \
    || die "primary tool '$PRIMARY' needs python3 for the enforcement gate, and python3 is not on PATH. Install python3, or re-run with --primary none for advisory-only wiring."
fi

# --- resolve the handoff dir + the path tools use to reach hooks.sh --------------------
if [ "$TOPOLOGY" = "cross-repo" ]; then
  [ -n "$HANDOFF_DIR" ] || HANDOFF_DIR="$(cd "$REPO/.." && pwd)/.agents/handoff"
  case "$HANDOFF_DIR" in /*) ;; *) HANDOFF_DIR="$(cd "$REPO/$HANDOFF_DIR" 2> /dev/null && pwd || echo "$REPO/$HANDOFF_DIR")" ;; esac
  HDEST="$HANDOFF_DIR"
  # path recorded in tool configs, relative to the repo when possible
  HDPATH="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$HDEST" "$REPO" 2> /dev/null || echo "$HDEST")"
else
  # single-repo (repo-level board). Location is configurable via --handoff-dir, but must live
  # INSIDE the repo (a shared parent dir is what --topology cross-repo is for).
  if [ -n "$HANDOFF_DIR" ]; then
    HDPATH="${HANDOFF_DIR#./}"
    HDPATH="${HDPATH%/}"
    case "$HDPATH" in
      /*) die "single-repo --handoff-dir must be a path inside the repo (e.g. .claude/handoff), got absolute: $HANDOFF_DIR — use --topology cross-repo for a shared parent dir" ;;
      "" | ../* | */../*) die "single-repo --handoff-dir must be inside the repo, got: $HANDOFF_DIR" ;;
    esac
    HDEST="$REPO/$HDPATH"
  else
    HDEST="$REPO/.agents/handoff"
    HDPATH=".agents/handoff"
  fi
fi

# --- optional migration from a legacy install -----------------------------------------
# Preserve docs, archive/, and history (git mv when possible), then re-point config below.
if [ -n "$MIGRATE" ]; then
  LEGACY="$MIGRATE"
  case "$LEGACY" in /*) ;; *) LEGACY="$REPO/$LEGACY" ;; esac
  [ -d "$LEGACY" ] || die "--migrate: no such legacy dir: $LEGACY"
  [ "$(cd "$LEGACY" && pwd)" = "$HDEST" ] && MIGRATE="" # already at the generic path
fi
if [ -n "$MIGRATE" ]; then
  echo "Migrating legacy handoff install: $LEGACY -> $HDEST"
  mkdir -p "$HDEST/archive"
  LEGREL="${LEGACY#$REPO/}"
  case "$HDEST" in "$REPO"/*) DEST_IN_REPO=1 ;; *) DEST_IN_REPO=0 ;; esac
  move_doc() { # src destdir — git mv (history) when both sides are in-repo, else copy
    local src="$1" dd="$2"
    [ -e "$src" ] || return 0
    if [ "$DEST_IN_REPO" = 1 ] && [ -n "$(git -C "$REPO" ls-files "$src" 2> /dev/null)" ]; then
      git -C "$REPO" mv "$src" "$dd/" 2> /dev/null || cp "$src" "$dd/"
    else
      cp "$src" "$dd/"
    fi
  }
  # durable docs + archive only — NEVER the ephemeral, machine-local .locks
  for f in "$LEGACY"/*.md; do move_doc "$f" "$HDEST"; done
  for a in "$LEGACY"/archive/*.md; do move_doc "$a" "$HDEST/archive"; done
  # de-register the legacy dir from the repo (removes tracked files from index + worktree)
  [ -n "$(git -C "$REPO" ls-files "$LEGREL" 2> /dev/null)" ] \
    && git -C "$REPO" rm -r -q --ignore-unmatch "$LEGREL" > /dev/null 2>&1 || true
  # relocate any leftover (untracked .locks, stray files) OUT of the repo — recoverable, not deleted
  [ -d "$LEGACY" ] && mv "$LEGACY" "${TMPDIR:-/tmp}/handoff-migrated-$$-$(basename "$LEGACY")" 2> /dev/null || true
fi

# --- migrate a FLAT board to the scripts/ + templates/ layout --------------------------
# Boards installed before the restructure keep machinery next to the docs. Move it into place
# before installing, so the payload copy below lands in one location instead of two. Docs, README,
# INDEX, config, archive/ and .locks/ all stay at the board root — only machinery moves. Uses git mv
# when the file is tracked so history follows the rename; the hook commands in each tool's settings
# are rewritten by merge-hooks.py further down (it recognizes both the old and new marker).
migrate_file() { # src dest
  [ -f "$1" ] || return 0
  [ -f "$2" ] && return 0 # already migrated; the payload install below refreshes it
  git -C "$REPO" mv -f "$1" "$2" > /dev/null 2>&1 || mv -f "$1" "$2"
}
if [ -f "$HDEST/hooks.sh" ] || [ -f "$HDEST/handoff-doc-template.md" ]; then
  echo "Migrating flat handoff layout -> scripts/ + templates/ in $HDEST"
  mkdir -p "$HDEST/scripts" "$HDEST/templates"
  migrate_file "$HDEST/hooks.sh" "$HDEST/scripts/hooks.sh"
  migrate_file "$HDEST/handoff-doc-template.md" "$HDEST/templates/handoff-doc-template.md"
  migrate_file "$HDEST/handoff-standalone-template.md" "$HDEST/templates/handoff-standalone-template.md"
  migrate_file "$HDEST/handoff-orchestrator-template.md" "$HDEST/templates/handoff-orchestrator-template.md"
  migrate_file "$HDEST/handoff-brief-template.md" "$HDEST/templates/handoff-brief-template.md"
fi

# --- migrate a legacy shell config to JSON ---------------------------------------------
# The old file is RETAINED, not deleted: the readers prefer config.json and fall back to it, so
# keeping it means a half-finished install cannot strand a board with no config at all. A later
# install overwrites config.json from live facts anyway.
if [ -f "$HDEST/config" ] && [ ! -f "$HDEST/handoff.json" ] && [ ! -f "$HDEST/config.json" ]; then
  echo "Migrating legacy shell config -> handoff.json in $HDEST"
  python3 - "$HDEST/config" "$HDEST/handoff.json" << 'PY'
import json, sys
MAP = {"TOPOLOGY": "topology", "REPO_NAME": "repoName", "HANDOFF_GROUPS": "groups",
       "HANDOFF_GROUP_LAYOUT": "groupLayout", "HANDOFF_TTL_HOURS": "ttlHours",
       "HANDOFF_ALLOW_VERIFY_CMD": "allowVerifyCmd"}
cfg = {}
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        if key in MAP:
            cfg[MAP[key]] = val.strip().strip('"').strip("'")
cfg["groups"] = [g for g in str(cfg.get("groups", "")).split(",") if g]
cfg["ttlHours"] = int(cfg.get("ttlHours") or 4)
cfg["allowVerifyCmd"] = str(cfg.get("allowVerifyCmd", "0")) == "1"
cfg.setdefault("topology", "single-repo")
cfg.setdefault("groupLayout", "")
with open(sys.argv[2], "w") as fh:
    json.dump(cfg, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
fi

# --- install the payload --------------------------------------------------------------
mkdir -p "$HDEST/archive" "$HDEST/scripts" "$HDEST/templates" "$HDEST/briefs"
install_cli "$HDEST"
install_file "$PAYLOAD/hooks.sh" "$HDEST/scripts/hooks.sh"
install_file "$PAYLOAD/config.sh" "$HDEST/scripts/config.sh"
install_file "$PAYLOAD/README.md" "$HDEST/README.md"
install_file "$ASSETS/handoff-doc-template.md" "$HDEST/templates/handoff-doc-template.md"
install_file "$ASSETS/handoff-standalone-template.md" "$HDEST/templates/handoff-standalone-template.md"
install_file "$ASSETS/handoff-orchestrator-template.md" "$HDEST/templates/handoff-orchestrator-template.md"
install_file "$ASSETS/handoff-brief-template.md" "$HDEST/templates/handoff-brief-template.md"
# Payload stamp: what version of the board machinery this install carries. Committed with the
# payload so a teammate's checkout carries it too, and readable with `cat` — the hooks that read
# it may run on a machine with nothing but bash. An ABSENT .version means a pre-versioning
# install, not a corrupt one; readers treat the two the same and report "behind".

chmod +x "$HDEST/scripts/hooks.sh"

# config (committed): board-global facts only. See write_board_config (top) for why REPO_NAME is
# single-repo-only and how the group facts are recorded, and allowVerifyCmd is written as a JSON key.
REPO_NAME="$(basename "$REPO")"
write_board_config "$HDEST/handoff.json" "$TOPOLOGY" "$REPO_NAME"
supersede_legacy "$HDEST/config.json" "board config now lives in handoff.json"
supersede_legacy "$HDEST/.version" "the payload stamp now lives in handoff.json"
supersede_legacy "$HDEST/config" "the legacy shell config was folded into handoff.json"

# .locks is machine-local — never commit it. Only meaningful for a single-repo (in-repo) board;
# a cross-repo board is a SHARED dir outside the worktree (git ignore can't act on a ../ path) that
# owns its own .gitignore, so the consumer entry would be inert. Key on TOPOLOGY, not a path prefix:
# on the first install the shared board does not exist yet, so HDEST resolves to the non-canonical
# "$REPO/../handoff" — which would spuriously match a "$REPO"/* test.
if [ "$TOPOLOGY" != "cross-repo" ]; then
  GI="$REPO/.gitignore"
  LOCK_IGNORE="$HDPATH/.locks/"
  if ! grep -qxF "$LOCK_IGNORE" "$GI" 2> /dev/null; then
    printf '%s\n' "$LOCK_IGNORE" >> "$GI"
  fi
fi

# --- per-tool hook wiring (python3 merge, non-clobbering) -----------------------------
render_and_merge() { # $1 = tool  $2 = is_primary(1|0)
  local tool="$1" primary="$2" cfg=""
  case "$tool" in
    claude)
      cfg="$REPO/.claude/settings.json"
      mkdir -p "$REPO/.claude"
      ;;
    gemini)
      cfg="$REPO/.gemini/settings.json"
      mkdir -p "$REPO/.gemini"
      ;;
    copilot)
      cfg="$REPO/.github/hooks/handoff.json"
      mkdir -p "$REPO/.github/hooks"
      ;;
    *)
      echo "  (skipping unknown tool: $tool)" >&2
      return 0
      ;;
  esac
  # Cross-repo: these no longer get baked into the hook command itself (that would go stale on a
  # rename, invisible to anyone reading the board). Instead merge-hooks.py reads them as its live
  # source of truth for THIS repo's identity and writes it to .agents/handoff.config.json --
  # both for a fresh install (nothing to migrate yet) and to override a migrated legacy prefix
  # with what this run actually knows. Single-repo leaves HANDOFF_REPO empty, so merge-hooks.py
  # writes no repo config there and the command stays byte-identical to a pre-existing one.
  local repo_id=""
  [ "$TOPOLOGY" = "cross-repo" ] && repo_id="$(basename "$REPO")"
  HANDOFF_HDPATH="$HDPATH" HANDOFF_TOOL="$tool" HANDOFF_PRIMARY="$primary" HANDOFF_REPO="$repo_id" HANDOFF_GROUP="$GROUP" \
    python3 "$SKILL_DIR/scripts/merge-hooks.py" "$cfg" --repo-root "$REPO" \
    && echo "  wired $tool ($([ "$primary" = 1 ] && echo 'hard enforcement' || echo advisory)): $cfg" \
    || echo "  WARN: could not wire $tool config: $cfg" >&2
}

IFS=',' read -r -a TOOL_ARR <<< "$TOOLS"
for t in "${TOOL_ARR[@]}"; do
  [ -n "$t" ] || continue
  if [ "$t" = "$PRIMARY" ]; then render_and_merge "$t" 1; else render_and_merge "$t" 0; fi
done

# cross-repo: grant the current repo read/exec access to the shared handoff dir via
# Claude's additionalDirectories (best-effort; only when claude is wired).
if [ "$TOPOLOGY" = "cross-repo" ] && printf '%s' "$TOOLS" | grep -q claude; then
  HANDOFF_HDPATH="$HDPATH" python3 "$SKILL_DIR/scripts/merge-hooks.py" "$REPO/.claude/settings.json" --add-dir || true
fi

# --- AGENTS.md routing block (idempotent) ---------------------------------------------
# The asset carries a PLACEHOLDER_HANDOFF_DIR token (prettier-safe, unlike a __x__ markdown token);
# substitute the real board path so the block advertises the correct commands (e.g. ../.claude/handoff
# for a shared board, not .agents/handoff).
# The block declares itself "managed by setup-handoff", so refresh it on every run rather than
# only injecting when absent — an insert-only guard let the block drift from the asset forever
# (agents-block-drift-handoff). The splice replaces only the span between the markers and refuses
# on duplicated/unbalanced ones instead of clobbering the file.
python3 "$SKILL_DIR/scripts/splice-agents-block.py" \
  --file "$REPO/AGENTS.md" \
  --template "$ASSETS/agents-handoff.md" \
  --handoff-dir "$HDPATH" || exit 1

echo "setup-handoff: installed at $HDEST (topology=$TOPOLOGY, tools=${TOOLS:-none}, primary=$PRIMARY)"
