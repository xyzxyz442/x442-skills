# x442-skills

Collection of agent skills for Claude Code, Gemini CLI, and GitHub Copilot.

> **Status:** iteration zero — bootstrap only. No skills shipped yet.

## Roadmap

- [x] **Iteration 0** — bootstrap: AI context files ([AGENTS.md](AGENTS.md), [CLAUDE.md](CLAUDE.md), [GEMINI.md](GEMINI.md), [.github/copilot-instructions.md](.github/copilot-instructions.md)), license, editor config.
- [ ] **Iteration 1** — first skills land under `skills/`. <!-- TODO -->
- [ ] **Iteration 2** — skill lint / validation tooling. <!-- TODO -->
- [ ] **Iteration 3** — TBD. <!-- TODO -->

## Layout

```text
.
├── AGENTS.md                       # shared rules for all AIs
├── CLAUDE.md                       # Claude Code overrides
├── GEMINI.md                       # Gemini CLI overrides
├── .github/copilot-instructions.md # GitHub Copilot overrides
├── .vscode/settings.json           # wires Copilot to AGENTS.md
├── LICENSE                         # MIT
└── skills/                         # (not yet created — iteration 1)
```

## Install

### Claude Code

```bash
claude plugin marketplace add xyzxyz442/x442-skills
```

Then, inside a Claude Code session:

```text
/plugin install <skill-name>@x442-skills
```

`<skill-name>` is a placeholder until iteration 1 ships plugins. Overrides live in [CLAUDE.md](CLAUDE.md).

### Gemini CLI

```bash
npx skills add git@github.com:xyzxyz442/x442-skills.git
```

Overrides live in [GEMINI.md](GEMINI.md).

### GitHub Copilot (VS Code)

```bash
npx skills add git@github.com:xyzxyz442/x442-skills.git
```

[.vscode/settings.json](.vscode/settings.json) auto-loads `AGENTS.md` into Copilot Chat. Overrides live in [.github/copilot-instructions.md](.github/copilot-instructions.md).

## Skills overview

No skills ship yet. Once iteration 1 begins, each skill is a directory under `skills/` containing a `SKILL.md` with YAML frontmatter (`name`, `description`) and a markdown body. See [AGENTS.md](AGENTS.md) for the full authoring spec.

## License

MIT — see [LICENSE](LICENSE).
