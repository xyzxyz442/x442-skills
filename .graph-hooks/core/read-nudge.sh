#!/usr/bin/env bash
# read-nudge.sh — tool-neutral "prefer the graph over reading source" decision core.
# stdin: a target string (file path / glob / dir, space-joined). stdout: neutral hook
# JSON {"context":"..."} when the target is a SOURCE file and a graph exists, else nothing.
# Ported from the original read-glob-nudge.sh; protocol wrapping is handled by emit.py.
set -uo pipefail

TARGET="$(cat 2>/dev/null || true)"
[ -z "$TARGET" ] && exit 0

HIT="$(printf '%s' "$TARGET" | python3 -c "import sys
s=sys.stdin.read().lower().replace(chr(92),'/')
exts=('.py','.js','.ts','.tsx','.jsx','.go','.rs','.java','.rb','.c','.h','.cpp','.hpp','.cc','.cs','.kt','.swift','.php','.scala','.lua','.sh')
sys.stdout.write('1' if 'graphify-out/' not in s and '.code-review-graph/' not in s and any(e in s for e in exts) else '')" 2>/dev/null || true)"
[ "$HIT" = 1 ] || exit 0

HINT=""
[ -f .code-review-graph/graph.db ] && HINT="semantic_search_nodes_tool / query_graph_tool / get_impact_radius_tool"
[ -f graphify-out/graph.json ] && HINT="${HINT:+$HINT or }graphify query/explain/path --graph graphify-out/graph.json"
[ -z "$HINT" ] && exit 0

python3 - "$HINT" <<'PY'
import json, sys
hint = sys.argv[1]
msg = ("For codebase questions prefer %s over reading source files one by one. "
       "Read raw files to modify or debug specific code." % hint)
print(json.dumps({"context": msg}))
PY
exit 0
