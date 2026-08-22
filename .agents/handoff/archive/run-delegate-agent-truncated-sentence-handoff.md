---
id: run-delegate-agent-truncated-sentence-handoff
title: Truncated sentence in run-delegate-agent step 2
type: coordination
status: done
audience:
repos: []
severity: low
created: 2026-08-23
updated: 2026-08-23
note:
verified_at: 2026-08-23
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

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

## Context

`skills/personal/run-delegate-agent/SKILL.md` step 2 ("Ask the user, and say what you concluded")
carried a truncated sentence — the quoted example ended mid-clause and the sentence's own subject
was missing, so the paragraph read as two fragments spliced together:

```text
If the agent is third-party, say so in the prompt. "This sends the file to someone who cannot
information the user needs before answering, not after.
```

Root cause: the text has been wrong since the skill first landed (`b74b768 feat(feature): add
run-delegate-agent skill`) — `git log -S` finds no later edit, so it was an authoring slip, not a
regression. It is the paragraph that tells an agent to disclose third-party egress before asking
for approval, which is the one disclosure in the suite with real consequences, so a garbled
instruction there is worth fixing rather than leaving.

## Where

- `skills/personal/run-delegate-agent/SKILL.md:56-57` — the truncated sentence.
- No mirror copies: `grep -rln 'information the user needs before answering'` matched only that
  one file, so nothing in `harness/` or a payload needed the same edit.

## Verify

```bash
sed -n '56,57p' skills/personal/run-delegate-agent/SKILL.md
npx prettier --check skills/personal/run-delegate-agent/SKILL.md
```

## Decisions

The completion is reconstructed from the suite's own wording rather than invented — the missing
clause matches `setup-delegate-agent`'s "a third-party agent means source code reaches someone who
cannot already see it" and this skill's own party table. Fixed as:

```text
If the agent is third-party, say so in the prompt. "This sends the file to someone who cannot
already see this code" is information the user needs before answering, not after.
```

## Suggested skills

None — a one-sentence doc fix.

## Activity

- 2026-08-23 — done — verified against live code by Gunn Bhatrakarn (352eb75b): read skills/personal/run-delegate-agent/SKILL.md:56-57 after the edit — sentence now reads whole; grep -rln found no other copy to fix; prettier --check passes.
