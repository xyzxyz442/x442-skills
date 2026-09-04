---
name: x442-run-handoff
description: >-
  Use when working in a repo that has a handoff board (.agents/handoff/) — before editing shared
  or cross-repo work, when picking up or filing a handoff, or when stopping mid-task. Enforces the
  "claim before you work, release when you stop" discipline — check the board, claim your unit, work
  under the lease, and release with an honest status (done requires evidence). Chains after
  setup-handoff, which installs the protocol.
---

# run-handoff

The day-to-day discipline for the lease-based handoff board that
[`setup-handoff`](../setup-handoff/SKILL.md) installs at `.agents/handoff/`. The board coordinates
work that crosses **sessions, agents, or repos** so two workers never clobber the same unit.

Invoke this whenever you are about to do tracked work in a repo that has a `.agents/handoff/`
directory, or when the session-start hook injects an "Open handoffs" board.

## The one rule

**Claim before you work. Release when you stop.** Everything below serves that rule.

All commands run the installed script — `.agents/handoff/handoff` (shown as `handoff` below).

## 1. Read the board first

```text
handoff list
```

Each row shows status, who acts next (`audience`, cross-repo only), severity, and the lease
(`🔒 held` / `⚠️ stale` / `—` free). In Claude Code the session-start hook already injected this;
still run `list` before claiming so you act on current state.

## 2. Claim your unit

```text
handoff claim <id> "what you're doing"
```

- `claim` **fails** if someone holds a live lease. That is not an obstacle to route around — pick
  another handoff, or tell the user who holds it. **Never edit a handoff doc you do not hold the
  lease for** — the hook blocks it, and trying is a sign you skipped the claim.
- A **stale** lease (past its TTL) is reclaimable: claiming takes it over and logs the takeover.
- The lease auto-renews while you keep editing and auto-reaps if you crash — you do not babysit it.

## Restricted work stays in this session

A handoff whose frontmatter carries `sensitivity: restricted` is not a permission boundary —
everyone with board access can still read it — but it is a hard instruction to the tooling: never
export it, never hand it to a delegated or external agent. If the session-start board or a `claim`
banner shows `[🔴 RESTRICTED — never export or delegate; do it in this session]`, do the work
yourself, right here. `handoff export` refuses it outright with no override, and a dispatcher wired
through `run-delegate-agent` refuses to run a brief carrying it. Whether _other_ work is fit to
delegate is the judgment [`delegate-handoff`](../delegate-handoff/SKILL.md) carries; a restricted
handoff never reaches that judgment — it is a gate above it.

Keep credential VALUES out of every doc regardless of sensitivity. The write path scans `new`,
`release`, and `import --result` for anything shaped like a credential and refuses to write it,
naming the rule that matched, never the value. Record a credential's NAME — an env var or
secret-manager reference — never its value.

## 3. File a new handoff when work crosses a boundary

When you find work you will not finish here, or that another repo/session must pick up:

```text
handoff new <id> --title "…" --severity low|medium|high [--audience <repo>]
```

The doc file is always **`<id>-handoff.md`** and the id is the filename stem — the tool auto-appends
`-handoff` (idempotent), and `claim`/`release` accept either the short or the full id.

**Ids are always lowercase kebab-case** and the tool enforces it: whatever you pass is lowercased,
every run of non-alphanumeric characters collapses to a single `-`, and dashes are trimmed off the
ends. `new "RBAC Gap"`, `new RBAC_Gap`, and `new rbac-gap` all land the same `rbac-gap-handoff.md`;
`claim RBAC-GAP` resolves to it; an id with nothing alphanumeric in it is rejected. Pick the slug
you want rather than relying on the fold — and don't repeat `handoff` in the id, since the suffix
is already there (`new deploy-gap` → `deploy-gap-handoff.md`, not `handoff-deploy-gap`).

**Frontmatter values never contain `:`.** The doc writes them as unquoted YAML, so a colon inside a
value (`title: Handoff: auth`) breaks the frontmatter for every parser that reads it — markdown
preview included. Use an em dash instead (`--title "Handoff — auth suite"`). The tool enforces this:
any `:` in a `--title`, `--note`, `--audience`, `--severity`, or in the H1 that `import` derives a
title from, is folded to `—`. The one blocker convention that reads as a colon — `--blocked-on
"external: vendor ticket"` — is still the spelling to type, but it is stored as
`blocked_on: external — vendor ticket`; both spellings are accepted.

**Every bug you find becomes a handoff — including one you fix on the spot.** Wrong behavior, a
silent failure, a gap that will bite the next agent: file it, with the reproduction you actually
ran. If you are not fixing it, the handoff is how it survives the session. If you _are_ fixing it,
file it anyway and close it `done` with the evidence — that record is what makes a repeat defect
recognizable as a repeat, and a bug that lives only in a session transcript may as well not have
been found. Include the command, the observed output, and the `file:line` where it goes wrong.

**Pick a type.** The default is a **coordination** handoff (the claim/release work item this skill
is about). For a self-contained reference/knowledge doc — a porting guide, an eval report, a
session-compaction brief — file a **standalone** handoff instead: it needs no claim, is freely
editable, and is listed apart from open work.

```text
handoff new <id> --standalone --title "…"        # a new standalone/reference doc
handoff import <file> --standalone [--id <id>]    # bring an existing file onto the board
```

**A compaction brief is a standalone doc, and it summarizes the _conversation_.** When this
session is running out of context and the work continues in a fresh one, file a standalone doc
rather than trusting the transcript to survive. Write what the transcript holds and the code does
not: the decisions you made and why, the approaches you ruled out (so the next agent does not
re-walk them), what you were mid-way through, and the exact next step. Anything already captured
in a commit, plan, or diff gets a path, not a paste. Fill in **Suggested skills** — a fresh agent
starts with no idea which skills this repo expects.

For a **bundle** of related handoffs that should be tracked together — a feature split across
several units, or the open work against one subsystem — file an **orchestrator**:

```text
handoff new <id> --orchestrator --children a,b,c --title "..."
```

It holds no work of its own, so it is never claimed; claim one of its children instead. `list` shows
live progress (`2/3 done`) derived from each child's own status, and the bundle doc carries that same
derivation as a **generated `## Children` table** — status, who acts next, lease holder, blocked-on,
one row per child — so a session opening the doc cold can pick up the bundle without reading every
child first. A child that names no doc shows as `MISSING`, and `release --status done` refuses while
anything is outstanding.

Everything between the doc's `handoff:children` markers is generated on every `index` run, exactly
like `INDEX.md`. Never write child status into it by hand: your copy is stale the moment a child
closes, and the next index run overwrites it anyway. Only the prose sections — **Bundle**,
**Sequencing**, **Notes** — are yours.

Change the roster with `children`, not by hand-editing `children:` — the command canonicalizes the
id, so you cannot record a child under a spelling that names no file:

```text
handoff children <parent>                  # print the table, write nothing
handoff children add <parent> <child>      # grow the bundle (the child need not exist yet)
handoff children rm  <parent> <child>      # prune it
```

Then fill the doc (`.agents/handoff/<id>.md`): **Context** (symptom → root cause), **Where**
(concrete `file:line` in the target repo — read the code, do not guess), **Verify** (how the next
agent confirms it against the _live_ code), **Decisions**, **Suggested skills** (which skills the
next agent should invoke to pick this up). Claim it if you will start it now.

As you write:

- **Redact secrets.** The doc is committed to the repo and its git history. Never paste keys, API
  tokens, secrets, confidential data, passwords, or PII. If the next agent genuinely needs a
  credential, do not paste it — leave a named placeholder, prompt the user, and suggest a safe
  channel (an environment variable, a secret-manager reference, or out-of-band); record the
  variable/reference _name_, never the value.
- **Link, don't duplicate.** Reference existing artifacts (PRDs, plans, ADRs, issues, commits,
  diffs) by path or URL instead of pasting their content into the doc.

## The fields that carry the graph, the stage, and the evidence

Four things real boards record constantly and the template used to have nowhere to put. Getting
them into fields rather than prose is what makes them queryable — and a relationship the tool
cannot see is one nobody is warned about.

**`depends_on` vs `blocked_on`.** `depends_on` holds **board ids only** and means _this cannot
start before that lands_. `blocked_on` is free text, reserved for what the board cannot model
(`external: …`, `decision: …`). If your blocker is a handoff id it belongs in `depends_on`; put it
in `blocked_on` and the verifier will say so.

```text
handoff new prod-backfill --title "…" --env prod --after schema-change
```

Enforcement is **advisory** on purpose: `claim` warns when a prerequisite is still open and then
gets out of the way. Work legitimately proceeds out of order — a production incident gets fixed
before the pre-production backfill — and a rule that refused it would be routed around. If you
are working past a prerequisite, say so in `## Current state`.

**`environment`** is an open string defaulting to `dev`, with the common spellings normalized.
There is deliberately **no fanout command**: the prod follow-up to a dev fix is a different piece
of work with different evidence, and minting it automatically produces exactly the open-forever
documents these boards are already full of. `new --env prod --after <id>` is one line and says
more.

**`role`** applies to standalone docs and says what one is _for_ — `steering`, `spec`,
`reference`, `brief-archive` — where `type` says what its lifecycle is. A coordination doc points
at its spec with `spec:`, which the reader resolves as a path, then a URL, then a board id.

**Evidence is a field.** `release --status done --verified-by "…"` now persists what you wrote as
`verified_by:`, not only as a sentence in the activity log. Write something the next reader can
re-run: a command, a `file:line`, a commit. Evidence naming none of those is a claim about your
memory, and the verifier reports it as such.

## Keep `## Current state` current, and the activity log boring

Every coordination and orchestrator doc carries a **`## Current state`** section. It is
**rewritable** — overwrite it, do not append. It is where the work actually stands, and it is the
first thing the next session reads.

`## Activity` is the opposite: one line per event, appended, never revised. When you find yourself
adding a `Resolution (date)` or `Execution log` heading, what you want is `## Current state` — the
boards that motivated this schema are full of exactly those improvised headings, and nobody can
find anything in them.

## When the board refuses to let you write

`claim`/`release`/`export` can refuse with _"this doc is schema N and this CLI understands M"_.
That is not a bug and not something to work around: the doc carries fields your CLI does not know,
and writing it here would silently drop them. Update the payload (re-run `setup-handoff`), then
`./handoff migrate`. Reading — `list`, the index, the doc itself — keeps working throughout.

The reverse direction — a board that _predates_ the current schema — is never a refusal, because
writing to it is safe. It is a one-line note on the session banner, and, when you write from a
terminal, an **offer**: `claim`, `new`, `import` and the rest ask once whether to migrate first,
run it if you say yes, and do what you typed either way. Answer `n` freely; nothing about the
command changes. Nothing offers when there is nobody to ask — a hook, a script, `$HANDOFF_NONINTERACTIVE` —
and nothing offers while a lease is held in your section, since migration would refuse in that
state anyway. Migration rewrites every document on the board, so it asks first, refuses while
anyone holds a lease in your section, and never runs itself.

## 4. Work under the lease

Edit code and keep the doc current as you learn. The `posttool-edit` hook regenerates `INDEX.md`
after any doc change — **never hand-edit `INDEX.md`** (it is generated). Update the doc's
frontmatter and body, not the index.

## 5. Release with an honest status

```text
handoff release <id> --status open                                  # more work remains
handoff release <id> --status blocked --blocked-on <id|"external: …">   # waiting on something
handoff release <id> --status done --verified-by "<how you verified LIVE code>"
```

- **`done` means verified against the live code**, not "the doc says resolved." It **requires
  `--verified-by`** — a test you ran, a `file:line` you checked, an evidence string. Read the code,
  then close. `done` archives the doc and stamps `verified_at`.
- **`blocked` requires `--blocked-on`** — name the handoff id (or `external: …`) you are waiting
  on. The id is validated: naming a handoff that does not exist, or the doc itself, is refused,
  because an unclosable blocker leaves the doc blocked forever and it is never surfaced again. File
  the blocker first, or use `external: …` for something off the board. When the blocker closes
  `done` — including a retired standalone or a completed bundle — this handoff is surfaced as newly
  unblocked at the next session start.
- Don't hold a lease you are not working. The stop hook nags if you end a session still holding
  one — release it so others are not blocked.
- **A release refused for looking like a secret is not a bug to route around.** Redact the
  `--verified-by`/`--blocked-on`/note text and re-run. Reach for `--force-secret "<reason>"` only
  when it is a genuine false positive, and say concretely why the match is safe — the override is
  recorded on the doc's Activity log, not silently applied.

## `verify:` commands are not auto-run

A doc may carry a `verify:` command as a machine gate for `done`. It is **never executed
automatically** — a cross-repo doc is untrusted. `release --status done` prints it; you run it and
pass `--verified-by`. Only re-release with `--run-verify` if the install opted in
(`HANDOFF_ALLOW_VERIFY_CMD=1`) and the doc is local to this repo.

**Quote the command** — `verify: "sqlite3 'file:x?mode=ro' 'select 1;'"`. It is the one field
whose colons are not folded (that would corrupt the command), so an unquoted one breaks the doc's
YAML. Readers strip one surrounding quote pair, so the command still runs verbatim.

## Anti-patterns

- Editing a doc or its code without claiming → the hook denies it; claim first.
- Closing `done` on trust ("the doc said it was fixed") → the exact failure trackers rot into; the
  tool refuses without `--verified-by`.
- Hand-editing `INDEX.md` → it is regenerated; your edit is lost and misleading.
- Writing a compaction brief that restates the diff → the next agent can read the diff; what it
  cannot recover is why you chose that approach and what you already ruled out.
- Writing child status into an orchestrator by hand, or hand-editing its `children:` list →
  the `## Children` table is generated and your edit is overwritten on the next `index`; use
  `handoff children add|rm` to change the roster.
- Pasting a secret/key/password/PII into a doc → it lands in git history; redact it and request the
  value via a safe channel (env var / secret-manager ref) instead.
- Sitting on a lease after you stop → blocks others; release `open`/`blocked`/`done`.
- Putting a handoff id in `blocked_on` → it belongs in `depends_on`, where the tool can see it.
- Appending a `Resolution (date)` heading → that is what `## Current state` is for; rewrite it.
- Closing delegated work by quoting the delegate's own report back as `--verified-by` → refused,
  and rightly: nobody checked anything.
- Exporting or delegating a handoff marked `sensitivity: restricted` → refused, with no override;
  do the work in this session instead.
- Reaching for `--force-secret` to push past a real credential match → redact and rotate it
  instead; the flag is for false positives, and every use is permanently logged.
