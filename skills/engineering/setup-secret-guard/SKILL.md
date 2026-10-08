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

- `secret-file-guard.py` — the `PreToolUse` hook (matcher `Bash|Grep|Read`). Rewrites a plain
  read into a redacted read, routes cluster-API reads (`argocd app get`, `helm get`,
  `kubectl get -o yaml|json`) through the viewer, asks on helm/Harness values files, denies
  extraction verbs, and asks before the `Read` tool opens a config file whose **content** holds a
  credential. It allows everything else.
- `permissions.deny` in the tool's settings — covers credential-**named** files (`.env*`,
  `*.env`, `.envrc`, keys, kubeconfigs) for `Read`/`Edit`, whose output a hook cannot filter.
- The `AGENTS.md` block — the rules an agent follows where no hook can intercept.

### The verbs are not on PATH, by design

`secret-scan` and `redact-view` install to `~/.claude/bin` and are called by full path — by the
hook, and in the `AGENTS.md` block. Nothing links them onto `PATH`. A generic name there can
resolve to another program first, and for a redactor that failure is silent: output that looks
redacted, printed raw. A bare `redact-view` failing with `command not found` is therefore
expected, not a broken install. A person who wants the short name can alias it in an interactive
shell, where it cannot shadow what a script or agent runs. `verify-secret-guard.sh` checks the
invocation the block actually documents (`docs.invocation`).

### YAML is read by structure

A line-local reader misses where Helm and Kubernetes put credentials. The viewer tracks
indentation instead, stdlib only, and redacts:

- the body of a `key: |` / `key: >` block scalar under a secret-shaped key
- `value:` in an `env` entry whose sibling `name:` is secret-shaped (`DB_PASSWORD`)
- children of a `secrets:` / `credentials:` parent, except switches and `imagePullSecrets`
- every `data`/`stringData` value in a document with `kind: Secret`, whatever the key is called
  — including each Secret inside a `kind: List`, as `kubectl get secrets -o yaml` returns
- credentials inside an ordinary block, such as a ConfigMap's embedded `application.yaml` or
  `app.env`

Text on stdin has no name to choose a grammar by, so it is read as YAML only when it carries a
manifest's `apiVersion:`/`kind:` signature. `helm get values` and `argocd app get -o yaml` carry
none, so `redact-view --yaml -` names the format, and the hook passes `--yaml` whenever it routes
a cluster-API read. Reading stdin, the viewer writes its header to stderr, so its output stays
valid JSON or YAML for a filter downstream. It also finds a column-0 JSON document among flat
log lines (`WARN[…]` merged in by `2>&1`) without reshaping structured YAML, and it accepts up to
256 MiB, because cluster output dwarfs a config file. A diff on stdin (`--diff`, which the hook
passes for `argocd app diff`, or text with a hunk header or Argo CD's `=====` header) is redacted
fail-closed: every value on every line is fingerprinted except the readable `name`, `kind` and
`apiVersion`, because a diff shows a changed value without the context that would mark it
secret.

### Cluster-API reads are routed by command, not path

`argocd app get APP -o json`, `argocd app manifests`, `argocd app diff`, `kubectl config view`,
`helm get values|manifest|all|hooks`, `helm template`, and `kubectl get … -o yaml|json|kyaml` print
credentials without naming a file, so no path rule sees them. The hook inserts `| redact-view
--yaml -` straight after the producer, before any `jq` or `head`, so field selection still works on
redacted text. Clean output passes byte-identical. A template output on a Secret (`-o jsonpath=…`,
`go-template`, `--template`) and an extraction verb downstream of a producer (`| base64 -d`) are
denied. A producer inside a quoted script or a heredoc the shell expands, and output redirected
anywhere but `/dev/null`, are asked about. A file of any name can be printed raw later, so a
redirect is not proof of silence. Matching reads the command the way the shell does: line
continuations are joined, and quoted words are unquoted (`'kubectl'`, `-o 'yaml'`). The producer
list is data in `secret-file-guard.py`, one line per tool. `kubecolor` counts as `kubectl`. A
producer or credential read inside a quoted script asks when an allowlisted runner (`sh -c`,
`eval`, `su -c`, `script -c`, a heredoc fed to `python3` or `make`) sits earlier in the same step,
and a read whose path is a variable always goes through the viewer. `kubectl config view` is
always routed; a template output on it passes only over `current-context`, `contexts`, `clusters`
or `preferences`, and `-o yaml|json` beats `--template` as it does in kubectl. A boolean shorthand
joined to `-o` (`-Ao yaml`) is read as `-o`. The viewer reads kyaml, kubectl's flow-style YAML, and
redacts it like any other document. ADR 0026 sets the scope: a binary reached through a variable or
an alias (`$k get secret …`), an interpreter one-liner, and a script file run later are the
cooperative-guard limit below.

`secret-scan` derives its answer from the viewer's own redaction count. The two cannot disagree,
so a file the scanner flags is never printed raw by the viewer.

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
