# Handoff Protocol

A lease-based coordination board for work that crosses **sessions, agents, or repos**. One
directory (`.agents/handoff/`) holds every handoff doc; ownership is settled by an atomic
file lock, not by editing the doc. Wired by [`setup-handoff`](https://github.com/xyzxyz442/x442-skills)
and operated per the [`run-handoff`] discipline.

## The rule

**Claim before you work. Release when you stop.**

```bash
cd .agents/handoff
./handoff list                                  # what exists, what's open, who holds what
./handoff new rbac-gap --title "Close RBAC gap" # file a new handoff (or write the .md by hand)
./handoff claim rbac-gap "adding policies to the payment module"
#   ... do the work, updating the doc as you go ...
./handoff release rbac-gap --status done --verified-by "e2e green: rbac.e2e.ts"
```

`claim` **fails** if someone else holds a live lease. That is not an obstacle to route around —
pick a different handoff, or tell the user who holds it. Never edit a handoff doc you do not
hold the lease for (the hooks block it).

## Two types of handoff

Every doc carries a `type:` (absent ⇒ `coordination`, so legacy docs are unaffected):

| type | gate | lifecycle | listed as |
| --- | --- | --- | --- |
| `coordination` (default) | **claim before edit** — the lease gate blocks non-holders | `release --status open/blocked/done --verified-by` | Open work |
| `standalone` | **exempt** — freely editable, no lease needed | retire via `release --status done` (no `--verified-by`) | Standalone / reference |

A **standalone** handoff is a self-contained reference/knowledge doc — a porting guide, an eval
report, a session-compaction brief. It is not claimable work: `claim` refuses it, the `pretool-edit`
gate allows editing it without a lease, and it is listed apart so it is not mistaken for open work.

```bash
./handoff new port-guide --standalone --title "Porting guide"   # create a standalone doc
./handoff import ./NOTES.md --id notes --standalone              # bring an existing file onto the board
```

`import` copies a file in (never moves it), normalizing its frontmatter (`id/title/type/status/
created/updated`); if the source has no YAML frontmatter, a fresh block is prepended above the
content verbatim.

## How the lock works

- A lease is an atomic `mkdir` of `.locks/<id>/` — two agents racing cannot both win. (This is
  why ownership is _not_ stored in the doc's frontmatter: a frontmatter edit is read-modify-write
  and would let both claimants think they won.)
- Ownership lives **only** in `.locks/` (gitignored, machine-local). Durable state lives **only**
  in the doc's frontmatter. They cannot desync because neither duplicates the other.
- The lease records `session=<raw session id>` — the same id the tool puts in its hook payload.
  That equality is the whole basis of the enforcement gate.
- A lease expires after **4 hours** (`HANDOFF_TTL_HOURS`). Expired leases are **auto-reaped** at
  the start of every session, and an active session's leases are **auto-touched** on every edit,
  so a crashed session self-heals and a working one never expires mid-flight. `./handoff reap`
  and `./handoff touch <id>` remain as manual escape hatches.

## Fields

| Field                     | Meaning                                                                                                                                                                                                    |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `type`                    | `coordination` (default; lease-gated work item) or `standalone` (self-contained reference doc, gate-exempt). Absent ⇒ `coordination`. See "Two types of handoff".                                          |
| `status`                  | `open` (needs work) · `blocked` (waiting — see `blocked_on`) · `done` (verified, archived)                                                                                                                 |
| `audience`                | **Which repo acts next** (cross-repo topology only). An agent in `main-api` only claims `audience: main-api` docs. This, not the lock, is what keeps a backend and a frontend agent off each other's toes. |
| `repos`                   | Every repo the handoff touches (for search, and to scope `verify:`).                                                                                                                                       |
| `blocked_on`              | The handoff id (or `external: …`) this one is waiting on. When the blocker closes `done`, this handoff is surfaced as newly unblocked at the next session start.                                           |
| `updated` / `verified_at` | `verified_at` is a claim about the **live code**, not the doc. `release --status done` stamps it and requires `--verified-by`.                                                                             |
| `verify`                  | _(optional)_ a command that machine-checks "done". **Never auto-run** — see below.                                                                                                                         |

## Two rules that exist because trackers rot

1. **`done` means verified against the live code, not "the doc says resolved."** `release
--status done` **requires `--verified-by "<how>"`** — a test run, a `file:line`, an evidence
   string — recorded into `verified_at` and the Activity log. Trust-closing is disabled.
2. **INDEX.md is generated** (`./handoff index`) and must never be hand-edited. A hand-maintained
   tracker is exactly the thing that goes stale; the hooks regenerate it after every doc edit.

## Authoring a doc: redact, suggest, link

- **Redaction (docs are committed).** A handoff doc lives in the repo and its git history — a
  pasted secret persists there. Remove or redact any keys, API tokens, secrets, confidential data,
  passwords, or PII before saving. If the next agent genuinely needs a credential, do **not** paste
  it: leave a named placeholder, prompt the user, and suggest a safe channel (an environment
  variable, a secret-manager reference, or out-of-band) — record the variable/reference **name**,
  never the value. `handoff new` and `release --status done` print a reminder.
- **Suggested skills.** List the skills the next agent should invoke to pick the work up, so
  continuation starts on the right path.
- **Link, don't duplicate.** Reference existing artifacts (PRDs, plans, ADRs, issues, commits,
  diffs) by path or URL instead of pasting their content into the doc.

## `verify:` is safe by default

A doc may carry a `verify:` command as a machine gate for `done`. Because a cross-repo doc is
**untrusted** (you read it from a repo you did not write), the command is **never run
automatically**. `release --status done` prints it and relies on `--verified-by`. Auto-execution
requires BOTH `--run-verify` on the command line AND the install-time opt-in
`HANDOFF_ALLOW_VERIFY_CMD=1`, and even then only for a doc whose `repos:` names this repo.

## Layout

```
.agents/handoff/
├── handoff                 # the lease script
├── hooks.sh                # the enforcement hooks
├── config                  # TOPOLOGY + REPO_NAME (committed)
├── handoff-doc-template.md # scaffold for `handoff new`
├── README.md               # this file
├── INDEX.md                # GENERATED — never hand-edit
├── *.md                    # open + blocked handoffs
├── archive/*.md            # done / superseded
└── .locks/                 # live leases (gitignored)
```
