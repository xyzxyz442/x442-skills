# demo-service

A small TypeScript service used as a harness fixture. AI-assistant config is already wired
(AGENTS.md) and `.graph-hooks/core` carries the embed-provider resolver and health checker.
Used to prove the embed-provider consent, unknown-provider, and tier-label regressions cannot
come back — see the `embed-provider-guard` eval.
