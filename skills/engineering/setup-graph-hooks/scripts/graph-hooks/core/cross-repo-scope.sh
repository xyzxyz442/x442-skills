#!/usr/bin/env bash
# cross-repo-scope.sh — resolve the in-scope sibling repos this repo may READ.
# No stdin. stdout: one "alias<TAB>abs-path" line per sibling whose graph can actually answer.
# Prints nothing (exit 0) when this repo has no cross-repo scope — the same "silence means the
# feature is off" contract embed-provider.sh uses, so callers need no feature flag.
#
# Source of truth is the ledger register-cross-repo-graph writes:
#   <repo-root>/.code-review-graph/cross-repo-state.json
# It is machine-readable and already absolute-path'd, so a hook never has to re-resolve the
# .graph-repos.json cascade (python + stat per grep — far too slow for a pre-tool hook).
#
# Two rules this must not get wrong:
#   - The ledger ACCUMULATES. An alias that left the scope stays in crg_registered until --prune,
#     so filter by in_scope_aliases — otherwise a hook would read a repo the AGENTS.md fence has
#     already dropped, silently widening the scope the user thinks they narrowed.
#   - Skip a sibling with no graph.db. It cannot answer, and sync deliberately leaves it out of the
#     AGENTS.md block for exactly that reason; advertising it here would contradict the block.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2> /dev/null)" || exit 0
LEDGER="$ROOT/.code-review-graph/cross-repo-state.json"
[ -f "$LEDGER" ] || exit 0

python3 - "$LEDGER" << 'PY' 2> /dev/null || true
import json, os, sys

try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)

in_scope = set(d.get("in_scope_aliases") or [])
for repo in d.get("crg_registered") or []:
    alias, path = repo.get("alias"), repo.get("path")
    if not alias or not path or alias not in in_scope:
        continue
    if not os.path.exists(os.path.join(path, ".code-review-graph", "graph.db")):
        continue
    print(f"{alias}\t{path}")
PY
exit 0
