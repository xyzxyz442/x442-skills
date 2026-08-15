# Backend shims

`delegate-agent` is deliberately thin. Claude Code speaks a richer protocol than most non-Anthropic
backends accept, and each mismatch has a known environment-variable fix — but every shim you turn
on preemptively is an untested claim about a backend you may not run, and shims that are never
exercised rot silently.

**Turn a shim on when you have the 400 that justifies it, not before.** Set it in the environment,
confirm the dispatch succeeds, then persist it by exporting it from your shell profile or adding it
to the profile's `settingsFile` `env` block.

| Symptom (from `.log` of a failed dispatch)                                 | Cause                                                                                            | Shim                                            |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ----------------------------------------------- |
| 400 mentioning `context_management`, or `"Extra inputs are not permitted"` | Claude Code sends pre-release fields that a translating gateway forwards verbatim                | `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`      |
| 400 containing `Input tag 'adaptive' found`                                | The backend rejects adaptive reasoning, which Claude Code requests on 4.6+ aliases               | `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1`       |
| 400 or silent truncation mentioning `cache_control`                        | `cache_control` blocks are dropped or rejected by most local servers                             | `DISABLE_PROMPT_CACHING=1`                      |
| Thinking blocks rejected, or wasted output budget on a non-reasoning model | The model has no thinking mode                                                                   | `MAX_THINKING_TOKENS=0`                         |
| Run dies on a context error that the automatic retry never caught          | Auto-compact only fires on Anthropic's exact "prompt is too long" wording; a gateway rewrites it | `CLAUDE_CODE_AUTO_COMPACT_WINDOW=<ctx − 16000>` |
| Output truncated well before the model's real limit                        | Default output cap too low for the backend                                                       | `CLAUDE_CODE_MAX_OUTPUT_TOKENS=<n>`             |

## The auto-compact floor

`CLAUDE_CODE_AUTO_COMPACT_WINDOW` is clamped to a 100k minimum. A profile whose `context` is below
roughly 116k therefore cannot arm it at all, and `/compact` becomes the only recovery inside a long
delegated session. That is a reason to prefer short, chunked dispatches on a small-context backend
rather than one long one — not a reason to raise the declared `context` past what the backend
actually serves, which only moves the failure later and makes it harder to read.

## Verifying a shim actually helped

A shim that does nothing looks identical to a shim that worked, because both produce a successful
run. To tell them apart, unset it and confirm the original error returns. If it does not, drop the
shim: an unexplained environment variable in a config is a future debugging session.
