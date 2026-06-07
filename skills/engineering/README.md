# engineering

Skills for day-to-day software engineering work: scaffolding projects, making code changes,
debugging, methodology, and process. Use these when the task is about *how* to build, change, or
reason about code — independent of the specific stack.

## Skills in this category

| Skill | Purpose |
| --- | --- |
| `initial-project` | Set up a project's AI assistant config around a shared `AGENTS.md`, detecting and wiring each tool to it. |
| `setup-graph-hooks` | Wire a repo for a self-updating code knowledge graph (code-review-graph + graphify): Claude Code hooks, a git post-commit refresh, and an `AGENTS.md` routing block. Chains after `initial-project`. |

## Authoring conventions

See [../../AGENTS.md](../../AGENTS.md) for skill-authoring rules (frontmatter, kebab-case naming,
house rules). Skills install into the generic `~/.agents/skills/` location with an `x442-` prefix at
link time — see the repo [README](../../README.md) for the dev-loop install scripts.
