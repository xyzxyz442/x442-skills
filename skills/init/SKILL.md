---
name: init
description: Use when initializing or setting up a project's AI assistant configuration ("init this project", "set up Claude here") — installs a project-local SessionStart hook that auto-applies the Karpathy coding guidelines every session.
---

# init

Initialize a project's AI assistant configuration. This skill is a container for
project setup steps. It currently implements exactly one step: install a project-local
Claude Code `SessionStart` hook that injects the Karpathy coding guidelines into every
session of the target project.

The guidelines text is copied into the project, so the hook is self-contained — it keeps
working even if the upstream `andrej-karpathy-skills` plugin is never installed.

## When to use

Use when the user asks to initialize, bootstrap, or set up AI/Claude configuration for a
project, or specifically asks to make the Karpathy coding guidelines apply automatically.
Run from the target project's root.

## Steps

Run these in order. Future setup steps will be added as additional numbered steps.

1. **Find the target root.** Use the user's current working directory, or its enclosing
   git root if one exists. Every file below is written under `<root>/.claude/`.
2. **Copy the guidelines into the project.** Write
   [references/karpathy-guidelines.md](references/karpathy-guidelines.md) verbatim to
   `<root>/.claude/karpathy-guidelines.md`. Do not alter the text or its source citation.
3. **Install the SessionStart hook.** Merge the hook from
   [references/settings-snippet.json](references/settings-snippet.json) into
   `<root>/.claude/settings.json` using the merge-safe procedure below.

The installed hook command is:

```
cat "$CLAUDE_PROJECT_DIR/.claude/karpathy-guidelines.md"
```

`$CLAUDE_PROJECT_DIR` is the Claude Code-provided project root, so the hook is
cwd-independent. For `SessionStart`, the command's plain stdout is injected into the
session as model-visible context — no JSON wrapper and no `jq` are required.
(Source: [Claude Code hooks docs](https://code.claude.com/docs/en/hooks).)
`matcher: ""` fires on startup, resume, clear, and compact.

## Merge-safe settings.json procedure

Let `CMD` be the hook command string above.

1. If `<root>/.claude/settings.json` does not exist, create the `.claude/` directory and
   write a new settings.json containing only the snippet from
   [references/settings-snippet.json](references/settings-snippet.json).
2. If it exists, read and parse it as JSON (round-trip — never splice with `sed`):
   - **Idempotency guard:** if any existing `hooks.SessionStart[].hooks[].command` equals
     `CMD`, stop. The hook is already installed; make no change.
   - If `hooks` is absent, add it. If `hooks.SessionStart` is absent, add it as `[]`.
   - **Append** the new entry to `hooks.SessionStart`. Never overwrite the array — preserve
     every existing entry (for example, a `code-review-graph status` hook).
   - Leave all other top-level keys (`permissions`, `model`, …) untouched.
3. Write back with 2-space indentation, LF line endings, and a final newline (per
   [.editorconfig](../../.editorconfig)).

Write to `.claude/settings.json` (the committed, team-shared file), not
`.claude/settings.local.json` (personal, gitignored), so the guidelines apply for everyone
working in the project.

## Verification

1. **Static:** confirm `<root>/.claude/karpathy-guidelines.md` exists, and that settings.json
   contains exactly one SessionStart hook whose command equals `CMD` (count is 1, not more).
2. **Dry-run:** print the file the hook reads to confirm it emits the guidelines:

   ```
   CLAUDE_PROJECT_DIR="<root>" cat "$CLAUDE_PROJECT_DIR/.claude/karpathy-guidelines.md"
   ```

3. **End-to-end:** start a fresh Claude Code session in `<root>`. The hook only runs on the
   next session start, not retroactively. In the new session, the guidelines should be in
   context (verify by asking the model to restate the four guidelines unprompted).
4. **Idempotency:** re-running this skill is a no-op — the guard keeps the command count at
   one, and re-copying the guidelines file overwrites it with identical content.

## Example

User: "init this project."

1. Resolve the root to the current git repo.
2. Write `.claude/karpathy-guidelines.md` from the bundled reference.
3. Merge the hook. If settings.json already had an unrelated SessionStart hook, the result
   preserves both:

   ```json
   {
     "hooks": {
       "SessionStart": [
         { "matcher": "", "hooks": [{ "type": "command", "command": "existing-hook" }] },
         { "matcher": "", "hooks": [{ "type": "command", "command": "cat \"$CLAUDE_PROJECT_DIR/.claude/karpathy-guidelines.md\"" }] }
       ]
     }
   }
   ```

4. Report what changed and run the verification steps. If you ever need to undo, remove the
   appended hook entry and `trash` the guidelines file — never `rm -rf`.
