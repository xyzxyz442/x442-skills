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

| Dimension       | Detect from                                                                                                                | Support          |
| --------------- | -------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| Package manager | `pnpm-lock.yaml`→pnpm, `yarn.lock`→yarn, `package-lock.json`→npm, `bun.lockb`→bun; no lockfile → default **npm**           | —                |
| Language        | `tsconfig.json`/`*.ts`→**Node/TypeScript**; `pyproject.toml`/`*.py`→**Python**; `*.sql` alongside Python→**Python-stream** | fully supported  |
| Language        | `*.csproj`/`*.sln`→C#; `Chart.yaml`→Helm; `go.mod`→Go; `Cargo.toml`→Rust; anything else                                    | common base only |
| Framework       | `next` dep→Next.js, `@nestjs/*` dep→NestJS, `react` dep→React                                                              | Node/TS touches  |

- **Category → always confirm.** Present the detected category as a recommendation and let the user
  choose. In Claude Code, use `AskUserQuestion` with options **frontend / backend / library / other**,
  the detected one first and marked "(Recommended)". Inference hint: Next/React→frontend,
  NestJS→backend, `"private": false` or a `bin`/`exports` field→library, else other (ETL/data).
- **Language → report, don't prompt,** when it is unambiguous (a lockfile, `pyproject.toml`, or a
  project file is factual). Prompt only when the repo is empty or genuinely mixed.
- **Python-stream** is plain Python plus the SQL add-on — trigger it when `*.sql` files are present.

Category is **lightweight**: it only sets the release-it default and framework expectation. The
**language** drives which lint/format fragments get applied.

| Category           | release-it default |
| ------------------ | ------------------ |
| Frontend / Backend | optional (ask)     |
| Library            | **on**             |
| Other (ETL/data)   | off                |

## Common / base tooling (every repo)

Apply these to every repo regardless of language.

### package.json + the hook-install command

If `package.json` is absent, create a minimal one (`name`, `version`, `"private": true` unless this
is a public library). Copy [`assets/husky.sh`](assets/husky.sh) to `scripts/husky.sh` and mark it
executable (`chmod +x scripts/husky.sh`). Then merge in a **single** command that installs the
hooks, plus the scripts the hooks and CI call:

```json
{
  "scripts": {
    "install:dev": "pnpm install && scripts/husky.sh install",
    "format": "prettier --check .",
    "format:fix": "prettier --write --list-different .",
    "lint-staged": "lint-staged"
  }
}
```

Adapt `pnpm`/`npm`/`yarn`/`bun` to the detected manager.

`scripts/husky.sh` is a sub-command dispatcher, the same shape as `initialize.sh`:

| Sub-command  | Role                                                                                         |
| ------------ | -------------------------------------------------------------------------------------------- |
| `install`    | Runs husky, then writes `.husky/commit-msg` + `.husky/pre-commit` and marks them executable. |
| `commit-msg` | Hook body — `commitlint --edit "$1"`.                                                        |
| `pre-commit` | Hook body — the staged-file checks (`lint-staged`).                                          |

Each generated hook is one command that hands git's own arguments to the dispatcher:

```sh
#!/bin/sh

scripts/husky.sh pre-commit "$@"
```

This keeps `.husky/` out of version control (the base `.gitignore` below ignores `.husky`) and
regenerates the hooks on every install, while the logic that runs on every commit stays in one
committed, reviewable, prettier-formatted script instead of JSON-escaped shell fragments. Binaries
are resolved through the detected package manager's exec form (`pnpm exec` / `yarn exec` / `bunx` /
`npx --no --`), because `npx` cannot see local binaries under Yarn PnP or a strict pnpm store.

Add a step by adding a `run_step` line to the relevant hook function. `run_step` skips a script the
repo does not define, so a Python or base-only repo with no `lint` is never blocked from committing.

**The command is named `install:dev`, never `prepare`.** `prepare` is an npm **lifecycle** script: it
runs automatically on any plain install, including CI jobs and Docker image builds. Two things follow.
Hook installation fires where it has no business firing, and — more importantly — `prepare` is
frequently already owned by a project's DevOps pipeline, so writing to it collides with theirs. Leave
that lifecycle free and use a name nothing runs implicitly.

The cost is explicit and worth stating to the user: **a plain `install` no longer installs the
hooks.** The command therefore installs dependencies itself, so it works from a bare clone, and it
has to be run once by hand. `initialize.sh` runs it on folder-open, so anyone who opens the workspace
is covered.

If the repo already owns a differently named install-time script (`setup`, `bootstrap`), adopt that
one rather than adding a competitor — report the choice, do not prompt. `initialize.sh` resolves the
name at runtime (`install:dev` → `prepare` → whichever script invokes husky), so any of these is
repaired on folder-open.

**Migrating a repo wired by an earlier version.** The previous shape fanned hook bodies out across
`<cmd>:commit-msg`, `<cmd>:pre-commit`, and `<cmd>:pre-commit:*` scripts that echoed shell fragments
into `.husky/`. Remove those scripts, replace them with the single command above, and add
`scripts/husky.sh`. A repo whose hook-install command is `prepare` moves to `install:dev` and the
`prepare` entry is deleted. The bundled verifier accepts either shape and any command name, so a repo
that has not been re-run does not fail CI in the meantime.

Teams that prefer **committed** hooks commit `.husky/commit-msg` and `.husky/pre-commit` as those
same one-line wrappers, drop `.husky` from `.gitignore`, and set the command to plain `husky`.
`scripts/husky.sh` is committed either way — the two modes differ only in whether `.husky/` is
tracked. [`assets/commit-msg`](assets/commit-msg) is the standalone hook body for a repo that wants
neither the dispatcher nor install-time generation.

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
2. **Local hook** → written by `scripts/husky.sh install` and executed by its `commit-msg`
   sub-command (or the committed-hook fallback). Enforcement is **local-only**; this skill does not
   wire a CI workflow.

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
glob; the `*.sh` override lets `prettier-plugin-sh` format shell scripts, including
`scripts/husky.sh` and `initialize.sh`.

`format` and `format:fix` run prettier over the whole tree in **every** repo, language-independent.
Scope is `.prettierignore`'s job, not the script's — no globs in `package.json` to drift out of sync
with the directory layout.

Prettier 3 defaults `--ignore-path` to `[.gitignore, .prettierignore]`, so everything git ignores
(`node_modules`, `dist`, `coverage`, `.venv`, `.husky`, and the graph output directories) is already
skipped. `.prettierignore` then only has to name **committed** files that must not be reformatted —
lockfiles, and `CHANGELOG.md`, which release-it regenerates and prettier would otherwise fight on
every release. The asset keeps the dependency and build entries anyway, as a safety net for repos
whose `.gitignore` is thinner than this skill's base.

Both are manual and CI entry points, **not** hook steps: `lint-staged` already formats staged files,
so running them again on commit would add no coverage while silently rewriting files you never
staged.

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
- **Hook repair = re-run the hook-install command** — resolves the command name
  (`install:dev` → `prepare` → whichever script invokes husky), restores the executable bit on
  `scripts/husky.sh`, and
  regenerates the gitignored `.husky/commit-msg` + `.husky/pre-commit`. A dispatcher that is present
  but not executable counts as broken, since the hooks are one-line wrappers around it.
- **Python** — makes the toolchain runnable through `scripts/py-tool.sh`. With uv or pipx present it
  pre-fetches the pinned tools so the first commit does not pay a download inside a git hook; with
  neither, it creates the `.venv` fallback and installs the versions `py-tool.sh` pins.

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

Tell the user to run the hook-install command once with the detected manager (do **not** run it
automatically): `pnpm run install:dev` / `npm run install:dev` / `yarn install:dev` /
`bun run install:dev`. It installs dependencies and then calls `scripts/husky.sh install`, which runs
husky and writes `.husky/commit-msg` + `.husky/pre-commit`. After that, a bad message is rejected and
staged files are linted on commit.

Because the command is deliberately **not** the `prepare` lifecycle script, a plain
`pnpm install` will _not_ wire the hooks — this run is required, and so is one per fresh clone.
Opening the workspace covers it: the folderOpen task runs `initialize.sh`, which resolves the command
name and runs it.

**Ordering with `setup-graph-hooks`:** husky points git at `.husky/`, so the graph `post-commit`
refresh installs to `.husky/post-commit`. `setup-graph-hooks` already detects husky and handles this
— run or re-run it **after** husky exists.

## Language modules (layered on the base)

### Node / TypeScript (strict)

- **lint-staged** → merge [`assets/lintstaged/nodejs.json`](assets/lintstaged/nodejs.json):
  `"*.{js,jsx,ts,tsx}": ["prettier --write", "eslint --fix", "eslint"]` (format, autofix, then a
  final lint that fails on anything unfixable).
- **lint scripts** → add a check-only `lint` and a mutating `lint:fix`, scoped to the code
  directories that actually exist among `src`, `apps`, `libs`, `test`, `tests`, `__tests__`:

  ```json
  {
    "scripts": {
      "lint": "eslint \"{src,apps,libs,test}/**/*.ts\" --no-error-on-unmatched-pattern",
      "lint:fix": "eslint \"{src,apps,libs,test}/**/*.ts\" --fix --no-error-on-unmatched-pattern"
    }
  }
  ```

  With one directory the brace glob collapses to `eslint "src/**/*.ts"`. Keep `--fix` out of `lint`:
  a CI job running a self-fixing lint repairs the violation in the runner and reports a pass, so the
  error never reaches anyone. Both are manual and CI entry points, not hook steps — lint-staged
  already runs `eslint --fix` then `eslint` on staged files, so a whole-repo pass on commit would
  only fail you for pre-existing errors in files you did not touch.

  Unlike prettier, eslint keeps an explicit glob: `.prettierignore` has no eslint equivalent that
  this skill owns, and the skill reuses whatever eslint config the repo already has rather than
  imposing one.

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

- **Toolchain** → copy [`assets/py-tool.sh`](assets/py-tool.sh) to `scripts/py-tool.sh` and mark it
  executable. ruff and black (and, for stream, sqlfluff) are **not** npm packages, and how they are
  installed varies per machine, so every Python command goes through this one resolver:

  | Order | Runner             | Notes                                           |
  | ----- | ------------------ | ----------------------------------------------- |
  | 1     | `uvx`              | ephemeral, cached, exact pin                    |
  | 2     | `uv tool run`      | when only the `uv` binary is on `PATH`          |
  | 3     | `pipx run --spec`  | same pin, slower                                |
  | 4     | `.venv/bin/<tool>` | traditional virtualenv; whatever the venv holds |

  Falling through all four fails with an install hint rather than a confusing "command not found"
  inside a git hook. **Versions are pinned in `py-tool.sh` and nowhere else** — `package.json` and
  `.lintstagedrc.json` name the tool only, so bumping a formatter is a one-line edit instead of a
  hunt across config files that can silently disagree. `scripts/py-tool.sh --spec ruff` prints the
  pip requirement specifier, which is how `initialize.sh` installs matching versions when it has to
  build the `.venv` fallback.

- **lint + format scripts** → ruff lints, black formats, and prettier still owns everything that is
  not Python:

  ```json
  {
    "scripts": {
      "lint": "scripts/py-tool.sh ruff check .",
      "lint:fix": "scripts/py-tool.sh ruff check --fix .",
      "format": "prettier --check . && scripts/py-tool.sh black --check .",
      "format:fix": "prettier --write --list-different . && scripts/py-tool.sh black ."
    }
  }
  ```

- **lint-staged** → merge [`assets/lintstaged/python.json`](assets/lintstaged/python.json):
  `"*.{py,ipynb}": ["scripts/py-tool.sh ruff check --fix", "scripts/py-tool.sh black"]`. lint-staged
  appends the staged paths to each command and re-stages what they rewrite, so neither command names
  a path of its own — a whole-repo `black .` here would reformat files you never staged.
- **editorconfig** → append [`assets/editorconfig/python`](assets/editorconfig/python) (`*.py`,
  `*.ipynb` → 4-space).
- **vscode** → merge [`assets/vscode/python.json`](assets/vscode/python.json) (Pylance analysis,
  `[python]` → black-formatter). It deliberately sets **no** tool paths: with uvx or pipx there is no
  stable executable path to point at, so the extensions resolve from the interpreter the user selects.
- **extensions** → `ms-python.python`, `ms-python.black-formatter`.

### Python (stream)

Python plus a Flink-SQL add-on. It is an **add-on, not a flavour of Python**: apply it in addition to
the Python module only when `*.sql` files are present. A Flink project with no SQL files is plain
Python and gets nothing from this section.

- **lint-staged** → merge
  [`assets/lintstaged/python-stream.json`](assets/lintstaged/python-stream.json): `sqlfluff fix` then
  `sqlfluff lint` on `*.sql`, through `scripts/py-tool.sh`.
- **format scripts** → append the SQL pass to the Python module's scripts:
  `format` gains `&& scripts/py-tool.sh sqlfluff lint . --config .sqlfluff`, `format:fix` gains
  `&& scripts/py-tool.sh sqlfluff fix . --config .sqlfluff`. Both take an explicit `.` — `sqlfluff
lint` with no path has nothing to lint.
- **config** → copy [`assets/sqlfluff`](assets/sqlfluff) to `.sqlfluff` (dialect `flink`). `.sqlfluff`
  is the **single source** of the dialect and no command passes `--dialect`, so switching engine
  (flink / ansi / bigquery / …) is a one-file edit that cannot drift out of sync with the scripts.
- **vscode** → merge
  [`assets/vscode/python-stream.json`](assets/vscode/python-stream.json) (config path only; the
  executable path is omitted for the same reason as the Python module).
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
   `.husky/commit-msg` **or** a hook-install command plus a `scripts/husky.sh` carrying
   `commitlint --edit`). After install, `git commit -m "bad message"` fails and
   `git commit -m "chore: ok"` passes; confirm with `npx commitlint --from HEAD~1 --to HEAD`.
2. **Hooks:** `scripts/husky.sh` is present and executable; `.husky/commit-msg` and
   `.husky/pre-commit` are one-line wrappers calling it and are executable. `scripts/husky.sh -h`
   prints usage. Re-running the hook-install command rewrites both hooks identically.
3. **lint-staged:** `.lintstagedrc.json` resolves with the base `*.{json,yml,yaml,md}` glob plus the
   detected language's globs.
4. **Format and lint:** `<pm> run format` is the unscoped prettier pair, and `prettier --check .`
   skips build output and lockfiles through `.gitignore` + `.prettierignore`. For Node/TS, `lint`
   names only directories that exist and carries no `--fix`. For Python, `scripts/py-tool.sh` is
   executable, `--spec ruff` prints a pinned requirement, and each tool runs — including with `uv`
   and `pipx` removed from `PATH`, which must fall through to `.venv` or fail with the install hint.
5. **Editor:** `.editorconfig`, `.prettierrc`, `.prettierignore`, and `.vscode/settings.json`
   present; `.vscode/extensions.json` lists the stack's extensions; `.vscode/tasks.json` has the
   **Bootstrap Workspace** task and `initialize.sh` is present and executable; `.gitignore` ignores
   `.husky` (plus the base AI paths) and does **not** ignore `scripts/`.
6. **Release (when wired):** `.release-it.json` present and `release` scripts in `package.json`;
   `npm run release:dry-run` produces a changelog preview.
7. **Common-only repos:** an unsupported-language repo still passes the base checks (commitlint,
   `.editorconfig`, a `.lintstagedrc.json` with the base glob), and its `pre-commit` skips any step
   it does not define rather than failing the commit.
8. **Idempotency:** re-running the skill is a no-op for every piece already present, including on a
   repo migrated from the older `<cmd>:commit-msg` / `<cmd>:pre-commit` chain.
