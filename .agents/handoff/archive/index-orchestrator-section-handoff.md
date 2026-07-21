---
id: index-orchestrator-section-handoff
title: INDEX.md lists orchestrators as claimable open work
type: coordination
status: done
audience:
repos: []
severity: medium
created: 2026-07-21
updated: 2026-07-21
note: cmd_index skips standalone but not orchestrator, so a bundle index appears in the Open table with no lease.
verified_at: 2026-07-21
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

`handoff list` and the generated `INDEX.md` disagreed about orchestrators. `cmd_list` gained an
orchestrator section when the type was added; `cmd_index` did not. Its Open-work loop skips
standalone docs (`is_standalone "$f" && continue`) but had no equivalent for orchestrators, so a
bundle fell through into the **Open** table — rendered as an unclaimed task with a blank severity,
blank audience, and an em-dash lease.

That matters more than the `list` view: `INDEX.md` is the committed, generated board that the
AGENTS.md routing block points agents at. An agent reading it would see a bundle index as claimable
work and try to claim it — which `claim` then refuses, because orchestrators hold no lease.

Observed on this repo's own board before the fix:

```text
## Open
| [Handoff protocol: outstanding work bundle](./handoff-protocol-suite-handoff.md) | `open` |  |  | 2026-07-21 | — | — |
```

## Where

- [payload/handoff](../../skills/engineering/setup-handoff/scripts/payload/handoff) — `cmd_index`:
  the Open-work loop needed `is_orchestrator "$f" && continue` alongside the existing standalone
  skip, plus its own Orchestrators section mirroring what `cmd_list` renders.

## Verify

`handoff index` on a board holding an orchestrator: the bundle must NOT appear in the Open table,
and an `## Orchestrators (bundles — no claim needed)` section must render progress derived from the
children (including `MISSING` for a child that names no doc). Covered by `script-behavior` in
`harness/setup-handoff-workspace`.

## Decisions

- **Derive progress in the index too**, rather than reusing a stored value. `cmd_index` calls
  `child_progress` exactly as `cmd_list` does, so the generated board cannot drift from the
  children's real state between regenerations.

## Outcome

Fixed 2026-07-21. `cmd_index` skips orchestrators in the Open table and renders them in their own
section with derived progress. Two new expectations in `grade_script_behavior` assert both halves,
so `list` and `INDEX.md` cannot diverge again.

## Suggested skills

- `x442-setup-handoff` — re-run the installer to propagate the payload to other boards.

## Activity

- 2026-07-21 — done — verified against live code by Gunn Bhatrakarn (c0ebf4f2): handoff index on the live board: bundle no longer in the Open table, renders under '## Orchestrators (bundles — no claim needed)' as 1/4 done with outstanding children listed. 12/12 evals green (script-behavior 39/39 incl. 2 new INDEX assertions); verify-setup-handoff.sh 18/18 0 warnings.
