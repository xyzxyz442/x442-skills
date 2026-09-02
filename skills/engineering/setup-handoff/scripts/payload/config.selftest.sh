#!/usr/bin/env bash
# Self-test for config.sh. Read-only outside its own temp dir. Run: bash config.selftest.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/config.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
P=0
F=0
chk() { # label expected actual
  if [ "$2" = "$3" ]; then
    printf '  [PASS] %s\n' "$1"
    P=$((P + 1))
  else
    printf '  [FAIL] %s (want %s, got %s)\n' "$1" "$2" "$3"
    F=$((F + 1))
  fi
}

mkdir -p "$T/board"
eval "$(handoff_config_load "$T/board")"
chk "default ttl" 4 "$HC_TTL_HOURS"
chk "default topology" single-repo "$HC_TOPOLOGY"

printf 'TOPOLOGY=cross-repo\nHANDOFF_TTL_HOURS=7\n' > "$T/board/config"
eval "$(handoff_config_load "$T/board")"
chk "legacy shell config honored" 7 "$HC_TTL_HOURS"
chk "legacy topology honored" cross-repo "$HC_TOPOLOGY"

printf '{"ttlHours": 9, "groups": ["a","b"], "allowVerifyCmd": true}\n' > "$T/board/config.json"
eval "$(handoff_config_load "$T/board")"
chk "json beats legacy" 9 "$HC_TTL_HOURS"
chk "groups joined" "a,b" "$HC_GROUPS"
chk "bool as 1" 1 "$HC_ALLOW_VERIFY_CMD"

mkdir -p "$T/repo/.agents"
printf '{"repo":"myrepo","group":"g1","ttlHours":12}\n' > "$T/repo/.agents/handoff.config.json"
eval "$(handoff_config_load "$T/board" "$T/repo")"
chk "repo beats board" 12 "$HC_TTL_HOURS"
chk "repo identity" myrepo "$HC_REPO_NAME"
chk "repo group" g1 "$HC_GROUP"

mkdir -p "$T/board_null"
printf '{"ttlHours": null}\n' > "$T/board_null/config.json"
eval "$(handoff_config_load "$T/board_null")"
chk "null ttlHours falls back to default" 4 "$HC_TTL_HOURS"

# Simulate a machine without python3 (by shadowing the `command` builtin in a subshell) to prove
# the no-python3 branch errors on a present repo config.json instead of silently ignoring it.
mkdir -p "$T/board3" "$T/repo3/.agents"
printf '{"repo":"myrepo3"}\n' > "$T/repo3/.agents/handoff.config.json"
(
  command() {
    if [ "$1" = "-v" ] && [ "$2" = "python3" ]; then
      return 1
    fi
    builtin command "$@"
  }
  handoff_config_load "$T/board3" "$T/repo3"
) > /dev/null 2>&1
chk "no-python3 errors on repo config.json" 1 "$([ $? -ne 0 ] && echo 1 || echo 0)"

# Never execute config content: a command substitution must survive as a literal.
printf 'REPO_NAME=$(touch %s/PWNED)\n' "$T" > "$T/board2_config"
mkdir -p "$T/board2"
cp "$T/board2_config" "$T/board2/config"
eval "$(handoff_config_load "$T/board2")" 2> /dev/null
[ -f "$T/PWNED" ] && {
  printf '  [FAIL] legacy config was EXECUTED\n'
  F=$((F + 1))
} \
  || {
    printf '  [PASS] legacy config parsed, not executed\n'
    P=$((P + 1))
  }

# --- one filename at every layer -----------------------------------------------------------
# `handoff.json` replaced five names. Every predecessor is still READ, at lower precedence than
# the file that replaced it in the same directory, so an install that has never been re-run keeps
# working — that is what the legacy cases above now prove. These prove the new name wins.
mkdir -p "$T/onefile/.agents" "$T/oneboard"
printf 'TOPOLOGY=single-repo\nHANDOFF_TTL_HOURS=1\n' > "$T/oneboard/config"
printf '{"ttlHours": 2, "groups": ["old"]}\n' > "$T/oneboard/config.json"
printf '{"ttlHours": 3, "groups": ["new"], "environments": ["dev","canary","prod"]}\n' > "$T/oneboard/handoff.json"
eval "$(handoff_config_load "$T/oneboard")"
chk "board handoff.json beats config.json beats the shell config" 3 "$HC_TTL_HOURS"
chk "and its groups win too" "new" "$HC_GROUPS"
chk "the environment ladder is board-global config" "dev,canary,prod" "$HC_ENVIRONMENTS"

printf '{"repo":"legacy-id","group":"gL"}\n' > "$T/onefile/.agents/handoff.config.json"
printf '{"repo":"current-id","board":"../workspace/handoff"}\n' > "$T/onefile/.agents/handoff.json"
eval "$(handoff_config_load "$T/oneboard" "$T/onefile")"
chk "repo handoff.json beats handoff.config.json" "current-id" "$HC_REPO_NAME"
chk "a key only the older file sets is still inherited" "gL" "$HC_GROUP"
chk "board is the canonical name for where the board is" "../workspace/handoff" "$HC_BOARD_PATH"

# `boardPath` was the older spelling of the same key and still resolves to it — one meaning, and
# a repo written before the rename must not silently lose its board.
mkdir -p "$T/oldboardkey/.agents"
printf '{"boardPath":"../workspace/old-handoff"}\n' > "$T/oldboardkey/.agents/handoff.json"
eval "$(handoff_config_load "$T/oneboard" "$T/oldboardkey")"
chk "boardPath is accepted as board" "../workspace/old-handoff" "$HC_BOARD_PATH"

# `groups` is the SAME key at two fidelities: a bare list on a board, a map of definitions in a
# workspace manifest. Both answer "which sections exist", so both yield the section names rather
# than splitting into two keys that would have to be kept in sync.
mkdir -p "$T/mapgroups"
printf '{"groups": {"infra": {"repos": []}, "auth": {"repos": []}, "gone": {"remove": true}}}\n' > "$T/mapgroups/handoff.json"
eval "$(handoff_config_load "$T/mapgroups")"
chk "a groups MAP yields its names, sorted, minus tombstones" "auth,infra" "$HC_GROUPS"

printf '{ not json\n' > "$T/board/config.json"
handoff_config_load "$T/board" > /dev/null 2>&1
chk "malformed json exits non-zero" 1 "$([ $? -ne 0 ] && echo 1 || echo 0)"

echo "Summary: $P passed, $F failed"
[ "$F" -gt 0 ] && exit 1 || exit 0
