---
id: payment-flow-handoff
title: Payment flow must re-validate the tenant's billing plan
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

Billing plan checks are cached per-session and are not invalidated on tenant switch, so a switched-to tenant can be billed under the wrong plan.

## Where

src/billing/plan.js:11 -- `planCache` is keyed on session id, not tenant id.

## Verify

Run `npm test -- payment-flow`.

## Decisions

<!-- Anything settled that the next agent must not relitigate. -->

## Suggested skills

<!-- Skills the next agent should invoke to pick this up (e.g. a systematic-debugging
     process skill, a domain skill). List them so continuation starts on the right path. -->
