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

printf '\nrepo_provider_of and repo_path_of\n'
chk "github" "github" "$(repo_provider_of 'github.com/acme/acme-api')"
chk "gitlab" "gitlab" "$(repo_provider_of 'gitlab.com/acme/acme-api')"
chk "bitbucket" "bitbucket" "$(repo_provider_of 'bitbucket.org/acme/acme-api')"
chk "self-hosted is other" "other" "$(repo_provider_of 'git.acme-corp.internal/acme/acme-api')"
chk "empty is unknown, not other" "unknown" "$(repo_provider_of '')"
chk "a repo with no remote reads unknown, not a recognized host" "unknown" "$(repo_provider_of "$(repo_origin_norm '')")"
chk "known host is dropped from the path" "acme/acme-api" "$(repo_path_of 'github.com/acme/acme-api')"
chk "gitlab host is dropped too" "acme/acme-api" "$(repo_path_of 'gitlab.com/acme/acme-api')"
chk "self-hosted keeps its host" "git.acme-corp.internal/acme/acme-api" "$(repo_path_of 'git.acme-corp.internal/acme/acme-api')"

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
chk "origin drops the known host" "acme/acme-api" "$(sed -n 's/^repo_origin: //p' "$BRIEF" | head -1)"
chk "brief records the provider" "github" "$(sed -n 's/^repo_provider: //p' "$BRIEF" | head -1)"
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

printf '\nbrief_identity — a same-named sibling directory is never trusted as identity (finding 6)\n'
# The OLD implementation guessed the cross-repo target by testing "${REPO_DIR}/../$aud/.git" and,
# on a match, treated it as VERIFIED — even though register-cross-repo-handoff's manifest (not
# read here) is the only authoritative source. Prove the guess is gone by constructing exactly the
# case that used to fool it: a git repo sibling to the board repo, sharing the audience's name.
SIB_NAME="acme-sibling-$$"
SIBLING="$(dirname "$R")/$SIB_NAME"
mkdir -p "$SIBLING"
git -C "$SIBLING" init -q
git -C "$SIBLING" config user.email "test@example.com"
git -C "$SIBLING" config user.name "test"
printf 'x\n' > "$SIBLING/README.md"
git -C "$SIBLING" add -A
git -C "$SIBLING" commit -qm "sibling initial commit"
SIBLING_ROOT="$(git -C "$SIBLING" rev-list --max-parents=0 HEAD | tail -1)"
hb "$R" new sibling-aud-case --title "Sibling audience case" --audience "$SIB_NAME" > /dev/null
hb "$R" export sibling-aud-case --no-claim > /dev/null
SIB_BRIEF="$BOARD/briefs/sibling-aud-case-handoff.brief.md"
chk "cross-repo identity degrades to unverified, never guesses a same-named sibling directory" "unverified" \
  "$(sed -n 's/^repo_root_commit: //p' "$SIB_BRIEF" | head -1)"
chk "the sibling repo's REAL root commit never appears in the brief" "no" \
  "$(grep -Fq "$SIBLING_ROOT" "$SIB_BRIEF" && echo yes || echo no)"
[ -n "$SIBLING" ] && [ -d "$SIBLING" ] && trash "$SIBLING" 2> /dev/null

printf '\ncmd_export — bundle (orchestrator) stamps the parent and pre-flights every child\n'
hb "$R" new bundle-child-1 --title "Bundle child 1" > /dev/null
hb "$R" new bundle-child-2 --title "Bundle child 2" > /dev/null
hb "$R" new bundle-parent --orchestrator --children bundle-child-1,bundle-child-2 --title "Bundle parent" > /dev/null
hb "$R" export bundle-parent --to Zara > /dev/null
BUNDLE_DOC="$BOARD/bundle-parent-handoff.md"
BUNDLE_COVER="$BOARD/briefs/bundle-parent-handoff.cover.md"
# Finding 4: export_bundle used to stamp only the children, leaving the orchestrator doc with no
# delegated_to/delegated_at/brief and no Activity entry — invisible to `list`'s recipient column
# and to repair-handoff's orphaned-delegation check, which keys on delegated_at.
chk "orchestrator doc records the delegate" "Zara" "$(sed -n 's/^delegated_to: //p' "$BUNDLE_DOC" | head -1)"
chk "orchestrator doc records delegated_at" "yes" "$([ -n "$(sed -n 's/^delegated_at: //p' "$BUNDLE_DOC" | head -1)" ] && echo yes || echo no)"
chk "orchestrator doc's brief: points at the cover file" "yes" \
  "$(grep -q '^brief: ' "$BUNDLE_DOC" && echo yes || echo no)"
chk "the cover file was actually written" "yes" "$([ -f "$BUNDLE_COVER" ] && echo yes || echo no)"
chk_contains "Activity log records the bundle export" "$(cat "$BUNDLE_DOC")" "bundle cover"

printf '\ncmd_export — bundle pre-flight refuses the WHOLE export on a live foreign lease (finding 5)\n'
hb "$R" new bundle-child-3 --title "Bundle child 3" > /dev/null
hb "$R" new bundle-child-4 --title "Bundle child 4" > /dev/null
hb "$R" new bundle-parent-2 --orchestrator --children bundle-child-3,bundle-child-4 --title "Bundle parent 2" > /dev/null
hb "$R" claim bundle-child-4 "already working it" > /dev/null
BUNDLE2_DOC="$BOARD/bundle-parent-2-handoff.md"
BUNDLE2_COVER="$BOARD/briefs/bundle-parent-2-handoff.cover.md"
CHILD3_DOC="$BOARD/bundle-child-3-handoff.md"
BUNDLE2_OUT="$(hb "$R" export bundle-parent-2 --to Yara)"
chk_contains "refuses the whole export when any child has a live lease" "$BUNDLE2_OUT" "lease"
chk "no cover file was written by the refused export" "no" "$([ -f "$BUNDLE2_COVER" ] && echo yes || echo no)"
chk "the untouched child was never claimed" "no" "$([ -d "$BOARD/.locks/bundle-child-3-handoff" ] && echo yes || echo no)"
chk "the untouched child's doc was never stamped delegated_to" "" "$(sed -n 's/^delegated_to: //p' "$CHILD3_DOC" | head -1)"
chk "the orchestrator itself was never stamped delegated_to" "" "$(sed -n 's/^delegated_to: //p' "$BUNDLE2_DOC" | head -1)"

printf '\ncmd_export — bundle skips a child with no doc on the board (must-fix coverage gap)\n'
hb "$R" new bundle-child-5 --title "Bundle child 5" > /dev/null
hb "$R" new bundle-parent-3 --orchestrator --children bundle-child-5,bundle-child-ghost --title "Bundle parent 3" > /dev/null
BUNDLE3_OUT="$(hb "$R" export bundle-parent-3 --to Wendy --no-claim)"
BUNDLE3_COVER="$BOARD/briefs/bundle-parent-3-handoff.cover.md"
CHILD5_BRIEF="$BOARD/briefs/bundle-child-5-handoff.brief.md"
chk_contains "the missing child is reported as skipped, not fatal" "$BUNDLE3_OUT" "skipped"
chk "the real child still got its own brief" "yes" "$([ -f "$CHILD5_BRIEF" ] && echo yes || echo no)"
chk "the ghost child is not listed in the cover" "no" "$(grep -q 'bundle-child-ghost' "$BUNDLE3_COVER" && echo yes || echo no)"
chk "the orchestrator still gets stamped for the child that DID export" "Wendy" \
  "$(sed -n 's/^delegated_to: //p' "$BOARD/bundle-parent-3-handoff.md" | head -1)"

printf '\ncmd_export — --branch is refused (not silently discarded) on a bundle export (minor)\n'
hb "$R" new bundle-child-6 --title "Bundle child 6" > /dev/null
hb "$R" new bundle-parent-4 --orchestrator --children bundle-child-6 --title "Bundle parent 4" > /dev/null
chk_contains "bundle export refuses --branch instead of discarding it" \
  "$(hb "$R" export bundle-parent-4 --branch custom-branch --no-claim)" "not supported for a bundle"

printf '\ncmd_export — a relative --out is resolved to an absolute path before being stamped (minor)\n'
hb "$R" new relout-case --title "Relative out dir" > /dev/null
mkdir -p "$R/subdir"
(cd "$R/subdir" && "$R/.agents/handoff/handoff" export relout-case --out ../relout-here --no-claim) > /dev/null 2>&1 # standalone-ok: a throwaway dir name inside this test's own mktemp board, not a repo path
RELOUT_DOC="$BOARD/relout-case-handoff.md"
RELOUT_BRIEF_FIELD="$(sed -n 's/^brief: //p' "$RELOUT_DOC" | head -1)"
# These two checks deliberately keep `case` OUT of a $( ) substitution. Inside one, an unbalanced
# `)` closes the substitution early, so the pattern has to be written `(*..*)` to stay balanced --
# and `prettier --check .` (which covers .sh, though lint-staged does not) insists on stripping
# that leading paren, silently breaking the test. Assigning first sidesteps the whole conflict.
RELOUT_HAS_DOTDOT=no
case "$RELOUT_BRIEF_FIELD" in
  *..*) RELOUT_HAS_DOTDOT=yes ;;
esac
chk "brief: never records a literal .. segment from a relative --out" "no" "$RELOUT_HAS_DOTDOT"

case "$RELOUT_BRIEF_FIELD" in
  /*) RELOUT_ABS="$RELOUT_BRIEF_FIELD" ;;
  *) RELOUT_ABS="$R/$RELOUT_BRIEF_FIELD" ;;
esac
RELOUT_REAL=no
[ -f "$RELOUT_ABS" ] && RELOUT_REAL=yes
chk "the resolved brief: path points at a real file" "yes" "$RELOUT_REAL"

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

printf '\nimport --result — frontmatter fields are colon-folded like the body\n'
# result_at goes through the SAME fold_colons guard as result_by — an executor writing a
# space-separated date/time (which contains a bare ":") must not corrupt the doc's frontmatter.
hb "$R" new colon-at-case --title "Colon in result_at" > /dev/null
hb "$R" export colon-at-case --to Dana > /dev/null
COLONBRIEF="$BOARD/briefs/colon-at-case-handoff.brief.md"
fill_brief "$COLONBRIEF" done
COLON_T="$(mktemp)"
sed 's/^result_at:.*/result_at: 2026-08-22 14:30/' "$COLONBRIEF" > "$COLON_T"
cat "$COLON_T" > "$COLONBRIEF"
rm -f "$COLON_T"
COLONDOC="$BOARD/colon-at-case-handoff.md"
hb "$R" import --result "$COLONBRIEF" > /dev/null
chk "result_at is colon-folded in the doc" "2026-08-22 14 — 30" \
  "$(sed -n 's/^result_at: //p' "$COLONDOC" | head -1)"

printf '\nimport --result — backslash-bearing evidence survives re-import byte-for-byte\n'
# Regression test for a POSIX awk footgun: `awk -v x="$val"` interprets C-style backslash escapes
# (\f, \b, \t, ...) in the assigned value. On some awk builds that silently corrupts a Windows path
# or a regex; on this repo's own awk (the multi-line body trips a FATAL "newline in string" error)
# it instead makes the whole splice a SILENT NO-OP — the `awk ... && cat` guard swallows the
# failure, `import_result` still prints success, and the doc keeps its stale content. Two DISTINCT
# backslash-bearing strings (not the same text reused) so a no-op fails this test exactly like
# byte-mangling would: if the second import didn't really replace anything, the doc still reads
# $evidence1, not $evidence2, and the final `chk` catches that mismatch too.
#
# inject_evidence anchors on the "### Evidence" HEADING rather than matching the old content line
# by equality — an equality match would need its OWN `awk -v old="$old"`, and $old is itself
# backslash-bearing on the second call (replacing evidence1 with evidence2), which hits the exact
# same escape-processing bug this test exists to catch, in the test helper instead of the CLI.
# Only `nf` (a mktemp path, never backslash-bearing) goes through -v here.
inject_evidence() { # file new-text -> replace the Result block's Evidence content line
  local f="$1" new="$2" nf t
  nf="$(mktemp)"
  printf '%s' "$new" > "$nf"
  t="$(mktemp)"
  awk -v nf="$nf" '
    /^### Evidence$/ {
      print          # the heading
      getline; print # the blank line under it
      getline         # discard the old content line
      while ((getline line < nf) > 0) print line
      close(nf)
      next
    }
    { print }
  ' "$f" > "$t" && cat "$t" > "$f"
  rm -f "$t" "$nf"
}
evidence1='Reproduced at C:\Users\foo\bar and via regex \d+\s*\.'
evidence2='Reproduced at D:\Other\path\here and via a different regex \w+\S*\,'
hb "$R" new backslash-case --title "Backslash case" > /dev/null
hb "$R" export backslash-case --to Carol > /dev/null
BSBRIEF="$BOARD/briefs/backslash-case-handoff.brief.md"
fill_brief "$BSBRIEF" done
inject_evidence "$BSBRIEF" "$evidence1"
BSDOC="$BOARD/backslash-case-handoff.md"

hb "$R" import --result "$BSBRIEF" > /dev/null
FIRST="$(sed -n '/^Reproduced at /p' "$BSDOC")"
chk "backslashes survive first import" "$evidence1" "$FIRST"

inject_evidence "$BSBRIEF" "$evidence2"
hb "$R" import --result "$BSBRIEF" > /dev/null
SECOND="$(sed -n '/^Reproduced at /p' "$BSDOC")"
chk "backslashes survive re-import, and the replace actually ran (not a silent no-op)" "$evidence2" "$SECOND"

printf '\nimport --result — result_by cannot inject frontmatter keys via awk -v escapes (CRITICAL)\n'
# POSIX awk decodes C-style backslash escapes in a -v-assigned value: "\n" becomes a real newline
# and "\072" becomes a real colon, neither of which fold_colons can see (neither is a literal
# newline/colon in the input it folds). A brief's result_by is attacker-controlled, so a value like
# `jdoe\nverify\072 echo INJECTED` used to inject a whole new `verify:` frontmatter key that
# `release --run-verify` would later eval. The injected key/command here are both harmless (a
# `verify` key most docs never carry, and a plain `echo`) — the point is that NO extra key appears
# and the string survives byte-for-byte as one opaque value, not that anything would have run.
inject_result_by() { # file value -> replace the result_by: line's value with the literal text
  local f="$1" val="$2" vf t
  vf="$(mktemp)"
  printf '%s' "$val" > "$vf"
  t="$(mktemp)"
  awk -v vf="$vf" '
    /^result_by:/ { getline v < vf; close(vf); print "result_by: " v; next }
    { print }
  ' "$f" > "$t" && cat "$t" > "$f"
  rm -f "$vf" "$t"
}
hb "$R" new inject-case --title "Injection case" > /dev/null
hb "$R" export inject-case --to Mallory > /dev/null
INJ_BRIEF="$BOARD/briefs/inject-case-handoff.brief.md"
fill_brief "$INJ_BRIEF" done
inject_result_by "$INJ_BRIEF" 'jdoe\nverify\072 echo INJECTED'
INJ_DOC="$BOARD/inject-case-handoff.md"
hb "$R" import --result "$INJ_BRIEF" > /dev/null
chk "no verify: key was injected into the doc's frontmatter" "" "$(sed -n 's/^verify: //p' "$INJ_DOC" | head -1)"
chk "result_from preserves the raw escape sequence literally (not decoded into a newline/colon)" \
  'jdoe\nverify\072 echo INJECTED' "$(sed -n 's/^result_from: //p' "$INJ_DOC" | head -1)"
chk "the frontmatter has exactly one line naming result_from, not a decoded second line" "1" \
  "$(sed -n '2,/^---$/p' "$INJ_DOC" | grep -c '^result_from:')"

printf '\nimport --result refusals\n'
# Every refusal below asserts the message AND that the doc on disk did not change at all — a
# refusal that ran the secret scan or repo guard after splicing would otherwise still print the
# right message while leaving a partial write behind.
WRONG="$(mktemp)"
sed 's/^repo_root_commit: .*/repo_root_commit: 0000000000000000000000000000000000000000/' "$BRIEF" > "$WRONG"
BEFORE="$(cat "$DOC")"
chk_contains "wrong repo refused" "$(hb "$R" import --result "$WRONG")" "different repository"
chk "wrong-repo refusal writes nothing" "$BEFORE" "$(cat "$DOC")"

BADV="$(mktemp)"
sed 's/^brief: 1$/brief: 99/' "$BRIEF" > "$BADV"
BEFORE="$(cat "$DOC")"
chk_contains "unknown format refused" "$(hb "$R" import --result "$BADV")" "brief format"
chk "unknown-format refusal writes nothing" "$BEFORE" "$(cat "$DOC")"

R2="$(mkboard)"
hb "$R2" new other-thing --title "Other" --severity low > /dev/null
hb "$R2" export other-thing > /dev/null
UNFILLED="$R2/.agents/handoff/briefs/other-thing-handoff.brief.md"
UNFILLED_DOC="$R2/.agents/handoff/other-thing-handoff.md"
BEFORE="$(cat "$UNFILLED_DOC")"
chk_contains "unfilled result refused" "$(hb "$R2" import --result "$UNFILLED")" "not filled in"
chk "unfilled-result refusal writes nothing" "$BEFORE" "$(cat "$UNFILLED_DOC")"

SECRET="$(mktemp)"
sed 's/Ran npm test -- tenant; 14 passing./token AKIAIOSFODNN7EXAMPLE/' "$BRIEF" > "$SECRET"
BEFORE="$(cat "$DOC")"
chk_contains "secret-bearing result refused" "$(hb "$R" import --result "$SECRET")" "looks like a credential"
chk "secret-bearing-body refusal writes nothing" "$BEFORE" "$(cat "$DOC")"

SECRET_BY="$(mktemp)"
sed 's/^result_by: Alice$/result_by: AKIAIOSFODNN7EXAMPLE/' "$BRIEF" > "$SECRET_BY"
BEFORE="$(cat "$DOC")"
chk_contains "secret-bearing result_by refused" "$(hb "$R" import --result "$SECRET_BY")" "looks like a credential"
chk "secret-in-result_by refusal writes nothing" "$BEFORE" "$(cat "$DOC")"

printf '\nimport --result refuses a target that was never delegated (finding 3)\n'
# The brief's `handoff:` field is attacker-controlled. Editing it to name a doc that was never
# exported used to stamp result_claimed/review straight onto that doc regardless.
hb "$R" new never-delegated-case --title "Never delegated" > /dev/null
NODELEG_DOC="$BOARD/never-delegated-case-handoff.md"
FORGED="$(mktemp)"
sed 's/^handoff: .*/handoff: never-delegated-case-handoff/' "$BRIEF" > "$FORGED"
BEFORE="$(cat "$NODELEG_DOC")"
chk_contains "refuses when the target was never delegated" "$(hb "$R" import --result "$FORGED")" "never delegated"
chk "refusal writes nothing to the undelegated doc" "$BEFORE" "$(cat "$NODELEG_DOC")"

printf '\nimport --result refuses when handoff: points at a delegated doc but the file is a different brief (finding 3)\n'
# Two doc, two briefs. Editing brief B's handoff: field to name doc A (which WAS delegated, so it
# passes the check above) must still be refused: A's own brief: pointer names A's brief file, not
# B's — importing B onto A would silently overwrite whatever A's real executor already reported.
hb "$R" new brief-mismatch-a --title "Mismatch A" > /dev/null
hb "$R" export brief-mismatch-a --to Gina > /dev/null
hb "$R" new brief-mismatch-b --title "Mismatch B" > /dev/null
hb "$R" export brief-mismatch-b --to Gina > /dev/null
MISMATCH_B_BRIEF="$BOARD/briefs/brief-mismatch-b-handoff.brief.md"
fill_brief "$MISMATCH_B_BRIEF" done
MISMATCH_A_DOC="$BOARD/brief-mismatch-a-handoff.md"
FORGED2="$(mktemp)"
sed 's/^handoff: .*/handoff: brief-mismatch-a-handoff/' "$MISMATCH_B_BRIEF" > "$FORGED2"
BEFORE="$(cat "$MISMATCH_A_DOC")"
chk_contains "refuses when the brief file does not match the target's own brief: pointer" \
  "$(hb "$R" import --result "$FORGED2")" "does not point at"
chk "mismatch refusal writes nothing to the doc" "$BEFORE" "$(cat "$MISMATCH_A_DOC")"

printf '\nlist and release\n'
# Reuses $R / rbac-gap-handoff from the export/import sections above: delegated_to=Alice,
# review=pending, and the doc body carries the executor's literal evidence line
# ("Ran npm test -- tenant; 14 passing.") spliced in by import --result.
chk_contains "list shows the delegate" "$(hb "$R" list)" "Alice"
chk_contains "list shows review pending" "$(hb "$R" list)" "review"

OUT="$(hb "$R" release rbac-gap --status done --verified-by "Ran npm test -- tenant; 14 passing.")"
chk_contains "warns on copied evidence" "$OUT" "identical to the reported evidence"

hb "$R" new fresh-close --title "Never delegated" > /dev/null
FRESH_OUT="$(hb "$R" release fresh-close --status done --verified-by "checked src/foo.ts:12 by hand")"
case "$FRESH_OUT" in
  *"identical to the reported evidence"*) chk "no false warning on a never-delegated doc" "no" "yes" ;;
  *) chk "no false warning on a never-delegated doc" "no" "no" ;;
esac

hb "$R" new no-echo-back --title "Different evidence" > /dev/null
hb "$R" export no-echo-back --to Eve > /dev/null
NEB_BRIEF="$BOARD/briefs/no-echo-back-handoff.brief.md"
fill_brief "$NEB_BRIEF" done
hb "$R" import --result "$NEB_BRIEF" > /dev/null
DIFF_OUT="$(hb "$R" release no-echo-back --status done --verified-by "I independently re-ran the suite myself.")"
case "$DIFF_OUT" in
  *"identical to the reported evidence"*) chk "no false warning when verified-by differs from the reported evidence" "no" "yes" ;;
  *) chk "no false warning when verified-by differs from the reported evidence" "no" "no" ;;
esac

NEB_DOC="$BOARD/archive/no-echo-back-handoff.md"
[ -f "$NEB_DOC" ] || NEB_DOC="$BOARD/no-echo-back-handoff.md"
chk "finish_release clears a genuinely pending review to done" "done" \
  "$(sed -n 's/^review: //p' "$NEB_DOC" | head -1)"

FRESH_DOC="$BOARD/archive/fresh-close-handoff.md"
[ -f "$FRESH_DOC" ] || FRESH_DOC="$BOARD/fresh-close-handoff.md"
chk "finish_release leaves a never-set review field alone" "" \
  "$(sed -n 's/^review: //p' "$FRESH_DOC" | head -1)"

printf '\nfinish_release — review: pending SURVIVES a non-done release (finding 2)\n'
# The old guard checked only that a review WAS pending, not what kind of release this is. The most
# reachable sequence in the whole feature — orchestrator imports a result, then releases the lease
# with --status open so someone else can review it — used to have THAT release erase the very
# "needs a reviewer" marker it was trying to hand off.
hb "$R" new open-release-marker-case --title "Review survives open release" > /dev/null
hb "$R" export open-release-marker-case --to Frank > /dev/null
ROC_BRIEF="$BOARD/briefs/open-release-marker-case-handoff.brief.md"
fill_brief "$ROC_BRIEF" done
hb "$R" import --result "$ROC_BRIEF" > /dev/null
ROC_DOC="$BOARD/open-release-marker-case-handoff.md"
chk "review is pending after import" "pending" "$(sed -n 's/^review: //p' "$ROC_DOC" | head -1)"
hb "$R" release open-release-marker-case --status open "parking the lease" > /dev/null
chk "review: pending survives a --status open release" "pending" "$(sed -n 's/^review: //p' "$ROC_DOC" | head -1)"
# Scoped to THIS doc's own row and to the exact "⇤ review" marker glyph — other docs on the shared
# test board can legitimately carry their own pending review, so neither a whole-table search nor
# an unscoped "review" substring (which could also match harmlessly elsewhere on the row) proves
# THIS doc's marker specifically survived.
chk_contains "list shows the review marker on THIS doc's own row after the open release" \
  "$(hb "$R" list | grep '^open-release-marker-case-handoff ')" "⇤ review"

printf '\ncmd_release — the copied-evidence warning is scoped to the Result block, not the whole doc (minor)\n'
# A whole-doc substring search fires on a reviewer who honestly re-ran the doc's own "## Verify"
# instructions and typed the same words to describe it — text that lives OUTSIDE the executor's
# reported Result block. Put the reviewer's exact words into the Verify section (not the Result
# block) and confirm they do NOT trip the "identical to the reported evidence" warning.
insert_into_verify() { # file text -> append a line right after the doc's "## Verify" heading
  local f="$1" text="$2" tf t
  tf="$(mktemp)"
  printf '%s' "$text" > "$tf"
  t="$(mktemp)"
  awk -v tf="$tf" '
    { print }
    /^## Verify$/ { print ""; while ((getline line < tf) > 0) print line; close(tf) }
  ' "$f" > "$t" && cat "$t" > "$f"
  rm -f "$tf" "$t"
}
REVIEWER_WORDS="Ran the tenant regression suite by hand; 14 passing."
hb "$R" new verify-scope-case --title "Verify scope case" > /dev/null
VS_DOC="$BOARD/verify-scope-case-handoff.md"
insert_into_verify "$VS_DOC" "$REVIEWER_WORDS"
hb "$R" export verify-scope-case --to Hank > /dev/null
VS_BRIEF="$BOARD/briefs/verify-scope-case-handoff.brief.md"
fill_brief "$VS_BRIEF" done
hb "$R" import --result "$VS_BRIEF" > /dev/null
VS_OUT="$(hb "$R" release verify-scope-case --status done --verified-by "$REVIEWER_WORDS")"
case "$VS_OUT" in
  *"identical to the reported evidence"*) chk "no false warning when the match is only in the Verify section" "no" "yes" ;;
  *) chk "no false warning when the match is only in the Verify section" "no" "no" ;;
esac

printf '\nset_field — a write failure is refused, not a silent no-op (minor)\n'
hb "$R" new writeprotect-case --title "Write protect case" > /dev/null
WP_DOC="$BOARD/writeprotect-case-handoff.md"
chmod 444 "$WP_DOC"
hb "$R" release writeprotect-case --status open "trying" > /dev/null 2>&1
WP_STATUS=$?
chmod 644 "$WP_DOC"
chk "release fails loudly instead of silently no-opping when the doc cannot be written" "nonzero" \
  "$([ "$WP_STATUS" -ne 0 ] && echo nonzero || echo zero)"

printf '\n--- %d passed, %d failed ---\n' "$P" "$F"
[ "$F" -eq 0 ]
