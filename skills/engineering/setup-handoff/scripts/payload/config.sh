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

# handoff_config_load BOARD_DIR [REPO_DIR] -> prints shell assignments; non-zero on bad config.
handoff_config_load() {
  local board="$1" repo="${2:-}"
  if ! command -v python3 > /dev/null 2>&1; then
    if [ -f "$board/config.json" ]; then
      echo "handoff: config.json needs python3, which is not installed" >&2
      return 3
    fi
    if [ -n "$repo" ] && [ -f "$repo/.agents/handoff.config.json" ]; then
      echo "handoff: $repo/.agents/handoff.config.json needs python3, which is not installed" >&2
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
       "groupLayout": "", "ttlHours": 4, "allowVerifyCmd": False, "boardPath": ""}
cfg.update(read_legacy(os.path.join(board, "config")))
cfg.update(read_json(os.path.join(board, "config.json")))
if repo:
    # The repo scope names identity from the repo's point of view: `repo` is "who am I on this
    # board", which is the board's `repoName`. Everything else keeps its name.
    for key, val in read_json(os.path.join(repo, ".agents", "handoff.config.json")).items():
        cfg["repoName" if key == "repo" else key] = val

groups = cfg.get("groups") or []
if isinstance(groups, str):
    groups = [g for g in groups.split(",") if g]

def emit(name, val):
    if isinstance(val, bool):
        val = "1" if val else "0"
    print("%s=%s" % (name, shlex.quote(str(val))))

emit("HC_TOPOLOGY", cfg.get("topology") or "single-repo")
emit("HC_REPO_NAME", cfg.get("repoName") or "")
emit("HC_GROUP", cfg.get("group") or "")
emit("HC_GROUPS", ",".join(str(g) for g in groups))
emit("HC_GROUP_LAYOUT", cfg.get("groupLayout") or "")
emit("HC_TTL_HOURS", cfg.get("ttlHours") or 4)
emit("HC_ALLOW_VERIFY_CMD", cfg.get("allowVerifyCmd") or False)
emit("HC_BOARD_PATH", cfg.get("boardPath") or "")
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
}
