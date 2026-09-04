#!/usr/bin/env bash
# config.sh — the handoff board's configuration resolver. Sourced by `handoff` and `hooks.sh`;
# never executed directly. Ships in the payload so both readers share ONE implementation of
# precedence rather than each re-deriving it (this payload already has four mirrored copies of
# hooks.sh — a hand-copied resolver is exactly how those drift).
#
# Precedence, nearest wins:  env > repo config.json > board config.json > legacy config > default
# The caller applies the env layer itself, because only it knows which HANDOFF_* name maps to
# which knob; everything below env is resolved here in a single python3 call.
#
# NOTHING here sources a config file. On a cross-repo board the config is written by every member
# repo's installer and read by every member's hooks, so executing it would let one repo run shell
# in its siblings' sessions. The legacy KEY=value file is PARSED for the same reason.

# --- CLI resolution -------------------------------------------------------------------
# Where the `handoff` CLI actually lives, defined ONCE because three readers need the same answer:
# the board's dispatcher (which execs it), the `handoff` CLI itself (for `--which`), and hooks.sh
# (which must know whether a CLI exists at all before it denies anybody an edit). A hand-copied
# ladder in three files is the same drift this resolver exists to end.
#
# Order is fixed and deliberate:  $HANDOFF_BIN  >  user-level install  >  the board's vendored copy.
# The env var is an operator override (testing an unreleased CLI, or a harness pointing every
# fixture at one binary). The user-level install is what setup-handoff writes and what upgrades on
# its own cadence. The vendored copy is last because it is the one that goes stale — but it is
# still there, because a cold clone with nothing but bash must work.
handoff_cli_home() { # -> the directory setup-handoff installs the user-level CLI into
  printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/handoff"
}

# A candidate must be a readable, NON-EMPTY regular file to count as a rung.
#
# Existence alone is not enough, and the gap is not cosmetic: an interrupted copy leaves a
# zero-byte file, `bash` runs it happily, and every command exits 0 having done nothing. `handoff
# claim` then reports success while the lease stays with whoever really holds it — and the run
# discipline tells agents to trust that exit code. A silently-successful claim is the worst
# failure this tool has, so a rung that cannot possibly work is SKIPPED rather than selected:
# the ladder falls through to a copy that does work, and if none does, the dispatcher's
# gate-is-off path fires, which is loud.
handoff_cli_usable() { # path -> 0 when it can actually be exec'd as a CLI
  [ -n "${1:-}" ] && [ -f "$1" ] && [ -r "$1" ] && [ -s "$1" ]
}

handoff_cli_resolve() { # board-dir -> prints "<source> <path>"; returns 1 when nothing resolves
  local board="${1:-}" c
  if handoff_cli_usable "${HANDOFF_BIN:-}"; then
    printf 'env %s' "$HANDOFF_BIN"
    return 0
  fi
  c="$(handoff_cli_home)/handoff"
  if handoff_cli_usable "$c"; then
    printf 'user %s' "$c"
    return 0
  fi
  if [ -n "$board" ] && handoff_cli_usable "$board/scripts/handoff-cli"; then
    printf 'vendored %s' "$board/scripts/handoff-cli"
    return 0
  fi
  return 1
}

# --- board git substrate (ADR 0002) ----------------------------------------------------
# Lives here, beside the config resolver, for the reason stated above: `handoff` and `hooks.sh` are
# two readers of one board, and anything they each re-derive is something they can each get wrong
# differently. Lease expiry is the sharp case — if the CLI and the edit gate disagree about when a
# lease lapses, the gate denies edits to the holder or admits them to everyone else, and neither
# side reports a problem.
#
# A board is SHARED when it is the root of its own git worktree AND has a remote. Merely sitting
# inside some repository is not enough: a nested board's remote belongs to the repo containing it,
# so committing a lease there would push that repo's source alongside it.
handoff_board_git() { # board-dir git-args...
  local b="$1"
  shift
  git -C "$b" "$@" 2> /dev/null
}
handoff_board_remote() { handoff_board_git "$1" remote | head -1; }

handoff_leases_shared() { # board-dir -> 0 when leases are shared state of record
  local b="$1" top
  top="$(handoff_board_git "$b" rev-parse --show-toplevel)" || return 1
  [ -n "$top" ] || return 1
  # `pwd -P` on both sides: git always reports the PHYSICAL toplevel, while `pwd` reports the
  # logical path the caller arrived by. On macOS a board under $TMPDIR is reached through /var and
  # lives at /private/var, so a logical comparison decides no board is ever its own repo — and
  # every shared-board behavior switches itself off without a word.
  [ "$(cd "$top" && pwd -P)" = "$(cd "$b" && pwd -P)" ] || return 1
  [ -n "$(handoff_board_remote "$b")" ]
}

# Expiry of a COMMITTED lease is stamped from the commit that recorded it, never from the wall
# clock of the machine that wrote the file. Two machines' clocks do not agree, and the whole point
# of a shared lease is that both of them read the same deadline out of it: a claimer running an
# hour fast would otherwise hand every peer a lease that already looks expired. `ttl_hours=` travels
# inside the owner file so the reader applies the CLAIMER's TTL rather than its own.
#
# Falls back to the recorded `expires=` whenever git cannot answer — a local-only board, a lease
# not yet committed, no git at all — so a board without a remote is unchanged in behavior.
handoff_lease_expiry() { # board-dir owner-file fallback-expires default-ttl-hours -> epoch seconds
  local b="$1" f="$2" fallback="${3:-0}" ttl_default="${4:-4}" ct ttl
  handoff_leases_shared "$b" || {
    printf '%s' "$fallback"
    return
  }
  ct="$(handoff_board_git "$b" log -1 --format=%ct -- "$f")"
  [ -n "$ct" ] || {
    printf '%s' "$fallback"
    return
  }
  ttl="$(sed -n 's/^ttl_hours=//p' "$f" 2> /dev/null)"
  case "$ttl" in '' | *[!0-9]*) ttl="$ttl_default" ;; esac
  printf '%s' "$((ct + ttl * 3600))"
}

# handoff_config_load BOARD_DIR [REPO_DIR] -> prints shell assignments; non-zero on bad config.
#
# ONE filename, `handoff.json`, at every layer. It used to be six files with five names — a board
# `config.json`, a generated `repos.json`, a `.version` stamp, a repo `handoff.config.json`, a
# workspace `.handoff-repos.json`, and a machine-local locations map — and nobody could answer
# "where is handoff configured" without listing all of them. They are now layers of one cascade
# distinguished by WHERE they sit, not by what they are called, which is the same shape AGENTS.md
# already uses and the same shape the fleet manifest's own user/scope/subdir cascade already had.
#
# Every legacy name is still READ, at lower precedence than the file that replaced it, so an
# existing install keeps working untouched until its installer is re-run.
handoff_config_load() {
  local board="$1" repo="${2:-}"
  if ! command -v python3 > /dev/null 2>&1; then
    if [ -f "$board/handoff.json" ] || [ -f "$board/config.json" ]; then
      echo "handoff: handoff.json needs python3, which is not installed" >&2
      return 3
    fi
    if [ -n "$repo" ] && { [ -f "$repo/.agents/handoff.json" ] || [ -f "$repo/.agents/handoff.config.json" ]; }; then
      echo "handoff: $repo/.agents/handoff.json needs python3, which is not installed" >&2
      return 3
    fi
    _handoff_config_legacy_nopython "$board"
    return $?
  fi
  python3 - "$board" "$repo" << 'PY'
import json, os, shlex, sys

board, repo = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")

def read_json(path):
    if not os.path.isfile(path):
        return {}
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (ValueError, OSError) as exc:
        sys.stderr.write("handoff: cannot read %s: %s\n" % (path, exc))
        sys.exit(3)
    if not isinstance(data, dict):
        sys.stderr.write("handoff: %s must contain a JSON object\n" % path)
        sys.exit(3)
    return data

# Legacy KEY=value, parsed rather than sourced. Only the keys the board ever wrote are mapped;
# anything else in an old file is ignored rather than guessed at.
LEGACY = {
    "TOPOLOGY": "topology", "REPO_NAME": "repoName",
    "HANDOFF_GROUPS": "groups", "HANDOFF_GROUP_LAYOUT": "groupLayout",
    "HANDOFF_TTL_HOURS": "ttlHours", "HANDOFF_ALLOW_VERIFY_CMD": "allowVerifyCmd",
    "HANDOFF_ENVIRONMENTS": "environments",
}

def read_legacy(path):
    out = {}
    if not os.path.isfile(path):
        return out
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            if key in LEGACY:
                out[LEGACY[key]] = val.strip().strip('"').strip("'")
    return out

cfg = {"topology": "single-repo", "repoName": "", "group": "", "groups": [],
       "groupLayout": "", "ttlHours": 4, "allowVerifyCmd": False, "board": "",
       # Ordered lowest-environment-first. Board-global because an index that sorted one member's
       # work by a different ladder than another's would not be one board's index.
       "environments": ["dev", "staging", "prod"]}

# Board layer, oldest name first so the newest wins: KEY=value, then config.json, then handoff.json.
cfg.update(read_legacy(os.path.join(board, "config")))
cfg.update(read_json(os.path.join(board, "config.json")))
cfg.update(read_json(os.path.join(board, "handoff.json")))

if repo:
    # The repo scope names identity from the repo's point of view: `repo` is "who am I on this
    # board", which is the board's `repoName` (ADR 0006 — each layer names its subject from its
    # own file's point of view, so the two are NOT converged). `boardPath` was a second name for
    # `board`; both are accepted, and both mean the same thing — where this repo's board is.
    for src in (os.path.join(repo, ".agents", "handoff.config.json"),
                os.path.join(repo, ".agents", "handoff.json")):
        data = read_json(src)
        for key, val in data.items():
            if key in ("repo", "board"):
                continue  # this layer's documented keys, applied last — see below
            cfg["board" if key == "boardPath" else key] = val
        # The documented keys go on LAST so a superseded spelling can never beat the live one.
        # merge-hooks.py carries a legacy `boardPath` forward alongside the `board` that replaced
        # it, so BOTH sit on disk in every repo that predates the rename; applied in file order
        # (json.dump sorts keys, so `boardPath` follows `board`) the dead key won, and repointing
        # a repo by editing `board` silently did nothing.
        if "repo" in data:
            cfg["repoName"] = data["repo"]
        if "board" in data:
            cfg["board"] = data["board"]

# `groups` carries the section names, and it is accepted in either fidelity. A board records the
# bare list of sections it hosts; a workspace manifest records the same names mapped to their
# member repos. They are the same fact at two levels of detail, so they share one key rather than
# splitting into `groups` and `groupDefs` — the resolver that needs the members reads the map, and
# everything that only needs the names reads the keys.
groups = cfg.get("groups") or []
if isinstance(groups, dict):
    groups = [g for g, v in sorted(groups.items())
              if not (isinstance(v, dict) and v.get("remove"))]
elif isinstance(groups, str):
    groups = [g for g in groups.split(",") if g]

envs = cfg.get("environments") or []
if isinstance(envs, str):
    envs = [e for e in envs.split(",") if e]

def emit(name, val):
    if isinstance(val, bool):
        val = "1" if val else "0"
    print("%s=%s" % (name, shlex.quote(str(val))))

emit("HC_TOPOLOGY", cfg.get("topology") or "single-repo")
emit("HC_REPO_NAME", cfg.get("repoName") or "")
emit("HC_GROUP", cfg.get("group") or "")
emit("HC_GROUPS", ",".join(str(g) for g in groups))
emit("HC_GROUP_LAYOUT", cfg.get("groupLayout") or cfg.get("layout") or "")
emit("HC_TTL_HOURS", cfg.get("ttlHours") or 4)
emit("HC_ALLOW_VERIFY_CMD", cfg.get("allowVerifyCmd") or False)
emit("HC_BOARD_PATH", cfg.get("board") or "")
emit("HC_ENVIRONMENTS", ",".join(str(e) for e in envs))
PY
}

# Legacy-only reader for a machine without python3. Reached only when there is no config.json,
# so a board that predates JSON keeps working exactly as it did. Still parses, never sources.
_handoff_config_legacy_nopython() {
  local board="$1" f="$1/config"
  local topology=single-repo repo_name="" groups="" layout="" ttl=4 allow=0
  if [ -f "$f" ]; then
    topology="$(sed -n 's/^TOPOLOGY=//p' "$f" | tail -1 | tr -d '"'"'"'')"
    repo_name="$(sed -n 's/^REPO_NAME=//p' "$f" | tail -1 | tr -d '"'"'"'')"
    groups="$(sed -n 's/^HANDOFF_GROUPS=//p' "$f" | tail -1 | tr -d '"'"'"'')"
    layout="$(sed -n 's/^HANDOFF_GROUP_LAYOUT=//p' "$f" | tail -1 | tr -d '"'"'"'')"
    ttl="$(sed -n 's/^HANDOFF_TTL_HOURS=//p' "$f" | tail -1 | tr -d '"'"'"'')"
    allow="$(sed -n 's/^HANDOFF_ALLOW_VERIFY_CMD=//p' "$f" | tail -1 | tr -d '"'"'"'')"
  fi
  printf 'HC_TOPOLOGY=%s\n' "$(printf %q "${topology:-single-repo}")"
  printf 'HC_REPO_NAME=%s\n' "$(printf %q "$repo_name")"
  printf 'HC_GROUP=%s\n' "''"
  printf 'HC_GROUPS=%s\n' "$(printf %q "$groups")"
  printf 'HC_GROUP_LAYOUT=%s\n' "$(printf %q "$layout")"
  printf 'HC_TTL_HOURS=%s\n' "$(printf %q "${ttl:-4}")"
  printf 'HC_ALLOW_VERIFY_CMD=%s\n' "$(printf %q "${allow:-0}")"
  printf 'HC_BOARD_PATH=%s\n' "''"
  printf 'HC_ENVIRONMENTS=%s\n' "$(printf %q "dev,staging,prod")"
}
