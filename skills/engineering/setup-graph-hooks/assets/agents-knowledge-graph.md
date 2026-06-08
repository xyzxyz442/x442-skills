<!-- graph-hooks:begin (managed by setup-graph-hooks — do not edit between markers) -->
## Knowledge Graph (code navigation)

This repo has a self-updating code knowledge graph. **Before** you grep, find, glob, or read
multiple source files to answer a code question, query the graph — it is far cheaper and more
precise. Reach for it when you:

- answer architecture, cross-module, or "how does X work" questions
- are about to grep / find / glob the codebase
- need to trace a call chain or get oriented in an unfamiliar module
- are about to refactor something with unclear blast radius

Routing (CRG first, graphify on miss, grep last):

| Need | Use |
| --- | --- |
| where is X defined | `semantic_search_nodes_tool(query=X)` |
| who calls / imports X | `query_graph_tool(pattern=callers_of\|importers, target=X)` |
| pre-refactor blast radius | `get_impact_radius_tool(changed_files=[...])` |
| code review / PR impact | `get_review_context_tool(changed_files=[...])` |
| architecture overview | `list_communities_tool()` — never `get_architecture_overview_tool` |
| CRG miss / neighborhood explore | `graphify query '<term>' --graph graphify-out/graph.json` |
| shortest path A→B | `graphify path '<A>' '<B>' --graph graphify-out/graph.json` |
| string / config / log text | `grep` (append `--graph-tried` to bypass the graph gate) |

If no graph exists yet, ask to run: `code-review-graph build && code-review-graph embed`.
The graph refreshes automatically (the primary tool's end-of-turn hook + a git post-commit
refresh that runs regardless of tool); you do not need to rebuild it manually after edits.
<!-- graph-hooks:end -->
