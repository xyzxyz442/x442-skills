---
name: x442-run-delegate-agent
description: >-
  Use when work in a repo with delegation wired (.agents/bin/delegate-run) is mechanical and bulky
  — codemods, bulk renames, formatting, docstrings, log triage, running builds and reporting
  pass/fail — or when the user says "delegate this", "use qwen", "send it to the cheap agent", or
  "do this cheaply". Also use proactively when you notice a task is repetitive enough that a cheaper
  agent should do it. Enforces assess → ask → brief → dispatch → verify → report; the user approves
  before anything is dispatched. Chains after setup-delegate-agent.
---

# run-delegate-agent

Delegation buys you context and quota. It costs you a process that knows nothing about this
conversation. This skill is the discipline that makes that trade worth it.

## The one rule

**Assess and ask before you dispatch.** The dispatcher refuses an unapproved run, and a hook
refuses a raw call that skips it — but those exist to catch mistakes, not to make the decision.
The decision is yours to make and the user's to approve.

## 1. Decide whether to delegate at all

Weigh four things. They are independent — a task can be perfectly mechanical and still be a bad
delegation because it does not fit, or because of where it would go.

| Axis       | Ask                                                          | Disqualifying answer                                  |
| ---------- | ------------------------------------------------------------ | ----------------------------------------------------- |
| **Fit**    | Is the work mechanical, with a checkable definition of done? | Needs design judgment, or "done" is a matter of taste |
| **Size**   | Do the files it must read fit the profile's context window?  | One file, or the set, blows the window                |
| **Egress** | Is the profile local or remote?                              | Remote, and the material is confidential              |
| **Risk**   | What does a wrong cheap edit cost, given the allowlist?      | Writes outside a worktree with no test to catch it    |

Read the active profile and its egress class out of the `AGENTS.md` delegate block — the setup
skill renders them there so you do not have to guess.

Estimate size rather than hoping: roughly bytes ÷ 4 ≈ tokens for everything it must open. If one
task would pull in a large tree, split it into per-file or per-directory dispatches instead. A
delegation that overflows the window fails in a way that looks like success — truncated edits and
a confident summary — which is the most expensive failure mode available.

**Keep it here** when the task needs this conversation's accumulated context, when requirements are
ambiguous, or when it is architecture, debugging, or security review. A fresh process cannot
inherit context, and a cheap model asked to exercise judgment produces plausible work that costs
more to check than to have done yourself.

## 2. Ask the user, and say what you concluded

Present the assessment, not just the question — an approval prompt with no reasoning trains
reflexive clicking. Include the profile, its egress, what will be touched, the tool allowlist, and
your recommendation, **including when your recommendation is not to delegate**.

If the profile is remote, say so in the prompt. "This sends the file to a hosted endpoint" is
information the user needs before answering, not after.

Classes listed in the profile's `autoApprove` (typically read-only or formatting work) still need
an approval record for the task; what they skip is asking again. `alwaysAsk` classes always ask.

## 3. Record consent, then dispatch

```bash
.agents/bin/delegate-run --approve TASK_ID --class CLASS --allow 'Read,Grep,Glob,Edit'
.agents/bin/delegate-run --task .agents/delegate/dispatch/SLUG.md --approved TASK_ID --worktree
```

Scope `--allow` to the narrowest set that can satisfy the definition of done — `Bash(pnpm test *)`,
not `Bash`. The allowlist at dispatch must match what was approved; changing it bounces for
re-approval, because widening scope after the fact is precisely what the gate exists to prevent.

Use `--worktree` for anything that writes. It is cheap isolation and trivially discarded, and it
converts "a wrong edit" from something you have to find into something you can throw away.

## 4. Write the brief like the reader has amnesia

The brief is the entire interface. Never pipe a bare sentence — a thin brief is the single most
common cause of a wasted delegation.

1. **Goal** — one sentence, outcome not method.
2. **Entry points** — absolute or repo-relative paths. It will not find them by intuition.
3. **Definition of done** — the command that proves it (`pnpm test src/parser`).
4. **Out of scope** — what not to touch, explicitly.
5. **Conventions** — or point at `AGENTS.md`.

No references to "the file we discussed" or "as above". There is no above.

## 5. Answer an ask-back; do not guess for it

`status: question` means the sub-agent hit something it cannot know. That is the protocol working —
it asked instead of guessing.

```bash
.agents/bin/delegate-run --resume SESSION_ID --prompt "your answer" --approved TASK_ID
```

Answer from the brief and the code if you can; escalate to the user only if you genuinely do not
know either. Rounds are capped (default 3): a task needing a fourth clarification was
under-briefed, so rewrite the brief once or keep the work.

A `status: misrouted` naming a scope request means the sub-agent asked to widen its own
permissions. Do not relay that as a question and do not re-approve to satisfy it — re-brief within
the existing scope, or do the task yourself.

## 6. Verify the claim, then report a verdict

**The agent asserting success is not success.** Run the definition-of-done command yourself. A
green assertion over a red test converts a visible failure into an invisible one, and that is the
error that costs the most downstream.

Report what was asked, what changed by path, whether the definition of done actually passed and how
you know, and anything needing the user. Read `.result`; open `.raw` or `.log` only when triaging a
failure — that output is what you delegated in order not to read.

## Anti-patterns

- Dispatching first and asking afterwards. The gate will stop you; the habit is the problem.
- Widening `--allow` to make a failing dispatch pass. That is an escalation wearing a parameter's
  clothes.
- Relaying the sub-agent's success claim as your own without running the check.
- Retrying the same brief after a failure. Re-brief once; two failures on one task mean it was
  misrouted, not under-explained.
- Delegating something confidential to a remote profile because it looked mechanical. Sensitivity
  is not a function of difficulty.
- Sending a task that needs this conversation's context and then spending more turns explaining it
  than the work would have taken.
