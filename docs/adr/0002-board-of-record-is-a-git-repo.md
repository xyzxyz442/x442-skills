---
status: accepted
date: 2026-08-29
---

# The board of record is a git repository with a remote

A handoff board coordinates work across sessions, agents, and repositories — but a board
that lives on one machine coordinates nobody. We decided the board of record is a
**dedicated git repository with a remote**, one per trust boundary, with the lease enforced
by `git push` acting as a compare-and-swap. Issue trackers and knowledge bases become
**one-way projections** of that board; neither is ever a second writer.

## Context

The board is read constantly and written occasionally. A session-start hook lists it on
every session; the edit gate resolves a lease synchronously before every write to a handoff
doc; `list` and `index` walk the whole board. As files, all of that is free, offline,
synchronous, and needs no credential. Behind an API it is a network round trip with a token
to distribute, rate limits, and a hard dependency on connectivity for the _most frequent_
operation.

But files on one disk are not a board. Two properties, discovered by inspection rather than
assumption, made this urgent:

- A board can be a git repository with a long history and **no remote** — versioned and
  still unshared.
- The board's own repo registry can use **relative filesystem paths as repo identity**
  (`"path": "../../../acme-lib"`), which resolves on exactly one disk. This, not the file
  format, is what pins a board to a machine.

A fleet also spans more than one git host in practice, so no single issue tracker can cover
every member repo.

## Decision

- The board of record is a **dedicated git repository with a remote**, owned by no member
  repo. It carries the docs, the index, the config, and the leases.
- **One board repo per trust boundary.** Groups are sections inside a board, not separate
  boards. A trust boundary is the only line forced by something real — an ACL and a host.
- **`git push` is the lease primitive.** `claim` writes the lease, commits, and pushes; a
  rejected non-fast-forward push means someone claimed first. This is mutual exclusion
  across machines with no server. `claim` is therefore **strict** (no network, no claim);
  `release` is **optimistic** (it records something that already happened, and must work
  offline).
- Leases are **committed** on boards that have a remote, and stay ignored on local-only
  boards. A lease is ephemeral machine state locally and shared state of record when
  distributed. Lease expiry is stamped from the **commit time**, not local wall-clock.
- **Repo identity is the root commit**, which is already recorded and already verified in
  offline briefs. Filesystem locations move to an uncommitted per-machine layer anchored at
  `$HOME`, alongside `$WORKSPACE_ROOT` and a cached identity map.
- A board is fetched to a **conventional location** by default so that a teammate who runs
  the setup skill gets a working board with nothing to configure.
- Projections are **one-way**. An issue tracker may mirror open coordination work for human
  visibility; a knowledge base may ingest the archive. Neither writes back.

## Considered options

- **An issue tracker as the board.** Rejected — it inverts the cost (network on the
  constant path), cannot answer the edit gate synchronously, has no atomic lease primitive,
  cannot cover a fleet spanning two hosts, and is a poor host for the restricted material a
  board legitimately carries.
- **Merging the board into a knowledge base.** Rejected — push-CAS means every `claim`
  fetches and pushes the repo, so lease latency would grow with the knowledge base forever;
  and a knowledge base's value is being widely readable, which is the wrong audience for
  restricted work. **The seam is the archive**: a closed handoff has no lease left and its
  value flips from coordination to retrieval, so that is what gets exported.
- **A lock service or server-authoritative board.** Rejected for now — it would allow
  humans to write status directly, but a human changing status while an agent holds a lease
  has no correct resolution. That is a different lease model and belongs in a later
  decision, not smuggled in here.
- **Keeping the vendored path-based registry.** Rejected — it is the specific mechanism
  that pins a board to one machine.

## Consequences

- `claim` and `release` acquire a network dependency; **reads do not**. Offline, `claim`
  refuses with an explicit message and `release` still works.
- Boards scaffolded as standalone must be `git init`-ed; see ADR 0005, where that becomes a
  hard prerequisite rather than a preference.
- The repo registry format changes: identity committed, location not. Existing registries
  need their paths demoted.
- Setup gains a bootstrap step (clone-if-absent) and the CLI gains a board-path override,
  so that pointing a repo at a different board no longer requires rewriting committed
  config — the absence of that override is what previously forced installers to edit
  tracked files.
