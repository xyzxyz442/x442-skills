---
id: cross-repo-verifier-stale-checks-handoff
title: verify-cross-repo-handoff reads board facts the installer no longer writes
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

`verify-cross-repo-handoff.sh` reports **10 FAILs on a freshly synced, healthy fleet**, and the
harness grader for `x442-register-cross-repo-handoff` sits at 18/30 because of it. Nothing is wrong
with the fleet — the verifier reads two board facts the installer stopped writing:

1. **Board config.** Section 2 greps the legacy `KEY=value` file `$BOARD/config` for
   `TOPOLOGY=cross-repo`, `HANDOFF_GROUPS`, and `HANDOFF_GROUP_LAYOUT`. `setup-handoff.sh` writes
   `$BOARD/config.json` instead (`write_board_config`), and a fresh board has no `config` file at
   all — so all three checks fail with `config: 'unset'`.
2. **Member group wiring.** Section 3 greps each member's `.claude/settings.json` for
   `HANDOFF_GROUP=<group>`. That was deliberately removed — see the comment at
   `skills/engineering/setup-handoff/scripts/setup-handoff.sh:412-418` ("these no longer get baked
   into the hook command itself... instead merge-hooks.py... writes it to
   `.agents/handoff.config.json`"). The group now lives in the member's
   `.agents/handoff.config.json` as `"group"`.

Found while implementing `cross-repo-brief-identity-handoff`. Confirmed pre-existing by stashing
that work — baseline and post-change graders both report 12 failed / 18 passed, with only the
verifier's own pass count moving (7 -> 9).

**Resolved.** Both readers now go through the payload's own resolver instead of naming a file:

- The verifier sources `payload/config.sh` and calls `handoff_config_load <board> [<repo>]`,
  which already decides `config.json` vs legacy `config` vs the repo scope, and their precedence.
  It prefers the **skill's** copy over the board's — current by construction, and auditing a board
  is not a reason to execute shell that lives inside it; the board's copy is a fallback for a
  checkout with no `setup-handoff` sibling.
- "Wired" and "scoped" are now separate checks: the hook command must invoke the board's
  `hooks.sh`, and the member's own `.agents/handoff.config.json` must name its section.
- `grade.py` carried the identical two assumptions, so fixing only the verifier would have left
  10 of the 12 grader failures standing. It now reads the board config the same way (config.json
  over legacy) and takes the member's section from its own config.

Three further stale reads of the same shape were fixed with it, all one line each: the
`[warn] config missing` in `verify-setup-handoff.sh` that fired on **every freshly installed
board** (the installer writes `config.json`; the check demanded the legacy name), and the two docs
that told a repairing agent to grep `$BOARD/config` and described `HANDOFF_GROUP` as baked into
the hook command.

## Where

- `skills/engineering/register-cross-repo-handoff/scripts/verify-cross-repo-handoff.sh` —
  `board_config()` + `cfg_reason()` (new) wrap the resolver and capture its stderr into the `[FAIL]`
  line it explains; sections 2 and 3 read through them.
- `harness/register-cross-repo-handoff-workspace/grade.py` — `_board_config()`, `_groups_csv()`,
  `_member_group()` (new); the fleet expectations use them.
- `harness/register-cross-repo-handoff-workspace/evals/evals.json` — the fleet `expected_output`
  described the old wiring.
- `skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh` — the payload-presence loop
  now accepts either config file.
- `skills/engineering/repair-handoff/SKILL.md` and
  `skills/engineering/register-cross-repo-handoff/SKILL.md` — the two stale instructions.
- `skills/engineering/setup-handoff/scripts/payload/config.sh` — the resolver everything now shares
  (unchanged).

## Verify

Run the grader — it manufactures a hermetic fleet and syncs it, so no fixture work is needed:

```text
python3 harness/register-cross-repo-handoff-workspace/grade.py \
  harness/register-cross-repo-handoff-workspace/fixtures/fleet fleet
```

Before the fix — `18 passed, 12 failed`, the verifier reporting `10 failed`. After — **36 passed,
0 failed**, the verifier reporting `0 failed` under both layouts. `not-configured` stays 2/2.

Nothing was satisfied by making the installer write the legacy file again; both readers were taught
to read what it actually writes.

Also checked by hand, on a real synced fleet:

- **A board carrying only the legacy `config`** (config.json deleted, the KEY=value file
  reconstructed from it) still verifies `12 passed, 0 failed` — the compatibility the Decisions
  below require.
- **A board with no config at all** FAILs (its topology resolves to the `single-repo` default), so
  the looser read did not become a silent pass.
- **A member stamped with the wrong section** FAILs, naming the value it actually resolved to.
- **A malformed `config.json`** FAILs in both sections, and the `[FAIL]` line now carries the
  resolver's own parse error and the offending path instead of letting it escape to stderr between
  unrelated checks.
- `verify-setup-handoff.sh` on a freshly installed board: `20 passed, 1 warning, 0 failed` (was
  `19 passed, 2 warnings`, the extra warning being the phantom `config missing`).

No regressions across the handoff suite: **setup-handoff 12/12 evals**, register-cross-repo-handoff
2/2, and every `post-state` / `precondition` eval in repair-, run-, and delegate-handoff. The only
failing evals are the four `kind: pre-state` fixtures, which are broken inputs by construction and
score ~0 when graded raw.

## Decisions

- **Read config the way the payload does.** `config.sh`'s `handoff_config_load` already resolves
  legacy `config`, `config.json`, and the repo scope in one place, with precedence. The verifier
  sources it rather than grow a third hand-rolled parser — the same reasoning that put the resolver
  in the payload to begin with.
- **Deviation from this doc's own plan, deliberately.** The plan said to source the board's copy at
  `$BOARD/scripts/config.sh`. The skill's copy is sourced first instead: it is current by
  construction (a stale board would otherwise audit itself with its own stale resolver), and
  auditing a board is not a reason to execute shell that lives inside it — the same argument
  `config.sh` itself makes for parsing the legacy file rather than sourcing it. The board's copy
  remains a fallback for a checkout with no `setup-handoff` sibling.
- **`grade.py` had to move with the verifier.** It asserted on the same two stale facts, so a
  verifier-only fix would have left 10 of 12 grader failures standing and looked like a partial
  repair.
- **The member's group comes from `.agents/handoff.config.json`, not the hook command.** Keep a
  separate check that a handoff hook exists at all; do not conflate "wired" with "scoped".
- A board that still has only the legacy `config` file must keep passing — the resolver handles
  both, which is another reason to go through it.

## Suggested skills

`x442-register-cross-repo-handoff` (owns the verifier), `x442-setup-handoff` (owns what the
installer writes), `x442-repair-handoff` if a board misbehaves while testing.

## Activity

- 2026-08-22 — open — filed by Gunn Bhatrakarn (7b3f9481). found while implementing cross-repo-brief-identity-handoff and confirmed pre-existing by stashing that work; not started
- 2026-08-22 — done — verified against live code by Gunn Bhatrakarn (7b3f9481): Cross-repo harness grader on the fleet fixture went 18/30 to 36/36 (verifier 10 failed to 0) under both layouts, not-configured still 2/2. Hand-checked on a real synced fleet that a legacy-config-only board still verifies 12 passed/0 failed, a board with no config FAILs, a wrong section stamp FAILs naming the resolved value, and a malformed config.json FAILs in both sections with the resolver's parse error inside the FAIL line. verify-setup-handoff.sh on a fresh board 20 passed/1 warning/0 failed, the phantom 'config missing' gone. No regressions: setup-handoff 12/12 evals, register-cross-repo-handoff 2/2, and every post-state and precondition eval in repair-, run-, and delegate-handoff; the only failing evals are the four kind pre-state fixtures, broken by construction..
