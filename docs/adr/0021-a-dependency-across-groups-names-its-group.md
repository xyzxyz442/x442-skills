---
status: accepted
date: 2026-09-29
---

# A dependency across groups names its group

ADR 0018 keeps one board for a team with many groups because "cross-group library-to-consumer
dependencies are routine, and `depends_on` only works inside one board". On a grouped board it does
not: an id resolves only in the caller's own section, so a consumer group cannot name a library
group's handoff at all. We decided a `depends_on` entry may name another group of the same board as
`group/id`, that a bare id keeps meaning the caller's own section, and that the edge stays advisory.
This makes ADR 0018's premise true and changes nothing on a flat board.

## Context

- **Reproduced 2026-09-29** on a subfolder-layout board with groups `libs` and `api`, filing from
  `api`:
  - `new consume-dto --after libs/shared-dto` is accepted and stores
    `depends_on: [libs-shared-dto-handoff]` — the `/` is folded to `-` like any other separator,
    producing an id nothing has.
  - `new consume-dto2 --after shared-dto` is accepted and stores `[shared-dto-handoff]`; `claim`
    then warns `shared-dto-handoff (not filed on this board yet)` although
    `libs/shared-dto-handoff.md` exists.
  - Both are silent at creation, and neither warning ever clears when the prerequisite lands.
- **Ids repeat across groups by design** — two groups may each have their own `api` handoff — so a
  bare id cannot be resolved by searching every section.
- Every reader of the field resolves through the caller's section: `doc_file`/`arch_file` default to
  `$GROUP`, `each_doc` walks one section, and `move_dependents_of` therefore misses a dependent in
  another group.
- `blocked_on: external — BOARD-REMOTE#ID` (ADR 0018) exists for a wait on **another board**. Inside
  one board the tool owns both documents and can check the edge, which is the whole reason
  `depends_on` exists (ADR 0004).

## Decision

- **Two spellings, one meaning each.** A bare `id` names a handoff in the caller's own section, as
  today. `group/id` names a handoff in another section of the same board. `/` cannot occur in a
  slug, so no existing id becomes ambiguous.
- **One stored spelling per edge.** Entries are canonicalised on write: the group is slugged, the id
  gets its `-handoff` suffix, and a qualified entry naming the caller's own group is stored bare.
- **Resolution follows the spelling.** A qualified entry resolves in the named section, active then
  archive; archived still means landed.
- **A typo in the group is refused at creation; an unfiled id is not.** `new --after g/x` refuses a
  group the board does not host, by name. A prerequisite that is not filed yet is accepted, as
  today — work is often planned before its prerequisite is written up.
- **Still advisory** (ADR 0004). `claim` warns and proceeds; nothing refuses on an open prerequisite.
- **Bundles stay within one group.** `--children` refuses an entry containing `/` by name instead of
  folding it. A cross-group relationship is a dependency between two groups' handoffs, not one
  bundle owned by two groups.
- **A flat board refuses the qualified form** — it has no sections to name.
- **A move names every dependent**, qualified ones in other sections included, so none is left
  reading as satisfied by a pointer.
- **Payload bump, no schema bump.** The field stays a list of strings and every existing document
  stays valid. An older CLI that meets a qualified entry folds it into a non-existent id and prints
  the same spurious "not filed" warning it prints today; it writes nothing from the misread value.

## Considered options

- **Search every section for a bare id.** Rejected — ids repeat across groups, so the first match is
  a silent guess, and the guess changes when another group files the same id.
- **A separate field for cross-group edges.** Rejected — ADR 0004 draws the line between edges the
  board can check and reasons it cannot. A third field would split one relation in two by where its
  target happens to live.
- **Use `blocked_on: external — …` inside one board.** Rejected — that form is for a board the tool
  does not own. Within one board it would turn a checkable edge into text nothing checks.
- **`group:id` as the separator.** Rejected — a colon breaks unquoted frontmatter, the reason
  `fold_colons` exists.
- **Refuse a claim while a cross-group prerequisite is open.** Rejected for the reason ADR 0004
  gives: work legitimately starts out of order, against a stub, and a refusal gets routed around.

## Consequences

- ADR 0019 regenerates only the claiming group's index on a lease commit, so a dependent in another
  group sees the prerequisite land on its next `claim` or `list`, or when the roll-up regenerates —
  not the instant it lands. Acceptable for an advisory edge.
- `list` and the indexes show a qualified edge as written, so a reader sees which group owns the
  prerequisite without opening it.
- Cross-board dependencies remain free text (ADR 0018). This decision stops at the board's edge.

## Sources

- `docs/adr/0004-two-edge-types.md` — `depends_on` versus `blocked_on`, and why the edge is advisory.
- `docs/adr/0018-a-trust-boundary-is-its-remote-owner-and-a-child-board-narrows-it.md` — the
  one-board premise this decision makes true.
- `docs/adr/0019-a-lease-commit-touches-only-its-group-and-a-lost-race-retries.md` — per-group index
  regeneration.
