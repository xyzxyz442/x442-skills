---
id: handoff-deprecation-registry-handoff
title: Handoff payload — deprecation registry and policy
type: standalone
status: open
created: 2026-08-23
updated: 2026-08-23
note:
---

## What this doc is

The **single source of truth for every deprecation in the handoff payload** — the CLI, the
hooks, the config resolver, the board layout, and the env surface. Standalone and
gate-exempt on purpose: it is a long-lived reference that any session may read and any
session may append to, not a work item that gets claimed and closed.

Rule: **a deprecation that is not entered here does not exist.** If you alias an old name,
retain an old file, or teach a reader to accept an old shape, add a row before you ship it.
Nothing else in the payload records this — the installer's migrations are silent, and the
verifier grades freshness, not compatibility.

## Policy

**How to deprecate.** Read the new thing first, fall back to the old, keep working. Never
break on an old name; refusing is a removal, and removal is a separate, later, announced step.

**Where the warning goes.** Stderr, once per process, guarded by a flag variable rather than
per call site.

The hooks are the constrained case and get their own rule: `hooks.sh` must never hard-fail a
tool session, and only its **sessionstart** channel surfaces anything to the user — pretool,
posttool and stop stay silent and fast by design
(`skills/engineering/setup-handoff/scripts/payload/hooks.sh:95-99`). So a deprecation notice
from the hooks belongs on **sessionstart only**. A notice on pretool fires on every edit,
floods the session, and is how an enforcement gate gets switched off by an annoyed operator.

**What a warning must say.** The old name, the new name, and the version it is removed at.
A warning that does not name its replacement generates a support question instead of a fix.

**The window.** A deprecation warns for at least **two payload minor bumps** and one full
sync cycle across every repo that consumes a shared board, whichever is longer. The shared
board is the binding constraint: members upgrade on their own cadence, so "everyone has
re-run the installer" is the real gate, not elapsed time.

**Removal criteria**, all three required:

1. The window above has elapsed.
2. No consumer still carries the old form — for env names, `grep` the wired hook commands in
   every member repo's tool settings; for files, check the boards themselves.
3. The replacement has shipped in a payload version that every consumer has actually
   installed (compare `<board>/.version` per board, not per checkout).

**Silent migration is allowed, and is not an exemption.** The installer rewrites some old
shapes in place with no warning at all — a flat board becomes `scripts/` + `templates/`, a
legacy shell config becomes `config.json`. That is the right behavior for on-disk layout,
because the operator has nothing to do about it. It still gets a row here, because the next
person to touch that code needs to know a fallback reader exists and why.

## Registry

Status values: `warns` (alias live, notice emitted) · `silent` (fallback accepted, no notice)
· `migrated` (installer rewrites it in place) · `removed`.

### Pending — introduced by in-flight work

| Deprecated                               | Replacement                                                   | Status  | Warns from   | Remove at | Owner                                        |
| ---------------------------------------- | ------------------------------------------------------------- | ------- | ------------ | --------- | -------------------------------------------- |
| `HANDOFF_HDPATH`                         | `HANDOFF_BOARD_PATH`                                          | planned | TBD on merge | TBD       | `handoff-env-term-naming-handoff`            |
| `HANDOFF_NO_MAIN`                        | `HANDOFF_INTERNAL_NO_DISPATCH` (or retained, marked internal) | planned | TBD on merge | TBD       | `handoff-env-term-naming-handoff`            |
| Board-resident CLI on a cross-repo board | per-repo CLI + data-only board                                | planned | TBD          | TBD       | `handoff-cli-version-guard-handoff` (step 3) |

Fill `Warns from` with the `payload.version` that first ships the alias — not a date. Leave
`Remove at` blank until the three removal criteria above can actually be evaluated; a
guessed removal version that slips is worse than an empty cell.

Not deprecated, recorded so nobody proposes it again: `HANDOFF_DIR` in
`setup-handoff.sh:138` is a local shell variable, never public, and may be renamed freely.
`CLAUDE_SESSION_ID` / `CLAUDE_CODE_SESSION_ID` (`payload/handoff:266`) are vendor-owned and
are never renamed or aliased.

### Existing — already shipped, previously unrecorded

These predate this registry. They are entered retroactively so the fallback readers in the
payload are attributable to something.

| Deprecated                                                     | Replacement                          | Status            | Where the fallback lives                                                                                                                                                                                                                                                                       |
| -------------------------------------------------------------- | ------------------------------------ | ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Legacy `<board>/config` (KEY=value)                            | `<board>/config.json`                | migrated + silent | Converted by `setup-handoff.sh:327-350`; the old file is **retained deliberately** so a half-finished install cannot strand a board with no config. Still read as a fallback layer by `payload/config.sh` (`read_legacy`, and `_handoff_config_legacy_nopython` for machines with no python3). |
| Flat board layout — `hooks.sh` and templates at the board root | `scripts/hooks.sh`, `templates/*.md` | migrated          | `setup-handoff.sh:311-322` (`migrate_file`, git-mv when tracked). `payload/hooks.sh:20-27` still probes `$SELF_DIR/../handoff` so an un-migrated board keeps working. `verify-setup-handoff.sh` warns on root-level templates.                                                                 |
| Legacy install path `.claude/handoff/`                         | `.agents/handoff/`                   | migrated          | `setup-handoff.sh --migrate`, preserving docs, `archive/`, and git history. Never moves `.locks` (machine-local).                                                                                                                                                                              |
| Absent `<board>/.version`                                      | stamped `payload.version`            | silent            | Treated as "pre-versioning install", not corrupt — `verify-setup-handoff.sh:54-55`. The same convention will apply to an absent `.schema`.                                                                                                                                                     |

## Keeping this honest

- Every entry names a real file:line or it is not an entry.
- When a row reaches `removed`, keep the row and mark it — deleting it loses the answer to
  "why does this code accept two shapes", which is the question the registry exists to answer.
- The env-naming and version-guard handoffs both write here. If they disagree with this doc,
  this doc is wrong and gets fixed; do not fork a second list into a SKILL.md.
