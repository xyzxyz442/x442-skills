<!-- delegate:begin (managed by setup-delegate-agent — do not edit between markers) -->

## Delegation to a cheaper agent

Mechanical work can be handed to a cheaper agent running as a separate CLI process, so this
session's context and quota are spent on judgment instead of bulk.

Active profile: **`PLACEHOLDER_PROFILE`** — `PLACEHOLDER_MODEL`, PLACEHOLDER_CONTEXT_K context, egress **PLACEHOLDER_EGRESS**.

PLACEHOLDER_EGRESS_NOTE

**Claim the decision before you spend it.** Assess, ask, then dispatch — never dispatch first.

```text
PLACEHOLDER_DECISION
```

Route by what the work _is_, not by how big it feels:

| Signal                                                                 | Route                                                                 |
| ---------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Mechanical bulk: codemods, renames, formatting, docstrings, log triage | delegate                                                              |
| Long batch where wall-clock does not matter                            | delegate                                                              |
| Needs this conversation's accumulated context                          | **keep it here** — a fresh process cannot inherit it                  |
| Novel architecture, ambiguous requirements, security review            | **keep it here**                                                      |
| Touches PLACEHOLDER_NEVER                                              | **never delegate** — refused by the dispatcher regardless of approval |

Dispatch is two steps: record the consent you obtained, then run under it.

```text
.agents/bin/delegate-run --approve <task-id> --class <class> --allow '<tools>'
.agents/bin/delegate-run --task .agents/delegate/dispatch/<slug>.md --approved <task-id> --worktree
```

One line of JSON comes back. Read `.result`; open `.raw` or `.log` only when triaging a failure —
that is the output you delegated in order not to read. A `status: question` means the sub-agent
needs something you know: answer it with `--resume <session_id> --prompt "<answer>"`, and escalate
to the user only if you genuinely do not know either.

Full discipline — the assessment rubric, how to write a brief, and the failure-mode table — lives
in the `run-delegate-agent` skill. Load it before your first dispatch.

<!-- delegate:end -->
