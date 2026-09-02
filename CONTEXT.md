# Agent Skills

A collection of reusable, model-agnostic capability packs that wire any repository for AI
coding assistants. The vocabulary below is the one this repo's skills install into other
repos — get a term wrong here and it is wrong in every consuming project.

## Skills

**Skill**:
A directory under `skills/` whose `SKILL.md` frontmatter tells an assistant _when_ to load
it and whose body tells it _how_. The unit this repo ships.
_Avoid_: plugin, module, command

**Payload**:
The artifacts a skill copies into a target repository — CLI, templates, hooks, config. What
can drift from the skill that wrote it.
_Avoid_: install, bundle, assets

**Harness**:
The per-skill evaluation workspace — fixtures, cases, and a grader wrapping the skill's
read-only verify script.
_Avoid_: test suite, eval

## Board

**Board**:
The directory of handoff documents, leases, and generated index that a group of sessions,
agents, or repositories coordinates through. The board of record is a git repository with a
remote.
_Avoid_: tracker, backlog, queue

**Shared board**:
A board owned by no member repository, coordinating several. Distinguished from an
**in-repo board**, which lives inside the single repository it serves.

**Group**:
A named partition of a shared board, holding one set of peer repositories. A board may have
many; a board with one is the ordinary case.
_Avoid_: team, workspace, namespace

**Section**:
Where a group's documents physically live on the board — a subfolder or an id prefix. A
group's layout, not the group itself.

**Handoff**:
One unit of coordinated work, or one self-contained reference document, recorded as a single
markdown file with frontmatter.
_Avoid_: ticket, issue, task, card

**Lease**:
The exclusive hold one session has on a handoff while working it. On a board with a remote
it is enforced by a compare-and-swap push and expires on a TTL stamped from commit time.
_Avoid_: lock, assignment, ownership

**Claim**:
Taking the lease. **Release** is giving it back with a status. Neither is the lease itself —
one handoff has many claims over its life and one lease at a time.

**Gate**:
The tool-side hook that refuses an edit to a handoff document the editing session does not
hold the lease for.
_Avoid_: guard, check

**Review gate**:
The separate hold on a result reported by someone outside the board, requiring a reader
other than the executor before the handoff can close. Unrelated to the edit gate.

## Document

**Type**:
A handoff's **lifecycle** declaration — whether it needs a lease, is claimable, and archives
on close. One of `coordination`, `standalone`, `orchestrator`.

**Role**:
What a `standalone` document _is for_ — steering, spec, reference, brief archive. Role does
not change lifecycle; type does. A steering document and a porting guide share a type and
differ in role.

**Orchestrator**:
A handoff that indexes a bundle of children and holds no work of its own. Its children table
is generated; its roster is not.

**Current state**:
The rewritable section saying where a handoff stands right now. Distinguished from
**Activity**, the append-only one-line-per-event log. A reader should never have to replay
Activity to learn Current state.

**Evidence**:
What a closing session recorded to show it verified against live code — a command and its
output, or a file reference it checked. Persisted as a field, not as prose.
_Avoid_: proof, justification

**Brief**:
The self-contained document exported for an executor with no board access, carrying its own
contract and a result block. Not a handoff — it has no lease and cannot set status.

**Depends on**:
A structural prerequisite: this cannot _start_ before that lands. Board ids only.
Distinguished from **blocked on**, which is the reason someone _stopped_ and is reserved for
what the board cannot model.

**Sensitivity**:
How the tooling must handle a document — whether it may be exported, delegated, or shown
without a banner. A handling flag, never an access boundary; board membership is the access
boundary.

**Schema**:
The version of the document format. Distinguished from **payload version**, which is the
version of the installed tooling. They move at different rates and only schema triggers
migration.

## Delegation

**Delegate**:
To dispatch scoped work to a cheaper agent running as a separate process, under a consent
gate. Distinguished from **export**, which sends a brief to an executor outside the board
entirely.

**Executed by**:
Who actually did the work behind a closure — this session, a delegated agent, or an offline
brief. It determines how much independent review the evidence needs.
