# Best practices — context, permissions and delegation

The skills wire a repo. These are the habits and user-level settings that make the wiring pay off.
They are what one maintainer arrived at after a lot of sessions that went wrong in instructive
ways. Each rule below says why it exists, so you can judge when it applies to you.

---

## Where context belongs

Every assistant reads instructions from several layers. When a rule sits in the wrong layer, it
either fails to reach the people who need it or reaches people it should not.

| Layer         | File                                                        | Put here                                                                            | Never put here                             |
| ------------- | ----------------------------------------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------ |
| user (global) | `~/.claude/CLAUDE.md`                                       | how _you_ want any assistant to behave, in every repo                               | anything about one repo                    |
| repo (shared) | `AGENTS.md`                                                 | the project: overview, commands, conventions, coding guidelines, routing blocks     | personal preferences                       |
| tool override | `CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md` | `@AGENTS.md`, plus what only that tool needs                                        | a copy of `AGENTS.md`                      |
| subdirectory  | `pkg/AGENTS.md` in a monorepo                               | what differs for that package                                                       | what the root already says                 |
| memory        | the assistant's memory store                                | facts that are not in the code and would be lost: decisions, gotchas, who owns what | what `git log` or the code already records |

Two rules follow from the table:

- **One source of truth per fact.** A rule copied into two files drifts. The `initial-project`
  verifier fails on duplicated guidelines for exactly that reason.
- **Repo beats user.** Where the two conflict, the repo's instructions win. Keep your global file
  to behaviour, and you will rarely have a conflict to think about.

---

## The standard global context

Use this as your `~/.claude/CLAUDE.md`. Copy it, then change the parts that are genuinely about
you. Every section is short on purpose, because this file loads into every session in every repo.
Some sections are missing on purpose:

- The secret-guard rules are written by `setup-secret-guard`.
- The graph routing is written into each repo's `AGENTS.md` by `setup-graph-hooks`.
- The commit rules live in each repo's `commitlint.config.mjs`.

```markdown
# User Preferences

## File deletion

- Never delete with `rm` / `rm -rf`. Use `trash` (macOS `trash`, or `trash-cli` on Linux) so the
  item can be recovered.

## Batch and LLM guardrails

- Never write or trigger scripts that make automated, concurrent or looped LLM calls without
  explicit confirmation.
- Default batch cap is 3 items, 1 run each, unless told otherwise.
- Before anything that issues several LLM requests, compute the expected call count, show it,
  and wait for an explicit yes.

## Model selection (subagents only)

- The main session keeps the model it started with. Never suggest switching it.
- Delegate scoped, mechanical, verifiable work to the `sonnet-high` subagent: edits from a clear
  spec, lint/format/typecheck loops, renames, running tests and reporting results, summarising
  files or logs.
- Keep on the main thread: architecture and API design, debugging with an unknown cause,
  security reasoning, refactors with unclear blast radius.
- Ask before delegating to a stronger model than Sonnet. A single Sonnet subagent needs no ask;
  any fan-out (parallel agents, a workflow) does, and respects the batch cap.

## Code knowledge graphs

- When a repo has `.code-review-graph/` or `graphify-out/`, follow the routing block in its
  `AGENTS.md`: query the graph before Grep/Glob/Read.
- Never rebuild by hand after edits; the hooks do it. Ask before building a graph that does not
  exist.

## Commits

- Conventional Commits, `type(scope): subject`, lowercase imperative subject, no trailing period.
  The repo's `commitlint.config.mjs` is the ruleset when it has one.
- Check a message with `echo "MSG" | pnpm exec commitlint` before committing.
- Never bypass hooks with `--no-verify`. Fix the message or the code.
- Never commit, push or release unless asked.

## Secrets

- Record a credential's name (an env var, a secret-manager path), never its value, in any file,
  commit message or handoff.
- If a task needs a plaintext secret, stop and say so.
```

### Why each section is there

| Section          | The failure it prevents                                                                                   |
| ---------------- | --------------------------------------------------------------------------------------------------------- |
| File deletion    | an `rm -rf` on the wrong path, with no way back. `trash` turns that disaster into an inconvenience        |
| Batch guardrails | a script that loops an LLM call over 400 files and spends a week's quota in an afternoon                  |
| Model selection  | either paying top-model rates for find-and-replace, or a cheap model making a design call nobody reviewed |
| Graphs           | an assistant that greps a repo it could have queried, at many times the token cost                        |
| Commits          | a history nobody can generate a changelog from, and hooks bypassed "just this once"                       |
| Secrets          | a token in a handoff doc or a commit message. Unlike a transcript, that is pushed, shared and indexed     |

---

## Permissions

Permissions decide what the assistant may do without asking. The goal is not the shortest prompt
count. It is that **everything it can do unasked is either harmless or reversible**, and
everything destructive is either impossible or explicitly approved.

Start from this shape in `~/.claude/settings.json`, and leave the deny rules the secret guard
already added next to it:

<!-- prettier-ignore -->
```json
{
  "permissions": {
    "allow": [
      "Bash(git add *)",
      "Bash(git commit *)",
      "Bash(git checkout *)",
      "Bash(trash *)",
      "Bash(code-review-graph update *)",
      "Bash(graphify update *)",
      "Bash(.agents/handoff/handoff list *)",
      "mcp__code-review-graph__query_graph_tool",
      "mcp__code-review-graph__semantic_search_nodes_tool"
    ],
    "deny": [
      "Bash(rm *)",
      "Bash(sudo rm *)",
      "Bash(rmdir *)",
      "Bash(unlink *)",
      "Bash(shred *)",
      "Bash(truncate *)",
      "Bash(find * -delete)",
      "Bash(find * -exec rm *)",
      "Bash(git clean *)"
    ],
    "ask": ["Read(**/values.yaml)", "Read(**/values-*.yaml)"]
  }
}
```

How to grow it:

- **Allow verbs, not invocations.** `Bash(git commit *)` once beats forty entries each with a
  different message. When a prompt offers "always allow", check how specific the rule it will
  write is.
- **Allow read-only and idempotent work** freely: graph queries, `git status`, test runners, lint.
- **Never allow `git push`, releases or deploys globally.** Those are outward-facing, and a push
  cannot be taken back once someone has fetched it. Approve them per session.
- **Deny anything whose only purpose is destruction.** The deny list is what makes it safe to
  leave a session running while you do something else.
- **Ask on files that might hold secrets but often do not**, such as Helm values files. A blanket
  deny there would block legitimate work.
- **Put repo-specific allows in the repo's `.claude/settings.json`**, so they reach everyone who
  works there and nobody else.

After a few weeks, the `fewer-permission-prompts` skill scans your transcripts for read-only
commands you approve over and over, and proposes a prioritised allow list.

---

## Delegation

Most of a working session is not judgment. It is edits from a clear spec, test runs, log reading
and summaries. Delegating those to a cheaper model at high effort keeps the main session's
context for the decisions that need it.

Create `~/.claude/agents/sonnet-high.md`:

```markdown
---
name: sonnet-high
description: Default delegate for scoped, self-contained work handed off from the main session (doc and file edits from a clear spec, surveys and read-only audits, lint/test fix loops, codemods, running builds or tests and reporting results). The main session reviews what it returns.
model: claude-sonnet-5-5
effort: high
---

You are a delegated worker. The main session gave you a scoped task and will review your output
line by line, so correctness matters more than speed.

- Follow the brief exactly. If it is contradictory or impossible, do the parts that are clear and
  report the conflict instead of improvising around it.
- Stay inside the stated scope. Never work around a permission denial, a hook, or a guardrail —
  stop and report it.
- Never print or record credential values. Record a file path or variable name instead.
- Your final message is all the caller sees: lead with what you did, then evidence (commands run,
  shas, file:line), then anything you skipped or found surprising.
```

A brief is a spec, and the delegate does exactly what it says. Three lines make the difference
between work you can trust and work you have to redo:

1. **State consequences as facts, not conditions.** "You are changing the payload, so every
   installed copy is now stale. Do not refresh them; state in your report that propagation is
   required." Never "let me know if anything needs re-propagating". A delegate that does not
   notice a thing will not report it, and its silence reads as a clean answer.
2. **Demand a falsification step for any test.** "Temporarily revert the fix, confirm the new test
   fails, restore it, report both runs." A regression test nobody has seen fail proves nothing.
3. **Forbid editing the code under test, and cap the runs.** "If a test exposes a real bug, stop
   and report it. Run the full suite at most twice." Without the first line you get a silently
   patched bug and a green suite. Without the second you can get an hour of re-runs.

Then **verify before you close**. A delegate's reported numbers are a claim. Re-run the check in
your own checkout and cite your own run.

---

## Working habits

These come from sessions where something went wrong. Each one is cheap to adopt.

- **Review the plan before executing it.** Per-task reviews compare each task against the plan.
  So a task that faithfully implements a wrong instruction passes. One reviewer reading the plan
  against its spec, before task 1, catches what eight task reviews will not.
- **Batch review fixes, release once.** When review findings arrive one after another, fix them
  on one branch and cut one release. A patch release per finding leaves a trail of tags that
  someone will later want consolidated.
- **Branch by intent.** `feature/*`, `fix/*`, `hotfix/*`, `release/*`, `wip/*`. Never commit
  onboarding or tooling changes straight to `main`.
- **Split commits by logical unit.** One concern per commit, each passing commitlint on its own.
  It makes review, revert and the generated changelog all better.
- **Do not edit generated tooling.** `.husky/commit-msg`, `.husky/pre-commit` and the graph hook
  configs are written by skills. Change the behaviour in `scripts/husky.sh`, or re-run the skill.
  A hand edit is lost on the next upgrade.
- **End sessions on purpose.** Before closing, ask whether anything is uncommitted, unreleased or
  still claimed. Work that has to continue goes on the handoff board, not in the transcript.
  See [Handoff, situation 5](handoff.md#situation-5--this-session-is-about-to-run-out-of-context).
- **Say which search mode answered.** When a graph search backs a claim, the result carries a
  `search_mode`. A `keyword` answer from a repo with embeddings means the vectors did not answer
  and the result needs checking.
