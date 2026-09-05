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
├── CONTEXT.md                      # domain glossary (terms only, no implementation)
├── docs/adr/                       # architecture decision records
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
- **No `:` in any frontmatter value** (`name`, `description`, `argument-hint`, …): a colon breaks how the frontmatter renders in markdown previews and naive parsers, even inside a `>-` block scalar where YAML itself would allow it. Use an em dash instead. Same rule as handoff titles.
- **Markdown-first**: most skills ship markdown only, with supporting samples/data under `references/`. Setup and automation skills _may_ ship executables (shell, Python) and config payloads — put runnable scripts under `scripts/` and bundled payloads (templates, config) under `assets/`. The no-destructive-shell-commands house rule still applies to every shipped file.
- **One skill, one purpose**: if a skill describes two unrelated workflows, split it.
- **Link, don't duplicate**: cross-reference other skills with relative links instead of copying their content.
- **When a `setup-*` skill owes a `repair-*` sibling**: only when it manages state **outside the files it wrote** — a database, leases, a daemon, an external tool install. That state is what re-running an installer cannot fix. Otherwise upgrade belongs inside the setup skill, repair is "re-run it", and drift detection belongs in `verify-*.sh`. `setup-graph-hooks` (a graph DB, embeddings, locks) and `setup-handoff` (a live board of leases and a generated index) qualify; `setup-project-tooling`, `setup-secret-guard` (files it wrote plus a marked block in a shared settings file — nothing else) and the `register-cross-repo-*` sync skills do not.
- **When a skill owes a payload version stamp**: only when it **copies artifacts into the target repo** that can then drift from what the skill ships. Such a skill owns `scripts/payload.version` as the single source of truth and writes it on install — a `.version` file at the payload root, or a marker comment when the assets scatter and have no root. A skill whose install is regenerated on every run does not drift and needs no stamp. The comparison belongs in `verify-*.sh`, which runs from the skill directory and can reach both halves; a session hook runs inside the target repo, where the skill directory is unreachable, so it can never make it.

## Skill Index

| Category       | Skill                         | Status         | Purpose                                                                                                                                                                                                                                                                                                |
| -------------- | ----------------------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `engineering`  | `initial-project`             | `stable`       | Set up a project's AI-assistant config around a shared `AGENTS.md`, detecting and wiring each tool to it.                                                                                                                                                                                              |
| `engineering`  | `setup-project-tooling`       | `experimental` | Detect language, recommend a category, then scaffold a common base + per-language tooling (commitlint, lint-staged, `.gitignore`/`.gitattributes`, VS Code, release-it). Chains after `initial-project`.                                                                                               |
| `engineering`  | `setup-graph-hooks`           | `stable`       | Wire a self-updating code knowledge graph so agents query the graph instead of grepping. Chains after `initial-project`.                                                                                                                                                                               |
| `engineering`  | `repair-graph-hooks`          | `stable`       | Smoke-test graph-tool integrity, then re-check, validate, and repair the graph-hooks wiring and graph state. Chains after `setup-graph-hooks`.                                                                                                                                                         |
| `engineering`  | `register-cross-repo-graph`   | `stable`       | Declare sibling repos in a per-project `.graph-repos.json` cascade (user → repo → subdir), then register/merge their graphs for read-only cross-repo access and record the in-scope list in `AGENTS.md` so agents query it instead of grepping. Chains after `setup-graph-hooks`.                      |
| `engineering`  | `setup-secret-guard`          | `experimental` | Install the secret guard — a redacting read-path guard plus the shared detection and masking engine (`secret-scan`, `redact-view`) — into the `.claude` cascade, so a credential file stays usable while its values are replaced by stable fingerprints. Chains after `initial-project`.               |
| `engineering`  | `setup-handoff`               | `experimental` | Install a lease-based handoff coordination protocol (`.agents/handoff/`) so multiple agents/sessions/repos work the same code without clobbering — claim/release leases, per-tool enforcement hooks (user picks a primary), and legacy-install migration. Chains after `initial-project`.              |
| `engineering`  | `run-handoff`                 | `experimental` | The claim → work → release discipline over an installed handoff board: check the board, claim before editing, and release with an honest status (`done` requires evidence). Chains after `setup-handoff`.                                                                                              |
| `engineering`  | `delegate-handoff`            | `experimental` | Judgment for handing a handoff to someone outside the board — is it brief-able, how to review what comes back. Drives `handoff export`/`handoff import --result`; import never sets `status`. Ships markdown only. Chains after `run-handoff`.                                                         |
| `engineering`  | `repair-handoff`              | `experimental` | Smoke-test the handoff CLI, then re-check, validate, and repair the board wiring and board state (index drift, orphaned leases, doc frontmatter, section resolution, orphaned delegations). Chains after `setup-handoff`.                                                                              |
| `engineering`  | `register-cross-repo-handoff` | `experimental` | Declare groups of peer repos in a per-workspace `.agents/handoff.json` cascade (user → workspace → subdir), then sync to scaffold a standalone shared board owned by no repo and wire every member to its own sub-indexed section (subfolder or prefix layout). No seed. Chains after `setup-handoff`. |
| `productivity` | `release-announcement`        | `experimental` | Turn a tagged version and its changelog into a user-facing announcement shaped for its channel (GitHub release, Slack, email), leading with user impact rather than the file diff. Can emit a second language.                                                                                         |
| `personal`     | `register-delegate-agents`    | `experimental` | Manage the `.agents/delegate.json` cascade that decides which cheaper agents a repo may delegate to — declare agents in an uncommittable layer, narrow per repo, set the primary assistant. Chains before `setup-delegate-agent`.                                                                      |
| `personal`     | `setup-delegate-agent`        | `experimental` | Install the dispatcher, per-vendor adapters, consent gate and credential scanning, and render an `AGENTS.md` routing block from the agents the cascade permits. Chains after `register-delegate-agents`, before `run-delegate-agent`.                                                                  |
| `personal`     | `run-delegate-agent`          | `experimental` | The assess → ask → brief → dispatch → verify → report discipline over an installed delegation setup: the user approves before anything is dispatched, and the sub-agent can ask back rather than guess. Chains after `setup-delegate-agent`.                                                           |

Full per-skill detail (prerequisites, verification harness, status meanings) lives in the
[skills catalog](skills/README.md). Folders stay unprefixed; the `x442-` prefix lives in each
skill's frontmatter `name` (e.g. `initial-project/` → `name: x442-initial-project`).

`personal/` skills depend on one machine's setup and are **not installed by default** — the link
scripts skip them unless you pass `--personal` (e.g. `scripts/link-claude-skills.sh --personal`),
so the default install stays safe to run on any checkout.

## House rules

- **Formatting**: defer to [.editorconfig](.editorconfig) — UTF-8, LF, 2-space indent, final newline. Markdown files keep trailing whitespace (line-break semantics).
- **No emojis** in skill content unless a skill is explicitly about emoji usage.
- **No destructive shell commands** in examples. Use `trash` instead of `rm`; never demonstrate `rm -rf`, `git push --force`, or `git reset --hard` without an explicit safety rail.
- **Cite sources** when a skill encodes external API behavior or a vendor convention — link to the upstream doc so future-you can verify it still holds.
- **Voice**: imperative, second person ("Do X", "Avoid Y"). No marketing language.
- **Standalone repo — never reference another project.** This repo is the _source_ of skills, not a
  participant in anyone's fleet. Nothing committed here may name, path to, or execute code in
  another project: no `../<other-repo>/...` paths in config, hooks, or scripts; no real repo,
  team, service, group, or product names in docs, examples, or fixtures. That includes wiring
  this repo into a shared board, graph, or workspace owned elsewhere — install those _from_ here,
  do not commit the result _into_ here. Examples use neutral placeholders (`acme-api`,
  `acme-lib`, `svc-a`, `../workspace/src`). Enforced by
  [`scripts/verify-standalone.sh`](scripts/verify-standalone.sh), which runs on `pre-commit`
  and in CI — see [docs/standalone-rule.md](docs/standalone-rule.md) for the escape hatch.

## Domain language

[CONTEXT.md](CONTEXT.md) is the glossary — the canonical term for each concept these skills
install into other repos, with the near-synonyms to avoid. Use its terms in skill content,
commit messages, and handoff docs; when a term is missing or wrong, fix the glossary rather
than inventing a local synonym. It is a glossary and nothing else — no schema listings, no
implementation detail. Decisions live in [docs/adr/](docs/adr/).

## Coding guidelines

Follow the [Karpathy coding guidelines](skills/engineering/initial-project/references/karpathy-guidelines.md) for all work in this project.

## Commit conventions

Follow the [commit guidelines](skills/engineering/initial-project/references/commit-guidelines.md): Conventional Commits `type(scope): subject` (lowercase imperative subject, no trailing period). The enforced ruleset is [`commitlint.config.mjs`](commitlint.config.mjs) — the single source of truth; `setup-project-tooling` wires the husky `commit-msg` hook that enforces it locally.

**`.husky/` is committed on purpose — do not add it back to `.gitignore`.** `core.hooksPath` points at `.husky/` itself, and that setting lives in `.git/config`, which every git worktree of a clone shares. Track the hook files and a worktree gets them for free; ignore them and a worktree inherits a hooks path naming a directory it does not have, so git runs **no** hook at all — not commitlint, not lint-staged, not [`verify-standalone.sh`](scripts/verify-standalone.sh), not the graph post-commit refresh — and says nothing. Only `.husky/_`, husky's generated helper directory, stays ignored. `verify-project-tooling.sh` fails on both broken shapes.

A **fresh clone** still needs `pnpm run install:dev` once, to set `core.hooksPath`. Worktrees of that clone need nothing. (`install:dev` rather than a `prepare` script because `prepare` also runs on install in CI.)

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

Route by **intent** — pick the lane for what you are trying to do, not for what just failed:

| Intent                                 | Lane                                                               |
| -------------------------------------- | ------------------------------------------------------------------ |
| find code by meaning ("what does X")   | `semantic_search_nodes_tool(query=X)` — see search modes below     |
| who calls / imports a known symbol     | `query_graph_tool(pattern=callers_of\|importers, target=X)`        |
| pre-refactor blast radius              | `get_impact_radius_tool(changed_files=[...])`                      |
| code review / PR impact                | `get_review_context_tool(changed_files=[...])`                     |
| architecture overview                  | `list_communities_tool()` — never `get_architecture_overview_tool` |
| explore / explain / onboard, code↔docs | `graphify query\|explain '<term>' --graph graphify-out/graph.json` |
| shortest path A→B                      | `graphify path '<A>' '<B>' --graph graphify-out/graph.json`        |
| exact string, config value, log text   | `grep` (append `--graph-tried` to bypass the graph gate)           |

These are lanes, **not a chain**. Graphify is not a CRG fallback — reach for it when the question
is exploratory, up front. And when a meaning-based search does not answer, the next stop is
`grep`, not graphify: what semantic search cannot find is usually what is not in the AST graph at
all — string literals, config values, comments, generated files, migrations. That is grep's
territory by construction.

### Search tiers — prefer vector, keyword is the floor

`semantic_search_nodes_tool` answers in one of three tiers. Prefer the richest one available, and
**state which tier a search used** when it backs an answer. Preference order is
**custom → local → keyword** (`./setup-embeddings.sh` sets it up in that order):

1. **custom** — vectors from an external / OpenAI-compatible provider. Richest.
   These are read ONLY when pinned, or the tool silently drops to keyword:
   `semantic_search_nodes_tool(query=X, provider="openai", model="<model>")`.
2. **local** — vectors from CRG's built-in model. Read by default, no pin: `semantic_search_nodes_tool(query=X)`.
3. **keyword** — no vectors: name match over symbols. Still the right tool, not a failure; a
   shallow result is not a reason to grep.

Which tier is live is announced at session start (`search tier: …` in the cheatsheet) and marked
on every grep pre-answer (`[search tier: keyword]`, since the grep gate always name-matches). A
keyword-_tier_ result is a quality difference, not an availability one — do not reach for grep
because a result looked shallow.

### Search modes — say which one answered

Tier is what this repo _can_ do; **`search_mode` is what a given query actually did.**
`semantic_search_nodes_tool` returns it per call as `semantic`, `fts`, or `keyword`, and there is
no minimum-score threshold — the tool returns its top _k_ whether or not anything actually
matched. A weak result is therefore indistinguishable from a good one unless you look.

**State the `search_mode` when a search backs an answer.** Then read it:

- `search_mode` matches the live tier → the vectors answered; trust it as far as the results go.
- Live tier is vector but `search_mode` came back `fts` or `keyword` → the vectors did **not**
  answer this query (unpinned custom vectors, or a provider mismatch). Pin the model and retry,
  and if it still degrades, `grep` is legitimate — this is the one case where a disappointing
  search _is_ a reason to grep.
- Live tier is already `keyword` → nothing degraded; see the tier note above.

If no graph exists yet, ask to run: `code-review-graph build`.
The graph refreshes automatically (the primary tool's end-of-turn hook + a git post-commit
refresh that runs regardless of tool); you do not need to rebuild it manually after edits.

<!-- graph-hooks:end -->
