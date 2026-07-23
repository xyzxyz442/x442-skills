# AGENTS.md

A personal collection of reusable, model-agnostic agent skills that wire any repo for AI coding assistants (Claude Code, Antigravity, Gemini CLI, GitHub Copilot).

This repository is the **single source of truth** for AI assistants working in this project. Tool-specific overrides live in:

- [CLAUDE.md](CLAUDE.md) — Claude Code
- [ANTIGRAVITY.md](ANTIGRAVITY.md) — Antigravity
- [GEMINI.md](GEMINI.md) — Gemini CLI (transitioning to Antigravity, see migration link in GEMINI.md)
- [.github/copilot-instructions.md](.github/copilot-instructions.md) — GitHub Copilot

Read this file first, then your tool-specific file for any overrides.

## Project overview

`x442-skills` is a collection of agent skills — reusable, model-agnostic capability packs written in markdown. Skills extend an AI assistant's behavior in a discoverable, on-demand way: the assistant reads a skill's frontmatter to decide _when_ to invoke it, then loads the body for the _how_.

The repo contains **no application code**. Everything ships as markdown plus the occasional supporting reference file.

## Repository structure

```text
.
├── AGENTS.md                       # shared rules (this file)
├── CLAUDE.md                       # Claude-only overrides
├── ANTIGRAVITY.md                  # Antigravity-only overrides
├── GEMINI.md                       # Gemini-only overrides (deprecating — see GEMINI.md)
├── .github/copilot-instructions.md # Copilot-only overrides
├── README.md                       # human-facing project docs
└── skills/
    └── <skill-name>/
        ├── SKILL.md                # frontmatter + body
        ├── references/             # optional supporting files (samples, data, docs)
        ├── scripts/                # optional executables for setup/automation skills
        └── assets/                 # optional bundled payloads (configs, templates)
```

## Skill authoring conventions

Every skill is a directory under `skills/` containing a `SKILL.md` with YAML frontmatter:

```markdown
---
name: x442-kebab-case-skill-name
description: One sentence that tells the assistant WHEN to use this skill. Be specific about triggers.
---

Skill body — instructions, examples, checklists, references.
```

Rules:

- **`name`**: lowercase kebab-case, **`x442-`-prefixed**, matching the directory name's
  unprefixed part (folder `initial-project` → `name: x442-initial-project`). The directory stays
  **unprefixed**; the prefix lives in the frontmatter so the installed slash-command is
  unambiguous across environments (a skill from this repo never collides with a same-named
  personal or built-in skill) and shows on every install path — `npx skills add` and the Claude
  plugin marketplace read the frontmatter `name`, while the dev-loop link scripts also prefix the
  symlink directory.
- **`description`**: the only thing the assistant sees at discovery time. Lead with trigger conditions ("Use when…"). Keep under ~200 chars.
- **Markdown-first**: most skills ship markdown only, with supporting samples/data under `references/`. Setup and automation skills _may_ ship executables (shell, Python) and config payloads — put runnable scripts under `scripts/` and bundled payloads (templates, config) under `assets/`. The no-destructive-shell-commands house rule still applies to every shipped file.
- **One skill, one purpose**: if a skill describes two unrelated workflows, split it.
- **Link, don't duplicate**: cross-reference other skills with relative links instead of copying their content.

## Skill Index

| Category      | Skill                       | Status         | Purpose                                                                                                                                                                                                                                                                                   |
| ------------- | --------------------------- | -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `engineering` | `initial-project`           | `stable`       | Set up a project's AI-assistant config around a shared `AGENTS.md`, detecting and wiring each tool to it.                                                                                                                                                                                 |
| `engineering` | `setup-project-tooling`     | `experimental` | Detect language, recommend a category, then scaffold a common base + per-language tooling (commitlint, lint-staged, VS Code, release-it). Chains after `initial-project`.                                                                                                                 |
| `engineering` | `setup-graph-hooks`         | `stable`       | Wire a self-updating code knowledge graph so agents query the graph instead of grepping. Chains after `initial-project`.                                                                                                                                                                  |
| `engineering` | `repair-graph-hooks`        | `stable`       | Smoke-test graph-tool integrity, then re-check, validate, and repair the graph-hooks wiring and graph state. Chains after `setup-graph-hooks`.                                                                                                                                            |
| `engineering` | `register-cross-repo-graph` | `stable`       | Declare sibling repos in a per-project `.graph-repos.json` cascade (user → repo → subdir), then register/merge their graphs for read-only cross-repo access and record the in-scope list in `AGENTS.md` so agents query it instead of grepping. Chains after `setup-graph-hooks`.         |
| `engineering` | `setup-handoff`             | `experimental` | Install a lease-based handoff coordination protocol (`.agents/handoff/`) so multiple agents/sessions/repos work the same code without clobbering — claim/release leases, per-tool enforcement hooks (user picks a primary), and legacy-install migration. Chains after `initial-project`. |
| `engineering` | `run-handoff`               | `experimental` | The claim → work → release discipline over an installed handoff board: check the board, claim before editing, and release with an honest status (`done` requires evidence). Chains after `setup-handoff`.                                                                                 |

Full per-skill detail (prerequisites, verification harness, status meanings) lives in the
[skills catalog](skills/README.md). Folders stay unprefixed; the `x442-` prefix lives in each
skill's frontmatter `name` (e.g. `initial-project/` → `name: x442-initial-project`).

## House rules

- **Formatting**: defer to [.editorconfig](.editorconfig) — UTF-8, LF, 2-space indent, final newline. Markdown files keep trailing whitespace (line-break semantics).
- **No emojis** in skill content unless a skill is explicitly about emoji usage.
- **No destructive shell commands** in examples. Use `trash` instead of `rm`; never demonstrate `rm -rf`, `git push --force`, or `git reset --hard` without an explicit safety rail.
- **Cite sources** when a skill encodes external API behavior or a vendor convention — link to the upstream doc so future-you can verify it still holds.
- **Voice**: imperative, second person ("Do X", "Avoid Y"). No marketing language.

## Coding guidelines

Follow the [Karpathy coding guidelines](skills/engineering/initial-project/references/karpathy-guidelines.md) for all work in this project.

## Commit conventions

Follow the [commit guidelines](skills/engineering/initial-project/references/commit-guidelines.md): Conventional Commits `type(scope): subject` (lowercase imperative subject, no trailing period). The enforced ruleset is [`commitlint.config.mjs`](commitlint.config.mjs) — the single source of truth; `setup-project-tooling` wires the husky `commit-msg` hook that enforces it locally.

## Workflow

To add a new skill:

1. Create `skills/<skill-name>/SKILL.md` with the frontmatter shape above.
2. Write the body — start with _when to use_, then _how_, then _examples_.
3. Give the skill an eval: add a `harness/<skill-name>-workspace/` with fixtures, cases, and a grader that wraps the skill's read-only `verify-*.sh`. See [docs/harness-structure.md](docs/harness-structure.md).
4. Commit. One skill per commit keeps history reviewable.

To edit an existing skill: change `SKILL.md` in place; don't fork into a `v2/` directory.

## References

- Tool-specific overrides live in the per-AI files listed at the top.
- <!-- TODO: link to upstream skill-format spec once a canonical URL exists. -->

<!-- graph-hooks:begin (managed by setup-graph-hooks — do not edit between markers) -->

## Knowledge Graph (code navigation)

This repo has a self-updating code knowledge graph. **Before** you grep, find, glob, or read
multiple source files to answer a code question, query the graph — it is far cheaper and more
precise. Reach for it when you:

- answer architecture, cross-module, or "how does X work" questions
- are about to grep / find / glob the codebase
- need to trace a call chain or get oriented in an unfamiliar module
- are about to refactor something with unclear blast radius

Routing (CRG first, graphify on miss, grep last):

| Need                            | Use                                                                |
| ------------------------------- | ------------------------------------------------------------------ |
| where is X defined              | `semantic_search_nodes_tool(query=X)`                              |
| who calls / imports X           | `query_graph_tool(pattern=callers_of\|importers, target=X)`        |
| pre-refactor blast radius       | `get_impact_radius_tool(changed_files=[...])`                      |
| code review / PR impact         | `get_review_context_tool(changed_files=[...])`                     |
| architecture overview           | `list_communities_tool()` — never `get_architecture_overview_tool` |
| CRG miss / neighborhood explore | `graphify query '<term>' --graph graphify-out/graph.json`          |
| shortest path A→B               | `graphify path '<A>' '<B>' --graph graphify-out/graph.json`        |
| string / config / log text      | `grep` (append `--graph-tried` to bypass the graph gate)           |

`semantic_search_nodes_tool` works whether or not this repo enabled vector embeddings — without
them it falls back to keyword search over symbol names. Weaker phrasing-tolerance, same tool, not
a failure. Do not reach for grep because a result looked shallow.

This repo embeds via Ollama, and the tool's `provider` argument defaults to `local`. To get
vector results rather than the keyword fallback, pin it:
`semantic_search_nodes_tool(query=…, provider="openai", model="qwen3-embedding")`.

If no graph exists yet, ask to run: `code-review-graph build`.
The graph refreshes automatically (the primary tool's end-of-turn hook + a git post-commit
refresh that runs regardless of tool); you do not need to rebuild it manually after edits.

<!-- graph-hooks:end -->

<!-- handoff:begin (managed by setup-handoff — do not edit between markers) -->

## Handoff Coordination

This repo coordinates cross-session / cross-repo work through a lease-based **handoff board**
in `.agents/handoff/`. **Claim before you work. Release when you stop.**

Before starting any tracked work, check the board and claim your unit. `claim` fails if someone
holds a live lease — pick another handoff or tell the user who holds it. Do **not** edit a handoff
doc you do not hold the lease for (the hooks block it).

```text
.agents/handoff/handoff list
.agents/handoff/handoff claim HANDOFF_ID "what you're doing"
```

File a new handoff when your work hands off to another session/repo, or when you find work you
will not finish here (SEVERITY is low, medium, or high):

```text
.agents/handoff/handoff new HANDOFF_ID --title "..." --severity SEVERITY
```

Titles must not contain `:` — a colon breaks the doc's YAML frontmatter in markdown previews. Use
an em dash instead (`Handoff — auth suite`); the tool folds any colon you pass to `—` anyway.

Handoff docs are **committed to the repo and its git history** — never paste keys, secrets,
passwords, or PII into one. Redact them; if the next agent needs a credential, prompt the user and
supply it via a safe channel (env var, secret-manager reference, or out-of-band), recording only
its name in the doc.

Release when you stop, with an honest status. `done` means **verified against the live code**,
not "the doc says resolved" — it requires `--verified-by`. `blocked` requires `--blocked-on`
(another handoff id, or "external: ..."). `INDEX.md` is generated; never hand-edit it.

```text
.agents/handoff/handoff release HANDOFF_ID --status open
.agents/handoff/handoff release HANDOFF_ID --status blocked --blocked-on OTHER_ID
.agents/handoff/handoff release HANDOFF_ID --status done --verified-by "how you verified live code"
```

Full protocol: [.agents/handoff/README.md](.agents/handoff/README.md).

<!-- handoff:end -->
