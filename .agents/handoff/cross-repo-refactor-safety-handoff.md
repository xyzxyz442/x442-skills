---
id: cross-repo-refactor-safety-handoff
title: Handoff — cross-repo graph hooks — freshness gate + caller-edge answers
type: standalone
status: open
created: 2026-07-20
updated: 2026-07-20
note:
---

# Handoff — cross-repo graph hooks — freshness gate + caller-edge answers

**Status:** evaluated, not implemented. Two changes are designed and justified below; neither is
written yet. Everything referenced here is already committed and green.

**Branch:** `feature/skill-eval-harness` (shared with the eval-harness work).
**Last commit at handoff:** `2495036 refactor(setup): unify the verify-script contract across the four skills`

---

## 1. Where we are

The cross-repo read path was previously unprotected: a grep into a registered sibling repo was
waved through, because `grep-steer.sh` only ever queried the **local** graph and read a cross-repo
miss as "the graph cannot help". That is now fixed and shipped:

| Commit    | What                                                                                                                                                                                                                                                                           |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `073f545` | `fix(setup)` — new `core/cross-repo-scope.sh`; `grep-steer` searches in-scope siblings and denies a repeat grep aimed into one; `session-context` no longer tells agents to skip the graph for cross-repo paths; `read-nudge` names `cross_repo_search_tool` for sibling paths |
| `b710917` | `test(setup)` — `verify-cross-repo-graph.sh` now asserts a cross-repo grep is answered from the sibling's graph (fails on the old hooks, passes on the new)                                                                                                                    |
| `83b0595` | `docs(docs)` — the grep-steer ladder, routing ladder, "How it fits together", and the cross-repo sequence diagram                                                                                                                                                              |
| `6fe6fb8` | `refactor(setup)` — `resolve.py` emits only fields a consumer reads; verifier consumes `gfy_mtime` instead of re-stat'ing                                                                                                                                                      |
| `2495036` | `refactor(setup)` — one `is_json`/`is_json_str` split, one exit idiom, fatal errors to stderr across the four verifiers                                                                                                                                                        |

All four verifiers report **0 failed**; the eval harness's wired fixtures grade **1.0**, including
the behavioral `graph-search-behavior` one.

## 2. What the evaluation found (why more work is needed)

A two-repo refactor simulation — rename `compute_invoice_total` in a library that an API depends on
— showed the hooks are **correct for a single lookup and unsafe for a multi-step refactor**. Three
findings, in severity order.

### F1 (worst) — a stale sibling graph makes the hook assert a falsehood, and block the check

The consuming repo's `post-commit` refreshes **only its own** graph. A sibling repo refreshes itself
_only if someone ran `setup-graph-hooks` in it_ — which nothing enforces. After the rename landed in
the library (no hooks there), the API session saw this:

| Agent action, post-rename               | Hook verdict                                                                                                           |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| greps the **new** name (exists on disk) | allowed silently — no graph help                                                                                       |
| greps the **old** name (deleted)        | **BLOCKED**: "the knowledge graph already has this — no grep/retry needed", pointing at a symbol that no longer exists |

It blocks the grep that would reveal the truth and abstains on the one that matters.
`verify-cross-repo-graph.sh` does `[warn] acme-lib graph may be stale (its HEAD is newer than
graph.db)` — but still reports `0 failed`, so the wiring looks healthy while the hook misleads.

**A stale graph must inform, never block.**

### F2 — the pre-answer is a name match, but the deny claims the question is settled

The blocked grep would have found **3** hits in the sibling (the definition plus two lines in an
in-library caller, `billing.py`). The graph returned **1** — the definition node — under the message
_"no grep/retry needed"_. For a rename that is false.

The sibling's graph **does** hold the caller (`CALLS: billing.py::monthly_statement ->
compute_invoice_total`), but nothing exposes it across the boundary: `cross_repo_search_tool` is
name-based, and `query_graph_tool(pattern=callers_of)` is single-repo. An agent that trusts the deny
can rename the definition and miss the caller.

### F3 (documented caveat, now measured) — no cross-repo blast radius, even via the merged graph

The merged graphify graph is a **disjoint union**: 4 nodes from the API, 9 from the library, and
**0 edges between them**. So `graphify path` cannot cross the boundary either. This is consistent
with the skill's stated caveat ("blast-radius tools stay single-repo") — no fix proposed, but the
docs should not imply the merged graph closes it.

## 3. The two changes to implement

### C1 — freshness gate (fixes F1)

Do not deny on an answer from a sibling whose graph is older than that sibling's HEAD. Advise
instead, and say the graph is stale.

- **Emit staleness from the scope core.**
  [`core/cross-repo-scope.sh:39`](../../skills/engineering/setup-graph-hooks/scripts/graph-hooks/core/cross-repo-scope.sh)
  currently prints `alias<TAB>path`. Add a third field: `alias<TAB>path<TAB>stale` (`1`/`0`).
  **Note:** the ledger (`.code-review-graph/cross-repo-state.json`) carries only `alias` + `path` —
  **no mtimes** — so staleness must be computed here. `resolve.py` computes `head_ct`/`db_mtime`
  ([resolve.py:182-184](../../skills/engineering/register-cross-repo-graph/scripts/manifest/resolve.py))
  but the hook must not shell out to it: this runs before **every** grep, and `resolve.py` stats the
  whole cascade. Cheapest correct check: compare `mtime(<sib>/.code-review-graph/graph.db)` against
  `mtime(<sib>/.git/HEAD)` — no subprocess. (`git -C <sib> log -1 --format=%ct` is more precise but
  forks per sibling on every grep; prefer it only if the mtime proxy proves flaky.)
- **Gate the deny.**
  [`grep-steer.sh:166-167`](../../skills/engineering/setup-graph-hooks/scripts/graph-hooks/core/grep-steer.sh)
  sets `DENYABLE="$RESULT_SIB"` when the command aims into a sibling. Only do that when that sibling
  is **fresh**. When stale: fall through to the advise branch and prefix the hits with a warning that
  the sibling's graph predates its latest commit, naming the refresh (`code-review-graph update` in
  that repo).
- **Same gate for `read-nudge.sh`** — do not steer a read toward a stale sibling graph without
  saying so.

### C2 — answer with usages, not just the definition (fixes F2)

`query_crg()` ([grep-steer.sh:67-91](../../skills/engineering/setup-graph-hooks/scripts/graph-hooks/core/grep-steer.sh))
searches `nodes` / `nodes_fts` only. Add a second query over `edges` so a pre-answer that **replaces
a grep** is as complete as the grep it replaced.

Schema (verified against a real `graph.db` — do **not** guess, there is no `source_id`/`target_id`):

```
nodes:  id kind name qualified_name file_path line_start line_end language parent_name ...
edges:  id kind source_qualified target_qualified file_path line extra confidence ...
        kind ∈ {CALLS, IMPORTS_FROM, CONTAINS, ...}
```

Callers of `X` in a sibling:

```sql
SELECT kind, source_qualified, file_path, line
FROM edges
WHERE target_qualified = ?          -- the bare symbol name, e.g. 'compute_invoice_total'
  AND kind IN ('CALLS', 'IMPORTS_FROM')
LIMIT 10;
```

Then soften the deny copy at
[`grep-steer.sh:211`](../../skills/engineering/setup-graph-hooks/scripts/graph-hooks/core/grep-steer.sh):
_"no grep/retry needed"_ is only honest once the answer includes usages. If only a name match is
available, advise rather than deny.

### C3 (smaller, optional) — close the loop in the cross-repo skill

`register-cross-repo-graph` assumes "each sibling refreshes itself via its own hooks", which holds
only if `setup-graph-hooks` was run there. At sync time, either warn when a sibling has no
`.graph-hooks/`, or offer `code-review-graph daemon add <path>`. Also consider promoting the stale
sibling from `[warn]` to `[FAIL]` in `verify-cross-repo-graph.sh` **when the block advertises that
alias** — today a repo can be "0 failed" while its hooks hand out expired answers.

## 4. How to reproduce the evaluation

CRG's registry is **machine-global** (`~/.code-review-graph/registry.json`). Always redirect `HOME`
or you will pollute the real one.

```bash
LAB= < scratch > /refactor-lab
SK=skills/engineering
export HOME="$LAB/home" # isolate the machine-global registry

# acme-lib: money.py (compute_invoice_total, round_half_even, format_currency)
#           billing.py -> imports + calls compute_invoice_total   <-- the in-library caller
# acme-api: handlers/invoices.py + handlers/reports.py -> both call it   <-- 2 call sites
# git init + commit both, then:
bash "$SK/setup-graph-hooks/scripts/setup-graph-hooks.sh" "$LAB/acme-api" --tools claude --primary claude
(cd "$LAB/acme-lib" && code-review-graph build && graphify update .)
(cd "$LAB/acme-api" && code-review-graph build && graphify update .)
# .graph-repos.json in acme-api: { "alias": "acme-lib", "path": "../acme-lib", "tools": ["crg","graphify"] }
bash "$SK/register-cross-repo-graph/scripts/sync-cross-repo-graph.sh" "$LAB/acme-api"
```

Probe the hook exactly as the tool would (Claude Code shape):

```bash
cd "$LAB/acme-api"
printf '{"tool_name":"Bash","tool_input":{"command":"grep -rn \"compute_invoice_total\" ../acme-lib"}}' \
  | bash .graph-hooks/hook.sh --tool claude --kind pretool-shell
```

**Gotcha — the one-shot allowance.** The first search per repo per hour is _always_ allowed (the
teaching moment). To observe steady-state behavior you must burn the slot first:

```bash
KEY="$(printf '%s' "$PWD" | { md5sum || md5; } | cut -c1-8)"
touch "$HOME/.cache/graph-steer-hook/first-${KEY}-$(date +%Y%m%d%H)"
```

To reproduce **F1**, rename the symbol in `acme-lib`, commit there, do **not** rebuild its graph,
then grep from `acme-api` for both the old and the new name.

## 5. Acceptance criteria

These must hold when C1/C2 land:

1. **F1 closed** — with a stale sibling, a grep aimed into it is **never denied**; the response says
   the sibling's graph predates its HEAD and names the refresh command.
2. **F2 closed** — a cross-repo pre-answer for a symbol with callers lists the `CALLS`/`IMPORTS_FROM`
   sites, not just the definition.
3. **No regressions** (all previously verified):
   - local symbol + local grep → still denied from the local graph;
   - `--graph-tried` → still bypasses;
   - non-code target (`.md`) → still passes silently;
   - broad local grep that merely matches a sibling symbol → advise, **never** deny;
   - repo with **no** ledger (i.e. `setup-graph-hooks` alone) → byte-identical to today
     (`cross-repo-scope.sh` prints nothing; this is the "silence = feature off" contract).
4. `verify-graph-hooks.sh` (this repo) → `0 failed`; `verify-cross-repo-graph.sh` (lab) → `0 failed`.
5. Eval harness still green: wired fixtures grade `1.0`, incl. `graph-search-behavior`.
   (`fresh-wired` scoring `0/3` is **correct** — it is the unwired pre-state fixture.)
6. `npx prettier --check .` clean. **`prettier-plugin-sh` reformats shell**, and staging explicit
   paths bypasses lint-staged — run prettier before committing scripts.

## 6. Conventions

- Commit scopes come from a **closed** `scope-enum` in `commitlint.config.mjs`:
  `setup, config, deps, feature, bug, docs, style, refactor, test, build, ci, release, other`.
  `skills` and `register-cross-repo-graph` are **not** valid scopes. Precedent: `fix(setup)` for a
  shipped skill payload, `docs(docs)` for prose.
- The husky `commit-msg` hook only fires if `.husky/commit-msg` is executable. `.husky/` is
  **gitignored**, so the exec bit is per-machine — check it, or commitlint silently does not run.
- House rules: never `rm` (use `trash`); no emojis; imperative second person.
- Dogfood: `.graph-hooks/` is **tracked** in this repo. After changing a core, re-run
  `setup-graph-hooks.sh .` so the installed copy matches the skill source, and commit both.
