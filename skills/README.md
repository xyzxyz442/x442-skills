# Skills catalog

The detailed index of every skill in this repo. The root [README](../README.md) is the
project overview; this file is the catalog — categories, status, per-skill detail, and the
authoring conventions. House rules (formatting, no emoji, no destructive commands, voice)
live once in [AGENTS.md](../AGENTS.md) — this file links to them rather than restating.

Each skill is a directory `skills/<category>/<skill-name>/` holding a `SKILL.md` (YAML
frontmatter + markdown body), optionally with `scripts/`, `references/`, and `assets/`.

## Categories

Skills are bucketed by role. Only the first three are promoted — the dev-loop link scripts
([`link-generic-skills.sh`](../scripts/link-generic-skills.sh)) skip `personal/`,
`in-progress/`, and `deprecated/`, so they never install into `~/.agents/skills/`.

| Category        | Holds                                                               | Linked / installed? |
| --------------- | ------------------------------------------------------------------- | ------------------- |
| `engineering/`  | daily code work — scaffolding, code changes, debugging, methodology | yes                 |
| `productivity/` | daily non-code workflow tools                                       | yes                 |
| `misc/`         | kept around but rarely used                                         | yes                 |
| `personal/`     | tied to one person's own setup, not promoted                        | no                  |
| `in-progress/`  | drafts not yet ready to ship                                        | no                  |
| `deprecated/`   | no longer used, retained for history                                | no                  |

A skill never nests inside another skill. Add a category by creating the directory with its
own `README.md`.

## Status

`Status` in the catalog below is the skill's own maturity, independent of its category:

| Status         | Meaning                                                                 |
| -------------- | ----------------------------------------------------------------------- |
| `stable`       | shipped; verified; safe to rely on                                      |
| `beta`         | usable, but rough edges or thin verification                            |
| `experimental` | newer; behavior/output may change; opt-in — verify before relying on it |
| `draft`        | incomplete; expect breakage (usually under `in-progress/`)              |
| `deprecated`   | retired; kept for reference (usually under `deprecated/`)               |

## Catalog

`Skill` is the installed (slash) name — `x442-`-prefixed (see [Conventions](#authoring--conventions)).
`Requires` lists hard preconditions; `Harness` is the bundled read-only checker that verifies
a wired repo.

### `engineering/`

| Skill                                                                              | Purpose                                                                                                                                                                                                                                                                                                                                                  | Status         | Requires                                                                                                                                            | Harness                                                                                                                                                                                                                                                                                                                                                 | Remark                                                                                                                                                                                              |
| ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`x442-initial-project`](engineering/initial-project/SKILL.md)                     | Set up a project's AI-assistant config around a shared `AGENTS.md`, detecting and wiring each tool (Claude Code, Antigravity, Gemini CLI, GitHub Copilot) to load it.                                                                                                                                                                                    | `stable`       | Run from the target repo root.                                                                                                                      | [`verify-initial-project.sh`](engineering/initial-project/scripts/verify-initial-project.sh) — asserts `AGENTS.md` + `## Coding guidelines`, per-tool wiring, and no guideline duplication.                                                                                                                                                             | Idempotent; on completion rechecks the chain (as if fresh) and runs any not-yet-wired step — `setup-project-tooling`, `setup-graph-hooks`, `setup-handoff` — skipping those already wired.          |
| [`x442-setup-project-tooling`](engineering/setup-project-tooling/SKILL.md)         | Detect the language, recommend a category to confirm, then scaffold a common base plus per-language dev tooling: commitlint + husky, lint-staged (prettier/black/sqlfluff), a VS Code workspace, and release-it. Python and Node/TS strict; rest get the base.                                                                                           | `experimental` | A project to scaffold; chains after `initial-project`. Node-rooted (husky/commitlint/lint-staged/release-it).                                       | [`verify-project-tooling.sh`](engineering/setup-project-tooling/scripts/verify-project-tooling.sh) — checks the scaffolded commit/lint/format/release config is present and valid.                                                                                                                                                                      | Output may change between versions — review what it writes before relying on it.                                                                                                                    |
| [`x442-setup-graph-hooks`](engineering/setup-graph-hooks/SKILL.md)                 | Wire a self-updating code knowledge graph (code-review-graph + graphify) so agents query the graph instead of grepping; tool-generic with a git post-commit refresh.                                                                                                                                                                                     | `stable`       | `AGENTS.md` present (run `initial-project` first); a git work-tree. `code-review-graph` / `graphify` are optional — needed only to build the graph. | [`verify-graph-hooks.sh`](engineering/setup-graph-hooks/scripts/verify-graph-hooks.sh) — asserts the shared `.graph-hooks/` layer, that each tool's dispatch fires, and a single refresh owner.                                                                                                                                                         | Idempotent. Note its `--tools` names **AI assistants** (`claude,gemini,copilot,antigravity`) — not the same `--tools` as `register-cross-repo-graph`, which names **graph tools** (`crg,graphify`). |
| [`x442-repair-graph-hooks`](engineering/repair-graph-hooks/SKILL.md)               | Smoke-test graph-tool integrity (does `code-review-graph`/`graphify` actually run?), then re-check, validate, and repair the graph-hooks wiring and graph state (staleness, corrupt/zero-node DB, partial embeddings, owner drift, ignore-file drift, stale locks).                                                                                      | `stable`       | `AGENTS.md` + `.graph-hooks/` present (run `setup-graph-hooks` first); a git work-tree.                                                             | Reuses [`verify-graph-hooks.sh`](engineering/setup-graph-hooks/scripts/verify-graph-hooks.sh) as the wiring detector, adding tool-integrity and graph-state probes on top.                                                                                                                                                                              | Idempotent; no-op on a healthy repo. Heavy graph rebuilds are offered, never auto-run.                                                                                                              |
| [`x442-register-cross-repo-graph`](engineering/register-cross-repo-graph/SKILL.md) | Declare sibling repos in a per-project `.graph-repos.json` cascade (user → repo → subdir, nearest wins), then sync: register them for CRG `cross_repo_search`, build a per-project merged graphify graph, and rewrite the in-scope routing block in `AGENTS.md`.                                                                                         | `stable`       | Consuming repo has `AGENTS.md` and its own graph wired (run `setup-graph-hooks` first); at least one of `code-review-graph` / `graphify` installed. | [`verify-cross-repo-graph.sh`](engineering/register-cross-repo-graph/scripts/verify-cross-repo-graph.sh) — asserts the cascade parses, every in-scope repo is queryable, the registry agrees, and the `AGENTS.md` block has not drifted.                                                                                                                | CRG's registry is machine-global and shared across projects — sync only ever adds to it, so scope is enforced by the in-scope alias list in `AGENTS.md`, not by the registry.                       |
| [`x442-setup-handoff`](engineering/setup-handoff/SKILL.md)                         | Install a lease-based handoff coordination protocol (`.agents/handoff/`) so multiple agents/sessions/repos work the same code without clobbering: atomic-lock claim/release, per-tool enforcement hooks (user picks a primary), fail-safe deny, self-maintaining leases, evidence-gated `done`, safe-by-default `verify:`, and legacy-install migration. | `experimental` | `AGENTS.md` present (run `initial-project` first); a git work-tree; `python3` for a hard-enforcement primary.                                       | [`verify-setup-handoff.sh`](engineering/setup-handoff/scripts/verify-setup-handoff.sh) — asserts the payload, config/gitignore/AGENTS.md block, each wired tool's JSON, a hard-enforcement primary, the python3 preflight, and that the read-only hook paths fire (deny INDEX, allow ordinary files).                                                   | Idempotent. Single-repo default; cross-repo (audience routing) is opt-in. Fixes two defects in the reference protocol (the `session=` gate; hooks actually registered).                             |
| [`x442-run-handoff`](engineering/run-handoff/SKILL.md)                             | The claim → work → release discipline over an installed handoff board: read the board, claim before editing, file handoffs across boundaries, and release with an honest status (`done` requires `--verified-by`; `blocked` requires `--blocked-on`).                                                                                                    | `experimental` | A repo with a `.agents/handoff/` board (run `setup-handoff` first).                                                                                 | [`run-handoff-workspace`](../harness/run-handoff-workspace/grade.py) — behavioral: drives the installed `handoff` script per the discipline and asserts the produced artifacts (schema-valid archived doc + `verified_at`, released lease, regenerated `INDEX.md`, blocked/`blocked_on` state). Wraps `verify-setup-handoff.sh` for environment sanity. | Behavioral skill — no scripts of its own; it operates the board `setup-handoff` installs.                                                                                                           |

### `productivity/`

| Skill                                                                     | Purpose                                                                                                                                                                                                                                           | Status         | Requires                                                                                                  | Harness                                                                                                                                                                                                                                                                                                         | Remark                                                                                                                                                |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------- | --------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`x442-release-announcement`](productivity/release-announcement/SKILL.md) | Turn a tagged version and its changelog into a user-facing announcement shaped for its channel (GitHub release body, Slack/Teams, email), grouped by user-visible theme rather than commit type. Can emit a second language alongside the source. | `experimental` | A release already cut (version bumped, changelog written, tag created) and the compare range to describe. | [`release-announcement-workspace`](../harness/release-announcement-workspace/grade.py) — text-output: grades the produced announcement against the skill's own rules (structure, attribution, marketing, invented numbers, status stated, destructive commands). No `verify-*.sh` — the skill ships no scripts. | Writes the message, not the release. Enforces attribution (never names a non-public upstream), explicit status changes, and no overstated guarantees. |

## Authoring & conventions

Full spec in [AGENTS.md](../AGENTS.md); the essentials:

- **Frontmatter** — every `SKILL.md` opens with YAML:
  ```yaml
  ---
  name: x442-<skill-name>
  description: One sentence that tells the assistant WHEN to use this skill. Lead with "Use when…".
  ---
  ```
- **Naming** — the directory stays **unprefixed** (e.g. `initial-project/`), but the
  frontmatter `name` carries the **`x442-` prefix** (e.g. `x442-initial-project`). The prefix
  makes the installed slash-command unambiguous across environments (so a skill from this repo
  never collides with a same-named personal or built-in skill), and it shows regardless of
  install path — `npx skills add` and the Claude plugin marketplace read the frontmatter
  `name`, while the dev-loop link scripts prefix the symlink directory. The directory still
  matches the **unprefixed** part of the name.
- **One skill, one purpose** — if a skill describes two unrelated workflows, split it.
- **Link, don't duplicate** — cross-reference other skills with relative links; never copy
  their content. Keep `SKILL.md` lean; offload long detail to `references/`.
- **Scripts** — under `scripts/`, executable (`chmod +x`), with a usage comment at the top;
  prefer shell or Python for portability. Bundled payloads (templates, config) go in `assets/`.
- **Verification** — ship a read-only `verify-*.sh` checker when a skill wires a repo, so its
  effect can be confirmed without re-running the interactive flow.

See AGENTS.md for the remaining house rules: formatting (defer to
[.editorconfig](../.editorconfig)), no emojis, no destructive shell commands in examples,
cite external sources, and imperative second-person voice.
