---
id: husky-dispatcher-migration-handoff
title: Migrate repos wired by the pre-dispatcher husky hook chain
type: coordination
status: open
audience:
repos: []
severity: low
created: 2026-07-22
updated: 2026-07-23
note: setup-project-tooling now installs scripts/husky.sh; older installs still carry the echo-fragment chain
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

`setup-project-tooling` used to generate git hooks by echoing shell fragments out of a fan-out of
`package.json` scripts (`prepare` → `prepare:commit-msg` + `prepare:pre-commit` →
`prepare:pre-commit:*`). That shape needed `rm -f` to truncate the hook before the `>>` fragments
appended (against the AGENTS.md house rule), put hook logic in JSON-escaped shell, relied on `echo`
expanding `\n` (bash's builtin does not), and resolved binaries with `npx --no --`, which cannot see
local binaries under Yarn PnP or a strict pnpm store.

The skill now copies `assets/husky.sh` to `scripts/husky.sh` — a sub-command dispatcher in the same
shape as `initialize.sh` — and `package.json` carries a single command,
`"install:dev": "<pm> install && scripts/husky.sh install"`. Each generated hook is one line handing
git's arguments to the dispatcher.

This repo has been migrated (commit `15c39af`).

**A workspace-wide audit on 2026-07-23 found the original premise was largely wrong.** Scanning every
`package.json` under `~/Work/Projects` (depth 3, excluding `node_modules`) for `prepare:commit-msg` /
`prepare:pre-commit` returned five hits, of which only one is a genuine migration target — and it is
deferred by decision, not by oversight. Do not re-run the sweep; the results are in **Where** below.

## Where

- Skill and asset: `skills/engineering/setup-project-tooling/SKILL.md` (see "package.json + the
  hook-install command", including the "Migrating a repo wired by an earlier version" paragraph) and
  `skills/engineering/setup-project-tooling/assets/husky.sh`.
- Migration steps per repo: remove the `<cmd>:commit-msg`, `<cmd>:pre-commit`, and
  `<cmd>:pre-commit:*` scripts; replace them with a single `install:dev` command (deleting any
  `prepare` entry the skill previously wrote); copy `assets/husky.sh` to `scripts/husky.sh` and
  `chmod +x`; re-run the command. For a Python repo also copy `assets/py-tool.sh` to
  `scripts/py-tool.sh`, since the lint-staged commands now invoke it instead of `.venv/bin/...`.
- The bundled verifier accepts both shapes deliberately —
  `skills/engineering/setup-project-tooling/scripts/verify-project-tooling.sh` passes a legacy repo
  and emits `[warn] legacy hook chain detected`, so nothing goes red before a repo is re-run. That
  warning is how you find the repos still needing migration.

### Audit results (2026-07-23) — the sweep is done, do not repeat it

| Repo (under `~/Work/Projects`)    | Carries old chain | Verdict                                                                                                                                                                   |
| --------------------------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `teebat`                          | yes               | **The only real target.** Deferred — see below.                                                                                                                           |
| `self/zeals-data-engr-tech-asgmt` | yes               | Out of scope: dormant 1yr5mo, never wired by this skill (no `AGENTS.md`, no `commitlint.config.mjs`), hand-rolled `source .venv/bin/activate` + `requirements.txt` idiom. |
| `self/zeals-…-asgmt-develop`      | yes               | Out of scope: **not a git repository** — a loose snapshot copy.                                                                                                           |
| `x442-skills copy`                | yes               | Out of scope: a backup copy of this repo.                                                                                                                                 |
| `x442-skills`                     | —                 | Migrated in `15c39af`.                                                                                                                                                    |

**Why `teebat` is deferred, and what it needs.** Its entire working tree is **untracked** —
`package.json`, `src/`, `next.config.ts`, `wrangler.jsonc`, all of it. The last commit (3 months ago,
"Update index.html") predates the current Next.js/Cloudflare app. Rewriting an uncommitted
`package.json` means editing WIP with no baseline to diff or revert against, so the migration waits
until that tree is committed by its owner. When it is, the steps are:

1. Copy `assets/husky.sh` to `teebat/scripts/husky.sh` and `chmod +x`.
2. Replace `prepare`, `prepare:commit-msg`, `prepare:pre-commit` and the three
   `prepare:pre-commit:*` scripts with
   `"install:dev": "pnpm install && scripts/husky.sh install"`.
3. **Do not lose `prepare:prepare-commit-msg`.** teebat wires a third hook to
   `scripts/prepare-commit-msg.sh` (a commitizen wrapper that runs `cz` when you commit with an empty
   `-m`). The dispatcher has no such sub-command by decision, and deleting `prepare` would otherwise
   orphan that script — so chain it explicitly:
   `"install:dev": "pnpm install && scripts/husky.sh install && pnpm run install:dev:prepare-commit-msg"`.
4. Split its `lint` (currently `eslint --fix`, which mutates and takes no path) into a check-only
   `lint` plus a `lint:fix`. Verify what `eslint` with no path resolves to under its flat config
   before choosing the replacement glob rather than assuming.
5. `format` / `format:fix` already match the new shape exactly — leave them alone.

## Verify

Per migrated repo: `bash verify-project-tooling.sh <repo>` reports `scripts/husky.sh is executable`
and `commit-msg hook generated at install time (scripts/husky.sh install)` with 0 failed and **no**
legacy warning; `.husky/commit-msg` and `.husky/pre-commit` are one-line wrappers and executable; a
non-conventional commit message is rejected and a conventional one passes.

**This handoff closes `done` when `teebat` clears that check** — it is the only outstanding carrier.
Re-running the audit is not required and not wanted; if you want to confirm nothing new appeared,
the one-liner is:

```text
find ~/Work/Projects -maxdepth 3 -name package.json -not -path '*/node_modules/*' \
  -print0 | xargs -0 grep -l 'prepare:commit-msg\|prepare:pre-commit'
```

Note it also matches the three out-of-scope entries in the table above; check a hit against that
table before treating it as new work.

## Decisions

Settled during the redesign — do not relitigate:

- One dispatcher for all hooks, not one script per hook; `install` and the hook bodies live in the
  same file.
- `husky.sh` is standalone from `initialize.sh` and carries its own `detect_pm`. A git hook that runs
  on every commit must not depend on the bootstrap script's failure surface.
- `pre-commit` runs **lint-staged only**. Whole-repo `format:fix` / `lint` were deliberately kept out
  of the hook: lint-staged already formats and lints staged files, so the whole-repo variants add no
  coverage while rewriting unstaged files and failing commits over pre-existing errors elsewhere.
  They stay as manual and CI scripts.
- The hook-install command is **`install:dev`, never `prepare`**. `prepare` is an npm lifecycle
  script that fires on every plain install (CI and Docker builds included) and is frequently owned by
  a DevOps pipeline, so the skill leaves it alone. The accepted cost: a plain install no longer wires
  hooks, so the command self-installs and must be run once per clone (`initialize.sh` covers anyone
  opening the workspace).
- `format` / `format:fix` are the unscoped `prettier --check .` /
  `prettier --write --list-different .` pair in every repo. Scope belongs to `.prettierignore`, not
  globs in `package.json`. Prettier 3 reads `.gitignore` by default, so build output is already out.
- ESLint keeps an explicit glob over the detected code directories (`src`, `apps`, `libs`, `test`,
  `tests`, `__tests__`), because there is no eslint equivalent of `.prettierignore` that this skill
  owns. `lint` is check-only; `lint:fix` carries `--fix`.
- **`prepare-commit-msg` stays out of the dispatcher**, re-confirmed on 2026-07-23 against real
  usage. `teebat` genuinely uses that hook (a commitizen wrapper), which is evidence _for_ the hook
  but not for the skill owning it: a repo wanting a third hook keeps its own npm script beside the
  dispatcher. The skill wires `commit-msg` and `pre-commit` only.
- **Foreign repos are not migrated unilaterally.** The audit deliberately stopped at reporting.
  `teebat` waits on its owner committing its tree; the dormant assignment, the non-repo snapshot and
  the backup copy are permanently out of scope.
- Python tooling runs through `scripts/py-tool.sh`, which resolves
  **uvx → `uv tool run` → `pipx run` → `.venv/bin`** and pins ruff/black/sqlfluff versions in that one
  file. The `.venv` path is a real supported fallback, not a legacy leftover: a machine with neither
  uv nor pipx still works, and `initialize.sh` builds the venv with the same pinned specs.

## Suggested skills

- `x442-setup-project-tooling` — re-run it in the target repo; it performs the migration.
- `x442-run-handoff` — claim before working, release with an honest status.

## Activity

- 2026-07-22 — open — released by Gunn Bhatrakarn (1806ddb8). skill + this repo migrated; other repos still to do
- 2026-07-22 — open — released by Gunn Bhatrakarn (1806ddb8). decisions corrected for install:dev + py-tool.sh resolver
- 2026-07-22 — open — released by Gunn Bhatrakarn (1806ddb8). doc consistent with the shipped shape
- 2026-07-23 — open — released by Gunn Bhatrakarn (1806ddb8). audit complete: teebat is the only carrier, deferred until its tree is committed; other three permanently out of scope
