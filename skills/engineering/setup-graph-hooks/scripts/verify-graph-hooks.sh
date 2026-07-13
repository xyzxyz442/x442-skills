#!/usr/bin/env bash
# verify-graph-hooks.sh — confirm the tool-generic graph hooks are installed AND fire.
# Read-only except that exercising the refresh may kick off the (idempotent, locked)
# background graph update. Discovers which tools are wired from their config files and
# fires the shared dispatcher with each tool's stdin shape, exactly as the tool would.
#
# Usage: ./verify-graph-hooks.sh [/path/to/repo]      (defaults to current dir)
set -uo pipefail

TARGET="${1:-$PWD}"
cd "$TARGET" 2> /dev/null || {
  echo "no such path: $TARGET"
  exit 1
}
ROOT=$(git rev-parse --show-toplevel 2> /dev/null) || {
  echo "ERROR: not a git repo"
  exit 1
}
cd "$ROOT"
export CLAUDE_PROJECT_DIR="$ROOT"

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
is_json() { printf '%s' "$1" | python3 -c "import json,sys; json.load(sys.stdin)" 2> /dev/null; }

# Semantic search is an opt-in tier, so ZERO embeddings is a healthy state, not a defect:
# CRG's semantic_search() falls back to keyword search over node names. Only a half-finished
# embed, or vectors the hooks can no longer refresh, deserve a warning.
check_embeddings() {
  read -r EMB NODES EPROV <<< "$(
    python3 - << 'PY' 2> /dev/null
import sqlite3
try:
    c = sqlite3.connect("file:.code-review-graph/graph.db?mode=ro", uri=True, timeout=2)
    nodes = c.execute("SELECT count(*) FROM nodes WHERE kind!='File'").fetchone()[0]
    emb = c.execute("SELECT count(*) FROM embeddings").fetchone()[0]
    row = c.execute("SELECT provider FROM embeddings GROUP BY provider "
                    "ORDER BY count(*) DESC LIMIT 1").fetchone()
    print(emb, nodes, (row[0] if row and row[0] else "-"))
except Exception:
    print(0, 0, "-")
PY
  )"

  if [ "${EMB:-0}" = 0 ]; then
    ok "semantic search: keyword mode (0 embeddings — optional; ./setup-embeddings.sh to enable)"
    return 0
  fi

  if [ "${EMB:-0}" -lt "${NODES:-0}" ]; then
    warn "semantic search: ${EMB}/${NODES} nodes embedded — interrupted embed; fix: code-review-graph embed"
  else
    ok "semantic search: vector mode (${EMB} embeddings, provider=${EPROV})"
  fi

  # Vectors exist but nothing can refresh them: the gate will skip embed from here on.
  RESOLVED=$(bash .graph-hooks/core/embed-provider.sh 2> /dev/null)
  if [ -z "$RESOLVED" ]; then
    warn "embeddings cannot refresh — .code-review-graph/embed.env missing; vectors will go stale"
    return 0
  fi

  # An Ollama-backed provider is only as live as its daemon.
  if [ "$RESOLVED" = openai ] && [ -f .code-review-graph/embed.env ]; then
    BASE=$(sed -n 's/^CRG_OPENAI_BASE_URL=//p' .code-review-graph/embed.env | head -1)
    if [ -n "$BASE" ] && ! curl -sf --max-time 2 "${BASE%/v1}/api/tags" > /dev/null 2>&1; then
      case "$BASE" in
        *localhost* | *127.0.0.1*) warn "ollama not reachable at $BASE — embeddings will not refresh" ;;
      esac
    fi
  fi

  # The READ path is a different process from the refresh hooks. CRG's OpenAI provider needs
  # CRG_OPENAI_* in the MCP server's own environment, and its `provider` argument defaults to
  # `local` regardless — so a non-local graph whose MCP server is unconfigured writes vectors
  # that semantic_search_nodes_tool will never read. The graph looks healthy; the feature is off.
  case "$EPROV" in
    openai:* | google:* | minimax:*)
      if [ -f .mcp.json ] && grep -q 'CRG_OPENAI_BASE_URL' .mcp.json 2> /dev/null; then
        ok "MCP read path configured — call the tool with provider=\"${EPROV%%:*}\" to use these vectors"
      else
        warn "MCP server has no CRG_OPENAI_* env — semantic_search will answer in keyword mode despite ${EMB} vectors"
      fi
      ;;
  esac
}

echo "Repo: $ROOT"
echo
echo "1. Shared layer (.graph-hooks)"
echo "------------------------------"
HOOK=".graph-hooks/hook.sh"
if [ -f "$HOOK" ]; then [ -x "$HOOK" ] && ok "dispatcher present and executable: $HOOK" || warn "$HOOK present but not executable (chmod +x)"; else bad "dispatcher missing: $HOOK"; fi
for f in core/grep-steer.sh core/read-nudge.sh core/session-context.sh core/graph-refresh.sh core/extract.py core/emit.py; do
  if [ -f ".graph-hooks/$f" ]; then [ -x ".graph-hooks/$f" ] && ok "$f present and executable" || warn "$f present but not executable"; else bad "$f missing"; fi
done
for f in pretool-shell.sh pretool-read.sh sessionstart.sh endturn.sh; do
  [ -f ".graph-hooks/copilot/$f" ] && ok "copilot/$f present" || warn "copilot/$f missing (copilot hooks would no-op)"
done

# git hook + gitignore
GH=""
[ -f .husky/post-commit ] && GH=.husky/post-commit
[ -z "$GH" ] && [ -f .git/hooks/post-commit ] && GH=.git/hooks/post-commit
if [ -n "$GH" ]; then grep -q 'graph-hooks-managed' "$GH" 2> /dev/null && ok "post-commit installed: $GH" || warn "post-commit exists but no managed marker: $GH"; else warn "no post-commit hook — commit-time refresh won't run"; fi
for e in ".code-review-graph/" "graphify-out/"; do grep -qxF "$e" .gitignore 2> /dev/null && ok ".gitignore excludes $e" || warn ".gitignore missing $e"; done

echo
echo "2. Wired tools + config validity"
echo "--------------------------------"
WIRED=""
add_wired() { WIRED="${WIRED:+$WIRED }$1"; }
# claude
CSET=""
[ -f .claude/settings.local.json ] && CSET=.claude/settings.local.json
[ -z "$CSET" ] && [ -f .claude/settings.example.json ] && CSET=.claude/settings.example.json
if [ -n "$CSET" ] && grep -q '\-\-tool claude' "$CSET" 2> /dev/null; then
  is_json "$(cat "$CSET")" && {
    ok "claude wired + valid JSON: $CSET"
    add_wired claude
  } || bad "claude config invalid JSON: $CSET"
fi
# gemini
if [ -f .gemini/settings.json ] && grep -q '\-\-tool gemini' .gemini/settings.json 2> /dev/null; then
  is_json "$(cat .gemini/settings.json)" && {
    ok "gemini wired + valid JSON: .gemini/settings.json"
    add_wired gemini
  } || bad "gemini config invalid JSON"
fi
# copilot
if [ -f .github/hooks/graph.json ]; then
  is_json "$(cat .github/hooks/graph.json)" && {
    ok "copilot wired + valid JSON: .github/hooks/graph.json"
    add_wired copilot
  } || bad "copilot config invalid JSON"
fi
# antigravity (inert by design)
[ -f .agents/hooks.json ] && warn "ACTIVE .agents/hooks.json present — contract is UNVERIFIED; confirm before trusting"
[ -f .agents/hooks.json.example ] && ok "antigravity example present and inert (not activated) — expected"
[ -z "$WIRED" ] && bad "no tool hooks wired (expected at least one of claude/gemini/copilot)"

echo
echo "3. Dispatcher fires per tool"
echo "----------------------------"
payload() { # $1=tool $2=kind
  case "$1:$2" in
    copilot:pretool-shell) printf '{"toolArgs":{"command":"grep -rn something src/app.ts"}}' ;;
    copilot:pretool-read) printf '{"toolArgs":{"file_path":"src/app.ts"}}' ;;
    *:pretool-shell) printf '{"tool_input":{"command":"grep -rn something src/app.ts"}}' ;;
    *:pretool-read) printf '{"tool_input":{"file_path":"src/app.ts"}}' ;;
    *) printf '{}' ;;
  esac
}
for t in $WIRED; do
  for k in pretool-shell pretool-read sessionstart; do
    out=$(payload "$t" "$k" | bash "$HOOK" --tool "$t" --kind "$k" 2> /dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      bad "$t/$k exited $rc"
    elif [ -z "$out" ]; then
      ok "$t/$k ran cleanly (no output — correct with no graph / no match)"
    elif is_json "$out"; then
      if printf '%s' "$out" | grep -q '"permissionDecision":"\(deny\|block\)"\|"decision":"deny"'; then
        ok "$t/$k emitted a valid BLOCK decision (graph hit)"
      else ok "$t/$k emitted valid context JSON"; fi
    else bad "$t/$k emitted INVALID JSON: $(printf '%s' "$out" | head -c 60)"; fi
  done
done

echo
echo "4. Single refresh owner (no duplicate builds)"
echo "---------------------------------------------"
OWNERS=""
grep -q '\-\-kind endturn' "${CSET:-/dev/null}" 2> /dev/null && OWNERS="${OWNERS:+$OWNERS }claude"
grep -q '\-\-kind endturn' .gemini/settings.json 2> /dev/null && OWNERS="${OWNERS:+$OWNERS }gemini"
grep -q 'endturn.sh' .github/hooks/graph.json 2> /dev/null && OWNERS="${OWNERS:+$OWNERS }copilot"
N=$(printf '%s\n' $OWNERS | grep -c . || true)
if [ "${N:-0}" -le 1 ]; then ok "exactly ${N:-0} end-of-turn refresh owner${OWNERS:+ ($OWNERS)} — no duplication"; else bad "MULTIPLE refresh owners ($OWNERS) — would duplicate the graph build"; fi

# lock smoke test: a held lock makes a second refresh a no-op
KEY="$(pwd | { md5sum 2> /dev/null || md5 2> /dev/null; } | cut -c1-8)"
LK="${TMPDIR:-/tmp}/crg-graph-${KEY:-x}.lock"
if mkdir "$LK" 2> /dev/null; then
  out=$(bash .graph-hooks/core/graph-refresh.sh 2> /dev/null)
  rc=$?
  rmdir "$LK" 2> /dev/null || true
  [ "$rc" = 0 ] && [ -z "$out" ] && ok "graph-refresh no-ops while the repo-global lock is held" || warn "graph-refresh unexpected under held lock (rc=$rc)"
else
  warn "could not take lock dir to test refresh dedup"
fi

echo
echo "5. Tools and graph state"
echo "------------------------"
if command -v code-review-graph > /dev/null 2>&1; then
  ok "code-review-graph installed"
  if [ -f .code-review-graph/graph.db ]; then
    ok "CRG graph built"
    check_embeddings
  else
    warn "CRG graph not built — run: code-review-graph install && code-review-graph build"
  fi
else
  warn "code-review-graph not installed (hooks stay silent until it is)"
fi
if command -v graphify > /dev/null 2>&1; then
  ok "graphify installed"
  [ -f graphify-out/graph.json ] && ok "graphify graph built" || warn "graphify graph not built — run: graphify update ."
else
  warn "graphify not installed (optional)"
fi

echo
echo "Summary: $P passed, $W warnings, $F failed"
[ "$F" -gt 0 ] && exit 1 || exit 0
