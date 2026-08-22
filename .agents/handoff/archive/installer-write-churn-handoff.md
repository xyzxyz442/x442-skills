---
id: installer-write-churn-handoff
title: Handoff — installer rewrites tool configs that did not change
type: coordination
status: done
audience:
repos: []
severity: low
created: 2026-08-23
updated: 2026-08-23
note:
verified_at: 2026-08-23
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

Two leftovers found while closing [[hook-command-drift-handoff]].

**1. The installer dirtied every prettier-using repo on each run.** `merge-hooks.py` wrote each
tool config unconditionally. It emits expanded JSON; prettier collapses short arrays; the next run
re-expands. The result was a diff with no semantic change on every single install. That matters
because "re-run the installer" is `repair-handoff` step 3's entire remedy — the noise buries a real
wiring change. It also meant `setup-handoff/claude-wired`'s empty-diff assertion passed only
because that fixture happens to be stored in installer format, not because the install was
genuinely idempotent.

**2. The `stale-stamp` eval text had rotted.** It claimed the skill "ships v1" while the skill
ships v9, and said a raw grade only warns when it also fails on the missing `handoff export`.

## Where

- `skills/engineering/setup-handoff/scripts/merge-hooks.py` — `dump()` now compares parsed JSON
  against the file and returns without writing when the data is unchanged. Comparing data rather
  than bytes is the point: it preserves whatever formatting the repo itself applies.
- `harness/repair-handoff-workspace/evals/evals.json` — `stale-stamp` text rewritten to name no
  version (that is what rotted) and to state both expected findings.

## Decisions

- **Compare parsed data, never bytes.** A byte comparison would still rewrite on every prettier
  pass, which is the bug.
- **A missing, unreadable, or non-JSON file falls through and writes.** Only a successful parse
  that equals the new data suppresses the write, so a corrupt config is still repaired.
- **No `payload.version` bump.** This changes when a file is written, not what is installed; v9
  already directs every install to re-run.
- **Nothing to migrate in the handoff docs.** All 24 (open and archived) already match their
  type's template exactly. The four archived standalone docs carrying `status: done` with no
  `verified_at` are correct — `handoff:1778` retires a standalone with no `--verified-by`, so
  `verified_at` is a coordination-only field.

## Verify

1. Run the installer twice in this repo; `git status` stays clean both times.
2. Wire a genuinely old config and confirm the change is still written:
   `HANDOFF_HDPATH=.agents/handoff HANDOFF_TOOL=claude HANDOFF_PRIMARY=0 python3
skills/engineering/setup-handoff/scripts/merge-hooks.py OLD.json --repo-root DIR` adds
   `--project-dir`.
3. All 12 setup-handoff evals pass, plus repair `healthy` 3/3 and `not-wired` 3/3, run-handoff
   7/7 and 5/5, delegate 7/7, 18/18, 7/7, 7/7. The three pre-state repair targets fail by design.

## Suggested skills

- `x442-repair-handoff` — its step 3 remedy is the thing this makes quiet.

## Activity

- 2026-08-23 — done — verified against live code by Gunn Bhatrakarn (010ceebc): installer run twice in this prettier-formatted repo leaves git status clean (it dirtied .claude/settings.json on every run before); a genuinely old config still gains --project-dir through merge-hooks.py, so real changes are still written; all 12 setup-handoff evals pass including claude-wired's empty-diff and fresh 5/5, plus repair healthy 3/3 and not-wired 3/3, run-handoff 7/7 and 5/5, delegate 7/7 18/18 7/7 7/7; audited all 24 handoff docs open and archived — every one already matches its type's template, and the four archived standalone docs without verified_at are correct per handoff:1778 which retires a standalone with no --verified-by.
