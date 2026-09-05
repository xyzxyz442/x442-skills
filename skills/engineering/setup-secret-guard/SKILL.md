---
name: x442-setup-secret-guard
description: >-
  Use when credential values must not reach an agent transcript — "stop Claude reading my .env",
  "redact secrets", "why did it print my API key", or any request to guard credential files
  across projects. Installs a redacting read-path guard plus the shared detection and redaction
  engine (secret-scan, redact-view) into the .claude cascade, so a credential file stays usable
  while its values are replaced by stable fingerprints. Idempotent, and on by default for repos
  that never installed it.
---

# setup-secret-guard

Installs the **secret guard**: the interception point that decides how credential-bearing
content may be handled before it reaches a transcript, a committed document, or an external
recipient.

The point is not to forbid credential files. It is to make them readable **without** their
values. `cat .env` becomes a redacted view — keys, structure and value types intact, each secret
replaced by a length and a truncated digest — so ordinary work continues and the transcript
never holds the secret.

Read [ADR 0008](../../../docs/adr/0008-one-credential-engine-resolved-through-a-cascade.md)
before changing anything here. It records why this payload deliberately breaks the
self-contained-payload convention every other skill follows.

## Why a read-path guard at all

Every other credential check in this repo runs when content is **written** or **dispatched** —
the handoff CLI's `scan_secrets` on `new`/`release`/`export`, the delegation consent gate. None
of them can help with a read, because **a tool result enters the transcript before any hook can
react to it**, and that transcript persists to disk. There is no after-the-fact redaction. The
read path is the only place prevention is possible, and it was unguarded.

## Architecture: one engine, two verbs, three consumers

**The engine** (`secret_redact.py`) owns two questions and no policy at all:

| Verb          | Question                             | Answer                                     |
| ------------- | ------------------------------------ | ------------------------------------------ |
| `secret-scan` | may this content be written or sent? | exit 0 found / 1 clean, plus the rule name |
| `redact-view` | show me this file, redacted          | the file, values fingerprinted             |

It never returns a verdict. `allow`/`ask`/`deny` are Claude Code's vocabulary and belong to the
hook; write-or-refuse belongs to the handoff CLI; each consumer maps detections to its own
policy. A shared verdict vocabulary would drag an `ask` into a bash CLI with no user to ask.

**The consumers** map detections to decisions:

- `secret-file-guard.py` — the `PreToolUse` hook. Rewrites a plain read into a redacted read,
  asks on helm/Harness values files, denies extraction verbs, allows everything else.
- `permissions.deny` in the tool's settings — covers `Read`/`Edit`, whose output a hook cannot
  filter.
- The `AGENTS.md` block — the rules an agent follows where no hook can intercept.

## Resolution: a cascade, with the home layer load-bearing

Consumers resolve the engine as `$CLAUDE_PROJECT_DIR/.claude/…`, then `$HOME/.claude/…`, then
`$SECRET_GUARD_HOME`. The home layer is the floor, because **a leak is a property of the machine
and the transcript, not of the repository** — the guard has to be on for a repo nobody installed
into. "Enforce it everywhere" therefore means one install, not one per project.

The repository layer exists only to **add**: extra path patterns, and `safe_keys` exceptions that
suppress redaction for a key already matched. It may never remove a path from the deny or rewrite
sets. Strict additive-only was rejected — unusable false positives get the whole guard switched
off, which is worse than a scoped exception.

> A `safe_keys` entry is a security change wearing the clothes of configuration. It is the
> easiest layer to modify by ordinary pull request, and it suppresses redaction. Review additions
> as security changes.

## Failure posture is per call site

| Call site       | Engine absent                               | Engine present but throws |
| --------------- | ------------------------------------------- | ------------------------- |
| read-path hook  | degrade to path-only matching, announce     | fail **open**             |
| write, outbound | degrade to the caller's own check, announce | fail **closed**           |

The read path fails open because a wedged session is worse than a bounded exposure — a guard
that denies every command is a guard that gets uninstalled. It announces the degrade once per
session rather than silently, because a control that quietly weakens is trusted further than it
has earned.

**Absent and broken are different failures.** Failing closed on _absent_ would refuse every write
on every machine that never installed the guard, which is the hard-dependency outcome ADR 0008
rejects.

## Install

```bash
scripts/setup-secret-guard.sh              # the home layer — the one that matters
scripts/setup-secret-guard.sh <repo>       # a repo's AGENTS.md block and pattern additions
scripts/verify-secret-guard.sh [--json]    # read-only health check
```

Idempotent: it byte-compares before writing, so a second run leaves `git status` clean.

**Adoption is guarded.** The installer hash-compares what is already installed against the
payload and **refuses on divergence** unless `--adopt` is passed, and it always backs up the
previous copy first — there may be no other copy anywhere. Note the honest limit: because the
payload is de-personalised, the first install on any machine always diverges, so `--adopt` is
always needed once. It defends against later silent drift, not against a bad first install.

## What this skill does not do

- **It does not replace the handoff CLI's `scan_secrets`.** Those rules are tuned so prose about
  credentials passes clean, because what they scan is handoff documents. Key-name matching over
  prose would fire on every security handoff that says "password", and a write-path scanner that
  cries wolf gets overridden by habit.
- **It does not change export policy.** ADR 0005 has `export` refuse on a detection, and it still
  does. Redaction is a read-path capability.
- **It is not a sandbox.** It is a cooperative guard. It cannot stop a command that prints a
  secret without naming a credential path — `env`, a build that echoes a variable, a stack trace.

## Verification

`verify-secret-guard.sh` fires the guard with a synthetic payload and asserts the **decision**,
rather than checking that files exist. It never prints a fixture's value, even on failure —
value-leak assertions belong in the harness, which runs on synthetic data in a sandbox.

Bundled files: `scripts/setup-secret-guard.sh`, `scripts/verify-secret-guard.sh`,
`scripts/splice-agents-block.py` (`--selftest`-able), `scripts/payload.version`,
`scripts/payload/{secret_redact.py,secret-scan,redact-view,secret-file-guard.py}`,
`assets/agents-secret-guard.md`.
