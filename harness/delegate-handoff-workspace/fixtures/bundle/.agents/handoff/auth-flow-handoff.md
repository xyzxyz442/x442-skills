---
id: auth-flow-handoff
title: Auth flow needs a re-auth prompt after tenant switch
type: coordination
status: open
audience:
repos: []
severity: medium
created: 2026-08-21
updated: 2026-08-21
note:
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

Sessions survive a tenant switch without re-checking authorization, so a user can act with the old tenant's permissions for a few requests.

## Where

src/auth/session.js:20 -- the re-auth check is skipped when `req.session.tenantId` already exists.

## Verify

Run `npm test -- auth-flow`.

## Decisions

<!-- Anything settled that the next agent must not relitigate. -->

## Suggested skills

<!-- Skills the next agent should invoke to pick this up (e.g. a systematic-debugging
     process skill, a domain skill). List them so continuation starts on the right path. -->
