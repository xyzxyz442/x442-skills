---
id: key-rotation-handoff
title: Rotate the signing keys named in the exposure inventory
type: coordination
status: open
audience:
repos: []
severity: high
environment: prod
sensitivity: restricted
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

A deploy key and a webhook signing secret were committed to this repo's history and are still inside their validity window. The inventory below names WHICH secrets, by environment variable name, and where each is consumed. No values are recorded here.

## Where

src/auth/signing.js:5-6 name the two secrets; src/auth/signing.js:24 is the overlap window that accepts `SIGNING_KEY_PREVIOUS` and is what closing the rotation removes.

## Verify

Both names resolve from the secret manager and the overlap window is closed: `npm test -- signing-rotation` passes and no request is served with the previous key.

## Decisions

<!-- Anything settled that the next agent must not relitigate. -->

## Suggested skills
