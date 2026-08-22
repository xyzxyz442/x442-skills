---
id: hook-command-drift-handoff
title: Handoff — hook command drift is undetected, and fixture blocks are stale
type: coordination
status: done
audience:
repos: []
severity: medium
created: 2026-08-23
updated: 2026-08-23
note:
verified_at: 2026-08-23
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

Follow-on to [[agents-block-drift-handoff]]. That handoff fixed the AGENTS.md routing block. Two
more instances of the same class remained.

**1. Hook command drift is undetected.** The installer rewrites each tool's hook config on every
run, so a config only goes stale when nobody re-runs the installer. Nothing noticed, because the
payload version stamp covers the payload **files**, not the wiring written around them. A board
can report `payload vN matches` while its hooks still run a command shape the skill stopped
writing. This repo hit it — the Claude hook commands were missing
`--project-dir "$CLAUDE_PROJECT_DIR"` while the stamp read current.

**2. Fixture staleness.** Twelve harness fixtures carried the pre-v9 AGENTS.md block, and ten
carried a v8 payload stamp. The v9 bump then broke `setup-handoff/claude-wired`, whose eval
asserts that an installer re-run produces an empty diff.

## Where

- `skills/engineering/setup-handoff/scripts/merge-hooks.py` — gained `events_for()` (extracted from
  `wire()`, now shared) and `check()`; `--check` exits 0 current / 2 drifted / 3 not wired.
- `skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh` — per-tool hook comparison,
  passing each file's own primary/advisory shape so an advisory tool is not reported as missing
  hard-enforcement hooks it should not have.
- `harness/*/fixtures/*/AGENTS.md` — twelve blocks refreshed.
- `harness/*/fixtures/*/.agents/handoff/.version` — ten stamps to v9. `stale-stamp` stays at 0: its
  payload really is old (62KB CLI vs 102KB shipped), so the stamp is honest there.

## Decisions

- **Bumping the fixture stamps to v9 is truthful, not cosmetic.** v9 changed no payload file, and
  every fixture except `stale-stamp` carries payload files byte-identical to what is shipped. The
  stamp records the payload, so v9 is the accurate value.
- **`stale-stamp` keeps its v0** and its one `[FAIL]`. Its CLI predates `handoff export`, so a raw
  grade of a pre-state repair target fails by design.
- **No second `payload.version` bump.** This change is verifier-side; it installs no new artifact
  into a target repo. The v9 bump already tells every install to re-run.
- **The hook check compares commands, not formatting.** The installer writes expanded JSON and
  prettier collapses it, so a byte comparison would churn forever in any repo with prettier.

## Verify

1. `bash skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh .` → 27 passed, 0
   warnings, 0 failed, including a `hook commands match` line per wired tool.
2. Restore the pre-fix config and confirm the warning fires:
   `git show 68d63bc:.claude/settings.json > /tmp/old.json` then
   `HANDOFF_HDPATH=.agents/handoff HANDOFF_TOOL=claude HANDOFF_PRIMARY=0 python3
skills/engineering/setup-handoff/scripts/merge-hooks.py /tmp/old.json --check` → exit 2.
3. Every fixture verifies 0 failed except `stale-stamp` (see Decisions).
4. `claude-wired` and `healthy` graders pass, including the empty-diff and stamp assertions.

## Suggested skills

- `x442-repair-handoff` — step 2 now carries both drift probes.
- `x442-setup-handoff` — the installer and verifier being changed.

## Activity

- 2026-08-23 — done — verified against live code by Gunn Bhatrakarn (010ceebc): merge-hooks.py --check returns 0/2/3 correctly, proven against the real pre-fix config from 68d63bc (exit 2) and the current one (exit 0); verifier reports a hook-commands line per wired tool and this repo is 27 passed/0 warnings/0 failed; SCRIPT_DIR fix confirmed by running the verifier relative and absolute against a foreign target, which now reports the payload-stamp warn that was previously silent and no longer false-reports drift; all 12 fixtures verify 0 failed except stale-stamp whose single FAIL is its deliberately-old CLI lacking 'export'; graders pass claude-wired 3/3, advisory-wired 2/2, script-behavior 66/66, grouped-board 34/34, cross-repo 15/15, healthy 3/3, run-handoff 7/7, delegate 18/18 and 7/7.
