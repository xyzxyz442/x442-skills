---
id: blocked-on-validation-handoff
title: --blocked-on accepts dangling, self, and standalone blockers
type: coordination
status: done
audience:
repos: []
severity: high
created: 2026-07-21
updated: 2026-07-21
note: A blocked handoff can name a nonexistent or self id, or a standalone doc whose retire path never surfaces dependents — all deadlock silently.
verified_at: 2026-07-21
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

`release --status blocked` requires `--blocked-on` so that a blocked handoff always names something
trackable, and so `surface_unblocked` can announce it the moment the blocker closes. The value is
never validated, so three spellings all deadlock silently — the doc sits `blocked` forever and is
never surfaced as unblocked.

Reproduced against the live payload on a scratch board (2026-07-21):

1. **Dangling blocker.** `release d1 --status blocked --blocked-on nope-does-not-exist` succeeds and
   records `blocked_on: nope-does-not-exist-handoff`. A typo'd id is indistinguishable from a real
   one; nothing ever closes it.
2. **Self-block.** `release s1 --status blocked --blocked-on s1` succeeds and records
   `blocked_on: s1-handoff` — the doc waits on itself. Guaranteed deadlock.
3. **Standalone blocker.** `release d2 --status blocked --blocked-on ref1` succeeds where `ref1` is
   a standalone doc. Retiring a standalone takes a different branch in `cmd_release` that returns
   before `surface_unblocked` is ever called, so the dependent is never announced even when the
   blocker is legitimately retired.

(1) and (2) are validation gaps; (3) is a missing call on a code path that was added later than the
unblock feature. Same symptom, so they belong in one fix.

## Where

- [payload/handoff](../../skills/engineering/setup-handoff/scripts/payload/handoff) — the
  `--blocked-on` case in `cmd_release` normalizes via `resolve_id` but never checks that the target
  exists, is not the doc being released, and is not standalone. `resolve_id` deliberately returns
  the canonical id when no file exists (so `doc_of` can report a good error), so the existence check
  has to be explicit here.
- Same file, the standalone branch of `cmd_release` (the `Retired standalone` path): it ends with
  `cmd_index; return` and never calls `surface_unblocked "$id"`, unlike the coordination `done`
  branch.

## Verify

On a scratch board with the payload installed:

```text
handoff release d1 --status blocked --blocked-on nope   -> must FAIL (no such handoff)
handoff release s1 --status blocked --blocked-on s1     -> must FAIL (cannot block on itself)
handoff release d2 --status blocked --blocked-on ref1   -> either FAIL, or retiring ref1 must
                                                           surface d2 as UNBLOCKED
handoff release d3 --status blocked --blocked-on "external: vendor ticket"  -> must still PASS
```

Then the full suites: `harness/setup-handoff-workspace` and `harness/run-handoff-workspace`. Add the
cases above to `grade_script_behavior` in the setup-handoff grader.

## Decisions

- **`external:` stays unvalidated.** It exists precisely for blockers outside the board.
- **Prefer failing the release over silently rewriting the value.** A typo'd blocker should be a
  loud error at release time, not a doc that looks fine and never unblocks.
- Decide as part of the fix whether a standalone doc is a legal blocker at all. Allowing it means
  adding `surface_unblocked` to the retire path; forbidding it is a one-line check. Allowing is
  probably right — a coordination item genuinely can wait on a reference doc being written.

## Outcome

Fixed 2026-07-21 in the payload, propagated to all four boards.

- `cmd_release` now validates a non-`external:` blocker: it must name a doc that exists (active or
  archived) and must not be the doc being released. Both refuse the release rather than recording an
  id nothing will ever close.
- `external: …` stays unvalidated, as decided — it exists for blockers off the board.
- **Standalone is a legal blocker**, and its retire path now calls `surface_unblocked`. Chose this
  over forbidding it: a coordination item genuinely can wait on a reference doc being written.
- The orchestrator retire path had the identical defect — it was written earlier the same day and
  also returned before announcing dependents. Fixed in the same pass, so all four closing paths
  (coordination done, standalone retire, bundle complete) now surface what was blocked on them.
- 4 new expectations in `grade_script_behavior`: dangling refused, self refused, `external:` still
  accepted, standalone retire surfaces its dependent.

## Suggested skills

- `x442-run-handoff` — claim before editing the payload.
- `superpowers:test-driven-development` — write the four release cases above as failing grader
  expectations first.

## Activity

- 2026-07-21 — open — released by Gunn Bhatrakarn (c0ebf4f2).
- 2026-07-21 — done — verified against live code by Gunn Bhatrakarn (c0ebf4f2): Reproduced all 3 defects pre-fix on a scratch board, then post-fix: dangling blocker refused ('no such handoff to block on'), self-block refused, 'external: vendor ticket' still accepted, standalone retire prints the dependent bo2-handoff. 12/12 evals green (script-behavior 37/37 incl. 4 new blocked-on cases); verify-setup-handoff.sh 18/18 0 warnings.
