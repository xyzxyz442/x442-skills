# AGENTS.md

Shared rules for AI assistants working in this project. Read this file first.

## Project overview

`demo-service` is a small TypeScript service.

## Coding guidelines

- Prefer small, well-named functions.
- Add tests for new behavior.
- No secrets in source; use environment variables.

<!-- graph-hooks:begin (managed by setup-graph-hooks — do not edit between markers) -->

## Knowledge Graph (code navigation)

This repo has a self-updating code knowledge graph. **Before** you grep, find, glob, or read
multiple source files to answer a code question, query the graph — it is far cheaper and more
precise. Reach for it when you:

- answer architecture, cross-module, or "how does X work" questions
- are about to grep / find / glob the codebase
- need to trace a call chain or get oriented in an unfamiliar module
- are about to refactor something with unclear blast radius

Route by **intent** — pick the lane for what you are trying to do, not for what just failed:

| Intent                                 | Lane                                                               |
| -------------------------------------- | ------------------------------------------------------------------ |
| find code by meaning ("what does X")   | `semantic_search_nodes_tool(query=X)` — see search modes below     |
| who calls / imports a known symbol     | `query_graph_tool(pattern=callers_of\|importers, target=X)`        |
| pre-refactor blast radius              | `get_impact_radius_tool(changed_files=[...])`                      |
| code review / PR impact                | `get_review_context_tool(changed_files=[...])`                     |
| architecture overview                  | `list_communities_tool()` — never `get_architecture_overview_tool` |
| explore / explain / onboard, code↔docs | `graphify query\|explain '<term>' --graph graphify-out/graph.json` |
| shortest path A→B                      | `graphify path '<A>' '<B>' --graph graphify-out/graph.json`        |
| exact string, config value, log text   | `grep` (append `--graph-tried` to bypass the graph gate)           |

These are lanes, **not a chain**. Graphify is not a CRG fallback — reach for it when the question
is exploratory, up front. And when a meaning-based search does not answer, the next stop is
`grep`, not graphify: what semantic search cannot find is usually what is not in the AST graph at
all — string literals, config values, comments, generated files, migrations. That is grep's
territory by construction.

### Search tiers — prefer vector, keyword is the floor

`semantic_search_nodes_tool` answers in one of three tiers. Prefer the richest one available, and
**state which tier a search used** when it backs an answer. Preference order is
**custom → local → keyword** (`./setup-embeddings.sh` sets it up in that order):

1. **custom** — vectors from an external / OpenAI-compatible provider (e.g. Ollama). Richest.
   These are read ONLY when pinned, or the tool silently drops to keyword:
   `semantic_search_nodes_tool(query=X, provider="openai", model="<model>")`.
2. **local** — vectors from CRG's built-in model. Read by default, no pin: `semantic_search_nodes_tool(query=X)`.
3. **keyword** — no vectors: name match over symbols. Still the right tool, not a failure; a
   shallow result is not a reason to grep.

Which tier is live is announced at session start (`search tier: …` in the cheatsheet) and marked
on every grep pre-answer (`[search tier: keyword]`, since the grep gate always name-matches). A
keyword-_tier_ result is a quality difference, not an availability one — do not reach for grep
because a result looked shallow.

### Search modes — say which one answered

Tier is what this repo _can_ do; **`search_mode` is what a given query actually did.**
`semantic_search_nodes_tool` returns it per call as `semantic`, `fts`, or `keyword`, and there is
no minimum-score threshold — the tool returns its top _k_ whether or not anything actually
matched. A weak result is therefore indistinguishable from a good one unless you look.

**State the `search_mode` when a search backs an answer.** Then read it:

- `search_mode` matches the live tier → the vectors answered; trust it as far as the results go.
- Live tier is vector but `search_mode` came back `fts` or `keyword` → the vectors did **not**
  answer this query (unpinned custom vectors, or a provider mismatch). Pin the model and retry,
  and if it still degrades, `grep` is legitimate — this is the one case where a disappointing
  search _is_ a reason to grep.
- Live tier is already `keyword` → nothing degraded; see the tier note above.

If no graph exists yet, ask to run: `code-review-graph build`.
The graph refreshes automatically (the primary tool's end-of-turn hook + a git post-commit
refresh that runs regardless of tool); you do not need to rebuild it manually after edits.

<!-- graph-hooks:end -->
