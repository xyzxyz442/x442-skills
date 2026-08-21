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
# Deliberately NOT exported: this process needs it (sourcing happens in-process, no subshell
# required), but the `hb` helper below runs the board's own copy of `handoff` as a subprocess —
# an exported HANDOFF_NO_MAIN would leak into that subprocess and make it skip its own dispatch
# too, silently no-op-ing every end-to-end check.
HANDOFF_NO_MAIN=1
# shellcheck disable=SC1091
. "$HERE/handoff"

printf '\nrepo_origin_norm\n'
chk "ssh form" "github.com/acme/acme-api" "$(repo_origin_norm 'git@github.com:acme/acme-api.git')"
chk "https form" "github.com/acme/acme-api" "$(repo_origin_norm 'https://github.com/acme/acme-api.git')"
chk "https with credentials" "github.com/acme/acme-api" "$(repo_origin_norm 'https://user:tok@github.com/acme/acme-api.git')"
chk "no .git suffix" "github.com/acme/acme-api" "$(repo_origin_norm 'https://github.com/acme/acme-api')"
chk "trailing slash" "github.com/acme/acme-api" "$(repo_origin_norm 'https://github.com/acme/acme-api/')"
chk "no colon survives" "" "$(repo_origin_norm 'git@github.com:acme/acme-api.git' | tr -cd ':')"

printf '\ndoc_section\n'
DS="$(mktemp -d)"
trap 'rm -rf "$DS"' EXIT
cat > "$DS/doc.md" << 'DOCEOF'
---
id: rbac-gap-handoff
---

## Context

symptom leads to cause

## Where

src/auth/tenant.ts:88

## Verify

run the suite
DOCEOF
chk "extracts a middle section" "src/auth/tenant.ts:88" "$(doc_section "$DS/doc.md" Where | tr -d '\n')"
chk "extracts the last section" "run the suite" "$(doc_section "$DS/doc.md" Verify | tr -d '\n')"
chk "absent section is empty" "" "$(doc_section "$DS/doc.md" Decisions | tr -d '\n')"

# A throwaway board inside its own git repo. The board must be a real git repo because export
# reads repo identity from it.
mkboard() { # -> path to the repo root
  local r
  r="$(mktemp -d)"
  git -C "$r" init -q
  git -C "$r" config user.email "test@example.com"
  git -C "$r" config user.name "test"
  git -C "$r" remote add origin "git@github.com:acme/acme-api.git"
  printf 'x\n' > "$r/README.md"
  git -C "$r" add -A
  git -C "$r" commit -qm "initial commit"
  mkdir -p "$r/.agents/handoff/scripts" "$r/.agents/handoff/templates" "$r/.agents/handoff/archive"
  cp "$HERE/handoff" "$r/.agents/handoff/handoff"
  cp "$HERE/config.sh" "$r/.agents/handoff/scripts/config.sh"
  cp "$ASSETS"/handoff-*-template.md "$r/.agents/handoff/templates/"
  chmod +x "$r/.agents/handoff/handoff"
  printf '%s' "$r"
}

hb() { # repo subcommand... -> run the board CLI from inside that repo
  (cd "$1" && shift && ./.agents/handoff/handoff "$@") 2>&1
}

printf '\ncmd_export\n'
R="$(mkboard)"
BOARD="$R/.agents/handoff"
hb "$R" new rbac-gap --title "RBAC gap on tenant switch" --severity high > /dev/null
BRIEF="$BOARD/briefs/rbac-gap-handoff.brief.md"

hb "$R" export rbac-gap --to "Alice" > /dev/null
chk "brief was written" "yes" "$([ -f "$BRIEF" ] && echo yes || echo no)"
chk "brief names the handoff" "rbac-gap-handoff" "$(sed -n 's/^handoff: //p' "$BRIEF" | head -1)"
chk "brief carries root commit" "$(git -C "$R" rev-list --max-parents=0 HEAD | tail -1)" \
  "$(sed -n 's/^repo_root_commit: //p' "$BRIEF" | head -1)"
chk "origin normalized" "github.com/acme/acme-api" "$(sed -n 's/^repo_origin: //p' "$BRIEF" | head -1)"
chk "no colon in frontmatter values" "" "$(sed -n '2,/^---$/p' "$BRIEF" | sed 's/^[a-z_]*://' | tr -cd ':')"
chk "default branch" "fix/rbac-gap-handoff" "$(sed -n 's/^branch: //p' "$BRIEF" | head -1)"
chk "result_status ships empty" "" "$(sed -n 's/^result_status:[[:space:]]*//p' "$BRIEF" | head -1)"
chk_contains "result markers present" "$(cat "$BRIEF")" "<!-- handoff:result:begin -->"

DOC="$BOARD/rbac-gap-handoff.md"
chk "doc records the delegate" "Alice" "$(sed -n 's/^delegated_to: //p' "$DOC" | head -1)"
chk "doc records the brief path" "yes" "$(grep -q '^brief: ' "$DOC" && echo yes || echo no)"
chk "export took the lease" "yes" "$([ -d "$BOARD/.locks/rbac-gap-handoff" ] && echo yes || echo no)"
chk "status untouched by export" "open" "$(sed -n 's/^status: //p' "$DOC" | head -1)"

chk_contains "flag guard rejects a swallowed flag" "$(hb "$R" export rbac-gap --to --no-claim)" \
  "--to needs a value"

hb "$R" new port-guide --standalone --title "Porting guide" > /dev/null
chk_contains "standalone refused" "$(hb "$R" export port-guide)" "standalone"

printf '\n--- %d passed, %d failed ---\n' "$P" "$F"
[ "$F" -eq 0 ]
