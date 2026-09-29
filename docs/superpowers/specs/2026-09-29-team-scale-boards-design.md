# Team-scale boards — design

Date — 2026-09-29
Status — approved, pre-implementation
Branch — `feature/team-scale-boards`
Decisions — [ADR 0021](../../adr/0021-a-dependency-across-groups-names-its-group.md),
[ADR 0022](../../adr/0022-the-team-board-is-the-one-setup-finds-and-a-developers-own-board-is-reached-by-name.md),
[ADR 0023](../../adr/0023-who-does-the-work-is-told-through-the-tracker-and-the-board-names-only-the-reviewer.md)

## Problem

A team of dozens of developers, holding a hundred or more live handoffs, coordinates through one
dedicated board with several groups — a shared-library group and the service groups that consume
it. Each developer also keeps a board for drafts. A senior files and plans work, a junior executes
it, and the team is notified through each repository's issues.

A design review on 2026-09-29 stress-tested that arrangement against the suite as shipped at payload
66, schema 4. Most of it already works: dedicated boards and groups (register-cross-repo-handoff),
child boards (ADR 0018), per-group tracker rules (ADR 0020), per-group index regeneration and push
retries (ADR 0019), and `reviewer` projected as the issue assignee (ADR 0016). Three gaps remain:

| Gap                                                                   | Effect today                                                                                                   |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `depends_on` resolves only in the caller's section                    | a consumer group cannot name a library group's handoff; `g/id` is silently folded into a non-existent id       |
| `--local-board` replaces the checkout's board and setup does not warn | a developer recording their draft board moves every claim in that checkout off the team board                  |
| nothing checks that a `handle` is the tracker login                   | a wrong handle makes the reviewer assignment fail, and that step is non-fatal by design, so nobody is notified |

The first was reproduced on a throwaway subfolder board; the record is in ADR 0021's Context.

## Decisions

In short — the ADRs carry the reasoning.

1. **Claims happen on the team board.** A developer's own board holds unshared drafts only. The
   tracker notifies; the board decides. (ADR 0022, reaffirming 0002 and 0011.)
2. **`depends_on` accepts `group/id`** for a handoff in another group of the same board. A bare id
   keeps meaning the caller's own section. Still advisory. (ADR 0021.)
3. **Bundles stay within one group.** `--children` refuses `/`. (ADR 0021.)
4. **The team board goes where setup finds it; a developer's own board goes where setup does not
   look first**, and is recorded in the `boards` map rather than with `--local-board`. Setup warns
   before `--local-board` overrides a committed team board. (ADR 0022.)
5. **No implementer field.** The senior files with `--reviewer` naming themselves and adds the
   implementer as an issue assignee by hand. The verifier warns when `handle` differs from
   `hostAccount`. (ADR 0023.)

### Rejected alternatives

Recorded in the ADRs: a discovery-only catalog board with leases on personal boards, an issue as the
unit of coordination, one board per group, searching all sections for a bare id, a third edge
field, a `:` separator, an implementer field now, reusing `reviewer`, and claiming on someone's
behalf.

## Qualified dependencies

### Grammar

```text
depends_on entry := id | group "/" id
```

- `group` is slugged with the board's `slug()`; `id` is normalised with `norm_id()` (adds
  `-handoff`). A `/` never survives either, so the separator is unambiguous.
- Exactly one `/`. More than one is refused as unusable.
- Canonical stored spelling: `group/id-handoff`, except that a qualified entry naming the caller's
  own group is stored bare.

### Where it is read and written

Every site below changes; nothing else reads the field.

| Site                                            | Change                                                                                                                              |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `new --after` / `--depends-on` (builds `dlist`) | parse through a new `dep_csv` instead of `children_csv`; refuse an unknown group by name; refuse the qualified form on a flat board |
| `depends_of`                                    | read through a new `dep_read`, which keeps the `group/` prefix instead of folding it                                                |
| `warn_open_dependencies` (claim)                | resolve each entry through a new `dep_path`, which calls `doc_file`/`arch_file` with the named group                                |
| `move_dependents_of`                            | walk every section, reading a bare entry as the section it sits in; name dependents in other sections as `group/id`                 |
| `move_stage_copy` (turns edges into a blocker)  | unchanged — a qualified entry reads correctly in the blocker text as written                                                        |
| `--children` (`children_csv`)                   | refuse an element containing `/` by name, before slugging: a bundle stays within one group                                          |

The group list is the board's configured `groups` (`each_group`). The qualified form needs a board
that hosts groups; anywhere else it is refused.

### Compatibility

No schema bump. An older CLI reading a qualified entry folds it and prints the "not filed" warning
it prints today; it writes nothing from that value. Payload bumps 66 → 67.

## A developer's own board

### Setup guard

`setup-handoff.sh --local-board PATH`, when the repo's committed `.agents/handoff.json` (`board` or `boardPath`)
or, failing that, an in-repo `.agents/handoff/` names a different board, prints before writing
(a board found only in a parent directory is not consulted):

```text
setup-handoff: this checkout claims on <team board> today. Recording <PATH> as its board moves every
claim, list and hook here onto <PATH>, where the rest of the team does not look.
To keep claiming on the team board and still reach <PATH>, record it in the boards map instead:
  "boards": { "<PATH's remote>": "<PATH>" } in .agents/handoff.local.json
```

It still writes — a developer may deliberately take one checkout off the team board. Exit status
stays 0.

### Skill guidance

`setup-handoff/SKILL.md`, "A developer's own board is a choice, not a role": the three layouts stay,
each gains the rule that the path must not be a detected spelling at the repo or its two parents,
and the wiring becomes the `boards` map when a team board exists. `--local-board` is kept for a
checkout whose only board is the developer's own.

## Handle and host account

Verifier, beside the existing ADR 0018 `hostAccount` shape check: when `handoff.local.json` sets both
`handle` and `hostAccount` and they differ, warn `repo.local_config.handle_not_host_account` —
"assignments naming you target `<handle>`, but this board writes as `<hostAccount>`; they are
usually the same login". Offline, advisory. Nothing in the CLI changes.

## Documentation

- `docs/usage/handoff.md`
  - Situation 2: the implementer is told through the issue assignee (ADR 0023).
  - Situation 6: qualified ids, with a library-to-consumer example.
  - "A team, several groups…": the cross-group dependency, the placement of the team board and of
    Alice's own board, and the `boards`-map wiring.
  - A short onboarding checklist for a team board: handle = login, one test assignment per member,
    and what to watch in the first weeks (claims exhausting the three retries, `TRACKER-DRIFT.md`,
    implementers asking what to do outside the handoff).
- `skills/engineering/run-handoff/SKILL.md` — the `depends_on` field row gains `group/id`.
- `skills/engineering/setup-handoff/scripts/payload/README.md` — the same.
- `CONTEXT.md` — **Qualified id** added, **Depends on** amended (done with this spec).
- ADR 0018's Context bullet stays as written; ADR 0021 is what makes it hold.

## Verification

### Selftests (`handoff.selftest.sh`)

A subfolder board with groups `libs` and `api`, filing from `api`. Each case is seen to fail on the
unpatched CLI first.

1. `--after libs/shared-dto` stores `depends_on: [libs/shared-dto-handoff]`.
2. With `libs/shared-dto` open, `claim consume-dto` warns naming `libs/shared-dto-handoff (open)`.
3. After `libs/shared-dto` is released `done` (archived), the same claim prints no warning.
4. `--after nope/x` is refused, naming `nope` and the board's groups; nothing is written.
5. `--after api/local-thing` from `api` stores the bare `local-thing-handoff`.
6. `--after a/b/c` is refused as unusable.
7. On a flat board, `--after libs/x` is refused.
8. `--children libs/x` is refused with the "stays within one group" message, before any slugging.
9. `move` of `libs/shared-dto` lists `api/consume-dto-handoff` among its dependents.
10. Regression: a bare `--after` inside one section behaves exactly as at payload 66.

### Setup and verifier

- `setup-handoff.selftest.sh`: `--local-board` over a committed team board prints the guard and still
  writes; with no committed board it prints nothing new.
- `verify-setup-handoff.sh`: `handle` ≠ `hostAccount` warns; equal or either absent is silent.

### Harness

The fixture boards mirror the payload: `scripts/sync-fixture-boards.sh --check` must pass after the
bump, and `scripts/verify-payload-version.sh` must see 67.

## Out of scope

- An implementer field (ADR 0023 names the evidence that would reopen it).
- `depends_on` across boards (ADR 0018 — stays free text).
- Per-group write permissions (ADR 0018 — a narrower audience needs its own repository).
- Any team's own rollout — its board, groups, pilot members and dates. That belongs on that team's
  board, never in this repository (standalone rule).
