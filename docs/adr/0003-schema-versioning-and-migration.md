---
status: accepted
date: 2026-08-29
---

# Version the document schema separately from the payload

A board's documents and the tooling that reads them drift apart at very different rates, and
on a shared board they drift apart _per person_. We decided to carry **two version numbers**
— `payload` for the installed CLI, templates, and hooks, and `schema` for the document
format — and to make the compatibility rule asymmetric: an older CLI **reads forward** with
a warning, and **refuses to write backward**.

## Context

The payload version stamp was written by the installer and read only by the verifier; the
CLI never consulted it, so there was no runtime negotiation at all. The only precedent for
refusing an unknown format was the offline brief check, which dies outright — correct for a
brief (one file, one executor, a bad parse means wrong work) and wrong for a shared board,
where one newer document would take `list` and `index` down for every member.

Two failures follow from having a single number:

- **Spurious migrations.** Payload moves on every bugfix. If migration triggers on it, a
  routine CLI fix prompts a full-board rewrite for every member of every group.
- **Silent downgrade.** Warn-and-proceed covers reading. It says nothing about writing — so
  an older CLI could read a newer document, run `release` on it, and quietly drop every
  field it did not understand.

A board is also the shared root of a fork: a derived, internally-maintained suite tracks this
one as upstream, and needs to add its own fields without waiting for upstream to bless them.

## Decision

- **Two numbers.** `payload` covers the CLI, templates, and hooks; drift stays a verifier
  warning that says re-run the installer, in both directions. `schema` covers the document
  format, is recorded on the board and per document, and is the **only** trigger for
  migration.
- **Read forward.** A CLI that meets a `schema` it does not know **warns once and
  proceeds** for read paths — list, index, show. It never dies.
- **Refuse to write backward.** The same CLI **refuses to write** such a document:
  _"this doc is schema N, this CLI understands M — upgrade to edit it."_
- **Extension namespace.** A downstream fork adds fields under a flat `x_*` prefix, which
  upstream validation ignores. Flat, not nested.
- **Migration is offered, never silent.** An interactive invocation offers on a write
  command; a hook invocation reports one line and never blocks; `--yes` exists for CI and
  local boards.
- **Migration moves structure only.** It adds, renames, and moves keys. It never infers a
  value — not an environment, not a sensitivity, not a summary seeded from a log entry.
  Judgment stays lazy-on-touch, with the verifier listing what is still missing.

## Considered options

- **One version number.** Rejected — see "spurious migrations" above.
- **Die on unknown schema, as the brief check does.** Rejected — it turns one member's
  upgrade into an outage for everyone else on a shared board.
- **Write through, preserving unknown keys.** Rejected reluctantly. It is the
  theoretically better answer, but frontmatter is edited with line-matchers throughout the
  CLI, so a faithful preserve-unknown round trip means rewriting the whole parsing layer —
  and any gap in it corrupts data _silently_, which is the failure mode this decision
  exists to prevent. Refusing is one comparison and fails loudly.
- **A nested extension map instead of `x_*` keys.** Rejected — it would require teaching
  every line-matcher in the CLI to parse nested YAML, for no gain.
- **Silent auto-migration when the CLI is newer.** Rejected — pushing a whole-board rewrite
  to a shared remote is an irreversible outward-facing action and must be confirmed.
- **Migrating content as well as structure.** Rejected — a script that stamps a default
  sensitivity onto a document about a credential exposure writes an actively false claim,
  and no script can determine which entry of a long activity log is current.

## Consequences

- Refuse-to-write-backward is what makes read-forward safe. The two are one decision and
  must ship together; shipping only the read half is worse than shipping neither.
- Migration is a distributed mass write, so it acquires gates — see ADR 0005.
- The CLI needs machinery it does not have: it must read the version stamp at runtime, gain
  a `migrate` command, and be able to prompt from an interactive context while staying
  silent and non-blocking under a hook.
