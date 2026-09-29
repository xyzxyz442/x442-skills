---
status: accepted
date: 2026-09-29
---

# The team board is the one setup finds, and a developer's own board is reached by name

A team of dozens shares one dedicated board with several groups, and each developer also wants a
board for drafts (ADR 0018's child board). The natural layout puts the developer's own board at the
workspace root and clones the team board beside the repositories — which makes setup propose the
wrong one, and `--local-board` then moves every claim in that checkout onto a board nobody else
reads. We decided the team board is where claims happen and is placed where setup finds it, and a
developer's own board is placed where setup does not look first and is reached by name. This
applies ADR 0002 and ADR 0010 at team scale; it adds no mechanism a board can hold.

## Context

- **Detection is positional.** Setup scans the repo and two parents (ADR 0010) and proposes exactly
  one candidate. Under `workspace/src/<repo>`, a board at `workspace/.agents/handoff` is found from
  every repo; a board cloned at `workspace/src/<board>` is found from none.
- **`--local-board` replaces, it does not add.** It writes `board` into `handoff.local.json`, which
  outranks the committed `handoff.json` and even the board's own dispatcher. The checkout then
  claims on the developer's own board.
- **A lease excludes only the sessions that read it.** A claim on a board the rest of the team does
  not read stops nobody from claiming the same work (ADR 0002).
- **The `boards` map** in `handoff.local.json` already records a developer's other boards for
  cross-board status (ADR 0018) without changing which board the checkout uses.
- A proposal was stress-tested on 2026-09-29: the team board as a discovery-only **catalog**,
  per-developer boards holding leases, and issues carrying transfer between people.

## Decision

- **Claims happen on the team board.** It is the board of record for coordination; a developer's own
  board holds only work not yet shared. Trackers notify, the board decides (ADR 0002, 0011).
- **Place the team board where setup finds it.** Under `workspace/src/<repo>`, clone it at
  `workspace/.agents/handoff`, so every member repo detects it with no per-repo setting.
- **Place a developer's own board where setup does not look first** — any path outside the detected
  spellings, for example `workspace/.agents/handoff-<handle>`.
- **Record the own board in the `boards` map, not with `--local-board`,** when the checkout belongs
  to a team board. Drive it through its own CLI, and promote a draft with `handoff move --to`.
  `--local-board` stays for a checkout whose only board is the developer's own.
- **Setup warns before `--local-board` overrides a committed team board**, naming the board the
  checkout will stop claiming on. The guard reads only this repo: its committed `.agents/handoff.json`
  (`board` or `boardPath`), else an in-repo `.agents/handoff/`. That is the normal state of a member
  repo once setup has run, since setup writes the detected board into that file (ADR 0010); a board
  found only in a parent directory is not consulted. A warning, not a refusal — a developer may legitimately take one
  checkout off the team board.

## Considered options

- **The team board as a discovery-only catalog, leases on personal boards.** Rejected — each lease
  excludes only its owner, so two developers claim the same work and neither sees the other.
- **An issue as the unit of coordination.** Rejected in ADR 0002 and 0011 and reaffirmed: a tracker
  is a projection. An issue assignee cannot be compare-and-swapped, and a closed issue carries no
  evidence.
- **Keep the team board beside the repos and point each repo at it.** Works, but every member repo
  then carries config to reach the board everyone needs, while detection still proposes the own
  board. The default points the wrong way.
- **One board per group, to cut push contention.** Rejected in ADR 0018 — it turns cross-group
  dependencies back into free text. ADR 0019 carries contention; a group that needs a narrower
  audience gets its own board for that reason alone.

## Consequences

- `setup-handoff`'s list of places for a developer's own board changes: the in-repo and
  beside-the-team-board options gain the `boards`-map wiring, and the path must avoid detected
  spellings.
- Contention at dozens of writers is ADR 0019's to carry. Whether its three retries suffice is
  measured, not assumed — a claim that routinely exhausts them is the signal to split a group onto
  its own board.
- An own board on the developer's personal host account is a cross-owner child (ADR 0018):
  `restricted` documents never move into it. That is the intended cost of keeping it there.

## Sources

- `docs/adr/0002-board-of-record-is-a-git-repo.md` — the lease as a compare-and-swap push.
- `docs/adr/0010-a-repo-finds-its-board-locally.md` — detection scope and runtime precedence.
- `docs/adr/0018-a-trust-boundary-is-its-remote-owner-and-a-child-board-narrows-it.md` — child
  boards, the `boards` map, cross-owner restrictions.
- `docs/adr/0019-a-lease-commit-touches-only-its-group-and-a-lost-race-retries.md` — contention.
