---
name: x442-setup-project-tooling
description: >-
  (Experimental) Use after initial-project, or whenever setting up project dev tooling — commit
  conventions (commitlint + husky), staged-file lint/format (lint-staged), a VS Code workspace, or
  release automation (release-it). Detects the language and recommends a category for you to confirm,
  then applies a common base plus per-language config. Fully supports Python and Node/TypeScript
  (strict); other languages get the common base to customize.
---

# setup-project-tooling

> **Status: experimental.** This skill scaffolds real config files, and its profile detection and
> output may change between versions — review what it writes before relying on it.

Scaffold a project's dev tooling to match what it actually is. Detect the language(s), **recommend a
category for the user to confirm** (frontend / backend / library / other), then wire tooling in two
layers: a **common base** every repo gets, plus **per-language config** layered on top. Everything is
Node-rooted: husky, commitlint, lint-staged, and release-it live in `package.json`, so a
`package.json` must exist (the skill creates a minimal one for a greenfield repo) even when the code
itself is Python or SQL.

Fully supported languages today: **Python** (plus a **Python-stream** Flink-SQL flavor) and
**Node/TypeScript strict** (NestJS / Next.js). Any other language (C#, Helm, Go, Rust, …) gets the
**common base only** — the user adds their own language-specific config from there.

Runs as a repo-onboarding step, typically right after [`initial-project`](../initial-project/SKILL.md)
has created `AGENTS.md`. It is separate from `initial-project` on purpose: that skill owns
AI-assistant configuration; this one owns dev tooling.

## When to use

Use when the user wants to set up or standardize commit messages, pre-commit lint/format, editor
settings, or releases — e.g. "set up commitlint", "add lint-staged", "wire prettier/husky",
"configure the VS Code workspace", "set up release-it". Run from the target project's root.

Everything here is idempotent: detect each piece and skip what is already present. Never overwrite a
config the repo already has unless the user asks; merge into `package.json`, `.vscode/settings.json`,
and `.lintstagedrc.json` round-trip (parse → mutate → write), never splice with `sed`.

## Step 1 — Detect the language, recommend the category, confirm

Read the repo first. **Detect** the package manager and language from filesystem signals;
**recommend** the category and let the user pick.

| Dimension | Detect from | Support |
| --- | --- | --- |
| Package manager | `pnpm-lock.yaml`→pnpm, `yarn.lock`→yarn, `package-lock.json`→npm, `bun.lockb`→bun; no lockfile → default **npm** | — |
| Language | `tsconfig.json`/`*.ts`→**Node/TypeScript**; `pyproject.toml`/`*.py`→**Python**; `*.sql` alongside Python→**Python-stream** | fully supported |
| Language | `*.csproj`/`*.sln`→C#; `Chart.yaml`→Helm; `go.mod`→Go; `Cargo.toml`→Rust; anything else | common base only |
| Framework | `next` dep→Next.js, `@nestjs/*` dep→NestJS, `react` dep→React | Node/TS touches |

- **Category → always confirm.** Present the detected category as a recommendation and let the user
  choose. In Claude Code, use `AskUserQuestion` with options **frontend / backend / library / other**,
  the detected one first and marked "(Recommended)". Inference hint: Next/React→frontend,
  NestJS→backend, `"private": false` or a `bin`/`exports` field→library, else other (ETL/data).
- **Language → report, don't prompt,** when it is unambiguous (a lockfile, `pyproject.toml`, or a
  project file is factual). Prompt only when the repo is empty or genuinely mixed.
- **Python-stream** is plain Python plus the SQL add-on — trigger it when `*.sql` files are present.

Category is **lightweight**: it only sets the release-it default and framework expectation. The
**language** drives which lint/format fragments get applied.

| Category | release-it default |
| --- | --- |
| Frontend / Backend | optional (ask) |
| Library | **on** |
| Other (ETL/data) | off |

## Common / base tooling (every repo)

Apply these to every repo regardless of language.

### package.json + the `prepare` hook chain

If `package.json` is absent, create a minimal one (`name`, `version`, `"private": true` unless this
is a public library). Then merge in the scripts that generate the git hooks at install time — the
canonical pattern (matches the `.husky/`-gitignored convention). Adapt `pnpm`/`npm`/`yarn`/`bun` to
the detected manager in `lint-staged`'s invocation:

```json
{
  "scripts": {
    "prepare": "husky && npm run prepare:commit-msg && npm run prepare:pre-commit",
    "prepare:commit-msg": "echo 'npx --no -- commitlint --edit \"$1\"' > .husky/commit-msg",
    "prepare:pre-commit": "echo 'npx --no -- lint-staged' > .husky/pre-commit",
    "lint-staged": "lint-staged"
  }
}
```

This keeps `.husky/` out of version control (the base `.gitignore` below ignores `.husky`) and
regenerates the hooks on every `install`. Teams that prefer **committed** hooks can instead copy
[`assets/commit-msg`](assets/commit-msg) to `.husky/commit-msg`, `chmod +x` it, and set
`"prepare": "husky"` — documented as a fallback, not the default.

### Base .gitignore

[`assets/gitignore`](assets/gitignore) is the common ignore set — a
[toptal-generated](https://www.toptal.com/developers/gitignore) baseline for
node/yarn/python/macOS/Linux/Windows/SonarQube/virtualenv/VS Code — plus a **user-specific** and
**AI** tail:

```gitignore
# user-specific
.husky
.tmp

# AI
.code-review-graph/
graphify-out/
.claude/settings.local.json
```

Greenfield (no `.gitignore`): copy the asset wholesale. Existing `.gitignore`: append any missing
entries — at minimum the user-specific + AI tail — line-merged; never duplicate a line, never drop
existing entries.

### Commit conventions (commitlint)

Conventional Commits: `type(scope): subject` — lowercase imperative subject, no trailing period,
header ≤100 chars. Scope is optional but, when present, must be in the config enum. The scope-enum is
**universal** (not tailored per category).

1. **Config** → copy [`assets/commitlint.config.mjs`](assets/commitlint.config.mjs) to the repo root
   as `commitlint.config.mjs`.
2. **Local hook** → generated by the `prepare:commit-msg` script above (or the committed-hook
   fallback). Enforcement is **local-only**; this skill does not wire a CI workflow.

### Base staged-file formatting (lint-staged)

Author `.lintstagedrc.json` starting from the base glob — always present in every repo — then stack
the detected language's globs on top:

- Base: [`assets/lintstaged/base.json`](assets/lintstaged/base.json) →
  `"*.{json,yml,yaml,md}": "prettier --write"`.

Merge each fragment as a shallow JSON key-merge into `.lintstagedrc.json`.

### Prettier config

Copy [`assets/prettierrc`](assets/prettierrc) to `.prettierrc` and
[`assets/prettierignore`](assets/prettierignore) to `.prettierignore` (skip if the repo already has a
Prettier config; do not overwrite unless the user asks). These back the base `prettier --write`
glob; the `*.sh` override lets `prettier-plugin-sh` format shell scripts.

### Editor + workspace

1. `.editorconfig` → concatenate [`assets/editorconfig/base`](assets/editorconfig/base) with the
   detected language block(s) (text append). The base covers the global rules, markdown, JSON/YAML,
   and shell.
2. `.vscode/settings.json` → round-trip **deep JSON merge** of
   [`assets/vscode/base.json`](assets/vscode/base.json) plus the language fragment(s). Preserve any
   existing keys (e.g. `chat.agentFilesLocations` set by `initial-project`).
3. `.vscode/extensions.json` → union the recommendations for the detected stack (table under each
   language module). Merge into an existing file; never drop entries.
4. `.vscode/tasks.json` → merge [`assets/tasks.json`](assets/tasks.json) (union the `tasks` array by
   `label`; never drop existing tasks). This registers the workspace-bootstrap task below.

### Workspace bootstrap (auto-init on open)

Copy [`assets/initialize.sh`](assets/initialize.sh) to `initialize.sh` at the repo root and mark it
executable (`chmod +x initialize.sh`). It is committed (not gitignored) and idempotent — it installs
missing dependencies and repairs Husky hooks so a freshly cloned or freshly opened workspace is ready
to commit:

- **Package-manager aware** — detects npm/pnpm/yarn/bun from the lockfile and runs `<pm> install`
  (provisioning yarn/pnpm via corepack when needed).
- **Hook repair = re-run `prepare`** — regenerates the gitignored `.husky/commit-msg` +
  `.husky/pre-commit`, matching this skill's hook convention.
- **Python** — for a Python project, bootstraps `.venv` (uv-first, pip fallback) and installs black
  (plus sqlfluff when `*.sql` is present) when missing.

The `.vscode/tasks.json` task **Bootstrap Workspace** runs `bash ./initialize.sh folder-open --force`
on `folderOpen`, so opening the workspace repairs only what is missing. `full` mode
(`./initialize.sh full`) runs the complete bootstrap on demand.

### Release automation (release-it)

Wire by default for the **library** category; for frontend/backend, ask first; skip for other/ETL.
When wiring:

1. Copy [`assets/release-it.json`](assets/release-it.json) to `.release-it.json`
   (`@release-it/conventional-changelog`, `npm.publish: false` by default — flip for a public library
   the user wants to publish).
2. Add the release scripts to `package.json`:

```json
{
  "scripts": {
    "release": "release-it",
    "release:dry-run": "release-it --dry-run",
    "release:changelog": "release-it --no-git --no-github"
  }
}
```

### Base dev dependencies

Merge into `package.json` (round-trip; preserve all other keys), pinned to the versions this repo
runs. Base (always): `@commitlint/cli ^21.1.0`, `@commitlint/config-conventional ^21.1.0`,
`@commitlint/types ^21.1.0`, `husky ^9.1.7`, `lint-staged ^17.0.8`, `prettier ^3.8.4`,
`prettier-plugin-sh ^0.18.1`. Release-only (when release-it is wired): `release-it ^20.2.0`,
`@release-it/conventional-changelog ^11.0.1`, `conventional-changelog ^7.2.1`. Language toolchains
add their own (see each module).

### Install and activate

Tell the user to run the install once with the detected manager (do **not** run it automatically):
`pnpm install` / `npm install` / `yarn install` / `bun install`. The `prepare` script then runs
husky and writes `.husky/commit-msg` + `.husky/pre-commit`. After that, a bad message is rejected
and staged files are linted on commit.

**Ordering with `setup-graph-hooks`:** husky points git at `.husky/`, so the graph `post-commit`
refresh installs to `.husky/post-commit`. `setup-graph-hooks` already detects husky and handles this
— run or re-run it **after** husky exists.

## Language modules (layered on the base)

### Node / TypeScript (strict)

- **lint-staged** → merge [`assets/lintstaged/nodejs.json`](assets/lintstaged/nodejs.json):
  `"*.{js,jsx,ts,tsx}": ["prettier --write", "eslint --fix", "eslint"]` (format, autofix, then a
  final lint that fails on anything unfixable).
- **editorconfig** → append [`assets/editorconfig/nodejs`](assets/editorconfig/nodejs).
- **vscode** → merge [`assets/vscode/nodejs.json`](assets/vscode/nodejs.json) (workspace TS SDK,
  semicolons, eslint fix-on-save).
- **TypeScript strict** → ensure `compilerOptions.strict` is `true` in `tsconfig.json`. Greenfield:
  create a minimal `tsconfig.json` with `"strict": true`. **Existing** project: set the flag, then
  **report** that enabling strict may surface pre-existing type errors, and offer to relax individual
  flags (`strictNullChecks`, `noImplicitAny`, …) rather than forcing a clean compile in one step.
- **extensions** → `dbaeumer.vscode-eslint`, `esbenp.prettier-vscode`; add
  `bradlc.vscode-tailwindcss` only if Tailwind is detected.
- **Frameworks:** NestJS and Next.js are framework touches on this module, not separate modules — the
  eslint/prettier config and extensions above cover both. Reuse the project's existing eslint setup
  if present rather than imposing one; TS projects also need `eslint` and its config as devDeps.

### Python

- **lint-staged** → merge [`assets/lintstaged/python.json`](assets/lintstaged/python.json):
  `"*.{py,ipynb}": ["./.venv/bin/black --check --diff", "./.venv/bin/black ."]`. black is the
  formatter; tools are invoked from a repo-root `.venv` (adjust the path if the venv lives elsewhere).
- **editorconfig** → append [`assets/editorconfig/python`](assets/editorconfig/python) (`*.py`,
  `*.ipynb` → 4-space).
- **vscode** → merge [`assets/vscode/python.json`](assets/vscode/python.json) (Pylance analysis,
  `python-envs` venv search paths, `[python]` → black-formatter).
- **extensions** → `ms-python.python`, `ms-python.black-formatter`.
- **Toolchain:** black (and, for stream, sqlfluff) are **not** npm packages — install them into
  `.venv` with the Python toolchain, **preferring `uv`, falling back to `pip`**. Detect uv via a `uv`
  on `PATH` or a `uv.lock`; otherwise use pip:
  - uv: `uv venv && uv pip install black sqlfluff`
  - pip: `python -m venv .venv && ./.venv/bin/pip install black sqlfluff`

  The lint-staged hook invokes `./.venv/bin/...` directly, so either installer lands the tools in the
  same place.

### Python (stream)

Python plus a Flink-SQL add-on. Apply **in addition to** the Python module when `*.sql` files are
present.

- **lint-staged** → merge
  [`assets/lintstaged/python-stream.json`](assets/lintstaged/python-stream.json): `sqlfluff fix` then
  `sqlfluff lint` on `*.sql`, dialect `flink`, via `.venv`.
- **config** → copy [`assets/sqlfluff`](assets/sqlfluff) to `.sqlfluff` (dialect `flink`). Change the
  `--dialect` / `.sqlfluff` dialect per your engine (flink / ansi / bigquery / …) if not Flink.
- **vscode** → merge
  [`assets/vscode/python-stream.json`](assets/vscode/python-stream.json) (sqlfluff executable +
  config paths under `.venv`).
- **extensions** → `sqlfluff.sqlfluff`.

### Everything else → common base only

For a recognized-but-unsupported language (C#, Helm, Go, Rust, …), apply the **common base** only,
then tell the user to add their own language-specific config from there:

- Add a lint-staged `glob → command` pair to `.lintstagedrc.json` following the same shape as the
  supported modules (e.g. `"*.go": ["gofmt -w", "golangci-lint run"]`).
- Add editor-format blocks to `.editorconfig` and any language extensions to
  `.vscode/extensions.json`.

Do not invent a full toolchain the user did not ask for — scaffold the base, name the gap, and let
them fill it.

## Future (tracked)

Not yet supported as first-class modules; they currently get the common base only.

- **C#** → likely `dotnet format` / csharpier via lint-staged (or Husky.Net if going native), plus
  `.editorconfig` Roslyn analyzer rules.
- **Helm** → likely `helm lint` + `yamllint` + `kubeconform` + `helm-docs`.

## Verification

Run the bundled checker for a fast pass/fail:
[`scripts/verify-project-tooling.sh`](scripts/verify-project-tooling.sh) — `bash
scripts/verify-project-tooling.sh [repo-root]` (read-only; no network/LLM; exits non-zero on
failure). Then spot-check:

1. **Commitlint:** `commitlint.config.mjs` exists and local enforcement is present (committed
   `.husky/commit-msg` **or** a `prepare` script that generates it). After install,
   `git commit -m "bad message"` fails and `git commit -m "chore: ok"` passes; confirm with
   `npx commitlint --from HEAD~1 --to HEAD`.
2. **lint-staged:** `.lintstagedrc.json` resolves with the base `*.{json,yml,yaml,md}` glob plus the
   detected language's globs.
3. **Editor:** `.editorconfig`, `.prettierrc`, `.prettierignore`, and `.vscode/settings.json`
   present; `.vscode/extensions.json` lists the stack's extensions; `.vscode/tasks.json` has the
   **Bootstrap Workspace** task and `initialize.sh` is present and executable; `.gitignore` ignores
   `.husky` (plus the base AI paths).
4. **Release (when wired):** `.release-it.json` present and `release` scripts in `package.json`;
   `npm run release:dry-run` produces a changelog preview.
5. **Common-only repos:** an unsupported-language repo still passes the base checks (commitlint,
   `.editorconfig`, a `.lintstagedrc.json` with the base glob).
6. **Idempotency:** re-running the skill is a no-op for every piece already present.
