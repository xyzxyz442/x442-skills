#!/usr/bin/env bash
# Self-test for the handoff CLI's export/import round-trip. Read-only outside its own temp dirs.
# Run: bash handoff.selftest.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$(cd "$HERE/../../assets" && pwd)"
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

chk_contains() { # label haystack needle
  case "$2" in
    *"$3"*)
      printf '  [PASS] %s\n' "$1"
      P=$((P + 1))
      ;;
    *)
      printf '  [FAIL] %s (missing %s)\n' "$1" "$3"
      F=$((F + 1))
      ;;
  esac
}

# Sourcing the CLI must not run a command. HANDOFF_NO_MAIN is the guard added in this task.
HANDOFF_NO_MAIN=1
export HANDOFF_NO_MAIN
# shellcheck disable=SC1091
. "$HERE/handoff"

printf '\nrepo_origin_norm\n'
chk "ssh form" "github.com/acme/acme-api" "$(repo_origin_norm 'git@github.com:acme/acme-api.git')"
chk "https form" "github.com/acme/acme-api" "$(repo_origin_norm 'https://github.com/acme/acme-api.git')"
chk "https with credentials" "github.com/acme/acme-api" "$(repo_origin_norm 'https://user:tok@github.com/acme/acme-api.git')"
chk "no .git suffix" "github.com/acme/acme-api" "$(repo_origin_norm 'https://github.com/acme/acme-api')"
chk "trailing slash" "github.com/acme/acme-api" "$(repo_origin_norm 'https://github.com/acme/acme-api/')"
chk "no colon survives" "" "$(repo_origin_norm 'git@github.com:acme/acme-api.git' | tr -cd ':')"

printf '\n--- %d passed, %d failed ---\n' "$P" "$F"
[ "$F" -eq 0 ]
