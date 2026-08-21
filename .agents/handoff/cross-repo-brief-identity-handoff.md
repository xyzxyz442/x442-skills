---
id: cross-repo-brief-identity-handoff
title: Resolve brief repo identity from the group manifest
type: coordination
status: open
audience:
repos: []
severity: medium
created: 2026-08-22
updated: 2026-08-22
note:
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

`handoff export` records repo identity in a brief so it cannot be executed against the wrong
checkout. On a **flat** board that works: identity comes from the exporting repo's root commit.

On a **grouped** board (scaffolded by `register-cross-repo-handoff`), the board is owned by no repo
and a handoff's `audience` names a different repo than the one export runs in. The design spec says
identity should resolve from the target repo **via the group manifest**. It never did.

The original implementation guessed a sibling directory — `${REPO_DIR}/../$audience/.git`. The
whole-branch review showed that a same-named-but-unrelated sibling made the brief record that
unrelated repo's **real** root commit and render a fully confident preflight. A mis-resolved SHA is
indistinguishable from a fabricated one to the executor, which the spec explicitly forbids.

That guess was **deleted** rather than fixed (commit `e238dbb`). Cross-repo exports now always
record `repo_root_commit: unverified`, which forces `--force-repo` and a human check on import. That
is honest but degraded — on the exact topology the guard was built for, the guard does not run.

## Where

- `skills/engineering/setup-handoff/scripts/payload/handoff` — `brief_identity()`, the
  `audience != REPO_NAME` branch that now unconditionally sets `target=""`.
- `skills/engineering/register-cross-repo-handoff/` — owns `.handoff-repos.json`, whose per-repo
  entries carry an explicit `path` (and an `audience` that may differ from both alias and path).
  Nothing in the payload CLI reads that manifest today.
- `docs/superpowers/specs/2026-08-21-handoff-offline-delegation-design.md` — the cross-repo section
  records this as deferred; update it when this lands.

## Verify

Scaffold a grouped board with two member repos whose directory names do **not** match their
`audience` values. Export a handoff whose `audience` names the second repo. The brief must carry
that repo's real root commit, and `import --result` must accept it in that repo without
`--force-repo` and refuse it in the first repo.

Then re-run the trap the review found — create an unrelated sibling directory whose name matches an
`audience` — and confirm identity still resolves from the manifest, not the name.

## Decisions

- **Never fall back to a name guess.** When the manifest is absent or its declared path is
  unreachable, record `unverified`. A wrong-but-confident SHA is worse than no SHA.
- Identity belongs to the **target** repo (the audience), not the board and not the exporting repo.
- The payload CLI already shells to `python3` for `config.json` in `config.sh`; reading JSON is
  established precedent, not a new dependency.

## Suggested skills

`x442-register-cross-repo-handoff` (owns the manifest format), `x442-delegate-handoff` (owns the
delegation loop this feeds), `x442-repair-handoff` if a grouped board misbehaves while testing.

## Activity

- 2026-08-22 — open — released by Gunn Bhatrakarn (a84bbfe9). filed from the whole-branch review; not started
