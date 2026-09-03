---
id: rate-limit-handoff
title: Rate limiter admits a burst past the configured ceiling
type: coordination
status: open
audience:
repos: []
severity: medium
environment: prod
sensitivity: normal
depends_on: []
created: 2026-08-25
updated: 2026-08-25
note:
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

The token bucket refills on wall-clock elapsed time rather than on the request timestamp, so a client that pauses and resumes is granted a burst above the configured ceiling.

## Where

src/limit/bucket.js:17 computes `refill` from `Date.now()` instead of the request's own received-at stamp, which src/limit/bucket.js:7 already captures.

## Verify

Run `npm test -- rate-limit`. The spec `refuses a burst after an idle gap` must pass.

## Decisions

<!-- Anything settled that the next agent must not relitigate. -->

## Suggested skills
