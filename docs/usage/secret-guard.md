# Secret guard — keeping credential values out of the transcript

An agent that can read your `.env` will, eventually, print it. The guard's job is to make the file
stay **usable** — an agent can still see its shape, its keys, whether two environments share a token
— while the values themselves are replaced by fingerprints.

Install it with
[`setup-secret-guard`](../../skills/engineering/setup-secret-guard/SKILL.md).

---

## Why a read-path guard specifically

Every other credential check in this repo fires when content is **written** or **sent** — the
handoff CLI scanning a release note, the delegation consent gate. None of them can help with a read,
because **a tool result enters the transcript before any hook can react to it**, and that transcript
persists to disk.

There is no after-the-fact redaction. Once a value is in the transcript it is in the transcript.
That is why the rules here are absolute rather than advisory, and why the read path was the gap
worth closing.

---

## What actually happens to a read

**[Open the read-path diagram](diagrams/secret-guard-read-path.html)** alongside this section.

A `PreToolUse` hook sits in front of `Bash`, `Grep` and `Read`. It classifies the call and takes one
of four actions. In rough order of what it checks:

| The call                                                           | What happens | Why                                                                                         |
| ------------------------------------------------------------------ | ------------ | ------------------------------------------------------------------------------------------- |
| `Grep` in content mode at a credential file                        | **deny**     | It would print raw matching lines. Pipe from the viewer instead.                            |
| `base64`, `openssl`, `xxd`, `strings`, `source`, `curl`, `pbcopy`… | **deny**     | The whole purpose is to obtain the raw value. Redaction cannot help.                        |
| A filter aimed at a credential file _in the same stage_            | **deny**     | `grep TOKEN .env` slices values out. `redact-view .env \| grep TOKEN` is fine.              |
| `cat` / `head` / `tail` / `less` on a credential file              | **rewrite**  | Silently re-run through `redact-view`. You get the file; values are fingerprinted.          |
| A read inside `docker exec`, `ssh`, `kubectl exec`…                | **ask**      | The host's viewer has no meaning in that namespace, so no rewrite both works and withholds. |
| `Read` on a config-shaped file whose _content_ holds a credential  | **ask**      | The `Read` tool returns the file raw and no hook can filter its output.                     |
| Everything else                                                    | **allow**    |                                                                                             |

A rewritten read looks like this — structure intact, value gone:

```text
password: <redacted len=25 sha256:585c2252>
```

The digest derives from the real value, so **the same secret shows the same tag in two files**. That
answers "do staging and production share this token?" without disclosing either.

Files with nothing secret in them pass through **byte-identical**, so the detour is invisible on
ordinary config.

### It is content-driven, not just filename-driven

An ordinary-looking `appsettings.json` holding a `database.password`, or a connection string with an
embedded `Password=`, is redacted too. And YAML is read by **structure**, not line by line, because
that is where Helm and Kubernetes actually put credentials — a `key: |` block scalar under a
secret-shaped key, a `value:` whose sibling `name:` is `DB_PASSWORD`, every `data` value in a
document with `kind: Secret`.

Raw key material (`*.pem`, `id_rsa`, `*.p12`) has no structure worth showing, so it is withheld
wholesale — you get the type, a byte count and a digest.

---

## The two verbs you will actually type

```text
"$HOME/.claude/bin/redact-view" svc-a/.env            # the file, values fingerprinted
"$HOME/.claude/bin/redact-view" --all svc-a/config.yml  # when the KEY names are sensitive too
"$HOME/.claude/bin/secret-scan" svc-a/deploy.yml      # exit 0 = found, 1 = clean, names the rule
```

Use `secret-scan` before writing or sending content you did not author. It names the rule that
matched, never the value.

**They are deliberately not on `PATH`.** A generic name on `PATH` can resolve to another program
first, and for a redactor that failure is silent — output that looks redacted, printed raw. So a
bare `redact-view` failing with `command not found` is expected, not a broken install. Alias it in
an interactive shell if you want the short name, where it cannot shadow what a script runs.

---

## Situation — you actually need the plaintext

You usually do not. **A process that consumes a secret needs no read from you.** `npm run deploy`
and `kubectl --kubeconfig=...` already work, because the child process reads the file itself and
inherits the environment. You never need to see the value to let something else use it.

If a task genuinely requires a plaintext secret, stop and say so. That is the operator's call, not
the agent's — and the answer is never to route around the guard: no copying to an unwatched path, no
base64, no reading it through a language interpreter, no renaming to dodge a pattern.

---

## Where it is installed, and why that layer

Consumers resolve the engine as the project's `.claude/`, then `$HOME/.claude/`, then
`$SECRET_GUARD_HOME`. **The home layer is load-bearing**
([ADR 0008](../adr/0008-one-credential-engine-resolved-through-a-cascade.md)), because a leak is a
property of the machine and the transcript, not of the repository. The guard has to be on for a repo
nobody installed into, so "enforce it everywhere" means one install, not one per project.

The repository layer exists only to **add** — extra path patterns, and `safe_keys` exceptions that
suppress redaction for a key already matched. It may never remove a path from the deny set.

> A `safe_keys` entry is a security change wearing the clothes of configuration. It is the easiest
> layer to modify by ordinary pull request, and it suppresses redaction. Review additions as
> security changes.

Strictly additive-only was rejected, deliberately: unusable false positives get the whole guard
switched off, which is worse than a scoped exception.

---

## What it does when it breaks

The posture differs by call site, and the asymmetry is the point:

| Call site        | Engine absent                               | Engine present but throwing |
| ---------------- | ------------------------------------------- | --------------------------- |
| Read path        | degrade to path-only matching, and announce | fail **open**               |
| Write / outbound | degrade to the caller's own check, announce | fail **closed**             |

The read path fails **open** because a wedged session is worse than a bounded exposure — a guard
that denies every command is a guard that gets uninstalled. It announces the degrade once per
session rather than silently, because a control that quietly weakens is trusted further than it has
earned.

**Absent and broken are different failures.** Failing closed on _absent_ would refuse every write on
every machine that never installed the guard.

---

## The part that is documentation, not enforcement

Claude Code enforces this with a hook that can rewrite a command before it runs. Other tools get
deny/ask rules where their hook model allows it, and **where a tool cannot intercept, these rules
hold only because the agent follows them.** The `AGENTS.md` block the installer injects is that
instruction.

So the guard is two things at once: a mechanism where a mechanism is possible, and a written rule
everywhere else. Knowing which one you are relying on matters when you are deciding how much to
trust it.

The standing rules, in short:

- Never route around the guard.
- Record a credential's **name** — an environment variable or a secret-manager reference — never its
  value. In every file, every commit message, every handoff document.
- A refusal is not a puzzle to solve. If you need the value, ask the operator.
