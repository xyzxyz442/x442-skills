---
status: accepted
date: 2026-09-19
---

# A reviewer is a pointer, not a gate

ADR 0015 gave the board a way to say "finished, not closed" — `release --for-review` sets
`review: pending`, the doc stays live, and the lease drops so a reviewer can claim it. It hands the
work back to **nobody in particular**. Every reader sees the same `AWAITING REVIEW`, which is
addressed to everyone and therefore to no one, and nothing in the system tells a human that work is
waiting on them.

We decided to add one optional field, `reviewer`, holding a tracker handle, and to project it as the
tracker's assignee. It changes who is _told_. It changes nothing about who may _close_. This extends
ADR 0015, reuses ADR 0014's assign-on-create rule, and is bound by ADR 0013.

## Context

- **`audience` cannot carry this.** It names a **repo**, resolved through the board registry's
  `rootCommit` attestation, and there is no equivalent attestation for people. ADR 0015 already
  declined to flip `audience` to the reviewer for exactly this reason, and recorded the gap: "Naming
  a reviewer is a real gap, tracked separately — it needs a new field and therefore a schema bump."
- **A tracker assignee is the only mechanism in the system that reaches a person.** A `status:`
  label reaches whoever is already looking. An assignee generates a notification.
- **Boards have no roles** (ADR 0011). There is no identity model, and the nearest handle — the lease
  owner — is a _session_, not a person.
- **A new field is ADR 0003's trigger for a schema bump.** This is the cost, and it was the reason
  the work sat unstarted: the handoff proposing it said "do not land it alone" and named another
  schema-3 candidate to batch with.
- **That batch partner does not exist.** `hitl-external-evidence-handoff` closed `done` with "No
  schema bump" — `executed_by` was already a schema 2 field gaining a writer. Its one leftover gap,
  an `executed_by` placeholder in the brief template, is a payload asset change and needs no bump
  either. Nothing else on the board is a schema-3 candidate.
- **The measured migration cost is small, and mostly pre-existing.** A census of every board on the
  filing developer's machine outside test fixtures found 9 board directories, 7 holding documents,
  607 documents in total — of which **347 are archived and out of scope by rule**, since ADR 0003
  migrates the live section only. Exactly **one** board is actually at schema 2, with **8 live
  documents**. The other six are already stranded at schema 1 or pre-schema: they are behind today,
  they need a `setup-handoff` re-sync regardless of this change, and schema 3 does not worsen them.
  The fleet drift that looked like this feature's cost is a debt that already exists.

## Decision

- **It is a pointer. Nothing compares the closer against it.** No `release` path reads `reviewer` to
  decide anything. This is not an oversight to be fixed later — see Considered options, which
  pre-refuses it.
- **It stores a tracker handle, not a display name.** A display name cannot be assigned and cannot
  be verified. `result_from` already holds a login, so there is precedent, and it avoids inventing a
  people registry.
- **It is validated, not folded.** Every other free-text frontmatter value passes through
  `fold_colons`, which turns a `:` into an em dash so the unquoted YAML stays parseable. That is
  right for prose and wrong for an identifier: a silently mangled handle is not a cosmetic blemish
  but an assignment to a user who does not exist. A leading `@` is accepted and stripped, since that
  is how people write handles and storing both spellings would make two docs naming one person
  compare unequal. Anything with whitespace, a colon, a quote, a comma, a bracket or a `#` is
  refused by name.
- **It is set where the answer is known** — `new --reviewer` (the senior files the work and will
  review it) and `release --for-review --reviewer` (decided at hand-back). `--reviewer` on a plain
  `open`/`blocked`/`done` release is refused rather than ignored, so a mistyped hand-back does not
  silently lose the handle.
- **It applies to coordination handoffs only**, scoped exactly as `--for-review` is. A bundle holds
  no work of its own and is never claimed; a standalone doc has no lifecycle to review.
- **Assigned on create, never reconciled** — ADR 0014's existing rule for links, applied to the
  assignee for the same reason. Reassigning in the tracker is a legitimate human act; a board that
  reconciled it would fight the person every run and always win. It follows that `assignees` is
  absent from the mirror's sameness comparison, so a reassignment is not drift and does not even
  mark the issue as needing an update.
- **Assignment is a separate, non-fatal step in the adapter.** `gh issue create --assignee` fails the
  **whole create** when a handle cannot be assigned — a typo, or someone who is simply not a
  collaborator. That would trade a shared issue for a missing one, which is the wrong way round: the
  issue is the point and the assignment is a courtesy. So the issue is created first, assigned
  second, and a failed assignment is reported on stderr while the run still exits zero.
- **The public gate is ADR 0013's, and there is exactly one copy of it.** `mirror_survey` already
  drops any doc not marked `share: public` before it is rendered on a public repository, so a handle
  cannot reach a public tracker. No second test is added at the projection site; a second copy could
  only diverge, and the divergence would leak a login.
- **The banner distinguishes "awaiting review" from "awaiting YOUR review"**, matching `reviewer`
  against `handle` in `handoff.local.json` — this developer's own login, uncommitted and
  per-machine. `handle` is the one piece of _identity_ the local layer may set, and the exception
  proves the rule: every other local key answers "which board, which section" because board-wide
  policy and _team_ identity stay committed. Nothing is authorised by it, so an inaccurate value
  costs one wrong marker.
- **Schema 2 to 3.** `reviewer` is optional; absent means "nobody named", which is what every
  existing doc means and still means. Migration writes the stamp and nothing else.

## Considered options

- **Refuse a close by anyone who is not the named reviewer.** Rejected, and rejected _in advance_ —
  this field will attract the request, so the refusal is recorded here rather than left to accrete.
  Boards have no roles (ADR 0011) and ADR 0015 already rejected refusing a close by the session that
  asked for review: a session is not a person, so such a rule fires on honest continuous work and
  misses the dishonest case entirely. The failure modes are asymmetric — a stale reviewer on a
  pointer is merely wrong, while a stale reviewer on a gate is a deadlock, and teams rotate. The
  review gate that does exist checks **evidence**, which is the part a board with no roles can
  actually check.
- **Overload `audience`.** Rejected — it names a repo, and cross-repo brief resolution depends on
  that; a person there would break `board_repo_entry()` and the registry's `rootCommit` attestation.
- **A GitHub review request instead of an assignee.** Rejected — review requests exist only on pull
  requests, not on issues, and the mirror projects issues.
- **The `x_*` extension namespace, to dodge the schema bump.** Rejected — ADR 0003 scopes that to
  downstream forks, not to upstream features.
- **Wait and batch the bump with another schema-3 candidate.** Rejected on measurement, having been
  the filing recommendation. No such candidate exists or is foreseeable, so "batch it" resolves to
  "wait indefinitely"; and the cost it was protecting against is one board of 8 live documents.
- **A people registry mapping names to handles.** Rejected — it is a second source of truth about
  who someone is, for a field whose only consumer is an adapter that already speaks handles.
- **Infer a reviewer during migration** from the last holder, the closer, or the delegate. Rejected
  — ADR 0003 forbids migration inferring values, and this is why: a reviewer nobody appointed is a
  false claim about who is accountable, and it would be projected outward as a real assignment.

## Consequences

- One unmeasured cost remains, and it is the honest argument against this timing: the board has a
  remote, so a machine holding an older CLI refuses to write after the bump until it re-runs the
  installer (ADR 0003's refuse-backward rule, gated by ADR 0005). That cannot be seen from one
  machine.
- A board whose tracker is a sprint tool, or that has no tracker, gets the banner and `list` half of
  this and nothing else. The field is still worth setting: it says who to ask.
- An adapter that ignores the new optional `assignees` field simply is never asked again — the same
  shape as `children` in ADR 0014.
- **An outbound brief does not carry the handle**, because the brief renders named sections rather
  than copying frontmatter. That is the right default and is now depended upon: a login is personal
  data, and an outside executor has no use for the name of the person who will review their work.
  Verified rather than assumed — `export` on a doc naming a reviewer produces a brief containing
  neither the field nor the handle.
- Because assignment is never reconciled, the board's `reviewer` and the tracker's assignee may
  legitimately disagree. The tracker wins in practice and the board is not corrected. This is the
  intended asymmetry, not drift in ADR 0014's sense, and nothing reports it.

## Sources

- `docs/adr/0003-schema-versioning-and-migration.md` — the rule that a new field bumps the schema,
  that migration moves structure only, and that it reaches the live section alone.
- `docs/adr/0011-boards-have-no-roles-and-trackers-attach-per-board.md` — no roles, the one-way
  mirror, `external_ref`.
- `docs/adr/0013-a-tracker-publishes-to-a-public-repository-only-by-double-opt-in.md` — the share
  gate this field inherits rather than re-implements.
- `docs/adr/0014-a-bundle-projects-as-native-sub-issues-and-the-adapter-owns-the-identifier-gap.md`
  — assign/link on create and never reconcile; an adapter that reports a capability gets it.
- `docs/adr/0015-the-review-gate-is-about-evidence-not-identity.md` — `release --for-review`, and
  the recorded gap this ADR closes.
- https://cli.github.com/manual/gh_issue_edit — `--add-assignee`, applied after create.
- https://docs.github.com/en/rest/issues/assignees — only users with push access can be assigned;
  an invalid assignee is silently dropped or rejected, which is why the step must survive failure.
