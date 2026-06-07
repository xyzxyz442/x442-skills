# x442-skills

Collection of agent skills for Claude Code, Antigravity (recommended), Gemini CLI, and GitHub Copilot.

> **Status:** iteration 1 in progress — bootstrap done; building the first skills, `initial-project` and `setup-graph-hooks`, under `skills/engineering/`.

## Roadmap

- [x] **Iteration 0** — bootstrap: AI context files ([AGENTS.md](AGENTS.md), [CLAUDE.md](CLAUDE.md), [ANTIGRAVITY.md](ANTIGRAVITY.md), [GEMINI.md](GEMINI.md), [.github/copilot-instructions.md](.github/copilot-instructions.md)), license, editor config, dev-loop scripts under `scripts/`.
- [ ] **Iteration 1** _(in progress)_ — first skills land under `skills/engineering/`: [`initial-project`](skills/engineering/initial-project/SKILL.md) and [`setup-graph-hooks`](skills/engineering/setup-graph-hooks/SKILL.md) (which `initial-project` offers to run on completion).
- [ ] **Iteration 2** — skill lint / validation tooling. <!-- TODO -->
- [ ] **Iteration 3** — TBD. <!-- TODO -->

## Layout

```text
.
├── AGENTS.md                       # shared rules for all AIs (source of truth)
├── CLAUDE.md                       # Claude Code overrides (imports AGENTS.md)
├── ANTIGRAVITY.md                  # Antigravity overrides
├── GEMINI.md                       # Gemini CLI overrides (deprecating)
├── .github/copilot-instructions.md # GitHub Copilot overrides
├── .vscode/settings.json           # wires Copilot to AGENTS.md
├── .mcp.json                       # code-review-graph MCP server (repo dogfoods setup-graph-hooks)
├── .claude/                        # Claude Code config: settings.example.json + hook scripts
├── .editorconfig                   # UTF-8, LF, 2-space indent, final newline
├── LICENSE                         # MIT
├── scripts/
│   ├── link-generic-skills.sh      # symlinks skills/**/ into ~/.agents/skills/ (generic default)
│   ├── link-claude-skills.sh       # symlinks skills/**/ into ~/.claude/skills/ (Claude Code)
│   └── list-skills.sh              # lists every SKILL.md in the repo
└── skills/
    └── engineering/                # category README + skills
        ├── initial-project/        # SKILL.md + references/
        └── setup-graph-hooks/      # SKILL.md + scripts/ + assets/
```

## Install

Pick one of three paths depending on your situation.

### 1. Quickstart via the `skills` CLI (recommended general path)

The [`skills`](https://github.com/vercel-labs/skills) CLI installs this repo's skills into every supported agent in one shot:

```bash
npx skills add git@github.com:xyzxyz442/x442-skills.git
```

### 2. Tool-specific install

Prefer your tool's native install path. The `npx skills add … -a <agent>` form is listed underneath each as an optional fallback (see [supported agents](https://github.com/vercel-labs/skills#supported-agents)).

#### Claude Code

```bash
claude plugin marketplace add xyzxyz442/x442-skills
```

Then, inside a Claude Code session:

```text
/plugin install <skill-name>@x442-skills
```

Optional fallback: `npx skills add git@github.com:xyzxyz442/x442-skills.git -a claude-code`. Overrides live in [CLAUDE.md](CLAUDE.md).

#### GitHub Copilot (VS Code)

Open the repo in VS Code. [.vscode/settings.json](.vscode/settings.json) sets `chat.agentFilesLocations` so [AGENTS.md](AGENTS.md) loads automatically into Copilot Chat.

Optional fallback: `npx skills add git@github.com:xyzxyz442/x442-skills.git -a github-copilot`. Overrides live in [.github/copilot-instructions.md](.github/copilot-instructions.md).

#### Antigravity CLI

```bash
antigravity install xyzxyz442/x442-skills
```

Optional fallback: `npx skills add git@github.com:xyzxyz442/x442-skills.git -a antigravity`. Overrides live in [ANTIGRAVITY.md](ANTIGRAVITY.md).

#### Gemini CLI

> [!WARNING]
> Gemini CLI is transitioning to Antigravity CLI (sunset **2026-06-18** for consumer tiers). For new setups, prefer Antigravity. Details: <https://goo.gle/gemini-cli-migration>.

```bash
gemini extensions install xyzxyz442/x442-skills
```

Optional fallback: `npx skills add git@github.com:xyzxyz442/x442-skills.git -a gemini-cli`. Overrides live in [GEMINI.md](GEMINI.md).

### 3. From source (dev loop / dogfooding)

For working on a skill in this repo and having your AI pick it up immediately:

```bash
git clone git@github.com:xyzxyz442/x442-skills.git
cd x442-skills
./scripts/link-generic-skills.sh  # generic install: symlinks each skills/**/ into ~/.agents/skills/
./scripts/link-claude-skills.sh   # Claude Code: symlinks ~/.agents/skills/ entries into ~/.claude/skills/
```

Skills install once into the generic `~/.agents/skills/` location (read by any AGENTS.md-aware CLI);
tool-specific scripts then symlink from there into the tool's own directory rather than back to the
repo. `link-claude-skills.sh` runs the generic install for you first, so the chain is
`repo → ~/.agents/skills → ~/.claude/skills`. Each linked skill is prefixed with `x442-`
(e.g. `x442-initial-project`) so it can't collide with a same-named built-in skill. Dedicated
scripts for Antigravity / Gemini / Copilot land in a later iteration.

## Skills overview

Every skill is a directory under `skills/<category>/` containing a `SKILL.md` — YAML frontmatter (`name`, `description`) plus a markdown body. Setup skills may also ship `scripts/` and `assets/`. See [AGENTS.md](AGENTS.md) for the full authoring spec.

Iteration 1 ships two skills under [`engineering`](skills/engineering/):

| Skill | What it does |
| --- | --- |
| [`initial-project`](skills/engineering/initial-project/SKILL.md) | Sets up a project's AI assistant config around a shared `AGENTS.md`, then offers to run `setup-graph-hooks`. |
| [`setup-graph-hooks`](skills/engineering/setup-graph-hooks/SKILL.md) | Wires a repo for a self-updating code knowledge graph (code-review-graph + graphify) so agents query the graph instead of grepping. |

This repo dogfoods `setup-graph-hooks` on itself — see [`.claude/`](.claude/) and [`.mcp.json`](.mcp.json).

## References

Some skills in this repo build on external prior art:

- [`setup-graph-hooks`](skills/engineering/setup-graph-hooks/SKILL.md) adapts setup steps from
  [_Graphify + code-review-graph: Build a Self-Updating Knowledge Graph for Claude Code and Other AI_](https://dev.to/mir_mursalin_ankur/graphify-code-review-graph-build-a-self-updating-knowledge-graph-for-claude-code-and-other-ai-j1m)
  by Mir Mursalin Ankur.
- [`initial-project`](skills/engineering/initial-project/SKILL.md) incorporates concepts from
  [multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills) — the
  Karpathy coding guidelines it wires into `AGENTS.md`.

## License

MIT — see [LICENSE](LICENSE).
