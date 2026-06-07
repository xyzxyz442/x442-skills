#!/usr/bin/env python3
# graph-cheatsheet.py — SessionStart context injection for Claude Code.
# Emits a ~150-token "use the graph before grepping" cheatsheet as VALID JSON
# (json.dumps handles all escaping — unlike the old inline printf, which leaked
# literal newlines into the JSON string). Prints nothing when no graph exists.
import json, os, sqlite3

stats, lines = [], []
crg = os.path.exists(".code-review-graph/graph.db")
gfy = os.path.exists("graphify-out/graph.json")
if not (crg or gfy):
    raise SystemExit(0)

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

ctx = (
    "GRAPH QUERY CHEATSHEET (" + "; ".join(stats) + ") - use BEFORE Read/Grep/Bash-find on code:\n"
    + "\n".join("  " + line for line in lines)
    + "\nSkip the graph for: .md .json .yml .log .jsonl configs and cross-repo paths."
    + "\nOverride the grep gate: append --graph-tried to any Bash command."
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": ctx,
    }
}))
