---
id: delegation-fast-follows-handoff
title: Delegation fast-follows — self-held lease preflight and temp-file leak
type: coordination
status: done
audience:
repos: []
severity: low
created: 2026-08-22
updated: 2026-08-22
note:
verified_at: 2026-08-22
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

## Resolved

**Item 1.** A new `lease_is_mine()` answers "does THIS session hold a live lease on <id>?" from the
raw session id the lock records — never the display name, because two concurrent sessions of one
user share a user name and treating those as one session would walk a bundle export straight into
the foreign lease the pre-flight exists to catch. With no session id available at all (advisory
mode) it answers no: a false "yes" is the dangerous direction. An `expired` self-held lease also
answers no, so a normal claim still takes it over and refreshes it.

The carve-out lives in `export_one`, not only in the bundle pre-flight, so both paths follow one
rule. `export_one` **extends** a self-held lease (`cmd_touch`) instead of re-claiming it: the point
of claiming at export time is "a live lease I own for as long as this is out", and renewing reaches
exactly that with a full TTL — whereas merely skipping the claim would leave a lease that can expire
while the brief is in an executor's hands. It reports the extension on **stderr**, because
`export_bundle` sends `export_one`'s stdout to `/dev/null` and "I kept your lease rather than taking
a new one" must not vanish there.

Putting it in `export_one` also fixed the single-export case, which had the same defect for the same
reason: `claim X` then `export X` — investigate, then decide to delegate — died on the caller's own
lease. Fixing only the bundle would have left the two paths disagreeing, which is worse than either
behavior alone. `cmd_claim` itself is untouched: `claim X` on a lease you already hold still reports
CLAIMED, which is correct feedback for a command with nothing to do.

**Item 2.** `set_field` captures the write status into `rc`, runs `rm -f` unconditionally, then
dies. Reporting the failure and cleaning up after it were never a trade.

**A latent test defect surfaced with item 1.** The existing `cmd_export — claim before stamp` case
claimed and then exported from one shell, so whether its lease counted as "foreign" depended on
whether the machine running the suite happened to expose a session id. Under the new rule it became
a _self_-held lease and the test asserted the opposite of its own name. It now claims under an
explicit foreign session id, as does the finding-5 bundle case — both were passing by accident of
environment before.

## Where

- `skills/engineering/setup-handoff/scripts/payload/handoff` — `lease_is_mine()` (new, beside
  `lock_state`); the self-held branch in `export_one()`'s claim step; `export_bundle()`'s pre-flight
  loop; `set_field()`'s `rc` and unconditional `rm -f`.
- `skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh` — the finding-5 and
  claim-before-stamp cases now claim under an explicit foreign session id; three new blocks cover
  the self-held bundle child, the self-held single export, and the temp-file count.
- `skills/engineering/delegate-handoff/SKILL.md` and
  `skills/engineering/setup-handoff/scripts/payload/README.md` — `--no-claim` is for the case it is
  actually for, not for getting around your own lease.
- `skills/engineering/setup-handoff/scripts/payload.version` — bumped to 8; the CLI behaviour
  changed, so a board still on 7 must read as predating it. Propagated to all twelve mirrors.

## Verify

Payload selftest: **129 passed, 0 failed** (was 117). Both paths of item 1 are covered, plus the
single-export equivalents:

- a bundle whose child is leased by the acting session exports cleanly — cover written, both
  children briefed, the free child claimed, and the self-held lease still present, still carrying
  its **original claim note** (a re-claim would have overwritten it, so the note is what proves the
  extend path ran) and pushed back out to a full TTL from a deliberately shortened one;
- a bundle whose child is leased by a **foreign** session still refuses the whole export, with no
  cover, no claim, and no stamp on the untouched child or the orchestrator;
- a single export on a doc the caller holds writes its brief and stamps the delegate;
- a single export on a **foreign**-held doc still refuses, writing nothing.

For item 2, the write-protected release runs under a private `TMPDIR` so the temp files it creates
can actually be counted; the count is 0.

No regressions: setup-handoff 12/12 evals, register-cross-repo-handoff 2/2, and every post-state
eval in repair-, run-, and delegate-handoff. `repair-handoff/stale-stamp` still detects drift
(installed v0 vs shipped v8), so the version bump did not defeat the check that watches it.

## Decisions

- Item 1 must not reintroduce the original defect: a mid-loop failure that leaves some children
  stamped and claimed with no reverse operation. Pre-flight everything before writing anything.
- A narrow TOCTOU window between pre-flight and claim is **accepted** and out of scope. Closing it
  needs a board-wide lock the CLI does not have, and it is not what the original finding described.
- **Extend, do not merely skip.** The finding said "skip the claim for the already-held child". A
  skip leaves the existing expiry untouched, so a lease claimed an hour ago can lapse while the
  brief is out with an executor — the exact thing export claims a lease to prevent. Renewing
  produces what a successful claim would have.
- **Session id, not user name, decides self-ownership**, and no session id means "not mine".
- **The fix belongs in `export_one`, not only in the bundle pre-flight.** Both paths refuse for the
  same reason; fixing one would leave `export <bundle>` tolerating your own lease while
  `export <single>` still died on it.

## Suggested skills

`x442-delegate-handoff` for the delegation loop these sit in; `x442-run-handoff` for the claim and
release discipline around the lease behaviour item 1 touches.

## Activity

- 2026-08-22 — open — released by Gunn Bhatrakarn (a84bbfe9). parked at the whole-branch review; not started
- 2026-08-22 — done — verified against live code by Gunn Bhatrakarn (7b3f9481): Payload selftest 129 passed / 0 failed (was 117). Item 1 covered on both paths plus their single-export equivalents: a bundle child leased by the acting session now exports cleanly with the lease extended to a full TTL and its original claim note intact (a re-claim would have overwritten it), a foreign-leased child still refuses the whole export writing nothing, a single export on a self-held doc succeeds, a foreign-held one still refuses. Item 2 verified by running the write-protected release under a private TMPDIR and counting 0 surviving temp files. Payload bumped to 8 and propagated to all twelve mirrors; repair-handoff/stale-stamp still detects drift (installed v0 vs shipped v8). No regressions: setup-handoff 12/12 evals, register-cross-repo-handoff 2/2, and every post-state eval in repair-, run-, and delegate-handoff..
