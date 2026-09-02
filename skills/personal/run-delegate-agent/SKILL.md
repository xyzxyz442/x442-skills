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

| Axis      | Ask                                                          | Disqualifying answer                                  |
| --------- | ------------------------------------------------------------ | ----------------------------------------------------- |
| **Fit**   | Is the work mechanical, with a checkable definition of done? | Needs design judgment, or "done" is a matter of taste |
| **Size**  | Do the files it must read fit the profile's context window?  | One file, or the set, blows the window                |
| **Party** | Is the agent local, same-party, or third-party?              | Third-party, and the material is confidential         |
| **Risk**  | What does a wrong cheap edit cost, given the allowlist?      | Writes outside a worktree with no test to catch it    |

Read the roster and each agent's party class out of the `AGENTS.md` delegate block — the setup
skill renders them there so you do not have to guess. `local` never leaves the machine;
`same-party` goes to the vendor already running your primary assistant, so it adds no
observer; `third-party` adds one.

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
reflexive clicking. Include the agent, its party class, what will be touched, the tool allowlist, and
your recommendation, **including when your recommendation is not to delegate**.

If the agent is third-party, say so in the prompt. "This sends the file to someone who cannot
already see this code" is information the user needs before answering, not after.

Classes listed in the profile's `autoApprove` (typically read-only or formatting work) still need
an approval record for the task; what they skip is asking again. `alwaysAsk` classes always ask.

## 2b. When this skill should fire at all

**An explicit opt-out beats everything.** If the user says _don't delegate_, _do it yourself_, or
_keep this here_, do the work yourself — that overrides auto mode and every heuristic below.

**Explicit opt-in** skips the debate about whether to delegate, though not the consent gate:
"delegate this", "do it cheaply", "offload this", or naming an agent directly ("use the local one").

**Proactive** firing needs something countable, not a feeling. Before proposing delegation
unprompted, be able to say which of these is true: the same mechanical edit repeats across several
files; the input is bulk output nobody needs to read closely (logs, generated files); the task has
a definition-of-done command that will prove it. If you cannot name one, do not propose it — an
unprompted suggestion you cannot justify trains the user to ignore the next one.

## 3. Record consent, then dispatch

```bash
.agents/bin/delegate-run --approve TASK_ID --class CLASS --allow 'Read,Grep,Glob,Edit'
.agents/bin/delegate-run --task .agents/delegate/dispatch/SLUG.md --approved TASK_ID --kind KIND --worktree
```

Always pass `--kind`. It is validated against what the agent is declared to be for, so a misrouted
task bounces before it runs — and afterwards "why did this go there" has a written answer instead of
a recollection. In `auto` mode the kind is also what decides whether the dispatch needs a prompt.

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

## What the dispatcher refuses regardless of approval

Some things are not yours to approve, and the dispatcher enforces them before the agent starts:

- a brief naming a never-delegate path, or one that a credential scan flags
- an allowlist that differs from what was approved — widening after the fact is the escalation the
  gate exists to stop
- `bypassPermissions`, in any mode
- a returned result carrying a credential, which is blocked on the way back rather than reaching
  this session's transcript, where nothing could remove it

Treat a `status: blocked` naming a secret as a brief-authoring bug, not an obstacle. Rewrite the
brief to reference the value by name rather than by content.

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
- Delegating something confidential to a third-party agent because it looked mechanical.
  Sensitivity is not a function of difficulty.
- Pasting a credential into a brief to save a step. The dispatcher scans and will refuse,
  but the habit is what fails on the day the scanner has a gap — trivy does not flag every
  secret shape.
- Sending a task that needs this conversation's context and then spending more turns explaining it
  than the work would have taken.
