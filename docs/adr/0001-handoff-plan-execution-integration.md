---
status: accepted
date: 2026-08-23
---

# Link handoffs to task-structured plans

A handoff is the durable coordination **envelope** (claim → execute → verify → release);
a task-structured plan is the **payload** that tells an execution session _how_ the work
gets done. We decided to link the two with one optional `plan:` frontmatter field on
coordination docs, settable via `handoff new --plan PATH`, so a fresh session can route a
claimed handoff to its tool's plan-execution engine (fresh implementer per task, per-task
spec+quality review, bounded fix loop) instead of steering every task by hand — while the
lease, the `--verified-by` evidence gate, and the board stay exactly as they are.

## Context

Today a fresh execution session steers each task of a multi-task handoff by hand. A
plan-execution engine removes that per-task steering, but the board has no way to say
"this handoff has a plan" — the link between envelope and payload is missing. The
alternative of pasting the plan into the handoff doc was rejected: the doc would bloat,
and the plan file would no longer be the single source of task structure.

## Decision

- `plan:` is an **optional** frontmatter field on coordination docs, holding a
  **repo-relative path** to a task-structured plan (`Task N` headings, Global
  Constraints, exact steps). Its presence is the declaration that the handoff is
  plan-shaped; absence means today's behavior, unchanged.
- The CLI validates the path (no leading `/`, no `..` segment, no `:`) and stores it
  verbatim. It does **not** parse or validate the plan's content.
- `handoff export` inlines the plan path into the offline brief; `handoff list` shows a
  `Plan` column so a session can route at a glance.
- `run-handoff` gains an **Execution modes** routing table — plan-driven (`plan:`
  present), delegate (mechanical, one checkable definition of done, fits the context
  window), manual (needs this session's judgment) — and the rule that the lease wraps
  whichever runs: claim before, release `done --verified-by` after the engine's final
  review **plus the session's own verify**.
- `delegate-handoff` treats a linked plan as the spec-compliance reference when
  reviewing a returned brief.
- Committed skill content stays **tool-agnostic** — it says "the tool's plan-execution
  engine", never a specific vendor's engine name. Plan _files_ may name engines.

## Considered options

- **Embed the plan in the handoff doc.** Rejected — doc bloat, and the plan file stops
  being the single source of task structure.
- **A new `plan-execution` skill.** Rejected — the behavior is a routing decision over an
  existing handoff, not a new capability; it lives in `run-handoff` and
  `delegate-handoff`.
- **Let the CLI validate plan content (parse `Task N` headings).** Rejected — the CLI
  would own a plan format it does not author; validation belongs to the engine that
  executes the plan.
- **Name the engine in skill content.** Rejected — this repo installs into repos using
  different tools; the skill must route by shape, not by vendor.

## Consequences

- A handoff with no `plan:` behaves exactly as today — no existing doc, fixture, or
  self-test breaks.
- The payload version moves (currently `setup-handoff 6` → `7`) and every fixture mirror
  of the CLI and templates must be re-synced.
- Two behavioral shifts are accepted: **per-plan steering, not per-task steering** (the
  owner steers the plan up front and steps in only at the engine's stop conditions), and
  **retrospective rulings** (execution rulings are recorded and reviewed at the end, not
  approved as they happen). A handoff the owner cannot let go of routes to manual — the
  escape hatch the routing table exists for.

## Steering decisions (resolved 2026-08-23)

1. **Tool-agnosticism is required.** Committed skill content stays tool-agnostic — it
   routes by shape, never by a vendor's engine name. The owner's primary engines are
   Claude Code (CLI) and GitHub Copilot (VS Code); that is context for choosing which
   engine a session routes to, not a reason to name engines in the skill.
2. **No hard existence check; soft warning + executor preflight.** The CLI validates
   shape only (no leading `/`, no `..` segment, no `:`) and stores the path verbatim.
   When the file is missing at `new` time, the CLI prints a stderr warning
   ("plan file not found: … (may be filed later)") but does not refuse — a handoff is
   often filed before its plan is written. The brief's preflight block gains a second
   check (alongside the root-commit check) that verifies the plan file exists _in the
   executor's checkout_; a missing plan there is a stop condition, not a warning. The
   CLI does not own the plan's lifecycle.
3. **The plan is an SDD plan.** It follows the superpowers suite's SDD plan format
   (`writing-plans`): `Task N` headings, Global Constraints, exact steps, no
   placeholders. The documented location convention is `docs/superpowers/plans/`
   (documented, not enforced).
4. **Split of authority confirmed.** This ADR is the steering document (concept). The
   design spec and the implementation plan are the control documents for implementation
   and sub-agent delegation. Most of the work will be a handoff that references the plan
   and the spec — the envelope/payload pattern in practice.
