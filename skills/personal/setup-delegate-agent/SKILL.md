---
name: x442-setup-delegate-agent
description: >-
  Use when a repo should be able to hand mechanical work to a cheaper agent running as a separate
  CLI process — "set up delegation here", "wire up the local LLM for this project", or any mention
  of dispatching bulk work to a sub-agent. Detects the .agents/delegate.json cascade, installs a
  bounded dispatcher with a consent gate and credential scanning, and renders an AGENTS.md routing
  block from the agents that repo actually permits. Idempotent. Chains after
  register-delegate-agents, which declares the agents, and before run-delegate-agent.
---

# setup-delegate-agent

Wires a repo so mechanical work can be dispatched to a cheaper agent in a **separate CLI process**,
while this session stays on the model you are talking to.

The separate process is the mechanism, not an implementation detail. An agent CLI resolves one
endpoint per process — subagent frontmatter, model pickers, and env overrides all resolve _within_
it — so a second tier needs a second process with a different environment.

This skill installs machinery and reacts to configuration. It never invents an agent; declaring one
is [register-delegate-agents](../register-delegate-agents/SKILL.md)' job.

## Architecture

1. **The cascade** — `.agents/delegate.json` at every ancestor directory decides which agents this
   repo may use. Managed by `register-delegate-agents`.
2. **The dispatcher** (`.agents/bin/delegate-run`) — records consent, scans for credentials, runs
   the agent headless under hard caps, and prints one line of JSON. Everything verbose stays on
   disk.
3. **The adapters** (`.agents/bin/adapters/`) — one per agent CLI, translating dispatch intent into
   that CLI's flags.
4. **The consent gate** — a `PreToolUse` hook that refuses a dispatch which skipped the gate, and
   gates reads of credential-shaped paths.
5. **The routing block** in `AGENTS.md` — tells every agent in the repo what is worth delegating,
   which agents exist, and which of them are third-party.

### Per-tool support

| Tool           | Consent gate wired into       | Event        |
| -------------- | ----------------------------- | ------------ |
| Claude Code    | `.claude/settings.json`       | `PreToolUse` |
| Gemini CLI     | `.gemini/settings.json`       | `BeforeTool` |
| GitHub Copilot | `.github/hooks/delegate.json` | `preToolUse` |

## Preconditions

1. The target is a git working tree.
2. `AGENTS.md` exists at its root — if not, run `initial-project` first; this skill will not
   fabricate one.
3. `python3` and `jq` are available.
4. The cascade resolves at least one agent in this scope. If it resolves none, run
   `register-delegate-agents` first — wiring a block that advertises no route, or a route that
   fails on first use, is worse than not wiring one.

If any fails, report it and stop. Do not partially apply.

## Prerequisites & platform support

**`trivy` is required at dispatch time.** Credential scanning is fail-closed: a scanner that cannot
run is indistinguishable from a clean scan, and that is exactly the case that leaks. Without it
every dispatch refuses.

```bash
brew install trivy
```

GNU `timeout` is used when present and a pure-bash watchdog otherwise, so coreutils is **not**
required. Everything targets bash 3.2, which is what macOS ships.

## Procedure

`$SKILL` is this skill's directory; `$REPO` is the target repo root.

### 1. Resolve the repo root

```bash
REPO="$(git rev-parse --show-toplevel)"
```

### 2. See what this repo may use

```bash
python3 "$SKILL/scripts/manifest/resolve.py" --scope "$REPO" \
  | jq '{primary, default, agents: [.agents[] | {name, adapter, party}], errors}'
```

If it resolves nothing, stop and run `register-delegate-agents`.

### 3. Tell the user the party classes before applying

**Name every third-party agent and wait.** A third-party agent means source code reaches someone
who cannot already see it. That single fact inverts what the routing block says about sensitive
work, so it is not a detail to apply silently.

### 4. Apply

```bash
bash "$SKILL/scripts/setup-delegate-agent.sh" "$REPO" --tools claude
```

`--tools` takes a comma-separated list (`claude,gemini,copilot`). Add `--dry-run` first to see what
would be wired without touching anything.

### 5. Verify it fires

```bash
bash "$SKILL/scripts/verify-delegate-agent.sh" "$REPO"
```

Healthy result is **0 failed**. The verifier is read-only: it exercises the consent gate with
synthetic input and resolves the cascade, but never dispatches and never contacts a backend. If
anything reports `[FAIL]`, surface it and stop.

### 6. Report

Say plainly which agents are permitted, **which are third-party**, whether `trivy` is present, and
which tools got the consent hook.

## The credential rule, and its honest limits

Two boundaries are enforced, and they are not equally strong:

- **Into a sub-agent — enforced.** The brief is scanned before dispatch, credential-shaped
  variables are stripped from the child environment, and never-delegate paths are refused
  regardless of approval.
- **Back from a sub-agent — enforced.** The raw result is scanned before any of it reaches the
  orchestrator's context.
- **Inside your own session — prevention only.** A tool result enters the transcript _before_ any
  hook runs, and that transcript persists to disk. Nothing can redact it afterwards, so the gate
  asks before a credential read rather than cleaning up after one.

What this delivers, stated exactly: _secrets are never passed to a sub-agent, sub-agent output is
scanned before it enters context, and known-secret-path reads are gated in the main session. A
command can still print one by accident — and if it does, it is on disk permanently._

## Notes

- **Idempotent.** Every file is byte-compared before writing, so a second run leaves `git status`
  clean. Re-running after the roster changes rewrites the managed block in place.
- **Path rules are a pre-filter, not a classifier.** `neverDelegate` catches the obvious reach for
  a known credential file. Content scanning is the real check, and even that has gaps — trivy's
  default ruleset does not flag bare AWS access-key pairs.
- **The consent gate is cooperative, not a sandbox.** It raises skipping the assessment from an
  omission to a deliberate act. The real boundary is the tool allowlist and the worktree.
- **Adapters never read a credential.** Whatever the CLI already uses is that CLI's business.
- Bundled files: `scripts/setup-delegate-agent.sh`, `scripts/verify-delegate-agent.sh`,
  `scripts/manifest/resolve.py`, `scripts/payload/{delegate-agent,delegate-run,consent-gate.sh}`,
  `scripts/payload/adapters/{claude,codex,copilot,gemini}.sh`,
  `assets/{agents-delegate.md,delegate-to-agent.md}`, `references/backend-shims.md`.

Day-to-day discipline lives in [run-delegate-agent](../run-delegate-agent/SKILL.md).
