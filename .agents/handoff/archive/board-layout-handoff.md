---
id: board-layout-handoff
title: Restructure the handoff board from flat to scripts/ + templates/
type: coordination
status: done
audience:
repos: []
severity: high
created: 2026-07-21
updated: 2026-07-21
note: Machinery into subfolders; installer auto-migrates flat boards; hook command paths change.
verified_at: 2026-07-21
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

The handoff board was flat: `hooks.sh`, both templates, `config`, `README.md`, `INDEX.md` and every
handoff doc sat in one directory. Housekeeping request: give the board the same shape the
`setup-handoff` skill itself has (machinery in subfolders), and drop the redundant `handoff-` prefix
from doc ids that already carry the `-handoff` suffix.

Chosen layout — machinery only. The `handoff` CLI stays at the board root (it is the documented
entry point in every repo's AGENTS.md), and the docs stay at the root because they are the content.
Only `hooks.sh` and the templates move.

## Where

- [payload/hooks.sh:17-27](../../skills/engineering/setup-handoff/scripts/payload/hooks.sh#L17-L27)
  — `DIR` was `dirname $BASH_SOURCE`; from `scripts/` that resolved to the wrong root. Now probes
  for a sibling `handoff` CLI one level up, falling back to flat.
- [payload/handoff](../../skills/engineering/setup-handoff/scripts/payload/handoff) — new
  `tmpl_path()` resolves `templates/<name>` with a flat fallback; both scaffold sites use it.
- [merge-hooks.py:29-36](../../skills/engineering/setup-handoff/scripts/merge-hooks.py#L29-L36) —
  the idempotency marker. `handoff/scripts/hooks.sh` does NOT contain `handoff/hooks.sh`, so
  matching on the new marker alone would have left stale hook groups in place and appended new ones
  beside them. Both spellings are now recognized.
- [setup-handoff.sh](../../skills/engineering/setup-handoff/scripts/setup-handoff.sh) — flat→nested
  migration (`git mv` where tracked) ahead of the payload install; installs into `scripts/` +
  `templates/`.
- [verify-setup-handoff.sh:39-55](../../skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh#L39-L55)
  — derives a custom board location by `dirname`-ing the hook command path. One `dirname` too few
  now points at `scripts/` instead of the board, so it strips two segments for the new spelling.

## Verify

`harness/setup-handoff-workspace`: 10 evals, including the new `layout-migration` case that
installs, flattens the board back to the old layout, re-installs, and asserts convergence.
`harness/run-handoff-workspace`: 2 evals. Then `verify-setup-handoff.sh` against this repo.

## Decisions

- **Machinery only.** Docs, README, INDEX, config, `archive/`, `.locks/` stay at the board root.
  Moving the docs into `docs/` would have touched every path in the hooks, graders, and AGENTS.md
  examples for a cosmetic gain.
- **The `handoff` CLI does not move.** Every repo's AGENTS.md documents `.agents/handoff/handoff`;
  relocating it would break that contract for no benefit.
- **Auto-migrate on re-run**, matching how legacy `.claude/handoff/` installs are already handled.
  Both `hooks.sh` and the CLI keep a flat fallback so an un-migrated board never breaks in the
  meantime; the verifier reports flat layout as a warning, not a failure.
- **Renames keep meaning.** `handoff-types-eval-report` became `doc-types-eval-report-handoff`
  rather than `types-eval-report-handoff`, which would be vague out of context.

## Outcome

- Board restructured to `scripts/hooks.sh` + `templates/*.md` in the payload, this repo's live
  board, and all three harness fixtures; hook commands rewritten in every tool config.
- `handoff-cross-repo-eval-report-handoff` -> `cross-repo-eval-report-handoff`;
  `handoff-types-eval-report-handoff` -> `doc-types-eval-report-handoff`; cross-references updated
  in `x442-engineering-skills-handoff` and both renamed docs.
- Fixed while here: the grader's `_hook()` helper silently returned `""` for a missing `hooks.sh`,
  and empty output means ALLOW — so every gate assertion would have passed vacuously. It now raises.

## Suggested skills

- `x442-setup-handoff` — re-run the installer in any other repo with a board to migrate it.
- `x442-run-handoff` — the claim/release discipline this board serves.

## Activity

- 2026-07-21 — done — verified against live code by Gunn Bhatrakarn (c0ebf4f2): 12/12 evals green across both harnesses (new layout-migration 10/10, script-behavior 26/26, cross-repo 13/13); verify-setup-handoff.sh 18/18 0 warnings on this repo and 16/16 on a custom --handoff-dir install; live pretool gate fires from .agents/handoff/scripts/hooks.sh; installer re-run on a flattened board migrates with exactly 4 hook entries (no duplicates).
