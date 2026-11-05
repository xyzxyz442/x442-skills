---
name: x442-setup-project-tooling
description: >-
  Use after initial-project, or whenever setting up project dev tooling — commit conventions
  (commitlint + husky), staged-file lint/format (lint-staged), a VS Code workspace, or release
  automation (release-it), including migrating off commitizen and standard-version. Detects the
  language and recommends a category for you to confirm, then applies a common base plus
  per-language config. Fully supports Python and Node/TypeScript (strict); other languages get the
  common base to customize.
---

# setup-project-tooling

> **Status: beta.** Usable on Node/TypeScript and Python repos, with one rough edge — there is no
> installer script, so every merge below is applied by the agent from this body. Review the diff
> before committing it.

Scaffold a project's dev tooling to match what it actually is. Detect the language(s), **recommend a
category for the user to confirm** (frontend / backend / library / other), then wire tooling in two
layers: a **common base** every repo gets, plus **per-language config** layered on top. Everything is
Node-rooted: husky, commitlint, lint-staged, and release-it live in `package.json`, so a
`package.json` must exist (the skill creates a minimal one for a greenfield repo) even when the code
itself is Python or SQL.

Fully supported languages today: **Python** (plus a **Python-stream** Flink-SQL flavor) and
**Node/TypeScript strict** (NestJS / Next.js). Any other language (C#, Helm, Go, Rust, …) gets the
**common base only** — the user adds their own language-specific config from there. A **Unity**
module is drafted but **not supported yet** — see [Unity (draft — in progress)](#unity-draft--in-progress).

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

## Prerequisites & platform support

The skill's own steps are agent-driven — there is no installer script, so the assistant applies
every merge from this body. The host needs little beyond a shell at the project root. The
dependencies below are for the hooks the skill wires, the bundled bootstrap, and the verifier.

- **Node — hard, in every category.** husky, commitlint, lint-staged, and release-it are npm
  packages declared in `package.json`, so a Python or SQL repo needs Node too. The skill creates a
  minimal `package.json` for a greenfield repo; it does not install Node.
- **Package manager — `packageManager`, then the lockfile.** A `packageManager` field in
  `package.json` (`"yarn@4.5.0"`) names it outright and wins, so a repo that gitignores its lockfile
  is not mistaken for npm. Otherwise `pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn, `bun.lockb` → bun,
  anything else → npm. `initialize.sh` provisions pnpm and yarn through
  `corepack`, and stops with an "install Node.js and retry" message when corepack is absent. npm
  ships with Node; bun must already be installed.
- **Runtime:** `bash` and `git`. `scripts/husky.sh install` sets `core.hooksPath` and refuses to
  run outside a git working tree.
- **Python repos only:** one of `uvx`, `uv`, `pipx`, or a `.venv` holding the tools, tried in that
  order by `scripts/py-tool.sh`. With none of the first three, `initialize.sh` builds the `.venv`
  with `python3 -m venv`, which needs `python3` 3.10+.
- **Network:** `curl` fetches the `.gitignore` baseline from toptal.com.
- **Verifier:** `scripts/verify-project-tooling.sh` needs `python3` to validate JSON and to render
  `--json` output.
- **Platform:** macOS and Linux are first-class. **Windows is supported via WSL only** — every
  shipped script is bash with POSIX paths (`.venv/bin/<tool>`) and there is no PowerShell/cmd path.
  The [`.gitattributes` baseline](#gitattributes) forces LF on `*.sh`, so the shipped hooks survive
  a Windows checkout instead of failing on a `bash\r` shebang.

## Step 1 — Detect the language, recommend the category, confirm

Read the repo first. **Detect** the package manager and language from filesystem signals;
**recommend** the category and let the user pick.

| Dimension       | Detect from                                                                                                                                     | Support          |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| Package manager | `packageManager` field first; then `pnpm-lock.yaml`→pnpm, `yarn.lock`→yarn, `package-lock.json`→npm, `bun.lockb`→bun; neither → default **npm** | —                |
| Language        | `tsconfig.json`/`*.ts`→**Node/TypeScript**; `pyproject.toml`/`*.py`→**Python**; `*.sql` alongside Python→**Python-stream**                      | fully supported  |
| Language        | `ProjectSettings/ProjectVersion.txt` + `Assets/`→**Unity** (checked **before** C#)                                                              | draft (not yet)  |
| Language        | `*.csproj`/`*.sln`→C#; `Chart.yaml`→Helm; `go.mod`→Go; `Cargo.toml`→Rust; anything else                                                         | common base only |
| Framework       | `next` dep→Next.js, `@nestjs/*` dep→NestJS, `react` dep→React                                                                                   | Node/TS touches  |

- **Category → always confirm.** Present the detected category as a recommendation and let the user
  choose. In Claude Code, use `AskUserQuestion` with options **frontend / backend / library / other**,
  the detected one first and marked "(Recommended)". Inference hint: Next/React→frontend,
  NestJS→backend, `"private": false` or a `bin`/`exports` field→library, else other (ETL/data).
- **Language → report, don't prompt,** when it is unambiguous (a lockfile, `pyproject.toml`, or a
  project file is factual). Prompt only when the repo is empty or genuinely mixed.
- **Python-stream** is plain Python plus the SQL add-on — trigger it when `*.sql` files are present.
- **Unity → check before C#, and never from the C# files.** Unity writes its `*.csproj`, `*.sln`,
  and `*.slnx` itself and gitignores them, so a fresh clone may hold none and an opened one holds
  files that are not the project's source of truth. Match on `ProjectSettings/ProjectVersion.txt`
  plus an `Assets/` directory; `Packages/manifest.json` corroborates it but is not required, since
  projects created before the package manager lack it. Unity wins over the C# row whenever both
  match. The module is a draft, so report it as **Unity (draft)** and follow the banner under
  [Unity (draft — in progress)](#unity-draft--in-progress).
- **Legacy commit and release tooling → detect, then always prompt.** Look for commitizen,
  standard-version, and their helpers (signals under
  [Migrating off commitizen and standard-version](#migrating-off-commitizen-and-standard-version)).
  When any is present, ask whether to migrate to release-it **whatever the category** — the table
  below does not apply to that question.

Category is **lightweight**: it only sets the release-it default and framework expectation. The
**language** drives which lint/format fragments get applied.

| Category           | release-it default                  |
| ------------------ | ----------------------------------- |
| Frontend / Backend | optional (ask)                      |
| Library            | **on**                              |
| Other (ETL/data)   | off                                 |
| Legacy tooling     | **always ask**, overrides the above |

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

| Sub-command  | Role                                                                                                                   |
| ------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `install`    | Points `core.hooksPath` at `.husky/`, then writes `.husky/commit-msg` + `.husky/pre-commit` and marks them executable. |
| `commit-msg` | Hook body — `commitlint --edit "$1"`.                                                                                  |
| `pre-commit` | Hook body — the staged-file checks (`lint-staged`).                                                                    |

Each generated hook is one command that hands git's own arguments to the dispatcher:

```sh
#!/bin/sh

scripts/husky.sh pre-commit "$@"
```

**Commit `.husky/`.** The hook files are repo state, not user state — identical for everyone —
and tracking them is what makes a git worktree work. `core.hooksPath` lives in `.git/config`, which
every worktree of a clone shares, so an untracked hooks directory leaves a worktree pointing at
something it does not have, and git then runs **no** hook at all, silently. Only `.husky/_`, husky's
generated helper directory, stays ignored. The logic that runs on every commit stays in one
committed, reviewable, prettier-formatted script instead of JSON-escaped shell fragments. Binaries
are resolved through the detected package manager's exec form (`pnpm exec` / `yarn exec` / `bunx` /
`npx --no --`), because `npx` cannot see local binaries under Yarn PnP or a strict pnpm store.
Yarn 1 gets `yarn exec --`: without the separator it parses the binary's flags as its own, so
`commitlint --edit <file>` runs with no arguments and rejects every commit.

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

Committed hooks are the only mode as of payload 2; the older layout regenerated them into a
gitignored `.husky/` and is what broke worktrees. [`assets/commit-msg`](assets/commit-msg) is the
standalone hook body for a repo that wants neither the dispatcher nor install-time generation.

### Base .gitignore and .gitattributes

Both are repo-hygiene files this skill owns end to end: what git must not track, and how git must
store what it does.

#### .gitignore

The file is a **generated body plus a constant tail**. The body comes from
[toptal](https://www.toptal.com/developers/gitignore); the tail is the same on every project.

**Body — regenerate from the API.** Always request this base:

```text
linux,macos,dotenv,windows,sonarqube,visualstudiocode
```

then add the templates for each stack the repo actually uses:

| Detected  | Append              |
| --------- | ------------------- |
| Node / TS | `node,yarn`         |
| Python    | `python,virtualenv` |

Concatenate in that order (base, then Node, then Python) and fetch:

```bash
curl -sS "https://www.toptal.com/developers/gitignore/api/linux,macos,dotenv,windows,sonarqube,visualstudiocode,node,yarn,python,virtualenv"
```

Only add a stack's templates when that stack is present — a Python-only repo should not carry
`node_modules/` and the whole yarn Zero-installs block.

> **Unity repo (draft).** Do not regenerate the body: the base above carries no `unity` template,
> and a wholesale regeneration would drop `Library/`, `Temp/`, and the rest of the Unity rules. See
> [`.gitignore` under the Unity module](#unity-draft--in-progress).

**Two patches to re-apply after every regeneration.** Both correct upstream rules that over-match
in a real repo; a wholesale regeneration silently drops them, so re-apply them before committing:

| Upstream     | Replace with   | Why                                                                                                                                                            |
| ------------ | -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MANIFEST`   | `/MANIFEST`    | setuptools writes `MANIFEST` at the project root. Unanchored — and with `core.ignorecase=true` on macOS — it also swallows any directory named `manifest/`.    |
| `[Ss]cripts` | `# [Ss]cripts` | The virtualenv template means a venv's `Scripts/` dir, but unanchored it swallows a repo's own `scripts/` — including the `scripts/husky.sh` this skill ships. |

The macOS `Icon` rule ships with trailing `\r`s (the filename genuinely ends in `\r`). Strip them
when regenerating — `prettier-plugin-sh` parses `.gitignore` and rewrites `Icon\r\r\n` to `Icon\n`,
so leaving them in makes `prettier --check` fail. Do not expect git to do it for you: the
`* text=auto eol=lf` in [`assets/gitattributes`](assets/gitattributes) leaves these bytes alone,
because a lone `\r` makes git treat the line as unconvertible and store it verbatim. Strip the
`\r`s and nothing else — the blank line that follows is upstream's own, and prettier does not
collapse it. After that step the file is byte-identical to what the repo's own toolchain produces.

**Tail — identical on every project**, appended after the generated body:

```gitignore
# AI
.code-review-graph/
graphify-out/
.claude/settings.local.json
.claude/handoff/.locks/
.agents/handoff/.locks/

# user-specific
.husky/_
.tmp
```

The AI block must sit **above** any `!`-negation a repo adds for its own fixtures or test data,
since a negation only takes effect after the rule it re-includes from.

Greenfield (no `.gitignore`): copy the asset wholesale. Existing `.gitignore`: append any missing
entries — at minimum the tail — line-merged; never duplicate a line, never drop existing entries,
with two exceptions:

- **A rule that ignores the hooks directory is replaced in place by `.husky/_`.** That covers
  `.husky`, `.husky/`, `/.husky`, `/.husky/`, `.husky/*`, and `.husky/**` — any of them stops the
  hook files from being committed, which is the worktree defect described under
  [package.json + the hook-install command](#packagejson--the-hook-install-command). Older husky
  setups put the bare `.husky` line under a "user-specific" heading, so it reads like intent; it is
  not. Replace it on the same line rather than appending `.husky/_` beside it, or the broad rule
  still wins. Check the result with `git check-ignore --no-index -v .husky/commit-msg` — it must
  print nothing — and report the change to the user, since a hook file that was never tracked now
  shows up as untracked and needs committing.
- **An ignore line for a file the migration removes goes with it** — for example
  `scripts/prepare-commit-msg.sh` once the commitizen hook is gone.

The tail already carries the sibling skills' paths, so `setup-graph-hooks` (graph output
directories) and `setup-handoff` (its board's `.locks/`) are a no-op here when they run after this
skill. They still append their own paths rather than routing through this asset, because a
non-default install location is theirs to know, not this asset's.

#### .gitattributes

[`assets/gitattributes`](assets/gitattributes) is the line-ending and diff baseline. It matters
most for the **shell payloads this repo's skills ship** — `scripts/husky.sh`, `initialize.sh`,
`scripts/py-tool.sh`, and the generated `.husky/` hooks. A CRLF checkout turns `#!/usr/bin/env bash`
into `bash\r`, and every one of them dies inside a git hook with a "no such file or directory" that
names a file that plainly exists. `setup-graph-hooks` and `setup-handoff` both assume this file is
in place for exactly that reason.

```gitattributes
# LF in the index, LF on checkout, every platform
* text=auto eol=lf
# Explicit, so relaxing the default above cannot break a hook
*.sh text eol=lf
# cmd.exe mis-parses a batch file stored with LF
*.bat text eol=crlf
# Never converted, never diffed as text
*.png binary
# Collapsed in GitHub PR diffs and skipped by `git diff`
package-lock.json linguist-generated=true -diff
```

A `#` only starts a comment at the **start of a line** here — git reads a trailing `# ...` as more
attribute names, so keep comments on their own lines.

> **Unity repo (draft).** The baseline above lacks Unity's LFS and `unityyamlmerge` macros. Do not
> copy it over a Unity repo; see [`.gitattributes` under the Unity module](#unity-draft--in-progress).

Greenfield (no `.gitattributes`): copy the asset wholesale. Existing `.gitattributes`: append only
the missing patterns, and **never rewrite a pattern the repo already declares** — an existing
`* text=auto` without `eol=lf`, or a per-extension `eol=crlf`, is a deliberate choice on a team that
has Windows developers editing those files.

One consequence to state to the user rather than absorb silently: on a repo that already holds CRLF
content, adding `eol=lf` rewrites those files at the next checkout. Size it first with
`git ls-files --eol | grep -v 'i/lf'` (index-side CRLF entries; binaries read as `i/-text` and are
left alone). If that comes back empty the new attributes change nothing today. If it does not, do
not fold the rewrite into the tooling commit — recommend `git add --renormalize .` as a separate,
reviewable commit and let the user decide when to run it.

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

- **Package-manager aware** — detects npm/pnpm/yarn/bun from `packageManager`, else the lockfile, and runs `<pm> install`
  (provisioning yarn/pnpm via corepack when needed).
- **Hook repair = re-run the hook-install command** — resolves the command name
  (`install:dev` → `prepare` → whichever script runs the installer), restores the executable bit
  on `scripts/husky.sh`, and
  regenerates the tracked `.husky/commit-msg` + `.husky/pre-commit`. A dispatcher that is present
  but not executable counts as broken, since the hooks are one-line wrappers around it.
- **Python** — makes the toolchain runnable through `scripts/py-tool.sh`. With uv or pipx present it
  pre-fetches the pinned tools so the first commit does not pay a download inside a git hook; with
  neither, it creates the `.venv` fallback and installs the versions `py-tool.sh` pins. The trigger
  is `scripts/py-tool.sh` existing, **not** the presence of `*.py` files: a base-only repo can hold
  Python (test graders, a one-off script) without ever wiring the Python module, and bootstrapping
  it there would fail on the missing resolver and take the whole folder-open task down with it.
- **uv project environment** — a repo with `pyproject.toml` **and** `uv.lock` also gets its own
  dependencies: `full` runs `uv sync`, and `folder-open` runs it when `.venv` is missing. This is
  separate from the lint tools above and keyed on `uv.lock`, because a `pyproject.toml` alone may be
  poetry, hatch or pip. Without uv on `PATH` it says so and skips; it never installs uv.

The `.vscode/tasks.json` task **Bootstrap Workspace** runs `bash ./initialize.sh folder-open --force`
on `folderOpen`, so opening the workspace repairs only what is missing. `full` mode
(`./initialize.sh full`) runs the complete bootstrap on demand.

### Release automation (release-it)

Wire by default for the **library** category; for frontend/backend, ask first; skip for other/ETL —
unless legacy release tooling is present, in which case always ask (next section). When wiring:

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

### Migrating off commitizen and standard-version

Many repos predate this skill and carry an older stack: commitizen for an interactive commit prompt,
standard-version to bump, tag, and write the changelog, and a handful of conventional-changelog
helpers. standard-version is
[deprecated upstream](https://github.com/conventional-changelog/standard-version#readme), and
release-it covers its job. Detect the stack, then **always prompt** to migrate — never migrate
silently, and never skip the question because of the category.

**Detect** — any one of these is enough:

| Signal                 | Where                                                                                                                                                                                                                                                      |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| commitizen             | `commitizen` or a `cz-*` adapter (`cz-conventional-changelog`, `cz-git`, `cz-customizable`, `@commitlint/cz-commitlint`) in `devDependencies`                                                                                                              |
| commitizen config      | `config.commitizen` in `package.json`, or a `.czrc` / `.cz.json` file                                                                                                                                                                                      |
| commitizen hook        | `.husky/prepare-commit-msg` or `scripts/prepare-commit-msg.sh` calling `cz`, or a script whose value is `cz` / `git-cz`                                                                                                                                    |
| standard-version       | `standard-version` (or its fork `commit-and-tag-version`) in `devDependencies`, a `.versionrc*` file, or a script calling it                                                                                                                               |
| conventional-changelog | `conventional-changelog-cli` or a preset package `conventional-changelog-<preset>` (`-atom`, `-angular`, …) — **not** plain `conventional-changelog` (a release-it dependency) and **not** `-conventionalcommits` (the preset the release-it config names) |

**Prompt.** In Claude Code use `AskUserQuestion`, listing what was found and what would be removed:

- **Migrate to release-it (Recommended)** — wire release-it as in the previous section, then remove
  the legacy stack.
- **Keep the legacy tooling** — leave it untouched; the rest of the skill still runs.

State the one behaviour change plainly in the question: commitizen's interactive prompt goes away
and release-it has no equivalent. Commit messages are still enforced by commitlint on
`commit-msg`, so a malformed message is rejected rather than guided.

**Migrate.** Wire release-it first, then remove:

1. `config.commitizen` from `package.json`, and `.czrc` / `.cz.json`.
2. Scripts that call `cz`, `git-cz`, `standard-version`, or `conventional-changelog` — typically
   `commit` and the old `release`, which the release-it scripts replace.
3. The commitizen hook — `.husky/prepare-commit-msg` and `scripts/prepare-commit-msg.sh` — plus any
   `.gitignore` line naming them.
4. `.versionrc*`, after carrying its settings over. A `tagPrefix` other than `v` becomes
   `git.tagName` in `.release-it.json`; release-it already reuses a `v` prefix it finds on the latest
   tag, so the default needs nothing. Custom `types` map to the preset `types` in the release-it
   config. `bumpFiles` (bumping a version outside `package.json`) has no built-in release-it
   equivalent — name it to the user and leave it for them rather than dropping it.
5. The orphaned dev dependencies (below).

Keep `CHANGELOG.md` and the existing tags. The release-it asset already writes to `CHANGELOG.md`,
so new releases are prepended to the history standard-version wrote.

**Orphaned dev dependencies.** Remove a package only when both hold:

- It is in the legacy set: `commitizen`, any `cz-*` adapter, `@commitlint/cz-commitlint`,
  `standard-version`, `commit-and-tag-version`, `conventional-changelog-cli`, and
  `conventional-changelog-<preset>` other than `-conventionalcommits`.
- Nothing references it once steps 1–4 are done. Search the tracked files for the package name,
  excluding the lockfile, `node_modules/`, and `CHANGELOG.md`:

  ```bash
  git grep -l -F PACKAGE -- . ':!*lock*' ':!CHANGELOG.md' ':!package.json'
  ```

  and check `package.json` itself for any key other than its `devDependencies` entry.

Compute the set **after** release-it is wired, so `conventional-changelog` — which release-it needs —
is never mistaken for a leftover. Never remove a package outside the legacy set, however unused it
looks; that is a separate cleanup the user did not ask for. The `husky` package and a `prepare`
hook-install script are handled by
[Migrating a repo wired by an earlier version](#packagejson--the-hook-install-command), not here.
List every removal in the prompt. Do not reinstall yourself — as under
[Install and activate](#install-and-activate), tell the user to run the hook-install command, which
reinstalls with the detected manager so the lockfile drops the removed packages.

**Python commitizen** (`[tool.commitizen]` in `pyproject.toml`, or `.cz.toml`) is a different tool:
`cz bump` owns the version in `pyproject.toml`, which release-it cannot bump on its own — it needs
[`@release-it/bumper`](https://github.com/release-it/bumper) pointed at that file. Still ask, but
state that extra plugin in the question and do not mark the migration as recommended: where the
version lives is the user's decision.

### Base dev dependencies

Merge into `package.json` (round-trip; preserve all other keys), pinned to the versions this repo
runs. Base (always): `@commitlint/cli ^21.1.0`, `@commitlint/config-conventional ^21.1.0`,
`@commitlint/types ^21.1.0`, `lint-staged ^17.0.8`, `prettier ^3.8.4`,
`prettier-plugin-sh ^0.18.1`. Release-only (when release-it is wired): `release-it ^20.2.0`,
`@release-it/conventional-changelog ^11.0.1`, `conventional-changelog ^7.2.1`. Language toolchains
add their own (see each module).

### Install and activate

Tell the user to run the hook-install command once with the detected manager (do **not** run it
automatically): `pnpm run install:dev` / `npm run install:dev` / `yarn install:dev` /
`bun run install:dev`. It installs dependencies and then calls `scripts/husky.sh install`, which points
`core.hooksPath` at `.husky/` and writes `.husky/commit-msg` + `.husky/pre-commit` — commit those.
After that, a bad message is rejected and staged files are linted on commit.

Only a **fresh clone** needs this. Worktrees of that clone inherit `core.hooksPath` and find the
tracked hooks with no further action.

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

### Unity (draft — in progress)

> **Status: draft — in progress. Not a supported module and not yet applied by the skill.** The
> assets named below exist under `assets/` but nothing wires them in, and the items under
> [Open questions / TODO](#open-questions--todo-unity) are not done. The verifier already grades a
> Unity repo (section 5b). When Step 1 detects Unity: say so, apply the **common base** only, and offer the
> fragments below only if the user opts in. Two base steps are **unsafe on a Unity repo** and must
> be guarded even while this is a draft — never regenerate the `.gitignore` body, and never replace
> an existing `.gitattributes` (rules below).

Targets a Unity 6 project (URP or otherwise). Unity imports only `Assets/` and `Packages/`, so the
Node-rooted base sits beside it without interference; the work is stopping the base from fighting
Unity's own conventions: 4-space C#, Editor-owned YAML, `*.meta` files that **must** be committed,
and generated folders that must not be.

- **Detect** → `ProjectSettings/ProjectVersion.txt` + `Assets/` (+ `Packages/manifest.json`), ahead
  of the C# row. See [Step 1](#step-1--detect-the-language-recommend-the-category-confirm). Unity is
  a language, not a category: the category is usually **other**; confirm it as usual.
- **Stop on the two shapes this module does not cover** — say which one matched, apply the common
  base with the two Unity guards from the banner, and apply no Unity or other-language fragment:
  - **Mixed repo** — the Unity markers plus a second language's project file at the root
    (`pyproject.toml`, `tsconfig.json`, or a `package.json` the skill did not create). Their
    `.gitignore` templates over-match each other (listed under `.gitignore` below), so there is no
    safe union yet.
  - **UPM package repo** — a root `package.json` next to an `*.asmdef` (usually under `Runtime/` or
    `Editor/`) and no `ProjectSettings/`: the repo **is** a Unity package, and that `package.json`
    is its [package manifest](https://docs.unity.com/en-us/engine/current/manual/packages-list/cus-pkg-lp/cus-pkg-development/cus-pkg-manifest/upm-manifest-pkg), not npm's.
    Never merge dev dependencies or scripts into it.
- **`.gitignore`** → the body is the base **plus the `unity` template** — do not append `node,yarn`
  or `python,virtualenv` for the root `package.json` the skill creates:

  ```bash
  curl -sS "https://www.toptal.com/developers/gitignore/api/linux,macos,dotenv,windows,sonarqube,visualstudiocode,unity"
  ```

  Then append the constant tail and a single `node_modules/` line (the root `package.json` makes
  one appear; the `node` template that normally carries it is deliberately not added).
  Toptal's `unity` template trails the upstream
  [`Unity.gitignore`](https://github.com/github/gitignore/blob/main/Unity.gitignore) — it lacks
  `*.slnx`, `*.log`, `mono_crash.*`, and `*.DotSettings.user`, among others — so add at least those
  four lines after it.

  **If the existing `.gitignore` already carries Unity rules, do not regenerate.** Treat it as
  Unity-aware when it ignores both `Library` and `UserSettings` (any anchoring or case form, such as
  `/[Ll]ibrary/`), or opens with the upstream `Unity.gitignore` header. Then append only the missing
  lines of the constant tail plus `node_modules/`, line-merged as in the base rules above — never
  drop or reorder what is there. The base rule that replaces a `.husky` ignore with `.husky/_` still
  applies.

  Check the two base patches against Unity before re-applying them:

  - `[Ss]cripts` → `# [Ss]cripts` only ever applies when the `virtualenv` template is present, and
    a Unity repo does not add it, so there is nothing to patch. The check that matters is the
    result: `Assets/Scripts/` must not be ignored. The path check under **Verification** below
    prints nothing when it is not.
  - `MANIFEST` → `/MANIFEST` comes from the `python` template and is harmless here. Leave it
    anchored if it is present; `Packages/manifest.json` is not matched either way.

  **Templates a Unity repo must not receive**, each for a reason found in the generated body:
  `virtualenv` (unanchored `[Bb]in`, `[Ii]nclude`, `[Ll]ib`, `[Ll]ocal` swallow plugin folders),
  `python` (unanchored `lib/`, `build/`), and toptal's `csharp` / `visualstudio` (an unanchored
  `*.meta` — which silently drops Unity's meta files — plus unanchored `[Bb]in/`, `[Oo]bj/`,
  `[Ll]og/`). A mixed Unity-plus-Python repo is therefore an open question, not a union of the two.

- **`.gitattributes`** → [`assets/gitattributes-unity`](assets/gitattributes-unity) is the upstream
  [`Unity.gitattributes`](https://github.com/gitattributes/gitattributes/blob/master/Unity.gitattributes)
  verbatim (MIT, header kept), wrapped in two marked x442 blocks. The **x442 prefix** comes first:
  `* text=auto eol=lf` and `*.bat text eol=crlf`, as in the base asset. The **x442 layer** comes
  after: `eol=lf` pins for `*.sh`, `*.bash`, `*.zsh`, and the hook names, plus
  `linguist-generated -diff` on the lockfiles. Upstream's body sits between the two markers.
  - **Greenfield:** copy the asset wholesale in place of the base `assets/gitattributes`.
  - **Existing Unity `.gitattributes`:** never replace it. Insert the prefix lines at the **top**
    when the file declares no `*` text rule, and append the layer lines it lacks. Skip any pattern
    it already declares.
  - **Existing non-Unity `.gitattributes` on a Unity repo:** keep it, then add the prefix at the top
    and append the upstream body for the patterns it lacks, and report the merge. The `[attr]`
    macros only work in a top-level file, so they must land in the root `.gitattributes`.

  **Every text file is LF, on every platform** — by decision, so a Windows clone never checks
  files out as CRLF. The prefix must stay **above** upstream's rules, because a later line overrides
  an earlier one for the same attribute. Placed after them, `* text=auto` turns upstream's `-text`
  on the LFS binaries and its explicit `text` on `*.cs` back into `text=auto` (verified with
  `git check-attr`). An existing `*` text rule without `eol=lf` is a deliberate team choice and
  the base rule applies: never rewrite it, report it instead. Adding the prefix to a repo that
  already holds CRLF content rewrites those files at the next checkout, so size it and offer
  `git add --renormalize .` as its own commit, exactly as under the base
  [`.gitattributes`](#gitattributes) rules.

  **Git LFS is opt-in.** Upstream routes images, audio, models, video, and archives through LFS,
  and committing files through it cannot be undone without a history rewrite. Ask before applying
  the file, and say so in the question. Every LFS line goes through the one `[attr]lfs` macro, so
  the answer is a one-line edit and the upstream body otherwise stays verbatim:

  - **Declined (the default):** replace the macro line with `[attr]lfs -diff -merge -text`. Those
    files are then plain binaries — `git check-attr filter -- Assets/x.png` reports `unspecified`.
  - **Accepted:** keep the macro, confirm `git-lfs` is installed and the host has LFS storage, then
    run `git lfs install --local`. With `core.hooksPath` at `.husky/`, it writes its four hooks into
    `.husky/` (git-lfs 3.8.1, verified), where they are committed like the rest. If `.husky/post-commit`
    already exists — `setup-graph-hooks` writes one — it writes `pre-push` and `post-checkout`, then
    exits 2 **without** `post-commit` or `post-merge`. Do not pass `--force`; it overwrites the graph
    refresh. Append `git lfs post-commit "$@"` to the existing `post-commit`, write `post-merge` from
    `git lfs update --manual`, and check all four exist. A push without `pre-push` sends pointers
    with no objects.

- **lint-staged** → merge [`assets/lintstaged/unity.json`](assets/lintstaged/unity.json):
  `"*.{uss,tss}": "prettier --write"` on top of the base glob. Prettier globs only — there is no C#
  step, by decision (see [Decided](#decided-unity)). `*.uss` and `*.tss` are CSS dialects that
  prettier cannot infer, so this fragment **requires** the `.prettierrc` override below; without it prettier fails on every
  staged `.uss` with "No parser could be inferred".
- **prettier** → write the base `.prettierrc`, then add one `overrides` entry so the UI Toolkit
  stylesheets parse as CSS:

  ```json
  {
    "files": ["*.uss", "*.tss"],
    "options": { "parser": "css" }
  }
  ```

  Concatenate [`assets/prettierignore-unity`](assets/prettierignore-unity) onto the base
  `.prettierignore`. It adds the generated folders, `ProjectSettings/`, Unity's serialized YAML
  extensions, the Editor-written JSON (`*.inputactions`, `*.shadergraph`, `*.shadersubgraph`,
  `Packages/packages-lock.json`), `Assets/Plugins/`, and the root `.gitattributes`. Serialized YAML is ignored rather than
  formatted because the Editor emits custom `%TAG` lines and trailing spaces on empty values, and
  rewrites the file in its own style on the next save — a formatter and the Editor would take turns
  undoing each other. `*.meta` is on the same list. `.gitattributes` is there because the base
  `.prettierrc` loads `prettier-plugin-sh`, which claims the file and collapses upstream's column
  alignment, so `prettier --check .` fails on the verbatim file.

- **editorconfig** → append [`assets/editorconfig/unity`](assets/editorconfig/unity) to the base:
  C# at 4 spaces, UTF-8 BOM, and Allman braces with Unity-friendly .NET rules; shaders at 4;
  serialized YAML left alone (no trailing-space trim, no final-newline); Editor-written JSON at 4;
  the generated MSBuild and solution files noted. The base's 2-space default, markdown, JSON/YAML,
  and shell rules stay.
- **vscode** → deep-merge [`assets/vscode/unity.json`](assets/vscode/unity.json) over
  [`assets/vscode/base.json`](assets/vscode/base.json) with **two base keys skipped**:
  `editor.defaultFormatter: esbenp.prettier-vscode` and `editor.tabSize: 2`. Both are global, so
  they would put prettier on `.cs` files and force 2-space indent on C#, fighting the C# extension
  and the `.editorconfig` above. The fragment sets formatters **per language** instead — `[csharp]`
  → `ms-dotnettools.csharp`; `json`, `jsonc`, `yaml`, `markdown`, and `css` → prettier — maps `*.uss`/`*.tss` to `css`, and hides `*.meta` and the generated folders in the
  explorer. `editor.formatOnSave` still comes from the base. If an existing `settings.json` already
  holds either skipped key, report it as a conflict and leave it; do not delete it silently.
  `dotnet.defaultSolution` names the solution file Unity generates, so it is project-specific and
  **not** in the fragment. When a `.sln` / `.slnx` exists, tell the user the key is available; do
  not write it.
- **extensions** → `visualstudiotoolsforunity.vstuc`, `ms-dotnettools.csdevkit`,
  `ms-dotnettools.csharp`, `editorconfig.editorconfig`, `esbenp.prettier-vscode`.
- **Root `package.json` and `node_modules/`** → safe. Unity compiles and imports only `Assets/` and
  `Packages/`, so a root `package.json`, `node_modules/`, `scripts/`, and `.husky/` are invisible to
  it and need no `.meta` files. Keep them out of `Assets/`: anything under it is imported, and
  gets a `.meta`. `node_modules/` must be gitignored (the `.gitignore` rule above). **`Packages/manifest.json`
  is Unity's package manifest, not npm** — never merge dev dependencies into it, never detect a
  package manager from it, and never let the base's "create a minimal `package.json`" step touch
  `Packages/`. The same goes for `Packages/packages-lock.json`.
- **Verification** → `verify-project-tooling.sh` section **5b** detects Unity and fails when
  `Library/` or `UserSettings/` is not ignored, when `*.meta` or `Assets/Scripts/` is ignored, when
  `Packages/manifest.json` carries npm keys, or when binaries route through LFS with no
  `git lfs pre-push` hook. It warns when `*.cs` is not LF, when a `*` text rule placed after the
  Unity rules strips `-text` from the binaries, on a missing `unityyamlmerge`, on a missing LFS
  `post-checkout` / `post-commit` / `post-merge`, on a mixed repo, and on a UPM package repo.
  Spot-check what it does not cover: `git check-ignore --no-index -v` prints a match for `Temp/x`
  and `node_modules/x` and nothing for `Packages/manifest.json` or `scripts/husky.sh`, and
  `prettier --check .` passes without touching a `.prefab`, `.meta`, `.asset`, or `ProjectSettings/`
  file.

#### Decided (Unity)

Settled 2026-11-05; do not reopen these without the user.

- **No C# formatter in the hooks.** The `.editorconfig` fragment and the C# extension format on
  save, and the hooks stay Node-only. `csharpier` was rejected because it adds a .NET SDK and
  overrides the Allman and brace rules the fragment encodes. `dotnet format` was rejected because
  it needs the `.sln`/`.slnx` that Unity generates on demand and gitignores, which is missing on a
  fresh clone and in CI.
- **Git LFS is opt-in**, applied as the one-line macro edit under `.gitattributes` above.
- **Every text file is LF** — `* text=auto eol=lf` in the x442 prefix, above upstream's rules, so
  a Windows clone never converts to CRLF. Reversed 2026-11-05 from "pin scripts and hooks only".
- **The draft lives on a feature branch** with the payload bumped in its first commit, and merges
  only at promotion, so no install is told it is behind for files the skill does not yet apply.
- **Unity is a language, not a category.** Category only sets the release-it default, and Unity has
  no release shape of its own.
- **v1 covers a plain Unity project only.** Mixed repos and UPM package repos are detected and
  stopped (under **Detect** above); each needs its own design before it is supported.
- **No shell formatter in the VS Code fragment.** `[shellscript]` → prettier needs
  `prettier-plugin-sh`, which a Unity repo with its own `.prettierrc` does not have, so the
  fragment leaves shell files alone.
- **Graph ignore rules for Unity belong to `setup-graph-hooks`**, not to this module. It should
  detect Unity itself, so the rules land whichever skill runs first, and in repos that never run
  this one.

#### Open questions / TODO (Unity)

What remains before promoting this module out of draft. None of it is a design question.

- **Run it on a real Unity 6 project**, not only the hand-assembled harness fixture: apply the
  module end to end, open the project in the Editor, and confirm nothing it writes is reimported or
  rewritten.
- **Promote:** drop the draft banner and the "offer the fragments only if the user opts in" rule,
  change the Step 1 table's Unity row from `draft (not yet)` to supported, strip the `DRAFT`
  headers from the asset fragments, and drop the `.gitignore` four-line supplement if the template
  source moves to upstream's `Unity.gitignore`.

Found by a first manual run of the chain on a Unity 6 repo (each was worked around by hand). The
`setup-graph-hooks` post-commit hook landing outside `core.hooksPath` was found here too; it is
fixed for every language (`setup-graph-hooks` now treats `scripts/husky.sh` as a husky layout, and
`husky.sh install` moves a stray hook into `.husky/`), so the `mkdir -p .husky` workaround is gone.

- **Graph ignore files know nothing about Unity.** `.code-review-graphignore` / `.graphifyignore`
  from `setup-graph-hooks` omit `Library/`, `Temp/`, `Obj/`, `Logs/`, `UserSettings/`, `Build(s)/`
  and the generated `*.csproj` / `*.sln` / `*.slnx`. `Library/PackageCache` holds thousands of
  package `.cs` files. The fix belongs in `setup-graph-hooks` (see **Decided**); until it lands,
  append those lines to both files by hand.
- **Prettier-ignore entries the root tooling adds.** An existing Unity `.prettierignore` still
  needs the base asset's `pnpm-lock.yaml` (else lint-staged reformats the lockfile) and
  `.agents/handoff/**/*.md` lines, and `.mcp.json` (rewritten by `code-review-graph install` /
  `portable-mcp.py`), which the base asset lacks too.
- **The copied `commitlint.config.mjs` fails a repo with its own `.prettierrc`** — the asset is
  formatted with this skill's single-quote config. Format it with the repo's prettier after copying.

### Everything else → common base only

For a recognized-but-unsupported language (C#, Helm, Go, Rust, …), apply the **common base** only,
then tell the user to add their own language-specific config from there. A Unity repo is **not**
plain C#: it is the draft module above, with the guards its banner names.

- Add a lint-staged `glob → command` pair to `.lintstagedrc.json` following the same shape as the
  supported modules (e.g. `"*.go": ["gofmt -w", "golangci-lint run"]`).
- Add editor-format blocks to `.editorconfig` and any language extensions to
  `.vscode/extensions.json`.

Do not invent a full toolchain the user did not ask for — scaffold the base, name the gap, and let
them fill it.

## Future (tracked)

Not yet supported as first-class modules; they currently get the common base only.

- **Unity** → drafted, not supported: see [Unity (draft — in progress)](#unity-draft--in-progress)
  for the assets, the merge rules, and the open questions that block promotion.
- **C#** (non-Unity) → likely `dotnet format` / csharpier via lint-staged (or Husky.Net if going
  native), plus `.editorconfig` Roslyn analyzer rules. The Unity draft's formatter question
  overlaps this one.
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
   **Bootstrap Workspace** task and `initialize.sh` is present and executable.
6. **Git hygiene:** `.gitignore` ignores `.husky/_` but **not** `.husky/` itself (the hook files
   are tracked; see above) — `git check-ignore --no-index .husky/commit-msg` prints nothing — ignores
   the base AI paths, and does **not** ignore `scripts/`. `.gitattributes` is present and forces LF on `*.sh`, so the shipped hook payloads
   survive a Windows checkout; `git check-attr text eol -- scripts/husky.sh` reports
   `text: set` / `eol: lf`, and `git ls-files --eol scripts/husky.sh` shows `i/lf`. To size a
   renormalize before committing one, list the index-side CRLF files with
   `git ls-files --eol | grep -v 'i/lf'` — **not** `git add --renormalize --dry-run`, which prints
   every tracked path it would re-add whether or not the content changes.
7. **Release (when wired):** `.release-it.json` present and `release` scripts in `package.json`;
   `npm run release:dry-run` produces a changelog preview. After a migration, no legacy package,
   `config.commitizen`, `.czrc`, or `.versionrc*` remains, and the dry run picks up the latest
   existing tag.
8. **Common-only repos:** an unsupported-language repo still passes the base checks (commitlint,
   `.editorconfig`, a `.lintstagedrc.json` with the base glob), and its `pre-commit` skips any step
   it does not define rather than failing the commit.
9. **Idempotency:** re-running the skill is a no-op for every piece already present, including on a
   repo migrated from the older `<cmd>:commit-msg` / `<cmd>:pre-commit` chain.
