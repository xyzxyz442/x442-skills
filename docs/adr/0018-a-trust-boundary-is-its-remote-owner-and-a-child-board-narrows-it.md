---
status: accepted
date: 2026-09-24
---

# A trust boundary is its remote owner, and a child board narrows it

A developer keeps a board for drafts next to the team's, and a client engagement inside an
employer can need a smaller audience than the employer's board already reaches. Git cannot
restrict who reads a folder, so a narrower audience has always needed its own repository. We
decided the trust boundary is read from a board's remote host and owner, never declared and
never the host account used to reach it, and that a board may declare itself a **child** of
another board — narrower than its parent, so work flows into it freely and out of it only by
name — without inventing a role a board can hold. This refines ADR 0002, 0005, 0011, and 0013.

## Context

- Developers keep a board for their own drafts next to the team's; a client engagement inside
  an employer can need a smaller audience than the employer's board membership.
- Git cannot restrict read access per folder: every group or section of a board is readable by
  every member.
- ADR 0011's `move` proceeds silently within one host and owner, so a narrower board created
  under the same owner can have work moved out of it into the wider board with no flag — silent
  widening.
- One host account can reach several owners — a developer's personal account invited into an
  employer org, or one account reaching both a client's org and an open-source org. The account
  in use says nothing about where material belongs.
- Nothing checks the visibility of the board repository's own remote; only trackers are checked
  (ADR 0013).
- One machine can carry several host accounts; a mirror run under whichever account happens to
  be active either fails or writes issues under the wrong identity.
- `depends_on` stays within one board (ADR 0011); a wait on another boundary's board is free
  text nothing tracks.
- A team managing over a hundred repos in project groups still wants one board: cross-group
  library-to-consumer dependencies are routine, and `depends_on` only works inside one board.
  Readability is served by per-repo trackers (ADR 0017) and group-scoped listings, not by
  splitting boards.

## Decision

- **Two axes, and the tool reads one.** Locality: a **local board** has no remote; every other
  board has a private remote. Audience: **personal board** (one developer) versus **team
  board** — vocabulary and a setup suggestion only, never config (reaffirms ADR 0011: no board
  roles). Placement: **dedicated board** (its own repository) versus **in-repo board**. The
  term "shared board" is retired because it meant placement and was read as audience.
- **The trust boundary is the remote's host and owner**, never declared and never the host
  account used to reach it. A boundary holds one or more boards; no board spans two boundaries.
  This relaxes ADR 0002's "one board repo per trust boundary" wording. Groups stay the way to
  split one team's work inside a board.
- **A narrower audience needs its own repository.** A group organizes; it never restricts
  readers.
- **A child board declares its parent** (the parent board's remote) in its committed config.
  Moving into a child proceeds; moving out of a child refuses unless the target is named
  explicitly, even within one owner. A target with no remote is the one exception, as in ADR 0011:
  the work stays on this machine, which widens nothing. A **same-owner child** is declared by the
  child alone, so the parent's members never learn its name. A personal board under its team
  board's owner is a same-owner child.
- **A cross-owner child is an opt-in declared on both sides**: the child declares its parent,
  and the parent's committed config lists the child as accepted. With both, normal documents
  move from parent to child without naming the target. `restricted` documents are still refused
  whenever the real owners differ — ADR 0011's rule that restricted work never leaves its owner
  stays unconditional. Worked example: `dev-a/handoff-board` lives on a developer's own
  account, which is also a member of the org `acme`. It declares `acme/team-board` as its
  parent, and `acme/team-board` accepts it.
- **Separate boundaries are the default.** Without that two-sided link, owners are separate
  boundaries exactly as ADR 0011 describes: every move names the target, and restricted work
  never crosses. Example: work for a client org and a library owned by a separate open-source
  org, both reached with one account, stay two boundaries.
- **Board remotes are private.** Setup refuses a board whose remote is public; each `mirror`
  pass checks the board's own remote along with its trackers; an `unknown` answer warns rather
  than refuses for a board, so hosts without a visibility API still work. The verifier stays
  offline (ADR 0013) and does not ask. `claim` does not check — it stays a plain git operation.
  This applies to a board with a remote of its own: an in-repo board's remote is its code
  repository's, whose audience that repository already chose — an open-source project's board is
  public by design (ADR 0013).
- **A host account is recorded per developer** in `handoff.local.json` (ADR 0010's
  per-developer file). `mirror` and `export --to-issue` refuse when the active account differs.
  Setup suggests a git `includeIf` credential rule. The account never defines or merges a
  boundary.
- **Cross-board waits have a recognised form**: `blocked_on: external — BOARD-REMOTE#ID`. When
  that board is cloned on the same machine, `list` shows its current status next to the entry —
  read-only, status only, never fetched, never copied. Otherwise it is plain text. `depends_on`
  stays within one board.

## Considered options

- **The parent lists its children.** Rejected — discloses a client's name to every parent
  member.
- **A child as a section of its parent.** Rejected — git cannot hide a folder.
- **A cross-owner child declared by the child alone.** Rejected — any board could name a parent
  and receive its work silently.
- **A cross-owner child that also receives restricted work.** Rejected — makes ADR 0011's
  unconditional rule conditional on a declaration held on an account the parent's owner does
  not control.
- **Moving the personal board into the parent's org.** Valid, and needs no mechanism; kept as
  the zero-mechanism alternative, not required.
- **Audience as a config role.** Rejected — the tool needs only locality; ADR 0011 stands.
- **One board per project group.** Rejected — turns routine cross-group dependencies into
  untracked free text.
- **Checking board visibility on every claim.** Rejected — puts a host API call on the command
  that must stay fast.
- **A tracker as the board.** Rejected in ADR 0002 and reaffirmed: a tracker is only ever a
  projection.
- **Real cross-board `depends_on`.** Rejected — the tool would have to model boards it does not
  own.

## Consequences

- Board config gains a parent declaration and an accepted-children list (board config, not the
  document schema — no schema bump); `handoff.local.json` gains the host account; `move`'s
  trust check gains the child rules; setup and `mirror` gain the board-visibility check; the
  verifier gains offline parent/child and host-account checks; `list` gains read-only cross-board
  status. An existing board behaves exactly as before until it declares a parent.
