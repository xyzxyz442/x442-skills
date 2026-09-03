---
id: tenant-switch-handoff
title: Tenant switch drops session state
type: coordination
status: open
audience:
repos: []
severity: high
created: 2026-08-21
updated: 2026-08-21
note: Filed after a prod incident review.
schema: 1
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Current state

<!-- REWRITABLE. Where this stands right now — overwrite it, do not append. -->

## Context

Users lose their active session when switching tenants mid-request. The symptom traces to the auth middleware reusing a cached tenant id captured before the switch instead of the value on the new request.

## Where

src/auth/tenant-switch.js:42 -- reads `req.session.tenantId` before the switch handler at src/auth/tenant-switch.js:58 updates it.

## Verify

Run `npm test -- tenant-switch`. The failing spec `drops session on tenant switch` in `test/tenant-switch.test.js` must pass.

## Decisions

<!-- Anything settled that the next agent must not relitigate. -->

## Suggested skills

<!-- Skills the next agent should invoke to pick this up (e.g. a systematic-debugging
     process skill, a domain skill). List them so continuation starts on the right path. -->
