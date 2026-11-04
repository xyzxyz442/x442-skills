---
status: accepted
date: 2026-11-04
---

# Release honours the lease claim honours

`claim` enforced the lease and `release` did not, so any session could release another's live
lease or close a doc a second time. We decided `release` refuses exactly where `claim` refuses — a
live lease held by another session — and that a doc already `done` cannot be closed again.
`release --status open` on an archived doc reopens it.

## Context

- A session whose `claim` was refused could still `release --status open` the same handoff, which
  cleared the holder's lock, or close it `--status done` with no lease at all.
- `doc_of` searches `archive/` as well as the live directory, which is right for `show` but let
  `release --status done` reach a closed doc and overwrite its `verified_by`. This happened on a
  live board on 2026-10-27: a second session's closure replaced the first one's evidence in the
  frontmatter, and the first closure survived only as an Activity line.
- The same lookup let `release --status open` set an archived doc's status without moving the file,
  so the reopened doc stayed in `archive/` and `list` never showed it again.
- A lease claimed with no tool session id records `session=` empty (advisory mode). The
  advisory-mode decision keeps that state as "ownership cannot be proven" with a truthful message,
  rather than inventing an identity — and a gate keyed on proven ownership would lock such a holder
  out of their own lease.

## Decision

- **A non-holder may not release a live lease.** `release` reads the lease before anything is
  written. When it is `held` and records a session id other than the caller's, the release is
  refused and the lock is left untouched. An expired lease, or no lease, may be released by anyone —
  the same cases in which `claim` could take it over, so the rule adds no new way to be stuck.
- **A lease with no recorded session refuses nobody.** It proves no holder, so it cannot single out
  a non-holder. A session-less caller releasing a lease that does record a session is refused, and
  told to set `HANDOFF_SESSION_ID`.
- **A done doc cannot be closed again.** `release --status done` on a doc whose status is already
  `done` is refused, wherever the doc sits. Its `verified_by` and `verified_at` stay the first
  closer's.
- **Reopening is a release.** `release --status open` or `--status blocked` on an archived doc
  moves it back into the live directory and logs the reopen. There is no separate `reopen`
  command.
- **The check is local.** `release` stays optimistic (ADR 0019): it reads the lease from the local
  clone and does not fetch first. A lease claimed elsewhere and not yet pulled is not seen.
- Bundles and standalone docs carry no lease, so only the done and reopen rules apply to them.

## Considered options

- **Holder only** — refuse unless the caller holds a live lease. Rejected: a stale lease, or a
  doc nobody claimed, would then need a `claim` purely to be allowed to release it, and every
  advisory-mode holder would be locked out of their own lease.
- **Mirror claim, plus `--force`** — let a non-holder override a live lease, recorded in Activity.
  Rejected for now: waiting out the TTL or asking the holder covers the case, and an override flag
  is the first thing an agent reaches for when a command refuses.
- **Refuse any release of an archived doc.** Rejected: `release --status open` was already the
  only way to reopen work, and people use it. It needed to work, not to disappear.
- **Fetch before checking on a shared board.** Rejected: it would make `release` fail offline,
  which ADR 0019 deliberately avoids.

## Consequences

- A payload version bump.
- Selftest cases for: a non-holder refused on a live lease, an expired and an unleased doc released
  by anyone, a done doc refused a second closure, an advisory holder releasing their own lease, a
  session-less caller refused a session-held lease, and an archived doc reopened back into `list`.
- `run-handoff` §5 states the rule.
