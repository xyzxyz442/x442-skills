#!/usr/bin/env bash
# Refuse a change to a skill's PAYLOAD that does not move that skill's payload.version.
#
# WHY THIS EXISTS, in one sentence: nothing else can catch it.
#
# A payload is what a skill copies into a target repository (CONTEXT.md). `payload.version` is the
# stamp the installer writes into each install, and `verify-*.sh` compares the two to tell a target
# "you are behind — re-run the installer". Change the payload without moving the stamp and the
# numbers still match, so the comparison finds nothing, no target is ever told, and every install
# keeps the old behaviour permanently.
#
# The obvious guard does NOT cover this. `sync-fixture-boards.sh --check` compares the harness
# fixtures against the payload, and the fixtures deliberately carry no copy of the CLI (the harness
# points $HANDOFF_BIN at the payload, so the binary under test is never stale). A CLI-only edit
# therefore produces no fixture drift at all: the check passes, the pre-commit hook is satisfied,
# and the commit lands with no bump and no complaint. That happened — a behaviour fix to the handoff
# CLI shipped at the previous stamp and had to be corrected afterwards.
#
# The relationship runs one way only, which is why one script cannot do both jobs:
#   payload edited   -> stamp must move   (THIS script; nothing else sees it)
#   stamp moved      -> fixtures restale  (sync-fixture-boards.sh --check already sees it)
#
# Read-only. Exits non-zero on a violation and names the skill and the stamp to move.
#
#   bash scripts/verify-payload-version.sh --staged            # pre-commit: the staged set
#   bash scripts/verify-payload-version.sh --range A..B        # CI: an explicit range
#   bash scripts/verify-payload-version.sh --against origin/main
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# Which paths inside a skill are PAYLOAD, per skill that owns a stamp.
#
# Restated here rather than derived, because the five installers do not share one copy helper:
# setup-handoff and setup-secret-guard use `install_file`, setup-graph-hooks uses plain `cp -R`, and
# setup-project-tooling has no installer script at all — its assets are applied from the skill body.
# A table that restates something is a table that can go stale, so every entry is existence-checked
# below: a path matching nothing FAILS rather than silently covering nothing. That is the same
# vacuity trap the selftest guards against before its absence assertions.
#
# Format: <skill dir> <payload path>...   (paths are relative to the skill dir)
PAYLOADS="
skills/engineering/setup-graph-hooks|scripts/graph-hooks scripts/setup-embeddings.sh scripts/post-commit scripts/graphignore assets
skills/engineering/setup-handoff|scripts/payload assets
skills/engineering/setup-project-tooling|assets
skills/engineering/setup-secret-guard|scripts/payload assets
skills/personal/setup-delegate-agent|scripts/payload assets
"

# Files that live under a payload path but are NOT copied into a target, so editing them cannot
# make any install stale. Keep this list short and justified — every entry is coverage given up.
#   *.selftest.sh  the suites that test the payload; the harness runs them from the repo, never installs them
#   __pycache__    build residue, not tracked content
is_excluded() {
  case "$1" in
    *.selftest.sh | *__pycache__*) return 0 ;;
    *) return 1 ;;
  esac
}

MODE=""
REF=""
case "${1:-}" in
  --staged) MODE=staged ;;
  --range)
    MODE=range
    REF="${2:-}"
    ;;
  --against)
    MODE=against
    REF="${2:-}"
    ;;
  -h | --help)
    sed -n '2,30p' "$0"
    exit 0
    ;;
  "")
    MODE=staged
    ;;
  *)
    echo "verify-payload-version: unknown argument '$1'" >&2
    exit 2
    ;;
esac
if [ "$MODE" != staged ] && [ -z "$REF" ]; then
  echo "verify-payload-version: $1 needs a value" >&2
  exit 2
fi

changed_files() {
  case "$MODE" in
    staged) git diff --cached --name-only --diff-filter=ACMRD ;;
    range) git diff --name-only --diff-filter=ACMRD "$REF" ;;
    against) git diff --name-only --diff-filter=ACMRD "$REF...HEAD" ;;
  esac
}

CHANGED="$(changed_files)" || {
  echo "verify-payload-version: could not read the changed-file list" >&2
  exit 2
}

fails=0
stale=0
checked=0

while IFS='|' read -r skill paths; do
  [ -n "$skill" ] || continue
  stamp="$skill/scripts/payload.version"

  # The stamp itself must exist, or this skill is in the table by mistake.
  if [ ! -f "$stamp" ]; then
    echo "[FAIL] $stamp does not exist — the table in $(basename "$0") is stale."
    stale=$((stale + 1))
    continue
  fi

  # Existence check per path, so a rename empties coverage loudly instead of silently.
  hits=""
  for p in $paths; do
    if [ ! -e "$skill/$p" ]; then
      echo "[FAIL] $skill/$p matches nothing — the table in $(basename "$0") is stale."
      stale=$((stale + 1))
      continue
    fi
    hits="$hits $skill/$p"
  done
  [ -n "$hits" ] || continue
  checked=$((checked + 1))

  # Did any payload file change, ignoring the excluded ones?
  touched=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_excluded "$f" && continue
    for p in $hits; do
      case "$f" in
        "$p" | "$p"/*)
          touched="$touched $f"
          break
          ;;
      esac
    done
  done <<< "$CHANGED"

  [ -n "$touched" ] || continue

  # It did. The stamp has to be in the same change set.
  if printf '%s\n' "$CHANGED" | grep -qxF "$stamp"; then
    echo "[PASS] $(basename "$skill") — payload changed and $stamp moves with it."
  else
    echo "[FAIL] $(basename "$skill") — payload changed but $stamp does not move."
    for f in $touched; do echo "         $f"; done
    echo "       An install compares its stamp against this one, so without the bump no target is"
    echo "       ever told it is behind and every install keeps the old behaviour."
    echo "       Bump $stamp, then run: bash scripts/sync-fixture-boards.sh"
    fails=$((fails + 1))
  fi
done <<< "$PAYLOADS"

if [ "$stale" -gt 0 ]; then
  echo "[FAIL] $stale payload path(s) in the table no longer exist — fix the table before trusting this check."
  exit 1
fi
if [ "$fails" -gt 0 ]; then
  exit 1
fi
if [ "$checked" -eq 0 ]; then
  echo "[FAIL] no skill payload was checked — the table is empty or unreadable."
  exit 1
fi
echo "[PASS] payload version stamps: no payload changed without its bump."
