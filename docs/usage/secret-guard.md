# Secret guard — keeping credential values out of the transcript

An agent that can read your `.env` will print it sooner or later. So will an agent that runs
`kubectl get secret`. The guard makes the output stay **usable**: an agent can still see its shape
and keys, and whether two environments share a token. The values themselves are replaced by
fingerprints.

Install it with
[`setup-secret-guard`](../../skills/engineering/setup-secret-guard/SKILL.md). This page is the map;
that `SKILL.md` is the reference for flags and internals.

---

## Why a read-path guard specifically

Every other credential check in this repo fires when content is **written** or **sent**: the
handoff CLI scanning a release note, or the delegation consent gate. None of them can help with a
read, because **a tool result enters the transcript before any hook can react to it**, and that
transcript persists to disk.

There is no after-the-fact redaction. Once a value is in the transcript it stays there. That is why
the rules here are absolute rather than advisory, and why the read path was the gap worth closing.

---

## What happens to a command

A `PreToolUse` hook sits in front of `Bash`, `Grep` and `Read`. It classifies each call and takes
one of four actions: **rewrite** it so the output goes through the redacting viewer, **ask** you
first, **deny** it, or **allow** it untouched. These are real decisions from the installed hook:

| The call                                                       | What happens | Why                                                                                     |
| -------------------------------------------------------------- | ------------ | --------------------------------------------------------------------------------------- |
| `cat .env` (also `head`, `tail`, `less`)                       | **rewrite**  | Re-run through `redact-view`. You get the file with its values fingerprinted.           |
| `kubectl get secret db -o yaml \| head -20`                    | **rewrite**  | The viewer is inserted straight after `kubectl`, before `head`.                         |
| `argocd app get svc-a -o json \| jq .spec`                     | **rewrite**  | The same, so `jq` still selects fields, now from redacted text.                         |
| `kubectl get pods`                                             | **allow**    | Table output carries no values.                                                         |
| `kubectl get secret db -o jsonpath={.data.password}`           | **deny**     | A template prints one bare value, and no viewer can redact a value without structure.   |
| `base64 .env` (also `openssl`, `xxd`, `strings`, `source`, …)  | **deny**     | The whole purpose is to obtain the raw value, so redaction cannot help.                 |
| `grep TOKEN .env`                                              | **deny**     | It slices values out. `redact-view .env \| grep TOKEN` is fine.                         |
| `helm get values svc-a > out.yaml`                             | **ask**      | The viewer cannot reach a redirected file, and a later read could print it raw.         |
| `kubectl exec -it svc-a -- cat /app/.env` (also `docker`, ssh) | **ask**      | The host's viewer does not exist in that namespace, so no rewrite both works and hides. |
| `Read` or `Edit` on a credential-_named_ file (`.env`, a key)  | **deny**     | Settings deny rules, because the `Read` tool's output cannot be filtered at all.        |
| `Read` on a config file whose _content_ holds a credential     | **ask**      | The `Read` tool returns the file raw, and no hook can filter its output.                |
| Everything else                                                | **allow**    |                                                                                         |

A rewritten read looks like this, with the structure intact and the value gone:

```text
password: <redacted len=25 sha256:585c2252>
```

The digest derives from the real value, so **the same secret shows the same tag in two files**. That
answers "do staging and production share this token?" without disclosing either. Output with nothing
secret in it passes through **byte-identical**, so the detour is invisible on ordinary config and
ordinary cluster reads.

**[The read-path diagram](diagrams/secret-guard-read-path.html)** shows the file half of this
table. It predates cluster routing, which the next section covers.

---

## Situation — you read a credential file

You do nothing different. Type `cat svc-a/.env` and the guard runs
`"$HOME/.claude/bin/redact-view" svc-a/.env` instead.

**It is content-driven, not only filename-driven.** An ordinary-looking `appsettings.json` holding
a `database.password`, or a connection string with an embedded `Password=`, is redacted too. So is a
read whose path is still a shell variable (`cat "$CONF"`), because the guard cannot know what the
variable names. A clean file still comes back byte-identical.

**YAML is read by structure**, because that is where Helm and Kubernetes put credentials:

- the body of a `key: |` block scalar under a secret-shaped key;
- a `value:` whose sibling `name:` is `DB_PASSWORD`;
- every `data` and `stringData` value in a `kind: Secret`, whatever the key is called, including
  each Secret inside a `kind: List`;
- children of a `secrets:` or `credentials:` parent, except on/off switches and
  `imagePullSecrets`;
- credentials inside an embedded block, such as a ConfigMap's `application.yaml`.

Raw key material (`*.pem`, `id_rsa`, `*.p12`) has no structure worth showing, so it is withheld
whole: you get the type, a byte count and a digest.

---

## Situation — you read from a cluster

A **cluster-API read** prints credentials it fetched from a cluster or a deployment controller. It
names no file, so no rule keyed on file paths can see it. One agent ran
`argocd app get APP -o json | jq …`, and an Application's inline Helm values printed a client secret
raw. [ADR 0025](../adr/0025-a-cluster-api-read-is-routed-by-command-not-path.md) records that
incident and the design that answers it.

The guard recognises these commands, the **producers**, by their own shape:

| Producer                                                 | Routed when                                      |
| -------------------------------------------------------- | ------------------------------------------------ |
| `argocd app get`, `argocd app manifests`                 | always                                           |
| `argocd app diff`                                        | always, as a diff (see below)                    |
| `helm get values\|manifest\|all\|hooks`, `helm template` | always                                           |
| `kubectl get` (and `kubecolor get`)                      | with `-o yaml`, `-o json`, `-o kyaml` or `--raw` |
| `kubectl config view`                                    | always                                           |

**The viewer goes straight after the producer**, not at the end of the pipeline:

```text
kubectl get secret db -o yaml | "$HOME/.claude/bin/redact-view" --yaml - | head -20
```

So `jq`, `yq`, `head` and `grep` downstream still work, on redacted text with its structure intact.
On stdin the viewer writes its header to stderr, so the output stays valid JSON or YAML for that
filter.

Things to know when you work this way:

- **Your pipeline's exit status becomes the viewer's**, unless the shell runs with `pipefail`. Check
  a producer's own failure from its stderr, or set `pipefail`.
- **A diff shows which keys changed, not their new values.** A diff line has no surrounding context
  to mark a value as secret, so every value is fingerprinted except `name`, `kind` and
  `apiVersion`.
- **Flags are read the way kubectl reads them.** A boolean shorthand joined to `-o` (`-Ao yaml`)
  is `-A -o yaml`, and a quoted word (`-o 'yaml'`) is the word the shell passes.
- **kyaml works like YAML.** kubectl's flow-style output (`-o kyaml`) is parsed and redacted the
  same way, wherever the document starts: after stderr noise, a comment or a BOM. Piped output
  that does not parse is redacted fail-closed. One limit is pinned by a test: in a named file or a
  note, an unparseable kyaml-looking block may be prose, so it is left to the surrounding grammar.
- **`kubectl config view` is always routed.** kubectl hides passwords, tokens and certificate data
  on its own, but prints OIDC `auth-provider` secrets and exec-plugin `env` values raw. A template on
  it passes only when it reads `current-context`, `contexts`, `clusters` or `preferences`; a
  template that can reach `users` is denied.

And the shapes that are refused or asked about, because no rewrite can make them safe:

- A **template output on a Secret** (`-o jsonpath=…`, `go-template`, `--template`) is denied. Ask
  for `-o yaml` and select the field downstream instead; the field's key survives, its value does
  not.
- An **extraction verb after a producer** (`kubectl get secret db -o yaml | base64 -d`) is denied.
- **Output redirected to a file** is asked about. `> /dev/null` is fine.
- **`argocd app get --show-params`** is asked about: it prints Helm parameters as a table the
  viewer cannot read by structure.
- **A producer inside a quoted script** (`sh -c '…'`, `su -c`, `eval`, a heredoc fed to a shell or
  to `python3`) is asked about, because the viewer cannot be inserted into a script the guard does
  not run.

---

## Situation — you write or send something that quotes a credential

The read path is one half. The other half is `secret-scan`, which the handoff CLI and the
delegation gate run before content is committed or sent. It reads the same grammars as the viewer,
kyaml included, so a handoff `release` whose note pastes a Secret manifest is refused. The refusal
names the rule that matched, never the value.

Redact the text and re-run. Pass `--force-secret "<reason>"` only for a genuine false positive, and
say why the match is safe: the override is recorded in the document's Activity log.

Run `secret-scan` yourself before you write or send content you did not author:

```text
"$HOME/.claude/bin/secret-scan" svc-a/deploy.yml   # exit 0 = found, 1 = clean; names the rule
```

`secret-scan` derives its answer from the viewer's own redaction count, so the two cannot disagree:
a file `secret-scan` flags is never printed raw by the viewer.

---

## Situation — you actually need the plaintext

You usually do not. **A process that consumes a secret needs no read from you.** `npm run deploy`
and `kubectl --kubeconfig=...` already work, because the child process reads the file itself and
inherits the environment. You never need to see the value to let something else use it.

If a task genuinely requires a plaintext secret, stop and say so. That is the operator's call, not
the agent's. The answer is never to route around the guard: no copying to an unwatched path, no
base64, no reading it through a language interpreter, no renaming to dodge a pattern.

---

## The two verbs you will actually type

```text
"$HOME/.claude/bin/redact-view" svc-a/.env               # the file, values fingerprinted
"$HOME/.claude/bin/redact-view" --all svc-a/config.yml   # when the KEY names are sensitive too
"$HOME/.claude/bin/redact-view" --yaml -                 # stdin with no name, read as YAML
"$HOME/.claude/bin/secret-scan" svc-a/deploy.yml         # exit 0 = found, 1 = clean
```

**They are deliberately not on `PATH`.** A generic name on `PATH` can resolve to another program
first, and for a redactor that failure is silent: output that looks redacted, printed raw. So a bare
`redact-view` failing with `command not found` is expected, not a broken install. Alias it in an
interactive shell if you want the short name, where it cannot shadow what a script runs.

---

## Where the guard stops

The guard is **cooperative**. It routes the commands an honest agent, person or tool produces in
ordinary work. It does not sandbox a determined one, and it says so rather than pretending.
[ADR 0026](../adr/0026-the-secret-guard-closes-honest-shapes-and-free-fail-closed-gaps.md) draws
the line. These are **not** caught, by decision:

- a binary reached through a variable, an alias or a wrapper script (`k=kubectl; $k get secret …`);
- an interpreter one-liner (`python3 -c "…"`, `perl -e '…'`);
- a script file written and then run;
- quoting or encoding games whose only fix would add prompts to honest commands.

And, from the skill's own scope, a command that prints a secret without naming a credential path
or a producer: `env`, a build that echoes a variable, a stack trace.

The interpreter one-liner is pinned by a test, so the limit cannot change by accident. Process
isolation is the only thing that stops a determined command, and that is a different tool.

### Reporting a bypass

A finding is fixed when at least one of these holds:

1. **It is an honest shape**: something produced in ordinary work, like `2>&1` noise, `su -c '…'`,
   a `for` loop over files, or an aliased binary such as `kubecolor`.
2. **Its fix is free and fail-closed**: it makes the guard stricter and adds no prompt, denial or
   rewrite to any honest command.

Anything else is filed and recorded as the limit, not fixed. The reason is practical: chasing every
obfuscation adds prompts to honest commands, and a guard that prompts on honest work gets switched
off. When you report one, include the exact command and the decision the hook made.

One case is always fixed: a **regression**, a value the installed payload redacts that new code
prints raw, reproduced. Its fix must provably redact no less than the installed payload did.

---

## Where it is installed, and why that layer

Consumers resolve the engine as the project's `.claude/`, then `$HOME/.claude/`, then
`$SECRET_GUARD_HOME`. **The home layer is load-bearing**
([ADR 0008](../adr/0008-one-credential-engine-resolved-through-a-cascade.md)), because a leak is a
property of the machine and the transcript, not of the repository. The guard has to be on for a repo
nobody installed into, so "enforce it everywhere" means one install, not one per project.

```text
setup-secret-guard.sh             # the home layer, the one that matters
setup-secret-guard.sh REPO        # a repo's AGENTS.md block and pattern additions
verify-secret-guard.sh [--json]   # read-only health check
```

**The first install needs `--adopt`.** The installer compares what is already installed with its
payload and refuses on any difference unless you pass `--adopt`, and it backs up the old copy first.
The payload carries no personal paths, so it differs from any existing install on first contact. The
check protects you from later silent drift, not from a bad first install.

**`verify-secret-guard.sh` checks behaviour, not files.** It fires the hook with synthetic
payloads and asserts the decision. It never prints a fixture's value, even on failure.

The repository layer exists only to **add**: extra path patterns, and `safe_keys` exceptions that
suppress redaction for a key already matched. It may never remove a path from the deny set.

> A `safe_keys` entry is a security change wearing the clothes of configuration. It is the easiest
> layer to modify by ordinary pull request, and it suppresses redaction. Review additions as
> security changes.

Strictly additive-only was rejected on purpose: unusable false positives get the whole guard
switched off, which is worse than a scoped exception.

---

## What it does when it breaks

The posture differs by call site, and the asymmetry is the point:

| Call site        | Engine absent                               | Engine present but throwing |
| ---------------- | ------------------------------------------- | --------------------------- |
| Read path        | degrade to path-only matching, and announce | fail **open**               |
| Write / outbound | degrade to the caller's own check, announce | fail **closed**             |

The read path fails **open** because a wedged session is worse than a bounded exposure: a guard
that denies every command is a guard that gets uninstalled. It announces the degrade once per
session rather than silently, because a control that quietly weakens is trusted further than it has
earned. **Absent and broken are different failures.** Failing closed on _absent_ would refuse every
write on every machine that never installed the guard.

**A second check covers the failure the first cannot report.** A guard that wrongly denies is
reported in minutes; one that wrongly allows is reported never. So after the main classifier
decides nothing needs doing, a **backstop** re-asks the question per pipeline stage, token by token,
and asks you rather than staying quiet. It only ever asks, never rewrites. Its origin is a regex
defect that let `head -20 /etc/passwd; cat SECRETFILE` through with no decision at all
([ADR 0009](../adr/0009-a-backstop-that-only-asks.md)). The defect is fixed; the backstop stays.

---

## The part that is documentation, not enforcement

Claude Code enforces all of this with a hook that can rewrite a command before it runs. Other tools
get deny and ask rules where their hook model allows it, and **where a tool cannot intercept, these
rules hold only because the agent follows them.** The `AGENTS.md` block the installer injects is
that instruction.

So the guard is two things at once: a mechanism where a mechanism is possible, and a written rule
everywhere else. Know which one you are relying on before you decide how much to trust it.

The standing rules, in short:

- Never route around the guard.
- Record a credential's **name**, an environment variable or a secret-manager reference, never its
  value. In every file, every commit message, every handoff document.
- A refusal is not a puzzle to solve. If you need the value, ask the operator.
