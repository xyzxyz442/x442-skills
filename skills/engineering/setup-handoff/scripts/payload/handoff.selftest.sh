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

printf '\ncmd_export — claim before stamp\n'
# A concurrent agent already holds the lease. cmd_export must fail on the claim BEFORE it writes
# the brief or stamps the doc — a lease taken after stamping would leave the doc reading
# "delegated" and a brief on disk with no lease actually held.
hb "$R" new claim-race --title "Claim race" > /dev/null
hb "$R" claim claim-race "already working it" > /dev/null
RACE_OUT="$(hb "$R" export claim-race --to Bob)"
chk_contains "failed claim reports CLAIMED" "$RACE_OUT" "CLAIMED"
RACE_DOC="$BOARD/claim-race-handoff.md"
RACE_BRIEF="$BOARD/briefs/claim-race-handoff.brief.md"
chk "no brief written when the claim fails" "no" "$([ -f "$RACE_BRIEF" ] && echo yes || echo no)"
chk "doc not stamped delegated_to when the claim fails" "" "$(sed -n 's/^delegated_to: //p' "$RACE_DOC" | head -1)"
chk "doc not stamped brief when the claim fails" "" "$(sed -n 's/^brief: //p' "$RACE_DOC" | head -1)"

printf '\nbrief_identity — pipe in audience does not shift fields\n'
# fold_colons only folds ":"; an --audience value carrying "|" must not corrupt the packed
# "name|origin|root|note" string that brief_identity returns for the caller's IFS='|' read.
hb "$R" new pipe-aud --title "Pipe audience" --audience "foo|bar" > /dev/null
hb "$R" export pipe-aud --no-claim > /dev/null
PIPE_BRIEF="$BOARD/briefs/pipe-aud-handoff.brief.md"
chk "repo_name field carries the (pipe-stripped) audience, not shifted" "foobar" \
  "$(sed -n 's/^repo_name: //p' "$PIPE_BRIEF" | head -1)"
chk "repo_origin field is not shifted by the pipe" "unverified" \
  "$(sed -n 's/^repo_origin: //p' "$PIPE_BRIEF" | head -1)"
chk "repo_root_commit field is not shifted by the pipe" "unverified" \
  "$(sed -n 's/^repo_root_commit: //p' "$PIPE_BRIEF" | head -1)"

# A standalone shared board (see register-cross-repo-handoff) is owned by no repo, so REPO_DIR is
# empty for it — no `git init` here, unlike mkboard above.
mkboard_nogit() { # -> path to a repo-less board (REPO_DIR is empty for it)
  local r
  r="$(mktemp -d)"
  mkdir -p "$r/.agents/handoff/scripts" "$r/.agents/handoff/templates" "$r/.agents/handoff/archive"
  cp "$HERE/handoff" "$r/.agents/handoff/handoff"
  cp "$HERE/config.sh" "$r/.agents/handoff/scripts/config.sh"
  cp "$ASSETS"/handoff-*-template.md "$r/.agents/handoff/templates/"
  chmod +x "$r/.agents/handoff/handoff"
  printf '%s' "$r"
}

printf '\ncmd_export — REPO_DIR empty (standalone shared board)\n'
NG="$(mkboard_nogit)"
NGBOARD="$NG/.agents/handoff"
hb "$NG" new nogit-case --title "No repo owns this board" > /dev/null
hb "$NG" export nogit-case --no-claim > /dev/null
NG_DOC="$NGBOARD/nogit-case-handoff.md"
NG_DEST="$NGBOARD/briefs/nogit-case-handoff.brief.md"
chk "stored brief path is the absolute path, not a mangled one" "$NG_DEST" \
  "$(sed -n 's/^brief: //p' "$NG_DOC" | head -1)"
chk "the stored brief path resolves to a real file" "yes" \
  "$([ -f "$(sed -n 's/^brief: //p' "$NG_DOC" | head -1)" ] && echo yes || echo no)"

printf '\nimport --result\n'
fill_brief() { # brief-file status -> fill the frontmatter and Result block
  local b="$1" st="$2" t
  t="$(mktemp)"
  sed -e "s/^result_status:.*/result_status: $st/" \
    -e "s/^result_by:.*/result_by: Alice/" \
    -e "s/^result_at:.*/result_at: 2026-08-22/" "$b" > "$t"
  awk '
    /<!-- handoff:result:begin -->/ {
      print
      print ""
      print "### Status"
      print ""
      print "done"
      print ""
      print "### What changed"
      print ""
      print "Guarded the tenant switch."
      print ""
      print "### Evidence"
      print ""
      print "Ran npm test -- tenant; 14 passing."
      print ""
      print "### Commits and PR"
      print ""
      print "abc1234, PR #42"
      print ""
      print "### Open questions and follow-ups"
      print ""
      print "None."
      print ""
      skip = 1
      next
    }
    /<!-- handoff:result:end -->/ { skip = 0 }
    !skip { print }
  ' "$t" > "$b"
  rm -f "$t"
}

fill_brief "$BRIEF" done
hb "$R" import --result "$BRIEF" > /dev/null
DOC="$BOARD/rbac-gap-handoff.md"
chk "status still NOT done" "open" "$(sed -n 's/^status: //p' "$DOC" | head -1)"
chk "claim recorded as a claim" "done" "$(sed -n 's/^result_claimed: //p' "$DOC" | head -1)"
chk "reporter recorded" "Alice" "$(sed -n 's/^result_from: //p' "$DOC" | head -1)"
chk "flagged for review" "pending" "$(sed -n 's/^review: //p' "$DOC" | head -1)"
chk_contains "result spliced into the doc" "$(cat "$DOC")" "Guarded the tenant switch."

hb "$R" import --result "$BRIEF" > /dev/null
chk "re-import does not duplicate" "1" "$(grep -c 'Guarded the tenant switch.' "$DOC")"

printf '\nimport --result refusals\n'
WRONG="$(mktemp)"
sed 's/^repo_root_commit: .*/repo_root_commit: 0000000000000000000000000000000000000000/' "$BRIEF" > "$WRONG"
chk_contains "wrong repo refused" "$(hb "$R" import --result "$WRONG")" "different repository"

BADV="$(mktemp)"
sed 's/^brief: 1$/brief: 99/' "$BRIEF" > "$BADV"
chk_contains "unknown format refused" "$(hb "$R" import --result "$BADV")" "brief format"

R2="$(mkboard)"
hb "$R2" new other-thing --title "Other" --severity low > /dev/null
hb "$R2" export other-thing > /dev/null
UNFILLED="$R2/.agents/handoff/briefs/other-thing-handoff.brief.md"
chk_contains "unfilled result refused" "$(hb "$R2" import --result "$UNFILLED")" "not filled in"

SECRET="$(mktemp)"
sed 's/Ran npm test -- tenant; 14 passing./token AKIAIOSFODNN7EXAMPLE/' "$BRIEF" > "$SECRET"
chk_contains "secret-bearing result refused" "$(hb "$R" import --result "$SECRET")" "looks like a credential"

printf '\n--- %d passed, %d failed ---\n' "$P" "$F"
[ "$F" -eq 0 ]
