#!/usr/bin/env bash
# verify-standalone.sh — enforce the "standalone repo" house rule (read-only).
#
# This repo is the SOURCE of skills, not a participant in anyone's fleet. Nothing committed
# here may name, path to, or execute code in another project. Skills get installed *from*
# here into other repos; the result of such an install must never be committed back *into*
# here — that is how `../<someone>/...` hook paths and real service names leak in.
#
# Three checks, all read-only:
#   wiring    a `../` path in tool-config that would execute or read outside the repo
#   escaping  a `../SEGMENT` path whose first segment names nothing in this repo
#   names     an identifier listed in scripts/standalone-denylist.txt
#
# Escape hatch: put `standalone-ok` in a comment on the offending line, or
# `standalone-ok-next-line` on the line above it (the prettier-safe form for markdown). Use it
# for prose that must quote a real name (a cited vendor doc) — never to re-wire.
#
# Usage: scripts/verify-standalone.sh [--staged] [PATH...]
#   --staged     check only files staged for commit (what the pre-commit hook runs)
#   PATH...      check only these paths
#   (no args)    check every git-tracked file
#
# Exit 0 clean, 1 on any violation.

set -euo pipefail

DENYLIST="scripts/standalone-denylist.txt"

# Tool-config directories: a `../` here is wiring, and wiring never legitimately leaves the
# repo. Kept separate from the escaping check because the bar is absolute, not heuristic.
WIRING_DIRS='^(\.claude|\.gemini|\.vscode|\.husky|\.github/hooks)/'

# Neutral placeholders that stand in for "some other repo" in documentation and fixtures.
# These deliberately name nothing real, so `../acme-lib` is allowed to escape.
PLACEHOLDERS='^(acme|acme-.*|example|example-.*|my-.*|some-.*|other-.*|the-.*|workspace|svc-.*|foo|bar|baz|repo-[ab]|parent|sibling)$'

# Not a project reference: an ellipsis standing in for an elided path (`../.../handoff`), and
# build output a tool writes relative to its own config (jest `coverageDirectory: "../coverage"`).
NON_PROJECT='^(\.+|coverage|dist|build|out|tmp|target|node_modules)$'

# Paths never scanned: generated artifacts, vendored trees, lockfiles.
EXCLUDE='(^|/)(node_modules|graphify-out|\.code-review-graph|\.tmp|dist|build)/|(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock)$'

violations=0

fail() {
  echo "Error: $1" >&2
  exit 2
}

report() {
  # report <file> <line-number> <check> <message>
  printf '  %s:%s  [%s] %s\n' "$1" "$2" "$3" "$4" >&2
  violations=$((violations + 1))
}

# section: file selection
select_files() {
  case "${1:-}" in
    --staged)
      git diff --cached --name-only --diff-filter=ACMR
      ;;
    "")
      git ls-files
      ;;
    *)
      printf '%s\n' "$@"
      ;;
  esac
}

# section: repo vocabulary
# Every path segment that exists anywhere in this repo. A `../SEG` whose SEG is in here is an
# intra-repo relative reference (`../AGENTS.md`, `../lib/grade_common.py`); one that is not
# names something outside, which is exactly what this rule forbids.
build_repo_segments() {
  git ls-files | tr '/' '\n' | sort -u
}

is_text_file() {
  [ -f "$1" ] || return 1
  # `grep -Iq .` succeeds only on text; an empty file also passes, which is fine.
  LC_ALL=C grep -Iq . "$1" 2> /dev/null || [ ! -s "$1" ]
}

# section: checks
# Each check is a single grep pass over the whole file list, emitting `file:line:text`.
# Per-line shell loops are far too slow at repo scale — keep the greps whole-file.

build_hatch_keys() {
  # `file:line` for every exempted line. Precomputed once, because the escaping pass greps for
  # the matched token alone and so cannot see the marker in its own output.
  #
  # Two spellings. `standalone-ok` exempts the line it sits on, which is the natural form in
  # code and config. `standalone-ok-next-line` exempts the following line instead, and is the
  # form to use in markdown: prettier reflows prose and moves a trailing inline comment onto a
  # different line than the text it was meant to cover, whereas a comment on its own line stays
  # put. The -next-line form emits both keys, so it works whichever way prettier leaves it.
  {
    grep -n 'standalone-ok' "$@" /dev/null 2> /dev/null | cut -d: -f1,2
    grep -n 'standalone-ok-next-line' "$@" /dev/null 2> /dev/null \
      | cut -d: -f1,2 \
      | awk -F: '{ print $1 ":" $2 + 1 }'
  } | sort -u || true
}

is_hatched() {
  # is_hatched <file> <line-number>
  grep -qxF "$1:$2" "$HATCH_FILE"
}

check_wiring() {
  # A `../` in tool config is wiring that would execute or read outside the repo.
  local wiring=()
  local f
  for f in "$@"; do
    [[ "$f" =~ $WIRING_DIRS ]] && wiring+=("$f")
  done
  [ "${#wiring[@]}" -eq 0 ] && return 0

  local hit
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    is_hatched "${hit%%:*}" "$(cut -d: -f2 <<< "$hit")" && continue
    report "${hit%%:*}" "$(cut -d: -f2 <<< "$hit")" wiring \
      "tool config reaches outside the repo — hooks and settings must stay repo-relative"
  done < <(grep -nF -- '../' "${wiring[@]}" /dev/null)
}

check_escaping() {
  # `../SEG` where SEG names nothing in this repo points at another project.
  local hit file line seg
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file="${hit%%:*}"
    line="$(cut -d: -f2 <<< "$hit")"
    is_hatched "$file" "$line" && continue
    seg="${hit#*:*:}"
    seg="${seg#../}"
    [ "$seg" = ".." ] && continue
    grep -qxF "$seg" "$SEGMENTS_FILE" && continue
    [[ "$seg" =~ $PLACEHOLDERS ]] && continue
    [[ "$seg" =~ $NON_PROJECT ]] && continue
    report "$file" "$line" escaping \
      "\`../$seg\` points outside this repo — use a neutral placeholder (acme-api, ../workspace)"
  done < <(grep -noE -- '\.\./[A-Za-z0-9._-]+' "$@" /dev/null)
}

check_names() {
  # One alternation built from the denylist, matched on word boundaries.
  local pattern
  pattern="$(grep -vE '^\s*(#|$)' "$DENYLIST" | paste -sd'|' -)"
  [ -n "$pattern" ] || return 0

  local hit
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    local file="${hit%%:*}"
    local line
    line="$(cut -d: -f2 <<< "$hit")"
    is_hatched "$file" "$line" && continue
    local matched
    matched="$(cut -d: -f3- <<< "$hit" | grep -oiE "(^|[^A-Za-z0-9_-])($pattern)([^A-Za-z0-9_-]|$)" | grep -oiE "$pattern" | sort -u | tr '\n' ' ' | sed 's/ $//; s/ /, /g')"
    report "$file" "$line" names \
      "names the foreign project \`$matched\` — replace with a neutral placeholder"
  done < <(grep -niE "(^|[^A-Za-z0-9_-])($pattern)([^A-Za-z0-9_-]|\$)" "$@" /dev/null)
}

# section: execution
main() {
  git rev-parse --show-toplevel > /dev/null 2>&1 || fail "not inside a git repository."
  cd "$(git rev-parse --show-toplevel)"
  [ -f "$DENYLIST" ] || fail "missing denylist: $DENYLIST"

  SEGMENTS_FILE="$(mktemp)"
  trap 'rm -f "$SEGMENTS_FILE"' EXIT
  build_repo_segments > "$SEGMENTS_FILE"

  local file
  local -a files=()
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [[ "$file" =~ $EXCLUDE ]] && continue
    # The rule's own definition and denylist must be able to spell the words they forbid.
    case "$file" in "$DENYLIST" | scripts/verify-standalone.sh) continue ;; esac
    is_text_file "$file" || continue
    files+=("$file")
  done < <(select_files "$@")

  if [ "${#files[@]}" -eq 0 ]; then
    echo "[PASS] standalone rule: no files to check."
    return 0
  fi

  HATCH_FILE="$(mktemp)"
  trap 'rm -f "$SEGMENTS_FILE" "$HATCH_FILE"' EXIT
  build_hatch_keys "${files[@]}" > "$HATCH_FILE"

  check_wiring "${files[@]}"
  check_escaping "${files[@]}"
  check_names "${files[@]}"

  if [ "$violations" -gt 0 ]; then
    echo "" >&2
    echo "[FAIL] $violations standalone-rule violation(s) in ${#files[@]} file(s)." >&2
    echo "       This repo must not reference any project other than itself." >&2
    echo "       See the 'Standalone repo' house rule in AGENTS.md and docs/standalone-rule.md." >&2
    return 1
  fi
  echo "[PASS] standalone rule: no foreign-project references in ${#files[@]} file(s)."
}

main "$@"
