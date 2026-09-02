---
id: auth-hardening-handoff
title: Auth hardening bundle
type: orchestrator
status: open
children: [rate-limit-handoff, key-rotation-handoff]
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

## Bundle

Two units that touch the auth path. One of them is restricted, which is the point of this
fixture: a bundle is refused WHOLE, never child by child.

## Children

<!-- prettier-ignore-start -->
<!-- handoff:children:begin -->

**0/2 done.** Outstanding — rate-limit-handoff (open), key-rotation-handoff (open)

| Child | Status | Acts next | Severity | Updated | Blocked on | Lease |
| --- | --- | --- | --- | --- | --- | --- |
| [Rate limiter admits a burst past the configured ceiling](./rate-limit-handoff.md) | `open` | — | medium | 2026-08-25 | — | — |
| [Rotate the signing keys named in the exposure inventory](./key-rotation-handoff.md) | `open` | — | high | 2026-08-25 | — | — |

<!-- handoff:children:end -->
<!-- prettier-ignore-end -->

## Sequencing

Rate limiting first; the rotation depends on nothing here.

## Suggested skills
