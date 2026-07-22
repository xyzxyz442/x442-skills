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
note: registry of 16 repos still on the echo-fragment chain; migrate each when next working in it (/ais/ excluded)
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

**A full-depth workspace audit on 2026-07-23 produced the registry in "Where" below: 16 repos still
carry the old chain.**

Two corrections to earlier readings of this handoff, both worth knowing before you trust any number
in it:

1. **An initial scan used `-maxdepth 3` and found only 5 carriers. That was wrong** — it could not
   see anything nested at `<repo>/src/<project>/`, which is where most of them live. The full-depth
   sweep found 21 before exclusions. Use the command in **Verify**, not a shallower one.
2. **These repos were mostly not "wired by this skill."** Several predate it by up to two years. The
   echo-fragment chain is a personal convention the skill later codified, so this is a **convention
   rollout across a portfolio**, not repair of the skill's own output. That reframes the urgency: no
   repo here is broken, they are just on the older shape.

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

### Registry — 16 repos to migrate (audited 2026-07-23, full depth)

**Nothing here has been modified.** By decision, each repo is migrated when someone next works in it,
not in a sweep. `dirty` is the uncommitted-file count at audit time; treat a dirty tree as a reason to
migrate on a clean baseline instead, not as a blocker to route around.

| Repo (under `~/Work/Projects`)               | Dirty | Last commit | Branch                           |
| -------------------------------------------- | ----- | ----------- | -------------------------------- |
| `impexagentsu-com/src/main-web`              | 0     | 10w         | main                             |
| `wmboacs-com/src/backoffice-web`             | 2     | 23h         | develop                          |
| `wmboacs-com/src/main-api`                   | 11    | 24h         | develop                          |
| `yupp-labs/src/badmintime-main-api`          | 22    | 3w          | main                             |
| `x442-skills copy`                           | 8     | 6w          | main                             |
| `teebat`                                     | 24    | 3mo         | develop — see the caveat below   |
| `x-carpe-noctem/src/nextjs-project-template` | 7     | 6mo         | main                             |
| `x-carpe-noctem/src/library-node-common`     | 0     | 11mo        | main                             |
| `x-carpe-noctem/src/library-node-data`       | 1     | 11mo        | main                             |
| `givery/src/recipe-api`                      | 0     | 1y          | main                             |
| `merchant-payment-e2p/src/main-api`          | 0     | 1y5mo       | feature/migrate-library-core-api |
| `self/zeals-data-engr-tech-asgmt`            | 2     | 1y5mo       | develop — Python, see note       |
| `wmboacs-com/src/main-web`                   | 0     | 1y8mo       | release/0.x.y                    |
| `verk/src/zoom-web`                          | 0     | 1y10mo      | release/2.x.y                    |
| `verk/src/zoom-web-refactor`                 | 18    | 1y11mo      | feature/revamp-migrate-to-nextjs |
| `2c2p/src/soft-arch-tech-asgmt`              | 0     | 2y          | main                             |

**Permanently excluded — do not re-add:**

- **Anything under a path containing `/ais/`.** That is 227 `package.json` files under `./ais` plus
  `./work/ais/**`; deliberately out of scope for this handoff.
- `wmboacs-com/src/_legacy/{backoffice-web copy, backoffice-web-legacy, backoffice-web-new}` — parked
  under `_legacy`, one carrying 193 uncommitted files.
- `self/zeals-data-engr-tech-asgmt-develop` — not a git repository, a loose directory snapshot with
  nothing to revert to.

**Per-repo caveats.**

- **`teebat`** — its entire tree is **untracked** (`package.json`, `src/`, `next.config.ts`,
  `wrangler.jsonc`); the last commit predates the current Next.js/Cloudflare app. Commit that tree
  before migrating, so there is a baseline to diff against. It also wires a third hook to
  `scripts/prepare-commit-msg.sh` (a commitizen wrapper firing `cz` on an empty `-m`) — deleting
  `prepare` orphans it, so chain it explicitly:
  `"install:dev": "pnpm install && scripts/husky.sh install && pnpm run install:dev:prepare-commit-msg"`.
  Its `format`/`format:fix` already match the new shape; leave them. Its `lint` is `eslint --fix`
  with no path — check what that resolves to under its flat config before splitting it.
- **`self/zeals-data-engr-tech-asgmt`** — Python, and on an older idiom than this skill ever emitted
  (`source .venv/bin/activate && …` plus a `prepare:setup` doing `pip install -r requirements.txt`).
  Migrating means adopting `scripts/py-tool.sh` and rethinking that bootstrap, not a mechanical
  find-and-replace.
- **Any repo whose `lint` carries `--fix`** (several do) — split into check-only `lint` plus
  `lint:fix` as part of the migration.

## Verify

Per migrated repo: `bash verify-project-tooling.sh <repo>` reports `scripts/husky.sh is executable`
and `commit-msg hook generated at install time (scripts/husky.sh install)` with 0 failed and **no**
legacy warning; `.husky/commit-msg` and `.husky/pre-commit` are one-line wrappers and executable; a
non-conventional commit message is rejected and a conventional one passes.

**This handoff closes `done` when every repo in the registry has cleared that check.** Tick them off
in the table as you go — a migration happens when someone next works in that repo, so this stays
`open` for a while by design.

To re-audit (full depth; the earlier `-maxdepth 3` version missed most carriers):

```text
cd ~/Work/Projects
find . \( -type d \( -name node_modules -o -name .git -o -name .venv -o -name dist -o -name .next \) -prune \) \
  -o -type f -name package.json -print \
  | grep -v '/ais/' \
  | tr '\n' '\0' | xargs -0 grep -l 'prepare:commit-msg\|prepare:pre-commit'
```

Cross-check every hit against the registry and the permanent-exclusion list before treating it as new
work — the exclusions still match this grep.

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
- **Foreign repos are not migrated unilaterally, and not in a sweep.** The audit deliberately stopped
  at reporting. Each repo in the registry is migrated when someone next works in it, on a clean
  baseline — rewriting 16 separate repos in one pass would be 16 unreviewed changes across
  independent histories, and a repo dormant for two years gains nothing from it.
- **`/ais/` is out of scope by instruction**, both `./ais` (227 `package.json`) and `./work/ais/**`.
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
- 2026-07-23 — open — released by Gunn Bhatrakarn (1806ddb8). full-depth re-audit: registry of 16 carriers recorded; /ais/ and _legacy copies excluded; nothing migrated by decision
