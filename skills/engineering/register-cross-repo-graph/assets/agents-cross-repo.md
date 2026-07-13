<!-- cross-repo:begin (managed by register-cross-repo-graph — do not edit between markers) -->

## Cross-repo graph access (read-only)

Before you grep, find, or read into another checkout, query that repo's graph instead. These
sibling repos are in scope for `{{SCOPE}}`:

{{REPO_TABLE}}

**In-scope aliases: {{IN_SCOPE_ALIASES}}.**

`cross_repo_search_tool` searches a machine-global registry shared with your other projects, so it
**will** return hits from repos that are not listed above. Ignore them. Use only hits whose alias is
in the in-scope set, and never open a file outside the repo paths in that table. If you believe you
need a repo that is not listed, say so — the fix is a new entry in `.graph-repos.json`, not a wider
search.

| Need | Use |
| ------------------------------- | -------------------------------------------------------------- | ---------------------------------------------------- |
| find a symbol in a sibling repo | `cross_repo_search_tool(query=…)` — keep only in-scope aliases |
| which repos are registered | `list_repos_tool()` — a superset; filter to the in-scope set |
| {{GRAPHIFY_ROWS}} | blast radius / review context | single-repo only — these tools do **not** span repos |
| string / config / log text | `grep` (append `--graph-tried` to bypass the graph gate) |

Each repo refreshes its **own** graph via its own hooks; here they are read-only. If a sibling graph
looks stale, refresh it in that repo — do not rebuild it from this session without asking.

Scope comes from the `.graph-repos.json` cascade (user → repo root → subdirectory, nearest wins).
After editing one, re-run `sync-cross-repo-graph.sh` so this block, the registry, and the merged
graph agree.

<!-- cross-repo:end -->
