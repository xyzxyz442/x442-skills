---
name: initial-project
description: Use when initializing or setting up a project's AI assistant configuration ("init this project", "set up Claude/Copilot here") — puts shared coding guidelines in AGENTS.md, detects the AI tools in use, and wires each chosen tool to load it.
---

# initial-project

Initialize a project's AI assistant configuration around a single shared `AGENTS.md`.

Common, cross-tool context — including the Karpathy coding guidelines — lives in `AGENTS.md`,
the source of truth every tool loads. Each tool's own file holds only its special overrides
plus an import of `AGENTS.md`; the shared guidelines are never copied into a tool file.

This skill puts the shared guidelines in `AGENTS.md`, detects which AI coding tools the
project uses, asks which ones to set up, and wires each chosen tool to load `AGENTS.md`.

## When to use

Use when the user asks to initialize, bootstrap, or set up AI/assistant configuration for a
project, or specifically to make the Karpathy coding guidelines apply automatically. Run from
the target project's root.

## Shared vs special

- **Shared, cross-tool context → `AGENTS.md`.** Read by every tool. The Karpathy coding
  guidelines go here, once.
- **Tool-specific overrides → that tool's file.** Each tool file imports `AGENTS.md` and adds
  only what is unique to that tool. Never duplicate the shared guidelines into a tool file.

## Supported tools

| Tool | Detect marker(s) | Entry file | Loads AGENTS.md via |
| --- | --- | --- | --- |
| Claude Code | `.claude/`, `CLAUDE.md` | `CLAUDE.md` | `@AGENTS.md` import |
| Antigravity | `ANTIGRAVITY.md`, `.antigravity/` | `ANTIGRAVITY.md` | `@AGENTS.md` import |
| Gemini CLI | `GEMINI.md`, `.gemini/` | `GEMINI.md` | `@AGENTS.md` import |
| GitHub Copilot | `.github/copilot-instructions.md`, `.github/` | `.github/copilot-instructions.md` | prose link + `.vscode/settings.json` → `chat.agentFilesLocations` |

## Steps

Run these in order from the target project root.

1. **Ensure the shared guidelines in `AGENTS.md`.** If `AGENTS.md` is missing, create it with a
   top-level heading. Ensure it contains a `## Coding guidelines` section holding the text of
   [references/karpathy-guidelines.md](references/karpathy-guidelines.md) (adjust heading levels
   to fit the document). Keep the source citation link intact. **Idempotency guard:** if a
   section already carries the Karpathy guidelines, leave it.
2. **Detect.** Check each tool's marker(s) from the table. Record which tools are present.
   Detection is best-effort and only drives the pre-selection in the next step.
3. **Prompt the user to choose.** Present all four supported tools and let the user pick any
   subset (multi-select), pre-selecting the detected tools. In Claude Code, use the
   `AskUserQuestion` tool with `multiSelect: true`. Do nothing for tools the user does not pick.
4. **Wire each chosen tool** to load `AGENTS.md` (idempotent — skip a tool already wired):
   - **Claude Code / Antigravity / Gemini CLI** → ensure the entry file exists and carries an
     `@AGENTS.md` import line near the top. Create the file (heading + `@AGENTS.md`) if absent;
     if it exists without the import, add it. Leave any existing tool-specific content alone.
   - **GitHub Copilot** → ensure `.github/copilot-instructions.md` exists and points readers to
     `AGENTS.md`, and ensure `.vscode/settings.json` lists the project root in
     `chat.agentFilesLocations` (`".": true`) using the merge-safe procedure below.
5. **Offer graph-hooks setup.** Once wiring and verification pass, `AGENTS.md` exists — the
   precondition for [`setup-graph-hooks`](../setup-graph-hooks/SKILL.md), which wires a
   self-updating code knowledge graph so agents query the graph instead of grepping. Ask the user
   whether to run it now (in Claude Code, use `AskUserQuestion` with `multiSelect: false`, yes/no).
   On yes, invoke `setup-graph-hooks`. On no, name it as the recommended next step in your report.

## Merge-safe `.vscode/settings.json` (Copilot)

1. If the file is absent, create it with `{ "chat.agentFilesLocations": { ".": true } }`.
2. If present, parse as JSON (round-trip — never splice with `sed`). Add or update
   `chat.agentFilesLocations` to include `".": true`; preserve all other keys.
3. Write back with 2-space indentation, LF line endings, and a final newline.

## Verification

1. **Shared:** `AGENTS.md` exists and has a `## Coding guidelines` section citing the Karpathy
   guidelines.
2. **Per chosen tool:** the entry file loads `AGENTS.md` — Claude/Antigravity/Gemini contain an
   `@AGENTS.md` line; Copilot's file references `AGENTS.md` and `.vscode/settings.json` lists the
   root in `chat.agentFilesLocations`.
3. **No duplication:** the guidelines text appears only in `AGENTS.md`, not copied into any tool
   file.
4. **End-to-end:** start a fresh session in a wired tool; `AGENTS.md` (and its guidelines) is in
   context.
5. **Idempotency:** re-running this skill is a no-op for every already-wired tool.

## Example

User: "init this project."

1. Ensure `AGENTS.md` has the `## Coding guidelines` section (create the file, or append the
   section if missing).
2. Detect finds `.claude/` and `.github/`; Antigravity and Gemini are absent.
3. Ask which tools to wire, pre-selecting Claude Code and GitHub Copilot. User confirms both.
4. Ensure `CLAUDE.md` imports `@AGENTS.md`; ensure `.github/copilot-instructions.md` points to
   `AGENTS.md` and `.vscode/settings.json` lists the root in `chat.agentFilesLocations`.
5. Report what changed and run the verification steps. To undo, remove the added lines and
   `trash` any file you created — never `rm -rf`.
6. Ask whether to set up graph hooks now; on yes, hand off to `setup-graph-hooks`.
