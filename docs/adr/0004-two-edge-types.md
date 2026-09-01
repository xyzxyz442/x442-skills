---
status: accepted
date: 2026-08-29
---

# Two blocker fields, not one — `depends_on` and `blocked_on`

A future reader will find two frontmatter fields that both look like "what is holding this
up" and will reasonably try to merge them. We decided to keep both, because they answer
different questions: `depends_on` is a **structural prerequisite** that is true whether or
not anyone is working, and `blocked_on` is a **status justification** written at the moment
someone stopped.

## Context

Boards in real use record their relationships almost entirely in prose. Documents routinely
name a dozen or more sibling handoff ids in body text while only a handful declare any
structured relationship at all, so the tool sees a flat list where the humans and agents see
a dependency web.

The one structured field that existed, `blocked_on`, was free text and carried both kinds of
answer at once — sometimes a sibling handoff id, sometimes something the board cannot model
at all (`external — deferred until the service is running`, `decision — waiting on the
owner`). Adding a second field risks two names for one concept, so the distinction has to be
stated or it will be collapsed later by someone tidying up.

## Decision

- **`depends_on`** holds **board ids only**, as a list. It means _this cannot start before
  that lands_. It is machine-checkable and renders as a real edge.
- **`blocked_on`** stays free text and is **reserved for what the board cannot model** —
  `external — …`, `decision — …`. If the blocker is a board id, it belongs in `depends_on`.
- **`superseded_by`** becomes first-class; it already occurred in the wild.
- **Enforcement is advisory.** `claim` warns when a `depends_on` target is still open.
  `release --status done` is **not** gated on it.
- **Prose references are surfaced, not required.** The index generates an advisory
  "referenced by" block from ids named in body text, so undeclared edges become visible
  without forcing anyone to declare them.
- **No general-purpose `relates_to`.**

## Considered options

- **One merged field.** Rejected — it is exactly the merge this ADR exists to prevent. The
  two are written at different times by different reasoning, and merging them would either
  force free text into a machine-checkable field or throw away the non-modellable cases.
- **Gate `done` on open dependencies.** Rejected — `depends_on` is about _starting_, not
  finishing, and work legitimately proceeds out of order. A production incident gets fixed
  before the pre-production backfill, and a tool that refuses to record that is a tool people
  route around. The bundle roster's outstanding-children refusal is a different thing and
  stays: that one really is about completeness.
- **Gate `done` on the reverse edge** (refuse to close a prerequisite while its dependants
  are open). Rejected — it inverts the meaning; a prerequisite finishing first is the
  intended order.
- **Adding `relates_to`.** Rejected — it would absorb every other edge and mean nothing.
- **Extracting prose references into real frontmatter automatically.** Rejected — a
  reference in prose is not necessarily a dependency, and promoting it to one would
  manufacture edges nobody asserted.

## Consequences

- `blocked_on` gets narrower than its existing usage. Documents that name a board id there
  are not wrong, but the convention going forward puts the id in `depends_on` and leaves a
  pointer behind.
- The index gains a generated backlink block, which is advisory and must be visibly marked
  as generated so nobody hand-edits it.
- Because enforcement is advisory, none of this is testable by exit code alone; the verifier
  needs machine-readable findings for any of it to be gradeable.
