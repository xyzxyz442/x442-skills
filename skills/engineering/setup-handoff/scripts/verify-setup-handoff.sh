#!/usr/bin/env bash
# verify-setup-handoff.sh — confirm the handoff protocol is installed AND its hooks fire.
# READ-ONLY: it never claims/releases and never fires the posttool hook (which would
# regenerate INDEX.md). It fires the read-only hook paths (sessionstart, and pretool on
# INDEX.md / an ordinary file) exactly as a tool would, and inspects the wired config.
#
# Usage: ./verify-setup-handoff.sh [/path/to/repo]      (defaults to current dir)
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
cd "$ROOT"

P=0
F=0
W=0
ok() {
  printf '  [PASS] %s\n' "$1"
  P=$((P + 1))
}
bad() {
  printf '  [FAIL] %s\n' "$1"
  F=$((F + 1))
}
warn() {
  printf '  [warn] %s\n' "$1"
  W=$((W + 1))
}
is_json() { python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1" 2> /dev/null; }
is_json_str() { printf '%s' "$1" | python3 -c "import json,sys; json.load(sys.stdin)" 2> /dev/null; }

# Locate the handoff dir: the default repo-level path, else derive the configured location
# from any wired tool config (honors a custom --handoff-dir and any primary tool).
HD="$ROOT/.agents/handoff"
if [ ! -d "$HD" ]; then
  for CF in .claude/settings.json .claude/settings.local.json .gemini/settings.json .github/hooks/handoff.json; do
    [ -f "$ROOT/$CF" ] || continue
    # hooks.sh lives at <board>/scripts/hooks.sh; a board wired before the layout restructure has
    # it at <board>/hooks.sh. Match either, then strip the right number of path segments — one
    # dirname too few would point the verifier at the scripts/ subdir instead of the board.
    DERIVED=$(grep -o '[^"]*handoff/\(scripts/\)\?hooks\.sh' "$ROOT/$CF" 2> /dev/null | head -1)
    [ -n "$DERIVED" ] || continue
    D="${DERIVED##*CLAUDE_PROJECT_DIR/}"
    D="${D#bash }"
    case "$D" in */scripts/hooks.sh) D="$(dirname "$(dirname "$D")")" ;; *) D="$(dirname "$D")" ;; esac
    case "$D" in /*) HD="$D" ;; *) HD="$ROOT/$D" ;; esac
    break
  done
fi
# resolve any ../ or symlinks so paths we build match the hook's realpath $DIR
[ -d "$HD" ] && HD="$(cd "$HD" && pwd)"

echo "Repo: $ROOT"
echo "Handoff dir: $HD"
echo
echo "1. Payload present + executable"
echo "-------------------------------"
if [ ! -d "$HD" ]; then
  bad "handoff not installed (no $HD) — run setup-handoff"
  echo
  echo "Summary: $P passed, $W warnings, $F failed"
  exit 1
fi
# hooks.sh lives under scripts/ and the templates under templates/; a board installed before the
# layout restructure still has them flat, which is a warning (re-run the installer to migrate),
# not a failure — the CLI and hooks both fall back to the flat locations.
for f in handoff scripts/hooks.sh; do
  if [ -f "$HD/$f" ]; then
    [ -x "$HD/$f" ] && ok "$f present and executable" || warn "$f present but not executable (chmod +x)"
  elif [ -f "$HD/$(basename "$f")" ]; then
    warn "$(basename "$f") is at the board root (flat layout) — re-run setup-handoff to migrate to $f"
  else bad "$f missing"; fi
done
for f in README.md config; do
  [ -f "$HD/$f" ] && ok "$f present" || warn "$f missing"
done
if [ -f "$HD/templates/handoff-doc-template.md" ]; then
  ok "templates/handoff-doc-template.md present"
elif [ -f "$HD/handoff-doc-template.md" ]; then
  warn "handoff-doc-template.md is at the board root (flat layout) — re-run setup-handoff to migrate"
else warn "handoff-doc-template.md missing"; fi
[ -d "$HD/archive" ] && ok "archive/ present" || warn "archive/ missing (created on first done)"

echo
echo "2. Config, gitignore, AGENTS.md block"
echo "-------------------------------------"
TOPO=""
if [ -f "$HD/config" ]; then
  TOPO=$(sed -n 's/^TOPOLOGY=//p' "$HD/config" | head -1)
  case "$TOPO" in single-repo | cross-repo) ok "config topology: $TOPO" ;; *) bad "config missing/invalid TOPOLOGY" ;; esac
else bad "config missing"; fi
if [ "$TOPO" = "cross-repo" ]; then
  # Shared board lives outside the worktree and owns its own .gitignore; a consumer .locks/ entry
  # would be inert, so its absence is correct — not a warning.
  ok ".gitignore .locks/ check skipped (cross-repo: shared board self-ignores its .locks/)"
else
  grep -q '/.locks/' .gitignore 2> /dev/null && ok ".gitignore excludes .locks/" || warn ".gitignore missing a .locks/ entry — leases could get committed"
fi
if grep -q 'handoff:begin' AGENTS.md 2> /dev/null && grep -q 'handoff:end' AGENTS.md 2> /dev/null; then
  ok "AGENTS.md routing block present (handoff:begin/end)"
else bad "AGENTS.md routing block missing"; fi

echo
echo "3. Wired tools + hard-enforcement primary"
echo "-----------------------------------------"
WIRED=""
HARD=""
check_tool() { # name file marker_event
  local name="$1" file="$2"
  [ -f "$file" ] || return 0
  if grep -qE 'handoff/(scripts/)?hooks\.sh' "$file" 2> /dev/null; then
    if is_json "$file"; then
      ok "$name wired + valid JSON: ${file#$ROOT/}"
      WIRED="${WIRED:+$WIRED }$name"
      # hard enforcement = a pretool-edit (deny) hook is wired for this tool
      grep -q 'pretool-edit' "$file" 2> /dev/null && HARD="${HARD:+$HARD }$name"
    else bad "$name config invalid JSON: ${file#$ROOT/}"; fi
  fi
}
check_tool claude "$ROOT/.claude/settings.json"
check_tool claude "$ROOT/.claude/settings.local.json"
check_tool gemini "$ROOT/.gemini/settings.json"
check_tool copilot "$ROOT/.github/hooks/handoff.json"
[ -z "$WIRED" ] && bad "no tool hooks wired (expected at least one)"
if [ -n "$HARD" ]; then
  ok "hard-enforcement primary wired (pretool deny): $HARD"
else
  warn "no hard-enforcement primary (advisory-only) — no tool has a pretool deny gate"
fi

echo
echo "4. Enforcement preflight (python3)"
echo "----------------------------------"
if command -v python3 > /dev/null 2>&1; then
  ok "python3 present — the deny gate can parse hook payloads"
else
  [ -n "$HARD" ] && bad "python3 MISSING but hard enforcement is wired — the gate will fail safe (deny handoff-doc edits)" \
    || warn "python3 missing (advisory-only install; deny gate unavailable)"
fi

echo
echo "5. Hooks fire (read-only paths)"
echo "-------------------------------"
HK="$HD/scripts/hooks.sh"
[ -f "$HK" ] || HK="$HD/hooks.sh" # flat (pre-restructure) board
if [ -f "$HK" ]; then
  # sessionstart: valid JSON context, or empty when no open handoffs — both fine.
  out=$(printf '{"session_id":"verify"}' | bash "$HK" --kind sessionstart --tool claude 2> /dev/null)
  if [ -z "$out" ]; then ok "sessionstart ran cleanly (no open handoffs)"; elif is_json_str "$out"; then ok "sessionstart emitted valid context JSON"; else bad "sessionstart emitted INVALID JSON"; fi

  # pretool on INDEX.md must DENY (generated) — proves the gate fires deterministically.
  out=$(printf '{"session_id":"verify","tool_input":{"file_path":"%s/INDEX.md"}}' "$HD" | bash "$HK" --kind pretool-edit --tool claude 2> /dev/null)
  if is_json_str "$out" && printf '%s' "$out" | grep -qE '"permissionDecision": *"deny"'; then ok "pretool-edit denies editing generated INDEX.md"; else bad "pretool-edit did NOT deny INDEX.md edit"; fi

  # pretool on an ordinary repo file must ALLOW (empty) — never block non-handoff files.
  out=$(printf '{"session_id":"verify","tool_input":{"file_path":"%s/src/app.js"}}' "$ROOT" | bash "$HK" --kind pretool-edit --tool claude 2> /dev/null)
  [ -z "$out" ] && ok "pretool-edit allows ordinary (non-handoff) files" || bad "pretool-edit wrongly acted on an ordinary file"
else
  bad "hooks.sh missing — cannot fire"
fi

echo
echo "6. handoff script runs"
echo "----------------------"
if [ -x "$HD/handoff" ]; then
  "$HD/handoff" list > /dev/null 2>&1 && ok "handoff list runs" || bad "handoff list failed"
else warn "handoff not executable"; fi

echo
echo "Summary: $P passed, $W warnings, $F failed"
if [ "$F" -gt 0 ]; then exit 1; fi
exit 0
