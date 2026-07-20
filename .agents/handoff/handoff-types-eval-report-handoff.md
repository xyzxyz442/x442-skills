---
id: handoff-types-eval-report-handoff
title: Evaluation report — handoff types (standalone/isolated)
type: standalone
status: open
created: 2026-07-20
updated: 2026-07-20
note:
---

<!-- NEVER COMMIT SECRETS. This doc is committed to git history. Redact any keys,
     secrets, passwords, confidential data, or PII. If a credential is truly needed,
     prompt the user and record its NAME (env var / secret-manager ref), never the value. -->

## Summary

Adds a `type:` to every handoff — `coordination` (default; the lease-gated work item) or
`standalone` (a self-contained reference/knowledge doc that is exempt from the claim gate). Ships
in the `setup-handoff` payload + installer and the `run-handoff` discipline, with a new
`handoff import` command and a `handoff-standalone-template.md`. This repo was migrated: its three
former `.claude/handoff/` reference docs are now `type: standalone` on the board, and this report is
itself a standalone doc (dogfood). **All evals green: 60/60 grader assertions, verifier 18/18.**

## Context

Feature landed across four commits on `feature/handoff-skills` (link, don't duplicate — see
`git log`): `ea0e8fe` (redaction/suggested-skills/link authoring), `344af84` (the type feature),
`d468353` (repo migration), `9d0180c` (prettier-sh formatting). Design and rationale live in the
skill sources — [setup-handoff SKILL](../../skills/engineering/setup-handoff/SKILL.md),
[run-handoff SKILL](../../skills/engineering/run-handoff/SKILL.md), and the payload
[README](../../skills/engineering/setup-handoff/scripts/payload/README.md) — this report evaluates
what shipped, it does not restate it.

### Behavior under test

| Dimension               | Coordination (default)                 | Standalone (new)                       |
| ----------------------- | -------------------------------------- | -------------------------------------- |
| `pretool-edit` gate     | claim-before-edit (blocks non-holders) | **exempt** — editable with no lease    |
| `claim`                 | takes the lease                        | **refused** ("no lease needed")        |
| `release --status done` | requires `--verified-by`               | retires (archives), no `--verified-by` |
| listing                 | Open work table                        | "Standalone / reference" section       |
| session-start injection | "claim before working"                 | "reference — no claim needed"          |
| absent `type:`          | ⇒ coordination (back-compat)           | n/a                                    |

## Results

Deterministic, LLM-free graders (`harness/**/grade.py`) driving the installed `handoff` + `hooks.sh`,
plus the read-only verifier. Reproduce: `python3 harness/setup-handoff-workspace/grade.py <fixture> <eval>`.

| Suite            | Eval                                    | Result              |
| ---------------- | --------------------------------------- | ------------------- |
| setup-handoff    | no-agents-md                            | 3/3                 |
| setup-handoff    | fresh                                   | 5/5                 |
| setup-handoff    | claude-wired                            | 3/3                 |
| setup-handoff    | advisory-wired                          | 2/2                 |
| setup-handoff    | legacy-install                          | 6/6                 |
| setup-handoff    | detect                                  | 6/6                 |
| setup-handoff    | custom-location                         | 5/5                 |
| setup-handoff    | script-behavior                         | 18/18               |
| run-handoff      | discipline-done                         | 7/7                 |
| run-handoff      | discipline-blocked                      | 5/5                 |
| **Grader total** |                                         | **60/60**           |
| verifier         | fresh install (3 tools, claude primary) | 18 passed, 0 failed |

The five type-specific assertions added to `script-behavior`: `new --standalone` writes
`type: standalone`; the gate **allows** a non-holder to edit a standalone doc; `claim` refuses a
standalone; `release --status done` archives a standalone without `--verified-by`; `import` lands a
file typed as standalone. Coordination assertions (gate denies non-holder, `done` needs evidence,
lease lifecycle) still pass unchanged.

## Regressions found and fixed during the work

- **Template leak (latent, pre-existing).** `list`/`index`/session-start scanned `*.md` skipping only
  `INDEX`/`README`, so `handoff-doc-template.md` (and the new standalone template) surfaced as fake
  handoffs. Fixed by excluding both template basenames from every scan and from the gate's
  `doc_id_of`.
- **Shell-format drift.** Script edits diverged from the repo's `prettier-plugin-sh` style; because
  lint-staged only formats `json/md/yml`, the pre-commit hook did not catch it. Reformatted and
  re-propagated (`9d0180c`).
- **Stale wired fixtures.** `claude-wired`/`advisory-wired`/`board-wired` bake the installer's output;
  refreshed to the typed payload so the idempotency evals see current bytes.

## Suggested skills

- [`x442-run-handoff`](../../skills/engineering/run-handoff/SKILL.md) — to file/operate typed handoffs.
- [`x442-setup-handoff`](../../skills/engineering/setup-handoff/SKILL.md) — to (re)install/upgrade a board.

## Notes

- **Limitation — coverage is behavioral, not agentic.** Graders are deterministic; there is no LLM
  A/B run proving an assistant _chooses_ the right type. That remains the deferred harness follow-up.
- **Known cosmetic.** Imported titles containing `:` are stored unquoted (e.g.
  `title: Handoff: ...`); the sed-based `meta` reads them correctly and prettier tolerates them, but a
  strict YAML parser would not. Acceptable for this sed-based tool; revisit if a YAML consumer is added.
