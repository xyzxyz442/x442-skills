---
status: accepted
date: 2026-09-16
---

# A backstop that only asks — keeping a second check after the root cause is fixed

A future reader will find `missed_reads()`/`backstop()` in `secret-file-guard.py`, note that the
regex defect it was written for is already fixed, and reasonably delete it as redundant. We kept
it, because the failure it covers is one the guard cannot report on its own — and a second
failure of that kind would be just as invisible as the first.

## Context

The guard's read-rewrite half finds a credential read and routes it through `redact-view`. It is
one regex, `READ_CALL`, applied across a whole shell line. Its flag-matching group ended in
`\S+`, which no shell separator terminates, while the path token it sits next to deliberately
stops at one. So in a compound command:

```text
head -20 /etc/passwd; cat SECRETFILE
```

the flag value for `-20` ran on past the `;`, and the match's captured "path" became the literal
word `cat`. The read that followed had already been consumed by that match, so `re.sub` never
re-examined it.

What makes this worth an ADR is not the regex. It is the **failure mode**. Nothing was denied,
because no stage looked like a secret read. The guard emitted no decision at all, the command ran
verbatim, and the credential was printed. A guard that wrongly denies is reported in minutes; a
guard that wrongly allows is reported never. The defect was found by chance, and the reproduction
originally filed for it turns out not to reproduce — inserting any other command between the two
stages hides it — which is a fair measure of how little signal this class of bug emits.

A transcript also cannot be repaired after the fact: a tool result enters it before any hook can
react, and it persists to disk. Prevention is the only lever the guard has.

## Decision

Fix the root cause **and** keep an independent second layer.

- **Root cause.** `FLAG_VALUE = PATH_TOKEN` — a flag's value stops at a shell separator, exactly
  as a path token does.
- **Backstop.** `missed_reads()`/`backstop()` run at both terminal exits of the Bash path. They
  re-ask the question in a different shape — per stage, token by token, rather than one regex over
  the line — and emit `ask` rather than exiting quiet.

The backstop is deliberately narrow, and the boundaries are the decision:

- It **only ever asks**. It never rewrites, so it cannot corrupt a caller's argument.
- Stages already routed through the viewer, and stages crossing a namespace boundary, are skipped.
- Probes are capped per command.
- It does **not** look inside masked (quoted) regions. See the rejected option below.

Either layer alone closes the hole; both are kept. The regex fix makes this instance safe, the
backstop makes the next instance loud.

## Considered options

- **Ship the regex fix alone.** Rejected. It is the obvious option and the reason to reject it is
  the whole point of this record: the first failure of this class was invisible, so the second one
  will be too. A fix for a known instance buys nothing against the unknown one, and the cost of
  being wrong is a credential in a transcript that cannot be unwritten.
- **Let the backstop rewrite rather than ask.** Rejected. Rewriting is how the guard earns its
  keep, but it edits a command the user is about to run. The backstop fires precisely when the
  primary path's understanding of the line was wrong, which is the worst possible moment to trust
  that understanding enough to edit it. Asking is the outcome that is safe even when the
  backstop itself is confused.
- **Deny instead of ask.** Rejected. The backstop's whole premise is uncertainty — it fires on a
  token that _looks_ credential-bearing in a command the rewriter did not understand. A denial
  the user cannot override turns every false positive into a blocked workflow.
- **Extend the backstop to masked verbs**, closing the related case where an earlier unbalanced
  quote masks a later read. Rejected. All such shapes checked were invalid shell (`bash -n`
  rejects them), so they cannot execute and are not a leak path — while the cost is real:
  it would start prompting on honest commands like `echo "cat .env" >> notes.txt`. A guard that
  prompts on honest commands is a guard that gets switched off, and a switched-off guard protects
  nothing. The narrow scope is what keeps the prompt meaningful.
- **Rely on review or on the verifier instead of a runtime layer.** Rejected. Both check the guard
  the author thought of. Neither sees the command a user actually runs six months from now.

## Consequences

- There are now two places that decide a read is credential-bearing, and they can disagree. That
  is intended — disagreement surfaces as a prompt, which is the safe direction — but it means a
  change to the read path must be tested against both, not just the one that looks authoritative.
- The backstop can double-prompt: a command the primary path already handled through some other
  branch may still be asked about. Acceptable, and cheaper than the alternative.
- The narrow scope is load-bearing, not incidental. Widening it later — to masked regions, to more
  verbs, to uncapped probing — trades away the property that makes the prompt worth reading. Treat
  any such widening as revisiting this ADR.
- `verify-secret-guard.sh` now runs the 135-case read-rewrite regression suite
  (`selftest.read-rewrite`). That is the only gate that runs it — CI checks the standalone rule
  and the fixture boards and nothing else — so removing it from the verifier silently retires the
  tests too.
