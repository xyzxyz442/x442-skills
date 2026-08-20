# Adapters

One file per agent CLI. Each translates the dispatcher's _intent_ into that CLI's flags, and
normalises its output back into `{result, session_id}`.

Contract — two subcommands, both reading a JSON spec on stdin:

```text
build   spec -> one argv element per line on stdout
parse   spec -> normalised {result, session_id} JSON, given .raw_file
```

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

An adapter never reads a credential. Whatever the CLI already uses — its config dir, its own
keychain entry, an env var the operator exported — is that CLI's business.
