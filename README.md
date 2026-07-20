# x442-skills

My personal collection of agent skills — reusable, model-agnostic capability packs I use to wire
any repo for AI coding assistants (Claude Code, Antigravity, Gemini CLI, GitHub Copilot). This is
a personal-first workshop: I build, dogfood, and iterate on skills here, and may polish a few up
for sharing later.

> **Status:** engineering skills shipped under `skills/engineering/` —
> [`initial-project`](skills/engineering/initial-project/SKILL.md),
> [`setup-project-tooling`](skills/engineering/setup-project-tooling/SKILL.md) _(experimental)_,
> and [`setup-graph-hooks`](skills/engineering/setup-graph-hooks/SKILL.md), plus its two support
> skills [`repair-graph-hooks`](skills/engineering/repair-graph-hooks/SKILL.md)
> and [`register-cross-repo-graph`](skills/engineering/register-cross-repo-graph/SKILL.md), and
> [`setup-handoff`](skills/engineering/setup-handoff/SKILL.md) _(experimental)_ with its run
> skill [`run-handoff`](skills/engineering/run-handoff/SKILL.md) _(experimental)_.
> See the [skills catalog](skills/README.md) for the full detail.

## Philosophy

The design these skills share — and what they wire into the repos they touch:

- **One shared `AGENTS.md`.** Cross-tool guidance lives in a single source of truth; each tool's
  own file just loads it. No copy-paste drift across `CLAUDE.md` / `GEMINI.md` / `ANTIGRAVITY.md`.
- **Tool-generic.** A skill targets the behavior, not one vendor — the same skill wires Claude
  Code, Antigravity, Gemini CLI, and GitHub Copilot.
- **Model-agnostic markdown.** A skill is frontmatter (_when_ to use) plus a body (_how_). Setup
  skills may also ship `scripts/` and `assets/`; everything else is plain markdown.
- **Query, don't grep.** Repos get a self-updating code knowledge graph so agents ask the graph
  for structure instead of re-reading files.

## Roadmap

- [x] **Iteration 0** — bootstrap: AI context files ([AGENTS.md](AGENTS.md), [CLAUDE.md](CLAUDE.md), [ANTIGRAVITY.md](ANTIGRAVITY.md), [GEMINI.md](GEMINI.md), [.github/copilot-instructions.md](.github/copilot-instructions.md)), license, editor config, dev-loop scripts under `scripts/`.
- [x] **Iteration 1** — first skills land under `skills/engineering/`: [`initial-project`](skills/engineering/initial-project/SKILL.md), [`setup-project-tooling`](skills/engineering/setup-project-tooling/SKILL.md) _(experimental)_, and [`setup-graph-hooks`](skills/engineering/setup-graph-hooks/SKILL.md) (both of which `initial-project` offers to run on completion).
- [ ] **Iteration 2** — the eval harness — fixtures, graders, and A/B benchmarks that score what a skill actually produces — lands in [`harness/`](harness/README.md), specced by [docs/harness-structure.md](docs/harness-structure.md) and built on the per-skill read-only `verify-*.sh` checkers. Shipped so far: the shared `harness/lib/` graders plus a workspace for **all five** engineering skills (including a behavioral `setup-graph-hooks` fixture that proves the wired hooks actually steer a search), and the first committed benchmark iterations — deterministic `+1.00` A/B runs for [`setup-graph-hooks`](harness/setup-graph-hooks-workspace/iterations/iteration-1) and [`setup-project-tooling`](harness/setup-project-tooling-workspace/iterations/iteration-1) that exercise the grade → aggregate → benchmark pipeline end-to-end. Still open: a true **agent** A/B (LLM-driven, to measure whether a skill helps a model, not just the structural delta) and skill lint / validation tooling.
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
├── harness/                        # skill eval harness: fixtures, graders, A/B benchmarks
│   ├── lib/                        # shared graders (grade_common, aggregate, reorg)
│   └── <skill>-workspace/          # evals/ + fixtures/ + grade.py + iterations/
└── skills/
    ├── README.md                   # skills catalog: categories, status, per-skill detail
    └── engineering/                # category README + skills
        ├── initial-project/        # SKILL.md + references/ + scripts/
        ├── setup-project-tooling/  # SKILL.md + assets/ + scripts/  (experimental)
        ├── setup-graph-hooks/      # SKILL.md + scripts/ + assets/
        ├── repair-graph-hooks/     # SKILL.md only  (reuses setup-graph-hooks scripts)
        ├── register-cross-repo-graph/  # SKILL.md + scripts/ + assets/
        ├── setup-handoff/          # SKILL.md + scripts/ + assets/  (experimental)
        └── run-handoff/            # SKILL.md only  (experimental)
```

Skills are grouped by category under `skills/`; the [skills catalog](skills/README.md)
documents the full set of categories (`engineering/`, `productivity/`, `misc/`, `personal/`,
`in-progress/`, `deprecated/`) and which are promoted.

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
./scripts/link-generic-skills.sh # generic install: symlinks each skills/**/ into ~/.agents/skills/
./scripts/link-claude-skills.sh  # Claude Code: symlinks ~/.agents/skills/ entries into ~/.claude/skills/
```

Skills install once into the generic `~/.agents/skills/` location (read by any AGENTS.md-aware CLI);
tool-specific scripts then symlink from there into the tool's own directory rather than back to the
repo. `link-claude-skills.sh` runs the generic install for you first, so the chain is
`repo → ~/.agents/skills → ~/.claude/skills`. Each linked skill is prefixed with `x442-`
(e.g. `x442-initial-project`) so it can't collide with a same-named built-in skill. Dedicated
scripts for Antigravity / Gemini / Copilot land in a later iteration.

## Skills overview

Seven skills under [`engineering`](skills/engineering/); the [skills catalog](skills/README.md)
has the full detail (status, prerequisites, verification harness, conventions):

| Skill                                                                                | Status         | What it does                                                                                                                                                                                                                                   |
| ------------------------------------------------------------------------------------ | -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`initial-project`](skills/engineering/initial-project/SKILL.md)                     | `stable`       | Sets up a project's AI assistant config around a shared `AGENTS.md`, then offers to run `setup-project-tooling` and `setup-graph-hooks`.                                                                                                       |
| [`setup-project-tooling`](skills/engineering/setup-project-tooling/SKILL.md)         | `experimental` | Detects the project profile and scaffolds matching dev tooling: commitlint + husky, lint-staged/prettier/ruff/black/sqlfluff, a VS Code workspace, and release-it.                                                                             |
| [`setup-graph-hooks`](skills/engineering/setup-graph-hooks/SKILL.md)                 | `stable`       | Wires a repo for a self-updating code knowledge graph (code-review-graph + graphify) so agents query the graph instead of grepping.                                                                                                            |
| [`repair-graph-hooks`](skills/engineering/repair-graph-hooks/SKILL.md)               | `stable`       | Smoke-tests graph-tool integrity, then re-checks, validates, and repairs the graph-hooks wiring and graph state. Support skill for `setup-graph-hooks`.                                                                                        |
| [`register-cross-repo-graph`](skills/engineering/register-cross-repo-graph/SKILL.md) | `stable`       | Registers/merges another repo's graph for read-only cross-repo access and records it in `AGENTS.md` so agents query it instead of grepping. Support skill.                                                                                     |
| [`setup-handoff`](skills/engineering/setup-handoff/SKILL.md)                         | `experimental` | Installs a lease-based handoff protocol (`.agents/handoff/`) so multiple agents/sessions/repos share code without clobbering — atomic claim/release, per-tool enforcement hooks, and legacy-install migration. Chains after `initial-project`. |
| [`run-handoff`](skills/engineering/run-handoff/SKILL.md)                             | `experimental` | The claim → work → release discipline over an installed handoff board: check the board, claim before editing, release with an honest status. Support skill for `setup-handoff`.                                                                |

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
