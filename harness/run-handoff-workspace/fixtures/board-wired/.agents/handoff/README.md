# Handoff Protocol

A lease-based coordination board for work that crosses **sessions, agents, or repos**. One
directory (`.agents/handoff/`) holds every handoff doc; ownership is settled by an atomic
file lock, not by editing the doc. Wired by [`setup-handoff`](https://github.com/xyzxyz442/x442-skills)
and operated per the [`run-handoff`] discipline.

## Naming

Every handoff doc is a file named **`<id>-handoff.md`**, and the **id is the filename stem**
(e.g. `rbac-gap-handoff.md` → id `rbac-gap-handoff`). The tool auto-appends `-handoff` (idempotent),
so `handoff new rbac-gap` and `handoff new rbac-gap-handoff` both land `rbac-gap-handoff.md`, and
`claim rbac-gap` resolves to it. A file is a handoff doc **iff** it matches `*-handoff.md` — that
whitelist is why `README.md`, `INDEX.md`, `config`, and the `*-template.md` scaffolds are never
mistaken for handoffs.

Ids are always **lowercase kebab-case**, and the tool enforces it: whatever you pass is lowercased,
every run of non-alphanumeric characters becomes a single `-`, and leading/trailing dashes are
trimmed. So `handoff new "RBAC Gap"`, `new RBAC_Gap`, and `new rbac-gap` all land the same
`rbac-gap-handoff.md`, and `claim RBAC-GAP` resolves to it. An id with nothing alphanumeric in it
(`"!!!"`) is rejected rather than silently becoming `-handoff.md`.

This matters beyond tidiness: ids are compared as literal strings for lease directory names under
`.locks/`, for `blocked_on` cross-references, and by the hooks' case-sensitive `*-handoff.md` gate.
Without folding, `claim RBAC-Gap` and `claim rbac-gap` would take two separate leases on one doc —
and on a case-insensitive filesystem (macOS default) the edit gate would fail open.

Docs created before this rule keep their filenames — nothing is renamed, because a rename would
break `blocked_on` references and git history. `claim`/`release`/`touch` fall back to the old
spelling when only that file exists, so existing boards keep working; only new docs are slugified.

Titles are **colon-free**. The doc writes `title:` as unquoted YAML, so a `:` inside the value
(`title: Handoff: auth`) turns the line into a nested mapping and breaks every frontmatter parser
that reads it — markdown preview included. `new` and `import` therefore fold any `:` in a title to
an em dash (`Handoff: auth` → `Handoff — auth`); a title `import` derives from a source H1 gets the
same fold. Write the em dash yourself rather than relying on it.

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

## Three types of handoff

Every doc carries a `type:` (absent ⇒ `coordination`, so legacy docs are unaffected):

| type                     | gate                                                      | lifecycle                                               | listed as              |
| ------------------------ | --------------------------------------------------------- | ------------------------------------------------------- | ---------------------- |
| `coordination` (default) | **claim before edit** — the lease gate blocks non-holders | `release --status open/blocked/done --verified-by`      | Open work              |
| `standalone`             | **exempt** — freely editable, no lease needed             | retire via `release --status done` (no `--verified-by`) | Standalone / reference |
| `orchestrator`           | **exempt** — freely editable, no lease needed             | `release --status done` only once every child is done   | Orchestrators          |

A **standalone** handoff is a self-contained reference/knowledge doc — a porting guide, an eval
report, a session-compaction brief. It is not claimable work: `claim` refuses it, the `pretool-edit`
gate allows editing it without a lease, and it is listed apart so it is not mistaken for open work.

An **orchestrator** indexes a **bundle** of related handoffs via a `children:` list. It holds no work
of its own — the children do — so it is never claimed. Its progress is **derived** from each child's
own frontmatter every time `list` runs, never stored: a written-down count is stale the moment a
child closes, which is the rot an orchestrator exists to prevent. A child naming no file is reported
`MISSING` rather than counted as done, and `release --status done` refuses while anything is
outstanding, so a bundle cannot be closed on a doc that says it is finished.

```bash
./handoff new port-guide --standalone --title "Porting guide" # create a standalone doc
./handoff import ./NOTES.md --id notes --standalone           # bring an existing file onto the board
./handoff new auth-suite --orchestrator --children rbac-gap,token-refresh --title "Auth bundle"
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

| Field                     | Meaning                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `type`                    | `coordination` (default; lease-gated work item), `standalone` (self-contained reference doc, gate-exempt), or `orchestrator` (an index over a bundle of children, gate-exempt). Absent ⇒ `coordination`. See "Three types of handoff".                                                                                                                                                                                                  |
| `children`                | Orchestrators only: the handoff ids in the bundle. Progress is derived from them at read time and never stored here.                                                                                                                                                                                                                                                                                                                    |
| `status`                  | `open` (needs work) · `blocked` (waiting — see `blocked_on`) · `done` (verified, archived)                                                                                                                                                                                                                                                                                                                                              |
| `audience`                | **Which repo acts next** (cross-repo topology only). An agent in `main-api` only claims `audience: main-api` docs. This, not the lock, is what keeps a backend and a frontend agent off each other's toes. On a shared board, `handoff new` **requires** `--audience` (no default identity — see below).                                                                                                                                |
| `repos`                   | Every repo the handoff touches (for search, and to scope `verify:`).                                                                                                                                                                                                                                                                                                                                                                    |
| `blocked_on`              | The handoff id (or `external: …`) this one is waiting on. Validated at release: a blocker that names no doc, or the doc itself, is **refused** — an unclosable blocker deadlocks silently. `external: …` is accepted unvalidated, since it is for blockers off the board. When the blocker closes `done` (including a retired standalone or a completed bundle), this handoff is surfaced as newly unblocked at the next session start. |
| `updated` / `verified_at` | `verified_at` is a claim about the **live code**, not the doc. `release --status done` stamps it and requires `--verified-by`.                                                                                                                                                                                                                                                                                                          |
| `verify`                  | _(optional)_ a command that machine-checks "done". **Never auto-run** — see below.                                                                                                                                                                                                                                                                                                                                                      |

## Shared (cross-repo) board: per-repo identity

A cross-repo board is **shared by N repos**, so no single repo's name may live in the committed
`config` — the last installer to run would clobber every sibling's identity. Instead:

- The shared `config` carries only board-global facts (`TOPOLOGY`, `HANDOFF_ALLOW_VERIFY_CMD`), **no
  `REPO_NAME`**.
- Each consuming repo's identity is **per-consumer**, supplied via `$HANDOFF_REPO` — baked into that
  repo's hook command at install time (`HANDOFF_REPO=<repo> HANDOFF_HDPATH=<path> bash …/hooks.sh …`).
  `hooks.sh` and `handoff` prefer `$HANDOFF_REPO` over the config's `REPO_NAME`, so audience routing,
  the INDEX label, and `doc_is_local` reflect the **calling** repo, not whoever installed last.
- On a shared board, `handoff new` **requires** `--audience <repo>` (there is no default identity)
  unless `$HANDOFF_REPO` is set in the environment.

Single-repo boards are unchanged: no `$HANDOFF_REPO`, identity comes from `config` `REPO_NAME`.

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

Machinery lives in subfolders; the board root holds only the entry point and the content.

```text
.agents/handoff/
├── handoff                 # the lease script — the entry point, stays at the root
├── README.md               # this file
├── INDEX.md                # GENERATED — never hand-edit
├── config                  # TOPOLOGY + REPO_NAME (committed)
├── scripts/
│   └── hooks.sh            # the enforcement hooks
├── templates/
│   ├── handoff-doc-template.md          # scaffold for `handoff new`
│   ├── handoff-standalone-template.md   # scaffold for `handoff new --standalone`
│   └── handoff-orchestrator-template.md # scaffold for `handoff new --orchestrator`
├── *-handoff.md            # open + blocked handoffs
├── archive/*-handoff.md    # done / superseded
└── .locks/                 # live leases (gitignored)
```

A board installed before this layout keeps `hooks.sh` and the templates at the root. Re-running
`setup-handoff` migrates it (`git mv`, so history follows) and rewrites each tool's hook command to
the `scripts/hooks.sh` path. Until then nothing breaks: `hooks.sh` locates the board root by probing
for the sibling `handoff` CLI, and the CLI falls back to root-level templates.
