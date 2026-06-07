#!/usr/bin/env bash
# verify-graph-hooks.sh — confirm the graph hooks are installed AND fire correctly in a repo.
# Mirrors how Claude Code invokes hooks: each command is run with the same stdin payload,
# exit code 0 = allow, a JSON body with permissionDecision=block = block. Read-only except
# that running the Stop hook may kick off the (idempotent, guarded) background graph update.
#
# Usage: ./verify-graph-hooks.sh [/path/to/repo]      (defaults to current dir)
set -uo pipefail

TARGET="${1:-$PWD}"
cd "$TARGET" 2>/dev/null || { echo "no such path: $TARGET"; exit 1; }
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: not a git repo"; exit 1; }
cd "$ROOT"
export CLAUDE_PROJECT_DIR="$ROOT"   # Claude Code sets this; needed so repo-local script resolves

P=0; F=0; W=0
ok()   { printf '  [PASS] %s\n' "$1"; P=$((P+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; F=$((F+1)); }
warn() { printf '  [warn] %s\n' "$1"; W=$((W+1)); }
is_json() { printf '%s' "$1" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; }

echo "Repo: $ROOT"
echo
echo "1. Files in place"
echo "-----------------"

# settings: prefer repo-local, fall back to global
SET=""
if [ -f .claude/settings.local.json ]; then SET=.claude/settings.local.json
elif [ -f .claude/settings.json ];    then SET=.claude/settings.json
elif [ -f "$HOME/.claude/settings.json" ]; then SET="$HOME/.claude/settings.json"
fi
if [ -n "$SET" ]; then
  if is_json "$(cat "$SET")"; then ok "settings found and valid JSON: $SET"; else bad "settings is not valid JSON: $SET"; fi
else
  bad "no settings file found (.claude/settings.local.json, .claude/settings.json, or ~/.claude/settings.json)"
fi

# expected hook events present
if [ -n "$SET" ]; then
  for ev in Stop PreToolUse SessionStart; do
    if python3 -c "import json,sys; d=json.load(open('$SET')); sys.exit(0 if d.get('hooks',{}).get('$ev') else 1)" 2>/dev/null; then
      ok "hooks.$ev configured"
    else
      bad "hooks.$ev missing"
    fi
  done
  if python3 -c "import json,sys; d=json.load(open('$SET')); sys.exit(0 if d.get('hooks',{}).get('PostToolUse')==[] else 1)" 2>/dev/null; then
    ok "hooks.PostToolUse is empty []"
  else
    warn "hooks.PostToolUse is not empty — make sure nothing there double-fires with Stop"
  fi
fi

# smart-grep script
SCRIPT=""
[ -f .claude/scripts/smart-grep-hook.sh ] && SCRIPT=.claude/scripts/smart-grep-hook.sh
[ -z "$SCRIPT" ] && [ -f "$HOME/.claude/scripts/smart-grep-hook.sh" ] && SCRIPT="$HOME/.claude/scripts/smart-grep-hook.sh"
if [ -n "$SCRIPT" ]; then
  if [ -x "$SCRIPT" ]; then ok "smart-grep-hook.sh present and executable: $SCRIPT"
  else warn "smart-grep-hook.sh present but not executable: $SCRIPT (chmod +x it)"; fi
else
  warn "smart-grep-hook.sh not found — Bash interceptor will no-op"
fi

# git hook
HOOK=""
[ -f .husky/post-commit ] && HOOK=.husky/post-commit
[ -z "$HOOK" ] && [ -f .git/hooks/post-commit ] && HOOK=.git/hooks/post-commit
if [ -n "$HOOK" ]; then
  if grep -q 'graph-hooks-managed' "$HOOK" 2>/dev/null; then ok "post-commit hook installed: $HOOK"
  else warn "post-commit exists but no graph-hooks-managed marker: $HOOK"; fi
  [ -x "$HOOK" ] || warn "post-commit not executable: $HOOK (chmod +x it)"
else
  warn "no post-commit hook found — commit-time refresh won't run"
fi

# gitignore
for e in ".code-review-graph/" "graphify-out/"; do
  grep -qxF "$e" .gitignore 2>/dev/null && ok ".gitignore excludes $e" || warn ".gitignore missing $e"
done

echo
echo "2. Hooks execute (run exactly as Claude Code would)"
echo "---------------------------------------------------"
if [ -n "$SET" ]; then
  GHOOKS=$(mktemp "${TMPDIR:-/tmp}/ghooks.XXXXXX")
  GERR=$(mktemp "${TMPDIR:-/tmp}/gerr.XXXXXX")
  trap 'rm -f "$GHOOKS" "$GERR"' EXIT
  # dump every configured command as: EVENT <tab> MATCHER <tab> base64(command)
  python3 - "$SET" <<'PY' > "$GHOOKS" 2>/dev/null
import json,sys,base64
d=json.load(open(sys.argv[1]))
for ev,groups in d.get('hooks',{}).items():
    for g in groups:
        m=g.get('matcher','')
        for h in g.get('hooks',[]):
            c=h.get('command','')
            if c: print(ev+'\t'+(m or '_')+'\t'+base64.b64encode(c.encode()).decode())
PY
  while IFS="$(printf '\t')" read -r ev matcher b64; do
    [ -z "${b64:-}" ] && continue
    cmd=$(printf '%s' "$b64" | base64 -d 2>/dev/null)
    case "$ev" in
      PreToolUse)
        case "$matcher" in
          *Bash*)        payload='{"tool_input":{"command":"grep -rn something src/app.ts"}}'; label="PreToolUse/Bash" ;;
          *Read*|*Glob*) payload='{"tool_input":{"file_path":"src/app.ts"}}';                  label="PreToolUse/Read" ;;
          *)             payload='{}'; label="PreToolUse/$matcher" ;;
        esac ;;
      *) payload='{}'; label="$ev" ;;
    esac
    out=$(printf '%s' "$payload" | bash -c "$cmd" 2>"$GERR"); rc=$?
    if [ "$rc" -ne 0 ]; then
      bad "$label exited $rc — $(head -1 "$GERR" 2>/dev/null)"
    elif [ -z "$out" ]; then
      ok "$label ran cleanly (no output — correct when no graph / not matched)"
    elif printf '%s' "$out" | head -c1 | grep -q '{'; then
      if is_json "$out"; then
        if printf '%s' "$out" | grep -q '"permissionDecision":"block"'; then
          ok "$label ran and would BLOCK with inline answer (graph hit)"
        else
          ok "$label ran and emitted valid context JSON"
        fi
      else
        bad "$label emitted INVALID JSON"
      fi
    else
      ok "$label ran (plain text output, e.g. status)"
    fi
  done < "$GHOOKS"
fi

# direct smoke test of the script's two branches
if [ -n "$SCRIPT" ]; then
  o=$(printf '{"tool_input":{"command":"grep -rn TODO README.md"}}' | bash "$SCRIPT" 2>/dev/null); r=$?
  { [ "$r" = 0 ] && [ -z "$o" ]; } && ok "interceptor passes non-code (.md) target silently" || warn "interceptor unexpected on .md target (rc=$r)"
  o=$(printf '{"tool_input":{"command":"grep -rn x src/ --graph-tried"}}' | bash "$SCRIPT" 2>/dev/null); r=$?
  { [ "$r" = 0 ] && [ -z "$o" ]; } && ok "interceptor honors --graph-tried override" || warn "interceptor unexpected on --graph-tried (rc=$r)"
fi

echo
echo "3. Tools and graph state"
echo "------------------------"
if command -v code-review-graph >/dev/null 2>&1; then
  ok "code-review-graph installed ($(code-review-graph --version 2>/dev/null | head -1))"
  if [ -f .code-review-graph/graph.db ]; then
    ok "CRG graph built: $(code-review-graph status 2>/dev/null | tr '\n' ' ' | cut -c1-80)"
  else
    warn "CRG graph not built — run: code-review-graph install && code-review-graph build && code-review-graph embed"
  fi
else
  warn "code-review-graph not installed (hooks stay silent until it is)"
fi
if command -v graphify >/dev/null 2>&1; then
  ok "graphify installed"
  [ -f graphify-out/graph.json ] && ok "graphify graph built" || warn "graphify graph not built — run: graphify init . && graphify update ."
else
  warn "graphify not installed (optional)"
fi

# freshness: was the graph updated at/after the last commit?
if [ -f .code-review-graph/graph.db ]; then
  ct=$(git log -1 --format=%ct 2>/dev/null || echo 0)
  gt=$(stat -c %Y .code-review-graph/graph.db 2>/dev/null || stat -f %m .code-review-graph/graph.db 2>/dev/null || echo 0)
  [ "${gt:-0}" -ge "${ct:-0}" ] && ok "CRG graph is fresh (newer than last commit)" || warn "CRG graph older than last commit — commit again or run code-review-graph update"
fi

echo
echo "Summary: $P passed, $W warnings, $F failed"
[ "$F" -gt 0 ] && exit 1 || exit 0
