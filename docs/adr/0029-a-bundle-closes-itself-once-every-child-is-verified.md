---
status: accepted
date: 2026-11-15
---

# A bundle closes itself once every child is verified

A bundle closed only when someone ran `release <bundle> --status done`, and nothing prompted it. A
bundle on a live board read `5/5 done — all children done` for ten days and stayed open. We decided
that the release which closes a bundle's last child also closes the bundle, but only after a
verification that checks each child's evidence, not only its status.

## Context

- An orchestrator holds no work of its own. Its progress is derived from its children, so "every
  child done" is its whole definition of done.
- The manual close checked only each child's `status`. A status is the one field anyone can set by
  hand. Older docs closed before evidence was a field carry a date and no `verified_by`.
- The child's `done` path already announced docs blocked on it (`surface_unblocked`), but never the
  bundle it belonged to.
- A bundle can carry its own `verify:` command. A command never runs automatically (a cross-repo
  doc is untrusted), so an automatic close cannot honour it.

## Decision

- **One verification for both closes.** A bundle is verified when its roster is not empty and
  every child resolves to a doc that is `done`, is in `archive/`, is not `review: pending`, and
  carries its evidence: `verified_by` and `verified_at` on a coordination child, `verified_at` on a
  nested bundle, and nothing on a retired standalone doc, which makes no live-code claim. The
  manual `release <bundle> --status done` refuses when any of this fails, and names each reason.
- **A child's `done` release closes the bundles it completes.** After any `done` release
  (coordination, standalone or bundle), each bundle in the same section that lists the child, and
  now has every child done, is verified. A verified bundle is set `done`, stamped `verified_at` and
  `verified_by: "auto — all N children done and verified"`, logged with the child that completed
  it, archived, and announced to the docs blocked on it. The same check then runs for that
  bundle's own parents.
- **A bundle that fails verification stays open and says why.** The release prints each failing
  child and its reason. Nothing is closed on a partial check.
- **A bundle with its own `verify:` command is never closed automatically.** The release says so
  and prints the manual close command.
- The closed bundle rides the child's release commit, through the existing staging of changed
  orchestrator docs. No new commit or push is added.

## Considered options

- **Print a nudge only.** Rejected by the user. A person still has to remember the step, and the
  open 5/5 bundle shows that the step is forgotten.
- **Auto-close on status alone.** Rejected. It trusts the one field that can be set by hand, and it
  would close bundles over legacy children that carry no evidence.
- **Close bundles in `index`.** Rejected. `index` runs after every mutating command and on other
  machines, so a close would land in an unrelated session's commit with nobody's release behind it.

## Consequences

- A manual bundle close is stricter. It now also refuses over a child with no evidence or a child
  awaiting review.
- A board with legacy children (done, no `verified_by`) keeps such bundles open until the child's
  evidence is recorded.
- A payload version bump.
