# Adapters

One file per agent CLI. Each translates the dispatcher's _intent_ into that CLI's flags, and
normalises its output back into `{result, session_id}`.

Contract — three subcommands, all reading a JSON spec on stdin:

```text
env     spec -> KEY=VALUE lines the wrapper exports before exec
build   spec -> one argv element per line on stdout
parse   spec -> normalised {result, session_id} JSON, given .raw_file
```

`env` exists because each CLI names its endpoint differently — `ANTHROPIC_BASE_URL`,
`COPILOT_PROVIDER_BASE_URL`, a `--local-provider` flag. Hard-coding one vendor's variable in the
wrapper is what made a local OpenAI server unreachable.

**Argv elements must not contain newlines.** `build` emits one element per line, so a value
with an embedded newline is split into several arguments. Anything multi-line (a JSON schema,
a prompt) must be written on one line or passed by file path.

The spec carries: `model`, `allow_tools`, `mode`, `max_turns`, `timeout`, `schema_file`,
`prompt_file`, `last_message_file`, `raw_file`, `resume`, `worktree`, `local_provider`,
`config_dir`, `base_url`, `strict_mcp`.

Two capability differences matter and are declared in the resolver rather than hidden here:

- **Forced output schema.** `claude` takes it inline, `codex` takes a file, `copilot` and `gemini`
  have no equivalent. Without one, a blocked sub-agent may return prose instead of a structured
  question, so ask-back is best-effort on those two.
- **Tool scoping.** `claude` and `copilot` accept a per-tool allowlist. `codex` has only sandbox
  levels, so an approved list like `Read,Grep` is approximated by `read-only` — it is not enforced
  tool by tool, and the resolver warns about exactly that.

## Reaching a local model

A local runtime such as LM Studio serves the **OpenAI** API, so an Anthropic-protocol CLI cannot
talk to it at all. Two adapters can:

- **copilot**, via BYOK — set the agent's `baseUrl` to the runtime's `/v1`; the adapter exports
  `COPILOT_PROVIDER_BASE_URL`/`TYPE`/`MODEL`. GitHub auth is not required in this mode.
- **codex**, via `--oss --local-provider lmstudio|ollama`.

Prefer copilot where the model is fussy: codex emits a system message mid-conversation, which some
chat templates reject outright with a 500.

LM Studio's own `lms` CLI is **not** usable as an adapter. It is a model manager — `lms chat -p` is
a plain completion with no tool use, no file editing, no allowlist and no resumable session, so a
delegate driven through it could not read or change anything.

## Models must support native function calling

An adapter can only expose tools the model actually calls. A model that emits `<tool_call>` as
text has not called anything, and the CLI will return prose while having done nothing. The
dispatcher detects that shape and reports it as blocked rather than as an answer, because a run
that looks like a result but changed nothing is the most expensive failure available.

An adapter never reads a credential. Whatever the CLI already uses — its config dir, its own
keychain entry, an env var the operator exported — is that CLI's business.
