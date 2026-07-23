---
name: x442-initial-project
description: Use when initializing or setting up a project's AI assistant configuration ("init this project", "set up Claude/Copilot here") — puts shared coding guidelines in AGENTS.md, detects the AI tools in use, and wires each chosen tool to load it.
---

# initial-project

Initialize a project's AI assistant configuration around a single shared `AGENTS.md`.

Common, cross-tool context — including the Karpathy coding guidelines and the commit
conventions — lives in `AGENTS.md`, the source of truth every tool loads. Each tool's own file
holds only its special overrides and
loads `AGENTS.md` by that tool's own mechanism (import, native read, or settings — see the table);
the shared guidelines are never copied into a tool file.

This skill puts the shared guidelines in `AGENTS.md`, detects which AI coding tools the
project uses, asks which ones to set up, and wires each chosen tool to load `AGENTS.md`.

## When to use

Use when the user asks to initialize, bootstrap, or set up AI/assistant configuration for a
project, or specifically to make the Karpathy coding guidelines apply automatically. Run from
the target project's root.

## Prerequisites & platform support

The skill's own steps are agent-driven — the assistant edits files with its own tools, so the
host needs little beyond a shell at the project root. The dependencies below are for the bundled
verifier and the JSON-safe Copilot merge.

- **Runtime:** `bash`, `git` (soft — the verifier falls back to `$PWD` when the path is not a git
  repo), `grep`, and `python3` (hard — used to parse and validate `.vscode/settings.json` for the
  Copilot check). No `node`, `npm`, or `jq`.
- **Platform:** macOS and Linux are first-class. **Windows is supported via WSL only** — the
  verifier is bash + `python3` with no PowerShell/cmd path. On bare Windows Python, ensure a
  `python3` alias exists (Windows often ships `python` only).
- **Line endings:** the Copilot `.vscode/settings.json` merge always writes LF + a final newline,
  so it stays CRLF-safe by construction.
- **Undo guidance uses `trash`**, which is macOS/Homebrew-oriented. On Linux, substitute
  `trash-cli` (`trash-put`) or `gio trash`. Never `rm -rf`.

## Shared vs special

- **Shared, cross-tool context → `AGENTS.md`.** Read by every tool. The Karpathy coding
  guidelines and the commit conventions go here, once.
- **Tool-specific overrides → that tool's file.** Each tool file loads `AGENTS.md` (by import,
  native read, or settings, per the table) and adds only what is unique to that tool. Never
  duplicate the shared guidelines into a tool file.

## Supported tools

| Tool           | Detect marker(s)                              | Entry file                        | Loads AGENTS.md via                                                                                |
| -------------- | --------------------------------------------- | --------------------------------- | -------------------------------------------------------------------------------------------------- |
| Claude Code    | `.claude/`, `CLAUDE.md`                       | `CLAUDE.md`                       | [`@AGENTS.md` import](https://docs.claude.com/en/docs/claude-code/memory)                          |
| Antigravity    | `ANTIGRAVITY.md`, `.antigravity/`             | `ANTIGRAVITY.md` (overrides only) | [reads `AGENTS.md` natively](https://antigravity.google/docs/home) (v1.20.3+) — no import line     |
| Gemini CLI     | `GEMINI.md`, `.gemini/`                       | `GEMINI.md`                       | [`@AGENTS.md` import](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/gemini-md.md) |
| GitHub Copilot | `.github/copilot-instructions.md`, `.github/` | `.github/copilot-instructions.md` | prose link to `../AGENTS.md` + `.vscode/settings.json` → `chat.agentFilesLocations`                |

## Steps

Run these in order from the target project root.

1. **Ensure the shared guidelines in `AGENTS.md`.** If `AGENTS.md` is missing, create it with a
   top-level heading. Ensure it contains a `## Coding guidelines` section holding the text of
   [references/karpathy-guidelines.md](references/karpathy-guidelines.md) (adjust heading levels
   to fit the document). Keep the source citation link intact. **Idempotency guard:** if a
   section already carries the Karpathy guidelines, leave it.
2. **Ensure the commit conventions in `AGENTS.md`.** Ensure it contains a `## Commit conventions`
   section carrying (or linking) [references/commit-guidelines.md](references/commit-guidelines.md):
   Conventional Commits `type(scope): subject`, with `commitlint.config.mjs` named as the enforced
   source of truth. This is the always-on guidance for _writing_ commits; the actual commitlint +
   husky enforcement (local-only — no CI workflow ships) is installed separately by
   [`setup-project-tooling`](../setup-project-tooling/SKILL.md).
   **Idempotency guard:** if a `## Commit conventions` section already exists, leave it.
3. **Detect.** Check each tool's marker(s) from the table. Record which tools are present.
   Detection is best-effort and only drives the pre-selection in the next step.
4. **Prompt the user to choose.** Present all four supported tools and let the user pick any
   subset (multi-select), pre-selecting the detected tools. In Claude Code, use the
   `AskUserQuestion` tool with `multiSelect: true`. Do nothing for tools the user does not pick.
5. **Wire each chosen tool** to load `AGENTS.md` (idempotent — skip a tool already wired):
   - **Claude Code / Gemini CLI** → ensure the entry file exists and carries an `@AGENTS.md`
     import line near the top (both honor `@path` Markdown imports — see the table's citations).
     Create the file (heading + `@AGENTS.md`) if absent; if it exists without the import, add it.
     Leave any existing tool-specific content alone.
   - **Antigravity** → Antigravity reads `AGENTS.md` natively at session start (v1.20.3+), so no
     import line is needed. Create `ANTIGRAVITY.md` only as a home for Antigravity-specific
     overrides; do not rely on an `@AGENTS.md` line to load the shared rules.
   - **GitHub Copilot** → ensure `.github/copilot-instructions.md` exists and points readers to
     `../AGENTS.md` (the file lives in `.github/`, so the relative link is `../AGENTS.md`), and
     ensure `.vscode/settings.json` lists the project root in `chat.agentFilesLocations`
     (`".": true`) using the merge-safe procedure below.
6. **Recheck and run the setup chain.** `AGENTS.md` now exists — the shared precondition for the
   three setup skills that chain after this one. Walk them **in the order below**, treating this
   run like a fresh project: for each, recheck its "already-wired" marker _now_ (do not assume a
   prior run's state). If the marker is present, report it and move on — no prompt. If it is
   absent, offer to run it (in Claude Code, `AskUserQuestion`, `multiSelect: false`, yes/no,
   default **yes**); on yes, invoke the skill and let its own verifier run; on no, name it as a
   recommended next step. Each chained skill is itself idempotent, so this is safe to repeat.

   | Order | Skill                                                        | Already-wired marker (recheck → skip if present)                    | What running it wires                                    |
   | ----- | ------------------------------------------------------------ | ------------------------------------------------------------------- | -------------------------------------------------------- |
   | 1     | [`setup-project-tooling`](../setup-project-tooling/SKILL.md) | `commitlint.config.mjs` or `.husky/` present                        | commit enforcement, staged lint/format, editor + release |
   | 2     | [`setup-graph-hooks`](../setup-graph-hooks/SKILL.md)         | `<!-- graph-hooks:begin -->` in `AGENTS.md` **and** `.graph-hooks/` | self-updating code knowledge graph + routing             |
   | 3     | [`setup-handoff`](../setup-handoff/SKILL.md)                 | `<!-- handoff` block in `AGENTS.md` **and** `.agents/handoff/`      | lease-based cross-session/-repo handoff board            |

   Skill 1 installs the `commitlint.config.mjs` behind the commit conventions seeded in step 2.
   Skills chained _downstream_ of these are named as next steps, not walked here:
   [`register-cross-repo-graph`](../register-cross-repo-graph/SKILL.md) and
   [`repair-graph-hooks`](../repair-graph-hooks/SKILL.md) after graph-hooks;
   [`run-handoff`](../run-handoff/SKILL.md) after handoff.

## Merge-safe `.vscode/settings.json` (Copilot)

1. If the file is absent, create it with `{ "chat.agentFilesLocations": { ".": true } }`.
2. If present, parse as JSON (round-trip — never splice with `sed`). Add or update
   `chat.agentFilesLocations` to include `".": true`; preserve all other keys.
3. Write back with 2-space indentation, LF line endings, and a final newline.

## Verification

Run the bundled checker for a fast pass/fail over the post-conditions below:
[`scripts/verify-initial-project.sh`](scripts/verify-initial-project.sh) — `bash
scripts/verify-initial-project.sh [repo-root]` (read-only; defaults to the current repo; exits
non-zero on any failure). Then spot-check by hand:

1. **Shared:** `AGENTS.md` exists and has a `## Coding guidelines` section citing the Karpathy
   guidelines and a `## Commit conventions` section citing `commit-guidelines.md` /
   `commitlint.config.mjs`.
2. **Per chosen tool:** the entry file loads `AGENTS.md` — Claude/Gemini contain an `@AGENTS.md`
   line; Antigravity reads `AGENTS.md` natively (no line required); Copilot's file references
   `../AGENTS.md` and `.vscode/settings.json` lists the root in `chat.agentFilesLocations`.
3. **No duplication:** the guidelines text appears only in `AGENTS.md`, not copied into any tool
   file.
4. **End-to-end:** start a fresh session in a wired tool; `AGENTS.md` (and its guidelines) is in
   context.
5. **Idempotency:** re-running this skill is a no-op for every already-wired tool.

## Example

User: "init this project."

1. Ensure `AGENTS.md` has the `## Coding guidelines` and `## Commit conventions` sections
   (create the file, or append the sections if missing).
2. Detect finds `.claude/` and `.github/`; Antigravity and Gemini are absent.
3. Ask which tools to wire, pre-selecting Claude Code and GitHub Copilot. User confirms both.
4. Ensure `CLAUDE.md` imports `@AGENTS.md`; ensure `.github/copilot-instructions.md` points to
   `../AGENTS.md` and `.vscode/settings.json` lists the root in `chat.agentFilesLocations`.
5. Report what changed and run the verification steps. To undo, remove the added lines and
   `trash` any file you created — never `rm -rf`.
6. Recheck the chain in order. `commitlint.config.mjs` is absent → ask, on yes hand off to
   `setup-project-tooling`. No `<!-- graph-hooks:begin -->` in `AGENTS.md` → ask, hand off to
   `setup-graph-hooks`. No `.agents/handoff/` → ask, hand off to `setup-handoff`. Any skill whose
   marker is already present is reported and skipped, not re-prompted.
