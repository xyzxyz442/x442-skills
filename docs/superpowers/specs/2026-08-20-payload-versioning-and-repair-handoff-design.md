# Payload versioning and repair-handoff — design

Date — 2026-08-20
Status — approved, pre-implementation
Branch — `feature/payload-versioning-repair-handoff`

## Problem

Two related gaps in how this repo's install-shaped skills age.

**1. A stale install is invisible.** Skills that copy a payload into a target repo have no way
to say "the payload here is older than what I now ship". `setup-handoff` is the only one that
tries, and it does so by feature-sniffing: `detect-handoff.sh` greps the installed `handoff`
script for the literal `"session=` to decide `version=current|legacy`. Every future payload
change needs a new sniff, and the other skills cannot answer the question at all. A repo wired
a year ago looks identical to one wired today.

**2. Repair is conflated with re-install.** `repair-graph-hooks` exists because graph-hooks owns
state outside the files it wrote — a SQLite graph, embeddings, lock directories, two external
CLIs. Re-running the installer fixes none of that. `setup-handoff` has the same shape (a live
board with leases, a generated index, an archive) and no repair counterpart.

## The rule this encodes

> A setup skill needs a `repair-*` sibling only when it manages state **outside the files it
> wrote** — a database, leases, a daemon, external tool installs. Otherwise upgrade lives in
> the setup skill, repair is "re-run it", and drift detection lives in `verify-*.sh`.

And its corollary for versioning:

> A skill needs a payload version stamp only if it **copies artifacts into the target repo**
> that can then drift from what the skill ships. A skill whose "install" is regenerated on
> every run does not drift.

## Scope

Applying both tests to `main` as it stands:

| skill                         | copies a payload?            | stamp | outside state?                    | repair-\* |
| ----------------------------- | ---------------------------- | ----- | --------------------------------- | --------- |
| `setup-graph-hooks`           | yes — `.graph-hooks/`        | yes   | graph db, embeddings, locks, CLIs | exists    |
| `setup-handoff`               | yes — `.agents/handoff/`     | yes   | board, leases, index, archive     | **new**   |
| `setup-project-tooling`       | yes — scattered assets       | yes   | no                                | no        |
| `initial-project`             | no — agent authors AGENTS.md | no    | no                                | no        |
| `register-cross-repo-graph`   | no — sync regenerates        | no    | no                                | no        |
| `register-cross-repo-handoff` | no — sync regenerates        | no    | no                                | no        |

Out of scope — `setup-delegate-agent` / `run-delegate-agent` live on the unmerged
`feature/delegate-agent` branch and do not exist on `main`. `setup-delegate-agent` copies a
payload and so inherits a stamp when that branch lands; that is a follow-up, not this change.

## Part 1 — the version stamp

**Source of truth.** Each stamped skill gains `scripts/payload.version`, a single line:

```text
setup-handoff 1
```

Bumping a payload means editing that one file. Nothing else encodes the number.

**Where it lands in the target repo.**

- Directory payloads write a `.version` file at the payload root — `.graph-hooks/.version`,
  `.agents/handoff/.version`. It is committed with the payload, so a teammate's checkout
  carries it, and it is readable with `cat` — no `python3`, which matters because the hooks
  that read it must run on a machine that has only `bash`.
- `setup-project-tooling` has no payload root; its artifacts scatter across `scripts/`,
  `.husky/`, and root configs. Its stamp rides as a marker comment in the header of
  `scripts/husky.sh`, the one file that is unambiguously the skill's and already required to
  exist. Still a one-line read.

**Absent `.version` means pre-versioning**, not corrupt — it reports the same "behind" warning
and the same fix. This is what lets the stamp replace `detect-handoff.sh`'s `"session=` sniff
without a migration step.

## Part 2 — verifier reporting

Every stamped skill's `verify-*.sh` gains one check: read the installed stamp, compare against
`$(dirname "$0")/payload.version` — self-locating, no configuration — and emit

```text
[warn] payload v1 installed, skill ships v2 — re-run setup-handoff
```

A warning, never a FAIL: a behind-but-working install is not broken. This preserves the
`Summary: N passed, W warnings, F failed` contract the harness parses, and the non-zero exit
stays reserved for real failures.

## Part 3 — session notice

### Where a notice belongs, and where it does not

`setup-graph-hooks` and `setup-handoff` both emit session-start context, and
[`session-context.sh`](../../../skills/engineering/setup-graph-hooks/scripts/graph-hooks/core/session-context.sh)
produces two separate outputs:

- `out["context"]` — the `GRAPH QUERY CHEATSHEET`. A routing table, injected every session and
  re-read every turn. It answers "how do I query this graph".
- `out["systemMessage"]` — a notices block. Conditional, silent when healthy, already carrying
  `embed-health.sh` drift. It answers "something needs your attention".

Anything actionable belongs in **notices**, not the cheatsheet: a version line in a routing
table re-read every turn dilutes it, and would print on healthy repos.

### Correction — the stale-payload notice is not implementable

This design originally put the Part 1 version comparison in that notice. It cannot go there.

A session hook runs **inside the target repo**, where the skill directory is unreachable —
`setup-graph-hooks.sh` states this outright, as the reason `setup-embeddings.sh` must be copied
into the repo at all: _"the skill directory it ships from is not reachable from a consuming
repo."_ The hook can read `.graph-hooks/.version`, but it has nothing to compare it against,
and the installed payloads record no path back to the skill.

Recording an absolute skill path at install time would fix the comparison and break worse — a
machine-local path committed into a shared file, dead on every other checkout.

So the stamp's only sound consumers are the two that **do** run from the skill directory:
`verify-*.sh` (Part 2) and `repair-handoff` step 1 (Part 4). No session notice reports staleness.

### What the session notice does instead

`hooks.sh sessionstart` gains a notice for board problems that are **locally detectable** —
needing no reference outside the repo — pointing at `repair-handoff`:

- a lock directory with no `owner` file, or whose handoff doc no longer exists
- `INDEX.md` absent while docs are present

This is implementable precisely because these checks are self-contained, and it mirrors the
`embed-health` precedent it sits beside: state the condition, name the repair skill, stop.
Never auto-run anything.

`setup-project-tooling` has no session hook, so `verify-project-tooling.sh` is its only surface.
That asymmetry is accepted rather than papered over with a new hook.

## Part 4 — repair-handoff

A new `skills/engineering/repair-handoff/SKILL.md`, sibling to `verify-setup-handoff.sh` in the
same split as `repair-graph-hooks` is to `verify-graph-hooks.sh`.

**Narrower than the graph case, because the board already self-heals in part.**
`hooks.sh sessionstart` runs `reap_expired`, so leases past their TTL clear themselves at the
start of every session. `repair-handoff` covers only what does not self-heal:

0. **Tool integrity, first and fail-fast** — does `.agents/handoff/handoff` execute at all
   (exec bit, CRLF line endings, shebang)? Every check below assumes it runs, so a broken
   payload would otherwise surface as a dozen confusing downstream failures.
1. **Wiring** — per-tool hook owner drift, primary-tool drift, `merge-hooks.py` state, exec
   bits, and the payload stamp from Part 1.
2. **Board state** — lock directories with no `owner` file or no matching doc; `INDEX.md`
   drift (it is generated and never hand-edited, so regenerating is safe); malformed doc
   frontmatter; open-versus-`archive/` mismatch.
3. **Shared board** — the board pointer resolves, the `HANDOFF_GROUP` section exists, and the
   sub-indexes agree with the manifest.
4. **Offer, never auto-run** — releasing a lease held by a demonstrably dead session that has
   not yet hit its TTL. Someone else's live work is not ours to reclaim unasked.

**Safety rails, mirroring the sibling.** Idempotent — a clean no-op on a healthy repo. Never
deletes a doc or its content. `rmdir` on empty lock directories only, never `rm -rf`. Never
rewrites a doc it does not hold the lease for.

**Precondition.** If `.agents/handoff/` is absent the repo was never wired — stop and point at
`setup-handoff`. Do not repair a repo that was never set up.

## Testing

- `harness/repair-handoff-workspace/` — fixtures, `evals/evals.json`, and a `grade.py` that
  wraps `verify-setup-handoff.sh`, following [harness-structure.md](../../harness-structure.md).
  Fixtures need a healthy board, a stale-stamp board, an orphaned-lock board, and an unwired
  repo for the precondition-refusal case.
- Existing `setup-graph-hooks`, `setup-handoff`, and `setup-project-tooling` fixtures gain the
  new stamp file; their idempotency cases would otherwise fail on the first re-run.
- Red/green on the stale-stamp case — the warning must be absent before the change and present
  after, the same way the lease-leak regression was proven.

## Order

The stamp lands first. `repair-handoff` step 1 reads it, so the reverse order would need a
placeholder.

## Documentation

`AGENTS.md` Skill Index and [skills/README.md](../../../skills/README.md) gain the
`repair-handoff` row. The rule at the top of this document goes in `AGENTS.md` alongside the
skill authoring conventions, so the next setup skill knows whether it owes a repair sibling.
