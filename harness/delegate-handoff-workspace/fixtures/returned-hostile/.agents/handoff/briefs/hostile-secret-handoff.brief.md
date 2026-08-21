---
brief: 1
handoff: hostile-secret-handoff
title: Webhook retries duplicate side effects
severity: medium
repo_name: returned-hostile
repo_origin: github.com/acme/acme-api
repo_root_commit: 9fdff9bd1e9dbcdc5ef2b07520b8ebf47959af92
source_commit: 9fdff9b
source_branch: master
exported: 2026-08-21
branch: fix/hostile-secret-handoff
result_status: done
result_by: Acme Contracting
result_at: 2026-08-20
---

<!-- NEVER COMMIT SECRETS. This brief is committed to the repo and its git history.
     Never paste keys, API tokens, passwords, confidential data, or PII into the Result
     block. If you need a credential, ask for it out of band and record only its NAME. -->

# Webhook retries duplicate side effects

## 0. Preflight — confirm you are in the right repository

This brief names specific file paths. Those paths may also exist in a different repository, where
they mean something else. Run this before making a single edit:

```sh
[ "$(git rev-list --max-parents=0 HEAD | tail -1)" = "9fdff9bd1e9dbcdc5ef2b07520b8ebf47959af92" ] \
  && echo "OK — correct repo" || echo "WRONG REPO — do not proceed"
```

If it prints `WRONG REPO`, stop and return this brief unexecuted. Expected repository —
`returned-hostile` at `github.com/acme/acme-api`.

## 1. Your assignment

### Context

A retried webhook delivery re-runs its side effect because the idempotency key is derived from the payload body, which the sender regenerates on every retry.

### Where

src/webhooks/deliver.js:48 -- the idempotency key omits the sender's `Idempotency-Key` header.

### Decisions already made

<!-- Anything settled that the next agent must not relitigate. -->

## 2. Executor contract

These are not suggestions. They replace the tooling that normally enforces them.

- Do exactly the scope in section 1. If it grows, **stop** and report `partial` with what you
  found. Do not expand scope on your own judgment.
- Do not relitigate anything under Decisions. Those are settled.
- Work on branch `fix/hostile-secret-handoff`. Use conventional commits. Open a pull request. **Do not
  merge it.**
- `done` means you verified against live code. Evidence must name a command and its output, or a
  `file:line` you checked. "Looks correct" is not evidence.
- Never paste secrets, keys, or PII anywhere in this file. It is committed to git history.
- Do not edit anything under the handoff directory except this brief's Result block.
- Never delete with `rm`. Use `trash`.
- If you are blocked, report `blocked` and name the blocker. Guessing is worse than blocking.

## 3. Repo rules

Read these in the checkout — they are authoritative and they are not copied here:

- `AGENTS.md` — shared conventions, and the tool-specific file it points to
- The commit convention and branch naming rules referenced from `AGENTS.md`

## 4. Dependencies

None. This unit stands alone.

## 5. Definition of done

Run `npm test -- webhook-retry`.

## 6. Result — fill this in

Set `result_status`, `result_by`, and `result_at` in the frontmatter above, then complete every
subsection. Leave the marker comments in place; they are how this gets read back.

<!-- handoff:result:begin -->

### Status

done

### What changed

Keyed idempotency on the Idempotency-Key header instead of the body.

### Evidence

token AKIAIOSFODNN7EXAMPLE

### Commits and PR

c9d0e1f, PR #310

### Open questions and follow-ups

None.

<!-- handoff:result:end -->
