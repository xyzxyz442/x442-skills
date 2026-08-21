---
id: hostile-unfilled-handoff
title: Report generator times out on large exports
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
brief: .agents/handoff/briefs/hostile-unfilled-handoff.brief.md
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

Large tenant exports (> 50k rows) time out at the 30s gateway limit instead of streaming.

## Where

src/reports/export.js:64 -- the handler buffers the full result set before writing the response.

## Verify

Run `npm test -- report-export` against a 60k-row fixture.

## Decisions

<!-- Anything settled that the next agent must not relitigate. -->

## Suggested skills

<!-- Skills the next agent should invoke to pick this up (e.g. a systematic-debugging
     process skill, a domain skill). List them so continuation starts on the right path. -->

## Activity

- 2026-08-21 — exported as a brief for Acme Contracting
