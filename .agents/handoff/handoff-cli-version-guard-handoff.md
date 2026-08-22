---
id: handoff-cli-version-guard-handoff
title: Handoff board — CLI version guard and per-repo CLI
type: coordination
status: open
audience:
repos: []
severity: high
created: 2026-08-23
updated: 2026-08-23
note:
---

## Context

A cross-repo handoff board today has exactly **one** CLI. `setup-handoff.sh` in
`--topology cross-repo` resolves `HDEST` to the _shared board_, not to the member repo
(`skills/engineering/setup-handoff/scripts/setup-handoff.sh:246-252`), and
`sync-cross-repo-handoff.sh:169-171` re-runs the installer once per member with
`--handoff-dir "$board"`. So every member wires hooks that invoke `<board>/handoff`, and
every member's sync pass rewrites that one copy from whatever `x442-skills` checkout the
syncing machine happens to have.

Two consequences, one of them a live bug:

1. **Silent downgrade.** `install_file` (`setup-handoff.sh:51-54`) is `cmp -s` then an
   unconditional `cp`. It skips byte-identical files (the write-churn fix) but has no notion
   of newer/older. A teammate on a stale checkout who runs the cross-repo sync silently
   downgrades the shared board's CLI for every member. The only thing that would notice is
   that same person running `verify-setup-handoff.sh`, which hits the "installed is newer
   than the skill's" branch and blames their own copy. Nobody else is told.
2. **No skew today, but no isolation either.** Because there is one CLI, there is no
   old-CLI-writes-new-board hazard right now. There is also no way for a repo to hold its
   tooling steady while a sibling upgrades.

`payload.version` exists (`scripts/payload.version`, currently `setup-handoff 9`) and is
stamped to `<board>/.version` on install (`setup-handoff.sh:225` and `:370`), but **nothing
reads it at runtime** — `grep -n version` over `payload/handoff`, `payload/hooks.sh` and
`payload/config.sh` returns only unrelated prose. The single comparison lives in
`verify-setup-handoff.sh:50-63`, which is manual, runs from the skill directory, and warns
rather than fails.

## Where

Read before changing anything:

- `skills/engineering/setup-handoff/scripts/payload/handoff:12` — `DIR="$(cd "$(dirname
"${BASH_SOURCE[0]}")" && pwd)"`. The board is wherever the CLI file sits. There is no
  `--board` flag and no env override; this is the blocker for step 3.
- `skills/engineering/setup-handoff/scripts/setup-handoff.sh:51-54` — `install_file`, the
  unconditional `cp` that step 2 must gate.
- `skills/engineering/setup-handoff/scripts/setup-handoff.sh:225`, `:370` — the two places
  `.version` is stamped (`--board-only` path and the normal install).
- `skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh:50-63` — the existing
  `check_payload_version`; keep it a warning, it grades freshness, not compatibility.
- `skills/engineering/setup-handoff/scripts/payload/config.sh:73`, `:98` — `boardPath` is
  already resolved into `HC_BOARD_PATH`.
- `skills/engineering/setup-handoff/scripts/payload/hooks.sh:145` —
  `hd="${HANDOFF_HDPATH:-${HC_BOARD_PATH:-.agents/handoff}}"`. The hooks already locate a
  board from inside a repo; the CLI does not. Step 3 teaches the CLI the same lookup.
- `skills/engineering/register-cross-repo-handoff/scripts/sync-cross-repo-handoff.sh:135-139`
  — the standing decision that the board's CLI cannot reach the skill. Do not reverse it.

## The work, in order

**Step 1 — split the version number in two.** `payload.version` is a build counter, bumped
for a README typo as readily as a format change; a hard gate on it becomes noise and gets
disabled. Add a second, slow-moving number written to `<board>/.schema`, bumped **only** when
the on-disk board format changes: doc frontmatter keys, `.locks/<id>/` layout, `INDEX.md`
format, `config.json` keys, section/prefix routing. `payload.version` keeps its current job
(install freshness, warning-only in `verify-*.sh`); `.schema` is what the gate compares.

**Step 2 — gate at invocation, not only at install.** This is the part that matters, and it
does not depend on moving the CLI.

- Every `handoff` run reads `<board>/.schema` and compares against the schema the CLI ships for.
- CLI older than board: refuse **writes** (`new`, `claim`, `release`, `import`, `export`),
  allow **reads** (`list`, `index`, doc display). Message names the fix — re-run
  `setup-handoff` in this repo. Reads stay open so an agent mid-session is not blinded.
- CLI newer than board: refuse writes, tell the operator to re-run `setup-handoff` against
  the board. **Never auto-migrate** — the installer is the only thing allowed to rewrite
  board state, and it already owns the migration paths (`setup-handoff.sh:311-322`).
- An absent `.schema` means a pre-gate board, exactly as an absent `.version` means a
  pre-versioning install: treat as "behind", not corrupt.
- Also gate `install_file`'s caller: read `<board>/.schema` before installing and refuse to
  write backwards unless an explicit `--force-downgrade` is passed. This alone closes
  consequence (1) above.

**Step 3 — per-repo CLI, data-only board.** Decouple board location from CLI location at
`payload/handoff:12`: `HANDOFF_BOARD` env, else `HC_BOARD_PATH`, else `dirname($0)`. The
fallback keeps every existing single-repo board resolving exactly as it does now. Then
`setup-handoff.sh` in cross-repo topology installs the CLI into the _member repo_ and leaves
the board as data (docs, `.locks/`, `config.json`, `repos.json`, `INDEX.md`, `.schema`).

Note the env name here is provisional — `handoff-env-term-naming-handoff` owns the final
spelling and the deprecation path. Do not ship a new public env var without reading it.

## Decisions

Settled; do not relitigate:

- **Do not run the CLI from the skill's `scripts/` directory.** It is not "always latest", it
  is "whatever that machine's skill checkout is" — the same divergence, now unstamped and
  undetectable. It also breaks for teammates and CI who never installed the skill, puts a
  machine-absolute path into committed tool settings, and reverses the standing decision at
  `sync-cross-repo-handoff.sh:135-139`.
- **Ordering is not negotiable.** Step 3 before step 2 is the bad order: that is precisely
  when an old CLI writes new-schema state with old rules and nobody notices. Steps 1+2 alone
  leave a correct system with one CLI and no silent skew, and are a legitimate stopping point.
- **Step 3 buys isolation, not correctness.** Its value is that each repo upgrades on its own
  cadence and a sibling's sync can no longer touch your tooling. It costs N copies to keep
  current. Worth doing, but not the fix for the bug.
- **Templates ship with the CLI in step 3**, not with the board. Leaving them on the board
  keeps a versioned surface there and the board is not actually data-only. Divergence in doc
  scaffolding is cosmetic.
- **Two numbers, not one.** A gate on the build counter will be turned off.

## Verify

- `grep -n 'schema' skills/engineering/setup-handoff/scripts/payload/handoff` shows the gate
  reading `<board>/.schema` before any write path, and only reads bypass it.
- Skew test, both directions, on a scratch board outside this repo: stamp `.schema` one
  ahead, confirm `list` succeeds and `claim` refuses with an actionable message; stamp it one
  behind, confirm writes refuse and point at the board.
- Downgrade test: run `setup-handoff.sh` from a checkout whose `.schema` is lower than the
  board's and confirm it refuses without `--force-downgrade`, and that the board's CLI is
  byte-unchanged afterward (`cmp`).
- `bash skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh .` still passes, and
  `check_payload_version` is still a warning.
- Harness: `harness/setup-handoff-workspace/` and `harness/repair-handoff-workspace/` cases
  green, with a new case per skew direction.
- Bump `scripts/payload.version` — this changes installed files in every target.

## Suggested skills

- `superpowers:systematic-debugging` if the skew tests behave unexpectedly.
- `x442-repair-handoff` to smoke-test the CLI and board wiring after each step.
- `x442-run-handoff` for the claim/release discipline while working this.

## Activity

- 2026-08-23 — open — released by Gunn Bhatrakarn (d874fc91).
