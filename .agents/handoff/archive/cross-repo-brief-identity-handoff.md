---
id: cross-repo-brief-identity-handoff
title: Resolve brief repo identity from the group manifest
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

`handoff export` records repo identity in a brief so it cannot be executed against the wrong
checkout. On a **flat** board that works: identity comes from the exporting repo's root commit.

On a **grouped** board (scaffolded by `register-cross-repo-handoff`), the board is owned by no repo
and a handoff's `audience` names a different repo than the one export runs in. The design spec says
identity should resolve from the target repo **via the group manifest**. It never did.

The original implementation guessed a sibling directory — `${REPO_DIR}/../$audience/.git`. The
whole-branch review showed that a same-named-but-unrelated sibling made the brief record that
unrelated repo's **real** root commit and render a fully confident preflight. A mis-resolved SHA is
indistinguishable from a fabricated one to the executor, which the spec explicitly forbids.

That guess was **deleted** rather than fixed (commit `e238dbb`). Cross-repo exports then always
recorded `repo_root_commit: unverified`, which forced `--force-repo` and a human check on import —
honest but degraded: on the exact topology the guard was built for, the guard did not run.

**Resolved.** Identity now resolves from the manifest, through a projection the manifest's owner
writes. The payload CLI cannot read `.handoff-repos.json` itself — it ships inside the member repos,
so it can reach neither `resolve.py` nor the cascade's `--scope`, and re-implementing the
user -> scope -> subdir merge there would be a second copy free to drift from the first. So the
cross-repo sync writes `<board>/repos.json`: one entry per member with its `audience`, its path
relative to the board, and that repo's root commit **as an attestation**. `export` resolves the
audience to exactly one entry within the caller's own section, reads the live root commit at that
path, and records identity only when the two agree. Everything else — a moved checkout, a stale
registry, an undeclared audience, an audience claimed twice inside one group, an unreadable or
absent registry, no `python3` — degrades to `unverified` with a warning naming the cause. Nothing
falls back to a name.

## Where

- `skills/engineering/setup-handoff/scripts/payload/handoff` — `board_repo_entry()` (new) reads
  the registry; `brief_identity()` attests it against the live repo and picks the degradation note.
- `skills/engineering/register-cross-repo-handoff/scripts/manifest/registry.py` (new) — owns the
  projection, called by both the sync (`--write`) and the verifier (`--check`), so they cannot
  disagree about what the file should contain.
- `skills/engineering/register-cross-repo-handoff/scripts/manifest/resolve.py` — members now carry
  `root_commit`.
- `skills/engineering/register-cross-repo-handoff/scripts/sync-cross-repo-handoff.sh` — step 1b.
- `skills/engineering/register-cross-repo-handoff/scripts/verify-cross-repo-handoff.sh` — section 4
  fails on registry drift.
- `docs/superpowers/specs/2026-08-21-handoff-offline-delegation-design.md` — the cross-repo section
  now describes the landed design; open choice 3 is settled.

## Verify

Done exactly as specified, end to end, against a real synced fleet:

- Two member repos in a scratch workspace whose directory names (`checkout-one`, `checkout-two`) do
  **not** match their audiences (`acme-api`, `acme-web`); `sync-cross-repo-handoff.sh` run over a
  `.handoff-repos.json` declaring both.
- A handoff filed in `checkout-one` with `--audience acme-web`, exported from `checkout-one`. The
  brief carried `checkout-two`'s real root commit and `repo_origin: acme/acme-web`, and the
  exporting repo's root commit appeared nowhere in it.
- `import --result` accepted the brief in `checkout-two` with no `--force-repo`, and refused it in
  `checkout-one` ("this brief targets a different repository").
- **The trap re-run:** an unrelated git repo created at `<workspace>/acme-web` — a directory whose
  name matches the audience exactly. Identity still resolved to `checkout-two` through the manifest;
  the decoy's root commit never appeared.
- Re-sync left `repos.json` byte-identical (idempotent); a hand-edited `rootCommit` made
  `verify-cross-repo-handoff.sh` report drift.

Payload selftest: **117 passed, 0 failed**, against a baseline of 99 measured by running HEAD's own
copy of the suite. The 18 added cases cover resolution through the registry, the same-named-sibling
trap, attestation mismatch, undeclared audience, duplicate audience inside one group, an unreadable
registry, an absent registry, and section scoping. Cross-repo harness grader: the verifier's own
pass count rose 7 -> 9 with no new failures (the 12 grader failures there are pre-existing and now
filed as `cross-repo-verifier-stale-checks-handoff`).

To re-run: `bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh`.

## Decisions

- **Never fall back to a name guess.** When the manifest is absent or its declared path is
  unreachable, record `unverified`. A wrong-but-confident SHA is worse than no SHA.
- Identity belongs to the **target** repo (the audience), not the board and not the exporting repo.
- The payload CLI already shells to `python3` for `config.json` in `config.sh`; reading JSON is
  established precedent, not a new dependency.
- **The CLI reads a projection, not the manifest.** It cannot reach `resolve.py` or `--scope`, and a
  second copy of the cascade's merge semantics would drift from the first. The manifest's owner
  writes the answer to `<board>/repos.json`; `registry.py` builds those bytes for both the writer
  and the verifier.
- **The recorded root commit is an attestation, not a value to copy.** It is compared against the
  live repo at export time, so a stale projection fails closed instead of producing the very
  wrong-but-confident SHA this handoff exists to prevent. That is what makes a projection safe where
  a name guess was not.
- **Lookup is scoped to the caller's section**, the same fence every other command applies — so two
  groups sharing a board may each declare their own `api`.

## Suggested skills

`x442-register-cross-repo-handoff` (owns the manifest format), `x442-delegate-handoff` (owns the
delegation loop this feeds), `x442-repair-handoff` if a grouped board misbehaves while testing.

## Activity

- 2026-08-22 — open — released by Gunn Bhatrakarn (a84bbfe9). filed from the whole-branch review; not started
- 2026-08-22 — done — verified against live code by Gunn Bhatrakarn (7b3f9481): End-to-end against a real synced two-repo fleet whose directory names do not match their audiences: the brief carried the TARGET repo's live root commit and origin, import --result accepted it in that repo with no --force-repo and refused it in the exporting repo, and with an unrelated git repo planted at a directory named exactly like the audience, identity still resolved through the manifest and the decoy's SHA never appeared. Re-sync left repos.json byte-identical; a hand-edited rootCommit made verify-cross-repo-handoff.sh report drift. Payload selftest 117 passed / 0 failed (baseline 99, measured by running HEAD's own suite)..
