---
status: accepted
date: 2026-09-16
---

# Boards have no roles, and a tracker attaches per board

Developers keep boards of their own next to the team's, and teams already plan in a project
tracker. We decided the tooling names **no board role** — a board a developer keeps for drafts
is an ordinary board, suggested at setup and never assumed — that a handoff **moves** between
boards and is never copied, and that each board attaches **at most one external tracker**, by
reference first. This narrows ADR 0002's allowance that an issue tracker may mirror open work.

## Context

- How a developer splits private drafts from team work is a preference. A built-in "personal"
  key would make one arrangement the only one the tooling understands.
- Without a role, nothing marks which board is private — yet moving a draft onto a board hosted
  somewhere else can carry one organization's material into another's.
- Planning already lives in a project tracker — a Scrum tool for sprints, or an issue tracker on
  a smaller project. The board sits below it: technical breakdown, cross-repo coordination,
  leases, evidence.
- Two copies of one handoff is the second writer ADR 0002 rules out, and an older CLI writing
  one copy drops fields ADR 0003 protects.

## Decision

- **No board role in config.** Setup suggests layouts for a developer's own board — an ignored
  folder in the repo, a folder beside the team board, any path named — and records the choice
  in `handoff.local.json` (ADR 0010).
- **One board of record per handoff.** `handoff move <id> --to <board>` transfers ownership: the
  doc lands on the target with a new id in the target section, and a one-line pointer stays
  behind. It runs the same secret scan and sensitivity refusal as `export`.
- **The trust boundary comes from the remote.** `move` compares the target board's git remote
  host and owner with the source's. Same host and owner, or a target with no remote, proceeds.
  Anything else refuses unless named explicitly, and says which two remotes differ.
- **`depends_on` stays within one board.** A dependency on another board is written in
  `blocked_on` as `external — …` (ADR 0004).
- **A board declares at most one external tracker**, under `external` in its `handoff.json`, with
  three opt-in levels:
  1. **Reference** — `external_ref` on a handoff, validated by the board's `refPattern`. No
     network. The default.
  2. **Delegation** — `export` may open the brief as an issue; a reply returns through
     `import --result` as a claim awaiting review, never as a status.
  3. **Mirror** — CI on the board repository projects open, non-restricted, secret-scanned work
     one way into the tracker. Offered only for an issue tracker the team already uses as its
     backlog.
- **A board that references a sprint tool is never mirrored anywhere.** Its tracker is the
  planning surface; a mirror would be a second backlog.
- **A progress checkpoint** rewrites a held handoff's Current state and pushes without releasing
  the lease, so progress reaches the team before `release`.

## Considered options

- **A built-in personal board.** Rejected — it hardcodes one preference, and one private board
  shared across trust boundaries mixes organizations' material on one disk and possibly one
  remote.
- **Syncing a draft board with the team board.** Rejected — two writers for one handoff.
- **An issue tracker as a board backend.** Rejected in ADR 0002, and nothing here reopens it.
- **Mirroring into the sprint tool.** Rejected — it fills sprint boards with internal churn and
  couples the board to that tool's workflow states.
- **A trust boundary declared by hand per board.** Rejected for now — the remote already encodes
  the host and owner, and a declared field drifts from it.

## Consequences

- The document schema gains `external_ref`, which is a schema bump and a confirmed per-board
  `migrate` (ADR 0003).
- The CLI gains `move` and a checkpoint command; the board config gains `external`.
- A board without a remote cannot prove where it belongs, so `move` onto it always proceeds —
  a local-only board keeps material on one machine, which is the point of having none.
- The mirror needs its own verify checks and a fake provider in the harness; graders never touch
  the network.
