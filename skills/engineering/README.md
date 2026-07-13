# engineering

Skills for day-to-day software engineering work: scaffolding projects, making code changes,
debugging, methodology, and process. Use these when the task is about _how_ to build, change, or
reason about code — independent of the specific stack.

## Skills in this category

| Skill                       | Status         | Purpose                                                                                                                                                                                                                                           |
| --------------------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `initial-project`           | `stable`       | Set up a project's AI assistant config around a shared `AGENTS.md`, detecting and wiring each tool to it.                                                                                                                                         |
| `setup-project-tooling`     | `experimental` | Detect the project profile (category, language, framework, package manager) and scaffold matching dev tooling: commitlint + husky, lint-staged/prettier/ruff/black/sqlfluff, a VS Code workspace, and release-it. Chains after `initial-project`. |
| `setup-graph-hooks`         | `stable`       | Wire a repo for a self-updating code knowledge graph (code-review-graph + graphify): tool-generic hooks (Claude Code, Gemini CLI, GitHub Copilot), a git post-commit refresh, and an `AGENTS.md` routing block. Chains after `initial-project`.   |
| `repair-graph-hooks`        | `experimental` | Smoke-test graph-tool integrity, then re-check, validate, and repair the graph-hooks wiring and graph state. Chains after `setup-graph-hooks`.                                                                                                    |
| `register-cross-repo-graph` | `experimental` | Declare sibling repos in a per-project `.graph-repos.json` cascade, then register/merge their graphs for read-only cross-repo access and record the in-scope list in `AGENTS.md`. Chains after `setup-graph-hooks`.                               |

Full per-skill detail (prerequisites, verification harness, status meanings) lives in the
[skills catalog](../README.md).

## Authoring conventions

See [../README.md](../README.md) for the catalog's authoring section and [../../AGENTS.md](../../AGENTS.md)
for the full skill-authoring rules (frontmatter, naming, house rules). Skills install into the
generic `~/.agents/skills/` location with an `x442-` prefix — see the repo
[README](../../README.md) for the dev-loop install scripts.
