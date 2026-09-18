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

**Trust boundary**:
The line between organizations whose material must not mix — an employer, a client, a person's
own projects. One board per trust boundary. Read from a board's git remote host and owner, not
declared.
_Avoid_: tenant, account

**External tracker**:
The one project tracker a board links to — a sprint tool or an issue tracker — where planning
lives. Linked by reference; mirrored only where it is the team's issue backlog. Never the board.
_Avoid_: board, backend, sync target

**Sub-issue link**:
A **bundle**'s parent/child relationship expressed in the tracker's own native form, so a
progress bar appears where the checklist was inert text. Projected from an orchestrator's
roster only, and only onto issues the mirror itself made. Distinguished from the **checklist**,
which states the same relationship portably and remains alongside it.
_Avoid_: nesting, linked issue, epic

**Tracker drift**:
A divergence between an issue's state and its handoff's, once they disagree — the issue closed
while the handoff is still open. It is reported, never reconciled — status changes only on the
board, with evidence — and is recorded in a generated file, not on the document.
_Avoid_: out of sync, conflict, stale mirror

A board a developer keeps for their own drafts is an ordinary board with no role of its own.
_Avoid_: personal board, private board, scratch board

**Local config**:
One developer's board and section choices for one checkout, never committed. Outranks the
repository's committed config. The user-level layer above both is read only when opted into.
_Avoid_: personal config, user config

**Move**:
Transferring a handoff's board of record to another board. The source keeps an archived
pointer; the handoff is never copied.
_Avoid_: copy, sync

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
one handoff has many claims over its life and one lease at a time. A **checkpoint** publishes
Current state while the lease is kept.

**Gate**:
The tool-side hook that refuses an edit to a handoff document the editing session does not
hold the lease for.
_Avoid_: guard, check

**Review gate**:
The hold on a handoff that is finished but not closed, asking for a reader before it can be
archived. Set by an imported result, or by the author with `release --for-review`. It checks the
evidence, not who wrote it: the board has no roles, so it cannot require a second person, and what
it does catch is a closure whose stated evidence merely restates the claim. Unrelated to the edit
gate.

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

**Ruled out**:
The optional, append-only section listing approaches that were tried and failed — each with why
and the evidence. Distinguished from **Decisions**, which says what to do and is read before
starting; Ruled out says what not to retry and is read when an approach looks tempting.
_Avoid_: dead ends, tried, rejected approaches

**Slice**:
One child of an orchestrator, sized so it has its own runnable Verify, lands as one change on its
own, and can be checked without another child's unfinished work. A vertical cut through the work,
not a layer of it.
_Avoid_: subtask, ticket, chunk

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

**Environment**:
The stage a piece of work targets. An open string, ordered per board by a **ladder** running
lowest to highest; an unlabelled document reads as the lowest. Naming an environment does not
duplicate the work — the same fix at two stages is two documents with two pieces of evidence.
_Avoid_: stage, deployment target, and `tier` **as a synonym for this**. `tier` is not a
reserved word — see **search tier**, which is a different concept in a different subsystem.

**Sensitivity**:
How the tooling must handle a document — whether it may be exported, delegated, or shown
without a banner. A handling flag, never an access boundary; board membership is the access
boundary. Distinguished from **redaction**, which it is often confused with — sensitivity is
_declared_ by a person about a whole document and decides whether content moves at all;
redaction is _detected_ from the content itself and decides what survives when it does. A
restricted document is refused outright and never reaches a redactor.

**Share**:
Whether a document's audience may be the public — declared on the document itself, and honoured
only when its board also allows a public tracker. Distinguished from **sensitivity**,
which decides how carefully the tooling handles a document at all: a restricted document is never
shared, and a normal one is not shared publicly unless someone marks it.
_Avoid_: public, visibility, published

**Schema**:
The version of the document format. Distinguished from **payload version**, which is the
version of the installed tooling. They move at different rates and only schema triggers
migration.

## Graph

**Search tier**:
What the graph's semantic search _can_ do in a repo, set by which vectors it holds —
**custom** (an external OpenAI-compatible provider), **local** (the built-in model), or
**keyword** (no vectors, name matching only). A property of the repo, not of a query.
Distinguished from **search mode**, which is what one query actually did. Unrelated to
**environment**, which is where work is deployed.
_Avoid_: search level, embedding quality, provider tier

**Search mode**:
What a single `semantic_search_nodes_tool` call actually used — `semantic`, `fts`, or
`keyword` — returned per call. A mode below the repo's **search tier** means the vectors did
not answer that query, which is the one case where falling back to `grep` is warranted.
_Avoid_: search type, fallback

**Provider**:
Which embedding backend writes and reads a repo's vectors. Three buckets, by transport, not
by vendor: **local** (in-process model), **openai-compatible** (anything speaking
`/v1/embeddings`), and **native** (a backend with its own SDK path). `ollama` and `lmstudio`
are aliases _within_ openai-compatible — presets that autofill an endpoint and a model — never
peers of it.
_Avoid_: vendor, service, backend, LLM

**Driven**:
Of a provider — one this repo's tooling configures for you, writing its credentials and
mirroring them to the read path. Only **local** and **openai-compatible** are driven.
A provider can be **recognised** and health-checked without being driven; the two are
independent, and conflating them is what produced ADR 0007.
_Avoid_: supported, enabled

**Embedding identity**:
The string stamped on every vector recording who wrote it — `local:<model>` or
`openai:<model>@<endpoint>`. What **drift** is measured against, and why mixing two providers
in one index degrades every later search.
_Avoid_: provider string, signature

## Secrets

**Secret guard**:
The interception point that decides how credential-bearing content may be handled before it
reaches a transcript, a committed document, or an external recipient. Named for what it does —
intercept and decide — not for any one of its outcomes.
_Avoid_: scanner, filter, blocker

**Detection**:
Finding that content holds a credential, and which rule matched. Reports the rule, never the
value — a refusal that prints what it caught has put that credential in a terminal, a
scrollback, and probably a transcript, which is the harm the check exists to prevent.
Distinguished from a **finding**, which is a verify-script check outcome; one word for both
would cover two unrelated things.
_Avoid_: scan result, hit, match

**Redaction**:
Replacing a credential value with a stable, non-reversible fingerprint while preserving the
surrounding structure — key names, nesting, types. Distinguished from removal, which loses the
structure, and from refusal, which yields nothing. The same secret fingerprints identically in
two files, which answers whether two environments share a credential without disclosing either.
_Avoid_: masking, scrubbing, sanitising

**Backstop**:
A second, independent check that asks the same question in a different shape and prefers a prompt
over a silent pass. It exists for the outcome a **secret guard** cannot report on itself — a
credential read it failed to recognise is not refused, it is simply allowed. Distinguished from a
fallback, which takes over when the first path fails visibly; a backstop fires precisely when the
first path believed it had succeeded.
_Avoid_: fallback, safety net, second pass

## Delegation

**Delegate**:
To dispatch scoped work to a cheaper agent running as a separate process, under a consent
gate. Distinguished from **export**, which sends a brief to an executor outside the board
entirely.

**Executed by**:
Whether a human was in the loop for the work behind a closure — **HITL** if a person was present,
**AFK** if nobody watched. Agent-executed work is AFK by default, because assuming supervision that
did not happen is the more expensive mistake. It decides how much independent review a closure needs
and what its evidence even looks like: HITL work is answered with a change reference, what was
observed and when; AFK work must be reproducible by someone who was not there. Not to be confused
with _who_ acted — an outside contractor's unattended agent and an engineer watching a change land
are both off the board, and need opposite amounts of scrutiny.
_Avoid_: who ran it, executor type
