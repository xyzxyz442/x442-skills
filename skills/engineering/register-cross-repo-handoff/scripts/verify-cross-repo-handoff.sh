#!/usr/bin/env bash
# verify-cross-repo-handoff.sh — read-only health probe for a cross-repo handoff fleet.
#
#   verify-cross-repo-handoff.sh --scope <dir> [--from <dir>]
#
# Confirms the manifest cascade parses, each board is scaffolded with the expected group facts, each
# member repo is wired to its board + section, and the AGENTS.md block matches the resolved set.
# Distinguishes "not configured" (no manifest -> exit 0) from "broken" (-> exit 1). Writes nothing.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVE="$SKILL_DIR/scripts/manifest/resolve.py"

SCOPE="" FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scope)
      SCOPE="${2:-}"
      shift 2
      ;;
    --from)
      FROM="${2:-}"
      shift 2
      ;;
    *)
      echo "verify: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done
[ -n "$SCOPE" ] || {
  echo "usage: verify-cross-repo-handoff.sh --scope <dir> [--from <dir>]" >&2
  exit 2
}
[ -n "$FROM" ] || FROM="$SCOPE"
command -v python3 > /dev/null 2>&1 || {
  echo "verify: python3 required" >&2
  exit 2
}

PASS=0 WARN=0 FAIL=0
pass() {
  echo "  [PASS] $*"
  PASS=$((PASS + 1))
}
warn() {
  echo "  [warn] $*"
  WARN=$((WARN + 1))
}
fail() {
  echo "  [FAIL] $*"
  FAIL=$((FAIL + 1))
}

# "not configured" short-circuit: no manifest anywhere in the cascade.
if [ ! -f "$SCOPE/.handoff-repos.json" ] && [ ! -f "$HOME/.agents/handoff-repos.json" ]; then
  echo "verify: no .handoff-repos.json in scope or user layer — nothing to verify (not configured)."
  exit 0
fi

RESOLVED="$(mktemp)"
trap 'rm -f "$RESOLVED"' EXIT
python3 "$RESOLVE" --scope "$SCOPE" --from "$FROM" > "$RESOLVED"
RES_RC=$?

echo "1. manifest cascade"
echo "-------------------"
# parse errors are FAILs (a missing repo, bad JSON, bad alias)
while IFS= read -r line; do [ -n "$line" ] && fail "$line"; done < <(
  python3 - "$RESOLVED" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for e in d.get("errors", []):
    print(e)
PY
)
[ "$RES_RC" = 0 ] && pass "cascade resolves with no errors"
while IFS= read -r line; do [ -n "$line" ] && warn "$line"; done < <(
  python3 - "$RESOLVED" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for w in d.get("warnings", []):
    print(w)
PY
)

echo
echo "2. boards"
echo "---------"
# BOARD<TAB>path<TAB>groups_csv<TAB>layout
while IFS=$'\t' read -r path groups layout; do
  [ -n "$path" ] || continue
  if [ -x "$path/handoff" ] && [ -f "$path/scripts/hooks.sh" ]; then
    pass "board $path has payload"
  else
    fail "board $path missing payload (handoff / scripts/hooks.sh) — run the sync"
    continue
  fi
  cfg="$path/config"
  if grep -q '^TOPOLOGY=cross-repo$' "$cfg" 2> /dev/null; then pass "board $path is cross-repo"; else fail "board $path config not TOPOLOGY=cross-repo"; fi
  want="$(printf '%s' "$groups" | tr ',' '\n' | sort | paste -sd, -)"
  got="$(sed -n 's/^HANDOFF_GROUPS=//p' "$cfg" 2> /dev/null | tr ',' '\n' | sort | paste -sd, -)"
  if [ "$want" = "$got" ]; then pass "board $path hosts groups: $want"; else fail "board $path HANDOFF_GROUPS drift (config: '${got:-unset}', manifest: '$want') — re-run the sync"; fi
  gotlay="$(sed -n 's/^HANDOFF_GROUP_LAYOUT=//p' "$cfg" 2> /dev/null)"
  if [ "$gotlay" = "$layout" ]; then pass "board $path layout=$layout"; else fail "board $path layout drift (config: '${gotlay:-unset}', manifest: '$layout')"; fi
  # sub-index + roll-up presence (generated on first CLI use; absence is a warn, not a fail)
  [ -f "$path/INDEX.md" ] || warn "board $path has no roll-up INDEX.md yet (created on first handoff command)"
  for g in $(printf '%s' "$groups" | tr ',' ' '); do
    if [ "$layout" = "prefix" ]; then sidx="$path/INDEX-$g.md"; else sidx="$path/$g/INDEX.md"; fi
    [ -f "$sidx" ] || warn "group $g has no sub-index yet ($sidx — created on first handoff command)"
  done
done < <(
  python3 - "$RESOLVED" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for b in d["boards"]:
    print("\t".join([b["path"], ",".join(sorted(b["groups"])), d["layout"]]))
PY
)

echo
echo "3. member repos"
echo "---------------"
# MEMBER<TAB>group<TAB>board<TAB>alias<TAB>repo<TAB>exists<TAB>has_agents
while IFS=$'\t' read -r group board alias repo exists has_agents; do
  [ -n "$alias" ] || continue
  if [ "$exists" != 1 ]; then
    fail "$group/$alias — $repo not on disk"
    continue
  fi
  if [ "$has_agents" != 1 ]; then
    fail "$group/$alias — no AGENTS.md"
    continue
  fi
  if grep -q 'cross-repo-handoff:begin' "$repo/AGENTS.md" 2> /dev/null; then
    # the block must name this repo's own group
    if sed -n '/cross-repo-handoff:begin/,/cross-repo-handoff:end/p' "$repo/AGENTS.md" | grep -q "\`$group\` section"; then
      pass "$group/$alias AGENTS.md block present + scoped to $group"
    else
      fail "$group/$alias AGENTS.md block does not name the $group section — re-run the sync"
    fi
  else
    fail "$group/$alias missing the cross-repo-handoff AGENTS.md block — re-run the sync"
  fi
  # hook wiring (claude): a handoff hook command carrying this repo's HANDOFF_GROUP
  cfg="$repo/.claude/settings.json"
  if [ -f "$cfg" ]; then
    if grep -q "HANDOFF_GROUP=$group" "$cfg" && grep -q '/scripts/hooks.sh' "$cfg"; then
      pass "$group/$alias claude hooks wired to section $group"
    else
      fail "$group/$alias claude settings.json has no handoff hook for section $group — re-run the sync"
    fi
  else
    warn "$group/$alias has no .claude/settings.json (claude not wired — advisory only if another tool is primary)"
  fi
done < <(
  python3 - "$RESOLVED" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for g in d["groups"]:
    for m in g["members"]:
        print("\t".join([g["group"], g["board"], m["alias"], m["path"],
                         "1" if m["exists"] else "0", "1" if m["has_agents_md"] else "0"]))
PY
)

echo
echo "Summary: $PASS passed, $WARN warnings, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
