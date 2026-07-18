#!/usr/bin/env bash
# detect-handoff.sh — find existing handoff installs and suggest a migration target.
# READ-ONLY. Scans repo-level and parent-level candidate locations, classifies each install,
# and prints machine-parseable FOUND lines plus a human suggestion. The SKILL uses this to
# drive the "migrate to current / parent-level / specific location" prompt.
#
# Usage: ./detect-handoff.sh [/path/to/repo]      (defaults to current dir)
#
# FOUND lines:  FOUND <path> | scope=repo|parent | kind=generic|legacy-toolpath|shared | version=current|legacy|unknown | docs=<n>
set -uo pipefail

TARGET="${1:-$PWD}"
cd "$TARGET" 2> /dev/null || {
  echo "no such path: $TARGET" >&2
  exit 1
}
ROOT=$(git rev-parse --show-toplevel 2> /dev/null) || {
  echo "ERROR: not a git repo" >&2
  exit 1
}
PARENT="$(cd "$ROOT/.." && pwd)"
GENERIC="$ROOT/.agents/handoff"

# candidate locations: repo-level tool paths + parent-level shared dirs
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
SEEN=""

report() { # abspath scope
  local d="$1" scope="$2"
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
  echo "FOUND $rp | scope=$scope | kind=$kind | version=$ver | docs=$docs"
  FOUND_COUNT=$((FOUND_COUNT + 1))
  [ "$d" = "$GENERIC" ] && [ "$ver" = current ] && GENERIC_CURRENT=1
  [ "$scope" = repo ] && [ "$kind" = legacy-toolpath ] && LEGACY_REPO="$rp"
}

for c in $REPO_CANDS; do report "$ROOT/$c" repo; done
for c in $PARENT_CANDS; do report "$PARENT/$c" parent; done

echo
echo "Suggestion:"
if [ "$FOUND_COUNT" = 0 ]; then
  echo "  No existing handoff install found. A fresh install will be created at .agents/handoff/"
  echo "  (or the location you pass via --handoff-dir / --topology cross-repo)."
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
