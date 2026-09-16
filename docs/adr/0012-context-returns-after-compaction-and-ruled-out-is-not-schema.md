---
status: accepted
date: 2026-09-16
---

# Held-lease context returns after compaction, and Ruled out is not a schema change

A session holding a lease loses the handoff's Verify, Decisions, and dead ends when its context
is compacted, and then redoes rejected work or closes without the real checks. We decided the
session-start hook re-injects a capped working set for every held lease **after** compaction,
through `SessionStart`'s `compact` matcher, on the tools that can do it — Claude Code today — with
the gap on every other tool documented rather than papered over. Separately, the new
`## Ruled out` section is **optional and not a schema change**, unlike `## Current state` before
it.

## Context

- Of the wired tools, only Claude Code can put text back into a compacted session. Its
  `PreCompact` hook can block or run side effects but cannot inject context; injection happens
  from `SessionStart` with the `compact` matcher
  ([Claude Code hooks](https://code.claude.com/docs/en/hooks)). Gemini CLI's `PreCompress` is
  asynchronous and advisory, its output is not injected, and its `SessionStart` has no compaction
  trigger ([Gemini CLI hooks reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/reference.md)).
  Copilot CLI has no compaction event
  ([Copilot CLI hooks](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks)).
- Compaction happens because context is full; re-filling it undoes the point.
- A doc's path changes when it is archived or moved between boards (ADR 0011). Only its id is
  stable.
- The template recorded what was settled (Decisions) and what happened (Activity), but not what
  was tried and failed. That is what a second session spends its time rediscovering.
- ADR 0003 treats body sections as schema: `migrate` inserts a missing `## Current state`,
  because every reader depends on it.

## Decision

- **Re-inject after compaction, from `SessionStart(compact)`.** For each handoff the session holds
  a lease on, emit Current state, Verify, Decisions, and Ruled out, in that order.
- **Cap it.** About 2,000 characters per doc and 6,000 in total. A cut section ends with
  `… (truncated — run: handoff show <id> --section <name>)`; docs past the total cap appear as id,
  lease expiry, and `handoff show <id>`. The constants are tunable.
- **Name ids, never paths.** Everything the hook emits refers to a handoff by id and a CLI command
  that resolves it at call time.
- **Add `handoff show <id>`** — read-only, offline, group-aware, searching live docs then the
  archive, with `--section <name>` and `--path`; a restricted doc prints the same handling banner
  as `claim`. ADR 0003 already names `show` as a read path.
- **Report lease expiry, never extend it.** The hook reports in one line, never blocks, and never
  writes to the network (ADR 0003's rule for hook invocations). An automatic `touch` would hide a
  stalled session.
- **Document the gap on every other tool.** Setup states that held-lease context is not restored
  after compaction there, and `run-handoff` tells agents on those tools to re-read their held
  handoffs with `handoff show` when they notice a compaction.
- **`## Ruled out` is optional.** One line per approach —
  `<approach> — <why it failed> — <evidence>` — appended by hand under the lease or by
  `release --ruled-out`, which runs the write-path secret scan. It is append-only by convention,
  as Activity is. The template gains it; readers treat an absent section as empty; the schema
  version does not move and `migrate` does not add it.

## Considered options

- **Inject from `PreCompact`.** Rejected — the event cannot inject.
- **A marker file written by Gemini's `PreCompress` and picked up by a later hook.** Rejected — it
  builds state on an event documented as async and advisory, and the next hook to fire may not be
  able to inject either. It would fail silently.
- **Inject the whole doc.** Rejected — it refills the context compaction just freed, and Context
  and Where are cheap to re-read on demand.
- **Paths in the truncation line.** Rejected — a path goes stale on archive or `move`; an id does
  not.
- **Extend the lease on compaction.** Rejected — see above.
- **Make Ruled out a schema change and migrate it in.** Rejected — Current state was migrated
  because a reader cannot work without it; a board where no approach has failed loses nothing
  from an absent Ruled out. Tying a template line to a schema bump would also couple it to
  unrelated format work.
- **Fold failed approaches into Decisions or Activity.** Rejected — Decisions is what to do and is
  read before starting; Ruled out is what not to retry and is read when an approach looks
  tempting. Activity is chronological, so finding a dead end would mean replaying it.

## Consequences

- The session-start hook gains a `compact` branch and a size budget; it stays bash-only and must
  not make session start slow.
- The CLI gains `show` and `release --ruled-out`.
- A future Gemini post-compression trigger or a Copilot compaction event reopens the tool gap; the
  documented gap is the marker to revisit.
- Readers of old docs see no Ruled out section and treat it as empty; nothing needs rewriting.
