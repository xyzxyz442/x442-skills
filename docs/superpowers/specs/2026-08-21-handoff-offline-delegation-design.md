# Offline handoff delegation — export and import — design

Date — 2026-08-21
Status — approved, pre-implementation
Branch — `feature/handoff-offline-delegation`

## Problem

The handoff board coordinates work across sessions, agents, and repos, but every participant has to
be _on_ the board. The scenario this design serves is the one that is not: an orchestrator plans
work, files several handoffs, and hands each to a developer who will execute it with whatever AI
tool they use — no board, no CLI, no hooks, no installed skills.

Handing over the doc alone does not work. A handoff doc is a **coordination record**, not an
**execution brief**. Roughly half of what makes the protocol hold lives outside the file:

| Not in the doc                                                          | Where it actually lives                           |
| ----------------------------------------------------------------------- | ------------------------------------------------- |
| Claim before you work, release when you stop, `done` requires evidence  | `run-handoff/SKILL.md` and the `AGENTS.md` block  |
| Deny edits to an unclaimed doc, regenerate `INDEX.md`                   | `scripts/hooks.sh`, wired per tool                |
| `claim`, `release --status done --verified-by`, `reap`                  | the `handoff` CLI                                 |
| Coding guidelines, commit convention, branch naming, no-`rm`            | `AGENTS.md` in the target repo                    |
| Meaning of `blocked_on`, orchestrator `children`, cross-repo `audience` | only resolvable against the board                 |
| Any return path at all                                                  | nothing — `import` refuses an id already on board |

Two consequences follow. First, an off-board executor operates with none of the constraints the
protocol exists to impose. Second, whatever they produce has to be hand-transcribed back, so the
board's record of who reported what, and on what evidence, is lost.

There is also a correctness gap that predates any of this: a handoff handed to someone else still
reads as **free** on the board, because nothing represents "being worked off-board."

## Scenario and its assumptions

Fixed by decision, and the rest of the design depends on them:

- The executor **has a checkout of the same repo**. Code lands through normal git, so the return is
  a _report_, not a patch.
- The executor **does not have the board** — no leases, no hooks, no skills, possibly a different
  AI tool.
- Work returns as a **branch and a pull request**, reviewed by the orchestrator or another senior.
- The board doc stays **authoritative and CLI-owned**. Nothing off-board hand-edits its frontmatter.

## The constraint that shapes the design

Board docs are committed; `.locks/` is not (`.gitignore` line 458). Leases are therefore
machine-local, and a junior working on a branch can never collide with the orchestrator's lease.
That is what makes an offline round-trip safe at all: the only shared state is the doc, and only
one side writes it.

It also settles where the logic can live. Every piece of board state this design introduces —
claiming on export, stamping who has it, recording what came back — is a frontmatter write. Only
the CLI writes frontmatter. So a markdown-only skill cannot implement this; the CLI must, and the
skill carries the judgment instead.

## Artifacts

### Where briefs live

`.agents/handoff/briefs/<id>.brief.md`, **committed**.

The orchestrator exports and commits. The executor pulls, fills the Result block in place on their
branch, and opens the PR — so the PR diff shows the report next to the code that justifies it. One
artifact, versioned, with no attachment to lose and no second file to keep paired.

### Brief format

Frontmatter is flat `key: value`, because the board's reader is line-based and does not parse
nested mappings. No value may contain `:` (the house rule), which constrains URL normalization
below.

```yaml
---
brief: 1
handoff: rbac-gap
title: Handoff — RBAC gap on tenant switch
severity: high
repo_name: acme-api
repo_provider: github
repo_origin: acme/acme-api
repo_root_commit: 4f2a1c9e...
source_commit: 927b762
source_branch: main
exported: 2026-08-21
branch: fix/rbac-gap
result_status:
result_by:
result_at:
---
```

The three `result_*` keys ship empty and are filled by the executor.

Body sections, in order:

1. **Preflight** — the repo guard, below. First, before anything.
2. **Your assignment** — Context, Where, Verify, Decisions, copied from the doc.
3. **Executor contract** — inlined; this is what replaces the missing skills and hooks.
4. **Repo rules** — links only (`AGENTS.md`, coding guidelines, commit convention). The executor
   has the checkout, and the repo's own link-don't-duplicate rule applies.
5. **Dependencies** — resolved `blocked_on` and sibling children, each with title and current status.
6. **Definition of done** — lifted from Verify.
7. **Result** — an empty block between `<!-- handoff:result:begin -->` and `<!-- handoff:result:end -->`.

The Result block ships with its subsections fixed, because import reads them:

```markdown
<!-- handoff:result:begin -->

### Status

<!-- done | partial | blocked — must match result_status in the frontmatter -->

### What changed

### Evidence

<!-- A command and its output, or a file:line checked. Not "looks correct". -->

### Commits and PR

### Open questions and follow-ups

<!-- handoff:result:end -->
```

The same marker pair appears in the brief and in the board doc — import reads between them in the
source and writes between them in the destination, which is what makes re-import idempotent.

Field names differ across the two files on purpose. The brief holds the executor's own account
(`result_status`, `result_by`, `result_at`); the doc holds the board's record of a report received
(`result_claimed`, `result_from`, `result_at`). Import maps `result_status` to `result_claimed` and
`result_by` to `result_from`, so a value written by an outsider never lands in a field name that
reads like a board verdict.

### The executor contract

The load-bearing prose. It is what makes a bare markdown file carry the constraints that normally
come from hooks and skills:

- Do exactly the scope in Assignment. If it grows, stop and report `partial`. Do not expand scope.
- Do not relitigate anything under Decisions.
- Work on the named branch, conventional commits, open a PR, do not merge.
- `done` means verified against live code. Evidence must name a command and its output, or a
  `file:line` checked. "Looks correct" is not evidence.
- Never paste secrets, keys, or PII. This file is committed to git history.
- Do not edit anything under `.agents/handoff/` except this brief's Result block.
- Never delete with `rm`; use `trash`.
- If blocked, report `blocked` and name the blocker. Guessing is worse than blocking.

## Repo identity — the wrong-repo guard

A brief naming `src/auth/tenant.ts:88` is dangerous precisely because that path plausibly exists in
a different repo. Identity must travel with the brief and be checked on both sides.

`repo_root_commit` is the primary key — the SHA of the first commit. It survives renames, remote
moves, and mirror pushes, and a fork matching it is the correct answer, because a fork is the same
lineage. `repo_provider` and `repo_origin` are human-readable confirmation, not the check.

**The brief records a provider, not a host.** A host is a deployment detail — a repo that moves from
`github.com` to an enterprise install is still the same repo, and the root commit proves that.
`repo_provider` is one of `github`, `gitlab`, `bitbucket`, or `other`, and for a recognized provider
the host is dropped from `repo_origin` because the provider implies it.

`other` covers self-hosted git and any provider not yet listed, and there the host is **kept** in
`repo_origin`. "acme/api on other" would not let a reader confirm which repo they are standing in,
and confirming exactly that is the whole job of the line — the same honest-degradation principle as
`unverified`.

**Normalization matters.** The SSH remote form `git@github.com:owner/repo.git` contains a colon,
which would break the frontmatter under the no-colon rule. Export normalizes both SSH and HTTPS
forms to bare `host/owner/repo`, stripping scheme, credentials, and the `.git` suffix.

**Executor side.** No CLI and no hooks, so the guard is a readable preflight that is still
checkable, rendered with the expected value already substituted:

```sh
# Run before making a single edit. If this prints WRONG REPO, stop and return the brief unexecuted.
[ "$(git rev-list --max-parents=0 HEAD | tail -1)" = "4f2a1c9e..." ] \
  && echo "OK — correct repo" || echo "WRONG REPO — do not proceed"
```

Read-only, one line, works in any tool. The contract's first line is: do not edit anything until
this passes.

**Orchestrator side.** `import --result` hard-refuses a brief whose `repo_root_commit` does not
match the repo it runs in. That is the real gate; the preflight is the courtesy that catches it
earlier and cheaper.

**Drift.** Import warns, without refusing, when `source_commit` is well behind `HEAD` — the Where
anchors may have moved since export.

**Cross-repo boards.** On a grouped board from `register-cross-repo-handoff`, the board is owned by
no repo and a handoff's `audience` names a different repo than the one export runs in. Identity is
supposed to resolve from the **target** repo via the group manifest — `register-cross-repo-handoff`
carries an explicit per-repo `path` and an `audience` that may differ from both, and manifest
reading is not implemented here; it belongs to that skill and is deferred future work. Until it
lands, any `audience` that differs from the exporting repo degrades honestly straight to
`repo_root_commit: unverified`, downgrading the preflight to a name-and-origin check with a visible
warning. An earlier version of this CLI guessed the target by sibling directory name
(`../$audience`) and treated a match as verified; that guess is deleted, because a wrong guess
renders as VERIFIED — indistinguishable from a fabricated SHA to the executor, and worse than
declining to guess. It never fabricates a SHA, because a fabricated SHA would make a wrong-repo run
look verified.

## CLI — `handoff export`

```text
handoff export <id> [--to WHO] [--out DIR] [--branch NAME] [--no-claim]
```

1. Resolve `<id>` through the existing `norm_id` path. Die if it is not on the live board.
2. Dispatch on type:
   - **coordination** — render one brief.
   - **orchestrator** — render a cover brief carrying the Sequencing section, plus one brief per
     child.
   - **standalone** — refuse. A reference doc holds no work; sending the file directly is the right
     answer, and the message says so.
3. Claim the lease unless `--no-claim`, reusing the existing claim path verbatim — a live foreign
   lease dies, a stale one is taken over and logged.
4. Stamp `delegated_to`, `delegated_at`, and `brief` on the doc.
5. Render to `.agents/handoff/briefs/<id>.brief.md`, then `cmd_index`.
6. Print the path and the redact-before-commit reminder.

`--branch` defaults to `fix/<id>`, matching the repo's git-flow convention. It cannot be derived
reliably from severity, so it is a default rather than an inference.

## CLI — `handoff import --result`

```text
handoff import --result <file> [--force-repo]
```

Refusals, in order. Each one is the point of the command:

| Check            | Refuses when                                                                                   |
| ---------------- | ---------------------------------------------------------------------------------------------- |
| `brief:` version | The format version is unknown to this CLI                                                      |
| **Repo guard**   | `repo_root_commit` does not match locally; `unverified` warns and requires `--force-repo`      |
| Id resolution    | `handoff:` names nothing live on the board; archived gets its own message                      |
| `result_status`  | Missing, or not one of `done`, `partial`, `blocked`                                            |
| Result block     | Still the empty template                                                                       |
| Secret scan      | The returned text matches key or token shapes — it is untrusted and about to enter git history |
| Empty commits    | Warns when `result_claimed` is `done` but no commit or PR is named                             |

On success it splices the Result between managed markers under `## Result (reported)` — replacing
on re-import rather than appending — stamps `result_from`, `result_at`, `result_claimed`, and
`review: pending`, reindexes, and prints the exact `release --status done --verified-by "..."`
command for the reviewer to run.

**It never writes `status`.** Not even for `blocked`, which requires a validated `--blocked-on`
the reviewer must supply. The executor's claim lands in a field named `result_claimed`, sitting
visibly beside a `status` it did not change.

### Naming caveat

`import --result` preserves the export/import symmetry, at the cost of inverting `import`'s
precondition: `import <file>` dies if the id already exists, `import --result` dies if it does not.
Two preconditions under one verb. `handoff result <file>` would be the cleaner API. Recorded as an
open choice rather than silently accepted.

## Board state

All new fields are optional. Absent means today's behavior, so existing boards need no migration.

| Field                                        | Written by                                                   | Meaning                                         |
| -------------------------------------------- | ------------------------------------------------------------ | ----------------------------------------------- |
| `delegated_to`, `delegated_at`, `brief`      | `export`                                                     | Out for work, with whom, and where the brief is |
| `result_from`, `result_at`, `result_claimed` | `import --result`                                            | Who reported, when, and what they claimed       |
| `review`                                     | `import --result` sets `pending`; a `done` release clears it | Needs the reviewer's eyes                       |

`list` gains two markers — the recipient for a delegated row, and a review marker for
`review: pending`. Review-pending rows surface as actionable, because they are waiting on the
reviewer rather than on the executor.

`release` gains one warning, never a refusal: when `--verified-by` is byte-identical to the
executor's reported evidence, that is closing on their word with extra steps.

## The `delegate-handoff` skill

Markdown-only, `experimental`, under `skills/engineering/`, chaining after `run-handoff`. It owns
the judgment the CLI cannot encode:

- **Is this brief-able?** Exportable only if Context links symptom to root cause, Where names
  `file:line` actually read, Verify is runnable by someone who was not in the conversation, and
  Decisions are settled. A handoff whose Where was guessed becomes a stranger guessing further.
- **Reviewing the return.** Read the PR diff first and the Result second, in that order and
  deliberately, so the report does not frame the code. Reproduce the evidence. `result_claimed:
done` is a claim about live code the reviewer has not run.
- **Anti-patterns** — closing `done` on the executor's evidence string; delegating a bundle with an
  empty Sequencing section; re-exporting after a scope change instead of amending and re-sending;
  exporting a handoff to buy time on one that was never specified well enough to delegate.

It owes **no `repair-*` sibling** — it manages no state outside the files it writes. Orphaned
delegations (exported, lease gone stale, nothing returned) are real drift, and that check belongs
in the existing `repair-handoff`. It owes **no payload version stamp** of its own; the CLI it
drives is `setup-handoff`'s payload.

## Testing

Three layers, matching the repo's existing two-layer model plus a CLI self-test.

1. **`handoff.selftest.sh`** in the payload, following `config.selftest.sh` — temp board, PASS/FAIL
   counters, read-only outside its sandbox. This is where the round-trip is proven: export, fill,
   import, then assert `status` unchanged, `review: pending` set, Result spliced exactly once on
   re-import. Every refusal in the import table gets its own case. The wrong-repo guard especially:
   an untested guard is not a guard.
2. **`verify-setup-handoff.sh`** gains checks that the installed payload carries the new commands
   and the `briefs/` directory.
3. **`harness/delegate-handoff-workspace/`** with `evals/`, `fixtures/`, and `grade.py` per
   [docs/harness-structure.md](../../harness-structure.md). Fixtures — a board with an exportable
   coordination handoff, an orchestrator with three children, and returned briefs in four states:
   well-formed, unfilled, wrong-repo, and secret-bearing.

## Propagation

The unavoidable tax. Bump `scripts/payload.version` to `setup-handoff 3`, then refresh the CLI in
every live copy by re-running the installer into each: the board at `.agents/handoff/`, plus eight
harness fixtures (four under `repair-handoff-workspace`, one under `run-handoff-workspace`, three
under `setup-handoff-workspace`). Those eight are byte-identical to the payload today, so drift
would be visible but silent.

The ninth fixture, `setup-handoff-workspace/fixtures/legacy-install/.claude/handoff/handoff`, is a
deliberately stale 217-byte stub representing a pre-migration install. **It must not be refreshed** —
refreshing it destroys the very condition the migration case tests.

There is no sync script for any of this; each copy is installed, not copied.
`.agents/handoff/.version` then does its job on real installs.

Documentation that must move in the same commit or it lies:

- the payload `README.md`
- `assets/agents-handoff.md` (the AGENTS block)
- the `skills/README.md` catalog row
- the skill index table in `AGENTS.md`

## Build order

1. Brief template asset and `export` (render only, no board writes) — settle the artifact first
2. Board stamps and lease claim on export
3. `import --result` with the full refusal table
4. `handoff.selftest.sh`, alongside 1 through 3 rather than after
5. Payload propagation and version bump
6. `delegate-handoff` skill and harness workspace
7. Documentation

Steps 1 through 5 are one reviewable unit; 6 and 7 are the second. The work itself gets filed as an
orchestrator handoff with those two children, which exercises the bundle export path on itself.

## Open choices

Recorded so implementation does not silently decide them:

1. **`import --result` versus `handoff result`** — symmetry against the precondition inversion.
2. **`--branch` default** — `fix/<id>` as a default, or required with no default.
3. **Unreachable cross-repo target** — degrade to `unverified` with a warning, or hard-fail.

## Non-goals

- **Patch-bearing returns.** The executor has the repo; code travels by git. Briefs carry reports,
  never diffs.
- **Board merging or sync.** This is not an offline replica of the board. One side owns the doc.
- **Trusting the executor's status.** No flag makes `import` close a handoff. `done` stays a
  reviewer action backed by evidence the reviewer reproduced.
- **Exporting standalone docs.** A reference doc is already self-contained; send the file.
