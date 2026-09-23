# Handoff — coordinating work nobody owns alone

A **handoff board** is a directory of markdown documents, committed to git, that answers one
question: _who is working on what, right now, and what did they find out?_

It exists because the usual answers do not survive. A branch name says nothing about intent. A
ticket goes stale the moment the work moves. And a chat transcript — where most of an agent's
reasoning actually lives — is gone the next session. The board is the part that persists.

**[Open the lifecycle diagram](diagrams/handoff-lifecycle.html)** for the shape of it — filed,
claimed, and the three ways a claim ends.

The suite is nine skills, but you meet them in an order. Read the situations below and stop when
one matches yours.

---

## Situation 1 — two agents keep clobbering each other

This is the one the board was built for. Two sessions, or two agents, or you and a colleague, edit
the same code and neither knows what the other is mid-way through.

```text
handoff list                                  # what is open, and who holds it
handoff claim rbac-gap "tightening the tenant check"
# ... work ...
handoff release rbac-gap --status open "parser done, wiring the CLI next"
```

The **lease** is the whole mechanism. `claim` takes one, `release` drops it, and **an attempt to
edit a handoff document you do not hold is blocked by a hook**. Leases expire on a TTL so a crashed
session does not block the board forever, and a stale one is reclaimable by whoever needs it next.

Two things surprise people:

- **The lease protects the document, not the code.** Nothing stops another process editing
  `src/auth.ts`. What the board gives you is the knowledge that someone is in there, and a place
  for them to say what they found. Treat it as coordination, not as a file lock.
- **It only excludes another _machine_ when the board has a git remote.** The lease primitive is
  `git push` used as a compare-and-swap ([ADR 0002](../adr/0002-board-of-record-is-a-git-repo.md)). A board
  with no remote is versioned, not shared, and two people on it will silently overwrite each other.

Install it with [`setup-handoff`](../../skills/engineering/setup-handoff/SKILL.md); the day-to-day
discipline is [`run-handoff`](../../skills/engineering/run-handoff/SKILL.md).

### Closing honestly

`done` is not a mood. It requires `--verified-by`, naming something a second person could go and
re-check:

```text
handoff release rbac-gap --status done --verified-by "npm test -- tenant; 14 passing"
```

The reason is worth internalising: across two real boards that motivated this rule, 144 documents
carried a verification _date_ and two carried retrievable _evidence_. A date is a field and can be
queried; a sentence in a log cannot. Evidence that names no command, file reference or commit is a
claim about your memory, and the tool says so.

When you stop without finishing, say which:

```text
handoff release rbac-gap --status open                              # more work remains
handoff release rbac-gap --status blocked --blocked-on schema-change   # waiting on something
handoff release rbac-gap --for-review "finished as far as I can tell"  # someone should look
```

---

## Situation 2 — you are handing a feature to a junior

A senior plans, a junior executes, and the work comes back for review. Both are on the board.

**Split the feature into a bundle.** A bundle is an orchestrator document that indexes its children
and holds no work of its own:

```text
handoff new tenant-isolation --orchestrator --children rbac-gap,audit-log,rate-limit \
  --title "Tenant isolation"
```

Size each child as a **slice**, not a layer. A slice has its own runnable `Verify`, lands as one
change without waiting on a sibling, and can be checked without another child's unfinished work.
"API, then UI, then tests" is three layers, none of which can be verified alone.

**Confirm the roster with the other person before you file it.** The CLI does not prompt — it runs
in agent shells with no terminal — so that confirmation is yours to ask for. A roster nobody agreed
to gets re-sliced after the work has started.

The junior then claims a child, works, and hands it back without closing it:

```text
handoff release rbac-gap --for-review "guarded the tenant switch; tests green"
```

The document stays `open` and stays on the board, gains `review: pending`, and drops its lease so
the reviewer can claim it. The row shows `⇤ review` in `handoff list` and `AWAITING REVIEW` on the
session banner, so the next agent reviews it instead of starting it again. The senior closes it the
ordinary way, with their own `--verified-by`.

### What the gate does and does not do

**It checks the evidence, not who wrote it.** Nothing stops the junior closing their own work. A
board has no roles ([ADR 0011](../adr/0011-boards-have-no-roles-and-trackers-attach-per-board.md)),
and the nearest handle — the lease — belongs to a _session_, not a person, so the same human in
tomorrow's session is a different session id. A rule keyed on that would fire on honest continuous
work and miss the dishonest case entirely
([ADR 0015](../adr/0015-the-review-gate-is-about-evidence-not-identity.md)).

What it does catch is a closure whose stated evidence merely restates the claim already in the
document. If you need real two-person enforcement, it belongs on the board's own repository —
branch protection requiring a review is the only layer that can actually tell two people apart.

### Sharing one board between two people

Two people sharing a board is the same install as a fleet of repos, read differently. Give the
board a remote, then decide whether you want one section or one each — see
[`register-cross-repo-handoff`](../../skills/engineering/register-cross-repo-handoff/SKILL.md).
Sections are a sub-index boundary, not an access boundary: everyone who can clone the board reads
all of it.

---

## Situation 3 — the work is leaving the board

A contractor, another team, or an AI tool without the protocol. They cannot claim a lease, so the
board's mechanism does not reach them. What travels instead is a **brief**.

```text
handoff export rbac-gap --to "Contractor"                    # a file to send
handoff export rbac-gap --to-issue                           # an issue in the team's tracker
handoff export tenant-isolation --to-issue                   # a bundle: parent issue, one per child
```

Before you export anything, ask whether the handoff is **brief-able** — Context links symptom to
root cause, `Where` names something concrete, `Verify` is runnable by a stranger, and Decisions are
settled. Exporting a vague handoff does not make it less vague; it hands your uncertainty to someone
with less context than you had. [`delegate-handoff`](../../skills/engineering/delegate-handoff/SKILL.md)
is the judgment layer.

**Say whether a human will be watching.** `--executed-by hitl` means a person is present and their
evidence is an observation — a change reference, what they saw, when. `--executed-by afk` (the
default) means nobody is watching, so the evidence must be reproducible by someone who was not
there. The default is deliberate: assuming supervision that did not happen is the more expensive
mistake.

The reply comes back as a claim, never a verdict:

```text
handoff import --result briefs/rbac-gap-handoff.brief.md
handoff import --result --from-issue rbac-gap
```

`import` never writes `status`. It splices in what they reported and marks the document as awaiting
review. **You** still close it, with evidence you reproduced yourself — and handing their words
straight back as your `--verified-by` is refused outright, because that is the executor reviewing
itself.

A handoff marked `sensitivity: restricted` never leaves. `export` refuses it with no override.

---

## Situation 4 — teammates who never open the board

If the board declares an issue tracker, `handoff mirror` projects open work into it so people can
see it without learning any of this. Each handoff lands in the tracker of the repository it belongs
to — its **home** — so a team reads its own repository's issues:

```text
handoff mirror --dry-run           # what it would create, update, close, skip
handoff mirror                     # every tracker this board declares
handoff mirror --repo acme-web     # just one of them
```

An issue carries the title, the labels and `## Current state`. `## Context` and `## Verify` go out
only where that tracker asked for `"projection": "full"`, and your ruled-out options, notes and
evidence never leave the board — the board is the record, the issue is the window into it.

It is **one way**. Issues carry a hidden marker, the board is never written from the tracker, and an
edit made in the tracker is overwritten on the next run. Intake was rejected deliberately: letting a
tracker issue write the board makes the tracker a second source of truth and demands conflict
resolution the board does not have.

The consequence people trip on: **an issue closed out there does not close the handoff here.** That
is drift. The mirror reports it, writes a generated `TRACKER-DRIFT.md`, and still exits zero —
status changes on the board, with evidence, and nothing else does it.

On a **public** repository the mirror refuses unless that tracker opts in _and_ each document is
marked `share: public`
([ADR 0013](../adr/0013-a-tracker-publishes-to-a-public-repository-only-by-double-opt-in.md)).
Publishing cannot be undone, so it asks twice. Every tracker is asked for its visibility before any
of them is written to, so one public repository stops the whole run rather than half of it.

The second consequence: **who acts next is a label, not a move.** A handoff's issue stays in its home
repository for life. When the next step belongs to another team, flip the `audience` for a quick
hand-back, or — when that team really owns the work — file it as its own handoff homed in their
repository (`handoff new ID --home acme-web --after THIS_ID`), so it appears in the tracker they
actually watch.

---

## Situation 4b — several maintainers, one project

One board mirrors into a tracker. Each issue records which board wrote it, and a second board
mirroring into the same repository refuses rather than opening duplicates — two boards writing one
tracker is two sources of truth, and leases on one board do not restrain the other.

So a team shares **one board** — a private repository everyone clones — and each maintainer keeps a
**draft board** of their own for work that is not ready to be seen:

```text
handoff new spike-rate-limits --title "Spike — rate limits"     # on your draft board
handoff move spike-rate-limits --to ../workspace/.agents/handoff
```

A draft board never mirrors. It holds one person's thinking; the shared board holds what the team
coordinates on; the repositories' issues hold what everyone else needs to see. A board also stays
inside one organization — its trackers must all share one owner, and its own remote too — so work
for another organization gets its own board rather than a section on yours.

---

## Situation 5 — this session is about to run out of context

File a **standalone** document. It needs no lease, is freely editable, and is listed apart from open
work:

```text
handoff new auth-rewrite-brief --standalone --title "Auth rewrite — compaction brief"
```

Write what the transcript holds and the code does not: the decisions you made and why, the
approaches you **ruled out** so the next agent does not re-walk them, what you were mid-way through,
and the exact next step. Anything already in a commit or diff gets a path, not a paste.

**Solo continuity is not a handoff.** Carrying your own work into tomorrow — a scratch to-do list,
where you stopped — needs no lease and no board. File a handoff when the work crosses a boundary:
another session picks it up, another repo has to act, or it must survive you. A board full of
private reminders is a board nobody can read for the work that actually needs coordinating.

---

## The pieces, and which skill owns each

| Piece                                    | Skill                                                                                          |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Install the board and wire the hooks     | [`setup-handoff`](../../skills/engineering/setup-handoff/SKILL.md)                             |
| Claim, work, release                     | [`run-handoff`](../../skills/engineering/run-handoff/SKILL.md)                                 |
| Hand work to someone outside the board   | [`delegate-handoff`](../../skills/engineering/delegate-handoff/SKILL.md)                       |
| Several repos or people on one board     | [`register-cross-repo-handoff`](../../skills/engineering/register-cross-repo-handoff/SKILL.md) |
| Something is wrong with the board itself | [`repair-handoff`](../../skills/engineering/repair-handoff/SKILL.md)                           |

## When it misbehaves

Run [`repair-handoff`](../../skills/engineering/repair-handoff/SKILL.md). It smoke-tests the CLI
first, then re-checks and repairs the wiring and the board state — index drift, orphaned leases, a
section that will not resolve, a delegated handoff that never came back.

Two states that look like bugs and are not:

- **"This doc is schema N and this CLI understands M."** The document carries fields your CLI does
  not know, and writing it would silently drop them. Re-run `setup-handoff`, then `handoff migrate`.
  Reading keeps working throughout.
- **A `verify:` command that did not run.** Commands in documents are never executed automatically —
  a cross-repo document is untrusted. The tool prints it; you run it.
