---
status: accepted — refined by ADR 0020
date: 2026-09-17
---

# A tracker publishes to a public repository only by double opt-in

ADR 0011 lets a board mirror open work into an issue tracker and delegate a handoff as an issue. It
never asked who can read that tracker. We decided that when the target repository is **public**,
nothing is sent unless the **board** opts in and each **document** is marked for sharing; otherwise
`handoff mirror` and `handoff export --to-issue` refuse. This refines ADR 0011.

## Context

- Publishing to a public repository is irreversible. Closing an issue hides nothing, and a deleted
  issue has already been read, cached, and indexed.
- The first live run of the mirror (2026-09-17) wrote issues to a public repository with no warning
  at all. It was harmless only because the board held test documents.
- `sensitivity: restricted` already keeps a document from leaving the board, but it answers a
  different question: how carefully the tooling handles a document. Whether its audience may be the
  whole internet is a separate choice, and most documents on a board are `normal` without being
  fit for strangers.
- A repository's visibility can change after a board is configured, so any answer recorded at setup
  goes stale.

## Decision

- **Visibility is asked, every run.** The adapter gains a `visibility` operation (GitHub:
  `gh repo view --json visibility`) returning `public`, `private`, `internal`, or `unknown`. It is
  never cached. `unknown`, or a failed call, is treated as `public`. GitHub's `internal` —
  visible to an enterprise, behind its login — is treated as private.
- **Guarded commands are the ones that publish:** `handoff mirror` and `handoff export --to-issue`.
  Reading a reply (`import --result --from-issue`) and `--ref` are not guarded.
- **First opt-in, the board.** A public repository is refused unless the board's committed
  `handoff.json` sets `external.allowPublic: true`. It cannot come from `handoff.local.json` or an
  environment variable: publishing is a team decision, recorded where review and history see it.
- **Second opt-in, the document.** On a public repository only documents carrying
  `share: public` are mirrored or delegated. `new --share public` sets it; it is optional, absent
  means not shared, and `migrate` never backfills it. `restricted` always wins: `new` refuses the
  pair and the verifier warns (`doc.share.conflict`). On a private repository `share` changes
  nothing.
- **A public bundle names only what was shared.** Its checklist lists children marked public and
  one line counting the rest, never their titles.
- **A repository that turns public refuses the whole run.** Before any create, update, or close,
  `mirror` stops and lists the issues it had already mirrored, for a person to review. Nothing is
  closed or deleted automatically.
- **A mark removed closes the issue and says it stays visible.**
- **The verifier stays offline.** It warns `board.external.public` whenever `allowPublic` is set
  and names the documents marked public; visibility itself is checked only at run time.
- **No schema bump.** ADR 0003 bumps the document schema for a new field so an older CLI refuses to
  write a document carrying it. That protects nothing here: an older CLI has no public guard at all,
  and `mirror` only reads documents. The protection lives in the CLI that publishes, and an
  out-of-date payload is already a verifier warning.

## Considered options

- **Warn and continue.** Rejected — a warning printed after an irreversible publish is a record of
  the mistake, not a guard against it.
- **Never publish to a public repository.** Rejected — some boards coordinate open-source work
  whose audience is public by design.
- **Board opt-in alone.** Rejected — a board where every document starts public-safe is rare, and
  one run would publish all of it.
- **A third `sensitivity` value.** Rejected — it would change what `normal` means on every existing
  board and fold audience into handling.
- **Record visibility at setup.** Rejected — a repository made public later is exactly the case a
  stale answer misses.
- **Close or delete issues when a repository turns public.** Rejected — closing hides nothing, and
  deleting is irreversible and belongs to a person.

## Consequences

- Every tracker adapter implements `visibility`; one that cannot answer reads as public.
- `new` gains `--share public`; the verifier gains `board.external.public`, `doc.share.conflict`,
  and `doc.share.invalid`.
- `external.allowPublic` is board policy and survives a re-install, like the rest of `external`.
- A board mirroring to a private repository behaves exactly as before.
