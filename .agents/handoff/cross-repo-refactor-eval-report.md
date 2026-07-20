---
id: cross-repo-refactor-eval-report
title: Evaluation report — cross-repo graph hooks: freshness gate, caller-edge answers, loop-closing
type: standalone
status: open
created: 2026-07-20
updated: 2026-07-20
note: 
---

# Evaluation report — cross-repo graph hooks: freshness gate, caller-edge answers, loop-closing

**Date:** 2026-07-15
**Branch:** `feature/skill-eval-harness`
**Scope evaluated:** C1 (freshness gate), C2 (caller-edge answers), C3 (close the sibling-refresh
loop), F3 (docs: no cross-repo blast radius). Companion to
[`cross-repo-refactor-safety.md`](cross-repo-refactor-safety.md).

All results below are measured, not asserted. The lab is the two-repo refactor simulation from the
handoff §4: `acme-lib` (defines `compute_invoice_total`, called in-library by `billing.py`) and a
consumer `acme-api` (two handlers call it) that registers `acme-lib` as an in-scope sibling. Every
step is AST-only / SQLite — **no LLM calls**.

---

## 1. Summary

| ID     | Defect                                                                                                                                             | Fix                                                                                                                                  | Status       |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ------------ |
| **F1** | A stale sibling graph made the hook **deny** the grep for a deleted symbol and abstain on the new one — blocking the check that reveals the truth. | **C1** freshness gate: a grep into a stale sibling advises, never denies, and names the refresh command.                             | ✅ closed    |
| **F2** | A cross-repo pre-answer returned only the definition under "no grep/retry needed" — callers silently dropped.                                      | **C2** caller-edge query: the answer now lists `CALLS`/`IMPORTS_FROM` sites; the deny copy is honesty-gated.                         | ✅ closed    |
| **F3** | Docs implied the graphify merged graph gives cross-repo blast radius / path tracing.                                                               | Docs corrected: the merged graph is a **disjoint union** (0 cross edges, measured); tracing across repos is a manual, per-repo step. | ✅ corrected |
| **C3** | Nothing warned that an in-scope sibling had no refresh hook, and a repo could report "0 failed" while advertising a stale alias.                   | Sync warns on a sibling with no `.graph-hooks/`; the verifier promotes an advertised-yet-stale alias from `[warn]` to `[FAIL]`.      | ✅ added     |

---

## 2. F1 — freshness gate (C1)

**Setup:** rename `compute_invoice_total` → `calc_invoice_total` in `acme-lib`, commit there, **do
not** rebuild its graph. `cross-repo-scope.sh` now reports the sibling as stale (`stale=1`).

| Probe (from `acme-api`)                      | Before (handoff evaluation)                                                                                 | After (measured)                                                                                                                                                                                                  |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| grep **old** (deleted) name into the sibling | **BLOCKED**: "the graph already has this — no grep/retry needed" (points at a symbol that no longer exists) | **Not denied.** Advises with: `WARNING: the 'acme-lib' graph predates its latest commit … Refresh in that repo first: code-review-graph update. Not blocking this grep — a stale graph must inform, never block.` |
| grep **new** name into the sibling           | allowed silently (graph can't help)                                                                         | allowed silently (correct — grep finds it on disk)                                                                                                                                                                |

**Key correctness fix during implementation:** when a command points **into** a sibling, only that
sibling's answer is denyable — never the local graph's. The first pass wrongly left
`DENYABLE=RESULT_LOCAL`, and because `acme-api`'s own graph holds caller edges for the symbol, the
stale sibling grep was still denied from _local_ results. Gating now branches on target: sibling →
`RESULT_SIB` (fresh) or empty (stale); local → `RESULT_LOCAL`.

Staleness is computed with **no subprocess** (`mtime(.git/HEAD) > mtime(graph.db)`) because the check
runs before every grep. Unknown → treated as fresh: silence must never escalate into a block.

---

## 3. F2 — answer with usages, not just the definition (C2)

**Setup:** fresh `acme-lib` graph; grep `compute_invoice_total` into the sibling from `acme-api`.

**Result (measured):** the deny now carries the call site, not just the definition:

```
The 'acme-lib' graph already has this — definition and its call sites below, no grep/retry needed:
[acme-lib] Function  compute_invoice_total  -> …/acme-lib/money.py:1
[acme-lib] CALLER  …/acme-lib/billing.py::monthly_statement (CALLS)  -> …/acme-lib/billing.py:5
```

**Correction to the handoff's SQL:** the handoff prescribed `WHERE target_qualified = ?` with the
bare symbol. Verified against a real `graph.db`, `target_qualified` is stored **path-qualified**
(`money.py::compute_invoice_total`), so the equality match returns **zero rows**. The shipped query
suffix-anchors on `'%::' || symbol` (precise — `::total` will not match `subtotal`) with a broad
`%symbol%` fallback.

**Honesty gate:** the "no grep/retry needed" copy is cross-repo-only and now conditional. If the
answer carries a `CALLER` line, the deny stands and says so; if it is a bare definition match, the
hook **advises instead of denying** ("this is not a full usage list, so the grep is not redundant").
Local greps are unchanged — the agent has the full local graph on hand, so a local definition hit is
still a legitimate stop.

---

## 4. F3 — no cross-repo blast radius (docs correction)

**Measured on the lab merged graph** (`acme-api/graphify-out/merged-graph.json`): 43 nodes, 33 edges,
**0 cross-repo edges**. `merge-graphs` concatenates each repo's subgraph and adds no edges between
them, so `graphify path` across the boundary returns nothing.

**Docs changed** (`register-cross-repo-graph/SKILL.md`):

- The "Querying it" section now flags `graphify path` as within-one-repo-only and adds: _"The merged
  graph is a disjoint union, not a bridge."_
- The Caveats bullet previously read _"Tracing a change into another repo needs one merged graph, not
  two read separately"_ — which implied the merge closes the gap. Corrected to state there is **no**
  cross-repo blast radius, and that tracing a change into a sibling is a manual, per-repo step
  (`cross_repo_search_tool` to locate, then that sibling's own `get_impact_radius` / `graphify path`
  inside it).

No code fix — this matches the skill's long-standing "blast-radius tools stay single-repo" caveat;
the docs simply no longer imply the merged graph is an exception.

---

## 5. C3 — close the sibling-refresh loop

**C3a — sync warns on a sibling with no refresh hook** (measured):

```
[warn] acme-lib has no .graph-hooks/ — nothing refreshes its graph, so it will drift stale
    keep it fresh: run setup-graph-hooks in …/acme-lib, or add it to CRG's watch daemon:
    code-review-graph daemon add "…/acme-lib"
```

**C3b — verifier promotes advertised-yet-stale to FAIL** (measured): with `acme-lib` stale (commit
time newer than `graph.db`) **and** advertised in the AGENTS.md block:

```
[FAIL] acme-lib is advertised in AGENTS.md but its graph is stale (HEAD newer than graph.db) —
       agents get expired cross-repo answers; refresh in that repo: code-review-graph update
Summary: 11 passed, 1 warnings, 1 failed
```

A stale sibling that is **not** advertised stays a `[warn]` (the block never routes to it, so it
cannot mislead). This closes the "0 failed while hooks hand out expired answers" gap the handoff
named.

---

## 6. Regression matrix (all measured, no change from prior behavior)

| Scenario                                                                | Expected                             | Result                 |
| ----------------------------------------------------------------------- | ------------------------------------ | ---------------------- |
| local symbol + local grep                                               | deny from local graph                | ✅ deny                |
| `--graph-tried` present                                                 | pass silently                        | ✅ empty               |
| non-code target (`.md`)                                                 | pass silently                        | ✅ empty               |
| broad local grep matching a **sibling-only** symbol (not aimed into it) | advise, never deny                   | ✅ context/advise      |
| repo with **no ledger** (`setup-graph-hooks` alone)                     | `cross-repo-scope.sh` prints nothing | ✅ empty (feature off) |

---

## 7. Verifiers and eval harness

| Check                                                                    | Result                                                                                                                                                                                                  |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `verify-graph-hooks.sh` (this repo)                                      | **36 passed, 0 failed**                                                                                                                                                                                 |
| `verify-cross-repo-graph.sh` (lab, fresh sibling)                        | **11 passed, 0 failed**                                                                                                                                                                                 |
| `verify-cross-repo-graph.sh` (lab, advertised stale sibling)             | **1 failed** — the C3b FAIL firing as designed                                                                                                                                                          |
| Eval `graph-search-behavior` (behavioral)                                | **8/8**                                                                                                                                                                                                 |
| Eval wired fixtures `all-wired` / `both-wired` / `copilot-primary-wired` | **idempotent** — installer re-run on a committed scratch copy produces zero diff (grade 1.0 post-commit; the in-place grader's only failure is `git_diff_empty` seeing this session's uncommitted tree) |
| `prettier --check` (changed files)                                       | clean                                                                                                                                                                                                   |

The four `.graph-hooks/core/*` copies (this repo + four fixtures) were re-synced to match the skill
source. `graphify path` / merged-graph counts and every deny/advise string above are transcript
evidence from the lab, not narration.

---

## 8. Reproduce

Lab builder: `scratchpad/setup-lab.sh <lab-dir>` (mirrors handoff §4). Remember `export HOME` to a
throwaway — CRG's registry is machine-global. Burn the once-per-hour allowance slot before observing
steady-state deny/advise behavior (handoff §4 gotcha). For C3b, staleness is driven by the git
**commit time** (`git log -1 --format=%ct`) vs the `graph.db` mtime — backdate the db below the commit
time, do not just `touch .git/HEAD`.
