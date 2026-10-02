---
status: accepted
date: 2026-10-02
---

# VS Code runs the Claude-format hooks when a repo wires Claude

A developer works in VS Code and uses both Claude Code and VS Code's own chat, and the repo also
serves Copilot CLI and the Copilot cloud agent. VS Code chat can read both hook formats. We decided
that when a repo wires Claude, its committed Claude-format hooks are what VS Code runs, while the
`.github/hooks/` files are kept for the Copilot agents that cannot read anything else. Each setup
skill switches off its own Copilot file in VS Code only when the Claude-format file it committed
already covers every hook kind in that Copilot file.

## Context

- VS Code chat always reads `.github/hooks/*.json`. It also reads `.claude/settings.json`,
  `.claude/settings.local.json` and `~/.claude/settings.json`, but only while `chat.useClaudeHooks`
  is on, and that setting is off by default. It ignores `matcher` in Claude-format files, so every
  command for an event fires on every tool call. It does not set `CLAUDE_PROJECT_DIR`.
  `chat.hookFilesLocations` can switch off a single file. [VS Code hooks][vscode]
- Copilot CLI reads `.github/hooks/*.json` **and** `.claude/settings*.json`, and runs every hook it
  finds. The Copilot cloud agent reads `.github/hooks/*.json` only. [Copilot hooks reference][gh]
- Copilot code review runs no hooks. It reads `AGENTS.md`, `CLAUDE.md`,
  `.github/copilot-instructions.md` and `*.instructions.md`, plus repository skills and MCP
  servers. [Copilot code review][review]
- Claude Code's PreToolUse `permissionDecision` takes `allow`, `deny`, `ask` or `defer`. `block` is
  the old top-level spelling and is not accepted there. [Claude Code hooks][claude]
- setup-graph-hooks used to put Claude's graph hooks in the gitignored `settings.local.json`, so
  that each teammate opted in. Copilot's `graph.json` was committed. Switching `.github/hooks` off
  in a committed `.vscode/settings.json` therefore removed the graph hooks from VS Code for every
  teammate who had never run the installer.
- "Is Claude Code installed?" cannot be answered from VS Code settings. What the installer can
  know is whether the repo wires Claude, and a Claude-format hook is a plain shell command that
  runs without Claude Code.

## Decision

- **The Claude-format file is committed.** setup-graph-hooks writes Claude's graph hooks to
  `.claude/settings.json`, where setup-handoff already writes its hooks. It also removes its own
  groups from `.claude/settings.local.json` and `.claude/settings.example.json`, because VS Code
  would otherwise run them twice.
- **Claude-format commands do not depend on `CLAUDE_PROJECT_DIR`.** They fall back to the git root,
  then to `$PWD`, which is the form graph hooks already used.
- **The switch belongs to the repo.** An installer that commits Claude-format hooks sets
  `chat.useClaudeHooks: true` in `.vscode/settings.json`. It also sets its own Copilot file to
  `false` in `chat.hookFilesLocations`, but only when the Claude-format file covers every hook kind
  the Copilot file has. That holds unless Copilot is the primary tool, the one that gets the hard
  enforcement and end-of-turn hooks. When Copilot is the primary, the Copilot file stays on.
  Each skill touches only its own key, so neither skill can switch off the other's hooks.
- **`--local-wiring` leaves `.vscode/` alone.** It promises that nothing tracked changes, so the
  installer prints the two settings for the developer to set in their own user settings.
- **A JSONC `.vscode/settings.json` is not rewritten.** Rewriting it would drop the comments, so
  the installer prints the settings to add by hand and the verifier warns until they are present.
- **Copilot CLI's double run is accepted.** A deny that fires twice still denies. The cost is
  session context and post-edit notes injected twice. The end-of-turn refresh already runs once,
  because only the primary tool wires it. A guard that skips the Copilot file outside the cloud
  agent was rejected: if VS Code were switched back to `.github/hooks`, enforcement would disappear
  and nothing would report it.
- **Code review is served by instructions, not hooks.** The `AGENTS.md` routing blocks already
  reach it. Installing graph tools into the review sandbox through `copilot-setup-steps.yml` is a
  separate piece of work.
- **The grep gate's deny is spelled `deny` for Claude.** Spelled `block`, the gate never blocked.
- **Hooks judge the tool themselves.** VS Code ignores `matcher`, so the handoff edit gate sees
  every tool call. It waves through a tool whose name says it only reads, and a payload that names
  no file, such as a terminal command. It keeps gating every other tool, including one it does not
  recognize. Missing a write tool would switch enforcement off without anyone seeing it, while
  missing a read tool only refuses a call that should have passed.

## Consequences

- Teammates get the same graph and handoff hooks in VS Code whether or not they ran an installer
  or have Claude Code installed.
- Turning on `chat.useClaudeHooks` also makes VS Code run each developer's `~/.claude/settings.json`
  hooks, with their matchers ignored. Whether that is wanted is each developer's call, and
  `"~/.claude/settings.json": false` in their user settings turns it off. Installers never set that
  key, because a committed value would switch it off for the whole team.
- Graph hooks become opt-out for Claude Code users, as they already were for Copilot. They do
  nothing when code-review-graph is not installed or no graph exists.
- The verifiers fail when a Copilot file is switched off but the committed Claude-format file does
  not cover it, since that combination silently removes hooks for teammates.

[vscode]: https://code.visualstudio.com/docs/copilot/customization/hooks
[gh]: https://docs.github.com/en/copilot/reference/hooks-reference
[review]: https://docs.github.com/en/copilot/how-tos/use-copilot-agents/request-a-code-review/use-code-review
[claude]: https://code.claude.com/docs/en/hooks
