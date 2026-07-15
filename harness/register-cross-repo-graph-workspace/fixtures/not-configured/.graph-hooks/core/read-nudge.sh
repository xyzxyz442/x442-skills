#!/usr/bin/env bash
# read-nudge.sh — tool-neutral "prefer the graph over reading source" decision core.
# stdin: a target string (file path / glob / dir, space-joined). stdout: neutral hook
# JSON {"context":"..."} when the target is a SOURCE file and a graph exists, else nothing.
# Ported from the original read-glob-nudge.sh; protocol wrapping is handled by emit.py.
set -uo pipefail

TARGET="$(cat 2> /dev/null || true)"
[ -z "$TARGET" ] && exit 0

HIT="$(printf '%s' "$TARGET" | python3 -c "import sys
s=sys.stdin.read().lower().replace(chr(92),'/')
exts=('.py','.js','.ts','.tsx','.jsx','.go','.rs','.java','.rb','.c','.h','.cpp','.hpp','.cc','.cs','.kt','.swift','.php','.scala','.lua','.sh')
sys.stdout.write('1' if 'graphify-out/' not in s and '.code-review-graph/' not in s and any(e in s for e in exts) else '')" 2> /dev/null || true)"
[ "$HIT" = 1 ] || exit 0

# Reading INTO an in-scope sibling? Then the single-repo tools below cannot answer — name the one
# that can. Silence from cross-repo-scope.sh means this repo has no sibling scope. Scope lines are
# alias<TAB>path<TAB>stale; the match prints alias<TAB>stale so we can flag an out-of-date sibling.
HERE="$(cd "$(dirname "$0")" && pwd)"
SCOPE="$(bash "$HERE/cross-repo-scope.sh" 2> /dev/null || true)"
XREPO=""
XREPO_STALE=0
if [ -n "$SCOPE" ]; then
  MATCH="$(printf '%s' "$TARGET" | SCOPE="$SCOPE" python3 -c "import os,sys
scope=[l.split(chr(9)) for l in os.environ.get('SCOPE','').splitlines() if chr(9) in l]
for tok in sys.stdin.read().split():
    p=os.path.realpath(os.path.join(os.getcwd(), os.path.expanduser(tok)))
    for alias, path, *rest in scope:
        root=os.path.realpath(path)
        if p==root or p.startswith(root+os.sep):
            print(alias + chr(9) + (rest[0] if rest else '0')); sys.exit(0)" 2> /dev/null || true)"
  XREPO="$(printf '%s' "$MATCH" | cut -f1)"
  XREPO_STALE="$(printf '%s' "$MATCH" | cut -f2)"
  [ -z "$XREPO_STALE" ] && XREPO_STALE=0
fi

HINT=""
if [ -n "$XREPO" ]; then
  HINT="cross_repo_search_tool (the '$XREPO' repo's own graph — this repo's tools do not span it)"
  [ "$XREPO_STALE" = 1 ] && HINT="$HINT; NOTE: that graph predates its latest commit — refresh it in that repo (code-review-graph update) before trusting the result"
else
  [ -f .code-review-graph/graph.db ] && HINT="semantic_search_nodes_tool / query_graph_tool / get_impact_radius_tool"
  [ -f graphify-out/graph.json ] && HINT="${HINT:+$HINT or }graphify query/explain/path --graph graphify-out/graph.json"
fi
[ -z "$HINT" ] && exit 0

python3 - "$HINT" << 'PY'
import json, sys
hint = sys.argv[1]
msg = ("For codebase questions prefer %s over reading source files one by one. "
       "Read raw files to modify or debug specific code." % hint)
print(json.dumps({"context": msg}))
PY
exit 0
