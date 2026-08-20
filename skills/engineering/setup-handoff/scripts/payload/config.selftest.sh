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

printf '{ not json\n' > "$T/board/config.json"
handoff_config_load "$T/board" > /dev/null 2>&1
chk "malformed json exits non-zero" 1 "$([ $? -ne 0 ] && echo 1 || echo 0)"

echo "Summary: $P passed, $F failed"
[ "$F" -gt 0 ] && exit 1 || exit 0
