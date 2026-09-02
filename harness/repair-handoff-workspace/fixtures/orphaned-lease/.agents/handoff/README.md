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

Frontmatter values are **colon-free**. The doc writes them as unquoted YAML, so a `:` inside a value
(`title: Handoff: auth`) turns the line into a nested mapping and breaks every frontmatter parser
that reads it — markdown preview included. `new` and `import` therefore fold any `:` to an em dash
(`Handoff: auth` → `Handoff — auth`) in every free-text value they write: `title` (including one
derived from a source H1), `note`, `audience`, and `severity`. `release` folds `blocked_on` the same
way, so the documented `--blocked-on "external: vendor ticket"` is stored as
`external — vendor ticket` — type either spelling. Write the em dash yourself rather than relying on
the fold. Ids and children are unaffected: they are slugified, which strips colons already.

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

The bundle doc carries that derivation as a **generated children table**, so a session that opens it
cold can pick up the bundle without reading every child first — which child is next, who holds it,
what it is blocked on, which children are not filed yet:

```markdown
## Children

<!-- prettier-ignore-start -->
<!-- handoff:children:begin -->

**1/3 done.** Outstanding — token-refresh-handoff (open), audit-logs-handoff (MISSING)

| Child                                       | Status    | Acts next | Severity | Updated    | Blocked on | Lease         |
| ------------------------------------------- | --------- | --------- | -------- | ---------- | ---------- | ------------- |
| [RBAC gap](./archive/rbac-gap-handoff.md)   | `done`    | acme-api  | high     | 2026-03-04 | —          | —             |
| [Token refresh](./token-refresh-handoff.md) | `open`    | acme-lib  | medium   | 2026-03-06 | —          | 🔒 dana       |
| `audit-logs-handoff`                        | `MISSING` | —         | —        | —          | —          | not filed yet |

<!-- handoff:children:end -->
<!-- prettier-ignore-end -->
```

Everything between the markers is **generated**, exactly like `INDEX.md`: it is rebuilt from the
child docs on every `index` run — which every mutating command already triggers — so it cannot
drift, and a hand-edit inside the markers is overwritten on the next run. The `prettier-ignore`
pair is there because the generated table is unaligned markdown — without it, a repo that runs
prettier over its docs would re-align the table on every commit and the next `index` run would
un-align it again, churning forever on a bundle nobody touched. Only the doc's prose
sections (Bundle, Sequencing, Notes) are yours to write. An existing bundle doc gains the section
automatically on the next `index`, above its Activity log.

Change the roster with `children`, never by hand-editing `children:`: the command canonicalizes each
id the same way `--children` does, so a child recorded under a spelling that names no file — and
therefore reads `MISSING` for the bundle's whole life — is not a failure mode you can reach.

```bash
./handoff new port-guide --standalone --title "Porting guide" # create a standalone doc
./handoff import ./NOTES.md --id notes --standalone           # bring an existing file onto the board
./handoff new auth-suite --orchestrator --children rbac-gap,token-refresh --title "Auth bundle"
./handoff children auth-suite                  # print the table without writing anything
./handoff children add auth-suite audit-logs   # grow the bundle (the child need not exist yet)
./handoff children rm auth-suite token-refresh # prune it
```

`import` copies a file in (never moves it), normalizing its frontmatter (`id/title/type/status/
created/updated`); if the source has no YAML frontmatter, a fresh block is prepended above the
content verbatim.

## How the lock works

- A lease is an atomic `mkdir` of `.locks/<id>/` — two agents racing cannot both win. (This is
  why ownership is _not_ stored in the doc's frontmatter: a frontmatter edit is read-modify-write
  and would let both claimants think they won.)
- Ownership lives **only** in `.locks/`. Durable state lives **only** in the doc's frontmatter.
  They cannot desync because neither duplicates the other.
- The lease records `session=<raw session id>` — the same id the tool puts in its hook payload.
  That equality is the whole basis of the enforcement gate.
- A lease expires after **4 hours** (`HANDOFF_TTL_HOURS`). Expired leases are **auto-reaped** at
  the start of every session, and an active session's leases are **auto-touched** on every edit,
  so a crashed session self-heals and a working one never expires mid-flight. `./handoff reap`
  and `./handoff touch <id>` remain as manual escape hatches.

### On a board with a remote, the lock crosses machines

`mkdir` excludes every other process on **one** machine. What excludes the other machines is
`git push`, which is a compare-and-swap: `claim` writes the lease, commits it, and pushes, and a
rejected non-fast-forward push means somebody claimed first. That is real mutual exclusion with no
server, and the losing claim is undone rather than kept locally.

A board earns this by being **its own git repository with a remote**. Nothing changes on a board
without one: leases stay gitignored machine state, and no command touches the network.

| | Board with a remote | Local-only board |
| --- | --- | --- |
| `.locks/` | committed — shared state of record | gitignored — ephemeral machine state |
| `claim` | **strict**: fetches first, and refuses outright if the remote is unreachable | offline, as always |
| `release` | **optimistic**: commits and pushes, but a failed push is a warning and the release stands | offline, as always |
| every read (`list`, `index`, the edit gate) | offline and free | offline and free |
| lease expiry | stamped from the lease's **commit time** | stamped from the claiming machine's clock |

The asymmetry between `claim` and `release` is the design. A claim asserts something about the
future ("nobody else may work this"), and asserting that without seeing the other machines' leases
is not exclusion — it is a local file. A release records something that already happened, so
refusing it offline would strand a lease whose holder has already stopped.

Expiry is read from the commit rather than the file because two machines' clocks do not agree: a
claimer running an hour fast would otherwise hand every peer a lease that already looks expired.

One thing to watch: a board that gains a remote later is still gitignoring `.locks/`, and that
combination is silent — every claim commits, pushes, and reports success while carrying no lease.
The next `claim` removes the rule and says so; `verify-setup-handoff.sh` reports it too.

## Fields

| Field                                          | Meaning                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `type`                                         | `coordination` (default; lease-gated work item), `standalone` (self-contained reference doc, gate-exempt), or `orchestrator` (an index over a bundle of children, gate-exempt). Absent ⇒ `coordination`. See "Three types of handoff".                                                                                                                                                                                                                                                                                 |
| `children`                                     | Orchestrators only: the handoff ids in the bundle. Progress is derived from them at read time and never stored here. Change it with `handoff children add\|rm`, not by hand.                                                                                                                                                                                                                                                                                                                                           |
| `status`                                       | `open` (needs work) · `blocked` (waiting — see `blocked_on`) · `done` (verified, archived)                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `audience`                                     | **Which repo acts next** (cross-repo topology only). An agent in `main-api` only claims `audience: main-api` docs. This, not the lock, is what keeps a backend and a frontend agent off each other's toes. On a shared board, `handoff new` **requires** `--audience` (no default identity — see below).                                                                                                                                                                                                               |
| `repos`                                        | Every repo the handoff touches (for search, and to scope `verify:`). Absent or empty (`[]`, the template default) means "this repo's own doc"; naming other repos marks it foreign and blocks `--run-verify`. Flow (`[a, b]`) and block (`- a`) lists both count, and the match is on the whole name — `[api-gateway]` is not repo `api`.                                                                                                                                                                              |
| `blocked_on`                                   | The handoff id (or `external: …`) this one is waiting on. Validated at release: a blocker that names no doc, or the doc itself, is **refused** — an unclosable blocker deadlocks silently. `external: …` is accepted unvalidated, since it is for blockers off the board; it is stored colon-folded (`external — …`) to keep the frontmatter valid YAML. When the blocker closes `done` (including a retired standalone or a completed bundle), this handoff is surfaced as newly unblocked at the next session start. |
| `updated` / `verified_at`                      | `verified_at` is a claim about the **live code**, not the doc. `release --status done` stamps it and requires `--verified-by`.                                                                                                                                                                                                                                                                                                                                                                                         |
| `verify`                                       | _(optional)_ a command that machine-checks "done". **Never auto-run** — see below. **Quote it** — it is the one field whose colons are not folded, so an unquoted command breaks the doc's YAML; readers strip one surrounding quote pair.                                                                                                                                                                                                                                                                             |
| `delegated_to` / `delegated_at` / `brief`      | Written by `export`: who it went to, when, and the path to the rendered brief under `briefs/`. See "Delegating off-board".                                                                                                                                                                                                                                                                                                                                                                                             |
| `result_from` / `result_at` / `result_claimed` | Written by `import --result`: who reported back, when, and what they claimed (`done`/`partial`/`blocked`). A **claim**, not a verdict — `status` is untouched until a reviewer runs `release`.                                                                                                                                                                                                                                                                                                                         |
| `review`                                       | `pending` once `import --result` lands a report; cleared by `release`. Surfaces the doc as needing a reviewer's eyes rather than an executor's.                                                                                                                                                                                                                                                                                                                                                                        |

## Configuration

Settings resolve through four scopes, **nearest wins**:

```text
env  >  repo config.json  >  board config.json  >  built-in default
```

Environment is for **overrides** — a one-off run, debugging, CI. Normal operating configuration
belongs in a committed file, where it can be reviewed and where the whole team gets it.

**`<board>/config.json`** — board-global. On a shared board this file is read by every member repo,
so it must never carry any one repo's identity.

| Key              | Default         | Meaning                                                                |
| ---------------- | --------------- | ---------------------------------------------------------------------- |
| `topology`       | `"single-repo"` | `single-repo` or `cross-repo`. Structural; the installer owns it.      |
| `repoName`       | `""`            | This board's repo. Written for a single-repo board **only**.           |
| `groups`         | `[]`            | Sections a shared board hosts, as a JSON array.                        |
| `groupLayout`    | `""`            | `subfolder` or `prefix` — how each section is laid out.                |
| `ttlHours`       | `4`             | Hours a claim holds before it self-reaps.                              |
| `allowVerifyCmd` | `false`         | `true` lets `release --run-verify` execute a command from a local doc. |

**`<repo>/.agents/handoff.config.json`** — per-consumer, written only for cross-repo installs.

| Key         | Meaning                                                  |
| ----------- | -------------------------------------------------------- |
| `repo`      | This repo's identity on the board (its `audience` name). |
| `group`     | This repo's section, on a grouped board.                 |
| `boardPath` | Path from this repo to the shared board.                 |

**Environment overrides** keep the `HANDOFF_` prefix, so the two are never confused: a `HANDOFF_`
name always means "override this run", a camelCase key always means "configured". `HANDOFF_TTL_HOURS`,
`HANDOFF_ALLOW_VERIFY_CMD`, `HANDOFF_REPO`, `HANDOFF_GROUP`, `HANDOFF_GROUP_LAYOUT`.

Two keys behave differently on re-install, deliberately:

- **`ttlHours` is preserved.** Once you commit a value, re-running the installer keeps it. Lease
  policy is a team decision, not something an install should quietly revert.
- **`allowVerifyCmd` follows its `--allow-verify-cmd` flag** and is **not** preserved. It permits
  `release --run-verify` to execute a command out of a doc, and a security opt-in that nobody
  re-affirmed is not one worth inheriting.

JSON has no comments, which is why this table exists. The config is **parsed, never sourced** — on a
shared board it is written by every member's installer, so executing it would let one repo run shell
in its siblings' sessions.

## Shared (cross-repo) board: per-repo identity

A cross-repo board is **shared by N repos**, so no single repo's name may live in the board's
`config.json` — the last installer to run would clobber every sibling's identity. Instead each
consuming repo commits its own `.agents/handoff.config.json` (table above), and `hooks.sh` finds it
by resolving the calling repo: the `--project-dir` anchor in the hook command first, then the git
toplevel. Audience routing, the INDEX label, and `doc_is_local` therefore reflect the **calling**
repo, not whoever installed last.

On a shared board, `handoff new` **requires** `--audience <repo>` when no identity resolves.

Single-repo boards keep it simple: no repo config file at all, identity comes from the board's own
`repoName`.

## Two rules that exist because trackers rot

1. **`done` means verified against the live code, not "the doc says resolved."** `release
--status done` **requires `--verified-by "<how>"`** — a test run, a `file:line`, an evidence
   string — recorded into `verified_at` and the Activity log. Trust-closing is disabled.
2. **Generated state is generated** and must never be hand-edited: `INDEX.md`, and an
   orchestrator's `## Children` table between its `handoff:children` markers. Both are rebuilt by
   `./handoff index` from the docs' own frontmatter, and the hooks run it after every doc edit. A
   hand-maintained tracker is exactly the thing that goes stale.

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
`HANDOFF_ALLOW_VERIFY_CMD=1`, and even then only for a doc that belongs to this repo — `repos:`
absent or empty, or naming this repo outright. A doc scoped to other repos never auto-executes.

**Quote the command.** It is the one field the colon fold does not apply to — folding would
corrupt the command itself — so a command containing `:` (nearly all of them do) must be quoted
or the doc stops being valid YAML:

```yaml
verify: "sqlite3 'file:graph.db?mode=ro' 'select count(*) from embeddings;'"
```

Readers strip one surrounding quote pair, so the command still reaches the shell verbatim. An
unquoted command keeps working, but only for tools that read frontmatter the way this board does;
a strict parser (markdown preview included) rejects the whole doc.

## Delegating off-board

Every command above assumes the person doing the work has this board — leases, hooks, skills, all
of it. `export`/`import --result` are for when they do not: a contractor, a junior engineer,
another team, or an AI tool with no `.agents/handoff/` installed. The judgment for when a handoff
is ready to leave and how to review what comes back lives in the `delegate-handoff` skill, not
here; this section documents the mechanics the CLI enforces.

```bash
./handoff export rbac-gap --to "a contractor" --branch fix/rbac-gap
#   ... they pull the branch, do the work, fill in the Result block, open a PR ...
./handoff import --result briefs/rbac-gap-handoff.brief.md
./handoff release rbac-gap --status done --verified-by "reproduced their fix: e2e green"
```

**`export <id>`** claims the id (unless `--no-claim`), stamps `delegated_to`/`delegated_at`/
`brief` on the doc, and renders `briefs/<id>.brief.md` — a single self-contained markdown file
carrying:

- a **preflight** the executor runs before touching anything, checking their checkout's root
  commit against the one recorded at export time, so a brief naming `src/auth/tenant.ts:88` can
  never silently land against the wrong repository's file at that path;
- the assignment itself — Context, Where, Decisions, Verify — copied from the doc;
- an **executor contract** inlining the scope discipline, evidence requirements, secret redaction,
  and no-`rm` rule that the missing hooks and skills would otherwise carry;
- an empty **Result** block bounded by `<!-- handoff:result:begin/end -->` markers, with
  `result_status`, `result_by`, `result_at` left blank in the frontmatter for the executor to fill.

Refuses on a `standalone` handoff (send the file — it is already self-contained) and on one
already `done` (nothing left to delegate). On an `orchestrator` it renders one cover brief with the
Sequencing section plus one brief per child.

A lease **this session already holds** is extended rather than re-claimed, so `claim X` then
`export X` works and ends with the full TTL a fresh claim would have given. A lease held by
**another** session still refuses — and on a bundle it refuses the whole export before anything is
written, rather than stranding half the children claimed and stamped.

**Repo identity on a grouped board.** When a handoff's `audience` names a repo other than the one
`export` runs in, the target is resolved through `<board>/repos.json` — the projection of the
group manifest that `register-cross-repo-handoff`'s sync writes, where each member carries its path
(relative to the board) and its root commit as an attestation. `export` reads the live root commit
at that path and records identity only when the two agree; a stale entry, a missing registry, an
undeclared or doubly-claimed audience, or an unreachable checkout each degrade to
`repo_root_commit: unverified` with a warning naming the cause. It never matches an audience
against a directory name. `repos.json` is generated — fix the manifest and re-sync, do not edit it.

**Commit the brief** before telling the executor — they pull it from the branch, they are not
attached a file out of band. `export` prints a reminder to redact anything that should not enter
git history before that commit.

**`import --result <brief>`** reads the executor's filled-in brief back. It refuses, in order: an
unrecognized `brief:` format version; a `repo_root_commit` that does not match this checkout
(`unverified` requires `--force-repo` and your own manual confirmation); an id that does not
resolve to a live handoff; a missing or invalid `result_status`; a Result block still holding only
the template's placeholder comments; a Result whose text matches the shape of a committed
credential; and a target doc that was never delegated, or whose `brief:` pointer names a different
file — stops a stray or hand-edited `handoff:` id from stamping a result onto a doc that was never
exported. Passing all of those, it splices the Result under `## Result (reported)` — replacing
on re-import rather than duplicating — and stamps `result_from`, `result_at`, `result_claimed`,
and `review: pending`.

**It never writes `status`.** Not for `done`, not even for `blocked`, which still needs a reviewer
to supply a validated `--blocked-on`. `result_claimed` sits in the frontmatter next to a `status`
field it did not touch, precisely so nobody mistakes an executor's account for a verdict.
`release --status done --verified-by "..."` remains the only way this handoff closes, same as
every other handoff on the board — the reviewer runs it after reproducing the evidence themselves,
not after reading that someone else claims to have done so.

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
│   ├── handoff-orchestrator-template.md # scaffold for `handoff new --orchestrator`
│   └── handoff-brief-template.md        # scaffold for `handoff export`
├── *-handoff.md            # open + blocked handoffs
├── archive/*-handoff.md    # done / superseded
├── briefs/*.brief.md       # rendered by `export`, committed for the executor to pull
└── .locks/                 # live leases (gitignored)
```

A board installed before this layout keeps `hooks.sh` and the templates at the root. Re-running
`setup-handoff` migrates it (`git mv`, so history follows) and rewrites each tool's hook command to
the `scripts/hooks.sh` path. Until then nothing breaks: `hooks.sh` locates the board root by probing
for the sibling `handoff` CLI, and the CLI falls back to root-level templates.
