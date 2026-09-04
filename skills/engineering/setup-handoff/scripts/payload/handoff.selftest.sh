#!/usr/bin/env bash
# Self-test for the handoff CLI's export/import round-trip. Read-only outside its own temp dirs.
# Run: bash handoff.selftest.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$(cd "$HERE/../../assets" && pwd)"

# ONE payload version per run, frozen here and never re-read.
#
# Every fixture copies the CLI in at fixture-creation time, and this suite builds 19 of them across
# three builders over ~8 minutes. Reading $HERE live meant a run spanning an edit to the payload
# built some boards from the old CLI and some from the new, then asserted the new behaviour against
# both. That produced false failures twice — 2 each time, both in the delegate review gate — and
# each cost ~25 minutes hunting a bug that was never in the code. It is not a hypothetical: the
# payload is exactly what you are editing when you have reason to run this.
#
# SRC and TPL are what everything below reads. $HERE and $ASSETS are deliberately not used again —
# a builder added later inherits the freeze only if it reads these, so these are the greppable names.
SRC="$(mktemp -d)"
TPL="$SRC/templates"
mkdir -p "$TPL"
cp "$HERE/handoff" "$HERE/config.sh" "$SRC/"
cp "$ASSETS"/handoff-*-template.md "$TPL/"
chmod +x "$SRC/handoff"
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
. "$SRC/handoff"

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
  cp "$SRC/handoff" "$r/.agents/handoff/handoff"
  cp "$SRC/config.sh" "$r/.agents/handoff/scripts/config.sh"
  cp "$TPL"/handoff-*-template.md "$r/.agents/handoff/templates/"
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
#
# The holder is a CONCURRENT agent, so it claims under an explicit foreign session id. Left to the
# ambient environment this claimed and exported as one session, which is now the allowed self-held
# case — the test would then be asserting the opposite of what its name says, and passing or failing
# on whether the machine running it happens to expose a session id at all.
hb "$R" new claim-race --title "Claim race" > /dev/null
(
  export HANDOFF_SESSION_ID="foreign-session-$$"
  hb "$R" claim claim-race "already working it"
) > /dev/null
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
# on a match, treated it as VERIFIED. Prove the guess is gone by constructing exactly the case that
# used to fool it: a git repo sibling to the board repo, sharing the audience's name, on a board
# that carries no cross-repo registry at all.
SIB_NAME="acme-sibling-$$"
SIBLING="$(dirname "$R")/$SIB_NAME"
mkrepo() { # dir remote -> creates a git repo with one commit
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email "test@example.com"
  git -C "$1" config user.name "test"
  [ -n "${2:-}" ] && git -C "$1" remote add origin "$2"
  # Content and message vary by directory name ON PURPOSE. Two repos built from identical trees in
  # the same second get identical author/committer timestamps and therefore the SAME root commit —
  # which silently turns "the decoy's sha must not appear" into a test that cannot fail.
  printf '%s\n' "$(basename "$1")" > "$1/README.md"
  git -C "$1" add -A
  git -C "$1" commit -qm "initial commit for $(basename "$1")"
}
mkrepo "$SIBLING" ""
SIBLING_ROOT="$(git -C "$SIBLING" rev-list --max-parents=0 HEAD | tail -1)"
hb "$R" new sibling-aud-case --title "Sibling audience case" --audience "$SIB_NAME" > /dev/null
hb "$R" export sibling-aud-case --no-claim > /dev/null
SIB_BRIEF="$BOARD/briefs/sibling-aud-case-handoff.brief.md"
chk "cross-repo identity degrades to unverified, never guesses a same-named sibling directory" "unverified" \
  "$(sed -n 's/^repo_root_commit: //p' "$SIB_BRIEF" | head -1)"
chk "the sibling repo's REAL root commit never appears in the brief" "no" \
  "$(grep -Fq "$SIBLING_ROOT" "$SIB_BRIEF" && echo yes || echo no)"
chk_contains "a registry-less board says so, rather than blaming an unreachable repo" \
  "$(cat "$SIB_BRIEF")" "carries no cross-repo registry"

printf '\nbrief_identity — cross-repo identity resolves from the board registry, not the name\n'
# The grouped-board topology the guard was built for: the target's DIRECTORY NAME deliberately does
# not match its `audience`, and an unrelated repo standing at the audience's name sits right beside
# the board. Only the registry (register-cross-repo-handoff's projection of .handoff-repos.json)
# knows which is which.
TARGET="$(dirname "$R")/checkout-not-named-like-audience-$$"
mkrepo "$TARGET" "git@github.com:acme/acme-web.git"
TARGET_ROOT="$(git -C "$TARGET" rev-list --max-parents=0 HEAD | tail -1)"
DECOY="$(dirname "$R")/acme-web-$$"
mkrepo "$DECOY" "git@github.com:evil/decoy.git"
DECOY_ROOT="$(git -C "$DECOY" rev-list --max-parents=0 HEAD | tail -1)"

write_registry() { # json-body -> $BOARD/repos.json
  printf '%s\n' "$1" > "$BOARD/repos.json"
}
# Paths are stored RELATIVE TO THE BOARD DIR, which is what makes a committed board portable.
TARGET_REL="../../../$(basename "$TARGET")"
write_registry "{
  \"version\": 1,
  \"repos\": [
    { \"group\": \"acme\", \"alias\": \"web\", \"audience\": \"acme-web-$$\",
      \"path\": \"$TARGET_REL\", \"rootCommit\": \"$TARGET_ROOT\" }
  ]
}"
hb "$R" new manifest-aud-case --title "Manifest audience case" --audience "acme-web-$$" > /dev/null
hb "$R" export manifest-aud-case --no-claim > /dev/null
MAN_BRIEF="$BOARD/briefs/manifest-aud-case-handoff.brief.md"
chk "the brief carries the DECLARED repo's real root commit" "$TARGET_ROOT" \
  "$(sed -n 's/^repo_root_commit: //p' "$MAN_BRIEF" | head -1)"
chk "identity comes from the declared path, never the same-named decoy" "no" \
  "$(grep -Fq "$DECOY_ROOT" "$MAN_BRIEF" && echo yes || echo no)"
chk "the brief records the target's own origin, not the exporting repo's" "acme/acme-web" \
  "$(sed -n 's/^repo_origin: //p' "$MAN_BRIEF" | head -1)"
chk "a resolved cross-repo brief carries no degradation warning" "" \
  "$(sed -n 's/^.*\(\*\*Warning\*\*\).*$/\1/p' "$MAN_BRIEF" | head -1)"

printf '\nbrief_identity — an unattested or unresolvable registry entry degrades, never guesses\n'
# The declared path still exists but now holds a DIFFERENT repo (a moved checkout, a hand-edited
# manifest, a registry never re-synced). The attestation is what catches it.
write_registry "{
  \"version\": 1,
  \"repos\": [
    { \"group\": \"acme\", \"alias\": \"web\", \"audience\": \"acme-web-$$\",
      \"path\": \"$TARGET_REL\", \"rootCommit\": \"$DECOY_ROOT\" }
  ]
}"
hb "$R" new stale-registry-case --title "Stale registry case" --audience "acme-web-$$" > /dev/null
hb "$R" export stale-registry-case --no-claim > /dev/null
STALE_BRIEF="$BOARD/briefs/stale-registry-case-handoff.brief.md"
chk "a root-commit mismatch fails closed to unverified" "unverified" \
  "$(sed -n 's/^repo_root_commit: //p' "$STALE_BRIEF" | head -1)"
chk "the repo standing at the stale path is never stamped into the brief" "no" \
  "$(grep -Fq "$TARGET_ROOT" "$STALE_BRIEF" && echo yes || echo no)"
chk_contains "the warning names the re-sync as the fix" "$(cat "$STALE_BRIEF")" "Re-run the cross-repo sync"

# Two entries claiming one audience is a manifest the operator must fix, not a tie to break.
write_registry "{
  \"version\": 1,
  \"repos\": [
    { \"group\": \"a\", \"alias\": \"web\", \"audience\": \"acme-web-$$\",
      \"path\": \"$TARGET_REL\", \"rootCommit\": \"$TARGET_ROOT\" },
    { \"group\": \"b\", \"alias\": \"web2\", \"audience\": \"acme-web-$$\",
      \"path\": \"../../../$(basename "$DECOY")\", \"rootCommit\": \"$DECOY_ROOT\" }
  ]
}"
hb "$R" new ambiguous-aud-case --title "Ambiguous audience case" --audience "acme-web-$$" > /dev/null
hb "$R" export ambiguous-aud-case --no-claim > /dev/null
AMB_BRIEF="$BOARD/briefs/ambiguous-aud-case-handoff.brief.md"
chk "an audience claimed twice resolves to nothing rather than a coin flip" "unverified" \
  "$(sed -n 's/^repo_root_commit: //p' "$AMB_BRIEF" | head -1)"
chk "neither candidate's root commit leaks into the brief" "no" \
  "$({ grep -Fq "$TARGET_ROOT" "$AMB_BRIEF" || grep -Fq "$DECOY_ROOT" "$AMB_BRIEF"; } && echo yes || echo no)"

# An audience the registry simply does not declare.
write_registry "{
  \"version\": 1,
  \"repos\": [
    { \"group\": \"acme\", \"alias\": \"web\", \"audience\": \"acme-web-$$\",
      \"path\": \"$TARGET_REL\", \"rootCommit\": \"$TARGET_ROOT\" }
  ]
}"
hb "$R" new undeclared-aud-case --title "Undeclared audience case" --audience "acme-nowhere" > /dev/null
hb "$R" export undeclared-aud-case --no-claim > /dev/null
UND_BRIEF="$BOARD/briefs/undeclared-aud-case-handoff.brief.md"
chk "an audience absent from the registry degrades to unverified" "unverified" \
  "$(sed -n 's/^repo_root_commit: //p' "$UND_BRIEF" | head -1)"
chk "an undeclared audience never resolves to the one repo that IS declared" "no" \
  "$(grep -Fq "$TARGET_ROOT" "$UND_BRIEF" && echo yes || echo no)"

# A malformed registry is not trusted even partially.
write_registry "{ this is not json"
hb "$R" new bad-registry-case --title "Bad registry case" --audience "acme-web-$$" > /dev/null
hb "$R" export bad-registry-case --no-claim > /dev/null
BAD_BRIEF="$BOARD/briefs/bad-registry-case-handoff.brief.md"
chk "an unreadable registry degrades to unverified rather than erroring out" "unverified" \
  "$(sed -n 's/^repo_root_commit: //p' "$BAD_BRIEF" | head -1)"
chk_contains "an unreadable registry says so, rather than reporting an undeclared audience" \
  "$(cat "$BAD_BRIEF")" "could not be read"

printf '\nboard_repo_entry — an audience resolves inside the CALLING section only\n'
# Two groups sharing one board may each declare their own "api"; the manifest is the fence, so each
# caller must see only its own. Exercised against the resolver directly (DIR/GROUP are the globals
# the CLI reads) because a sectioned board is otherwise a whole install to stand up.
# -P: board paths come back through realpath, so the expectation must be the physical
# path too (macOS /var -> /private/var would otherwise fail every comparison).
SECDIR="$(cd "$(mktemp -d)" && pwd -P)"
cat > "$SECDIR/repos.json" << 'REGEOF'
{
  "version": 1,
  "repos": [
    { "group": "alpha", "alias": "api", "audience": "api", "path": "./alpha-api", "rootCommit": "aaaa1111" },
    { "group": "beta",  "alias": "api", "audience": "api", "path": "./beta-api",  "rootCommit": "bbbb2222" }
  ]
}
REGEOF
sec_entry() { (DIR="$SECDIR" GROUP="$1" && board_repo_entry api); }
chk "the alpha section resolves alpha's api" "ok|$SECDIR/alpha-api|aaaa1111" "$(sec_entry alpha)"
chk "the beta section resolves beta's api" "ok|$SECDIR/beta-api|bbbb2222" "$(sec_entry beta)"
chk "a section that declares no api gets nothing, not someone else's" "no-entry||" "$(sec_entry gamma)"
chk "with no section set, an audience claimed twice stays ambiguous" "ambiguous||" "$(sec_entry '')"
trash "$SECDIR" 2> /dev/null

rm -f "$BOARD/repos.json"
for d in "$SIBLING" "$TARGET" "$DECOY"; do
  [ -n "$d" ] && [ -d "$d" ] && trash "$d" 2> /dev/null
done

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
# The lease has to be FOREIGN for this to be the finding-5 case at all: a lease the acting session
# holds is deliberately allowed through (the next block). Claiming under an explicit foreign session
# id — rather than whatever the ambient environment happens to expose — is what keeps the two cases
# from collapsing into each other depending on where the suite runs.
(
  export HANDOFF_SESSION_ID="foreign-session-$$"
  hb "$R" claim bundle-child-4 "already working it"
) > /dev/null
BUNDLE2_DOC="$BOARD/bundle-parent-2-handoff.md"
BUNDLE2_COVER="$BOARD/briefs/bundle-parent-2-handoff.cover.md"
CHILD3_DOC="$BOARD/bundle-child-3-handoff.md"
BUNDLE2_OUT="$(hb "$R" export bundle-parent-2 --to Yara)"
chk_contains "refuses the whole export when any child has a live lease" "$BUNDLE2_OUT" "lease"
chk "no cover file was written by the refused export" "no" "$([ -f "$BUNDLE2_COVER" ] && echo yes || echo no)"
chk "the untouched child was never claimed" "no" "$([ -d "$BOARD/.locks/bundle-child-3-handoff" ] && echo yes || echo no)"
chk "the untouched child's doc was never stamped delegated_to" "" "$(sed -n 's/^delegated_to: //p' "$CHILD3_DOC" | head -1)"
chk "the orchestrator itself was never stamped delegated_to" "" "$(sed -n 's/^delegated_to: //p' "$BUNDLE2_DOC" | head -1)"

printf '\ncmd_export — a child leased by THIS session is extended, not refused\n'
# The pre-flight treated ANY held lease as blocking, including the caller's own, so an orchestrator
# that had claimed a child to investigate it could not then delegate the bundle: it had to release
# its own lease first, or pass --no-claim, which drops leasing for EVERY child in the run.
SELF_SESS="self-session-$$"
hb "$R" new bundle-child-7 --title "Bundle child 7" > /dev/null
hb "$R" new bundle-child-8 --title "Bundle child 8" > /dev/null
hb "$R" new bundle-parent-5 --orchestrator --children bundle-child-7,bundle-child-8 --title "Bundle parent 5" > /dev/null
(
  export HANDOFF_SESSION_ID="$SELF_SESS"
  hb "$R" claim bundle-child-7 "investigating"
) > /dev/null
SELF_LOCK="$BOARD/.locks/bundle-child-7-handoff/owner"
# Shorten the held lease to a minute so "was it extended?" is answerable. Re-claiming inside the
# same second would otherwise stamp the same expiry a fresh claim would, and the check could not
# tell the two paths apart. Still live, so it is a self-held lease and not an expired one.
SELF_T="$(mktemp)"
grep -v '^expires=' "$SELF_LOCK" > "$SELF_T"
echo "expires=$(($(now) + 60))" >> "$SELF_T"
cat "$SELF_T" > "$SELF_LOCK"
rm -f "$SELF_T"
B5_OUT="$(
  export HANDOFF_SESSION_ID="$SELF_SESS"
  hb "$R" export bundle-parent-5 --to Vic
)"
B5_COVER="$BOARD/briefs/bundle-parent-5-handoff.cover.md"
chk "the export is not refused over the caller's own lease" "yes" \
  "$([ -f "$B5_COVER" ] && echo yes || echo no)"
chk "the self-held child still got its brief" "yes" \
  "$([ -f "$BOARD/briefs/bundle-child-7-handoff.brief.md" ] && echo yes || echo no)"
chk "the free child got its brief too" "yes" \
  "$([ -f "$BOARD/briefs/bundle-child-8-handoff.brief.md" ] && echo yes || echo no)"
chk "the free child WAS claimed" "yes" \
  "$([ -d "$BOARD/.locks/bundle-child-8-handoff" ] && echo yes || echo no)"
chk "the self-held lease survives the export" "yes" "$([ -f "$SELF_LOCK" ] && echo yes || echo no)"
chk "it is still the SAME lease, not a re-claim (the original note is intact)" "investigating" \
  "$(sed -n 's/^note=//p' "$SELF_LOCK" | head -1)"
chk "the self-held lease was extended to a full TTL" "yes" \
  "$([ "$(sed -n 's/^expires=//p' "$SELF_LOCK" | head -1)" -gt "$(($(now) + 3600))" ] && echo yes || echo no)"
chk_contains "the export says it kept the lease rather than re-claiming" "$B5_OUT" "lease extended"

printf '\ncmd_export — a single export on a doc THIS session already holds is not refused\n'
# Same carve-out, reached through export_one directly: `claim X` then `export X` is the obvious
# order — investigate, then decide to delegate — and it used to die on the caller's own lease.
hb "$R" new self-single-case --title "Self single case" > /dev/null
(
  export HANDOFF_SESSION_ID="$SELF_SESS"
  hb "$R" claim self-single-case "looking at it"
) > /dev/null
SS_OUT="$(
  export HANDOFF_SESSION_ID="$SELF_SESS"
  hb "$R" export self-single-case --to Uma
)"
chk "the brief was written despite the caller holding the lease" "yes" \
  "$([ -f "$BOARD/briefs/self-single-case-handoff.brief.md" ] && echo yes || echo no)"
chk "the doc is stamped with the delegate" "Uma" \
  "$(sed -n 's/^delegated_to: //p' "$BOARD/self-single-case-handoff.md" | head -1)"
chk_contains "and it reports the lease was extended" "$SS_OUT" "lease extended"

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
  cp "$SRC/handoff" "$r/.agents/handoff/handoff"
  cp "$SRC/config.sh" "$r/.agents/handoff/scripts/config.sh"
  cp "$TPL"/handoff-*-template.md "$r/.agents/handoff/templates/"
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
chk_contains "secret-bearing result refused" "$(hb "$R" import --result "$SECRET")" "aws-access-key-id"
chk "secret-bearing-body refusal writes nothing" "$BEFORE" "$(cat "$DOC")"

SECRET_BY="$(mktemp)"
sed 's/^result_by: Alice$/result_by: AKIAIOSFODNN7EXAMPLE/' "$BRIEF" > "$SECRET_BY"
BEFORE="$(cat "$DOC")"
chk_contains "secret-bearing result_by refused" "$(hb "$R" import --result "$SECRET_BY")" "aws-access-key-id"
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

# Handing the delegate's own words back as the review is now REFUSED, not warned: this doc came
# through `import --result`, so it carries executed_by: delegate, and closing it on the executor's
# evidence would stamp a verification date asserting somebody checked when nobody did.
OUT="$(hb "$R" release rbac-gap --status done --verified-by "Ran npm test -- tenant; 14 passing.")"
chk_contains "refuses the delegate's own words as the review" "$OUT" "That is the delegate reviewing itself"
chk "and the doc is NOT closed" "open" "$(sed -n 's/^status: //p' "$BOARD/rbac-gap-handoff.md" | head -1)"
chk "nor stamped with a verification date" "" "$(sed -n 's/^verified_at: //p' "$BOARD/rbac-gap-handoff.md" | head -1)"
# Evidence the reviewer actually produced closes it normally.
OUT="$(hb "$R" release rbac-gap --status done --verified-by "re-ran npm test -- tenant myself; 14 passing at rbac.e2e.ts:88")"
chk_contains "evidence of the reviewer's own check closes it" "$OUT" "done"

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
# A private TMPDIR so "did the failed write leak its scratch files?" is answerable at all — counting
# files in the shared temp dir would be counting every other process on the machine.
WP_TMP="$(mktemp -d)"
chmod 444 "$WP_DOC"
(
  export TMPDIR="$WP_TMP"
  hb "$R" release writeprotect-case --status open "trying"
) > /dev/null 2>&1
WP_STATUS=$?
chmod 644 "$WP_DOC"
chk "release fails loudly instead of silently no-opping when the doc cannot be written" "nonzero" \
  "$([ "$WP_STATUS" -ne 0 ] && echo nonzero || echo zero)"
# set_field's cleanup used to sit AFTER its `|| die`, so the reporting fix leaked both mktemp files
# on every genuine write failure. Reporting the failure and cleaning up after it are not a trade.
chk "the failed write leaves no temp files behind" "0" \
  "$(find "$WP_TMP" -type f | wc -l | tr -d ' ')"
trash "$WP_TMP" 2> /dev/null

# --- orchestrator children table -------------------------------------------------------------
# The generated block that lets a fresh session pick up a bundle from the bundle doc alone. Every
# check here is about the ONE property that makes the table safe to add at all: it is derived, not
# stored. A table that could be edited into a lie would be the exact rot the type forbids.
printf '\ncmd_index — the orchestrator children table\n'
CT="$(mkboard)"
CTB="$CT/.agents/handoff"
hb "$CT" new kid-one --title "Kid one" --severity high --audience acme-api > /dev/null
hb "$CT" new kid-two --title "Kid two" > /dev/null
hb "$CT" new ct-bundle --orchestrator --children kid-one,kid-two,never-filed --title "CT bundle" > /dev/null
CTDOC="$CTB/ct-bundle-handoff.md"
ctblock() { sed -n '/handoff:children:begin/,/handoff:children:end/p' "$CTDOC"; }

chk_contains "a fresh bundle renders a row per child" "$(ctblock)" "[Kid one](./kid-one-handoff.md)"
chk_contains "the table carries the child's own audience and severity" "$(ctblock)" "| acme-api | high |"
chk_contains "a child that is not on the board yet reads MISSING, not done" "$(ctblock)" '`never-filed-handoff` | `MISSING`'
chk_contains "progress is stated above the table" "$(ctblock)" "**0/3 done.**"

hb "$CT" claim kid-one "picking it up" > /dev/null
chk_contains "claiming a child surfaces the lease holder in the parent's table" "$(ctblock)" "🔒"
hb "$CT" release kid-one --status done --verified-by "ran the suite" > /dev/null
chk_contains "an archived child relinks into archive/" "$(ctblock)" "](./archive/kid-one-handoff.md)"
chk_contains "closing a child moves the derived count without anyone editing the parent" "$(ctblock)" "**1/3 done.**"

# The no-churn property. `index` runs after EVERY mutating command, so an unconditional rewrite
# would touch every bundle doc on the board on every claim anywhere in it — a git diff that says a
# bundle changed when nothing about it did.
cp "$CTDOC" "$CT/ct-before.md"
hb "$CT" index > /dev/null
chk "re-indexing an unchanged bundle does not rewrite its doc" "same" \
  "$(cmp -s "$CT/ct-before.md" "$CTDOC" && echo same || echo rewritten)"

# The rot guarantee, stated as a test: whatever a session writes between the markers is derived
# state, and the next index run replaces it. This is why the table may exist at all.
awk '/handoff:children:begin/ { print; print ""; print "**3/3 done.** all finished, trust me"; next } { print }' \
  "$CTDOC" > "$CT/ct-lied.md" && cat "$CT/ct-lied.md" > "$CTDOC"
hb "$CT" index > /dev/null
chk "a hand-edited count inside the markers is overwritten, not preserved" "0" \
  "$(grep -c 'trust me' "$CTDOC" | tr -d ' ')"

printf '\ncmd_children\n'
chk_contains "add records the canonical id" "$(hb "$CT" children add ct-bundle kid-three)" "+ kid-three-handoff"
chk_contains "add warns when the child is not on the board yet" "$(hb "$CT" children add ct-bundle kid-four)" "not on the board yet"
chk_contains "an added child appears in the table" "$(ctblock)" '`kid-three-handoff` | `MISSING`'
chk_contains "adding the same child twice is a no-op, not a duplicate row" \
  "$(hb "$CT" children add ct-bundle kid-three)" "already a child"
chk "the roster records each child once" "1" \
  "$(sed -n 's/^children: //p' "$CTDOC" | head -1 | grep -o 'kid-three-handoff' | wc -l | tr -d ' ')"
chk_contains "rm drops a child" "$(hb "$CT" children rm ct-bundle kid-four)" "- kid-four-handoff"
chk "a removed child leaves the roster" "0" \
  "$(sed -n 's/^children: //p' "$CTDOC" | head -1 | grep -c 'kid-four-handoff' | tr -d ' ')"
chk_contains "rm refuses an id that is not in the bundle" "$(hb "$CT" children rm ct-bundle kid-four)" "is not a child of"
chk_contains "a bundle cannot be made its own child" "$(hb "$CT" children add ct-bundle ct-bundle)" "cannot be its own child"
chk_contains "children refuses a non-orchestrator" "$(hb "$CT" children add kid-two kid-one)" "is not an orchestrator"
chk_contains "the bare form prints the table" "$(hb "$CT" children ct-bundle)" "| Child | Status |"
cp "$CTDOC" "$CT/ct-before-show.md"
hb "$CT" children ct-bundle > /dev/null
chk "the bare form writes nothing" "same" \
  "$(cmp -s "$CT/ct-before-show.md" "$CTDOC" && echo same || echo rewritten)"

# Boards created before this block existed must gain it, and must gain it ABOVE the activity log:
# log_activity appends to the end of the file, so a table appended there would swallow every
# subsequent entry into the generated section.
printf '\nwrite_children_block — a bundle doc that predates the table\n'
cat > "$CTB/legacy-bundle-handoff.md" << 'LEGACY'
---
id: legacy-bundle-handoff
title: Legacy bundle
type: orchestrator
status: open
children: [kid-two-handoff]
created: 2026-01-01
updated: 2026-01-01
---

## Bundle

Filed before the children table existed.

## Activity

- 2026-01-01 — created
LEGACY
hb "$CT" index > /dev/null
chk_contains "the section is added to a doc that has no markers" \
  "$(cat "$CTB/legacy-bundle-handoff.md")" "## Children"
# Without the prettier-ignore pair, a repo that formats its markdown re-aligns the generated table
# on every commit and the next index run un-aligns it again — a bundle nobody touched churning in
# every diff. Asserted here so the pair cannot be dropped as decoration.
chk_contains "the generated block is wrapped in prettier-ignore markers" \
  "$(cat "$CTB/legacy-bundle-handoff.md")" "<!-- prettier-ignore-start -->"
chk "the table is inserted ABOVE the activity log, not appended under it" "before" \
  "$([ "$(grep -n '## Children' "$CTB/legacy-bundle-handoff.md" | cut -d: -f1)" -lt \
    "$(grep -n '## Activity' "$CTB/legacy-bundle-handoff.md" | cut -d: -f1)" ] && echo before || echo after)"

# --- a SHARED board: its own git repo, with a remote (ADR 0002) ------------------------
# Every case above runs on a board nested inside a member repo, where the repo's remote is not the
# board's — leases_shared is false there and the CLI must behave exactly as it always has. These
# cases build the other shape: a standalone board that owns its repository and has a remote of its
# own, which is the only shape push-CAS applies to.
mkshared() { # -> board dir (its own repo, pushed to a bare remote beside it)
  local base bare b
  base="$(mktemp -d)"
  bare="$base/origin.git"
  git init -q --bare "$bare"
  b="$base/board"
  mkdir -p "$b/scripts" "$b/templates" "$b/archive" "$b/briefs"
  cp "$SRC/handoff" "$b/handoff"
  cp "$SRC/config.sh" "$b/scripts/config.sh"
  cp "$TPL"/handoff-*-template.md "$b/templates/"
  chmod +x "$b/handoff"
  printf '{\n  "topology": "cross-repo",\n  "ttlHours": 4\n}\n' > "$b/handoff.json"
  # The stale rule a board carries from before it had a remote. The CLI must repair it, because
  # leaving it turns every push-CAS into a commit of nothing.
  printf '.locks/\n' > "$b/.gitignore"
  git -C "$b" init -q
  git -C "$b" config user.email "test@example.com"
  git -C "$b" config user.name "test"
  git -C "$b" remote add origin "$bare"
  git -C "$b" add -A
  git -C "$b" commit -qm "board"
  git -C "$b" push -q -u origin HEAD
  printf '%s' "$b"
}

printf '\ndocument schema — environment, typed edges, role, evidence (ADR 0004)\n'
SC="$(mkboard)"
hb "$SC" new base-work --title "Base work" > /dev/null
hb "$SC" new prod-followup --title "Prod follow-up" --env production --after base-work > /dev/null
SCD="$SC/.agents/handoff/prod-followup-handoff.md"
chk "an environment alias normalizes to the canonical stage" "prod" \
  "$(sed -n 's/^environment: //p' "$SCD" | head -1)"
chk "--after records a canonicalized board id in depends_on" "[base-work-handoff]" \
  "$(sed -n 's/^depends_on: //p' "$SCD" | head -1)"
chk "an environment-less doc reads as dev" "dev" \
  "$(cd "$SC" && HANDOFF_NO_MAIN=1 . ./.agents/handoff/handoff && doc_env "$SC/.agents/handoff/base-work-handoff.md")"
chk "a coordination doc is given a rewritable Current state section" "yes" \
  "$(grep -q '^## Current state' "$SCD" && echo yes || echo no)"

# Advisory, and that is the decision, not an oversight: depends_on is about whether work can
# START, and work legitimately starts out of order.
DEP_OUT="$(hb "$SC" claim prod-followup "starting early")"
chk_contains "claiming past an unlanded prerequisite warns" "$DEP_OUT" "prerequisites that have not landed"
chk_contains "and names the prerequisite" "$DEP_OUT" "base-work-handoff (open)"
# `file:line` evidence is the format the verifier asks for, so the field has to be able to hold
# one. Colon-folding it (the treatment every other free-text field gets) would mangle exactly the
# thing being asked for, which is why this one is stored quoted like `verify:`.
chk_contains "and proceeds anyway" "$DEP_OUT" "Claimed prod-followup-handoff"
hb "$SC" release prod-followup --status open > /dev/null
# The day either side of the write, because the write is what stamps verified_at. Recomputing
# the date down at the assertion instead made any run that crossed midnight in between fail a
# check with nothing wrong behind it: the stamp was right, the expectation had moved on.
VERIFY_DAY_BEFORE="$(date '+%Y-%m-%d')"
hb "$SC" release base-work --status done --verified-by "read handoff:1 and ran the selftest" > /dev/null
VERIFY_DAY_AFTER="$(date '+%Y-%m-%d')"
QUIET_OUT="$(hb "$SC" claim prod-followup "starting again")"
chk "a landed prerequisite warns about nothing" "" \
  "$(printf '%s' "$QUIET_OUT" | grep -c 'have not landed' | grep -v '^0$')"

printf '\ndocument schema — closure evidence is a field, not a sentence in a log\n'
# 144 documents across two live boards carried a verification DATE and 2 carried retrievable
# evidence, for exactly this reason: the date was a field and the evidence was prose.
# Read through meta(), which is how every reader sees it: the field is STORED quoted so the colon
# survives, and meta() strips one surrounding quote pair — the same contract `verify:` already has.
chk "evidence is persisted as a field with its colons intact" "read handoff:1 and ran the selftest" \
  "$(cd "$SC" && HANDOFF_NO_MAIN=1 . ./.agents/handoff/handoff \
    && meta "$SC/.agents/handoff/archive/base-work-handoff.md" verified_by)"
# Whichever side of the write the stamp matches IS the expectation, so a genuinely wrong value
# still reports itself as want/got rather than collapsing to a bare yes/no.
VERIFIED_AT="$(sed -n 's/^verified_at: //p' "$SC/.agents/handoff/archive/base-work-handoff.md" | head -1)"
VERIFY_DAY_EXPECT="$VERIFY_DAY_BEFORE"
if [ "$VERIFIED_AT" = "$VERIFY_DAY_AFTER" ]; then
  VERIFY_DAY_EXPECT="$VERIFY_DAY_AFTER"
fi
chk "verified_at is still stamped beside it" "$VERIFY_DAY_EXPECT" "$VERIFIED_AT"

printf '\ndocument schema — role says what a standalone doc is FOR\n'
hb "$SC" new auth-spec --standalone --role spec --title "Auth spec" > /dev/null
chk "role is recorded" "spec" \
  "$(sed -n 's/^role: //p' "$SC/.agents/handoff/auth-spec-handoff.md" | head -1)"
chk_contains "an unknown role is refused rather than stored" \
  "$(hb "$SC" new bad-role-doc --standalone --role nonsense --title Bad)" "bad --role"
chk_contains "role is refused on a coordination doc, which has a lifecycle rather than a purpose" \
  "$(hb "$SC" new bad-role-coord --role spec --title Bad)" "only applies to a standalone"
chk "a standalone with no declared role reads as reference" "reference" \
  "$(hb "$SC" new plain-ref --standalone --title Plain > /dev/null && sed -n 's/^role: //p' "$SC/.agents/handoff/plain-ref-handoff.md" | head -1)"

printf '\ndocument schema — the index shows the graph, the stage, and the spec\n'
SI="$(mkboard)"
hb "$SI" new dev-chore --title "Dev chore" > /dev/null
hb "$SI" new prod-fix --title "Prod fix" --env prod > /dev/null
hb "$SI" new uat-check --title "UAT check" --env uat --spec "https://example.invalid/spec" > /dev/null
hb "$SI" new id-spec --title "Id spec" --spec dev-chore > /dev/null
printf '\nGroundwork lives in dev-chore-handoff.\n' >> "$SI/.agents/handoff/prod-fix-handoff.md"
hb "$SI" index > /dev/null
SIX="$SI/.agents/handoff/INDEX.md"
chk "the ladder orders the table, lowest stage first" "dev dev staging prod" \
  "$(grep -oE '\| (dev|staging|prod) \|' "$SIX" | tr -d '| ' | tr '\n' ' ' | sed 's/ $//')"
chk_contains "a URL spec resolves to a link" "$(cat "$SIX")" "[spec](https://example.invalid/spec)"
chk_contains "a board-id spec resolves to the doc" "$(cat "$SIX")" "[spec](./dev-chore-handoff.md)"
chk_contains "a prose mention becomes an advisory backlink" "$(cat "$SIX")" "Referenced by (advisory)"
chk_contains "and it names who mentioned it" "$(sed -n '/Referenced by/,$p' "$SIX")" "prod-fix-handoff"
# The backlink block reads BODIES only. Counting a declared depends_on here would report every real
# edge twice — once as structure, once as gossip — and make the advisory block look authoritative.
hb "$SI" new declared-dep --title "Declared" --after dev-chore > /dev/null
hb "$SI" index > /dev/null
chk "a declared edge is not also reported as a prose mention" "" \
  "$(sed -n '/Referenced by/,$p' "$SIX" | grep -c 'declared-dep' | grep -v '^0$')"

printf '\none handoff.json — the registry moved inside it, the old file still reads\n'
# The board registry used to be its own `repos.json`. It is now the `_generated.repos` key of the
# board's handoff.json — the block the cross-repo sync owns — so a board answers "which repo is
# this audience" from the same file that holds everything else about it.
OF="$(mkboard)"
OF_TARGET="$(mktemp -d)/acme-lib"
mkdir -p "$OF_TARGET"
git -C "$OF_TARGET" init -q
git -C "$OF_TARGET" config user.email "test@example.com"
git -C "$OF_TARGET" config user.name "test"
printf 'x\n' > "$OF_TARGET/README.md"
git -C "$OF_TARGET" add -A
git -C "$OF_TARGET" commit -qm "initial commit"
OF_ROOT="$(git -C "$OF_TARGET" rev-list --max-parents=0 HEAD | tail -1)"
OF_HOME_SAVE="$HOME"
export HOME="$(mktemp -d)"
mkdir -p "$HOME/.agents"
printf '{ "locations": { "%s": "%s" } }\n' "$OF_ROOT" "$OF_TARGET" > "$HOME/.agents/handoff.json"

cat > "$OF/.agents/handoff/handoff.json" << JSON
{
  "topology": "cross-repo",
  "ttlHours": 4,
  "_generated": {
    "schema": 2,
    "repos": [
      { "group": "acme", "alias": "lib", "audience": "acme-lib-$$", "rootCommit": "$OF_ROOT" }
    ]
  }
}
JSON
OF_OUT="$(cd "$OF" && HANDOFF_NO_MAIN=1 . ./.agents/handoff/handoff && DIR="$OF/.agents/handoff" board_repo_entry "acme-lib-$$")"
chk "the registry resolves from _generated inside handoff.json" \
  "ok|$(cd "$OF_TARGET" && pwd -P)|$OF_ROOT" "$OF_OUT"

# The machine-local layer is the same filename at $HOME. It is the one layer that must never be
# committed, which is why it lives there rather than as a gitignored file inside a cloned board.
chk "the location map is the ~ layer of the same file" "yes" \
  "$([ -f "$HOME/.agents/handoff.json" ] && echo yes || echo no)"

# Every board now HAS a handoff.json, so "present but declares no fleet" is the ordinary state of a
# single-repo board. Reporting that as a corrupt registry would send someone to repair a good file.
printf '{ "topology": "single-repo", "ttlHours": 4 }\n' > "$OF/.agents/handoff/handoff.json"
OF_NONE="$(cd "$OF" && HANDOFF_NO_MAIN=1 . ./.agents/handoff/handoff && DIR="$OF/.agents/handoff" board_repo_entry "acme-lib-$$")"
chk "a board with no fleet reports no-registry, not bad-registry" "no-registry||" "$OF_NONE"

# CONSEQUENCE OF CONSOLIDATION, asserted so it cannot regress quietly: the registry now shares a
# file with the board's config, so a corrupt registry is no longer a soft degrade of one feature —
# it takes the whole CLI down. That is the right direction (a board whose config cannot be parsed
# should not answer questions about itself), and it is loud: exit 3, naming the file and the parse
# error. A LEGACY standalone repos.json keeps degrading to `bad-registry`, since a board that has
# not been re-synced should not be worse off than before.
printf '{ nope\n' > "$OF/.agents/handoff/handoff.json"
OF_BAD="$(cd "$OF" && ./.agents/handoff/handoff list 2>&1)"
chk "a corrupt board config is fatal, not a silent degrade" "3" \
  "$(
    cd "$OF" && ./.agents/handoff/handoff list > /dev/null 2>&1
    echo $?
  )"
chk_contains "and it names the file that could not be read" "$OF_BAD" "cannot read"
chk_contains "and the parse error itself" "$OF_BAD" "handoff.json"

printf '{ "topology": "cross-repo", "ttlHours": 4 }\n' > "$OF/.agents/handoff/handoff.json"
printf '{ nope\n' > "$OF/.agents/handoff/repos.json"
OF_LEG="$(cd "$OF" && HANDOFF_NO_MAIN=1 . ./.agents/handoff/handoff && DIR="$OF/.agents/handoff" board_repo_entry "acme-lib-$$")"
chk "a corrupt LEGACY repos.json still only degrades brief resolution" "bad-registry||" "$OF_LEG"
chk "and the board still lists" "0" "$(
  cd "$OF" && ./.agents/handoff/handoff list > /dev/null 2>&1
  echo $?
)"
export HOME="$OF_HOME_SAVE"

printf '\nbundle rosters are bounded, and a dangling one can be closed\n'
# The session banner is injected into every agent's context on every session, so an unbounded
# roster is a token cost levied on unrelated work forever. One live board carries a bundle
# declaring 100 children of which 97 do not exist.
RB="$(mkboard)"
hb "$RB" new wide-bundle --orchestrator --title "Wide bundle" \
  --children c-one,c-two,c-three,c-four,c-five,c-six,c-seven,c-eight > /dev/null
RB_LIST="$(hb "$RB" list)"
chk_contains "list truncates a long roster" "$RB_LIST" "… and 3 more"
chk "and shows exactly the limit before the tail" "5" \
  "$(printf '%s' "$RB_LIST" | grep -o 'c-[a-z]*-handoff (MISSING)' | wc -l | tr -d ' ')"
chk_contains "the count is always there, whatever the roster does" "$RB_LIST" "0/8 done"
RB_V="$(hb "$RB" list --verbose)"
chk "--verbose restores the whole roster" "8" \
  "$(printf '%s' "$RB_V" | grep -o 'c-[a-z]*-handoff (MISSING)' | wc -l | tr -d ' ')"
chk "a bare list still works after the flag was added" "yes" \
  "$(printf '%s' "$(hb "$RB" list)" | grep -q '^ID ' && echo yes || echo no)"

# The generated summary line inside the bundle doc is truncated too: the table right below it
# carries every child, so a full roster there is the same information twice.
chk_contains "the generated summary line is bounded as well" \
  "$(sed -n 's/^\*\*.*Outstanding — //p' "$RB/.agents/handoff/wide-bundle-handoff.md")" "and 3 more"
# Counted as TABLE ROWS, not as occurrences of the word: the truncated summary line above the table
# also names a few of them, and a loose count silently passes whether the table is complete or not.
chk "while the generated table still carries every child, one row each" "8" \
  "$(grep -c '^| `c-[a-z]*-handoff` | `MISSING`' "$RB/.agents/handoff/wide-bundle-handoff.md")"

# --stub exists for children that are ALREADY on the roster and were never filed — which is every
# one of the 97. Skipping them as "already a child" would make the flag a no-op exactly when needed.
STUB_OUT="$(hb "$RB" children add --stub wide-bundle c-one c-two)"
chk_contains "--stub files a child that is already on the roster" "$STUB_OUT" "filed stub c-one-handoff"
chk "and the doc really exists afterwards" "yes" \
  "$([ -f "$RB/.agents/handoff/c-one-handoff.md" ] && echo yes || echo no)"
chk "a stub is a REAL handoff, claimable like any other" "yes" \
  "$(printf '%s' "$(hb "$RB" claim c-one "working the stub")" | grep -q 'Claimed' && echo yes || echo no)"
chk "the bundle now counts it as outstanding work, not as a gap" "yes" \
  "$(printf '%s' "$(hb "$RB" list)" | grep -q 'c-one-handoff (open)' && echo yes || echo no)"
chk_contains "--stub is refused on rm, where it means nothing" \
  "$(hb "$RB" children rm --stub wide-bundle c-two)" "only applies to 'children add'"

printf '\nthe secret scanner — write path, outbound, and a recorded override (ADR 0005)\n'
# The scanner exists because the only control before it was an HTML comment asking people not to
# paste secrets. Its two invariants are asserted everywhere below: NOTHING is written when it
# trips, and the refusal names the RULE, never the value it matched.
#
# `printf` builds every test credential from parts. A literal one in this file would be caught by
# the very sweep this feature adds to `verify`, and the file would then fail its own check.
AWSKEY="AKIA""IOSFODNN7EXAMPLE"
GHKEY="ghp_""abcdefghijklmnopqrstuvwxyz1234"

chk "a plausible AWS key id trips its rule" "aws-access-key-id" "$(printf '%s\n' "$AWSKEY" | scan_secrets)"
chk "and a GitHub token trips its own" "github-token" "$(printf '%s\n' "$GHKEY" | scan_secrets)"
chk "a clean line trips nothing, and says so by exit status" "1" \
  "$(
    printf 'nothing here\n' | scan_secrets > /dev/null
    echo $?
  )"
# The single most important false-negative case and the single most important false-positive case.
# A security handoff is MOSTLY prose about credentials; a scanner that fires on the word is a
# scanner that gets bypassed with --force-secret on every write, which is the same as no scanner.
chk "prose about secrets is not a secret" "1" \
  "$(
    printf 'rotate the deploy token and the db password before Friday\n' | scan_secrets > /dev/null
    echo $?
  )"
chk "and neither is a redaction placeholder" "1" \
  "$(
    printf 'password = <redacted len=25 sha256:585c2252>\n' | scan_secrets > /dev/null
    echo $?
  )"

SEC="$(mkboard)"
NEW_OUT="$(hb "$SEC" new leak-probe --title "probe" --note "key $AWSKEY here")"
chk_contains "new refuses a credential pasted into a flag" "$NEW_OUT" "aws-access-key-id"
chk "the refusal never echoes the value" "0" \
  "$(printf '%s' "$NEW_OUT" | grep -cF "$AWSKEY")"
# "Nothing was written" has to be literally true, which is why cmd_new renders to a temp file.
chk "and nothing was written" "no" \
  "$([ -f "$SEC/.agents/handoff/leak-probe-handoff.md" ] && echo yes || echo no)"

FORCE_OUT="$(hb "$SEC" new leak-probe --title "probe" --note "key $AWSKEY here" --force-secret "example key from the vendor's own docs")"
chk_contains "--force-secret gets past it" "$FORCE_OUT" "overridden"
chk_contains "and the override is RECORDED, with its reason" \
  "$(cat "$SEC/.agents/handoff/leak-probe-handoff.md")" "secret-scan OVERRIDDEN at creation (aws-access-key-id)"
chk_contains "naming the reason, not just the fact" \
  "$(cat "$SEC/.agents/handoff/leak-probe-handoff.md")" "example key from the vendor's own docs"
chk_contains "a bare --force-secret is refused — an unstated reason is a silent bypass" \
  "$(hb "$SEC" new other-probe --title "p" --force-secret)" "needs a value"

# release carries pasted terminal output more often than any other command, and terminal output is
# where credentials appear.
hb "$SEC" new rel-probe --title "rel" > /dev/null
hb "$SEC" claim rel-probe "x" > /dev/null
REL_OUT="$(hb "$SEC" release rel-probe --status done --verified-by "ran the suite with $GHKEY")"
chk_contains "release refuses a credential in the evidence" "$REL_OUT" "github-token"
chk "and the doc is untouched — still open, not archived" "open" \
  "$(sed -n 's/^status: //p' "$SEC/.agents/handoff/rel-probe-handoff.md" | head -1)"

printf '\noutbound redaction — the brief is scanned before anything leaves (ADR 0005)\n'
# The half that was missing. The CLI checked a RETURNED brief for pasted credentials while
# splicing document sections verbatim into an OUTBOUND one with no check at all.
OB="$(mkboard)"
hb "$OB" new ctx-leak --title "ctx leak" > /dev/null
python3 - "$OB/.agents/handoff/ctx-leak-handoff.md" "$AWSKEY" << 'PY'
import sys
p, key = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace("## Context\n", "## Context\n\nthe backup job authenticates as %s.\n" % key, 1))
PY
OB_OUT="$(hb "$OB" export ctx-leak --to Bob)"
chk_contains "export refuses a brief that would carry a credential" "$OB_OUT" "aws-access-key-id"
chk "no brief was written" "no" \
  "$([ -f "$OB/.agents/handoff/briefs/ctx-leak-handoff.brief.md" ] && echo yes || echo no)"
# The refusal happens BEFORE the claim on purpose: a lease taken for an export that never
# happened is a lease nobody knows to release.
chk "no lease was taken" "no" \
  "$([ -d "$OB/.agents/handoff/.locks/ctx-leak-handoff" ] && echo yes || echo no)"
chk "and the doc was not stamped as delegated" "" \
  "$(sed -n 's/^delegated_at: //p' "$OB/.agents/handoff/ctx-leak-handoff.md" | head -1)"

# A brief carries the four sections an executor needs and nothing else. The board's internal
# chronology — where the work stands, and who did what when — does not leave the board.
hb "$OB" new clean-unit --title "clean unit" > /dev/null
hb "$OB" export clean-unit --to Alice > /dev/null
CLEAN_BRIEF="$OB/.agents/handoff/briefs/clean-unit-handoff.brief.md"
chk "a clean brief carries no Current state" "0" "$(grep -c '^## Current state' "$CLEAN_BRIEF")"
chk "and no Activity log" "0" "$(grep -c '^## Activity' "$CLEAN_BRIEF")"

printf '\nexit codes — success is 0, on every command, restricted or not\n'
# Every assertion in this file checked OUTPUT. None checked status, and that gap shipped a bug:
# cmd_claim ended in `is_restricted ... && restricted_banner ...`, so a claim on an ORDINARY doc
# returned the condition's false status and exited 1 while succeeding in every visible way — and
# the restricted case, the one nobody runs in a loop, was the only one that exited 0. Anything
# gating on `handoff claim && ...` read every successful ordinary claim as a failure.
#
# `hb` captures output, so it cannot carry a status; these call the board CLI directly.
hbrc() { # repo subcommand... -> exit status only
  (cd "$1" && shift && ./.agents/handoff/handoff "$@" > /dev/null 2>&1)
  echo $?
}
XC="$(mkboard)"
chk "new (normal)" "0" "$(hbrc "$XC" new plain --title "Plain")"
chk "new (restricted)" "0" "$(hbrc "$XC" new locked --title "Locked" --sensitivity restricted)"
chk "claim (normal) — the regression" "0" "$(hbrc "$XC" claim plain "working")"
chk "claim (restricted)" "0" "$(hbrc "$XC" claim locked "working")"
chk "touch" "0" "$(hbrc "$XC" touch plain)"
chk "release --status open" "0" "$(hbrc "$XC" release plain --status open)"
chk "list" "0" "$(hbrc "$XC" list)"
chk "index" "0" "$(hbrc "$XC" index)"
chk "export (normal)" "0" "$(hbrc "$XC" export plain --to Someone)"
# And the refusals still refuse: a uniform 0 would be the same bug wearing the other mask.
hbrc "$XC" release locked --status open > /dev/null
chk "export (restricted) refuses" "1" "$(hbrc "$XC" export locked --to Someone)"
chk "claim on an unknown id refuses" "1" "$(hbrc "$XC" claim no-such-doc "x")"
chk "release with no --status refuses" "1" "$(hbrc "$XC" release plain)"

printf '\nsensitivity — a handling flag, not an access boundary (ADR 0005)\n'
SN="$(mkboard)"
hb "$SN" new key-rotation --title "Key rotation inventory" --sensitivity restricted --severity high > /dev/null
SN_DOC="$SN/.agents/handoff/key-rotation-handoff.md"
chk "restricted is recorded in frontmatter" "restricted" "$(sed -n 's/^sensitivity: //p' "$SN_DOC" | head -1)"
chk "an ordinary doc records the default explicitly, so the field is discoverable" "normal" \
  "$(
    hb "$SN" new ordinary --title "ordinary" > /dev/null
    sed -n 's/^sensitivity: //p' "$SN/.agents/handoff/ordinary-handoff.md" | head -1
  )"
chk_contains "a bad value is refused rather than silently read as normal" \
  "$(hb "$SN" new typo-doc --title "t" --sensitivity restrcted)" "bad --sensitivity"
chk_contains "and it is refused on a standalone doc, which is never exported anyway" \
  "$(hb "$SN" new ref-doc --title "r" --standalone --sensitivity restricted)" "never exported"

# Captured ONCE: claim takes a lease, so a second call would be answered by the lease, not the
# banner.
SN_CLAIM="$(hb "$SN" claim key-rotation "starting")"
chk_contains "claim prints the handling banner" "$SN_CLAIM" "RESTRICTED"
# The whole failure mode of a flag like this is being read as a permission. The banner has to say
# what it is not, in the same breath as what it is.
chk_contains "and the banner says plainly that it is not an access control" "$SN_CLAIM" "not an access control"

EXP_OUT="$(hb "$SN" export key-rotation --to "an external executor")"
chk_contains "export refuses a restricted doc outright" "$EXP_OUT" "sensitivity: restricted"
chk "with no brief written" "no" \
  "$([ -f "$SN/.agents/handoff/briefs/key-rotation-handoff.brief.md" ] && echo yes || echo no)"
# There is no --force-secret for this. The scanner's override is for false positives; restricted
# is a stated decision about the work, and an override would be a way to unmake it by accident.
chk_contains "and --force-secret does not unlock it" \
  "$(hb "$SN" export key-rotation --to X --force-secret "I am sure")" "sensitivity: restricted"

# The index keeps the title. Redacting it makes the board useless for exactly the work that most
# needs coordination, and the id discloses as much as the title does.
chk_contains "the index still lists it, by title" "$(cat "$SN/.agents/handoff/INDEX.md")" "Key rotation inventory"

# A bundle is refused WHOLE. Exporting the other children while refusing the restricted one would
# hand an executor a cover naming a unit they were never sent.
SB="$(mkboard)"
hb "$SB" new safe-child --title "safe" > /dev/null
hb "$SB" new secret-child --title "secret" --sensitivity restricted > /dev/null
hb "$SB" new roll-up --orchestrator --title "Roll-up" --children safe-child,secret-child > /dev/null
SB_OUT="$(hb "$SB" export roll-up --to Contractor)"
chk_contains "a bundle with a restricted child is refused" "$SB_OUT" "restricted child"
chk "and no cover file was written" "no" \
  "$([ -f "$SB/.agents/handoff/briefs/roll-up-handoff.cover.md" ] && echo yes || echo no)"
chk "nor a brief for the innocent sibling" "no" \
  "$([ -f "$SB/.agents/handoff/briefs/safe-child-handoff.brief.md" ] && echo yes || echo no)"

printf '\nschema versioning — read forward, refuse to write backward (ADR 0003)\n'
# These two are ONE decision. Warn-and-proceed covers reading and says nothing about writing, so an
# older CLI could read a newer doc, release it, and silently drop every field it did not know.
# Shipping only the read half is worse than shipping neither, so both are asserted together.
SV="$(mkboard)"
hb "$SV" new from-the-future --title "Written by a newer CLI" > /dev/null
FUT="$SV/.agents/handoff/from-the-future-handoff.md"
python3 - "$FUT" << 'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text().replace("schema: 1", "schema: 99", 1)
# A field this CLI has never heard of, to prove nothing quietly eats it. Deliberately nonsense:
# it was `sensitivity` until that became a real field, and a placeholder the CLI later learns
# stops testing anything.
p.write_text(s.replace("status: open", "status: open\nquantum_flux: 7", 1))
PY
hb "$SV" new ordinary-doc --title "An ordinary doc" > /dev/null

SV_LIST="$(hb "$SV" list)"
chk_contains "a newer doc is still LISTED" "$SV_LIST" "from-the-future-handoff"
chk_contains "with one warning naming both versions" "$SV_LIST" "is schema 99; this CLI understands 1"
chk "the warning is printed once, not once per doc" "1" \
  "$(printf '%s' "$SV_LIST" | grep -c 'this CLI understands' | tr -d ' ')"

chk_contains "claim on a newer doc is REFUSED" "$(hb "$SV" claim from-the-future "try")" "refusing to write it"
chk_contains "release too" "$(hb "$SV" release from-the-future --status open)" "refusing to write it"
chk_contains "and export, which stamps the doc" "$(hb "$SV" export from-the-future --to Someone)" "refusing to write it"
chk "the unknown field was never touched" "yes" \
  "$(grep -q '^quantum_flux: 7' "$FUT" && echo yes || echo no)"
chk "an ordinary doc is completely unaffected" "yes" \
  "$(printf '%s' "$(hb "$SV" claim ordinary-doc "fine")" | grep -q 'Claimed' && echo yes || echo no)"

printf '\nmigrate — structure only, and gated (ADR 0003)\n'
SM="$(mkboard)"
SMB="$SM/.agents/handoff"
cat > "$SMB/legacy-one-handoff.md" << 'EOF'
---
id: legacy-one-handoff
title: Written before the schema was versioned
type: coordination
status: open
severity: medium
created: 2026-01-01
updated: 2026-01-01
---

## Context

Predates environment, depends_on and Current state.
EOF
# mkboard writes no handoff.json, so this used to raise FileNotFoundError and stamp nothing — the
# gate still read as schema 0 (absent means 0), so the assertions passed while the setup they
# depend on had silently not happened, and the suite printed a traceback everyone learned to skip.
python3 - "$SMB/handoff.json" << 'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p)) if os.path.exists(p) else {}
d["schema"] = 0
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
chk_contains "a dry run reports what it would do and writes nothing" \
  "$(hb "$SM" migrate --dry-run)" "would migrate legacy-one-handoff"
chk "and really wrote nothing" "" "$(sed -n 's/^schema: //p' "$SMB/legacy-one-handoff.md" | head -1)"

# GATE: a live lease in this section. Migrating rewrites the file its holder is working in.
hb "$SM" claim legacy-one "holding it" > /dev/null
chk_contains "a live lease in the section blocks migration" "$(hb "$SM" migrate --yes)" "live lease(s) in this section"
hb "$SM" release legacy-one --status open > /dev/null

MIG="$(hb "$SM" migrate --yes)"
chk_contains "migration reports the version move" "$MIG" "Board schema 0 → 1"
chk "environment becomes EXPLICIT (absent already meant dev — this asserts nothing new)" "dev" \
  "$(sed -n 's/^environment: //p' "$SMB/legacy-one-handoff.md" | head -1)"
chk "depends_on gains its empty list" "[]" \
  "$(sed -n 's/^depends_on: //p' "$SMB/legacy-one-handoff.md" | head -1)"
chk "the doc is stamped" "1" "$(sed -n 's/^schema: //p' "$SMB/legacy-one-handoff.md" | head -1)"
chk "a rewritable Current state section is added" "yes" \
  "$(grep -q '^## Current state' "$SMB/legacy-one-handoff.md" && echo yes || echo no)"
# STRUCTURE ONLY. A migration that seeded Current state from the activity log, or stamped a
# sensitivity, would be writing a claim nobody made — on a board full of credential inventories
# that is an actively false claim, which is why this is asserted rather than assumed.
chk "but it is left EMPTY — no value was inferred" "" \
  "$(sed -n '/^## Current state/,/^## /p' "$SMB/legacy-one-handoff.md" | grep -v '^## \|^<!--\|^$' | head -1)"
chk "each migrated doc gains exactly one activity entry" "1" \
  "$(grep -c 'migrated to schema 1' "$SMB/legacy-one-handoff.md" | tr -d ' ')"
chk "the board itself is stamped" "1" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("schema"))' "$SMB/handoff.json")"
chk_contains "re-running is a no-op, not a second rewrite" "$(hb "$SM" migrate --yes)" "nothing to migrate"

# A payload bump moves a different number, and must not drag the whole board through a rewrite.
python3 - "$SMB/handoff.json" << 'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("_generated", {})["payloadVersion"] = "setup-handoff 999"
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
chk_contains "a payload-only bump triggers no migration" "$(hb "$SM" migrate)" "nothing to migrate"

printf '\nshared board — lease visibility and push-CAS\n'
SB="$(mkshared)"
"$SB/handoff" new cas-case --title "CAS case" --audience acme-api > /dev/null
CLAIM_OUT="$("$SB/handoff" claim cas-case "first" 2>&1)"
chk_contains "the claim reports repairing the stale .locks/ ignore rule" "$CLAIM_OUT" "removed '.locks/'"
chk ".locks/ is no longer ignored on a remote-backed board" "" \
  "$(grep -xF '.locks/' "$SB/.gitignore" 2> /dev/null)"
chk "the lease is committed, not left in the worktree" "yes" \
  "$(git -C "$SB" ls-files --error-unmatch .locks/cas-case-handoff/owner > /dev/null 2>&1 && echo yes || echo no)"
chk "the claim commit was pushed" "" "$(git -C "$SB" status -sb | grep -o 'ahead')"
chk "the doc travels with its lease" "yes" \
  "$(git -C "$SB" ls-files --error-unmatch cas-case-handoff.md > /dev/null 2>&1 && echo yes || echo no)"
chk "the generated index travels too, so the next fast-forward is not blocked" "yes" \
  "$(git -C "$SB" ls-files --error-unmatch INDEX.md > /dev/null 2>&1 && echo yes || echo no)"

printf '\nshared board — expiry is stamped from the commit, not the claiming clock\n'
# Rewrite the recorded expiry into the deep past and commit it. On a shared board the reader
# recomputes from the COMMIT time, so the lease is still live; trusting the field would report it
# expired and hand the work to a second machine while the first is still holding it.
grep -v '^expires=' "$SB/.locks/cas-case-handoff/owner" > "$SB/.locks/cas-case-handoff/owner.t"
printf 'expires=1\n' >> "$SB/.locks/cas-case-handoff/owner.t"
mv "$SB/.locks/cas-case-handoff/owner.t" "$SB/.locks/cas-case-handoff/owner"
git -C "$SB" commit -qam "tamper"
chk "a hand-edited expires= does not expire a committed lease" "held" \
  "$(cd "$SB" && HANDOFF_NO_MAIN=1 . ./handoff && lock_state cas-case-handoff | cut -d'|' -f1)"

printf '\nshared board — a second machine loses the race it did not win\n'
SB2="$(mktemp -d)/clone"
git clone -q "$(git -C "$SB" remote get-url origin)" "$SB2"
git -C "$SB2" config user.email "other@example.com"
git -C "$SB2" config user.name "other"
"$SB/handoff" new race-case --title "Race case" --audience acme-api > /dev/null
"$SB/handoff" claim race-case "machine one" > /dev/null
git -C "$SB2" fetch -q && git -C "$SB2" merge -q --ff-only '@{upstream}'
RACE_OUT="$("$SB2/handoff" claim race-case "machine two" 2>&1)"
chk "the second machine's claim fails" "1" "$([ -n "$RACE_OUT" ] && echo 1 || echo 0)"
chk_contains "and it says the lease is already held" "$RACE_OUT" "CLAIMED by"

printf '\nshared board — claim is strict offline, release is optimistic\n'
SB3="$(mkshared)"
"$SB3/handoff" new offline-case --title "Offline case" --audience acme-api > /dev/null
"$SB3/handoff" claim offline-case "before the network went" > /dev/null
git -C "$SB3" remote set-url origin "/nonexistent/gone.git"
OFF_CLAIM="$("$SB3/handoff" new second-case --title "Second case" --audience acme-api > /dev/null && "$SB3/handoff" claim second-case "offline" 2>&1)"
chk_contains "claim refuses when the remote is unreachable" "$OFF_CLAIM" "cannot reach the board's remote"
chk "nothing was claimed" "free" \
  "$(cd "$SB3" && HANDOFF_NO_MAIN=1 . ./handoff && lock_state second-case-handoff | cut -d'|' -f1)"
OFF_REL="$("$SB3/handoff" release offline-case --status open "stopping" 2>&1)"
chk_contains "release still succeeds offline" "$OFF_REL" "Released offline-case-handoff"
chk_contains "and says the push is still owed" "$OFF_REL" "push did not land"
chk "the lease is gone locally either way" "free" \
  "$(cd "$SB3" && HANDOFF_NO_MAIN=1 . ./handoff && lock_state offline-case-handoff | cut -d'|' -f1)"

printf '\nshared board — a lost CAS leaves nothing behind\n'
# Losing the race is the normal outcome of one, so the undo has to be complete: no lease, no
# commit, and nothing that would make the NEXT fetch refuse. A remote that rejects the push is the
# faithful simulation — it is precisely what a non-fast-forward rejection looks like to the client.
SB4="$(mkshared)"
SB4_REMOTE="$(git -C "$SB4" remote get-url origin)"
cat > "$SB4_REMOTE/hooks/pre-receive" << 'HOOK'
#!/bin/sh
exit 1
HOOK
chmod +x "$SB4_REMOTE/hooks/pre-receive"
"$SB4/handoff" new lost-case --title "Lost case" --audience acme-api > /dev/null
LOST_OUT="$("$SB4/handoff" claim lost-case "will lose the race" 2>&1)"
chk_contains "a rejected push refuses the claim rather than keeping it locally" "$LOST_OUT" "nothing was claimed"
chk "no lease is left behind" "free" \
  "$(cd "$SB4" && HANDOFF_NO_MAIN=1 . ./handoff && lock_state lost-case-handoff | cut -d'|' -f1)"
chk "the losing commit is rolled back, so the next fetch still fast-forwards" "" \
  "$(git -C "$SB4" log --oneline | grep -c 'claim lost-case' | grep -v '^0$')"
chk "and the rollback used no hard reset — the doc it wrote is still on disk" "yes" \
  "$([ -f "$SB4/lost-case-handoff.md" ] && echo yes || echo no)"

printf '\nboard_repo_entry — schema 2 identifies by root commit, never by path\n'
# The registry carries no path at all. Resolution goes through the per-machine location map, which
# is what lets one committed board resolve on a machine whose checkout layout differs from the
# machine that wrote it.
S2="$(mkboard)"
S2_TARGET="$(mktemp -d)/acme-lib"
mkdir -p "$S2_TARGET"
git -C "$S2_TARGET" init -q
git -C "$S2_TARGET" config user.email "test@example.com"
git -C "$S2_TARGET" config user.name "test"
printf 'x\n' > "$S2_TARGET/README.md"
git -C "$S2_TARGET" add -A
git -C "$S2_TARGET" commit -qm "initial commit"
S2_ROOT="$(git -C "$S2_TARGET" rev-list --max-parents=0 HEAD | tail -1)"
cat > "$S2/.agents/handoff/repos.json" << JSON
{
  "version": 2,
  "repos": [
    { "group": "acme", "alias": "lib", "audience": "acme-lib-$$", "rootCommit": "$S2_ROOT" }
  ]
}
JSON
HOME_SAVE="$HOME"
export HOME="$(mktemp -d)"
mkdir -p "$HOME/.agents"
printf '{ "version": 1, "locations": { "%s": "%s" } }\n' "$S2_ROOT" "$S2_TARGET" > "$HOME/.agents/handoff-locations.json"
S2_OUT="$(cd "$S2" && HANDOFF_NO_MAIN=1 . ./.agents/handoff/handoff && DIR="$S2/.agents/handoff" board_repo_entry "acme-lib-$$")"
chk "a path-less entry resolves through the per-machine location map" \
  "ok|$(cd "$S2_TARGET" && pwd -P)|$S2_ROOT" "$S2_OUT"
printf '{ "version": 1, "locations": {} }\n' > "$HOME/.agents/handoff-locations.json"
S2_MISS="$(cd "$S2" && HANDOFF_NO_MAIN=1 . ./.agents/handoff/handoff && DIR="$S2/.agents/handoff" WORKSPACE_ROOT="/nonexistent" board_repo_entry "acme-lib-$$")"
chk "an identified but unlocatable repo says so, rather than claiming it is undeclared" \
  "no-location||$S2_ROOT" "$S2_MISS"
export HOME="$HOME_SAVE"

printf '\n--- %d passed, %d failed ---\n' "$P" "$F"
[ "$F" -eq 0 ]
