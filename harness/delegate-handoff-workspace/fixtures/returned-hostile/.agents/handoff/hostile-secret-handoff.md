---
id: hostile-secret-handoff
title: Webhook retries duplicate side effects
type: coordination
status: open
audience:
repos: []
severity: medium
created: 2026-08-21
updated: 2026-08-21
note:
delegated_to: Acme Contracting
delegated_at: 2026-08-21
brief: .agents/handoff/briefs/hostile-secret-handoff.brief.md
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

A retried webhook delivery re-runs its side effect because the idempotency key is derived from the payload body, which the sender regenerates on every retry.

## Where

src/webhooks/deliver.js:48 -- the idempotency key omits the sender's `Idempotency-Key` header.

## Verify

Run `npm test -- webhook-retry`.

## Decisions

<!-- Anything settled that the next agent must not relitigate. -->

## Suggested skills

<!-- Skills the next agent should invoke to pick this up (e.g. a systematic-debugging
     process skill, a domain skill). List them so continuation starts on the right path. -->

## Activity

- 2026-08-21 — exported as a brief for Acme Contracting
