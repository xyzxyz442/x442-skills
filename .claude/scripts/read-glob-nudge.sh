#!/usr/bin/env bash
# read-glob-nudge.sh — PreToolUse (Read|Glob) hook: when the agent is about to Read/Glob a SOURCE
# file and a graph exists, nudge it to prefer the graph's MCP tools. No-op for non-code targets or
# when no graph is built. Emits valid JSON context (or nothing). Logic lives here so the hook
# COMMAND string stays a stable thin wrapper that Claude Code can de-dupe across installs.
set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
HIT=$(printf '%s' "$INPUT" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin); t=d.get('tool_input',d)
    s=(str(t.get('file_path') or '')+' '+str(t.get('pattern') or '')+' '+str(t.get('path') or '')).lower().replace(chr(92),'/')
    exts=('.py','.js','.ts','.tsx','.jsx','.go','.rs','.java','.rb','.c','.h','.cpp','.hpp','.cc','.cs','.kt','.swift','.php','.scala','.lua','.sh')
    sys.stdout.write('1' if 'graphify-out/' not in s and '.code-review-graph/' not in s and any(e in s for e in exts) else '')
except Exception:
    pass" 2>/dev/null || true)

[ "$HIT" = 1 ] || exit 0

HINT=""
[ -f .code-review-graph/graph.db ] && HINT="semantic_search_nodes_tool / query_graph_tool / get_impact_radius_tool"
[ -f graphify-out/graph.json ] && HINT="${HINT:+$HINT or }graphify query/explain/path --graph graphify-out/graph.json"
[ -n "$HINT" ] && printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"For codebase questions prefer %s over reading source files one by one. Read raw files to modify or debug specific code."}}' "$HINT"
exit 0
