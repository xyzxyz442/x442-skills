---
status: accepted
date: 2026-08-29
---

# Sensitivity is a handling flag, and boards must be versioned

Handoff boards legitimately carry security-sensitive coordination work — credential
exposure inventories, rotation plans, purge verification. We decided to mark those with a
`sensitivity` field that gates **what the tooling does with a document**, and to state
plainly that it is **not an access boundary**. Separately, and for related reasons, a
standalone shared board must be under version control, and an unversioned board cannot be
migrated at all.

## Context

Two facts about real boards drove this.

A board can hold an inventory of leaked credential material — file paths, commit hashes,
blob ids, certificate metadata, and the fact that the private keys are still inside their
validity window — while its only control is an HTML comment asking people not to paste
secrets. Meanwhile the outbound path was unguarded: exporting an offline brief splices whole
document sections verbatim, and the only credential check ran on the **inbound** path when a
result came back. That is backwards: refusing a pasted secret on the way in while shipping
one out is the wrong half.

A standalone shared board can also hold hundreds of irreplaceable documents with no
repository at all — no history, no blame, no recovery — while every document on it carries a
banner asserting that it is committed to git history.

## Decision

- **`sensitivity: normal | restricted`.** `restricted` refuses `export` outright, prints a
  handling banner on `claim`, **forbids delegation entirely** (no dispatch to any external
  executor or cheaper agent), and is counted by the verifier.
- **It is a handling flag, not an access control.** Board membership is the access
  boundary. This is stated explicitly so that nobody mistakes the field for a permission,
  and so that the day board membership grows wider than incident-response membership, the
  correct response is a separate repository with a tighter ACL — with `sensitivity` already
  being the field to filter on.
- **The secret scanner runs at the CLI write path** — on create, on release, on result
  import — plus an audit sweep in the verifier. The write path is the only place guaranteed
  to run regardless of how a board is (or is not) version controlled.
- **Outbound redaction.** `export` runs the scanner on the rendered brief and refuses if it
  trips, and strips the internal chronology sections from briefs.
- **Evidence is auditable.** The verification evidence required to close a handoff is
  persisted as a field rather than folded into prose, and the verifier flags closures whose
  evidence names no command, no file reference, and no commit.
- **Standalone shared boards are `git init`-ed, non-optionally.** Boards nested inside an
  existing repository inherit that repository's history and only warn.
- **Migration requires four gates**: the board is under version control; the worktree is
  clean and the migration is a single fetch-migrate-commit-push compare-and-swap that
  aborts cleanly on rejection; no live leases exist in the section being migrated; and each
  migrated document records the migration in its activity log.

## Considered options

- **Redacting restricted titles from the index.** Rejected — it makes the board unusable
  for exactly the work that most needs coordination, and the document id discloses as much
  as the title does.
- **A dedicated `security` document type.** Rejected — the lifecycle is identical to any
  other coordination work (claim, work, verify, close). What was missing was machine-enforced
  handling, not a new state machine.
- **A pre-commit secret scanner instead of a write-path one.** Rejected — a pre-commit hook
  has nothing to attach to on a board that is not a repository, which is precisely the case
  that most needs the scanner.
- **A separate restricted board repository now.** Deferred, not rejected. It is the honest
  answer once board membership is wider than the people who already have clone access to the
  affected repositories; today it doubles the infrastructure and splits the lease domain.
- **Refusing to operate on an unversioned board.** Rejected for ordinary commands — it would
  break existing boards outright. Refusing only _migration_ is the narrow version of the same
  instinct, and it is where the irreversible damage would actually occur.

## Consequences

- Restricted work cannot be delegated or exported. That is the intent, and it means a
  restricted handoff is always executed by someone with board access.
- Migration and the version-control requirement are coupled: a mass structural rewrite is
  only safe because it is recoverable, and it is only recoverable because gate one holds.
- The scanner sits on the write path, so a false positive blocks a write. It needs an
  explicit, recorded override rather than a silent bypass.
