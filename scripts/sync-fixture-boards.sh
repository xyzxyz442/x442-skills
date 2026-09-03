#!/usr/bin/env bash
# Re-sync every harness fixture board from the setup-handoff payload.
#
# A fixture board is a committed snapshot of an installed board, so the files the installer copies
# verbatim -- the dispatcher, hooks.sh, config.sh, README.md, the doc templates -- are mirrors. A
# mirror that is edited in one place and not the others is drift, and the idempotency evals fail on
# it with a message ("re-run produces an empty diff") that names the symptom rather than the file.
# Doing this by hand across ~15 boards is exactly the chore that produced the drift.
#
# The CLI itself is deliberately NOT mirrored: fixtures carry the dispatcher and the harness points
# $HANDOFF_BIN at the payload, so the binary under test can never be stale (grade_common.payload_cli).
#
# Read-only apart from the fixture files it rewrites. Idempotent. Run after any payload change:
#   bash scripts/sync-fixture-boards.sh          # write
#   bash scripts/sync-fixture-boards.sh --check  # report drift, write nothing (exit 1 if any)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD="$ROOT/skills/engineering/setup-handoff/scripts/payload"
ASSETS="$ROOT/skills/engineering/setup-handoff/assets"
PAYLOAD_VERSION_FILE="$ROOT/skills/engineering/setup-handoff/scripts/payload.version"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

# Fixtures whose board is a deliberately OLD install -- a stale payload stamp, a pre-migration
# tool-path layout. Their mirrors are the thing under test, so syncing them would delete the
# scenario. Matched as a path substring.
SKIP_FIXTURES="stale-stamp legacy-install"

changed=0
sync_one() { # src dest
  local s="$1" d="$2"
  [ -f "$d" ] || return 0 # only refresh mirrors a fixture already carries; never add new files
  cmp -s "$s" "$d" && return 0
  changed=$((changed + 1))
  if [ "$CHECK" = "1" ]; then
    echo "  drift: ${d#"$ROOT"/}"
  else
    cp "$s" "$d"
    echo "  synced: ${d#"$ROOT"/}"
  fi
}

# The payload STAMP is a mirror too, and a less obvious one: it lives inside the fixture's
# handoff.json rather than in a file the installer copies, so sync_one never sees it. Left behind on
# a version bump it fails the idempotency evals with "re-run produces an empty diff" naming
# handoff.json — the installer rewrites the stamp to the version it ships, which IS the drift.
# Rewritten in place (key by key, not regenerated) so every other value the fixture encodes as its
# scenario -- ttlHours, groups, topology, schema -- survives untouched.
sync_stamp() { # board-dir
  local cfg="$1/handoff.json" shipped
  [ -f "$cfg" ] || return 0
  shipped="$(head -1 "$PAYLOAD_VERSION_FILE" 2> /dev/null)"
  [ -n "$shipped" ] || return 0
  python3 - "$cfg" "$shipped" "$CHECK" "${cfg#"$ROOT"/}" << 'PYEOF' || changed=$((changed + 1))
import json, sys
cfg, shipped, check, label = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(cfg) as fh:
    d = json.load(fh)
gen = d.get("_generated")
if not isinstance(gen, dict) or gen.get("payloadVersion") in (None, shipped):
    sys.exit(0)  # no stamp to keep current, or already current
print(f"  {'drift' if check == '1' else 'synced'}: {label} ({gen['payloadVersion']} -> {shipped})")
if check != "1":
    gen["payloadVersion"] = shipped
    with open(cfg, "w") as fh:
        json.dump(d, fh, indent=2, sort_keys=True)
        fh.write("\n")
sys.exit(1)  # signal "this one changed" to the caller's counter
PYEOF
}

for board in $(find "$ROOT/harness" -type d -name handoff -path '*/fixtures/*' | sort); do
  skip=0
  for pat in $SKIP_FIXTURES; do
    case "$board" in *"$pat"*) skip=1 ;; esac
  done
  if [ "$skip" = "1" ]; then
    echo "skip (deliberately old): ${board#"$ROOT"/}"
    continue
  fi
  echo "${board#"$ROOT"/}"
  sync_one "$PAYLOAD/dispatcher" "$board/handoff"
  sync_one "$PAYLOAD/hooks.sh" "$board/scripts/hooks.sh"
  sync_one "$PAYLOAD/config.sh" "$board/scripts/config.sh"
  sync_one "$PAYLOAD/README.md" "$board/README.md"
  for t in handoff-doc-template handoff-standalone-template handoff-orchestrator-template handoff-brief-template; do
    sync_one "$ASSETS/$t.md" "$board/templates/$t.md"
  done
  sync_stamp "$board"
done

if [ "$CHECK" = "1" ]; then
  if [ "$changed" -gt 0 ]; then
    echo "[FAIL] $changed fixture file(s) have drifted from the payload — run: bash scripts/sync-fixture-boards.sh"
    exit 1
  fi
  echo "[PASS] every fixture board matches the payload."
else
  echo "Synced $changed file(s)."
fi
