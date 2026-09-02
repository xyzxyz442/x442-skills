# Plan-execution options — tradeoffs and steering

Companion to [ADR-0001](adr/0001-handoff-plan-execution-integration.md) (concept, accepted
2026-08-23), its design spec, and the
[implementation plan](superpowers/plans/2026-08-21-handoff-plan-execution-integration.md).

The ADR settles **what** to build and **why**. This document holds the **tradeoff analysis
behind that choice** and the **open items** that still need steering before or during
implementation. It is not a control document — if it disagrees with the ADR, the ADR wins.

## The three options

| Option                          | What it means                                                                                                       |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| **A — full engine, ad hoc**     | Use an external plan-execution engine directly, outside the board. No suite change.                                 |
| **B — linked engine** (the ADR) | One optional `plan:` field plus an Execution-modes routing table. The suite links to an engine and implements none. |
| **C — today**                   | `run-handoff` plus `run-delegate-agent`. No plan layer, no independent review.                                      |

A fourth option — reimplementing a reduced engine inside the suite — is rejected in the ADR's
Considered options, and the cost model below says why: it pays implementation and maintenance
cost across four tools to reproduce something routable for free.

**B is not an alternative to A.** B is the switch that routes to A. At execution time they are
the same tokens; B's marginal cost over A is one frontmatter field and one table. The real
comparison is whether reaching the engine is worth a routing layer, and whether the envelope is
worth its overhead.

## Grouped comparison

### Group 1 — What each thing is

| Axis            | A                      | B                                           | C                         |
| --------------- | ---------------------- | ------------------------------------------- | ------------------------- |
| Category        | Execution workflow     | Routing decision over an existing envelope  | Coordination and dispatch |
| Install surface | None                   | One field, one skill section (~120 lines)   | Already built             |
| Vendor coupling | Engine's own harnesses | None in committed content (steering dec. 1) | None                      |
| Reversibility   | Stop using it          | Absence of `plan:` is today's behavior      | —                         |

### Group 2 — Execution mechanics

| Axis                      | A                              | B                              | C                            |
| ------------------------- | ------------------------------ | ------------------------------ | ---------------------------- |
| Who writes code           | Fresh implementer per task     | Same, via the engine           | You, or a delegate process   |
| Independent review        | Yes — reviewer seat per task   | Same, **plus your own verify** | None; self-verification only |
| Fix loop                  | Bounded, with model escalation | Same                           | Ask-back cap only            |
| Final whole-branch review | Yes                            | Same, then `--verified-by`     | No                           |
| Steering granularity      | Per-plan, then hands-off       | Per-plan                       | Per-task or per-dispatch     |
| Escape hatch              | None — all-in                  | **The routing table**          | N/A                          |

### Group 3 — State and durability

| Axis               | A                             | B                                | C              |
| ------------------ | ----------------------------- | -------------------------------- | -------------- |
| Execution ledger   | Ephemeral, deleted on success | Same (inner)                     | None           |
| Durable record     | Git history only              | Board doc, committed and indexed | Board doc      |
| "Where was I?"     | Re-read `git log`             | `handoff list` — progress + plan | `handoff list` |
| Plan ↔ record link | None                          | The `plan:` field                | None           |

### Group 4 — Control and safety

| Axis                | A                 | B                             | C                         |
| ------------------- | ----------------- | ----------------------------- | ------------------------- |
| Enforcement         | Prose only        | Prose **plus the lease gate** | Lease gate + consent gate |
| Human approval      | Removed by design | Removed inside, kept at edges | Required per dispatch     |
| Multi-worker safety | Avoided by rule   | Prevented by lease            | Prevented by lease        |

## Cost model

These are **structural estimates from seat and turn counts, not measurements.** Treat the ratios
as reliable and the absolutes as indicative. Assumptions: one task touches 1-3 files with tests;
implementer 10-20 turns, reviewer 4-8, controller 2-4 per task; input dominates output roughly
6 to 1; prompt caching makes conversation re-sends about a tenth of fresh input cost.

### Seats per task

| Situation                      | A / B (identical)              | C          |
| ------------------------------ | ------------------------------ | ---------- |
| Clean task                     | ~2.2 seats                     | ~1 seat    |
| One fix round                  | ~3.5 seats                     | ~1.5 seats |
| Four small same-shape, batched | ~0.55 seats/task               | 0.25       |
| Plan level                     | + final review, + one fix wave | none       |

### Relative cost, baseline is doing the task manually in the main session

| Path                          | Tokens   | Dollars      | Main-session context |
| ----------------------------- | -------- | ------------ | -------------------- |
| Manual in-session             | 1.0x     | 1.0x         | **100%**             |
| A/B clean task                | 2.5-3.5x | 2.5-3.5x     | ~10-20%              |
| A/B with one fix round        | 4-5x     | 4-5x         | ~15-25%              |
| A/B batched                   | 1.2-1.5x | 1.2-1.5x     | ~10%                 |
| Delegate, cheaper hosted tier | 1.2-2x   | **0.2-0.6x** | ~15-25%              |
| Delegate, local model         | 1.2-2x   | **~0x**      | ~15-25%              |
| Handoff envelope overhead     | +2-5k    | ~1.02-1.05x  | ~5%                  |

Three readings that are easy to miss:

1. **Tokens and dollars diverge when the tier changes.** Delegation raises token count and lowers
   cost. Any optimization framed as "fewer tokens" steers wrong — optimize dollars and context
   separately.
2. **Main-session context is the scarce resource.** Manual costs 1.0x dollars and 100% of the
   thing that makes a session lose the thread. Buying context back with money is usually a good
   trade at these ratios.
3. **The reviewer seat is roughly 30-40% of A/B's cost.** That is the price of independent review.
   Worth knowing so the decision is explicit.

### Optimization levers, by leverage

| Lever                                     | Effect                                                                           |
| ----------------------------------------- | -------------------------------------------------------------------------------- |
| Batch same-shape tasks into one dispatch  | Up to 3-5x on a plan of small edits — kills N-1 implementer _and_ reviewer seats |
| Route one- and two-task handoffs away     | Avoids ~2.2 seats that buy nothing (already an anti-pattern in the plan)         |
| Pass artifacts as file paths, never paste | Keeps controller context flat across the whole plan                              |
| Tier models, but do not undershoot        | Cheap models take 2-3x the turns; the naive choice can cost more                 |
| Delegate as the cheap tier                | Reaches endpoints in-harness tiering cannot                                      |
| Graph over grep inside subagents          | Inherited from the repo's AGENTS.md routing                                      |

### Worked example — six tasks, four mechanical, two judgment

| Approach                                       | Seats | Dollars   | Main context | Durable record        |
| ---------------------------------------------- | ----- | --------- | ------------ | --------------------- |
| A, naive (one seat pair per task)              | ~15   | ~4.5x     | ~15%         | git only              |
| A, batched                                     | ~8    | ~2.2x     | ~12%         | git only              |
| B (A batched, routed)                          | ~8    | ~2.2x     | ~12%         | board doc + plan link |
| **B optimized** (mechanical batch to delegate) | ~7    | **~1.3x** | ~12%         | board doc + plan link |
| C, today                                       | ~5    | ~0.9x     | **~60%**     | board doc             |

The bottom two rows are the decision. B-optimized costs about 40% more than today, adds
independent review and a bounded fix loop, and cuts main-session context load roughly fivefold.

## What the accepted ADR settles, and what follows

| Decision                                         | Consequence to hold in mind                                                                                 |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------- |
| 1. Tool-agnosticism is **required**              | Engine names live in plan files only. See open item 1 — the constraint currently has no gate.               |
| 2. Soft warning at `new`, preflight in the brief | Covers the executor's checkout. See open item 3 for the local case.                                         |
| 3. Plan follows the SDD plan format              | A documentary coupling only — the CLI never parses the plan, so upstream format drift cannot break the CLI. |
| 4. ADR steers, spec and plan control             | Steering changes here must flow down to both before the affected task starts.                               |

Decision 1 also names the owner's two primary engines. Only one of them has a plan-execution
engine today, which is a routing rule rather than a defect — see open item 4.

## Open items for steering

Ranked. Each names a proposed resolution and where it would land.

### 1. Tool-agnosticism is required but ungated (high)

Task 4 Step 5 of the plan runs `scripts/verify-standalone.sh --staged` and expects it to catch a
leaked engine name. **It cannot.** That script checks three things — parent-relative wiring in tool
config, parent-relative paths that escape the repo, and identifiers in the standalone denylist —
and that denylist
holds only foreign project names. Its header comment explicitly says never to add tool vendors,
because vendor names appear legitimately throughout the repo (the per-tool support tables). So the
step passes whether or not a name leaked, and steering decision 1 ships with no enforcement.

Note the distinction the plan currently blurs: the constraint is not "no vendor names" — those are
legitimate almost everywhere — it is "no **engine** names in these two skills."

**Proposed:** add a scoped check to Task 5 (harness), not Task 4. A grep over
`skills/engineering/run-handoff/SKILL.md` and `skills/engineering/delegate-handoff/SKILL.md` for
engine identifiers, which never legitimately appear in those two files. Leave the denylist alone.

### 2. Execution rulings have nowhere durable to land (high)

The ADR accepts **retrospective rulings** as a behavioral shift. The engine records rulings in its
own workspace, which it deletes on success, surfacing them only in a closing message. If that
session ends, the decisions the engine made on your behalf are gone — in a system whose purpose is
that you can come back and not be lost.

The doc template already has a **Decisions** section, so the fix is prose, not code.

**Proposed:** one sentence in Task 4 Step 1 — on release, graduate the engine's rulings into the
doc's Decisions section, each with what it costs if wrong. Only rulings, commits, and evidence
graduate; the task-by-task trace stays in the ephemeral ledger and dies with it. A child that
writes its whole trace upward turns the board into a transcript dump, which is a different way of
being lost.

### 3. A dangling plan link is only caught in the executor's checkout (medium)

Decision 2 warns at `new` (when absence is most often legitimate) and hard-checks in the brief's
preflight (the offline path). The local case is uncovered: a plan-driven handoff whose plan was
renamed, moved, or never written, picked up months later by your own fresh session.

**Proposed:** mark unresolved paths in `list`'s Plan column — the column is already being printed
in Task 3, so this is nearly free — and add a probe to `repair-handoff`, which already owns this
class of board-state drift.

### 4. Only one of the two primary engines has a plan-execution engine (medium)

Decision 1 names Claude Code CLI and GitHub Copilot in VS Code. Task 4 already says a plan without
an engine still works as a manual task-by-task guide. The cost consequence is not yet written
down: in a session with no engine, plan-driven mode delivers C economics, not B — no reviewer
seat, main-session context load back near 100%.

**Proposed:** treat this as a routing rule in the adopted flow rather than a code change. Route
plan-driven children to sessions whose tool has an engine; give the others delegate or manual.
Keep the skill wording generic as decision 1 requires.

### 5. Location convention versus tool-agnostic content (low)

Decision 3 documents `docs/superpowers/plans/`, a path named after a specific suite. No conflict as
long as it appears only in the ADR, spec, and plan. It would conflict with decision 1 if it reached
committed skill content or a doc template.

**Proposed:** confirm during Task 2 and Task 4 that no template or skill body names the path.

## Adoption sequencing

1. Resolve open items 1 and 2 into the plan before Task 2 freezes the field's semantics.
2. Implement the ADR as planned — the field, the routing table, the harness cases, the payload bump.
3. Run one real multi-task handoff end to end before adding anything further. What hurts in that
   run is what earns code next.
4. Revisit the reviewer seat and the fix loop only if the engine's own review proves insufficient.
   Both are already provided by the engine B routes to; building them in-suite duplicates the seat.
