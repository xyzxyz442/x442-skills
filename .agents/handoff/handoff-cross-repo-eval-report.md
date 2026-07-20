---
id: handoff-cross-repo-eval-report
title: Evaluation report — cross-repo shared-board identity fix
type: standalone
status: open
created: 2026-07-21
updated: 2026-07-21
note:
---

<!-- NEVER COMMIT SECRETS. This doc is committed to git history. Redact any keys,
     secrets, passwords, confidential data, or PII. If a credential is truly needed,
     prompt the user and record its NAME (env var / secret-manager ref), never the value. -->

## Summary

Fixes the three cross-repo SHARED-board defects specified in
[`x442-setup-handoff-shared-board-support`](https://github.com/xyzxyz442) (a board shared by N repos,
e.g. `main-api` + `backoffice-web`). Root cause: the skill treated a **per-consumer fact — repo
identity — as board-global state**, and hardcoded the in-repo default path in human-facing strings.
Fix spine: a per-consumer `HANDOFF_REPO` (baked into each repo's own hook command), preferred over
the shared `config`; the shared `config` no longer carries `REPO_NAME`; the `AGENTS.md` block and the
session-start hint are path-substituted to the real board location. **All evals green: 73/73 grader
assertions (13 in the new `cross-repo` suite), verifier 0-failed on both single- and cross-repo.**

## Context

Single-repo behavior is intentionally **byte-identical** (no `HANDOFF_REPO` → falls back to `config`
`REPO_NAME`), so the fix is additive. Design + rationale live in the skill sources — this report
evaluates what shipped; it does not restate it. See
[setup-handoff SKILL §Cross-repo](../../skills/engineering/setup-handoff/SKILL.md),
[payload README §Shared board](../../skills/engineering/setup-handoff/scripts/payload/README.md).

### Defects → fixes

| #   | Sev     | Defect                                                                                                    | Fix                                                                                                                                                                                                                    |
| --- | ------- | --------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | BLOCKER | Shared `config` `REPO_NAME` single-valued; last installer wins → audience/label/`doc_is_local` mis-driven | Per-repo `HANDOFF_REPO` baked into each hook command (`merge-hooks.py`); `hooks.sh`/`handoff` prefer it; installer omits `REPO_NAME` from a cross-repo `config`; `handoff new` requires `--audience` on a shared board |
| 2   | HIGH    | `AGENTS.md` block (and session-start hint) hardcode `.agents/handoff/` — wrong for any non-default board  | `PLACEHOLDER_HANDOFF_DIR` token in the asset, `sed`-substituted to `HDPATH` on inject; `HANDOFF_HDPATH` baked so the session hint shows the real path                                                                  |
| 3   | LOW     | Cross-repo consumer `.gitignore` `.locks/` line is inert (path outside worktree); verifier warns falsely  | Installer writes the `.locks/` entry only for in-repo boards (keyed on `TOPOLOGY`, not a spoofable path prefix); verifier `.locks/` check is topology-aware                                                            |

## Results

Deterministic, LLM-free graders driving the installed `handoff` + `hooks.sh`, plus the read-only
verifier. Reproduce: `python3 harness/setup-handoff-workspace/grade.py <fixture> <eval>`.

| Suite                                                                                                                       | Evals | Result                                            |
| --------------------------------------------------------------------------------------------------------------------------- | ----- | ------------------------------------------------- |
| setup-handoff (no-agents-md, fresh, claude-wired, advisory-wired, legacy-install, detect, custom-location, script-behavior) | 8     | 48/48                                             |
| setup-handoff · **cross-repo** (new)                                                                                        | 1     | **13/13**                                         |
| run-handoff (discipline-done, discipline-blocked)                                                                           | 2     | 12/12                                             |
| **Grader total**                                                                                                            | 11    | **73/73**                                         |
| verifier · single-repo install                                                                                              | —     | 18 passed, 0 failed                               |
| verifier · cross-repo install                                                                                               | —     | 16 passed, 0 failed (`.locks/` correctly skipped) |

### The new `cross-repo` suite (13 assertions)

Builds `parent/{repo-a,repo-b}` + a shared `parent/handoff`, installs cross-repo in both, and asserts:
the shared `config` **omits `REPO_NAME`**; each repo's hook command carries its **own** `HANDOFF_REPO`;
each `AGENTS.md` block advertises the **shared relative path** (`../handoff`), not `.agents/handoff`;
neither consumer `.gitignore` gained an inert `.locks/` line; **re-installing repo-a does not flip
repo-b's identity** (the spec's exact repro); a session-start in repo-b surfaces **only its own
`audience`** and uses the shared path in its hint; and `handoff new` on the shared board **without
`--audience`/`HANDOFF_REPO` is refused** instead of defaulting to a stale name.

## Suggested skills

- [`x442-setup-handoff`](../../skills/engineering/setup-handoff/SKILL.md) — to (re)install/upgrade a board.
- [`x442-run-handoff`](../../skills/engineering/run-handoff/SKILL.md) — to operate a shared board.

## Notes

- **Out of scope — the live wmboacs board.** This fixes the skill only. To apply it, re-run
  `setup-handoff --topology cross-repo --handoff-dir <board>` in each wmboacs sibling; that replaces
  the interim manual mitigations (blanked `REPO_NAME`, hand-rewritten `AGENTS.md` paths) with the
  installer's correct output.
- **Coverage is behavioral, not agentic** — graders are deterministic; no LLM run proves an agent
  reads its own `audience`. Consistent with the existing harness limitation.
