# x442-skills

Collection of agent skills for Claude Code, Antigravity (recommended), Gemini CLI, and GitHub Copilot.

> **Status:** iteration zero — bootstrap complete; `skills/engineering/` and `scripts/` scaffolded, first skill content WIP.

## Roadmap

- [x] **Iteration 0** — bootstrap: AI context files ([AGENTS.md](AGENTS.md), [CLAUDE.md](CLAUDE.md), [ANTIGRAVITY.md](ANTIGRAVITY.md), [GEMINI.md](GEMINI.md), [.github/copilot-instructions.md](.github/copilot-instructions.md)), license, editor config, dev-loop scripts under `scripts/`.
- [ ] **Iteration 1** — first skills land under `skills/` (`skills/engineering/` scaffold exists). <!-- TODO -->
- [ ] **Iteration 2** — skill lint / validation tooling. <!-- TODO -->
- [ ] **Iteration 3** — TBD. <!-- TODO -->

## Layout

```text
.
├── AGENTS.md                       # shared rules for all AIs
├── CLAUDE.md                       # Claude Code overrides
├── ANTIGRAVITY.md                  # Antigravity overrides
├── GEMINI.md                       # Gemini CLI overrides (deprecating)
├── .github/copilot-instructions.md # GitHub Copilot overrides
├── .vscode/settings.json           # wires Copilot to AGENTS.md
├── LICENSE                         # MIT
├── scripts/
│   ├── link-skills.sh              # symlinks skills/**/ into ~/.agents/skills/ (generic default)
│   ├── link-claude-skills.sh       # symlinks skills/**/ into ~/.claude/skills/ (Claude Code)
│   └── list-skills.sh              # lists every SKILL.md in the repo
└── skills/
    └── engineering/                # category scaffold (first skills WIP)
```

## Install

Pick one of three paths depending on your situation.

### 1. Quickstart via `skills.sh` (recommended general path)

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
./scripts/link-skills.sh          # generic install: symlinks each skills/**/ into ~/.agents/skills/
./scripts/link-claude-skills.sh   # Claude Code: symlinks ~/.agents/skills/ entries into ~/.claude/skills/
```

Skills install once into the generic `~/.agents/skills/` location (read by any AGENTS.md-aware CLI);
tool-specific scripts then symlink from there into the tool's own directory rather than back to the
repo. `link-claude-skills.sh` runs the generic install for you first, so the chain is
`repo → ~/.agents/skills → ~/.claude/skills`. Each linked skill is prefixed with `x442-`
(e.g. `x442-initial-project`) so it can't collide with a same-named built-in skill. Dedicated
scripts for Antigravity / Gemini / Copilot land in a later iteration.

## Skills overview

No skills ship yet. Once iteration 1 begins, each skill is a directory under `skills/` containing a `SKILL.md` with YAML frontmatter (`name`, `description`) and a markdown body. See [AGENTS.md](AGENTS.md) for the full authoring spec.

## License

MIT — see [LICENSE](LICENSE).
