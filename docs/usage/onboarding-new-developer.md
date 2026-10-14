# Onboarding — a new developer

You have a GitHub account, VS Code is installed, and the toolchain for your project's language
(Node, Python, .NET, Go, …) already works. This page takes you from there to a machine where an AI
assistant reads the same rules as everyone else, queries the code graph instead of grepping, cannot
print a credential, and commits in the house format.

Work through it once, in order. Each step ends with a check. If you already use an assistant and
only some of this is missing, read [Onboarding — an existing developer](onboarding-existing-developer.md)
instead. It audits what you have and points back into the steps here.

Your operating system changes only the install commands. [Platforms](platforms.md) has them for
macOS, Linux and Windows (WSL). Read it first if you are on Windows.

---

## What you end up with

| Layer                        | Lives in                                         | Installed by                       | Shared with the team? |
| ---------------------------- | ------------------------------------------------ | ---------------------------------- | --------------------- |
| Base tools                   | your `PATH`                                      | you, step 1                        | no                    |
| AI assistant                 | CLI + VS Code extension                          | you, step 3                        | no                    |
| Skills                       | `~/.agents/skills/`, `~/.claude/skills/`         | you, step 4                        | same source, per user |
| Graph tools                  | `pipx` virtualenvs                               | you, step 5                        | no                    |
| Secret guard (home layer)    | `~/.claude/bin`, `~/.claude/settings.json`       | `setup-secret-guard`, step 6       | no                    |
| Global context + permissions | `~/.claude/CLAUDE.md`, `~/.claude/settings.json` | you, step 7                        | no — but standardised |
| Repo context, hooks, tooling | the repo (`AGENTS.md`, `.claude/`, `.husky/`, …) | already committed; you activate it | yes, through git      |

Everything below the last row is per machine. The last row is per repo and was set up once by
whoever onboarded the project — see [Onboarding — a project](onboarding-project.md). Your job for
that row is to activate it, in step 8.

---

## Step 1 — base tools

The skills are bash and Python 3 with the standard library only. Node is needed in every repo that
uses the commit tooling, including Python repos, because commitlint and lint-staged are Node
packages.

| Tool      | Why                                                                     |
| --------- | ----------------------------------------------------------------------- |
| `git`     | everything                                                              |
| `bash`    | every installer and hook                                                |
| `python3` | installers, verifiers, JSON merges (3.7 or newer; no packages needed)   |
| `node`    | commitlint, lint-staged, prettier, release-it; `corepack` for pnpm/yarn |
| `gh`      | GitHub auth for git, handoff boards with a remote, issue mirroring      |
| `pipx`    | installs the two graph tools in isolated environments                   |
| `trash`   | the house rule is "never `rm`" — deletions go to the system trash       |

Install whatever is missing with the commands in [Platforms](platforms.md), then check:

```bash
for t in git bash python3 node gh pipx trash; do
  command -v "$t" > /dev/null && echo "ok    $t" || echo "MISS  $t"
done
```

Every line should read `ok`. On Linux, `trash` comes from the `trash-cli` package.

---

## Step 2 — GitHub authentication

```bash
gh auth login     # choose HTTPS, authenticate in the browser
gh auth setup-git # let git use gh as its credential helper
gh auth status    # the active account is the one git will push as
```

If you hold more than one GitHub account (personal and work), `gh auth status` shows which one is
active. Nine times out of ten, a `403` on push means the wrong account is active, not a missing
permission. Switch with `gh auth switch` before you start debugging anything else.

---

## Step 3 — the AI assistant

Pick a primary assistant: the one whose hooks enforce the rules (the graph steer, the handoff
gate, the secret guard). Every skill here supports Claude Code as primary. GitHub Copilot in VS Code
reads the same `AGENTS.md` and runs the same Claude-format hooks, so both can run side by side.

**Claude Code** — the CLI plus the VS Code extension. Use one of these, per the
[official setup guide](https://docs.claude.com/en/docs/claude-code/setup):

```bash
brew install --cask claude-code                # macOS
curl -fsSL https://claude.ai/install.sh | bash # macOS, Linux, WSL
```

Then install the **Claude Code** extension from the VS Code marketplace, and run `claude` once in a
terminal to sign in.

**GitHub Copilot** — install the Copilot extensions in VS Code and sign in with your GitHub
account ([Copilot setup](https://code.visualstudio.com/docs/copilot/setup)). It needs nothing else
from you: a wired repo commits `chat.agentFilesLocations` and `chat.useClaudeHooks` in
`.vscode/settings.json`.

Check: `claude --version` prints a version. In VS Code, the Claude Code panel opens and shows your
account.

---

## Step 4 — the skills

Install them once per machine. Use one of these paths:

| You are                             | Run                                                                                        |
| ----------------------------------- | ------------------------------------------------------------------------------------------ |
| a Claude Code user                  | `claude plugin marketplace add xyzxyz442/x442-skills`, then `/plugin install` in a session |
| using several assistants            | `npx skills add git@github.com:xyzxyz442/x442-skills.git`                                  |
| going to edit the skills themselves | clone the repo, then `./scripts/link-claude-skills.sh`                                     |

The from-source path symlinks each skill into `~/.agents/skills/x442-NAME` and from there into
`~/.claude/skills/`. A `git pull` in the clone updates every assistant at once. The `personal/`
skills (the delegate suite) are skipped unless you pass `--personal`, because they depend on one
machine's setup.

Check: in a Claude Code session, `/skills` lists the `x442-` skills.

---

## Step 5 — the graph tools

```bash
pipx install code-review-graph
pipx install graphifyy # double "y" on PyPI; the command it installs is `graphify`
pipx ensurepath        # then open a new terminal
```

Both are optional on paper: every graph hook checks for its tool and does nothing when it is
missing. In practice, without them an assistant falls back to grepping and re-reading files, which
is slower and costs far more tokens. Install both.

Do not run `code-review-graph install` on its own. Without flags it configures every platform it
detects, injects its own instruction blocks, and adds a second refresh hook that fights the one the
repo already has. A wired repo has already done the right install. [Graph hooks](graph-hooks.md)
explains this.

Check: `code-review-graph --version` and `graphify --version` both print.

---

## Step 6 — the secret guard

The secret guard stops an assistant from printing credential values into a transcript, which is
saved to disk and cannot be redacted after the fact. Installed once in your home directory, it
covers every repo you open. [Secret guard](secret-guard.md) explains what it does.

In any Claude Code session, ask:

```text
/x442-setup-secret-guard install the home layer
```

The first install on any machine needs `--adopt`. The installer compares what is installed against
what it ships and refuses on any difference, and a first install always differs. If it refuses, let
the assistant re-run it with `--adopt`. Anything it replaces is backed up to
`~/.secret-guard-backup/` first. It merges deny rules and a hook into `~/.claude/settings.json`; it does
not overwrite the file.

Check: the skill runs `verify-secret-guard.sh`. Every line should be `[PASS]`; `[warn]` lines never
fail. Then try it: ask the assistant to `cat` any `.env` file. You should see
`<redacted len=… sha256:…>` where the values were.

---

## Step 7 — global context and permissions

Your user-level files say how an assistant behaves in **every** repo: never `rm`, cap batch LLM
calls, delegate mechanical work to a cheaper model, commit in Conventional Commits format.
Repo-specific rules do not belong here. They live in each repo's `AGENTS.md`.

1. Create `~/.claude/CLAUDE.md` from the template in
   [Best practices — the standard global context](best-practices.md#the-standard-global-context).
2. Create `~/.claude/agents/sonnet-high.md` from the template in
   [Best practices — delegation](best-practices.md#delegation).
3. Add the permission baseline from [Best practices — permissions](best-practices.md#permissions)
   to `~/.claude/settings.json`. The secret guard already wrote its own deny rules there in step 6.
   Leave them alone, and add yours next to them.

Check: start a new session and ask "what are your rules for deleting files?" It should answer
`trash`, not `rm`.

---

## Step 8 — your first repo

Clone a repo that has already been onboarded (it has an `AGENTS.md` and a `scripts/husky.sh`):

```bash
git clone git@github.com:acme/acme-api.git
cd acme-api
pnpm run install:dev # once per clone: points git at the committed hooks
code .
```

Use the repo's own package manager (`npm run`, `yarn run`, `bun run`). A plain `install` does
**not** wire the git hooks. `install:dev` does, and it never runs on its own. Skip it, and the
commit-message check, the staged-file formatter and the graph refresh all silently do nothing.
Worktrees of the same clone need nothing extra.

When VS Code opens the folder:

- **Accept the recommended extensions** (ESLint and Prettier, or Python and Black, depending on the
  repo).
- **Allow automatic tasks** if VS Code asks. The "Bootstrap Workspace" task runs `initialize.sh`
  when the folder opens.
- **Approve the project MCP server** when Claude Code asks. `.mcp.json` registers
  `code-review-graph` for this repo.

Then start a Claude Code session in the repo. Its first message should include a
`GRAPH QUERY CHEATSHEET` and, on a repo with a board, the open handoffs. If the cheatsheet says the
graph is not built, ask the assistant to build it (`code-review-graph build`, then
`graphify update .`). It takes a minute or two on a mid-sized repo, and the hooks keep it fresh
afterwards.

---

## Step 9 — prove it works

| Check                      | Command or action                                                 | Expect                                                |
| -------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------- |
| Git hooks are active       | `git config core.hooksPath`                                       | a path ending in `.husky`                             |
| Commit messages are linted | `echo "Bad message" \| pnpm exec commitlint`                      | a non-zero exit with `type-empty` and `subject-empty` |
| Repo context loads         | ask "what are this repo's commit conventions?"                    | it quotes `AGENTS.md`                                 |
| Graph answers              | ask "who calls FUNCTION?" for a function you know                 | it uses `query_graph_tool`, not grep                  |
| Secrets stay hidden        | ask it to show a `.env`                                           | fingerprints, not values                              |
| Repo wiring is healthy     | ask "run the verifiers for initial-project and setup-graph-hooks" | `0 failed` in each summary                            |

The verifiers print `[PASS]`, `[warn]` and `[FAIL]` lines and end with
`Summary: N passed, W warnings, F failed`. Only a `[FAIL]` needs action. On a fresh clone, a
`[warn]` usually just means a graph is not built yet.

---

## Next

- [Daily prompts](daily-prompts.md) — the prompts that get the most out of this setup.
- [Handoff](handoff.md) — if the repo has a `.agents/handoff/` board, read this before you edit
  anything shared.
- [Best practices](best-practices.md) — why the global context says what it says.
