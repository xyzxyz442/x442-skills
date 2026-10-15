# Onboarding — a project

A repo is onboarded when an AI assistant opening it reads the same rules as the humans working
in it, finds a code graph instead of grepping, commits in the house format, and (where work is
shared) checks a handoff board before editing. That state is a handful of committed files. Setting
it up is a chain of skills, run once per repo by one person. Everyone after that only activates it
(see [step 8 of developer onboarding](onboarding-new-developer.md#step-8--your-first-repo)).

The chain is the same for every repo. What changes is how much of the repo is already there. Find
your situation below.

| Situation                                            | Read                                                       |
| ---------------------------------------------------- | ---------------------------------------------------------- |
| the repo was created today, or has almost no tooling | [A new repo](#situation--a-new-repo)                       |
| the repo is years old and has its own conventions    | [A legacy repo](#situation--a-legacy-repo)                 |
| someone started onboarding it and stopped partway    | [A half-migrated repo](#situation--a-half-migrated-repo)   |
| the repo needs to read another repo's code           | [Sibling repos](#situation--the-repo-depends-on-a-sibling) |

---

## The chain

```text
initial-project ─► setup-project-tooling ─► setup-graph-hooks ─► setup-handoff ─► setup-secret-guard
   AGENTS.md         commitlint, husky,        graph hooks,          lease board      secret rules in
   tool wiring       lint-staged, VS Code,     AGENTS.md routing     (optional)       AGENTS.md; home
                     release-it                block, MCP                             guard if missing
```

Run **`/x442-initial-project`** from the repo root. It creates `AGENTS.md`, wires each assistant
you select to it, then offers the other four in order, each with a yes/no prompt that defaults to
yes. It skips a link whose marker is already present:

| Skill                   | Skipped when the repo already has                                                  |
| ----------------------- | ---------------------------------------------------------------------------------- |
| `setup-project-tooling` | `scripts/husky.sh`                                                                 |
| `setup-graph-hooks`     | a `<!-- graph-hooks:begin` block in `AGENTS.md` **and** `.graph-hooks/`            |
| `setup-handoff`         | a `<!-- handoff` block in `AGENTS.md` **and** `.agents/handoff/`                   |
| `setup-secret-guard`    | a `<!-- secret-guard:begin` block in `AGENTS.md` (the home-layer check still runs) |

Two links deserve a thought before you say yes:

- **`setup-handoff`** — say yes when more than one agent, session or person works the repo, or when
  work has to survive a session. [Handoff](handoff.md) covers that decision. It is safe to add later.
- **`setup-secret-guard`** — always say yes. The guard has two halves. The repo half is an
  `AGENTS.md` block that tells every assistant, including ones with no hook, how to treat
  credentials. The home half is the guard itself, installed once per developer machine. The chain
  writes the repo block and installs the home half too if your machine lacks it. Teammates install
  their own home half during [developer onboarding](onboarding-new-developer.md#step-6--the-secret-guard).

Every skill in the chain is idempotent. Re-running one detects what is present and skips it,
so running the chain again is always safe. Re-running is also how you upgrade a repo when a skill
ships a fix.

**Only the secret guard backs up what it replaces.** For everything
else, run the chain on a clean working tree on its own branch, so that `git diff` is your review and
`git restore` is your undo:

```bash
git switch -c feature/ai-onboarding
git status --short # must be empty before you start
```

---

## Situation — a new repo

The easy case. Nothing exists, so every skill writes its defaults.

1. Make sure the repo has a first commit and a manifest (`package.json`, `pyproject.toml`, …). The
   tooling skill detects the language from it.
2. Run `/x442-initial-project`. Select the assistants the team uses. Accept the chain.
3. **`setup-project-tooling`** asks you to confirm a category:

   | Category | release-it default |
   | -------- | ------------------ |
   | library  | on                 |
   | frontend | asks               |
   | backend  | asks               |
   | other    | off                |

   Node/TypeScript (strict, with NestJS and Next.js touches) and Python (ruff and black) get full
   configs. Python with Flink SQL files gets a sqlfluff add-on. Everything else (C#, Go, Helm, Rust)
   gets the common base: commitlint, husky, `.editorconfig`, `.gitignore`, `.gitattributes`, VS
   Code. You add the language's own lint-staged glob and extensions afterwards.

4. **`setup-graph-hooks`** asks which assistants to wire and which one is the primary refresh
   owner. Pick the one most of the team uses. Exactly one tool refreshes the graph at end of turn,
   and git's `post-commit` hook covers the rest. See [Graph hooks](graph-hooks.md).
5. Activate the hooks and build the graph:

   ```bash
   pnpm run install:dev
   code-review-graph build && graphify update .
   ```

6. Run the verifiers (the assistant can do this for you: "run every verifier for the skills you just
   ran"). Each must end with `0 failed`.
7. Commit in logical pieces, one per skill. A reviewer can then read the context changes apart from
   the tooling changes:

   ```text
   docs(docs): add AGENTS.md and wire claude and copilot to it
   chore(setup): add commitlint, lint-staged and release-it tooling
   chore(setup): wire graph hooks and the code-review-graph mcp server
   ```

Then fill in `AGENTS.md`. The skill writes the shared sections (coding guidelines, commit
conventions, graph routing). Only you can write the project overview, the build and test commands,
and the conventions specific to this codebase. An assistant with good project facts in `AGENTS.md`
makes far fewer wrong guesses than one with a perfect toolchain and no context. Keep it short and
factual. `/init` in Claude Code drafts a first version from the code that you then edit down.

---

## Situation — a legacy repo

The repo has years of history, its own `CLAUDE.md` or `.cursorrules`, commitizen or
standard-version, a prettier config with opinions, and a `.gitignore` that ignores things for
reasons nobody remembers. The skills are built to keep all of it. Know where they draw the lines:

| What the repo has                                   | What the chain does                                                                                                 |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| a `CLAUDE.md` / `GEMINI.md` with real content       | adds one `@AGENTS.md` import line and leaves the rest alone                                                         |
| an `AGENTS.md` already                              | adds only the missing sections (coding guidelines, commit conventions) and skips the ones present                   |
| coding guidelines pasted into `CLAUDE.md`           | **not handled.** The verifier then fails `guidelines.no_duplication`. Delete the copy from the tool file yourself   |
| commitizen, standard-version, `.versionrc`, `.czrc` | **always asks**: migrate to release-it (recommended), or keep the legacy tooling                                    |
| a prettier config                                   | kept; no `.prettierrc` is written                                                                                   |
| `.vscode/settings.json`                             | deep-merged, existing keys preserved. A file with comments is never rewritten; the installer prints the keys to add |
| `.gitignore`                                        | line-merged, never duplicated, never dropped. One exception below                                                   |
| `.gitattributes` with `text=auto` or `eol=crlf`     | kept. Only missing patterns are appended                                                                            |
| an install script named `setup` or `bootstrap`      | adopted, not duplicated                                                                                             |
| old Claude hooks in `settings.local.json`           | moved to the committed `.claude/settings.json`. Only the graph skill's own groups are moved                         |
| hand-copied graph scripts in `.claude/scripts/`     | reported as "safe to remove (use trash)". Never deleted                                                             |

Before you merge, look at these closely:

- **The migration off commitizen or standard-version.** It wires release-it first, then removes the
  old config, scripts, hooks and orphaned dependencies. `CHANGELOG.md` and existing tags are kept.
  `bumpFiles` has no release-it equivalent, so if the repo bumps a version in a second file, wire
  that yourself. Python commitizen needs `@release-it/bumper`, so the migration is not marked as
  recommended there. Decide case by case.
- **`.husky` in `.gitignore`.** Ignoring `.husky/` breaks every git worktree silently, so the skill
  rewrites that rule to `.husky/_`. The hook files then show up as untracked. That is intended:
  commit them.
- **Line endings.** If the repo is checked out with CRLF anywhere, the skill only _recommends_
  `eol=lf` for shell files. Size the change with `git ls-files --eol | grep -v 'i/lf'`, and if you
  take it, put `git add --renormalize .` in a commit of its own so blame stays readable.
- **VS Code key conflicts.** The merge preserves existing keys, but nothing defines what happens
  when the repo and the base set the same key differently (for example `editor.tabSize`). Read the
  `.vscode/settings.json` diff line by line.

Two traps that look like skill bugs:

- **Husky after graph hooks.** If `.husky/` appears after the graph hooks were wired, the graph's
  `post-commit` hook is still in `.git/hooks/`, which git no longer reads. Run the chain in order.
  If you are already past that point, re-run `setup-graph-hooks` or run `/x442-repair-graph-hooks`.
- **A huge first graph build.** A legacy monorepo can take several minutes and produce a large
  `graph.db`. Both graph directories are gitignored. If generated or vendored code dominates the
  graph, exclude it in `.code-review-graphignore` and `.graphifyignore` before you build.

---

## Situation — a half-migrated repo

Someone ran part of the chain. Maybe `AGENTS.md` exists but no hooks, maybe husky is there but
commitlint is not, maybe the graph block is in `AGENTS.md` but `.graph-hooks/` was never committed.

The answer is always the same: **re-run `/x442-initial-project`**. Each skill is detect-and-skip
per piece, so the chain fills the gaps and leaves the rest. The markers decide what gets offered:

| You find                                                             | What happens on re-run                                                                                          |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `.husky/` and commitlint, but no `scripts/husky.sh`                  | treated as unwired. `setup-project-tooling` is offered and moves the repo to `install:dev` + `scripts/husky.sh` |
| `package.json` scripts named `commit-msg`, `pre-commit` or `prepare` | migrated to the single `install:dev` script                                                                     |
| a graph block in `AGENTS.md` but no `.graph-hooks/`                  | treated as unwired. `setup-graph-hooks` is offered and replaces the block in place                              |
| `.graph-hooks/` but stale behaviour (double refresh, no cheatsheet)  | not offered, because the markers are present. Run `/x442-repair-graph-hooks`                                    |
| a handoff block but no `.agents/handoff/`                            | `setup-handoff` is offered                                                                                      |

Then run every verifier and read the warnings, not just the failures. A half-migrated repo is
exactly where a `[warn]` such as "commit ruleset not cited" or "Copilot wired with no
`.vscode/settings.json`" shows which piece someone skipped.

If the repo has a board that misbehaves, repair it with `/x442-repair-handoff`, not by re-running
setup. Setup does not touch board state, such as leases and the index. Repair does.

---

## Situation — the repo depends on a sibling

A frontend that calls a backend, a service that imports a shared library, packages in one monorepo.
An assistant in one repo needs to resolve a symbol defined in the other. Without help, it greps
across folders and reads whole files.

Once the repo is onboarded, run **`/x442-register-cross-repo-graph`**. You declare the siblings in
a committed `.graph-repos.json`, and a sync registers their graphs for **read-only** lookup and
records the in-scope list in `AGENTS.md`. Both repos must be checked out on the same machine. The
details are in
[Cross-repo lookups](../graph-tools-during-development.md#cross-repo-lookups).

For coordinating _work_ across those repos (an API change every consumer must adopt), use a shared
handoff board instead: [Handoff](handoff.md) and `/x442-register-cross-repo-handoff`.

---

## Checklist before you merge the onboarding branch

- [ ] Every verifier ends in `0 failed`.
- [ ] `AGENTS.md` has a real project overview, build, test and lint commands, not just the shared
      sections.
- [ ] No tool file (`CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`) duplicates
      `AGENTS.md`.
- [ ] `.husky/` is tracked. Only `.husky/_` is ignored.
- [ ] `.mcp.json` has no absolute path from your machine (`python3 .graph-hooks/portable-mcp.py`
      fixes it).
- [ ] A test commit with a bad message is rejected locally.
- [ ] The README tells a new clone to run `install:dev` once.
- [ ] Commits are split per skill, in Conventional Commits format.
