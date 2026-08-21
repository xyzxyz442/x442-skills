---
id: delegation-fast-follows-handoff
title: Delegation fast-follows — self-held lease preflight and temp-file leak
type: coordination
status: open
audience:
repos: []
severity: low
created: 2026-08-22
updated: 2026-08-22
note:
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

Two findings parked at the end of the offline-delegation work. Both were judged non-blocking by the
whole-branch review and are recorded here so they are not lost. Neither is urgent.

**1. `export_bundle`'s pre-flight refuses on a lease the acting session already holds.**
The pre-flight added in `e238dbb` checks every child's lock before writing or claiming anything,
which correctly made bundle export atomic. But it treats _any_ held lease as blocking, including one
held by the caller. The review finding's own wording asked for "lock is free **or self-held**"; the
carve-out was not implemented. It matches `cmd_claim`'s existing behaviour, which also does not
special-case self-ownership, so it is consistent rather than surprising — but an orchestrator who
already holds a child's lease must release it, or pass `--no-claim` (which drops leasing for every
child in that run), before exporting the bundle.

**2. `set_field` leaks two temp files when its write fails.**
The `|| die` added in `e238dbb` fires before the following `rm -f "$t" "$vf"` line, so a genuine
write failure (permissions, disk full) leaves both mktemp files behind. Before that commit there was
no `|| die` and cleanup always ran — silently swallowing the failure along with it, which was worse.
Reached only on real write failures; the OS reaps temp dirs eventually.

## Where

- `skills/engineering/setup-handoff/scripts/payload/handoff` — `export_bundle()`'s pre-flight loop
  for item 1; `set_field()`'s `|| die` and the `rm -f` line after it for item 2.
- `skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh` — the bundle pre-flight
  refusal test asserts zero writes on refusal; extend it rather than adding a parallel block.

## Verify

For item 1 — claim one child of a bundle as the acting session, then export the bundle. It should
succeed, skipping the claim for the already-held child while claiming the rest, and it must still
refuse when a **foreign** session holds a child. Both paths need a test.

For item 2 — make `set_field`'s destination unwritable and confirm no temp files survive. A `trap`
or moving cleanup before the `die` both work; keep whichever reads more like the surrounding code.

## Decisions

- Item 1 must not reintroduce the original defect: a mid-loop failure that leaves some children
  stamped and claimed with no reverse operation. Pre-flight everything before writing anything.
- A narrow TOCTOU window between pre-flight and claim is **accepted** and out of scope. Closing it
  needs a board-wide lock the CLI does not have, and it is not what the original finding described.

## Suggested skills

`x442-delegate-handoff` for the delegation loop these sit in; `x442-run-handoff` for the claim and
release discipline around the lease behaviour item 1 touches.

## Activity

- 2026-08-22 — open — released by Gunn Bhatrakarn (a84bbfe9). parked at the whole-branch review; not started
