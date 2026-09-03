---
id: sample-repair-handoff
title: Sample board entry
type: coordination
status: open
audience: 
repos: []
severity: low
created: 2026-08-20
updated: 2026-08-20
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

<!-- What is the work? Why now? Link the symptom to the root cause.
     Link, don't duplicate: reference existing artifacts (PRDs, plans, ADRs, issues,
     commits, diffs) by path or URL instead of pasting their content here. -->

## Where

<!-- Concrete file:line locations in the target repo(s). Read the code; do not guess. -->

## Verify

<!-- How the NEXT agent confirms this is done against the LIVE code — a test to run,
     a flow to exercise, a file:line to check. `release --status done` needs this as
     `--verified-by`. Optionally add a `verify:` frontmatter command (never auto-run). -->

## Decisions

<!-- Anything settled that the next agent must not relitigate. -->

## Suggested skills

<!-- Skills the next agent should invoke to pick this up (e.g. a systematic-debugging
     process skill, a domain skill). List them so continuation starts on the right path. -->
