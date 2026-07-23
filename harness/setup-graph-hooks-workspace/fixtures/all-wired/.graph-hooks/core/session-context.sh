#!/usr/bin/env bash
# session-context.sh — tool-neutral session-start context core. No stdin.
# stdout: neutral hook JSON combining (a) the graph query cheatsheet + live node/edge
# counts and (b) an optional systemMessage nudging first-time graph setup. Prints nothing
# when no graph is built and no graph CLI is installed. Consolidates the original
# graph-cheatsheet.py + session-status.sh + session-setup-nudge.sh into one core.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCOPE="$(bash "$HERE/cross-repo-scope.sh" 2> /dev/null || true)"
# Active read-path search tier (keyword | local <model> | custom <label>) so the session banner
# tells the agent which tier its semantic searches will land in, and whether to pin a provider.
TIER="$(bash "$HERE/embed-provider.sh" --tier 2> /dev/null | head -1)"

SCOPE="$SCOPE" TIER="$TIER" python3 - << 'PY'
import json, os, shutil, sqlite3, subprocess

crg = os.path.exists(".code-review-graph/graph.db")
gfy = os.path.exists("graphify-out/graph.json")
# In-scope sibling repos this repo may read (empty unless register-cross-repo-graph has run).
siblings = [ln.split("\t")[0] for ln in os.environ.get("SCOPE", "").splitlines() if "\t" in ln]
out = {}

stats, lines = [], []
if crg or gfy or siblings:
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
        # Search-tier banner: prefer vector (custom > local); keyword is the floor. State which
        # tier a search used, and pin the provider when custom vectors exist or the tool silently
        # drops to keyword. embed-provider.sh --tier: "keyword" | "local <model>" | "custom <label>".
        tkind, _, tlabel = os.environ.get("TIER", "keyword").strip().partition(" ")
        if tkind == "custom":
            stats.append(f"search tier: vector/custom ({tlabel or 'external'})")
            lines.append(
                "semantic search     -> PIN vectors: semantic_search_nodes_tool(query=X, "
                'provider="openai", model="...")  [tier custom, else drops to keyword]'
            )
        elif tkind == "local":
            stats.append("search tier: vector/local")
            lines.append("semantic search     -> semantic_search_nodes_tool(query=X)  [tier local, read by default]")
        else:
            stats.append("search tier: keyword")
            lines.append(
                "semantic search     -> semantic_search_nodes_tool(query=X)  [tier KEYWORD/name match; "
                "./setup-embeddings.sh enables vectors]"
            )
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
    if siblings:
        # These repos are read-only here and their graphs answer for them — so a cross-repo path is
        # a REASON to use the graph, not to skip it. Saying otherwise (as this cheatsheet once did)
        # contradicts the <!-- cross-repo --> block and sends the agent back to grep.
        lines += [
            "symbol in a sibling  -> cross_repo_search_tool(query=X), then keep only in-scope hits",
            "in-scope siblings    -> " + ", ".join(siblings),
        ]
        stats.append(f"{len(siblings)} in-scope sibling repo(s)")
    out["context"] = (
        "GRAPH QUERY CHEATSHEET (" + "; ".join(stats) + ") - use BEFORE reading/grepping code:\n"
        + "\n".join("  " + line for line in lines)
        + "\nSkip the graph for: .md .json .yml .log .jsonl and config text."
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
