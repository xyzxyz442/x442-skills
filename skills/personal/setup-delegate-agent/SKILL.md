---
name: x442-setup-delegate-agent
description: >-
  Use when a repo should hand mechanical work to a cheaper or local model instead of spending this
  session's quota — "set up delegation", "wire up qwen/LM Studio/Ollama", "delegate bulk work to a
  cheap agent", or any mention of a second agent running as a separate CLI process. Installs a
  bounded dispatcher, backend profiles you can switch between, a consent gate that asks before
  delegating, and an AGENTS.md routing block that tells agents what is worth delegating. Idempotent
  and safe on any repo. Chains before run-delegate-agent.
---

# setup-delegate-agent

Wires a repo so mechanical work can be dispatched to a cheaper agent running as a **separate CLI
process**, while this session stays on the model you are talking to.

The separate process is not an implementation detail. Claude Code resolves exactly one
`ANTHROPIC_BASE_URL` per process — subagent frontmatter, `CLAUDE_CODE_SUBAGENT_MODEL`, and the
`/model` picker all resolve _within_ that endpoint. A second tier therefore needs a second process
with a different environment. The parent keeps its subscription auth; the child gets the cheap
weights, and neither can see the other's credential.

## Architecture: four layers

1. **Backend profiles** — a cascade of JSON manifests declaring where work can go. Only your
   personal, uncommitted manifest may define an endpoint; a committed repo manifest can narrow the
   set but never add to it.

   A profile can be declared three ways. Prefer the first if you already have a working delegate:

   | Key            | Use when                                                     |
   | -------------- | ------------------------------------------------------------ |
   | `configDir`    | You already run a delegate under its own `CLAUDE_CONFIG_DIR` |
   | `settingsFile` | You have a `--settings` JSON file instead                    |
   | `baseUrl`      | Nothing exists yet — declare the endpoint and model directly |

   `configDir` adopts a directory whole: model, base URL, context window (from
   `CLAUDE_CODE_MAX_CONTEXT_TOKENS`), credential, and the delegate's own `CLAUDE.md` standing
   rules all come from its `settings.json`. Nothing is restated in the manifest, so nothing can
   drift out of sync with the setup that actually runs.

2. **The dispatcher** (`.agents/bin/delegate-run`) — writes a brief, runs the backend headless with
   hard caps, and prints one line of JSON. Everything verbose stays on disk.
3. **The consent gate** — the dispatcher refuses to run without recorded consent; a `PreToolUse`
   hook backstops it so a raw shell call cannot route around the gate.
4. **The routing block** in `AGENTS.md` — tells every agent in the repo what is worth delegating,
   and what must never be.

### Per-tool support

| Tool           | Consent gate wired into       | Event        |
| -------------- | ----------------------------- | ------------ |
| Claude Code    | `.claude/settings.json`       | `PreToolUse` |
| Gemini CLI     | `.gemini/settings.json`       | `BeforeTool` |
| GitHub Copilot | `.github/hooks/delegate.json` | `preToolUse` |

The dispatcher itself is tool-generic — the hook only closes the bypass path.

## Preconditions

1. The target is a git working tree.
2. `AGENTS.md` exists at its root. If it does not, run `initial-project` first — this skill will
   not fabricate one.
3. `python3` and `jq` are available.

If any fails, report it and stop. Do not partially apply.

## Prerequisites & platform support

`timeout` (GNU coreutils) is required **at dispatch time**, not at install time. Stock macOS ships
neither `timeout` nor `gtimeout`; without one, a dispatch has no wall-clock kill and a model that
loses the tool-call format spins until something else stops it. The installer warns and continues;
the verifier reports it as a failure, because an install that cannot dispatch is not done.

```bash
brew install coreutils # provides gtimeout, which the dispatcher accepts
```

## Procedure

`$SKILL` is this skill's directory; `$REPO` is the target repo root.

### 1. Resolve the repo root

```bash
REPO="$(git rev-parse --show-toplevel)"
```

### 2. Check for a backend manifest

```bash
python3 "$SKILL/scripts/manifest/resolve.py" --scope "$REPO" --root "$REPO" | jq '{default, profiles: [.profiles[].name], errors}'
```

If it resolves at least one profile, go to step 4.

### 3. Bootstrap a manifest — detect, propose, write only on approval

If nothing resolves, find out what is actually running before proposing anything:

```bash
# existing delegate config dirs (a settings.json beside a CLAUDE.md is the strongest signal)
ls -d ~/.claude-* 2> /dev/null | while read -r d; do
  [ -f "$d/settings.json" ] && echo "configDir candidate: $d"
done
# local runtimes
curl -s -m 2 -o /dev/null -w 'lmstudio:%{http_code}\n' http://127.0.0.1:1234/v1/models
curl -s -m 2 -o /dev/null -w 'ollama:%{http_code}\n' http://127.0.0.1:11434/api/tags
```

Prefer a `configDir` candidate over declaring an endpoint by hand: adopting the directory means the
model, base URL, context, and credential are read from the setup that already works, so they cannot
drift. Read its `settings.json` for the egress class — never print the token.

Show the user what was found, which of those you propose to declare, and **which of them are
remote**. Then, only with their agreement:

```bash
bash "$SKILL/scripts/setup-delegate-agent.sh" --write-user-manifest ~/.agents/delegate-backends.json
```

That writes the example manifest at mode 600 and refuses to overwrite an existing file. Have the
user edit it, then continue. Never write a token into it — a profile either points at a
`configDir`/`settingsFile` that already holds the credential, or names an environment variable via
`tokenEnv`.

### 4. Confirm the egress class before applying

```bash
python3 "$SKILL/scripts/manifest/resolve.py" --scope "$REPO" --root "$REPO" \
  | jq -r '.profiles[] | "\(.name)\t\(.egress)\t\(.base_url)"'
```

**Tell the user the egress class of the profile you are about to wire, and wait.** A `remote`
profile means source code leaves the machine. That single fact inverts what the routing block
says about sensitive work, so it is not a detail to apply silently.

### 5. Apply

```bash
bash "$SKILL/scripts/setup-delegate-agent.sh" "$REPO" --profile PROFILE_NAME --tools claude
```

`--tools` takes a comma-separated list (`claude,gemini,copilot`). Add `--dry-run` first to see
what would be wired without touching anything.

This installs the payload into `.agents/bin/`, the broker subagent into `.claude/agents/`, the
consent hook into each named tool's settings, the routing block into `AGENTS.md`, and the ignore
entries into `.gitignore`.

### 6. Verify it fires

```bash
bash "$SKILL/scripts/verify-delegate-agent.sh" "$REPO"
```

Healthy result is **0 failed**. The verifier is read-only: it exercises the consent gate with
synthetic input and resolves the manifest, but never dispatches and never contacts a backend. If
anything reports `[FAIL]`, surface it and stop.

### 7. Report

Say plainly: which profile is active, **whether it is local or remote**, which tools got the
consent hook, and whether `timeout` is available. If the profile is remote, say that delegated
code leaves the machine — the user should hear it from you, not discover it in the block.

## Notes

- **Idempotent.** Every file is byte-compared before writing, so a second run leaves `git status`
  clean. Re-running with a different `--profile` rewrites the managed block in place rather than
  appending a second one.
- **The committed manifest can only narrow.** A repo-level `.delegate-backends.json` may set
  `allow` (intersected across layers) and `neverDelegate` (unioned, never overridden). Declaring
  `profiles` there is a hard error: a pull request that could add an endpoint would add an egress
  target to every clone of the repo.
- **`neverDelegate` is a floor, not a classifier.** It is a path-match over the brief that catches
  the obvious cases. It is not a sensitivity classifier and will not catch a secret described in
  prose. Treat it as a seatbelt, not a lock.
- **The consent gate is cooperative.** It raises skipping the assessment from an omission to a
  deliberate act. It is not a sandbox — the real boundary is the tool allowlist and the worktree.
- **Credentials are never written or read by these scripts.** A profile either points at a
  `configDir`/`settingsFile` whose credential the CLI reads itself, or names an environment
  variable via `tokenEnv`. The verifier warns about a world-readable credential file; it never
  modifies one. `tokenEnv` must be a variable _name_ — a value starting `sk-` is rejected.
- **MCP is off for delegates by default.** The wrapper passes `--strict-mcp-config` so a delegated
  run does not inherit the project's MCP servers, which would widen its reachable tools without
  ever appearing in the `--allowedTools` the dispatch was approved against. Set `"strictMcp": false`
  on a profile if you genuinely need them.
- **A `configDir` profile brings its own `CLAUDE.md`.** That file is the delegate's standing
  operating rules, and it belongs to you, not to this skill — the installer never writes or
  rewrites it. It is the right place for "do only what the prompt asks, never widen the task".
- **Backend quirks are opt-in.** See [references/backend-shims.md](references/backend-shims.md) —
  turn a shim on when you have the 400 that justifies it, not in advance.
- Bundled files: `scripts/setup-delegate-agent.sh`, `scripts/verify-delegate-agent.sh`,
  `scripts/manifest/resolve.py`, `scripts/payload/{delegate-agent,delegate-run,consent-gate.sh}`,
  `assets/{agents-delegate.md,delegate-to-agent.md,delegate-backends.example.json}`,
  `references/backend-shims.md`.

Once installed, the day-to-day discipline lives in
[run-delegate-agent](../run-delegate-agent/SKILL.md).
