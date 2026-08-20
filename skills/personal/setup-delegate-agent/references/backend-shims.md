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

## Auto-compact

Three ways to set the window, and they are not equivalent:

| Where                                    | Form                              |
| ---------------------------------------- | --------------------------------- |
| `settings.json` in a `CLAUDE_CONFIG_DIR` | `"autoCompactWindow": 60000`      |
| CLI flag                                 | `--autocompact auto\|<tokens>`    |
| Environment                              | `CLAUDE_CODE_AUTO_COMPACT_WINDOW` |

An earlier version of this file claimed the window is clamped to a 100k minimum, inherited from the
design notes rather than measured. A working local profile runs `autoCompactWindow: 60000`, so that
floor does not apply to the settings key at minimum. Treat the clamp as unverified: if you need a
small window, set it and confirm compaction actually fires rather than trusting either claim.

What does hold: auto-compact only triggers on Anthropic's own "prompt is too long" wording. A
gateway that rewrites the error text stops the retry from ever firing, and the run dies on a
context error instead of compacting. On a small-context backend, prefer short chunked dispatches
over one long session — and never raise a profile's declared `context` past what the backend
actually serves, which only moves the failure later and makes it harder to read.

## Verifying a shim actually helped

A shim that does nothing looks identical to a shim that worked, because both produce a successful
run. To tell them apart, unset it and confirm the original error returns. If it does not, drop the
shim: an unexplained environment variable in a config is a future debugging session.
