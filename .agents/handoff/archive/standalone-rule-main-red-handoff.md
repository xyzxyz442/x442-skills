---
id: standalone-rule-main-red-handoff
title: Standalone rule fails on main — foreign names in the config-scopes docs
type: coordination
status: done
audience:
repos: []
severity: medium
created: 2026-08-22
updated: 2026-08-22
note:
verified_at: 2026-08-22
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

`scripts/verify-standalone.sh` failed on `main`. Five violations, all in two documents committed by
`ce4a9ec` (the handoff-config-scopes plan and spec). They named real foreign projects in example
config, and one snippet used a relative path escaping to a sibling `board/` directory.

CI runs this check across the whole repo, so `main` was red. The pre-commit hook only scans
**staged** files, which is why the violations were committed without anyone noticing — the hook
could not see the problem it was installed to prevent.

Found during the close-out of the offline-delegation work, which is unrelated to these documents.

## Where

- `docs/superpowers/plans/2026-08-21-handoff-config-scopes.md:607` — a path escaping to a sibling `board/` directory
- `docs/superpowers/specs/2026-08-21-handoff-config-scopes-design.md:81, 91, 183`

## Verify

```text
bash scripts/verify-standalone.sh
```

Must report `[PASS]` across every tracked file, not only staged ones.

## Decisions

- The escape hatch (`standalone-ok-next-line`) does **not** apply here. It exists for citing an
  upstream name where the citation is the point. These were ordinary examples that leaked real
  names, so they were replaced rather than exempted.
- Both leaked names were already on `scripts/standalone-denylist.txt`, so no denylist entry was
  added. `board` is not a foreign project — that line failed the `escaping` check for pointing
  outside the repo, and became `../workspace/`.
- Replacements keep each document's meaning: a group name became `acme-svcs`, a workspace path
  became `../workspace/src/...`, and one prose reference became "a shared cross-repo one".

## Suggested skills

None specific. Note the gap this exposed — the pre-commit hook scans staged files only, so a
whole-repo `verify-standalone.sh` run belongs in CI or in a pre-push hook, not just at commit time.
That gap is not fixed here.

## Activity

- 2026-08-22 — done — verified against live code by Gunn Bhatrakarn (a84bbfe9): Ran bash scripts/verify-standalone.sh on the full tree — [PASS] no foreign-project references in 819 file(s), was 5 failures before.
