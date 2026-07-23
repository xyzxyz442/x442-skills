---
id: id-casing-handoff
title: Handoff ids and filenames must be lowercase kebab-case
type: coordination
status: done
audience:
repos: []
severity: medium
created: 2026-07-21
updated: 2026-07-21
note: norm_id only appends -handoff; it does not slugify. Uppercase/underscore/space ids produce non-conforming filenames.
verified_at: 2026-07-21
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

Handoff ids (and therefore doc filenames, since the id **is** the filename stem) should always be
lowercase kebab-case. Today nothing enforces that.

The `<id>-handoff.md` convention landed in commit `86292ba`, which made `norm_id` the single place
that canonicalizes a user-supplied id. But `norm_id` only appends the `-handoff` suffix — it does
not normalize case or separators. Consequences:

- `handoff new "RBAC Gap"` and `handoff new RBAC_Gap` create `RBAC Gap-handoff.md` /
  `RBAC_Gap-handoff.md` — filenames with spaces, capitals, and underscores on a board whose whole
  contract is a lowercase-kebab stem.
- `cmd_import` has its own ad-hoc sanitizer that maps space and `/` to `-` and strips anything
  outside `[A-Za-z0-9._-]`. It still permits capitals, `.`, and `_`, and it duplicates logic that
  belongs in `norm_id`. Two id paths, two different notions of "safe id".
- Ids are compared as literal strings everywhere (lease dir names under `.locks/`, `blocked_on`
  cross-references, the hooks' `doc_id_of` whitelist glob, `INDEX.md` rows). Case variance means
  `claim RBAC-Gap` and `claim rbac-gap` are two different leases over one doc — the exact
  double-claim the board exists to prevent. On a case-insensitive filesystem (macOS default) they
  resolve to the _same file_ but _different_ lock dirs, so the gate silently fails open.

Fix: make `norm_id` slugify, and let every entry point flow through it.

## Where

Source of truth — everything else is a deployed copy of this file:

- [payload/handoff:110-113](../../skills/engineering/setup-handoff/scripts/payload/handoff#L110-L113)
  — `norm_id`, currently suffix-append only. This is the one function to change.
- [payload/handoff:284-287](../../skills/engineering/setup-handoff/scripts/payload/handoff#L284-L287)
  — `cmd_import`'s redundant `tr`-based sanitizer; delete it once `norm_id` slugifies.
- Call sites that then inherit the fix for free: `cmd_new` :165, `cmd_claim` :361, `cmd_touch` :405,
  :422, and the `--blocked-on` normalization at :486.
- [payload/hooks.sh:153-161](../../skills/engineering/setup-handoff/scripts/payload/hooks.sh#L153-L161)
  — `doc_id_of` matches the `*-handoff.md` glob case-sensitively. No change needed, but it is _why_
  a capitalized filename silently escapes the edit gate; note it in the fix's rationale.

Docs to update in the same change:

- [payload/README.md](../../skills/engineering/setup-handoff/scripts/payload/README.md) — the
  `## Naming` section (~line 8) states the suffix rule; add the slug rule.
- [setup-handoff/SKILL.md:195](../../skills/engineering/setup-handoff/SKILL.md#L195) — the
  "Naming: `<id>-handoff.md`" bullet.
- [run-handoff/SKILL.md](../../skills/engineering/run-handoff/SKILL.md) — the "File a new handoff"
  section's filename note.

Deployed copies to re-sync after the payload changes (the installer overwrites them; do not
hand-patch and skip the payload):

- `.agents/handoff/handoff` (this repo's own live board)
- `harness/run-handoff-workspace/fixtures/board-wired/.agents/handoff/handoff`
- `harness/setup-handoff-workspace/fixtures/{advisory,claude}-wired/.agents/handoff/handoff`

## Verify

1. Payload behavior, direct:

   ```text
   handoff new "RBAC Gap"      -> creates rbac-gap-handoff.md   (not "RBAC Gap-handoff.md")
   handoff new RBAC_Gap        -> fails, already exists          (proves both spellings collapse)
   handoff claim RBAC-GAP "x"  -> claims rbac-gap-handoff        (lookup slugifies too)
   handoff import Notes.md     -> creates notes-handoff.md
   ```

2. Legacy resolution still works: on a board holding a pre-existing non-conforming doc (e.g.
   `Legacy_Doc-handoff.md`), `claim Legacy_Doc` must still resolve to that file rather than
   inventing `legacy-doc-handoff`. Add a fixture case for this.
3. Full eval suites green, both workspaces:
   `harness/setup-handoff-workspace` (9 evals) and `harness/run-handoff-workspace`. The graders
   assert literal doc paths, so new slug cases go in `grade.py` alongside the existing
   `-handoff.md` assertions.
4. `skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh` passes against this repo's
   own board (18/18, 0 warnings) after the payload re-sync.

## Decisions

- **Slugify inside `norm_id`, not at each call site.** It is already the single canonicalization
  choke point for `new`, `import`, `claim`, `release`, `touch`, and `--blocked-on`. Adding a second
  normalizer is what created the `cmd_import` divergence in the first place.
- **Slug rule, in this order:** lowercase → replace every run of non-`[a-z0-9]` with `-` → collapse
  repeats → trim leading/trailing `-` → _then_ append `-handoff` unless already suffixed. Lowercase
  must come first, or `RBAC-Handoff` fails the suffix test and becomes `rbac-handoff-handoff`.
- **Stay bash-3.2 portable.** macOS ships bash 3.2, so no `${var,,}`. Use `tr '[:upper:]' '[:lower:]'`
  plus `sed`, consistent with the rest of the script.
- **Empty slug is an error, not a silent `-handoff`.** An id of `"---"` or `"!!!"` must `die` with a
  usage message.
- **Resolution keeps a legacy fallback; creation does not.** `claim`/`release`/`touch` should prefer
  the slugified id, but fall back to the raw `-handoff`-suffixed form when only that file exists —
  otherwise this change orphans docs on already-installed boards. `new`/`import` always slugify, so
  no new non-conforming file is ever created.
- **No migration of existing boards.** Renaming live docs breaks `blocked_on` cross-references and
  git history for a cosmetic gain. The fallback above covers them; new docs conform.

## Outcome

Implemented 2026-07-21 in the payload, then propagated to all four deployed copies.

- `norm_id` now slugifies (lowercase → non-alphanumeric runs to `-` → collapse → trim → suffix) and
  returns non-zero on an id with nothing alphanumeric, so callers `die` instead of writing
  `-handoff.md`.
- `legacy_id` + `resolve_id` added: `claim`/`touch`/`release`/`--blocked-on` prefer the slug but
  fall back to a pre-slug filename when only that file exists. `new`/`import` never fall back.
- `cmd_import`'s ad-hoc `tr` sanitizer deleted — `norm_id` is now the only id normalizer.
- 7 new expectations in `harness/setup-handoff-workspace/grade.py` (`script-behavior`), covering the
  fold, the collision, case-insensitive lookup, the empty-slug rejection, and the legacy fallback
  through claim and archive-on-done.

Not done, by decision: no existing doc was renamed.

## Suggested skills

- `x442-run-handoff` — claim this before editing the doc or the payload.
- `x442-setup-handoff` — re-run the installer to propagate the payload to the live board and the
  harness fixtures rather than hand-editing the copies.
- `superpowers:test-driven-development` — add the slug/legacy-fallback eval cases to both
  `grade.py` graders before changing `norm_id`.

## Activity

- 2026-07-21 — open — released by Gunn Bhatrakarn (c0ebf4f2).
- 2026-07-21 — done — verified against live code by Gunn Bhatrakarn (c0ebf4f2): 11/11 evals green (script-behavior 26/26 incl. 8 new slug/legacy/activity cases); verify-setup-handoff.sh 18/18 0 warnings; live smoke: new 'RBAC Gap'->rbac-gap-handoff.md, claim RBAC-GAP resolves, '!!!' rejected, Legacy_Doc-handoff.md still claimable+archivable.
