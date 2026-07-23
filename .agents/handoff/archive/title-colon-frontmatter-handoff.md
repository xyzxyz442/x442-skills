---
id: title-colon-frontmatter-handoff
title: Colon in handoff titles breaks YAML frontmatter
type: coordination
status: done
audience:
repos: []
severity: low
created: 2026-07-23
updated: 2026-07-23
note:
verified_at: 2026-07-23
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

The `handoff` CLI wrote `title: $title` into doc frontmatter as unquoted YAML. A colon in the
value (`title: Handoff: x442-skills engineering suite`) turns the line into a nested mapping and
breaks every frontmatter parser that reads the doc — the user hit it in VS Code's markdown
preview. Four live docs on this board carried such titles.

Fix (this session): a `norm_title()` fold in the CLI — every `:` in a `--title`, or in the H1
`import` derives a title from, becomes `—` (the board's existing em-dash convention). Rule
documented in the run-handoff skill, the payload README, and the AGENTS.md routing block; the
four live docs were retitled; harness fixtures were re-synced and two grader expectations added.

## Where

- `skills/engineering/setup-handoff/scripts/payload/handoff` — `norm_title()` (after
  `legacy_id()`), applied in `cmd_new` and `cmd_import` (both the `--title` and H1 paths).
- Installed copy synced: `.agents/handoff/handoff`, `.agents/handoff/README.md`.
- Docs: `skills/engineering/run-handoff/SKILL.md` ("Titles never contain `:`"),
  `skills/engineering/setup-handoff/scripts/payload/README.md` (Naming section),
  `skills/engineering/setup-handoff/assets/agents-handoff.md`, `AGENTS.md` (routing block).
- Harness: `harness/setup-handoff-workspace/grade.py` (two new expectations in
  `grade_script_behavior`); fixture boards under `harness/setup-handoff-workspace/fixtures/` and
  `harness/run-handoff-workspace/fixtures/board-wired/` re-synced to the new payload.

## Verify

```text
cd harness/setup-handoff-workspace && python3 grade.py fixtures/claude-wired script-behavior
```

Expect 44/44, including "a ':' in --title is folded to an em dash" and "import folds a ':' in
the H1-derived title too". Or directly: `.agents/handoff/handoff new t --title "A: B"` must land
`title: A — B`.

## Decisions

- Fold to `—`, do not quote: `meta()` and the other plain-sed readers (list, INDEX, hooks)
  would leak literal quotes through, and quoting still leaves naive regex-based preview parsers
  broken on the inner colon.
- Existing docs were retitled in place (frontmatter + H1); ids/filenames untouched.
- `note:` and the `blocked_on: external: …` convention still carry colons — split out to
  [[frontmatter-colon-fields-handoff]], not silently changed here (the `external:` prefix is a
  validated, documented format).

## Suggested skills

- x442-run-handoff (board discipline), x442-setup-handoff (payload/installer layout).

## Activity

- 2026-07-23 — done — verified against live code by Gunn Bhatrakarn (8aabdce4): harness: setup-handoff script-behavior 44/44 incl. both new colon-fold expectations; norm_title applied in cmd_new+cmd_import (payload handoff); board docs re-scanned, zero colon titles remain.
