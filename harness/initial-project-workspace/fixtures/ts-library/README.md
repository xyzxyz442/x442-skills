# @acme/toolkit-example

Example TypeScript library, already fully wired for AI assistants: `AGENTS.md` (source of
truth), `CLAUDE.md` + `GEMINI.md` (each importing `@AGENTS.md`), and `.vscode/settings.json`
(Copilot root auto-load).

This is the **idempotency** eval fixture for the `initial-project` skill — see
[../../../../docs/harness-structure.md](../../../../docs/harness-structure.md). Re-running the
skill against a copy must produce an empty diff.
