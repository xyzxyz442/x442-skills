<!-- delegate:begin (managed by setup-delegate-agent — do not edit between markers) -->

## Delegation to a cheaper agent

Mechanical work can be handed to a cheaper agent running as a separate CLI process, so this
session's context and quota go on judgment instead of bulk.

Primary assistant here is **PLACEHOLDER_PRIMARY**. Agents available in this scope —

PLACEHOLDER_ROSTER

PLACEHOLDER_PARTY_NOTE

**Assess, ask, then dispatch — never dispatch first.**

```text
PLACEHOLDER_DECISION
```

Route by what the work _is_, not by how big it feels:

| Signal                                                                  | Route              |
| ----------------------------------------------------------------------- | ------------------ |
| Mechanical bulk — codemods, renames, formatting, docstrings, log triage | delegate           |
| Long batch where wall-clock does not matter                             | delegate           |
| Needs this conversation's accumulated context                           | **keep it here**   |
| Novel architecture, ambiguous requirements, security review             | **keep it here**   |
| Touches PLACEHOLDER_NEVER                                               | **never delegate** |

Never-delegate paths are refused by the dispatcher regardless of approval, and both the brief and
the returned result are scanned for credentials before they move. A secret that reaches this
session's transcript cannot be removed afterwards, so the gate is prevention, not cleanup.

Dispatch is two steps — record the consent you obtained, then run under it:

```text
.agents/bin/delegate-run --approve TASK_ID --class CLASS --allow 'TOOLS'
.agents/bin/delegate-run --task .agents/delegate/dispatch/SLUG.md --approved TASK_ID --worktree
```

One line of JSON comes back. Read `.result`; open `.raw` or `.log` only when triaging a failure —
that is the output you delegated in order not to read. A `status: question` means the sub-agent
needs something you know: answer with `--resume SESSION_ID --prompt "your answer"`, and escalate to
the user only if you genuinely do not know either.

Full discipline — the assessment rubric, how to write a brief, and the failure-mode table — lives
in the `run-delegate-agent` skill. Load it before your first dispatch.

<!-- delegate:end -->
