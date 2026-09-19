#!/usr/bin/env bash
# Self-test for setup-handoff.sh's --with-mirror-workflow flag: install_mirror_workflow()
# renders .github/workflows/handoff-mirror.yml from assets/mirror-workflow.yml, substituting
# __BRANCH__, __SECTIONS__, __BOARD_PATH__, __TOKEN_EXPR__ and __TOKEN_NOTE__ from the board's
# own committed config. None of this was under automated coverage before this file — it was
# verified by hand while the flag was built, which means the next edit to install_mirror_workflow
# or to the template would have no test to catch a regression.
# Run: bash setup-handoff.selftest.sh
#
# SAFETY: every board this suite creates gets a remote under the "example-invalid" GitHub org
# (github.com/example-invalid/...) or the RFC 2606 reserved "example.invalid" host — never a real
# remote. --with-mirror-workflow commits the board and, when it already has a remote, best-effort
# pushes it (board_commit_payload in setup-handoff.sh). Against a real remote that push would land
# unrelated scratch history and a stray branch on a live repository; that is exactly what happened
# once while this flag was being built. Against these fake hosts the push fails fast (DNS failure
# for example.invalid, "repository not found" for the nonexistent example-invalid org) and touches
# nothing. Do not swap in a real owner/repo, even temporarily.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$HERE/setup-handoff.sh"

# Defensive, not load-bearing: the "repository not found" replies measured while writing this
# suite came back with no prompt at all, but a cached credential helper (this machine's is
# osxkeychain, not gh) is still a plausible source of a hang on someone else's box. Refusing any
# prompt outright is cheap insurance against that, on a push that must never succeed anyway.
export GIT_TERMINAL_PROMPT=0

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

# A fresh, empty repository at a private scratch path, git-initialised BEFORE setup-handoff.sh
# ever sees it. --board-only's own bootstrap (board_bootstrap in setup-handoff.sh) clones from
# --remote whenever the board directory is not already a repository at that exact path — which is
# the right behaviour for a teammate joining a real shared board, but would mean every board this
# suite makes attempts a `git clone` against a fake host. Pre-initialising here makes
# board_bootstrap take its "already here and already a repository" early return instead, so the
# only network operation any case below can trigger is the single best-effort push described above.
mkgitboard() { # -> prints a fresh board path
  local d
  d="$(mktemp -d)/b"
  git init --quiet "$d"
  printf '%s' "$d"
}

# Seed handoff.json with just an `external` block BEFORE the first install, so write_board_config
# (setup-handoff.sh) reads it as the board's existing config and preserves it — the same path a
# real board's external tracker declaration takes (ADR 0011's cross-repo tooling writes it, this
# installer only ever preserves it; there is deliberately no --external-repo flag). Doing this
# before the one and only --board-only call, rather than editing the file afterward and installing
# a second time, keeps each tracked board down to a single commit and a single push attempt.
seed_external() { # board-dir tracker-repo
  python3 -c '
import json, sys
path, tracker = sys.argv[1], sys.argv[2]
json.dump({"external": {"kind": "issues", "system": "github", "repo": tracker}}, open(path, "w"))
' "$1/handoff.json" "$2"
}

GH_FAKE_REMOTE="https://github.com/example-invalid/no-such-board.git"

printf '\n1. three refusals: no origin remote, exit nonzero, no workflow written\n'
B1="$(mkgitboard)"
OUT1="$("$INSTALLER" --board-only "$B1" --groups core --with-mirror-workflow 2>&1)"
ST1=$?
chk "no-origin board: refuses with a nonzero exit" "nonzero" "$([ "$ST1" -ne 0 ] && echo nonzero || echo zero)"
chk_contains "no-origin board: names the missing remote" "$OUT1" "no 'origin' remote"
chk "no-origin board: writes no workflow file" "no" "$([ -f "$B1/.github/workflows/handoff-mirror.yml" ] && echo yes || echo no)"

printf '\n1. three refusals: remote not on github.com, exit nonzero, no workflow written\n'
B2="$(mkgitboard)"
# example.invalid is one of the RFC 2606 reserved test domains: it can never resolve, so the
# best-effort push this board's install attempts fails on DNS alone, before any real network peer
# is involved.
git -C "$B2" remote add origin "https://example.invalid/no-such-board.git"
OUT2="$("$INSTALLER" --board-only "$B2" --groups core --with-mirror-workflow 2>&1)"
ST2=$?
chk "non-github remote: refuses with a nonzero exit" "nonzero" "$([ "$ST2" -ne 0 ] && echo nonzero || echo zero)"
chk_contains "non-github remote: names the reason" "$OUT2" "cannot run for it"
chk "non-github remote: writes no workflow file" "no" "$([ -f "$B2/.github/workflows/handoff-mirror.yml" ] && echo yes || echo no)"

printf '\n1. three refusals: no external.repo declared, exit nonzero, no workflow written\n'
B3="$(mkgitboard)"
git -C "$B3" remote add origin "$GH_FAKE_REMOTE"
OUT3="$("$INSTALLER" --board-only "$B3" --groups core --with-mirror-workflow 2>&1)"
ST3=$?
chk "no-tracker board: refuses with a nonzero exit" "nonzero" "$([ "$ST3" -ne 0 ] && echo nonzero || echo zero)"
chk_contains "no-tracker board: names the missing tracker" "$OUT3" "declares no external tracker"
chk "no-tracker board: writes no workflow file" "no" "$([ -f "$B3/.github/workflows/handoff-mirror.yml" ] && echo yes || echo no)"

printf '\n2. not passing the flag installs no workflow at all\n'
B4="$(mkgitboard)"
git -C "$B4" remote add origin "$GH_FAKE_REMOTE"
OUT4="$("$INSTALLER" --board-only "$B4" --groups core 2>&1)"
ST4=$?
chk "flag omitted: the plain board-only install still succeeds" "0" "$ST4"
chk "flag omitted: no workflow file" "no" "$([ -f "$B4/.github/workflows/handoff-mirror.yml" ] && echo yes || echo no)"
chk "flag omitted: not even a .github directory" "no" "$([ -d "$B4/.github" ] && echo yes || echo no)"

printf '\n3+5+6. self-tracker board: GITHUB_TOKEN, no ACTION NEEDED, exact sections\n'
B5="$(mkgitboard)"
git -C "$B5" remote add origin "$GH_FAKE_REMOTE"
# The tracker equals the board's own remote repo (both parse to example-invalid/no-such-board),
# which is the case ADR 0011 says needs no secret at all: the workflow's own GITHUB_TOKEN already
# carries issues:write on the repository it runs in.
seed_external "$B5" "example-invalid/no-such-board"
OUT5="$("$INSTALLER" --board-only "$B5" --groups "alpha,beta,gamma" --with-mirror-workflow 2>&1)"
ST5=$?
WF5="$B5/.github/workflows/handoff-mirror.yml"
chk "self-tracker: installer succeeds" "0" "$ST5"
chk "self-tracker: workflow file was written" "yes" "$([ -f "$WF5" ] && echo yes || echo no)"
chk_contains "self-tracker: uses the built-in GITHUB_TOKEN" "$(cat "$WF5")" 'GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}'
chk "self-tracker: prints no ACTION NEEDED line" "" "$(printf '%s' "$OUT5" | grep 'ACTION NEEDED')"
chk_contains "sections: SECTIONS names exactly the board's configured groups, in order" \
  "$(cat "$WF5")" 'SECTIONS="alpha beta gamma"'
chk_contains "board path: working-directory is . when the board is its own repository root" \
  "$(cat "$WF5")" 'working-directory: .'

printf '\n4+5. separate-tracker board: HANDOFF_TRACKER_TOKEN, ACTION NEEDED names the secret\n'
B6="$(mkgitboard)"
git -C "$B6" remote add origin "$GH_FAKE_REMOTE"
# A tracker in a DIFFERENT repository than the board's own remote: GITHUB_TOKEN has no access
# there, so the workflow needs a repository secret and the installer must say so out loud.
seed_external "$B6" "example-invalid/other-tracker"
OUT6="$("$INSTALLER" --board-only "$B6" --groups core --with-mirror-workflow 2>&1)"
ST6=$?
WF6="$B6/.github/workflows/handoff-mirror.yml"
chk "separate tracker: installer succeeds" "0" "$ST6"
chk_contains "separate tracker: uses the named repository secret" "$(cat "$WF6")" 'GH_TOKEN: ${{ secrets.HANDOFF_TRACKER_TOKEN }}'
chk_contains "separate tracker: installer prints an ACTION NEEDED line" "$OUT6" "ACTION NEEDED: set the repository secret HANDOFF_TRACKER_TOKEN"
chk_contains "separate tracker: the ACTION NEEDED line names the tracker repo" "$OUT6" "example-invalid/other-tracker"

printf '\n5. never a token value: every GH_TOKEN: line is a ${{ ... }} expression, not a literal\n'
for label_wf in "self-tracker:$WF5" "separate-tracker:$WF6"; do
  label="${label_wf%%:*}"
  wf="${label_wf#*:}"
  bad="$(grep '^[[:space:]]*GH_TOKEN:' "$wf" | grep -vc '\${{ secrets\.[A-Za-z_]* }}')"
  chk "$label: every GH_TOKEN line is a secrets expression" "0" "$bad"
done

printf '\n7. board path: a nested board renders the relative subpath, not .\n'
# --board-only always git-inits the board AT the board directory (ADR 0011's standalone board is
# its own repository by design), so it can never produce the nested shape on its own -- that shape
# is what an ordinary single-repo install makes: a board living under an existing repo's own git
# history. No fixture board in this repo's own harness is nested like this, which is exactly why
# the task calls it out as the one real gap.
mkparentrepo() { # -> prints repo path, with AGENTS.md (setup-handoff.sh requires it) and a commit
  local r
  r="$(mktemp -d)"
  git init --quiet "$r"
  git -C "$r" remote add origin "$GH_FAKE_REMOTE"
  git -C "$r" config user.email "test@example.com"
  git -C "$r" config user.name "test"
  printf '# scratch repo for setup-handoff.selftest.sh\n' > "$r/AGENTS.md"
  git -C "$r" add -A
  git -C "$r" commit --quiet -m "initial commit"
  printf '%s' "$r"
}
NB="$(mkparentrepo)"
NB_BRANCH="$(git -C "$NB" symbolic-ref --quiet --short HEAD)"
# Plain (non --board-only) install: this is the path that never calls board_ensure_git, so it
# never commits or pushes anything -- this case is the only one in the suite that touches no
# network at all.
#
# --tools and --primary are passed exactly as SKILL.md's own "Apply" step documents
# (--tools <comma-list> --primary <tool|none>), not omitted: omitting --tools entirely reaches a
# real bug in setup-handoff.sh (see the report at the end of this suite) that has nothing to do
# with the mirror workflow this file is testing, and is not how the skill ever actually invokes
# the installer.
"$INSTALLER" "$NB" --tools claude --primary none > /dev/null 2>&1
NB_BOARD="$NB/.agents/handoff"
chk "nested board: the default single-repo install landed at .agents/handoff" "yes" "$([ -f "$NB_BOARD/handoff.json" ] && echo yes || echo no)"
seed_external "$NB_BOARD" "example-invalid/no-such-board"
OUT7="$("$INSTALLER" "$NB" --tools claude --primary none --with-mirror-workflow 2>&1)"
ST7=$?
WF7="$NB/.github/workflows/handoff-mirror.yml"
chk "nested board: installer succeeds" "0" "$ST7"
chk "nested board: workflow file was written at the PARENT repo's root" "yes" "$([ -f "$WF7" ] && echo yes || echo no)"
chk_contains "nested board: working-directory is the board's relative subpath" "$(cat "$WF7")" "working-directory: .agents/handoff"
chk_contains "nested board: branch is read from the parent repo's actual HEAD" "$(cat "$WF7")" "branches: [$NB_BRANCH]"

printf '\nomitting --tools does not abort on bash 3.2 (unbound array)\n'
# `IFS=',' read -r -a ARR <<< ""` leaves the array UNSET on bash 3.2 -- the default /bin/bash on
# macOS -- rather than zero-length, so the next `"${ARR[@]}"` under `set -u` aborts the script.
# bash 4+ does NOT reproduce it, so this case must run under /bin/bash explicitly; running it
# under whatever `bash` is first on PATH proves nothing.
#
# It is reachable from the tool's OWN printed advice: detect-handoff.sh suggests
# `setup-handoff.sh <repo> --migrate <src>` and `... --topology cross-repo --handoff-dir <board>`,
# neither of which carries --tools.
UB="$(mkparentrepo)"
UB_OUT="$(/bin/bash "$INSTALLER" "$UB" 2>&1)"
UB_ST=$?
chk "installer exits 0 with no --tools" "0" "$UB_ST"
case "$UB_OUT" in
  *"unbound variable"*) chk "no unbound-variable abort" "no" "yes" ;;
  *) chk "no unbound-variable abort" "no" "no" ;;
esac
# TOOLS defaults to "" and PRIMARY to "none", so wiring nothing is the coherent reading -- but it
# must be SAID, or the operator gets a board whose lease gate is off and no hint why.
chk_contains "and it says no tool config was wired" "$UB_OUT" "no --tools"
chk "the board is still installed" "yes" "$([ -d "$UB/.agents/handoff" ] && echo yes || echo no)"
chk "and the CLI is executable" "yes" "$([ -x "$UB/.agents/handoff/handoff" ] && echo yes || echo no)"
# An explicit empty list is the same instruction, spelled out.
UB2="$(mkparentrepo)"
UB2_ST=$(
  /bin/bash "$INSTALLER" "$UB2" --tools "" --primary none > /dev/null 2>&1
  echo $?
)
chk "an explicitly empty --tools behaves the same" "0" "$UB2_ST"
# The sibling site: setup-graph-hooks.sh defaults TOOLS to "claude", so it only reaches the same
# shape when an empty list is passed explicitly -- which is one flag away, not unreachable.
GH_INST="$HERE/../../setup-graph-hooks/scripts/setup-graph-hooks.sh"
if [ -f "$GH_INST" ]; then
  UB3="$(mkparentrepo)"
  UB3_OUT="$(/bin/bash "$GH_INST" "$UB3" --tools "" 2>&1)"
  case "$UB3_OUT" in
    *"unbound variable"*) chk "setup-graph-hooks.sh survives an empty --tools too" "no" "yes" ;;
    *) chk "setup-graph-hooks.sh survives an empty --tools too" "no" "no" ;;
  esac
fi

printf '\n--- %d passed, %d failed ---\n' "$P" "$F"
[ "$F" -eq 0 ]
