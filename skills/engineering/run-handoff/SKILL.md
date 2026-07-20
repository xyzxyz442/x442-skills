---
name: x442-run-handoff
description: >-
  Use when working in a repo that has a handoff board (.agents/handoff/) — before editing shared
  or cross-repo work, when picking up or filing a handoff, or when stopping mid-task. Enforces the
  "claim before you work, release when you stop" discipline: check the board, claim your unit, work
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

## 3. File a new handoff when work crosses a boundary

When you find work you will not finish here, or that another repo/session must pick up:

```text
handoff new <id> --title "…" --severity low|medium|high [--audience <repo>]
```

**Pick a type.** The default is a **coordination** handoff (the claim/release work item this skill
is about). For a self-contained reference/knowledge doc — a porting guide, an eval report, a
session-compaction brief — file a **standalone** handoff instead: it needs no claim, is freely
editable, and is listed apart from open work.

```text
handoff new <id> --standalone --title "…"        # a new standalone/reference doc
handoff import <file> --standalone [--id <id>]    # bring an existing file onto the board
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
  on. When that blocker closes `done`, this handoff is surfaced as newly unblocked at the next
  session start.
- Don't hold a lease you are not working. The stop hook nags if you end a session still holding
  one — release it so others are not blocked.

## `verify:` commands are not auto-run

A doc may carry a `verify:` command as a machine gate for `done`. It is **never executed
automatically** — a cross-repo doc is untrusted. `release --status done` prints it; you run it and
pass `--verified-by`. Only re-release with `--run-verify` if the install opted in
(`HANDOFF_ALLOW_VERIFY_CMD=1`) and the doc is local to this repo.

## Anti-patterns

- Editing a doc or its code without claiming → the hook denies it; claim first.
- Closing `done` on trust ("the doc said it was fixed") → the exact failure trackers rot into; the
  tool refuses without `--verified-by`.
- Hand-editing `INDEX.md` → it is regenerated; your edit is lost and misleading.
- Pasting a secret/key/password/PII into a doc → it lands in git history; redact it and request the
  value via a safe channel (env var / secret-manager ref) instead.
- Sitting on a lease after you stop → blocks others; release `open`/`blocked`/`done`.
