#!/usr/bin/env bash
# detect-handoff.sh — find existing handoff installs and suggest a migration target.
# READ-ONLY. Scans repo-level and parent-level candidate locations, classifies each install,
# and prints machine-parseable FOUND lines plus a human suggestion. The SKILL uses this to
# drive the "migrate to current / parent-level / specific location" prompt.
#
# Usage: ./detect-handoff.sh [/path/to/repo] [--parents N]   (defaults: current dir, N=2)
#
# FOUND lines:  FOUND <path> | scope=repo|parent | kind=generic|legacy-toolpath|shared | version=current|legacy|unknown | docs=<n> | level=<0..N>
# Then:         CANDIDATES <n>, and AMBIGUOUS <n> when n >= 2.
#
# TWO PARENT LEVELS, NEVER AN UNBOUNDED WALK (ADR 0010). Repos sit at workspace/src/<repo> or
# workspace/<repo>, so the board of record is at level 1 in both; level 2 catches a workspace one
# folder further out. Stopping there keeps a workspace that merely CONTAINS another workspace from
# offering its board. --parents N is the deeper scan setup offers when nothing was found, and only
# then. Detection runs at setup only: the answer is written to config and runtime never re-scans.
#
# Exactly one candidate is a proposal to confirm. Zero or several is a question — the SKILL stops
# and asks, and this script never picks.
set -uo pipefail

TARGET="$PWD"
LEVELS=2
while [ $# -gt 0 ]; do
  case "$1" in
    --parents)
      case "${2:-}" in '' | *[!0-9]*) echo "--parents needs a number" >&2 && exit 1 ;; esac
      LEVELS="$2"
      shift
      ;;
    *) TARGET="$1" ;;
  esac
  shift
done
cd "$TARGET" 2> /dev/null || {
  echo "no such path: $TARGET" >&2
  exit 1
}
ROOT=$(git rev-parse --show-toplevel 2> /dev/null) || {
  echo "ERROR: not a git repo" >&2
  exit 1
}
GENERIC="$ROOT/.agents/handoff"

# candidate locations: repo-level tool paths + shared dirs at each parent level
REPO_CANDS=".agents/handoff .claude/handoff .gemini/handoff .github/handoff .handoff handoff"
PARENT_CANDS=".agents/handoff .claude/handoff handoff"

looks_like_install() { # dir -> 0 if it holds a handoff board
  local d="$1"
  [ -f "$d/handoff" ] && return 0
  [ -f "$d/INDEX.md" ] && return 0
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in README.md) continue ;; esac
    grep -q '^id:' "$f" 2> /dev/null && grep -q '^status:' "$f" 2> /dev/null && return 0
  done
  return 1
}

classify_version() { # dir -> current|legacy|unknown  (current == the script WRITES session= into the lease)
  local d="$1"
  [ -f "$d/handoff" ] || {
    echo unknown
    return
  }
  # match the actual lease write (echo "session=...), not a comment that merely mentions it
  grep -q '"session=' "$d/handoff" 2> /dev/null && echo current || echo legacy
}

count_docs() { # dir -> number of handoff docs (open + archived, excluding README/INDEX)
  local d="$1" n=0 f
  for f in "$d"/*.md "$d"/archive/*.md; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in README.md | INDEX.md) continue ;; esac
    n=$((n + 1))
  done
  echo "$n"
}

echo "Repo: $ROOT"
echo "Scanning for existing handoff installs..."
echo

FOUND_COUNT=0
GENERIC_CURRENT=0
LEGACY_REPO=""
LAST_PARENT=""
SEEN=""

report() { # abspath scope level
  local d="$1" scope="$2" level="$3"
  local rp="$d"
  case "$d" in "$ROOT"/*) rp="${d#$ROOT/}" ;; esac
  # dedupe by realpath
  case " $SEEN " in *" $d "*) return ;; esac
  SEEN="$SEEN $d"
  looks_like_install "$d" || return
  local kind ver docs
  case "$d" in
    "$GENERIC") kind=generic ;;
    "$ROOT"/.claude/* | "$ROOT"/.gemini/* | "$ROOT"/.github/*) kind=legacy-toolpath ;;
    *) [ "$scope" = parent ] && kind=shared || kind=generic ;;
  esac
  ver="$(classify_version "$d")"
  docs="$(count_docs "$d")"
  echo "FOUND $rp | scope=$scope | kind=$kind | version=$ver | docs=$docs | level=$level"
  FOUND_COUNT=$((FOUND_COUNT + 1))
  [ "$d" = "$GENERIC" ] && [ "$ver" = current ] && GENERIC_CURRENT=1
  [ "$scope" = repo ] && [ "$kind" = legacy-toolpath ] && LEGACY_REPO="$rp"
  [ "$scope" = parent ] && LAST_PARENT="$rp"
}

for c in $REPO_CANDS; do report "$ROOT/$c" repo 0; done
_dir="$ROOT"
_level=1
while [ "$_level" -le "$LEVELS" ]; do
  _up="$(cd "$_dir/.." && pwd)"
  [ "$_up" = "$_dir" ] && break # reached / — no higher level exists
  _dir="$_up"
  for c in $PARENT_CANDS; do report "$_dir/$c" parent "$_level"; done
  _level=$((_level + 1))
done

echo "CANDIDATES $FOUND_COUNT"
[ "$FOUND_COUNT" -ge 2 ] && echo "AMBIGUOUS $FOUND_COUNT — more than one board could be this repo's. Do not pick one: ask."

echo
echo "Suggestion:"
if [ "$FOUND_COUNT" = 0 ]; then
  echo "  No existing handoff install found in the repo or $LEVELS parent level(s). Ask before installing:"
  echo "    - a new in-repo board at .agents/handoff/ (or --handoff-dir <path>)"
  echo "    - a deeper scan:       detect-handoff.sh <repo> --parents $((LEVELS + 1))"
  echo "    - an existing board:   setup-handoff.sh <repo> --topology cross-repo --handoff-dir <path>"
elif [ "$FOUND_COUNT" -ge 2 ]; then
  echo "  Several candidate boards (FOUND above). Ask which one this repo uses — never choose silently."
  [ -n "$LEGACY_REPO" ] && echo "  Legacy install at '$LEGACY_REPO' can be migrated to the chosen one: --migrate $LEGACY_REPO"
elif [ -n "$LAST_PARENT" ]; then
  # The one candidate is a board outside the repo. That is a proposal to confirm, not a migration:
  # the board already exists and other repos may already use it.
  echo "  One candidate board, outside the repo: $LAST_PARENT. Propose it and confirm before wiring:"
  echo "    setup-handoff.sh <repo> --topology cross-repo --handoff-dir $LAST_PARENT"
elif [ "$GENERIC_CURRENT" = 1 ] && [ -z "$LEGACY_REPO" ]; then
  echo "  Already on the generic, current .agents/handoff/ — no migration needed (re-run is a no-op)."
else
  [ -n "$LEGACY_REPO" ] && echo "  Legacy install at '$LEGACY_REPO' — offer to UPGRADE + MIGRATE it to one of:"
  echo "    - current repo-level:  setup-handoff.sh <repo> --migrate <src>            (-> .agents/handoff/)"
  echo "    - parent-level shared: setup-handoff.sh <repo> --topology cross-repo --migrate <src>"
  echo "    - specific location:   setup-handoff.sh <repo> --handoff-dir <path> --migrate <src>"
  echo "  (<src> is the FOUND path above; migration preserves docs + archive/ + history.)"
fi

echo
echo "Detected: $FOUND_COUNT install(s)"
exit 0
