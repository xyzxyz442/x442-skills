---
id: flow-comparison-sdd-vs-handoff
title: Flow comparison — SDD vs handoff steering
type: standalone
status: open
created: 2026-08-23
updated: 2026-08-23
note:
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

<!-- STANDALONE / reference handoff: self-contained, gate-exempt (no lease needed to edit),
     and not surfaced as claimable work. Use it for knowledge transfer, a porting guide, an
     eval report, or a session-compaction brief — not for coordinating who edits what next. -->

## Summary

Reference for steering the **next handoff improvement**. It compares four candidate
working flows on token cost, flag handling, parallelism, and cross-project reach, and
ends with a concrete "SDD-lite" spec — the subset of superpowers SDD worth grafting onto
the current handoff-only flow. Read this before scoping the improvement; the verdicts and
the SDD-lite spec are the actionable parts.

Grounded in measured artifact sizes from this repo (see Context §1) and the user's actual
usage pattern: human-as-scheduler, several fresh sessions running handoffs in parallel,
frequent mid-session flags, and occasional cross-project work (API / frontend / library).

## The four flows, precisely

1. **Current** — handoff board only. Grill an idea → file an orchestration handoff
   (+ optional coordinate handoffs) → run each in a fresh session, several in parallel,
   the user reviews each.
2. **SDD + delegate + handoff** — superpowers spec → plan → subagent-driven execution,
   delegate for mechanical work, board for cross-session coordination.
3. **SDD + delegate + handoff + cross-project** — flow 2 plus
   `register-cross-repo-handoff` (shared board) and `register-cross-repo-graph`
   (cross-repo symbol resolution) across API / frontend / library.
4. **Delegate + handoff + SDD-lite + cross-project** — the current flow, plus delegate
   offload, plus the _useful_ SDD pieces grafted on (see SDD-lite spec), plus cross-project
   wiring.

## Context

### 1. Measured baseline (this repo)

SDD artifacts for one feature (`handoff-offline-delegation`):

| Artifact                                                                      | Size                                                                    |
| ----------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Spec `docs/superpowers/specs/2026-08-21-handoff-offline-delegation-design.md` | 354 lines / 19 KB                                                       |
| Plan `docs/superpowers/plans/2026-08-21-handoff-offline-delegation.md`        | 1,285 lines / 54 KB — 8 tasks, 49 checkbox steps, 46 fenced code blocks |
| **Static docs total**                                                         | **~73 KB ≈ 18–20k tokens**                                              |

Handoff equivalent: one doc. A single handoff entry is frontmatter + title + severity + a
few notes — roughly **100–300 tokens**. The board `INDEX.md` is ~2.9 KB and generated.

Why the SDD number is what it is:

- The plan **embeds complete code for every step** — it is the implementation pre-written,
  so the work is generated twice (once as plan text, once when the subagent writes it).
- Spec and plan **double-write** the same design facts.
- Execution **re-reads the plan per task** — with 8 tasks the 54 KB plan is consumed ~8–16×
  across the session, plus the orchestrator accumulates every subagent report.
- Opus multiplies all of it at its per-token rate.

### 2. Token cost model

Let `E` = execution cost (read live code + implement + verify). `E` is **irreducible and
identical in all four flows** — the plan does not replace execution, it precedes it.

| Flow               | Total (per feature)                                                                               |
| ------------------ | ------------------------------------------------------------------------------------------------- |
| 1 · Current        | E + grill + flags                                                                                 |
| 2 · SDD+del+ho     | E + **~20k plan** + **N×plan re-reads** + flags(dual-queue) − delegate savings                    |
| 3 · +cross-proj    | (E + 20k + re-reads) × N_repos + cross-proj overhead − delegate savings                           |
| 4 · SDD-lite+cross | E + grill + **~1–2k decision log** + flags(single-queue) − delegate savings + cross-proj overhead |

### 3. Comparison table

| Axis                  | 1 · Current                                   | 2 · SDD+del+ho                                          | 3 · +cross-proj                            | 4 · SDD-lite+cross                               |
| --------------------- | --------------------------------------------- | ------------------------------------------------------- | ------------------------------------------ | ------------------------------------------------ |
| Planning cost         | Low (grill + ~300 tok/handoff)                | High (~18–20k, one-time)                                | High × N repos                             | Low (grill + decision log ~1–2k)                 |
| Plan re-read tax      | None                                          | Per task                                                | Per task × N repos                         | None (no embedded plan)                          |
| Flag handling         | **Best** — single queue, 2-way triage         | Dual-queue drift (plan vs board)                        | Dual-queue × N repos                       | **Best** — single queue + delegate lane          |
| Parallelism           | **Native** — leases = locks, user = scheduler | Orchestrator = scheduler, subagents sequential per plan | Cross-repo parallel via shared board       | **Native** + cross-repo via shared board         |
| Cross-project         | No                                            | No                                                      | **Full** — shared board + cross-repo graph | **Full** — shared board + cross-repo graph       |
| Review surface        | Thin (handoff doc only)                       | **Rich** (spec is the artifact)                         | Rich × N                                   | Good (decision log + acceptance criteria)        |
| Mechanical offload    | No                                            | Delegate                                                | Delegate                                   | Delegate                                         |
| Dominant failure mode | Board noise; user attention = bottleneck      | Dual-queue drift; orchestrator bloat                    | All of #2 × N; cost multiplies             | Board noise (mitigated); SDD-lite must stay thin |

### 4. The flags axis (the recurring-cost insight)

Mid-session flags (in-scope / too-big / standalone / nice-to-have / cosmetic) are a
**recurring** cost, and recurring costs punish the flow with the more expensive per-unit
mechanism.

- **Current flow** has **one work queue** (the board). A flag is a first-class citizen:
  `handoff new`, pick a severity, keep going. 2-way triage (fix now / file). ~1–2k tokens
  per flag, bounded.
- **SDD flow** has **two queues** (frozen plan + board). Planned work is in the plan; a flag
  has nowhere to go _in the plan_, so it leaks to the board or a delegate. 4-way triage
  (fix now / append to plan / file / delegate). A cosmetic flag appended to the plan is
  re-read by every later subagent — pure waste. Per-flag cost is higher (subagent →
  orchestrator round-trip + routing judgment).

Net: on the flags axis the current flow is **structurally cheaper, and the gap widens with
flag frequency** — the opposite of the planning axis, where SDD's cost is front-loaded and
one-time. The flags problem tips the balance _away_ from SDD, not toward it.

The one thing SDD's stack genuinely adds here is the **delegate channel** for the
_mechanical_ flag class (rename, format, boilerplate, a self-contained obvious fix). That
value comes from **delegate, not SDD** — it can be grafted onto the current flow without
touching the planning side.

### 5. Verdicts

- **Flow 1** is the floor — cheapest, and its parallelism model (user as scheduler, leases
  as locks, fresh sessions as workers) is genuinely better than SDD's orchestrator model for
  this usage, because the user's attention is the bottleneck either way and leases survive
  session death while subagent state does not. Gaps: no cheap offload, no cross-project,
  thin review surface.
- **Flow 2 is dominated by Flow 4.** Every benefit it has (delegate, review surface) is
  available in Flow 4 without the dual-queue drift or the plan re-read tax. No scenario in
  the described usage where #2 beats #4.
- **Flow 3** is the expensive special case. Justified only when a cross-project feature is
  large _and_ the API contract is risky enough to warrant reviewing the full approach across
  three repos before any code is written. Even then, strip embedded code from the plan — it
  is the dominant cost and never the part being reviewed.
- **Flow 4 is the recommendation.** Keeps the single-queue and parallel-session advantages,
  adds SDD's review surface (decision log + acceptance criteria) at ~10% of the cost, adds
  delegate for the mechanical flag class, and adds cross-project when needed.

## SDD-lite spec (what to adopt, what not to)

**Adopt:**

1. **Decision log** (from the spec) — when grilling hits "frontier empty," append one line
   per settled decision to the orchestration handoff, _including rejected alternatives where
   the rejection was non-obvious_. ~1–2k tokens. This is the review surface and stops fresh
   sessions re-litigating.
2. **Acceptance criteria** (from the plan's task structure) — each handoff gets a "done
   means" list: verifiable outcomes, **not code**. This is what `release --verified-by`
   checks against. ~500 tokens.
3. **Task breakdown, only for big handoffs** (from the plan) — when one handoff is too big
   for one session, split it into sub-handoffs on the board. Interfaces + acceptance
   criteria only, **never embedded implementation**.
4. **Per-task verification** (from subagent-driven-development) — already present via
   `--verified-by`. Keep.

**Do not adopt:**

- Embedded implementation code in a plan (the dominant SDD cost — live code is read at
  execution time instead).
- Orchestrator subagent fan-out (the user's parallel sessions _are_ the fan-out, with
  durable leases).
- Spec/plan double-write (one doc carries both the decisions and the acceptance criteria).

## Cross-project wiring (flows 3 & 4)

Not SDD-specific — same for both:

- `register-cross-repo-handoff` → one shared board across API / frontend / library, each
  repo a sub-indexed section. A cross-project feature = one orchestration handoff that fans
  out to per-repo handoffs on the shared board.
- `register-cross-repo-graph` → a frontend session resolves backend symbols via the graph
  instead of grepping across folders. This is the token _saver_ in cross-project work — it
  keeps `E` from ballooning when a session needs context from a sibling repo.
- The **API contract** is the one artifact worth writing up front in either flow — as a
  compact contract handoff (endpoint shape, error codes, auth), ~1–2k tokens, not a 19k SDD
  spec.

## Suggested skills

- `run-handoff` — where the triage discipline + decision-log/acceptance-criteria shape land
  (the concrete skill change this doc is steering).
- `grilling` — the planning front-end that produces the decision log.
- `setup-delegate-agent` / `run-delegate-agent` — the mechanical-flag offload lane.
- `register-cross-repo-handoff` / `register-cross-repo-graph` — the cross-project wiring.

## Notes

- **Open question:** cap the board's low-severity queue. If cosmetic flags accumulate faster
  than they are cleared, the board becomes a tax on every future session's `handoff list`.
  Candidate: a periodic "clear or close the low-severity queue" pass. Decide whether this is
  a `run-handoff` discipline or a `repair-handoff` check.
- **Open question:** where the decision log lives — a section in the orchestration handoff
  doc vs. a frontmatter field. A section is more readable; a field is more queryable.
- **Guardrail for SDD-lite:** it must stay thin. The moment the "decision log" starts
  carrying implementation detail, it becomes the 54 KB plan again and the cost advantage
  collapses. The test: a fresh session should be able to execute the handoff by reading the
  decision log + acceptance criteria + live code, without needing any pre-written code.
- This doc is a reference, not a work item — no claim needed. The actual improvement work
  should be filed as its own coordination handoff(s) that cite this doc.
