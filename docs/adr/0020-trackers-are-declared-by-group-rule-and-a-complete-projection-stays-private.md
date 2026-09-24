---
status: accepted
date: 2026-09-24
---

# Trackers are declared by group rule, and a complete projection stays private

ADR 0017 requires one committed tracker entry per repository — a hundred hand-reviewed entries
for a team managing that many repos in project groups. We decided a group can declare a tracker
rule that every registered member mirrors under, with a per-repository entry still able to
override it, and added a `complete` projection level that carries the whole record but is
refused on any public tracker. This refines ADR 0011, 0013, and 0017.

## Context

- A team managing over a hundred repos in project groups reads work in each repo's own issues
  (ADR 0017); ADR 0017 requires one committed tracker entry per repository — about a hundred
  hand-reviewed entries.
- ADR 0017 rejected inferring a tracker from a repo's origin at run time because registering a
  repo would start publishing with nobody deciding.
- The secret guard detects credentials. It does not decide audience: a rotation plan naming
  hosts, commits and a key's validity window holds no credential and passes the scan.
- ADR 0017 sends `summary` by default and `full` on request, and never `## Ruled out`, notes or
  evidence. Teams on a private tracker want the whole record visible where they read.
- Machine references — a home-directory path carrying a username, a workspace path, a local
  port, a local hostname, a container name — resolve on one machine only. Written to a board
  with a remote or to a tracker, they mean nothing elsewhere, and a username in a home path ties
  a developer's personal identity to another organization's records.
- The glossary said a developer's own board never mirrors, yet a developer's personal board can
  be the only board for that developer's own repositories. ADR 0017's board identity already
  refuses a second board writing into a tracker another has claimed.

## Decision

- **A tracker rule** is a committed, group-level declaration in the board's config: every
  repository registered in that group mirrors into its own origin repository with the rule's
  system and projection. The target is resolved from the origin recorded when the repository is
  registered, never read at run time, so a CI mirror needs no member checkouts. A rule applies
  only to a member whose recorded origin is on the host its system names; a member elsewhere is
  not mirrored, since its path would otherwise be reused on a host it does not live on. Adding a
  repository to the group is the decision, visible in review. A per-repository **tracker
  entry** overrides the rule.
- **`allowPublic` is never part of a rule.** It is accepted only on a per-repository entry, so
  one rule cannot opt a group's public repositories into publishing. ADR 0013's double opt-in
  stands per repository.
- **Projection `complete`** adds Decisions, Ruled out and Evidence to `full`. Never Activity —
  it gains a line on every checkpoint, so each checkpoint would rewrite the issue body and
  notify every watcher. `complete` is refused on a public tracker, never carries a `restricted`
  document, and is opt-in per entry or rule.
- **The secret guard is necessary, not sufficient.** Every projection is scanned; the scan never
  decides who may read.
- **Machine references are rewritten on any board with a remote**: a path under the home
  directory becomes `~`, a path under the workspace root becomes the workspace-root token;
  another user's home path, local ports and `*.local` hostnames are warned about, never
  rewritten. A home path inside a `verify:` command is only warned about, since `~` does not
  expand inside the quotes that field requires. Container names are not detected: nothing in a
  doc marks a word as one. The detector runs on each CLI write (`new`, `checkpoint`, `release`,
  `import`), on `move`, and on `mirror` and `export`. It reports which rule matched, never the
  matched text. It applies
  regardless of audience because the rewrite loses nothing for the owner; a local board is
  untouched. It is a separate detector beside the secret guard, not a mode of it — it answers a
  portability question, not a credential one.
- **Any board may mirror.** Which board owns a tracker is decided by the board identity
  (ADR 0017): the first board to claim it. The glossary's "a developer's own board never
  mirrors" is withdrawn.
- **A tracker is never the board** (ADR 0002 reaffirmed): no drop-in replacement, no two-way
  sync.

## Considered options

- **One entry per repository only.** Rejected — a hundred entries that say the same thing.
- **A rule plus a consent file in each member repository.** Rejected — a hundred more consent
  points, no added safety.
- **The secret guard alone making full detail safe.** Rejected — it cannot see confidentiality.
- **`complete` including Activity.** Rejected — rewrites the issue body and notifies every
  watcher on every checkpoint.
- **Refusing machine references.** Rejected — blocks a harmless note on the owner's own board.
- **A machine-reference mode inside the secret guard.** Rejected — conflates portability with
  credentials.
- **Keeping "a developer's own board never mirrors."** Rejected — it was a proxy for
  one-writer-per-tracker, which board identity now enforces directly.

## Consequences

- Board config gains tracker rules.
- The projection levels gain `complete`.
- The verifier gains tracker-rule checks and refuses `allowPublic` inside a rule.
- The CLI gains the machine-reference detector.
- A payload version bump.
- An existing board behaves as before until it declares a rule.
