---
id: retire-paths-skip-unblock-handoff
title: Retire paths never announced their dependents
type: coordination
status: done
audience:
repos: []
severity: medium
created: 2026-07-21
updated: 2026-07-21
note: The standalone and bundle-complete branches returned before surface_unblocked.
verified_at: 2026-07-21
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

Closing a handoff must announce anything `blocked_on` it, so the dependent surfaces as newly
unblocked at the next session start. Only the coordination `done` branch did that.

`cmd_release` has three closing paths. The standalone retire branch and the orchestrator
bundle-complete branch both ended with `cmd_index; return`, never calling `surface_unblocked`. So a
handoff blocked on a standalone doc or on a bundle stayed blocked forever even after its blocker
legitimately closed.

Root cause is ordering, not logic: the unblock feature predates both branches. Each was added later
and did not pick up the rule. The orchestrator branch reproduced the defect the same day the
standalone one was diagnosed.

## Where

- [payload/handoff](../../skills/engineering/setup-handoff/scripts/payload/handoff) — `cmd_release`,
  the standalone retire branch and the orchestrator bundle-complete branch.

## Verify

Block a coordination doc on a standalone doc, then retire the standalone: the release output must
name the dependent. Same for a doc blocked on an orchestrator when the bundle completes. The
standalone half is covered by `script-behavior`.

## Decisions

- **Every path that closes a doc calls `surface_unblocked`.** Treat it as part of the definition of
  closing, not a step belonging to one branch.

## Outcome

Fixed 2026-07-21 alongside `blocked-on-validation-handoff` (same diagnosis). All three closing paths
now announce dependents.

## Suggested skills

- `x442-setup-handoff` — re-run the installer to propagate the payload.

## Activity

- 2026-07-21 — done — verified against live code by Gunn Bhatrakarn (c0ebf4f2): Retiring standalone boref prints dependent bo2-handoff; orchestrator bundle-complete branch now calls surface_unblocked; script-behavior eval covers the standalone half.
