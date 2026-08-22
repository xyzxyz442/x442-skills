---
name: x442-delegate-handoff
description: >-
  Use when a handoff goes to someone outside the board — a contractor, junior dev, other team, or
  AI tool without the protocol. Exports a brief, reads back their claim, never closes it for you.
  Chains after run-handoff.
---

# delegate-handoff

The judgment layer over `handoff export` and `handoff import --result` — the two commands
[`setup-handoff`](../setup-handoff/SKILL.md) installs so a handoff can leave the board entirely
and come back as a report. The CLI enforces mechanics (repo identity, format version, the secret
scan). This skill carries what the CLI cannot: whether a handoff is ready to leave, and whether
what came back is actually true.

Invoke this when you are about to hand tracked work to someone who will not run the board's
hooks or skills — a contractor, a junior engineer, another team, or an AI tool with no
`.agents/handoff/` installed. Read [`run-handoff`](../run-handoff/SKILL.md) first if you have
not — delegation only ever exports a handoff that already exists on the board.

## The one rule

**Export never closes a handoff, and import never closes one either.** Whatever the executor
reports is a claim, not a verdict. `done` stays an action a reviewer takes after reproducing the
evidence themselves — that is the entire reason this loop exists instead of just emailing someone
the doc.

## 1. Is this brief-able?

Delegating does not save work if the handoff was not ready to leave the room. Exporting a vague
handoff does not make it less vague — it hands your own uncertainty to a stranger, who now has to
resolve it with less context than you had, at a slower feedback loop, and reports back something
you still have to untangle. That is more expensive than finishing the investigation yourself.

Before you export, check all four:

- **Context links symptom to root cause.** Not "the tests fail sometimes" — the actual mechanism,
  written down.
- **Where names `file:line` you opened**, not a guess at which module probably owns this. An
  executor who has to relocate the bug before fixing it has been handed a different, harder task
  than the one you think you delegated.
- **Verify is runnable by someone who was not in this conversation.** A command they can paste, or
  a concrete state they can check — not "confirm it feels right."
- **Decisions are settled.** Anything still open is a design question, and a design question
  handed to an executor gets answered by whoever is cheapest to guess, not by whoever should
  decide it.

If any of the four is missing, the fix is to go do that work yourself first, not to export anyway
and hope the Executor contract section covers the gap. It does not — it constrains scope, it does
not supply missing judgment.

A handoff whose type is `standalone` holds no work and cannot be exported — send the file. A
handoff already `done` has nothing left to delegate.

## 2. Exporting

```text
handoff export <id> [--to WHO] [--out DIR] [--branch NAME] [--no-claim]
```

- `<id>` must resolve to a live `coordination` or `orchestrator` handoff on the board.
- `--to WHO` — who is executing this, recorded in `delegated_to`. Free text, colons folded to an
  em dash like every other free-text field.
- `--out DIR` — write the brief somewhere other than the default `.agents/handoff/briefs/`. Rarely
  needed; the default is what the executor's checkout expects.
- `--branch NAME` — the branch the executor works on and opens a PR from. Defaults to `fix/<id>`,
  the repo's own git-flow convention. Pick something more specific yourself when the default would
  collide or mislead.
- `--no-claim` — skip taking the lease. Use only when you are certain no one else could pick up
  this id while it is out for delegation; normally you want the claim, because it is what stops a
  second agent from claiming the same work while the executor has it.

**Already holding the lease is fine.** Claiming a handoff, investigating it, and then deciding to
delegate is the normal order, so export extends a lease this session already holds instead of
refusing on it — you end up with the same thing a fresh claim would have given you, a lease you own
with a full TTL, and it says so. A lease held by **another** session still refuses, and on a bundle
it refuses the whole export before anything is written. That is the point: reach for `--no-claim`
only for the case it is actually for, not to get around your own lease.

Export refuses a `standalone` handoff (send the file) and a handoff already `done` (nothing to
delegate). For an `orchestrator`, it renders one cover brief carrying the Sequencing section plus
one brief per child — the whole bundle goes out together.

The brief inlines everything the missing hooks and skills would otherwise enforce: a preflight
that checks the executor is in the right repository before they touch a line, the Context/Where/
Decisions/Verify from the doc, and an executor contract spelling out scope discipline, evidence
requirements, and the no-`rm` rule. None of that is optional reading for the executor — it is the
whole reason a bare file can carry what normally lives in tooling.

## 3. What to send

Export writes `.agents/handoff/briefs/<id>.brief.md`. **Commit it** before telling the executor —
they need to pull it from the branch, not receive it as an attachment. A brief that only exists in
your working tree is not exported yet.

Before committing, reread it once for anything that should not enter git history permanently — a
pasted log line with a token in it, an internal URL that names a system the executor should not
see. The CLI's secret scan runs on the way back in, not on the way out; export trusts you to have
written a clean doc in the first place.

## 4. Reviewing the return

The executor returns a branch and a PR, with the brief's Result block filled in on that branch.
Two artifacts, one order:

**Read the PR diff first. Read the Result second.** Deliberately, in that order. If you read the
narrative first, it tells you what to look for in the code, and you will find what it primed you
to find. Reading the diff cold — as if no one had told you what it does — is what catches a fix
that does not match its own description.

Then reproduce the evidence yourself. `result_claimed: done` in the frontmatter is a string an
outsider wrote about code you have not run. Run the command they named. Open the `file:line` they
checked. A claim that turns out to be true costs you one command; a claim that turns out to be
false and gets trusted anyway costs everyone downstream of it.

Two signals worth weighing before you trust the report at all:

- **`result_claimed: done` with no commit or PR named** — the CLI already warns on import when
  this happens. Treat it as a reason to look harder, not as noise to dismiss.
- **Drift between `source_commit` and current `HEAD`.** The brief was rendered against a snapshot;
  if the repo has moved a lot since, the Where anchors it named may no longer point at what they
  did when you wrote them.

## 5. Importing and closing

```text
handoff import --result <path/to/id.brief.md> [--force-repo]
```

This splices the Result block into the board doc under `## Result (reported)`, stamps
`result_from`, `result_at`, `result_claimed`, and sets `review: pending`. Re-importing the same
brief replaces the spliced block rather than stacking a second copy, so pulling a corrected brief
and importing again is safe.

**`import` never sets `status`.** Not for `done`, not even for `blocked` — a `blocked` claim still
needs you to supply a validated `--blocked-on` before the doc can carry it. The executor's account
lands in `result_claimed`, sitting next to a `status` field it did not touch. After you have
reproduced the evidence from step 4, you close it the same way you would close anything else:

```text
handoff release <id> --status done --verified-by "how YOU verified live code"
```

If `--verified-by` echoes text already present in the executor's reported Result block — the
check is scoped to that spliced block, never the rest of the doc — the CLI warns you: that is
closing on their word with extra steps, and the warning exists to catch exactly that shortcut.

## Anti-patterns

- **Closing `done` on the executor's evidence string.** Copying `result_claimed`'s text into
  `--verified-by` is not verification; it is transcription. Reproduce the check yourself first.
- **Delegating a bundle with an empty Sequencing section.** An orchestrator export with no
  ordering guidance hands the executor a pile of children and no sense of what blocks what —
  they will guess an order, possibly the wrong one.
- **Re-exporting after a scope change instead of amending and re-sending.** If the assignment
  changed while the executor was mid-flight, editing the board doc and telling them directly is
  faster and clearer than a second export they now have to reconcile against the first.
- **Exporting a handoff that was never specified well enough to delegate**, to buy time on a
  handoff you have not actually diagnosed. This does not buy time — see [Is this
  brief-able?](#1-is-this-brief-able) above.
- **Reading the Result before the PR diff.** Reverses the order that keeps the review honest.

## Notes

- **No `repair-*` sibling.** This skill manages no state outside the files `export` and `import`
  already write to the board doc and the brief. Drift that outlives its lease — an export that was
  claimed and never came back — is a board-state defect, and the check for it lives in
  [`repair-handoff`](../repair-handoff/SKILL.md), not here.
- **No payload version stamp of its own.** `export` and `import --result` ship as part of
  `setup-handoff`'s payload; this skill just drives them.
- **Cross-repo boards.** A handoff whose `audience` names another repo gets its identity from the
  board's `repos.json` — the manifest projection that
  [`register-cross-repo-handoff`](../register-cross-repo-handoff/SKILL.md) writes and attests with
  each member's root commit. Resolution never falls back to matching the audience against a
  directory name. When it cannot resolve and attest a target — the registry is missing or stale,
  the checkout moved, two members claim the audience — the brief carries
  `repo_root_commit: unverified`, the preflight downgrades to a name-and-origin check, and the
  brief says which of those happened. Importing that result requires `--force-repo` and an extra
  manual confirmation that it targets the right repo — treat an unverified brief's evidence with
  the same extra scrutiny, and prefer re-running the cross-repo sync and re-exporting.
