---
name: setup-graph-hooks
description: >-
  Use immediately after initial-project on a new repo, or whenever the user mentions a code
  knowledge graph, graph hooks, code-review-graph, graphify, smart-grep, or blast-radius/impact
  analysis — anything about agents querying a graph instead of grepping/re-reading files. Wires
  self-updating graph hooks (Claude Code + a git post-commit refresh) and a routing block in
  AGENTS.md, then verifies they fire. Idempotent and safe on any repo, with or without the tools
  installed.
---

# setup-graph-hooks

Sets up the self-updating knowledge-graph layer, and registers the routing rules in `AGENTS.md`
so both Claude Code and Copilot prefer graph queries over grep. Runs as the second step of repo
onboarding, right after `initial-project` has created the canonical `AGENTS.md`.

Everything here is idempotent and degrades gracefully: every hook silently no-ops when a tool
or graph is absent, so it is safe to run on any repo, with or without the tools installed yet.

## Preconditions

1. **`AGENTS.md` exists at the repo root.** This skill chains after `initial-project`. If
   `AGENTS.md` is missing, stop and tell the user to run `initial-project` first — do not
   create `AGENTS.md` here.
2. The repo is a git working tree.

If either fails, report it and stop. Do not partially apply.

## What this skill installs

Repo-local (committed, travels with the repo):
- `.claude/settings.example.json` — the merged hook config (PostToolUse empty; Stop = CRG
  update+embed once per turn, PID-guarded; PreToolUse = smart-grep interceptor + Read/Glob
  nudge; SessionStart = status + setup-nudge + cheatsheet). Every hook command is a stable thin
  wrapper that resolves its script repo-first then home (see Notes).
- `.claude/scripts/` — the six hook scripts: `smart-grep-hook.sh`, `graph-cheatsheet.py`,
  `stop-graph-update.sh`, `read-glob-nudge.sh`, `session-status.sh`, `session-setup-nudge.sh`.
- `.git/hooks/post-commit` (or `.husky/post-commit` for husky repos) — background, resource-
  guarded graph refresh. `graphify` lives here, never in a Claude hook (too slow per-turn).
- `.code-review-graphignore` and `.graphifyignore` — repo-root ignore files (seeded from the
  shared `scripts/graphignore` template) that keep generated, vendored, lockfile, and secret
  noise out of both graphs. Seeded only when absent; a hand-tuned existing file is left untouched.

Local/runtime (gitignored):
- `.claude/settings.local.json` — the active copy of the hooks.

Canonical context:
- A `<!-- graph-hooks -->` routing block appended to `AGENTS.md` (see `assets/agents-knowledge-graph.md`).

## Procedure

Run from the skill directory. `$SKILL_DIR` is this skill's folder; `$REPO` is the target repo root.

### 1. Resolve the repo root
```bash
REPO="$(git rev-parse --show-toplevel)"
```

### 2. Wire the files
```bash
bash "$SKILL_DIR/scripts/setup-graph-hooks.sh" "$REPO"
```
This copies the scripts, installs `settings.example.json`, activates `settings.local.json`
(without clobbering an existing one), installs the husky-aware `post-commit`, patches
`.gitignore`, and seeds `.code-review-graphignore` / `.graphifyignore` (when absent).
Re-running never duplicates.

### 3. Inject the AGENTS.md routing block (idempotent)
Append the canonical block only if its marker is not already present. This is what makes both
agents prefer the graph — Claude Code via its hooks, Copilot via `AGENTS.md`. Because
`CLAUDE.md` and the Copilot bridge already `@AGENTS.md`, no per-agent edit is needed.
```bash
if ! grep -q 'graph-hooks:begin' "$REPO/AGENTS.md" 2>/dev/null; then
  printf '\n' >> "$REPO/AGENTS.md"
  cat "$SKILL_DIR/assets/agents-knowledge-graph.md" >> "$REPO/AGENTS.md"
fi
```

### 4. Verify it fires
```bash
bash "$SKILL_DIR/scripts/verify-graph-hooks.sh" "$REPO"
```
Healthy result is **0 failed** (warnings are fine — they just mean a tool/graph isn't built
yet). The verifier runs each configured hook with the same stdin Claude Code uses and checks
exit codes and JSON validity, so a pass means the hooks actually run, not just that the config
looks right. If anything reports `[FAIL]`, surface it and stop.

### 5. Build the graph (only if a tool is installed)
The verifier prints whether `code-review-graph` / `graphify` are installed. Do not auto-run
heavy builds. Offer the one-time commands and run them only if the user agrees:
```bash
# CRG (recommended): MCP tools + semantic search
code-review-graph install && code-review-graph build && code-review-graph embed
# graphify (optional): CLI exploration + git-hook freshness
graphify init . && graphify update . && graphify hook install
```
If neither is installed, tell the user the hooks are wired and dormant, and give the install
commands: `pipx install code-review-graph` and `pipx install graphifyy` (note the double `y` —
the PyPI package is `graphifyy`, but the command it installs is `graphify`).

### 6. Report
Summarize: files wired, AGENTS.md updated (yes/no), verifier summary line, and the exact next
command the user still needs to run (install a tool and/or build the graph). Keep it short.

## Notes
- **Claude Code vs Copilot:** Claude Code gets the full hook automation. Copilot has no
  equivalent hook layer, so for Copilot the value is the `AGENTS.md` routing block plus the
  agent-agnostic git `post-commit` freshness. Both are installed regardless of agent.
- **Scope:** default is per-repo (committed `settings.example.json`, active `settings.local.json`).
  For a developer who wants it everywhere, the same files also work at `~/.claude/settings.json`
  and `~/.claude/scripts/`; the hooks resolve the repo copy first, then the home copy.
- **Priority + no double-firing:** Claude Code merges hooks across user, project, and local scopes
  and runs them all — but it de-duplicates identical handlers: *"identical handlers are
  deduplicated automatically. Command hooks are deduplicated by command string and `args`"*
  ([hooks doc](https://code.claude.com/docs/en/hooks.md)). That is why every hook command here is a
  byte-identical thin wrapper with all logic in a script: a home install and a repo install register
  the *same* command string, so Claude Code collapses them to a **single** fire, and the wrapper's
  repo-first resolution makes that single fire run the **repo** copy. Keep the wrappers identical
  across versions — putting logic inline (instead of in a script) would make the command strings
  diverge and reintroduce double-firing.
- **Bundled files:** `scripts/` holds the installer (`setup-graph-hooks.sh`), verifier
  (`verify-graph-hooks.sh`), the six hook scripts (`smart-grep-hook.sh`, `graph-cheatsheet.py`,
  `stop-graph-update.sh`, `read-glob-nudge.sh`, `session-status.sh`, `session-setup-nudge.sh`), the
  git `post-commit` source, the `graphignore` template (seeds `.code-review-graphignore` and
  `.graphifyignore`), and `settings.example.json` — all kept beside the installer because it
  resolves its payload from its own directory. `assets/agents-knowledge-graph.md` is the canonical
  AGENTS.md block.
