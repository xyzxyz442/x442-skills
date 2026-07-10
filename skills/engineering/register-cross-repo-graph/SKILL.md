---
name: x442-register-cross-repo-graph
description: >-
  (Experimental) Use when a project needs read-only access to another repo's code graph — e.g. a
  frontend session resolving a backend symbol, or any "reference another project's source" /
  cross-repo / monorepo-sibling lookup — so agents query the cross-repo graph instead of grepping
  across folders and burning tokens. Registers the foreign repo (code-review-graph) and/or merges
  it (graphify), then records it in AGENTS.md so agents actually reach for it. Chains after
  setup-graph-hooks.
---

# register-cross-repo-graph

> **Status: experimental.** This skill writes machine-local, per-user registry state
> (`~/.code-review-graph/`, `~/.graphify/`) and edits the consuming repo's `AGENTS.md`. Review what
> it registers before relying on it.

Give one project **read-only** access to another project's knowledge graph, and — the part that
actually saves tokens — tell the agents in context that the foreign graph exists so they query it
instead of grepping across the folder boundary.

By design each repo owns and refreshes its **own** graph (see
[`setup-graph-hooks`](../setup-graph-hooks/SKILL.md)): code-review-graph (CRG) writes
`<repo>/.code-review-graph/graph.db`, graphify writes `<repo>/graphify-out/graph.json`. Nothing is
shared across folders until you register it. This skill wires that link the read-only way: the
consumer only reads the foreign artifact; the foreign repo stays single-writer via its own hooks.

## When to use

- A session in repo A needs a symbol, type, or call site that lives in repo B (frontend↔backend,
  shared library, monorepo sibling, a vendored service).
- You keep grepping/reading across into another checkout and want the graph to answer instead.
- You want a durable, in-context pointer so _every_ future session in this repo knows the sibling
  graph is queryable.

## Preconditions

1. The **consuming** repo has `AGENTS.md` at its root (for the context block) and its own graph
   wired (run `setup-graph-hooks` first).
2. At least one of `code-review-graph` / `graphify` is installed.
3. You can name the **foreign** repo — a local path, or a GitHub URL to clone.

## Prerequisites & platform support

`code-review-graph` and/or `graphify` on `PATH`; `git`; `bash`/`python3`. Registration state is
**machine-local and per-user** — it lives under `~/`, is global to your account, and is **not**
committed. macOS/Linux first-class; Windows via WSL. Freshness assumes both repos are checkouts on
the **same machine** (see caveats).

## Procedure

`$CONSUMER` is the repo you are working in; `$FOREIGN` is the absolute path to the other repo.

### 1. Resolve the foreign repo

A local absolute path, or clone a remote one:

```bash
graphify clone <github-url>            # clones locally, prints the path → use as $FOREIGN
```

### 2. CRG path — register for read-only cross-repo search

CRG's `register` only writes the registry; it does **not** build. And `cross_repo_search_tool`
**silently skips** any registered repo whose `graph.db` is absent — so the foreign graph must exist
first. A `build` is enough: embeddings are the foreign repo's own opt-in choice, and cross-repo
search works without them.

```bash
# a) Build-if-needed: only if $FOREIGN/.code-review-graph/graph.db is missing (offer, don't force)
code-review-graph build --repo "$FOREIGN"

# b) Register (machine-local ~/.code-review-graph/registry.json), then confirm
code-review-graph register "$FOREIGN" --alias <short-alias>
code-review-graph repos                 # or the list_repos_tool MCP tool
```

**Optional freshness.** The registry is not the watch set — registering does not auto-refresh.
Offer to add the foreign repo to the watch daemon so its graph stays current, or document a manual
`update`:

```bash
code-review-graph daemon add "$FOREIGN" # auto-refresh via ~/.code-review-graph/watch.toml
```

Query it from either session with `cross_repo_search_tool(query="…")` and `list_repos_tool` — the
only two registry-aware MCP tools. (Single-repo tools like `get_impact_radius` do **not** span
repos.)

### 3. graphify path — merge into the global graph

graphify's cross-repo model is a merged graph at `~/.graphify/global-graph.json`. Add the foreign
repo's **already-built** `graphify-out/graph.json` into it under a tag (AST-only, no LLM cost), then
query the merged graph — note `global path` just _prints the global-graph file location_, so feed
it to `--graph`:

```bash
# merge the foreign repo's graph into the global graph under a tag
graphify global add "$FOREIGN/graphify-out/graph.json" --as <tag>
graphify global list                        # confirm the tag is present

# query across the merged graph
GLOBAL="$(graphify global path)"            # prints ~/.graphify/global-graph.json
graphify query "<term>"    --graph "$GLOBAL"
graphify path  "<A>" "<B>" --graph "$GLOBAL"
```

Ad-hoc alternative without merging — point any read command straight at the foreign artifact:

```bash
graphify query "<term>" --graph "$FOREIGN/graphify-out/graph.json"
```

The foreign repo must have a built `graphify-out/graph.json`; if it is missing, run
`graphify update .` inside that repo (AST-only, no API cost). Do **not** reach for `graphify extract`
to produce it here unless you intend a full semantic re-extraction — `extract` makes LLM API calls.
CRG's `graph.db` and graphify's `graph.json` are independent — building one does not satisfy the
other.

### 4. Define it in context (the token-saving core)

Inject an idempotent managed block into `$CONSUMER/AGENTS.md`, sibling to the existing
`<!-- graph-hooks -->` block, listing the registered foreign repos and the routing rule. This is
what makes agents reach for the cross-repo graph instead of grepping. Only write it if the marker
is absent; update the repo list in place otherwise.

```markdown
<!-- cross-repo:begin (managed by register-cross-repo-graph — do not edit between markers) -->

## Cross-repo graph access (read-only)

This project can query these sibling repos' graphs instead of grepping across folders:

| Alias   | Path       | Query with                                                                                     |
| ------- | ---------- | ---------------------------------------------------------------------------------------------- |
| <alias> | <abs-path> | `cross_repo_search_tool(query=…)` (CRG) · `graphify query … --graph "$(graphify global path)"` |

Before grepping/reading into another repo's tree, use `cross_repo_search_tool(query=…)` /
`list_repos_tool` (CRG), or the graphify merged global graph —
`graphify query/path … --graph "$(graphify global path)"` (or `--graph <foreign>/graphify-out/graph.json`
for an unmerged repo). These read the foreign graph read-only and cost a fraction of a cross-tree
grep.

<!-- cross-repo:end -->
```

### 5. Verify

- `code-review-graph repos` lists the entry and `$FOREIGN/.code-review-graph/graph.db` exists.
- A `cross_repo_search_tool` smoke query returns hits tagged with the foreign repo.
- `graphify global list` shows the merged tag (if the graphify path was used).
- The `<!-- cross-repo -->` block is present in `AGENTS.md` and the `<!-- graph-hooks -->` block is
  untouched.

### 6. Report

List the registered repos, the freshness mode (manual vs daemon), and the un-register path:

```bash
code-review-graph unregister <path-or-alias>
graphify global remove <tag>        # by the tag used in `global add`, not a path
```

## Caveats

- **Machine-local & per-user.** Registration lives under `~/` and is global to your account, not
  committed — each teammate/machine must run it. The committed `AGENTS.md` block documents _intent_;
  the actual registry is local.
- **Freshness is a same-machine assumption.** You read whatever state the foreign `graph.db` /
  `graph.json` is in. Keep it current (manual `update` or the watch daemon); a foreign repo on a
  different machine or CI won't be reachable.
- **Read-only covers search/lookup only.** `cross_repo_search_tool` spans repos; blast-radius tools
  (`get_impact_radius`, `get_affected_flows`) stay single-repo — tracing a change _into_ another
  repo needs one merged graph, not two read separately.
- **Read-mostly, not zero-write.** CRG opens the foreign DB in SQLite WAL mode, which may create
  `-wal`/`-shm` side files next to it; it never mutates graph content.

## Notes

- **Two independent CRG configs**, both under `~/.code-review-graph/`: `registry.json` (the
  query/search set, edited by `register`/`unregister`) and `watch.toml` (the auto-refresh set,
  edited by `daemon add`/`remove`). Adding to one does not affect the other.
- **CRG vs graphify are separate systems.** Register for CRG's MCP `cross_repo_search`; merge for
  graphify's global graph. Use whichever the consuming repo already relies on — or both.
- Pairs with [`repair-graph-hooks`](../repair-graph-hooks/SKILL.md) if a registered repo's graph
  goes stale or its tool install breaks.
