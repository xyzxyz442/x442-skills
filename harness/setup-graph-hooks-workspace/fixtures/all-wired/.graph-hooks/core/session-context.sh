#!/usr/bin/env bash
# session-context.sh — tool-neutral session-start context core. No stdin.
# stdout: neutral hook JSON combining (a) the graph query cheatsheet + live node/edge
# counts and (b) an optional systemMessage nudging first-time graph setup. Prints nothing
# when no graph is built and no graph CLI is installed. Consolidates the original
# graph-cheatsheet.py + session-status.sh + session-setup-nudge.sh into one core.
set -uo pipefail

python3 - << 'PY'
import json, os, shutil, sqlite3, subprocess

crg = os.path.exists(".code-review-graph/graph.db")
gfy = os.path.exists("graphify-out/graph.json")
out = {}

stats, lines = [], []
if crg or gfy:
    if crg:
        try:
            c = sqlite3.connect("file:.code-review-graph/graph.db?mode=ro", uri=True)
            n = c.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
            e = c.execute("SELECT COUNT(*) FROM edges").fetchone()[0]
            c.close()
            stats.append(f"CRG {n} nodes, {e} edges")
        except Exception:
            pass
        lines += [
            "where is X defined   -> semantic_search_nodes_tool(query=X)",
            "who calls X          -> query_graph_tool(pattern=callers_of, target=X)",
            "pre-refactor blast   -> get_impact_radius_tool(changed_files=[...])",
            "community / cluster  -> list_communities_tool()",
            "code review context  -> get_review_context_tool(changed_files=[...])",
        ]
    if gfy:
        try:
            g = json.load(open("graphify-out/graph.json"))
            nodes = g.get("nodes", [])
            comms = len({x.get("community", "") for x in nodes if x.get("community", "")})
            stats.append(f"graphify {len(nodes)} nodes, {comms} communities")
        except Exception:
            pass
        lines += [
            "CRG miss / explore   -> graphify query '<term>' --graph graphify-out/graph.json",
            "path A->B            -> graphify path '<from>' '<to>' --graph graphify-out/graph.json",
        ]
    out["context"] = (
        "GRAPH QUERY CHEATSHEET (" + "; ".join(stats) + ") - use BEFORE reading/grepping code:\n"
        + "\n".join("  " + line for line in lines)
        + "\nSkip the graph for: .md .json .yml .log .jsonl configs and cross-repo paths."
        + "\nOverride the grep gate: append --graph-tried to any shell command."
    )

# Setup nudge: CRG CLI installed but no graph built yet in this repo.
inside_git = subprocess.run(
    ["git", "rev-parse", "--is-inside-work-tree"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
).returncode == 0
if shutil.which("code-review-graph") and inside_git and not os.path.isdir(".code-review-graph"):
    out["systemMessage"] = (
        "Graph tool installed but not yet initialized. Ask me to set up: "
        "code-review-graph (code-review-graph install)"
    )

if out:
    print(json.dumps(out))
PY
exit 0
