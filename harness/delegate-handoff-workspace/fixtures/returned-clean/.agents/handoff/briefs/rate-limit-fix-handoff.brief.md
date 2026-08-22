---
brief: 1
handoff: rate-limit-fix-handoff
title: Rate limiter drops burst requests
severity: medium
repo_name: returned-clean
repo_provider: github
repo_origin: acme/acme-api
repo_root_commit: e06d53b95cffa6b52b5d67aabb6a2d83bec66410
source_commit: e06d53b
source_branch: master
exported: 2026-08-21
branch: fix/rate-limit-fix-handoff
result_status: done
result_by: Acme Contracting
result_at: 2026-08-20
---

<!-- NEVER COMMIT SECRETS. This brief is committed to the repo and its git history.
     Never paste keys, API tokens, passwords, confidential data, or PII into the Result
     block. If you need a credential, ask for it out of band and record only its NAME. -->

# Rate limiter drops burst requests

## 0. Preflight — confirm you are in the right repository

This brief names specific file paths. Those paths may also exist in a different repository, where
they mean something else. Run this before making a single edit:

```sh
[ "$(git rev-list --max-parents=0 HEAD | tail -1)" = "e06d53b95cffa6b52b5d67aabb6a2d83bec66410" ] \
  && echo "OK — correct repo" || echo "WRONG REPO — do not proceed"
```

If it prints `WRONG REPO`, stop and return this brief unexecuted. Expected repository —
`returned-clean` at `github.com/acme/acme-api`.

## 1. Your assignment

### Context

The token-bucket refill math undercounts elapsed time, so short legitimate bursts under 20 req/s return 429 instead of succeeding.

### Where

src/ratelimit/bucket.js:27 -- `refill()` truncates the elapsed-ms division instead of rounding.

### Decisions already made

<!-- Anything settled that the next agent must not relitigate. -->

## 2. Executor contract

These are not suggestions. They replace the tooling that normally enforces them.

- Do exactly the scope in section 1. If it grows, **stop** and report `partial` with what you
  found. Do not expand scope on your own judgment.
- Do not relitigate anything under Decisions. Those are settled.
- Work on branch `fix/rate-limit-fix-handoff`. Use conventional commits. Open a pull request. **Do not
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

Run `npm test -- rate-limit`. The suite covers a 15 req/s burst that must not 429.

## 6. Result — fill this in

Set `result_status`, `result_by`, and `result_at` in the frontmatter above, then complete every
subsection. Leave the marker comments in place; they are how this gets read back.

<!-- handoff:result:begin -->

### Status

done

### What changed

Fixed the token-bucket refill math so bursts under 20 req/s no longer 429.

### Evidence

Ran npm test -- rate-limit; 9 passing.

### Commits and PR

a1b2c3d, PR #101

### Open questions and follow-ups

None.

<!-- handoff:result:end -->
