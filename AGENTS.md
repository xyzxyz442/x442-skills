# x442-skills

<!-- TODO: one-line description of this skills collection. -->

This repository is the **single source of truth** for AI assistants working in this project. Tool-specific overrides live in:

- [CLAUDE.md](CLAUDE.md) — Claude Code
- [GEMINI.md](GEMINI.md) — Gemini CLI
- [.github/copilot-instructions.md](.github/copilot-instructions.md) — GitHub Copilot

Read this file first, then your tool-specific file for any overrides.

## Project overview

`x442-skills` is a collection of agent skills — reusable, model-agnostic capability packs written in markdown. Skills extend an AI assistant's behavior in a discoverable, on-demand way: the assistant reads a skill's frontmatter to decide *when* to invoke it, then loads the body for the *how*.

The repo contains **no application code**. Everything ships as markdown plus the occasional supporting reference file.

## Repository structure

<!-- TODO: confirm and document the on-disk layout once skills land. Suggested shape: -->

```text
.
├── AGENTS.md                       # shared rules (this file)
├── CLAUDE.md                       # Claude-only overrides
├── GEMINI.md                       # Gemini-only overrides
├── .github/copilot-instructions.md # Copilot-only overrides
├── README.md                       # human-facing project docs
└── skills/
    └── <skill-name>/
        ├── SKILL.md                # frontmatter + body
        └── references/             # optional supporting files
```

## Skill authoring conventions

Every skill is a directory under `skills/` containing a `SKILL.md` with YAML frontmatter:

```markdown
---
name: kebab-case-skill-name
description: One sentence that tells the assistant WHEN to use this skill. Be specific about triggers.
---

Skill body — instructions, examples, checklists, references.
```

Rules:

- **`name`**: lowercase kebab-case, must match the directory name.
- **`description`**: the only thing the assistant sees at discovery time. Lead with trigger conditions ("Use when…"). Keep under ~200 chars.
- **Markdown only**: no executable code shipped from the skill itself. Supporting reference files (JSON, YAML, sample inputs) go under `references/`.
- **One skill, one purpose**: if a skill describes two unrelated workflows, split it.
- **Link, don't duplicate**: cross-reference other skills with relative links instead of copying their content.

## House rules

- **Formatting**: defer to [.editorconfig](.editorconfig) — UTF-8, LF, 2-space indent, final newline. Markdown files keep trailing whitespace (line-break semantics).
- **No emojis** in skill content unless a skill is explicitly about emoji usage.
- **No destructive shell commands** in examples. Use `trash` instead of `rm`; never demonstrate `rm -rf`, `git push --force`, or `git reset --hard` without an explicit safety rail.
- **Cite sources** when a skill encodes external API behavior or a vendor convention — link to the upstream doc so future-you can verify it still holds.
- **Voice**: imperative, second person ("Do X", "Avoid Y"). No marketing language.

## Workflow

To add a new skill:

1. Create `skills/<skill-name>/SKILL.md` with the frontmatter shape above.
2. Write the body — start with *when to use*, then *how*, then *examples*.
3. <!-- TODO: lint/validation command once one exists. -->
4. Commit. One skill per commit keeps history reviewable.

To edit an existing skill: change `SKILL.md` in place; don't fork into a `v2/` directory.

## References

- Tool-specific overrides live in the per-AI files listed at the top.
- <!-- TODO: link to upstream skill-format spec once a canonical URL exists. -->
