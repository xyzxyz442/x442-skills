# Onboarding — an existing developer

You already use an AI assistant. Maybe for months. What you have probably grew one fix at a time: a
long personal `CLAUDE.md`, a permission list nobody has read through, hooks copied from a blog post,
VS Code settings that predate the repo's. None of that is wrong, but it drifts from what everyone
else runs. The usual symptoms are double cheatsheets, hooks that never fire, an assistant that
greps a repo that has a graph, or a commit rejected only on your machine.

This page is an audit, not an install guide. Each check takes under a minute. When one fails, it
links the step in [Onboarding — a new developer](onboarding-new-developer.md) that fixes it, so
nothing is described twice.

Run the checks top to bottom, in your own terminal rather than through an assistant. The later
ones assume the earlier ones pass.

---

## The fifteen-minute audit

### 1. Base tools and accounts

```bash
for t in git bash python3 node gh pipx trash code-review-graph graphify; do
  command -v "$t" > /dev/null && echo "ok    $t" || echo "MISS  $t"
done
gh auth status
```

| Finding                                            | Fix                                                                                                                       |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| any `MISS`                                         | [Step 1](onboarding-new-developer.md#step-1--base-tools) or [step 5](onboarding-new-developer.md#step-5--the-graph-tools) |
| the wrong GitHub account is active                 | `gh auth switch`; see [step 2](onboarding-new-developer.md#step-2--github-authentication)                                 |
| `graphify` missing but `graphify` is in `pip list` | you installed `graphify` (one "y"), a different package. `pipx install graphifyy`                                         |

### 2. Skill installs

List what your assistant actually loads:

```bash
ls -la ~/.claude/skills/ ~/.agents/skills/ 2> /dev/null | grep -i -e initial-project -e graph-hooks -e handoff
```

| Finding                                                     | Fix                                                                                                           |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| unprefixed names (`setup-graph-hooks`) next to `x442-` ones | an older install. Re-run `./scripts/link-claude-skills.sh` from the clone; it offers to trash the stale links |
| copied directories instead of symlinks                      | they will never update. Trash them, then reinstall ([step 4](onboarding-new-developer.md#step-4--the-skills)) |
| a skill shows up twice in `/skills`                         | a plugin install and a symlink install of the same skill. Keep one                                            |

### 3. Personal hooks that predate the repo's

This is the most common problem. Before the graph hooks shipped as a skill, they were often
installed by hand into `~/.claude/scripts/`, wired from `~/.claude/settings.json`. Those copies
still run, next to the repo's own. The result is two cheatsheets at session start, two graph
refreshes per turn, and occasionally a lock contention warning.

Inside any repo wired for graph hooks, ask the assistant to "run the graph-hooks verifier", or run
it yourself, and look for `user_hooks.predecessor`:

| Verifier says                                  | Meaning and fix                                                                 |
| ---------------------------------------------- | ------------------------------------------------------------------------------- |
| `[warn]` predecessor graph hooks are live      | `trash` each script the warning names. That alone stops them firing             |
| `[PASS]` … dead entries for …                  | the scripts are gone and the entries exit silently. Delete them when convenient |
| `[PASS]` no user-level predecessor graph hooks | nothing to do                                                                   |

The verifier only reads your home directory, and `repair-graph-hooks` only prints the `trash`
commands. Neither edits files outside the repo, so the fix is yours to run. The background is in
[Two generations of hooks](../graph-tools-during-development.md#two-generations-of-hooks-the-failure-outside-the-repo).

### 4. Global context

Open `~/.claude/CLAUDE.md` (and `~/.gemini/GEMINI.md` or your Copilot user instructions, if you use
those) and compare it against
[the standard global context](best-practices.md#the-standard-global-context).

| Finding                                                    | Fix                                                                   |
| ---------------------------------------------------------- | --------------------------------------------------------------------- |
| repo-specific rules ("in acme-api, always …")              | move them to that repo's `AGENTS.md`, where teammates also get them   |
| a copy of the coding guidelines or commit rules            | delete it. Each repo's `AGENTS.md` carries them, and two copies drift |
| a rule that contradicts the standard (e.g. "use `rm -rf`") | take the standard's version, or raise it with the team                |
| no delegation section, no batch guardrails                 | add them from the template                                            |

Repo instructions override user instructions where they conflict. A stale global rule therefore
does not break a wired repo. It breaks the repos that are not wired yet, which is where you are most
likely to be working unsupervised.

### 5. Permissions

```bash
python3 -c 'import json,os; p=json.load(open(os.path.expanduser("~/.claude/settings.json"))).get("permissions",{}); print({k:len(v) for k,v in p.items()}); print("rm denied:", any(r.startswith("Bash(rm") for r in p.get("deny",[])))'
```

| Finding                                                       | Fix                                                                                               |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `rm denied: False`                                            | add the deny baseline from [Best practices — permissions](best-practices.md#permissions)          |
| no `Read(**/.env)` style deny rules                           | the secret guard is not installed. [Step 6](onboarding-new-developer.md#step-6--the-secret-guard) |
| hundreds of `allow` entries, many with one-off arguments      | they were accepted one prompt at a time. Prune to verb-level patterns (`Bash(git commit *)`)      |
| you habitually start sessions with permission checks disabled | stop. The deny rules are what make an unattended session safe                                     |

### 6. A repo you already work in

Inside a repo that has been onboarded (it has `AGENTS.md` and `scripts/husky.sh`):

```bash
git config core.hooksPath # expect: a path ending in .husky
ls .husky/                # expect: commit-msg, pre-commit, post-commit
```

| Finding                                       | Fix                                                                                                       |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `core.hooksPath` is empty                     | your clone predates the tooling. Run `pnpm run install:dev` once (or the repo's package manager)          |
| `core.hooksPath` ends in `.husky/_`           | an old husky install. Run `install:dev`; it repoints to `.husky` itself                                   |
| the session shows no `GRAPH QUERY CHEATSHEET` | the graph is not built in this clone, or the MCP server is not approved. Run `/mcp`, then ask for a build |
| two cheatsheets                               | go back to check 3                                                                                        |

### 7. VS Code

Workspace settings (`.vscode/settings.json`, committed) override your user settings. That is
usually what you want, but check for conflicts:

| Finding                                                             | Fix                                                                                                                  |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| your files are reformatted with different quotes or indents on save | a user-level formatter is winning in a language the workspace does not configure. Install the recommended extensions |
| Copilot ignores `AGENTS.md`                                         | the workspace needs `"chat.agentFilesLocations": {".": true}`                                                        |
| Copilot chat does not show the graph steer or handoff gate          | the workspace needs `"chat.useClaudeHooks": true`                                                                    |
| the repo's `.vscode/settings.json` contains comments                | installers will not rewrite a JSONC file. They print the keys to add by hand                                         |

---

## When the audit is clean

You are on the same footing as a new developer who finished the onboarding. Read
[Daily prompts](daily-prompts.md). It covers the habits that are worth relearning once the setup
underneath you is standard.

If a repo you work in fails check 6 even after `install:dev`, the repo was never onboarded, or it
was onboarded only partly. That is a project problem, not a developer one. See
[Onboarding — a project](onboarding-project.md#situation--a-half-migrated-repo).
