---
name: x442-register-delegate-agents
description: >-
  Use when the set of agents available for delegation changes — a new local LLM appears in LM
  Studio or Ollama, a new CLI alias or custom config dir is set up, a project must be restricted to
  a subset of them, or you want to see which agents a repo actually permits and why. Manages the
  .agents/delegate.json cascade — declare agents in an uncommittable layer, narrow per repo, set
  the primary assistant. Chains before setup-delegate-agent, which wires a repo to what this
  resolves.
---

# register-delegate-agents

Owns the **roster**. `setup-delegate-agent` owns the machinery and reacts to whatever this
resolves; it never invents an agent.

## The cascade

Every ancestor directory of where you are may contribute one `.agents/delegate.json`, with `$HOME`
always included. Nearest wins. There is no git-root special case, which is the point — a workspace
directory holding many independent repos is not itself a repo, so policy placed there would be
unreachable from inside any of them if the cascade anchored on a git root.

| Layer                          | Typical use                        | May define agents?   |
| ------------------------------ | ---------------------------------- | -------------------- |
| `~/.agents/delegate.json`      | what this machine can reach at all | yes                  |
| a workspace dir outside a repo | policy for every repo beneath it   | yes                  |
| a repo's own `.agents/`        | this project's restrictions        | **no — narrow only** |

**A layer inside a git work tree may not define agents.** A committed manifest that could
introduce one would add an egress target to every clone of that repo via pull request. So
definition lives in layers that cannot be committed, and repos narrow.

## Narrowing only ever tightens

Every knob a nearer layer sets moves one direction:

| Knob                                                  | Combined by | Effect                                 |
| ----------------------------------------------------- | ----------- | -------------------------------------- |
| `allow`                                               | intersect   | fewer agents                           |
| `neverDelegate`                                       | union       | more protected paths                   |
| `policy.*.allowTools` / `allowModels`                 | intersect   | fewer tools, fewer models              |
| `policy.*.autoApprove`                                | intersect   | more prompting                         |
| `policy.*.alwaysAsk`                                  | union       | more prompting                         |
| `policy.*.maxQuestionRounds` / `maxTurns` / `timeout` | min         | smaller budgets                        |
| `policy.*.strictMcp`                                  | OR          | can force strict, never un-strict      |
| `policy.*.requireParty`                               | strictest   | `local` > `same-party` > `third-party` |

No layering order and no unexpected ancestor file can **widen** what the machine permits. That is
what makes walking up from the filesystem safe to begin with.

## Party, not distance

`local` means the work never leaves the machine. `same-party` means it goes to a vendor who
already sees this code because they run your primary assistant — delegating there adds no observer.
`third-party` adds one. Anything unrecognised resolves to `third-party`; guessing downward is the
only error here with real consequences.

This is what lets a project say _"frontier Claude is fine, that gateway is not"_ — a distinction
`local` versus `remote` cannot express, because both are remote.

## The ladder

Agents carry a `rank` (lower is tried first) and the `kinds` of work they are for. `"*"` is the
catch-all, which is what lets a capable same-party agent be the fallback for work no specialised
tier claims.

```jsonc
"agents": {
  "fast-cheap":  { "rank": 1, "kinds": ["codemod", "docstring"], "autoApprove": ["docstring"] },
  "same-vendor": { "rank": 2, "kinds": ["*"] },        // capable fallback, costs quota
  "on-machine":  { "rank": 3, "kinds": ["fetch-parse"] }  // offline-capable, usually slowest
}
```

Order by what you actually want tried first, which is rarely capability. A same-vendor agent on a
cheaper model needs no extra infrastructure and is always reachable, which makes it a good
fallback — but it spends quota, so it is often not the first choice. An on-machine agent costs
nothing and works offline, but if it is slow that belongs low in the order regardless.

**Failover walks this order, and only on reachability.** If an endpoint does not answer, the
dispatcher tries the next permitted agent. A poor _result_ never triggers it: retrying elsewhere
would move work across a party boundary a policy deliberately drew. Because approval records the
agent, a failover that changes the party forces re-approval rather than proceeding quietly.

## Mode

`mode` is `manual` (default), `auto`, or `off`, and a nearer layer may only tighten it —
`off` beats `manual` beats `auto`.

`auto` does **not** mean "never ask". It removes the prompt only for kinds listed in an agent's
`autoApprove`, and only when the dispatch is read-only or worktree-isolated. Everything else still
prompts. Pre-approving a kind an agent does not serve is a hard error, and auto-approving a
dispatch that could write outside a worktree is refused at dispatch time — an unreviewed write is
the failure you cannot detect afterwards.

```bash
python3 "$SKILL/scripts/register-delegate-agents.py" add --layer ~ \
  --name fast-cheap --adapter claude --config-dir ~/.some-config-dir
```

## Procedure

### 1. See what is available

```bash
python3 "$SKILL/scripts/register-delegate-agents.py" probe
```

Read-only. Lists agent CLIs on `PATH`, local runtimes and their loaded models, and existing config
dirs. Your primary assistant's own config dir is listed but marked as not a delegate — pointing a
sub-agent at it would run the session you are already in.

### 2. Declare an agent

```bash
python3 "$SKILL/scripts/register-delegate-agents.py" add \
  --name local-qwen --adapter codex --local-provider lmstudio --model MODEL_ID
```

Adapter is one of `claude`, `codex`, `copilot`, `gemini`, and it must match the endpoint's
protocol, not your preference. A local LM Studio or Ollama server speaks the OpenAI API, which an
Anthropic-protocol CLI cannot talk to at all — so a local model needs `copilot` (via BYOK, giving
it a `--base-url`) or `codex` (via `--local-provider`), never `claude` with a different base URL.

Prefer `copilot` for a local model: `codex` emits a system message mid-conversation, and some chat
templates reject that outright. Whichever you pick, the model must support **native function
calling** — one that writes `<tool_call>` as text has not called anything, and the dispatcher will
report the dispatch as blocked rather than hand you prose that changed nothing.

To adopt a CLI you already run under its own config dir, point at the directory and let it supply
model, endpoint, context, and credential:

```bash
python3 "$SKILL/scripts/register-delegate-agents.py" add \
  --name my-alias --adapter claude --config-dir ~/.some-config-dir
```

Nothing is restated, so nothing can drift from the setup that actually works. **Never pass a token
on the command line** — it would land in your shell history. A credential belongs to the CLI's own
config or to an environment variable.

### 3. Set the primary, so party means something

```bash
python3 "$SKILL/scripts/register-delegate-agents.py" set-primary --name claude
```

### 4. Restrict a project

From inside the repo:

```bash
python3 "$SKILL/scripts/register-delegate-agents.py" allow --names a,b --layer .
python3 "$SKILL/scripts/register-delegate-agents.py" never --paths 'config/prod/**' --layer .
```

For a policy covering many repos at once, use their common parent directory as `--layer` — as long
as it is outside any repo, it can carry the restriction for everything beneath it. Note the
trade-off: a file in a non-repo directory is **machine-local**, so it protects you and not a
colleague who clones one of those repos. Only a committed per-repo file binds the team.

### 5. Check what a repo actually permits

```bash
python3 "$SKILL/scripts/register-delegate-agents.py" list --scope .
```

Shows each layer (labelled committable or local-only), the effective agents with the layer that
declared each, everything that was narrowed and by which file, and any capability warnings.

### 6. Wire it

Run [setup-delegate-agent](../setup-delegate-agent/SKILL.md) in the repo. It renders the routing
block from what this resolves.

## Notes

- **Manifests are written mode 600.** They name endpoints your code is shipped to; that is not
  something to leave group-readable, even without a token in it.
- **Capability differences are reported, not smoothed over.** `codex` has sandbox levels rather
  than a per-tool allowlist, so an approved tool list is approximated there; `copilot` and `gemini`
  cannot force an output schema, so a blocked sub-agent may return prose instead of a structured
  question. `list` warns about both, because a capability that silently does nothing is worse than
  one that is absent.
- **`probe` and `list` never write.** Every other subcommand edits exactly one layer and prints
  what changed.
- Bundled files: `scripts/register-delegate-agents.py`.
