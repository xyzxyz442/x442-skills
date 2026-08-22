---
id: agents-block-drift-handoff
title: Handoff — setup-handoff never rewrites its AGENTS.md block
type: coordination
status: open
audience:
repos: []
severity: medium
created: 2026-08-23
updated: 2026-08-23
note:
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

`setup-handoff` writes a managed routing block into the target repo's `AGENTS.md`, delimited by
`<!-- handoff:begin (managed by setup-handoff — do not edit between markers) -->` /
`<!-- handoff:end -->`. The installer only ever **injects** that block when it is absent — it has
no path that rewrites an existing one. So once `assets/agents-handoff.md` changes, every repo that
already installed the block keeps the old text forever, and re-running the installer does not fix
it despite the marker declaring the block "managed by setup-handoff".

Found while running `repair-handoff` against this repo. Three consecutive clean runs missed it
because `verify-setup-handoff.sh` only checks that the block is _present_, never that its content
matches the asset.

Live symptom in this repo: the installed block is missing the doc-types paragraph the asset ships
(`coordination` vs `standalone`, `--standalone`, `handoff import`). The board's own open doc is
`type: standalone`, and `AGENTS.md` never explains what that means.

Reproduction:

```text
sed -n '208,263p' AGENTS.md > /tmp/blk.md
diff -u skills/engineering/setup-handoff/assets/agents-handoff.md /tmp/blk.md
```

The hunk removing the "Handoffs have a **type**" paragraph is the drift; the other hunks are the
expected `PLACEHOLDER_HANDOFF_DIR` substitution.

## Where

- `skills/engineering/setup-handoff/scripts/setup-handoff.sh:442` — the insert-only guard
  (`if ! grep -q 'handoff:begin' ...`). Root cause.
- `skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh:189` — presence-only block
  check. Why the drift was invisible.
- `skills/engineering/setup-handoff/scripts/payload.version` — the propagation lever. Without a
  bump, no other install's verifier ever reports that it needs the re-run.
- `skills/engineering/register-cross-repo-handoff/scripts/manifest/render.py:50` — `splice()`,
  the sibling skill's already-correct implementation: replaces between markers, appends when
  absent, raises on duplicate/mismatched markers. Port this rather than reinvent it.
- `skills/engineering/repair-handoff/SKILL.md` — step 2 needs a block-content probe.

`setup-handoff` is the only installer in the repo still using the insert-only guard; the two
cross-repo verifiers already do content-aware block checks.

## Verify

1. `bash skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh .` → 0 failed, and the
   AGENTS.md check reports content match, not just presence.
2. Delete a line from inside the managed block in `AGENTS.md`, re-run the installer, confirm the
   line comes back (the rewrite path works).
3. Corrupt the markers (duplicate a `handoff:begin`), re-run, confirm it refuses with a clear
   error instead of clobbering the file.
4. `diff` the block against the asset with `PLACEHOLDER_HANDOFF_DIR` substituted → identical.

## Decisions

- **Rewrite the block, do not hand-patch `AGENTS.md`.** A hand patch re-drifts on the next asset
  change and teaches nothing. Settled.
- **Rewriting honors the declared contract** — the marker says "do not edit between markers", so
  discarding hand edits inside them is the documented behavior, not a regression. Call it out in
  the commit anyway.
- **Bump `payload.version` 8 → 9.** This is the only mechanism that tells other installs they are
  stale; `verify-setup-handoff.sh` compares stamps and `repair-handoff` step 3 resolves the
  warning by re-running the installer. Fixing the installer without bumping leaves every other
  repo silently stale.
- **Reuse `render.py`'s `splice()` semantics** rather than writing new marker logic. Its
  marker-count guard is the safety that matters.

## Suggested skills

- `x442-repair-handoff` — to re-verify the board and confirm the block check now catches drift.
- `x442-setup-handoff` — the installer being changed; its `verify-setup-handoff.sh` is the harness.
