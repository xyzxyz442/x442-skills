---
id: frontmatter-colon-fields-handoff
title: note and blocked_on frontmatter values can still carry colons
type: coordination
status: done
audience:
repos: []
severity: low
created: 2026-07-23
updated: 2026-08-03
note:
verified_at: 2026-08-03
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

Same defect class as [[title-colon-frontmatter-handoff]] (fixed): the `handoff` CLI writes
frontmatter values as unquoted YAML, so a `:` inside the value breaks external parsers.
Titles are now folded, but two fields still admit colons:

- `note:` — free text from `--note`, written verbatim into frontmatter by `new`/`import`
  (a note like "see: foo" produces invalid YAML).
- `blocked_on:` — the documented `external: vendor ticket` convention produces
  `blocked_on: external: vendor ticket`, invalid YAML by design. A harness expectation
  ("an external: blocker is still accepted unvalidated") pins this format, and the unblock
  logic parses it, so changing it is a design decision, not a mechanical fold.

Fix (this session): `norm_title()` was generalized to `fold_colons()` and applied to every
free-text frontmatter value the CLI writes — `note`, and also `audience`/`severity`, which
turned out to have the same hole and were never listed. `blocked_on` keeps `external: …` as
the spelling to *type* and folds it on write, so it stores as `external — …`.

## Where

- `skills/engineering/setup-handoff/scripts/payload/handoff` — `norm_title()` renamed to
  `fold_colons()` (same fold, now documented as applying to any unquoted value); applied to
  `note`/`audience`/`severity` once in `cmd_new` and to `note`/`severity` in `cmd_import`,
  before any type branch, so all three template branches and their heredoc fallbacks are
  covered by one call; applied to the `external:` arm of the `blocked_on` case in `cmd_release`,
  which also now accepts the `external — …` and `external - …` spellings.
- Installed copies synced: `.agents/handoff/handoff`, the three harness fixture boards, and the
  shared cross-repo board at `../ais/src/.agents/handoff/handoff` (plus its `README.md`).
- `harness/setup-handoff-workspace/grade.py` — new `_fm_colon_offenders()` helper (no yaml
  dependency); the `external:` expectation now asserts colon-free storage; three added:
  `--note` folding, the em-dash blocker spelling, and a catch-all sweep over every doc the
  suite writes.
- Docs: `skills/engineering/run-handoff/SKILL.md`, `skills/engineering/setup-handoff/scripts/
  payload/README.md` (Naming + the `blocked_on` field row),
  `skills/engineering/setup-handoff/assets/agents-handoff.md`, `AGENTS.md` routing block.

## Verify

```text
cd harness/setup-handoff-workspace && python3 grade.py fixtures/claude-wired script-behavior
```

Expect 52/52, including "a ':' in --note is folded to an em dash", "an external: blocker is
still accepted unvalidated, stored colon-free", and the catch-all "every doc this suite wrote
has YAML-safe frontmatter". Or directly: `handoff new t --note "a: b"` and a doc released
`--status blocked --blocked-on "external: x"` both produce frontmatter a strict parser accepts
(no python yaml module here — use `ruby -ryaml -rdate -e 'YAML.safe_load(fm, permitted_classes:
[Date])'`).

## Decisions

- ~~Do not silently fold `blocked_on`~~ — resolved: the *typed* spelling stays `external: …`
  (every doc, the usage string, and the harness expectation keep their meaning), and only the
  stored value is folded. Nothing reads the colon: the hooks take `${bo%% *}` — "external",
  never an archived id — `surface_unblocked` substring-matches the closed id, and list/INDEX
  only display it. The `external — …` spelling is accepted on input too, so either round-trips.
- Folding, not quoting, for the same reason as the title fix: `meta()` reads frontmatter with
  plain sed and would leak literal quotes to every consumer.
- `audience` and `severity` were folded too — same class, same one-line guard, and no valid
  value contains a colon. Leaving them would have spawned a third round of this bug.
- `verify:` is deliberately still excluded: folding would corrupt a shell command, so it needs
  quoting plus a `meta()` that strips quotes. Split out to [[verify-field-yaml-quoting-handoff]].
- The installer only injects the AGENTS.md routing block when absent, so boards installed
  earlier keep the old wording until someone edits it. Unchanged behavior, noted here because
  it is why this repo's `AGENTS.md` block was updated by hand.

## Suggested skills

- x442-run-handoff, x442-setup-handoff.

## Activity

- 2026-08-03 — done — verified against live code by Gunn Bhatrakarn (7e8142fa): harness: setup-handoff script-behavior 52/52 (incl. --note fold, colon-free external blocker storage, and a catch-all frontmatter sweep proven non-vacuous against a pre-fix board), 5 other setup-handoff evals 19/19, run-handoff 12/12, verify-setup-handoff.sh 18 passed/0 warn/0 fail; strict ruby YAML parse of new/import/standalone/orchestrator/blocked docs fails pre-fix and passes post-fix; all 5 installed CLI copies byte-identical to the payload.
