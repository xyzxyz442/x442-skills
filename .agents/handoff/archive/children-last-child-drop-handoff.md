---
id: children-last-child-drop-handoff
title: children_of silently dropped a bundle's last child
type: coordination
status: done
audience:
repos: []
severity: high
created: 2026-07-21
updated: 2026-07-21
note: A tr/while-read pipeline lost the final element, so a 3-child bundle reported 0/2 done.
verified_at: 2026-07-21
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

`children_of` parsed an orchestrator's `children:` list with:

```text
printf '%s' "$raw" | tr ',' '\n' | while IFS= read -r c; do ... done
```

`printf '%s'` emits no trailing newline, so the final field arrives without one. `read` returns
non-zero on a last line with no terminator — it still assigns the value, but `while` evaluates the
status and exits before running the body. The last child was silently discarded.

Observed: a bundle declared with `--children kid-a,kid-b,kid-c` reported `0/2 done` and listed only
two children. Undercounting the denominator is the worst possible failure for this type — a bundle
whose last child is invisible can be closed as complete while that child is still open.

## Where

- [payload/handoff](../../skills/engineering/setup-handoff/scripts/payload/handoff) — `children_of`.

## Verify

Create an orchestrator with three children, one of which is not filed. `handoff list` must show
`0/3 done` and report the unfiled child as `MISSING`. Covered by `script-behavior` in
`harness/setup-handoff-workspace`.

## Decisions

- **Split on `IFS=','` with a `for` loop instead of piping to `while read`.** No subshell, no
  dependence on trailing newlines, and the loop cannot terminate early on a well-formed list.

## Outcome

Fixed 2026-07-21, same session it was introduced. The eval deliberately declares a third child that
names no doc, so both the count and the `MISSING` report are pinned.

## Suggested skills

- `x442-setup-handoff` — re-run the installer to propagate the payload.

## Activity

- 2026-07-21 — done — verified against live code by Gunn Bhatrakarn (c0ebf4f2): 3-child bundle with one unfiled child reports 0/3 done and kid-c-handoff (MISSING); script-behavior eval pins both count and MISSING report.
