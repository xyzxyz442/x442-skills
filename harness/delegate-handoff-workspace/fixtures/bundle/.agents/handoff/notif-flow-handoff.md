---
id: notif-flow-handoff
title: Notification flow leaks cross-tenant unread counts
type: coordination
status: open
audience:
repos: []
severity: high
created: 2026-08-21
updated: 2026-08-21
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

The unread-count badge is computed from a socket room keyed on user id only, so a tenant switch leaks the previous tenant's unread count into the new tenant's badge.

## Where

src/notifications/badge.js:33 -- the room key omits `tenantId`.

## Verify

Run `npm test -- notif-flow`.

## Decisions

<!-- Anything settled that the next agent must not relitigate. -->

## Suggested skills

<!-- Skills the next agent should invoke to pick this up (e.g. a systematic-debugging
     process skill, a domain skill). List them so continuation starts on the right path. -->
