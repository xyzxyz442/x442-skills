---
status: proposed
date: 2026-09-19
---

# The review gate is about evidence, not identity

ADR 0011 built the delegation path for one shape: a handoff leaves the board, an outside executor
returns a result, and a reviewer closes it. A real senior-to-junior loop needs three things that
path does not have. A collaborator **on** the board cannot say "finished, awaiting your steering"
without either losing the signal or archiving the doc. A bundle is refused as a delegable unit by
one code path while two others treat it as one shareable thing. And an external team acting on live
systems produces evidence that is not a diff, which the close-time advice actively argues against.

We decided to widen the review gate to any handoff that asks for review, to make a bundle delegable
as a parent brief with one issue per child, and to record whether a human was in the loop. None of
it enforces **who** closes a handoff. The gate checks what the evidence says, because that is the
part a board with no roles can actually check. This extends ADR 0011 and follows the shape ADR 0014
established; it is bound by ADR 0013.

## Context

- **The review gate fires for exactly one writer.** `set_field "$f" review pending` appears once, in
  `import --result`. A collaborator who is on the board claims, works, and releases: `open` loses
  the "someone should look at this" signal entirely, and `done` archives the doc. The state a senior
  reviewing a junior's work needs — finished, not closed — has nowhere to live.
- **The evidence check is already keyed on the right field, and already has both arms.** `copied`
  fires when `review` is `pending` and `--verified-by` appears verbatim in the doc's result block.
  Where the work was delegated it **refuses**; otherwise it **warns**, and the code states why:
  "without a delegate there is no second party whose words these are, so the reviewer may
  legitimately have re-run the very same command and written it the same way."
- **That check cannot fire for on-board work as written.** It compares against `result_block`, which
  only exists once a delegate's result has been spliced in. On-board review work has no result
  block, so `copied` is always `0`. Widening the gate without widening the comparison would ship a
  hold with nothing behind it.
- **Three code paths disagree about a bundle.** `export --to-issue` dies on any orchestrator;
  `export_bundle` already renders one for the file-based path; and ADR 0014 projects a bundle to the
  tracker as a parent issue with its children linked as native sub-issues. The tracker therefore
  already knows the shape that delegation refuses to produce.
- **Evidence changes shape when a human is in the loop, and `executed_by` cannot say whether one
  was.** An infrastructure or devops team acting on live systems answers with a change-request
  reference and an observation, not a test run: `Where` names a cluster, not a `file:line`. The
  field exists precisely to say how much independent review a closure needs, but its only value —
  `delegate` — records **who** acted, and who acted does not answer the question. A contractor's
  agent grinding through a migration unattended and an engineer watching a change land are both
  "outside the board", and they need opposite amounts of scrutiny.
- **Boards have no roles** (ADR 0011). There is no identity model to enforce against. The nearest
  handle is the lease owner, and a lease is held by a _session_, not a person.

## Decision

- **`release --for-review` is the second writer of `review: pending`.** `status` stays `open`, the
  lease releases as it always does, and the existing marker in `list` and on the session banner
  starts covering on-board work. No new status and no new field: `review` is an existing field
  gaining a writer, so ADR 0003's rule for bumping the schema is not met.
- **`copied` falls back to `## Current state` when there is no result block.** The comparison that
  makes the gate meaningful keeps working for on-board review, using the account the author wrote
  of their own work. Same mechanism, same field, no new state.
- **Closing your own review-pending work is a warning, never a refusal.** This is the whole of the
  identity question and the answer is no. See Considered options for why the alternatives are worse
  than the gap they close.
- **`export --to-issue` accepts an orchestrator**, writing a parent brief plus one issue per child
  and linking them as sub-issues — the shape ADR 0014 already mirrors, so the tracker looks the same
  however a bundle got there. Each child carries its own `external_ref`, returns through its own
  `import --result`, and is reviewed on its own. Slices that were sized to land independently stay
  independently reviewable.
- **A delegated bundle leaves the mirror.** Every doc involved gains an `external_ref`, and the
  mirror already skips those as "linked elsewhere". One issue has one owner; nothing is projected
  twice.
- **A partial export is resumed, not rolled back.** If the third of four children fails to create,
  the run fails and leaves what it made. `external_ref` makes a re-run idempotent, exactly as the
  hidden marker does for the mirror. A bundle holding a `restricted` child refuses whole, matching
  the mirror's rule.
- **`executed_by` records whether a human was in the loop — `hitl` or `afk` — not who acted.** That
  is the axis the field was always trying to express. `hitl` means a person was present and the
  evidence is their observation: the change reference, what they saw, and when. `afk` means nobody
  watched, so the evidence has to be reproducible by someone who was not there.
- **Agent-executed work defaults to `afk`.** The default assumes nobody was supervising rather than
  assuming supervision that may not have happened, because the cost of the two mistakes is not
  symmetric: under-reviewing unwatched work is how a wrong change closes, while over-reviewing
  watched work costs a second look. The value is set when work is handed out rather than when a
  result arrives, so the brief can be shaped for it, and the import path preserves it.
- **The mirror projects it as a `mode:` label.** The document stays the source of truth and the
  label is a projection, exactly as `status:` and `type:` already are, so a teammate reading the
  tracker can see how a piece of work is being executed without opening the board.
- **Evidence guidance stays advisory either way.** No pattern is enforced on `--verified-by`.

## Considered options

- **A fourth status, `review`.** Rejected. It is the most legible option on the board, and it
  touches every status consumer: `list`, the generated index, the session banner, the mirror's
  `status:` labels, the verifier, release validation and `migrate`. That is a schema-visible change
  in everything but name, bought for a signal the existing `review` field already carries.
- **A separate verb, `handoff submit`.** Rejected. Two verbs for one moment — stopping work — whose
  lease semantics would then have to be defined and kept consistent forever.
- **Refusing a close by the session that asked for review.** Rejected, and this is the one worth
  spelling out. A session is not a person: the same human in tomorrow's session is a different
  session id, so the rule fires on the honest case of continuous work and misses the dishonest case
  entirely. It would also refuse a legitimate solo use — parking work under `--for-review` to read
  it again with fresh eyes — which is a discipline worth encouraging, not blocking. And it invents a
  role out of lease ownership, which ADR 0011 deliberately does not have. A rule people cannot
  satisfy honestly is satisfied dishonestly.
- **A single `executed_by: external` value for work done off the board.** Rejected, and this was
  the first draft of this ADR. It conflates two independent things — that an outside party acted,
  and that a human observed it — which come apart immediately in both directions. It also leaves the
  high-scrutiny case unnamed: unattended agent work is the thing most needing independent review,
  and "external" does not say it.
- **Enforcing an evidence pattern for HITL work.** Rejected. No pattern can enumerate every
  organisation's change-management artifact, and a `--verified-by` that must match a regex gets
  written to match the regex.
- **One issue for a whole delegated bundle.** Rejected. It collapses the slices back into a single
  deliverable, so review becomes all-or-nothing for work that was deliberately cut to land in
  pieces.
- **Keeping the refusal and removing `export_bundle`.** Rejected, though it is the other consistent
  answer: it resolves the three-way disagreement by shrinking rather than growing. A bundle is the
  unit a contractor is actually handed, and ADR 0014 has already made the tracker able to express
  it.
- **Intake — a tracker issue becoming a board handoff.** Rejected, and out of scope by design. It
  would make the tracker a second source of truth and demand the conflict resolution the board
  deliberately does not have. The mirror stays one way.

## Consequences

- **The gate can be walked through by the person who asked for it.** This is accepted, not
  overlooked. The board cannot tell people apart, and pretending otherwise would put a check in the
  code that reads as enforcement while enforcing nothing. What the gate does guarantee is that
  closing on a restatement of the original claim is called out.
- **Real two-person enforcement has a home, and it is not this CLI.** A board hosted on GitHub can
  require a review on its own repository through branch protection, which is the only layer that can
  actually distinguish two people. That is deliberately outside this ADR.
- **`copied` gains a second comparison source**, so a reviewer who legitimately re-runs a command
  and writes it up the same way will see the warning more often than before. It is a warning.
- **Delegating a bundle is now a multi-write operation** and can fail part-way. The failure mode is
  a partially exported bundle that a re-run completes.
- **`executed_by` changes meaning, and that is a migration of understanding rather than of data.**
  Today the field is absent, meaning this session acted, or `delegate`, meaning someone off the
  board did. Both readings are about **who**. Existing documents keep their values and stay valid;
  what changes is that new writers record **whether a human was in the loop**. Every consumer
  comparing against `delegate` must be re-read against that axis rather than mechanically extended.
- **The managed label prefixes gain `mode:`, in two places.** `MANAGED` is declared in both
  `mirror_plan` and `mirror_links` and the two must not drift; a prefix listed in one and not the
  other reconciles inconsistently. Labels outside the managed set are still a person's and survive.
- **No schema bump.** `review` and `executed_by` are existing fields gaining a writer and a value.
  Documents written before this change are unaffected and need no migration.
- **`CONTEXT.md` moves**: **Review gate** widens beyond outside executors, and **Executed by** is
  re-cut along the human-in-the-loop axis rather than the who-acted one.

## Sources

- `docs/adr/0011-boards-have-no-roles-and-trackers-attach-per-board.md` — no roles, delegation, the
  one-way mirror, `external_ref`.
- `docs/adr/0013-a-tracker-publishes-to-a-public-repository-only-by-double-opt-in.md` — the share
  gate every export and link respects.
- `docs/adr/0014-a-bundle-projects-as-native-sub-issues-and-the-adapter-owns-the-identifier-gap.md`
  — the parent/sub-issue shape a delegated bundle reuses.
- `docs/adr/0003-schema-versioning-and-migration.md` — the rule that a new _field_ bumps the schema,
  which neither of these changes meets.
