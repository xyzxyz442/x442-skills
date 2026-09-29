---
status: accepted
date: 2026-09-29
---

# Who does the work is told through the tracker, and the board names only the reviewer

A senior developer files and plans a handoff; a junior developer executes it. The board has one
field naming a person, `reviewer` (ADR 0016), and nothing naming who is expected to pick the work up
before they claim it. We decided not to add that field yet: the senior files with `--reviewer`
naming themselves and adds the implementer as a tracker assignee by hand, the implementer claims on
the board when they start, and the field is reconsidered only on evidence that the gap costs
something.

## Context

- `reviewer` is projected as the tracker's assignee on create and **never reconciled** (ADR 0016),
  so an assignee added by hand in the tracker survives every later mirror run.
- The lease holder is a **session**, not a person, and its TTL starts at `claim`. Claiming on
  someone's behalf starts their clock before they begin and names the wrong session.
- A new document field is a schema bump (ADR 0003). On a board with a remote, every machine with an
  older CLI refuses to write until it re-runs the installer — on a board of dozens of members, that
  is dozens of reinstalls before anyone benefits.
- The glossary reserves **assignee** for the tracker projection of `reviewer`, not for a field.
- A handle is stored as the tracker login itself; ADR 0016 rejected a people registry. A handle that
  is not the login makes the assignment step fail, and that step is non-fatal by design.

## Decision

- **No implementer field now.** The senior files with `new --reviewer <own handle>`, then adds the
  implementer as an assignee in the tracker. The tracker notifies them.
- **The implementer claims on the board when they start.** From then on the lease says who is
  working; before then, the tracker says who is expected to.
- **A handle must equal its owner's tracker login.** Onboarding checks it by mirroring one test
  handoff naming each member as reviewer. The verifier warns when a developer's `handle` differs
  from their recorded `hostAccount`.
- **Revisit on evidence, not preference.** The field is reconsidered when implementers ask what
  they are meant to do outside the handoff and its issue, or when assigned work sits unclaimed with
  nobody noticing. Then it is a schema-bump candidate, named for what it holds and not `assignee`.

## Considered options

- **An implementer field now.** Deferred — it costs a schema bump and a reinstall on every member's
  machine before any evidence that the tracker assignee falls short.
- **Reuse `reviewer` for the implementer.** Rejected — in exactly this case the reviewer and the
  implementer are different people, and `reviewer` drives "awaiting YOUR review".
- **The senior claims, then hands the lease over.** Rejected — a lease belongs to a session, the TTL
  runs before work starts, and there is no transfer that keeps it a compare-and-swap.

## Consequences

- `list` and the session banner cannot show "waiting for YOUR pickup"; the implementer learns of the
  work from the tracker notification.
- The board and the tracker may disagree about who is expected to do the work. The tracker wins, as
  ADR 0016 already accepts for assignees, and nothing reports it as drift.

## Sources

- `docs/adr/0003-schema-versioning-and-migration.md` — a new field bumps the schema.
- `docs/adr/0016-a-reviewer-is-a-pointer-not-a-gate.md` — assign on create, never reconcile; no
  people registry; non-fatal assignment.
