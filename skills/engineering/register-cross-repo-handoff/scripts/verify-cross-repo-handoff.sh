#!/usr/bin/env bash
# verify-cross-repo-handoff.sh — read-only health probe for a cross-repo handoff fleet.
#
#   verify-cross-repo-handoff.sh --scope <dir> [--from <dir>]
#
# Confirms the manifest cascade parses, each board is scaffolded with the expected group facts, each
# member repo is wired to its board + section, the AGENTS.md block matches the resolved set, and
# each board's repos.json still projects the manifest (the file `handoff export` resolves a
# cross-repo brief's target repo from — drift there is what silently degrades every brief).
# Distinguishes "not configured" (no manifest -> exit 0) from "broken" (-> exit 1). Writes nothing.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVE="$SKILL_DIR/scripts/manifest/resolve.py"
REGISTRY="$SKILL_DIR/scripts/manifest/registry.py"
# The payload's own config resolver, used here instead of grepping a filename. Board facts live in
# config.json on any board the current installer wrote, in a legacy KEY=value `config` on older
# ones, and a member repo's own identity lives in its .agents/handoff.config.json — with a
# precedence between them. This file already decides all of that for `handoff` and `hooks.sh`;
# re-deriving it here is how this verifier came to report FAIL on every healthy board.
#
# Prefer the SKILL's copy over the board's: it is current by construction, and auditing a board is
# not a reason to execute shell that lives inside it. The board's copy is only a fallback for a
# checkout where the setup-handoff sibling is absent.
PAYLOAD_CONFIG_SH="$SKILL_DIR/../setup-handoff/scripts/payload/config.sh"

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

# Print one board's (optionally one member repo's) effective config as HC_* assignments, via the
# payload resolver. Non-zero + no output when it cannot be resolved, so a caller must branch on the
# status BEFORE eval-ing: `eval "$(f)"` reports eval's own status, never the callee's, and a silent
# empty eval would leave the PREVIOUS board's HC_* values in scope and grade this board on them.
board_config() { # board-dir [repo-dir] -> HC_* assignments
  local board="$1" repo="${2:-}" src=""
  : > "$CFG_ERR"
  if [ -f "$PAYLOAD_CONFIG_SH" ]; then
    src="$PAYLOAD_CONFIG_SH"
  elif [ -f "$board/scripts/config.sh" ]; then
    src="$board/scripts/config.sh"
  else
    echo "no config resolver found (setup-handoff payload missing beside this skill, and the board ships none)" > "$CFG_ERR"
    return 1
  fi
  # shellcheck disable=SC1090
  . "$src" || return 1
  # The resolver names the offending file and the parse error on stderr. Captured rather than let
  # loose so it lands INSIDE the [FAIL] line it explains, instead of as a stray line between checks
  # that reads like output from whichever check happens to print next.
  handoff_config_load "$board" "$repo" 2> "$CFG_ERR"
}

# The captured reason from the last board_config call, or the caller's fallback wording.
cfg_reason() { # fallback -> one-line reason
  local r
  r="$(tail -1 "$CFG_ERR" 2> /dev/null)"
  printf '%s' "${r:-$1}"
}

# "not configured" short-circuit: no manifest anywhere in the cascade. Still print a Summary line so
# the harness (which parses exactly that line) sees a clean, gradeable result rather than no output.
if [ ! -f "$SCOPE/.handoff-repos.json" ] && [ ! -f "$HOME/.agents/handoff-repos.json" ]; then
  echo "verify: no .handoff-repos.json in scope or user layer — nothing to verify (not configured)."
  echo "Summary: 0 passed, 0 warnings, 0 failed"
  exit 0
fi

RESOLVED="$(mktemp)"
CFG_ERR="$(mktemp)"
trap 'rm -f "$RESOLVED" "$CFG_ERR"' EXIT
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
  if hc="$(board_config "$path")" && [ -n "$hc" ]; then
    eval "$hc"
    if [ "$HC_TOPOLOGY" = "cross-repo" ]; then pass "board $path is cross-repo"; else fail "board $path topology is '${HC_TOPOLOGY:-unset}', not cross-repo"; fi
    want="$(printf '%s' "$groups" | tr ',' '\n' | sort | paste -sd, -)"
    got="$(printf '%s' "$HC_GROUPS" | tr ',' '\n' | sort | paste -sd, -)"
    if [ "$want" = "$got" ]; then pass "board $path hosts groups: $want"; else fail "board $path groups drift (config: '${got:-unset}', manifest: '$want') — re-run the sync"; fi
    if [ "$HC_GROUP_LAYOUT" = "$layout" ]; then pass "board $path layout=$layout"; else fail "board $path layout drift (config: '${HC_GROUP_LAYOUT:-unset}', manifest: '$layout')"; fi
  else
    fail "board $path config could not be read — $(cfg_reason "no config.json and no legacy config file") — re-run the sync"
  fi
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
  # Wired and scoped are two different facts and are checked separately. The group used to be baked
  # into the hook command as HANDOFF_GROUP=<group>; it is not any more — merge-hooks.py writes it to
  # the member's own .agents/handoff.config.json so a rename cannot leave a stale literal buried in
  # a tool config. Grepping the old literal made every correctly-wired member read as broken.
  cfg="$repo/.claude/settings.json"
  if [ -f "$cfg" ]; then
    if grep -q '/scripts/hooks.sh' "$cfg"; then
      pass "$group/$alias claude hooks invoke the board"
    else
      fail "$group/$alias claude settings.json has no handoff hook — re-run the sync"
    fi
  else
    warn "$group/$alias has no .claude/settings.json (claude not wired — advisory only if another tool is primary)"
  fi
  if hc="$(board_config "$board" "$repo")" && [ -n "$hc" ]; then
    eval "$hc"
    if [ "$HC_GROUP" = "$group" ]; then
      pass "$group/$alias resolves to section $group"
    else
      fail "$group/$alias resolves to section '${HC_GROUP:-unset}', not $group — re-run the sync"
    fi
  else
    fail "$group/$alias config could not be read — $(cfg_reason "no readable board config, and no $repo/.agents/handoff.config.json") — re-run the sync"
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
echo "4. board repo registries"
echo "------------------------"
# `handoff export` resolves a handoff's `audience` to a real repo through <board>/repos.json. It is
# generated, never hand-edited, so ANY difference from the manifest is drift — and drift here is
# invisible at export time: every affected brief just quietly renders repo_root_commit: unverified.
# registry.py builds the expected bytes, the same call the sync writes with, so the two cannot
# disagree about what "correct" means.
while IFS= read -r bpath; do
  [ -n "$bpath" ] || continue
  # stdout carries the verdict; stderr carries registry.py's advisories (an unattestable member, an
  # audience claimed twice). Both are folded into one stream so neither is lost, then classified —
  # an advisory is a warn, because a correctly projected file can legitimately carry one.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *"matches the manifest"*) pass "$line" ;;
      *"missing"* | *"drift"*) fail "$line" ;;
      *) warn "$line" ;;
    esac
  done <<< "$(python3 "$REGISTRY" --resolved "$RESOLVED" --board "$bpath" --check 2>&1)"
done < <(
  python3 - "$RESOLVED" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for b in d["boards"]:
    print(b["path"])
PY
)

echo
echo "Summary: $PASS passed, $WARN warnings, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
