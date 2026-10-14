# Daily prompts — what to type, and why it works

Once a repo is onboarded, most of the leverage is in how you ask. These are the prompts one
maintainer uses every day, taken from real session history and grouped by where they fall in a
working session. Each comes with what it relies on, because a prompt that works on this setup can
misfire on a repo that has no board, no graph or no commitlint.

They are short on purpose. The setup carries the context: `AGENTS.md` has the conventions, the
board has the task, and the hooks route the searches. So the prompt only has to carry the
_decision_.

---

## Starting a session

```text
what next handoff?
```

```text
execute this handoff "acme-checkout-retry-backend-handoff"
```

```text
execute this handoff "acme-checkout-retry-backend-handoff", code-review it, then I will decide
whether to bump the version and release
```

- **Refer to work by handoff id, not by file path.** Ids survive a doc moving between boards or
  sections. Paths do not. The assistant resolves an id with the `handoff` CLI.
- **Say where the session stops.** "Then I will decide" leaves the release to you instead of to
  the assistant's reading of "done".
- Relies on: a handoff board ([Handoff](handoff.md)). Without one, describe the task in the prompt
  and expect to repeat it next session.

---

## Shaping the work before writing any

```text
/grill-me add tenant invitations to acme-api. A user can be invited to one tenant only
```

```text
/grill-with-docs revise and polish all the documents in docs/, the README and the context files
if required
```

These two come from a separate skills collection, not this repo; any skill that interviews you
works the same way. A grilling skill asks you questions one at a time until the design has no open branches. It costs
ten minutes and saves the session that would have implemented the wrong thing.
`superpowers:brainstorming` does the same job for features.

Answer a round of questions by exception:

```text
Q4: a. Q5-Q9: as recommended. Q10: use a prefix, not a suffix. Q11: static readonly class instead
of an enum. Anything else this round: as recommended.
```

- **Let the assistant recommend, and override only where you disagree.** Typing "as recommended"
  nine times is faster than re-arguing each default. The exceptions you do type are the decisions
  that matter.
- **Answer in one message, keyed by number.** The assistant can apply a whole round at once, and
  the transcript keeps a record of which decisions were yours.

---

## Bounding the scope

The most useful sentences in a prompt are often the ones that say what _not_ to do:

```text
no need to run dev, just lint. This implements the Data Management page only. Ignore any mockup
code outside the Management section, and list the out-of-scope suggestions at the end
```

```text
update the sync handoff for the internal team using the current implementation, and leave the
delegate suite out of scope
```

```text
keep the deploy step. It will move to a local cluster later; for now just leave a remark
```

- **"No need to X, just Y"** stops the assistant from spending ten minutes and a lot of context on
  a dev server, a build or a full test run you did not want.
- **"Out of scope" plus "list the suggestions"** keeps the work narrow without losing what the
  assistant noticed along the way. Those suggestions are tomorrow's handoffs.
- **"Later in the future, just remark"** records a known gap without starting work on it.

---

## Checking the work

```text
recheck
```

```text
recheck this handoff "acme-ledger-rounding-handoff" against the current source and try to close it
```

```text
recheck all the context files, documentation, skill catalog and README
```

```text
those 2 are fixed, re-run the full loop
```

- **"Recheck" means re-read from the source, not from memory.** After a long session the
  assistant's picture of a file can be stale. Asking it to recheck makes it look again, and the
  second look is where it finds what it missed.
- **Name the yardstick.** "Against the handoff" or "against the current source" gives "done" a
  definition. A bare "is it done?" invites a yes.
- **Recheck the documentation separately from the code.** Code changes leave context files, the
  catalog and the README stale far more often than they leave tests failing.

---

## Polishing

```text
revise and polish this handoff "acme-orchestrator-handoff" to be self-contained
```

```text
refactor, revise and polish src/jobs/report_job.py. A stashed commit already did some of the
work; recheck it against the current source first
```

"Self-contained" is the important word for anything someone else will pick up. It means a reader
with no access to this session can act on the document alone. That rules out "as discussed above",
local paths and undefined abbreviations.

---

## Committing and releasing

```text
commit with logical splits, and follow the commit linting rules
```

```text
commit with logical splits, no co-author trailer, no need to push, just commit
```

```text
fix it, re-run the failed tests, commit, bump the version and release, merge to main and push
```

- **"Logical splits"** gets one commit per concern instead of one commit per session. Each commit
  passes commitlint on its own, the changelog reads well, and any single change can be reverted.
- **Spell out the whole chain when you want it.** The global context forbids committing, pushing
  or releasing unasked. A prompt that lists "commit, bump, release, merge, push" is that ask, in
  order, and the assistant stops at the first step that fails.
- **Say "just commit" when you mean it.** It is clearer than hoping the assistant will not push.
- Relies on: `commitlint.config.mjs` and release-it from
  [`setup-project-tooling`](onboarding-project.md). The release step is `release-it` reading the
  conventional commits. Nobody edits `CHANGELOG.md` by hand.

---

## Keeping work alive across sessions

```text
file as handoff for the backend
```

```text
those are fixed. Re-run the full loop, and file what is left as a handoff so I can run it again
later in a fresh session
```

```text
don't worry about the exposed credentials for now; I will rotate them. File a handoff to automate
the rotation, and never write a rotated value into it
```

- **A handoff is the transcript you keep.** Anything that must outlive the session goes on the
  board, with its findings and its "ruled out" list. The next session starts from the doc, not
  from a summary of this one.
- **Fresh sessions are cheaper than long ones.** Filing the remainder and starting clean beats
  dragging a context window full of resolved detail into the next task.
- **State the safety rule in the request itself** when the work touches secrets. The secret guard
  catches reads, but the handoff text is written by the assistant.

---

## Ending a session

```text
everything done? clean up, and can I close this session? what next?
```

That one line asks for three things:

1. **An inventory**: uncommitted changes, leases still held, a release half-cut, a background job
   still running.
2. **A release**: the assistant releases its claims with an honest status, so nobody else finds
   the work locked.
3. **A pointer**: the next handoff to pick up, so the next session starts with a decision already
   made.

---

## Patterns that do not work

| Prompt                                  | Why it misfires                                                       | Instead                                                         |
| --------------------------------------- | --------------------------------------------------------------------- | --------------------------------------------------------------- |
| "fix everything"                        | no stop condition, so it runs until context runs out                  | "fix the 3 failing tests in `ledger.spec.ts`; stop there"       |
| "make it better"                        | "better" gets the assistant's definition, not yours                   | "revise and polish for a reader new to the codebase"            |
| "is it done?"                           | invites a yes                                                         | "recheck against the handoff's acceptance criteria"             |
| a pasted absolute path to a handoff doc | breaks when the doc moves, and leaks your directory layout into notes | the handoff id                                                  |
| "let me know if anything else breaks"   | silence reads as "nothing broke"                                      | "list every file your change makes stale"                       |
| 20 questions answered in 20 messages    | 20 round trips and a scattered record of what you decided             | one message, keyed `Q1..Q20`, "as recommended" for the defaults |
| "push it" when you meant commit         | outward-facing and hard to undo                                       | "commit only, no push"                                          |
