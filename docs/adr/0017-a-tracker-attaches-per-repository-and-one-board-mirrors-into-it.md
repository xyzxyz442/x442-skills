---
status: accepted — refined by ADR 0020
date: 2026-09-21
---

# A tracker attaches per repository, and one board mirrors into it

ADR 0011 lets a board attach **at most one** external tracker. On a cross-repository board that
tracker is usually the board's own repository, so every member's work is projected into one place
the members' teams never read. We decided that a tracker attaches **per repository**, that a handoff
picks one by its **home**, that the board keeps no tracker of its own, that an issue carries only a
**summary** unless its tracker asks for more, and that **one board** mirrors into a tracker. This
refines ADR 0011 and keeps ADR 0013's double opt-in, now asked per tracker.

## Context

- What a team watches is its own repository's issues. A board-level tracker reaches the board's
  maintainers and nobody else, so the projection ADR 0011 built for teammates without board access
  did not actually arrive where they look.
- The board is the record — leases, evidence, `## Ruled out`, restricted documents — and it stays
  the record whether or not it has a remote. What a repository's readers may see is a narrower
  question than what the board holds, and on a public repository the readers are everyone.
- A handoff's `audience` names the repository acting next and changes throughout its life. An issue
  that followed it would hop repositories, split one handoff's history across trackers, and leave a
  trail of closed issues that were never finished.
- Several maintainers on one project each keeping a board would mean two writers for one tracker —
  the case ADR 0002 rules out — and leases on one board do not restrain the other.
- Nothing in the mirror could tell its own issues from another board's: an issue was matched by
  `<!-- handoff:SECTION/ID -->`, which names no board.

## Decision

- **A handoff's issue lives in its home repository.** A new document field, `home`, is pinned by
  `new` (`--home`, else `HANDOFF_REPO`, else — for a coordination document — its `audience`) and
  never changes. `audience` keeps changing and is projected as an `audience:ALIAS` label. Adding
  `home` bumps the document schema to 4 (ADR 0003); `migrate` backfills it from the audience, and on
  an orchestrator from the one home its children share, leaving unresolved documents unmirrored and
  naming them.
- **Work another team owns is split, not moved.** A quick audience flip relabels the issue and
  reassigns it to the `reviewer` pointer (ADR 0016). Work that repository genuinely owns becomes a
  child handoff homed there.
- **Trackers are declared per repository in the board's committed `handoff.json`**, under `trackers`
  keyed by the registry's repository aliases. Each entry carries what `external` carried — `kind`,
  `system`, `repo`, `refPattern`, `allowPublic` — plus `projection`. A `sprints` entry stays
  reference-only. An alias with no entry is never mirrored. Setup suggests an entry from a
  repository's `origin`; nothing is inferred at run time.
- **One owner per board, enforced.** Every tracker on a board shares one host and owner, and a board
  with a remote shares it too; a board without one takes its owner from its trackers. A mismatch
  refuses and names both owners. This is ADR 0011's one board per trust boundary, held while the
  trackers multiply.
- **The board keeps no tracker of its own.** On a cross-repository board a leftover `external` routes
  nothing and the verifier warns. A single-repository board keeps `external` as legacy mode, where it
  serves every document and `home` is not consulted.
- **A summary by default.** An issue carries the title, the labels and `Current state`. A tracker
  opts into `full`, which adds `Context` and `Verify`. `## Ruled out`, notes and evidence are sent
  under neither.
- **One board mirrors into a tracker.** A marker becomes `<!-- handoff:BOARD/SECTION/ID -->`, where
  the board identity is derived — a digest of the board repository's root commit and the board's path
  inside it — so every clone agrees and a draft board in the same repository does not. A pass that
  finds another board's identity refuses that tracker, names the owner, and sends nothing. A
  pre-identity marker is adopted while no other board has claimed the tracker.
- **A pass sees only its own home's documents.** Create, update and close are decided from that
  subset, so a pass cannot close another repository's issues. Visibility and ADR 0013's double
  opt-in are asked per tracker, in a preflight over every tracker before any pass sends anything.
- **Sub-issue links stay inside one tracker.** A child homed elsewhere stays in the parent's
  checklist. Linking across repositories would change the adapter contract (ADR 0014), and no board
  needs it yet.

## Considered options

- **Routing by `audience`.** Rejected — the issue would hop repositories on every flip and split one
  handoff's history.
- **One issue per repository in `repos`.** Rejected — N issues for one handoff multiply drift, and
  the extra copies answer to nobody.
- **A pointer issue in the audience's repository.** Rejected — an issue per flip for the mirror to
  manage, discussion split across two, and pull requests linked to the wrong number.
- **One board holding several owners' records.** Rejected in ADR 0011 and not reopened: it puts one
  organization's restricted material on another owner's disk, and possibly its remote.
- **Declaring trackers in the group cascade.** Rejected — the cascade has uncommittable layers, so
  `allowPublic` could come from a file review never sees, which ADR 0013 forbids.
- **Inferring a tracker from a repository's `origin`.** Rejected as behaviour — registering a
  repository would start publishing into it with nobody deciding. Kept as the suggestion setup makes.
- **Storing a board identity in `handoff.json`.** Rejected — a stored id is copied with the file and
  then claims two boards are one; a derived one cannot be wrong.

## Consequences

- The document schema moves to 4 and each board migrates on its own confirmed `migrate` (ADR 0003).
- The board config gains `trackers`; `external` survives on single-repository boards and is preserved
  across a re-install, as `trackers` now is.
- `mirror` gains `--repo ALIAS` and prints one pass per tracker; every mirrored issue's body is
  rewritten once, when its marker gains the board identity.
- The verifier gains `board.trackers.*`, `board.external.legacy`, `doc.home.missing` and
  `doc.home.unregistered`, and reports `board.external.public` per tracker.
- A mirror run in CI needs a token with issue write access on each member repository, recorded by
  name only.
- An existing board keeps behaving exactly as before until someone declares `trackers` on it.
