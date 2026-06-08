---
name: setup-graph-hooks
description: >-
  Use immediately after initial-project on a new repo, or whenever the user mentions a code
  knowledge graph, graph hooks, code-review-graph, graphify, smart-grep, or blast-radius/impact
  analysis — anything about agents querying a graph instead of grepping/re-reading files. Wires
  self-updating, tool-generic graph hooks (Claude Code, Gemini CLI, GitHub Copilot, plus a git
  post-commit refresh) and a routing block in AGENTS.md, then verifies they fire. Idempotent and
  safe on any repo, with or without the tools installed.
---

# setup-graph-hooks

Sets up the self-updating knowledge-graph layer for **every AI tool the repo uses**, and
registers the routing rules in `AGENTS.md` so each agent prefers graph queries over grep.
Runs as the second step of repo onboarding, right after `initial-project` has created the
canonical `AGENTS.md`.

Everything here is idempotent and degrades gracefully: every hook silently no-ops when a tool
or graph is absent, so it is safe on any repo, with or without the tools installed yet.

## Architecture: three layers

1. **Universal (tool-agnostic, always installed).** A git `post-commit` graph refresh, the
   `.code-review-graphignore` / `.graphifyignore` files, `.gitignore` entries, and the
   `<!-- graph-hooks -->` routing block appended to `AGENTS.md`. Because every tool's entry
   file `@AGENTS.md`-imports (set up by `initial-project`), the routing block reaches all
   tools with no per-tool edit.
2. **Shared behavior cores (one source of truth).** The four behaviors live once, protocol-free,
   under `.graph-hooks/core/`: `grep-steer.sh` (steer grep/find to the graph), `read-nudge.sh`
   (prefer graph tools over reading source), `session-context.sh` (inject a query cheatsheet),
   and `graph-refresh.sh` (the heavy `update+embed`, repo-global-locked). A single
   `.graph-hooks/hook.sh --tool <t> --kind <k>` dispatcher runs them; `core/extract.py` and
   `core/emit.py` hold the entire per-tool stdin/stdout protocol table.
3. **Per-tool hook config.** For each chosen tool, `config/render.py` emits that tool's native
   hook config and the installer merges it in (replacing only the hooks subtree, never
   clobbering user keys). Only the **primary** tool gets the end-of-turn refresh.

### Per-tool support

| Tool | Config file | Pre-tool event | Session event | End-of-turn | Deny shape |
| --- | --- | --- | --- | --- | --- |
| Claude Code | `.claude/settings*.json` | `PreToolUse` (matcher) | `SessionStart` | `Stop` | `permissionDecision:"block"` |
| Gemini CLI | `.gemini/settings.json` | `BeforeTool` (regex) | `SessionStart` | `AfterAgent` | `decision:"deny"` |
| GitHub Copilot | `.github/hooks/graph.json` | `preToolUse` | `sessionStart` | `agentStop` | `permissionDecision:"deny"` |
| Antigravity | `.agents/hooks.json` | `PreToolUse` *(unverified)* | — | — | *(unverified)* |

Sources: [Claude Code hooks](https://code.claude.com/docs/en/hooks.md),
[Gemini CLI hooks reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/reference.md),
[GitHub Copilot hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference),
[Antigravity hooks](https://antigravity.google/docs/hooks).

**Antigravity is gated.** Its hook contract is not yet confirmable from public docs, so the
installer writes an inert `.agents/hooks.json.example` and never activates it. Antigravity still
gets the full universal layer (git refresh + AGENTS.md routing). To activate later, verify the
contract against a live install, then rename the example to `.agents/hooks.json`.

## Preconditions

1. **`AGENTS.md` exists at the repo root.** This skill chains after `initial-project`. If it is
   missing, stop and tell the user to run `initial-project` first — do not create it here.
2. The repo is a git working tree.

If either fails, report it and stop. Do not partially apply.

## Procedure

`$SKILL_DIR` is this skill's folder; `$REPO` is the target repo root.

### 1. Resolve the repo root

```bash
REPO="$(git rev-parse --show-toplevel)"
```

### 2. Detect which tools the repo uses, and ask which to wire

Mirror `initial-project`. Detect by marker — Claude (`.claude/`, `CLAUDE.md`), Gemini
(`.gemini/`, `GEMINI.md`), Copilot (`.github/copilot-instructions.md`), Antigravity
(`ANTIGRAVITY.md`, `.antigravity/`, `.agents/`). Present all four with `AskUserQuestion`
(`multiSelect: true`), pre-selecting the detected ones. The universal layer installs regardless
of the choice.

### 3. Pick the primary refresh owner

If more than one tool is chosen, ask (`AskUserQuestion`, single-select) which **one** tool owns
the per-turn graph refresh — the heavy `code-review-graph update+embed`. Pre-select the
most-used / first-detected tool, and include a *"None — refresh only on git commit"* option.
Only that tool gets the end-of-turn hook; the rest get the cheap read-side hooks. This is what
keeps N wired tools from triggering N graph builds. (`graphify` is not part of this choice — it
runs single-owner from the git `post-commit` hook.)

### 4. Wire the files

```bash
bash "$SKILL_DIR/scripts/setup-graph-hooks.sh" "$REPO" \
  --tools <comma-list-of-chosen-tools> --primary <chosen-primary-or-none>
```

This installs the universal layer + `.graph-hooks/` cores, then renders and merges each chosen
tool's native hook config. Re-running with a different `--primary` moves ownership idempotently
(drops the old owner's end-of-turn hook) without disturbing the read-side hooks.

### 5. Inject the AGENTS.md routing block (idempotent)

```bash
if ! grep -q 'graph-hooks:begin' "$REPO/AGENTS.md" 2>/dev/null; then
  printf '\n' >> "$REPO/AGENTS.md"
  cat "$SKILL_DIR/assets/agents-knowledge-graph.md" >> "$REPO/AGENTS.md"
fi
```

### 6. Verify it fires

```bash
bash "$SKILL_DIR/scripts/verify-graph-hooks.sh" "$REPO"
```

Healthy result is **0 failed** (warnings just mean a tool/graph isn't built yet). The verifier
discovers the wired tools, fires the shared dispatcher with each tool's stdin shape, asserts the
single-owner invariant, and smoke-tests the refresh lock. If anything reports `[FAIL]`, surface
it and stop.

### 7. Build the graph (only if a tool is installed)

Do not auto-run heavy builds. Offer the one-time commands and run them only if the user agrees:

```bash
# CRG (recommended): MCP tools + semantic search
code-review-graph install && code-review-graph build && code-review-graph embed
# graphify (optional): CLI exploration + git-hook freshness
graphify init . && graphify update . && graphify hook install
```

If neither is installed, tell the user the hooks are wired and dormant, and give the install
commands: `pipx install code-review-graph` and `pipx install graphifyy` (note the double `y` —
the PyPI package is `graphifyy`, but the command it installs is `graphify`).

### 8. Report

Summarize: tools wired, primary refresh owner, AGENTS.md updated (yes/no), verifier summary
line, and the exact next command the user still needs to run. Keep it short.

## Notes

- **One refresh owner.** The heavy `update+embed` is duplication-sensitive — if every wired tool
  ran it, N tools (or two concurrent sessions) would trigger N redundant builds. Only the
  `--primary` tool's end-of-turn hook runs it, and `graph-refresh.sh` additionally takes a
  repo-global lock (`mkdir`-based — portable; macOS has no `flock`) so a stray concurrent refresh
  no-ops instead of racing the embed.
- **Shared core, thin adapters.** Behavior lives once in `core/*`; the per-tool protocol table
  lives once in `core/extract.py` (stdin field names) + `core/emit.py` (stdout JSON shape) and
  `config/render.py` (config shape). The `hook.sh` dispatcher and the Copilot wrappers are thin
  glue. Adding a tool means adding a row to those three tables, not copying scripts.
- **Copilot caveat.** Copilot's `.github/hooks/*.json` runs in both its cloud agent (where no
  local graph exists, so the hook safely no-ops) and local agent sessions (where it steers, as
  for the other tools). Its command hooks take a script PATH, so `.graph-hooks/copilot/*.sh`
  wrappers delegate to the dispatcher.
- **Claude de-duplication.** Claude Code merges hooks across user/project/local scopes and
  de-dupes identical command strings. The dispatcher command string is byte-stable and resolves
  repo-first then `$HOME`, so a home install and a repo install collapse to a single fire that
  runs the repo copy. Keep the wrapper stable across versions.
- **Bundled files:** `scripts/setup-graph-hooks.sh` (installer), `scripts/verify-graph-hooks.sh`
  (verifier), `scripts/post-commit` (git refresh), `scripts/graphignore` (ignore template),
  `scripts/config/{render,merge}.py` (per-tool config + JSON merge), and `scripts/graph-hooks/`
  (the `.graph-hooks/` payload: `hook.sh`, `core/`, `copilot/`). `assets/agents-knowledge-graph.md`
  is the canonical AGENTS.md routing block.
