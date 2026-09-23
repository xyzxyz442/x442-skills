# Handoff — coordinating work nobody owns alone

A **handoff board** is a directory of markdown documents, committed to git, that answers one
question: _who is working on what, right now, and what did they find out?_

It exists because the usual answers do not survive. A branch name says nothing about intent. A
ticket goes stale the moment the work moves. And a chat transcript — where most of an agent's
reasoning actually lives — is gone the next session. The board is the part that persists.

Two diagrams give the shape of it:

- **[The lifecycle](diagrams/handoff-lifecycle.html)** — filed, claimed, in progress, and every way
  a claim ends: released open, blocked, delegated, handed back for review, or closed with evidence.
- **[The topology](diagrams/handoff-topology.html)** — a team working one shared board split into
  group sections, a draft board feeding it, each section mirrored into its home repositories'
  trackers, and an optional shared library owned by someone else, on a board of its own.

The suite is five skills, but you meet them in an order. If you want to know whether the board fits
your problem at all, start with [Recommended use-cases](#recommended-use-cases). Otherwise read the
situations below and stop when one matches yours.

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

### Keeping the others informed while you hold it

On a board with a remote, other machines see your progress only when it is pushed, and a release is
the last push. For long work, **checkpoint** at a natural stopping point — a passing test, a design
decision, before a long build:

```text
handoff checkpoint rbac-gap "Parser written and tested; wiring the CLI next."
```

It rewrites `## Current state`, secret-scans it, commits and pushes, and **keeps your lease**. The
section is rewritable on purpose: it is where the work stands, not a log. `## Activity` is the log.

When an approach fails, record it so the next session does not walk it again:

```text
handoff release rbac-gap --status open --ruled-out "Inline cache — stale after archive — selftest run"
```

`## Ruled out` is append-only. Read it before you pick an approach, not after an hour on one it
already lists.

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

A `blocked` release names what it waits on, and the id is checked: a blocker that does not exist
would leave the handoff blocked forever. When that blocker closes `done`, the handoff is surfaced as
newly unblocked at the next session start.

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

### Naming who reviews it

`AWAITING REVIEW` with no name is addressed to every reader, and therefore to none. Name the
reviewer by their **tracker handle** — the login, not a display name — when you file the work or
when you hand it back:

```text
handoff new rbac-gap --title "RBAC gap" --reviewer alice
handoff release rbac-gap --for-review --reviewer alice "guarded the tenant switch; tests green"
```

Each person sets their own handle once, uncommitted, in `.agents/handoff.local.json`:

```json
{ "handle": "alice" }
```

Alice's session banner then says `AWAITING YOUR REVIEW` instead of the generic marker. On a board
with a tracker, the reviewer becomes the issue's **assignee** — set when the issue is created and
never reconciled afterwards, so reassigning it in the tracker is a legitimate act that survives
every later mirror run.

The reviewer is **a pointer, not a gate**
([ADR 0016](../adr/0016-a-reviewer-is-a-pointer-not-a-gate.md)). Nothing compares the person
closing the handoff against it.

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
status changes on the board, with evidence, and nothing else does it. `handoff list` and the
session banner mark the affected handoff, and `handoff list --tracker` asks the tracker for the same
answer live, at the cost of a round trip. Clear drift by closing the handoff with evidence, or by
reopening an issue closed by mistake — never by editing the report.

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

Read a handoff by its id, never by a path you wrote down — a path goes stale when a doc is archived
or moved to another board:

```text
handoff show auth-rewrite-brief                  # the whole doc, live or archived
handoff show rbac-gap --section Verify           # one section
```

**If you hold a lease when the context is compacted**, what you were working on comes back two ways,
depending on the tool. On Claude Code the session-start hook re-injects each held handoff's Current
state, Verify, Decisions and Ruled out. On Gemini CLI and Copilot CLI nothing does, so run
`handoff show ID --section …` for those sections yourself before touching the work again
([ADR 0012](../adr/0012-context-returns-after-compaction-and-ruled-out-is-not-schema.md)).

**Solo continuity is not a handoff.** Carrying your own work into tomorrow — a scratch to-do list,
where you stopped — needs no lease and no board. File a handoff when the work crosses a boundary:
another session picks it up, another repo has to act, or it must survive you. A board full of
private reminders is a board nobody can read for the work that actually needs coordinating.

---

## Situation 6 — the work has an order, or waits on someone off the board

Two fields carry what boards otherwise bury in prose. **`depends_on`** holds board ids only and
means _this cannot start before that lands_. **`blocked_on`** is free text for what the board cannot
model:

```text
handoff new prod-backfill --title "Backfill tenant ids — prod" --env prod --after schema-change
handoff release prod-backfill --status blocked --blocked-on "external: platform team — CHG-4471"
```

- `--after` writes `depends_on`. `claim` **warns** when a prerequisite is still open, then gets out
  of the way. Work legitimately runs out of order (a production incident fixed before the
  pre-production backfill), and a rule that refused it would be routed around. If you work past a
  prerequisite, say so in `## Current state`.
- `--env` records where the work lands. There is deliberately no command that fans a dev fix out to
  prod: the prod follow-up is different work with different evidence, and it should be filed on
  purpose, as above.
- The `external:` prefix is how you wait on a team that is not on the board — infrastructure, a
  vendor, another company. Put the change request in the text, so the wait can be audited later.

If the work is planned under a ticket in a sprint tool, point at it rather than copying the plan:

```text
handoff new rbac-gap --title "RBAC gap" --ref ABC-123
handoff list --ref ABC-123
```

The reference must match the tracker's `refPattern`, and a board with no tracker refuses `--ref`.
Nothing calls the sprint tool. Planning stays there, and the board records the work.

---

## Recommended use-cases

The board is worth its overhead when work **crosses a boundary**: another session, another agent,
another repository, another person, or a reader who never opens the board. The patterns below are
the ones it was shaped around. Each names what to reach for first.

| Scenario                                                           | Pattern                                    | Reach for                                                  |
| ------------------------------------------------------------------ | ------------------------------------------ | ---------------------------------------------------------- |
| Two agents or worktrees on one repository at once                  | One handoff per unit, claim before editing | `list`, `claim`, `release`                                 |
| A bug found in the middle of other work                            | File it, even if you fix it on the spot    | `new`, then `release --status done --verified-by`          |
| A feature split between a planner and an executor (human or agent) | Bundle of slices, hand-back for review     | `new --orchestrator`, `release --for-review --reviewer`    |
| An API change that other repositories must adopt                   | One child homed in each repository         | `new --home`, `--after`, `mirror`                          |
| A dev fix that needs a production follow-up owned by another team  | Separate prod handoff, external blocker    | `new --env prod --after`, `--blocked-on "external: …"`     |
| Work for a contractor or an AI tool without the protocol           | Brief out, claim back, you close it        | `export --executed-by`, `import --result`                  |
| A security fix that must not leave this session                    | Restricted handoff                         | `new --sensitivity restricted`                             |
| A long session near its context limit                              | Standalone compaction brief                | `new --standalone`, `show`                                 |
| Teammates who live in their repository's issues                    | One-way mirror into the home tracker       | `mirror --dry-run`, `mirror`                               |
| Several maintainers, each with half-formed ideas                   | Draft board per person, one shared board   | `move --to`                                                |
| A team whose repositories fall into separate groups                | One board, one section per group           | `register-cross-repo-handoff`, `HANDOFF_GROUP`             |
| A change that needs a shared library owned by another organization | Its own board; wait on it as external      | `--blocked-on "external: …"`, `export`, `move --to-remote` |

### Two agents on one repository

You run two sessions in separate worktrees — one on a parser, one on the CLI that calls it. Without
the board, the second session discovers the first one's half-finished change by tripping over it.

```text
handoff new parser-rewrite --title "Parser — accept quoted keys" --severity medium
handoff new cli-flags --title "CLI — expose --strict" --after parser-rewrite
handoff claim parser-rewrite "session A"
```

Session B runs `handoff list`, sees `parser-rewrite` held and `cli-flags` waiting on it, and either
claims something else or claims `cli-flags` knowing it is working ahead of its prerequisite.
Session A checkpoints as tests go green and releases `done` with the test command as evidence.

### An API change that other repositories must adopt

`acme-api` renames a field that `acme-web` and `acme-worker` both read. Each team watches its own
repository's issues, so the work is filed as a bundle whose children are homed where they land:

```text
handoff new rename-tenant --orchestrator --children rename-expand,rename-web,rename-worker,rename-contract \
  --title "Rename tenant field"
handoff new rename-expand --title "Dual-write tenant_id" --home acme-api
handoff new rename-web --title "Read tenant_id in the web client" --home acme-web --after rename-expand
handoff new rename-worker --title "Read tenant_id in the worker" --home acme-worker --after rename-expand
handoff new rename-contract --title "Drop the old field" --home acme-api --after rename-web
handoff mirror --dry-run
```

This is expand–contract: each child keeps the code working, so each is a slice with its own
`Verify`. Confirm the roster with the teams before you file it. The mirror then opens one issue in
each home repository, and no issue moves when the work passes between teams.

### A contractor, supervised or not

A contractor fixes a flaky integration test on a live staging environment while you watch the call.
The evidence owed is an observation, so say a human was present:

```text
handoff export flaky-ingest --to-issue --executed-by hitl
# ... they work, and reply on the issue ...
handoff import --result --from-issue flaky-ingest
handoff claim flaky-ingest "reviewing the contractor's result"
handoff release flaky-ingest --status done --verified-by "ingest suite green 20/20 runs, commit 4f2a9c1"
```

Had nobody been watching (`--executed-by afk`, the default), the closure would need evidence you
reproduced yourself. Either way, pasting their report back as `--verified-by` is refused.

### A team, several groups, and a library owned elsewhere

Alice and Bob work the application repositories, `acme-api` and `acme-web`. Carol maintains
`acme-infra`. All three repositories belong to one organization, so they share **one board** — a
private repository everyone clones — declared as two groups in `.agents/handoff.json` and synced
with [`register-cross-repo-handoff`](../../skills/engineering/register-cross-repo-handoff/SKILL.md).
Each group becomes a **section** with its own sub-index:

```text
HANDOFF_GROUP=app handoff list          # only the app section; the hooks set this for you
HANDOFF_GROUP=platform handoff list     # only the platform section
```

The board root `INDEX.md` rolls every section up. Sections are a sub-index boundary, not an access
boundary: anyone who can clone the board reads all of it. Draw the trust boundary with the board,
not with a group.

Inside the app section it is Situation 2: Bob claims a child, hands it back with
`--for-review --reviewer alice`, and Alice closes it with her own evidence. Alice sketches ideas on
her own draft board and moves one across when the team should see it. Each section mirrors into its
own repositories' issues, by each handoff's home.

Now the app needs a fix in `acme-lib`, a shared library another organization owns. That library is
**a different trust boundary**, and the board refuses to pretend otherwise: every tracker on a board
shares one owner, and `move` to a board under a different owner is refused unless you name it. The
cross-boundary work is therefore handled in one of three ways, cheapest first:

1. **Wait on it.** File the fix with the library's maintainers through their own process, and block
   on it by name. `depends_on` cannot cross boards, so an external blocker is the honest record:

   ```text
   handoff release adopt-lib-fix --status blocked --blocked-on "external: acme-lib — issue 212"
   ```

2. **Send a brief.** When they will do the work but are not on your board, `export` a brief, as in
   Situation 3. Nothing in it should be material your organization would not hand them.
3. **Move it.** When the work genuinely belongs on their board and the user has confirmed the
   material may go there, name their owner explicitly:

   ```text
   handoff claim lib-null-check "moving it to the library board"
   handoff move lib-null-check --to ../acme-lib/.agents/handoff --to-remote github.com/acme-lib-org
   ```

   A `sensitivity: restricted` handoff never crosses a differing remote, even when named.

If the project never touches such a library, none of this applies: one owner, one board, and as many
groups as the team needs.

### A security fix

A handoff carrying `sensitivity: restricted` still sits on the board where everyone with access can
read it. What the flag changes is where the work may go: `export` refuses it with no override, a
delegated agent is refused the brief, and the mirror never projects it. Do the work in the session
that found it.

### When not to use it

- **Solo continuity.** Carrying your own work into tomorrow needs notes, not a lease.
- **A one-line change nobody else is near.** A claim and a release are ceremony; when no second
  worker exists, they buy nothing.
- **Planning.** Sprint scope, estimates and priorities stay in the sprint tool. The board links to
  them with `--ref` and records execution.
- **Access control.** Sections and `restricted` are handling rules, not permissions. Anything a
  board-reader must not see does not belong on the board.

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
