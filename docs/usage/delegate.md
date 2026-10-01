# Delegate — sending bulk work to a cheaper agent

To **delegate** is to hand one scoped piece of work to a cheaper agent running as a **separate CLI
process**, while your session stays on the model you are talking to. The point is to spend this
session's context and quota on judgment, and let something cheaper do the bulk.

The separate process is the mechanism, not a detail. An agent CLI resolves one endpoint per
process — subagent frontmatter, model pickers and environment overrides all resolve _inside_ it — so
a second tier needs a second process with a different environment. Everything else in the suite
exists to make that second process safe to talk to: who may receive the work, whether you agreed to
send it, and what is allowed to come back.

Two diagrams give the shape of it:

- **[The dispatch lifecycle](diagrams/delegate-dispatch.html)** — assessed, approved, dispatched,
  returned, and verified, with the two ways a dispatch bounces: the sub-agent asks back, or the
  dispatcher refuses.
- **[The topology](diagrams/delegate-topology.html)** — the cascade that decides which agents a repo
  may use, the consent gate and dispatcher that every dispatch passes through, and the three party
  classes an agent can sit in.

The suite is three skills, met in order: declare the agents, wire a repo, then run dispatches. It
is a **personal** suite — it depends on what one machine can reach — so the link scripts skip it
unless you pass `--personal`. All three are `experimental`.

---

## Situation 1 — you have a cheaper model and nothing uses it

You run a local model in LM Studio, or you have a second CLI configured against a cheaper tier, and
every bulk rename still goes through your primary assistant.

Start with what the machine can actually reach:

```text
python3 "$SKILL/scripts/register-delegate-agents.py" probe
```

`probe` is read-only. It lists agent CLIs on `PATH`, local runtimes and their loaded models, and
existing config dirs. Your primary assistant's own config dir is listed but marked as not a
delegate — pointing a sub-agent at it would run the session you are already in.

Then declare an agent, and name your primary so that **party** means something:

```text
python3 "$SKILL/scripts/register-delegate-agents.py" add \
  --name local-qwen --adapter copilot --base-url http://localhost:1234/v1 --model MODEL_ID
python3 "$SKILL/scripts/register-delegate-agents.py" set-primary --name claude
```

Two choices here trip people up:

- **The adapter must match the endpoint's protocol, not your preference.** LM Studio and Ollama
  speak the OpenAI API, which an Anthropic-protocol CLI cannot talk to at all. A local model needs
  `copilot` (via BYOK) or `codex` (via `--local-provider`), never `claude` with a different base
  URL. Prefer `copilot`: `codex` emits a mid-conversation system message that some chat templates
  reject with a 500.
- **The model must support native function calling.** One that writes `<tool_call>` as text has not
  called anything. The dispatcher detects that shape and reports the run as blocked rather than
  handing you prose that changed nothing.

To adopt a CLI you already run under its own config dir, point at the directory instead
(`--config-dir ~/.some-config-dir`). Model, endpoint and credential come from that setup, so nothing
is restated and nothing can drift. Never pass a token on the command line; it lands in your shell
history.

Declaration is [`register-delegate-agents`](../../skills/personal/register-delegate-agents/SKILL.md).

### Where an agent may be defined

The roster is a **cascade**: every ancestor directory may contribute one `.agents/delegate.json`,
`$HOME` is always included, and nearest wins. There is no git-root special case, so a workspace
directory holding many repos can carry policy for all of them.

| Layer                          | Typical use                        | May define agents?   |
| ------------------------------ | ---------------------------------- | -------------------- |
| `~/.agents/delegate.json`      | what this machine can reach at all | yes                  |
| a workspace dir outside a repo | policy for every repo beneath it   | yes                  |
| a repo's own `.agents/`        | this project's restrictions        | **no — narrow only** |

The last row is the one that matters. A committed manifest that could define an agent would add an
egress target to every clone of the repo through an ordinary pull request. So definitions live in
layers that cannot be committed, and a repo can only **narrow**: `allow` intersects,
`neverDelegate` unions, budgets take the minimum, `mode` only tightens (`off` beats `manual` beats
`auto`). No layering order and no unexpected ancestor file can widen what the machine permits.

---

## Situation 2 — wiring a repo so its agents know delegation exists

A declared agent does nothing until a repo is wired to it. From inside the repo:

```text
python3 "$SKILL/scripts/manifest/resolve.py" --scope "$REPO"      # what this repo may use
bash "$SKILL/scripts/setup-delegate-agent.sh" "$REPO" --tools claude --dry-run
bash "$SKILL/scripts/setup-delegate-agent.sh" "$REPO" --tools claude
bash "$SKILL/scripts/verify-delegate-agent.sh" "$REPO"
```

That installs five pieces, all visible in [the topology](diagrams/delegate-topology.html):

1. **The dispatcher**, `.agents/bin/delegate-run` — records consent, scans for credentials, runs the
   agent headless under hard caps, and prints **one line of JSON**. Everything verbose stays on disk
   under `.agents/delegate/`.
2. **The adapters**, one per CLI (`claude`, `codex`, `copilot`, `gemini`), translating the dispatch
   into that CLI's flags and its output back into one shape.
3. **The consent gate**, a `PreToolUse` hook that refuses a dispatch which skipped consent, refuses a
   direct call to the backend wrapper, and gates reads of credential-shaped paths.
4. **The routing block** in `AGENTS.md` — the roster in rank order, each agent's party class, and
   what is worth delegating. Every agent in the repo reads it, so none has to guess.
5. **Credential scanning** through `trivy`, which is required. The scan is fail-closed: a scanner
   that cannot run looks exactly like a clean scan, so without `trivy` every dispatch refuses.

Before applying, **the setup skill names every third-party agent and waits.** That is not
ceremony. A third-party agent means source code reaches someone who cannot already see it, which
inverts what the routing block says about sensitive work.

Wiring is [`setup-delegate-agent`](../../skills/personal/setup-delegate-agent/SKILL.md). Re-running
it after the roster changes rewrites the managed block in place and leaves `git status` clean when
nothing changed.

### Party, not distance

Every agent resolves to one of three party classes, and the class — not whether it is remote — is
what decides where work may go:

| Party         | What it means                                                        |
| ------------- | -------------------------------------------------------------------- |
| `local`       | The work never leaves the machine.                                   |
| `same-party`  | The vendor already running your primary assistant; adds no observer. |
| `third-party` | Anyone else; adds an observer.                                       |

This is what lets a project say _"frontier Claude is fine, that gateway is not"_ — something
`local` versus `remote` cannot express, because both of those are remote. Anything unrecognised
resolves to `third-party`: guessing downward is the only mistake here with real consequences.

---

## Situation 3 — a mechanical task, and you want it done cheaply

A codemod across forty files, docstrings for a module, a pile of CI logs to triage. This is the
loop in [the dispatch lifecycle](diagrams/delegate-dispatch.html), and
[`run-delegate-agent`](../../skills/personal/run-delegate-agent/SKILL.md) is its discipline.

### Assess, then ask — with the reasoning

Weigh four independent things. A task can be perfectly mechanical and still be a bad delegation.

| Axis      | Ask                                                          | Disqualifying answer                                  |
| --------- | ------------------------------------------------------------ | ----------------------------------------------------- |
| **Fit**   | Is the work mechanical, with a checkable definition of done? | Needs design judgment, or "done" is a matter of taste |
| **Size**  | Do the files it must read fit the agent's context window?    | One file, or the set, blows the window                |
| **Party** | Is the agent local, same-party or third-party?               | Third-party, and the material is confidential         |
| **Risk**  | What does a wrong cheap edit cost, given the allowlist?      | Writes outside a worktree with no test to catch it    |

Then ask the user, and **show the assessment, not just the question** — the agent, its party class,
what will be touched, the allowlist, and your recommendation, including when that recommendation is
not to delegate. An approval prompt with no reasoning trains reflexive clicking.

Size is estimated, not hoped: roughly bytes ÷ 4 ≈ tokens for everything the agent must open. The
dispatcher enforces the same arithmetic — a brief whose named files exceed 70% of the agent's window
is refused before it runs. A delegation that overflows fails in a way that looks like success:
truncated edits and a confident summary.

### Record consent, then dispatch under it

```text
.agents/bin/delegate-run --approve docstrings-parser --class docstring --allow 'Read,Grep,Glob,Edit'
.agents/bin/delegate-run --task .agents/delegate/dispatch/docstrings-parser.md \
  --approved docstrings-parser --kind docstring --worktree
```

The approval record names the agent, the class and the allowlist. The dispatch must match it:

- **`--kind` is checked** against what the agent is declared for. A kind it does not serve bounces
  as `misrouted`, and "why did this go there" has a written answer afterwards.
- **The allowlist must be identical** to what was approved. Narrowing and widening cannot be told
  apart textually, so any change bounces for re-approval.
- **`--worktree` for anything that writes.** It turns a wrong edit from something you have to find
  into something you can throw away.

### Write the brief like the reader has amnesia

The brief is the entire interface. The sub-agent has none of this conversation.

1. **Goal** — one sentence, outcome not method.
2. **Entry points** — repo-relative paths. It will not find them by intuition.
3. **Definition of done** — the command that proves it (`pnpm test src/parser`).
4. **Out of scope** — what not to touch, explicitly.
5. **Conventions** — or point at `AGENTS.md`.

No "the file we discussed", no "as above". There is no above.

### Verify the claim, then report

One line of JSON comes back. Read `.result`; open `.raw` or `.log` only when triaging a failure —
that is the output you delegated in order not to read.

**`status: ok` is a claim, not a verdict.** Run the definition-of-done command yourself before you
report success. A green assertion over a red test turns a visible failure into an invisible one, and
that is the error that costs most downstream. Then report what was asked, what changed by path,
whether the check passed and how you know.

---

## Situation 4 — the sub-agent asks back

`status: question` means the sub-agent hit something it cannot know and asked instead of guessing.
That is the protocol working.

```text
.agents/bin/delegate-run --resume SESSION_ID --prompt "use the v2 error type" --approved docstrings-parser
```

Answer from the brief and the code if you can, and escalate to the user only when you genuinely do
not know either. Rounds are capped, three by default: a task that needs a fourth clarification was
under-briefed, so rewrite the brief once or keep the work.

One question is not a question: a sub-agent asking for wider permissions. The dispatcher turns that
into `misrouted` rather than relaying it, because forwarding it would let the sub-agent negotiate its
own scope through you. Re-brief within the existing scope, or do the task yourself.

Ask-back is best-effort on `copilot` and `gemini`, which cannot force an output schema; a blocked
sub-agent there may return prose instead of a structured question. `list` warns about it.

---

## Situation 5 — the dispatcher refuses

Some things are not yours to approve. The dispatcher refuses them before the agent starts, whatever
the approval says:

| Refusal                                               | Exit | What to do                                      |
| ----------------------------------------------------- | ---- | ----------------------------------------------- |
| Brief names a never-delegate path                     | 77   | Reference the value by name, not by path        |
| Brief carries `sensitivity: restricted`               | 77   | Stop. Do it in a session with board access      |
| Kind the agent does not serve                         | 77   | Pick the agent that serves it, or re-assess     |
| Files over 70% of the agent's window                  | 77   | Split per file or directory, or a larger tier   |
| Allowlist differs from the approval                   | 77   | Re-approve; never widen to make a run pass      |
| `bypassPermissions`, in any mode                      | 77   | Not available to a delegated dispatch           |
| No approval on file, or approved for another agent    | 78   | Record consent first                            |
| A credential in the brief                             | 78   | A brief-authoring bug; reference it by name     |
| A credential in the result                            | 78   | Blocked on the way back, before your transcript |
| `trivy` missing, or failing its known-positive canary | 78   | Install or fix the scanner                      |

Exit 77 is **misrouted** — the task should not go to this agent in this shape. Exit 78 is **config
or consent** — something the dispatch needs is absent. A sub-agent that stops itself returns
`status: blocked` with exit 70; the dispatcher's own exit codes are listed at the top of
`delegate-run`.

The restricted refusal is worth dwelling on. A handoff marked `sensitivity: restricted`
([ADR 0005](../adr/0005-sensitivity-is-a-handling-flag.md)) is never dispatched to any agent. `handoff
export` already refuses to render a brief for one; the dispatcher catches the routes that skip it —
a board document handed in directly, or a brief written by hand. It is a stop, not an obstacle.

A refusal sends you back to the start of the lifecycle: re-brief once within scope. Two failures on
one task mean it was misrouted, not under-explained — keep it.

### When the endpoint does not answer

If the chosen agent is unreachable and you did not name it explicitly, the dispatcher walks down the
rank order to the next permitted agent that answers. It fails over **only on reachability** — a poor
result never triggers it, because retrying elsewhere would move work across a party boundary a
policy deliberately drew. And since the approval names the agent, a failover bounces for
re-approval rather than proceeding quietly.

---

## Recommended use-cases

Delegation is worth its overhead when the work is **mechanical, bulky, and checkable** — and when
where it would go is somewhere the material may go.

| Scenario                                                 | Pattern                                         | Reach for                                  |
| -------------------------------------------------------- | ----------------------------------------------- | ------------------------------------------ |
| The same edit repeated across many files                 | One dispatch per directory, in a worktree       | `--kind codemod --worktree`                |
| Docstrings or comments for a module                      | Auto-approved kind on a local agent             | `mode: auto`, `autoApprove: ["docstring"]` |
| A pile of logs nobody needs to read closely              | Read-only dispatch, summary back                | `--allow 'Read,Grep'`                      |
| Running a build or test suite and reporting pass/fail    | Narrow `Bash` scope                             | `--allow 'Bash(pnpm test *)'`              |
| A project that may use frontier Claude but not a gateway | Narrow the repo layer                           | `allow --names … --layer .`                |
| Production config that must never leave the session      | Never-delegate path in the committed repo layer | `never --paths 'config/prod/**' --layer .` |
| A restricted handoff                                     | Do not delegate                                 | —                                          |

### Auto mode, precisely

`mode: auto` does **not** mean "never ask". It removes the prompt only for kinds listed in that
agent's `autoApprove`, and only when the dispatch is read-only or isolated in a worktree. A
pre-approved kind that could write outside a worktree is refused at dispatch time — an unreviewed
write is the failure you cannot detect afterwards. Everything else still prompts.

### A team policy that actually binds the team

A restriction in a workspace directory outside any repo is **machine-local**: it protects you, and
not a colleague who clones one of those repos. Only the committed per-repo layer binds everyone —
and it can only narrow, which is exactly why it is safe to commit.

### When not to delegate

- **The task needs this conversation's context.** A fresh process cannot inherit it, and you will
  spend more turns explaining than the work would take.
- **Architecture, debugging, security review, or ambiguous requirements.** A cheap model asked to
  exercise judgment produces plausible work that costs more to check than to have done.
- **There is no definition-of-done command.** Without one you cannot verify the claim, and an
  unverified claim is worse than no delegation.
- **The user said "don't delegate"**, "do it yourself" or "keep this here". That overrides auto mode
  and every heuristic.

Proactive delegation needs something **countable**: the same edit repeats across several files, the
input is bulk output nobody needs to read closely, or the task has a command that proves it. If you
cannot name one, do not propose it.

---

## Delegate versus export

The handoff suite has its own way to send work elsewhere, and the two are easy to confuse.
**Delegate** dispatches scoped work to a cheaper agent you run, under a consent gate, and the result
comes straight back into your session. **Export**
([`delegate-handoff`](../../skills/engineering/delegate-handoff/SKILL.md)) sends a brief to an
executor outside the board entirely — a contractor, another team, a tool without the protocol — and
what comes back is imported as a claim you still close. Use delegate for bulk you will verify in the
next minute; use export for work someone else owns until it returns.

---

## What the credential rule does, and where it stops

Three boundaries, not equally strong:

- **Into a sub-agent — enforced.** The brief is scanned before dispatch, credential-shaped variables
  are stripped from the child environment, and never-delegate paths are refused regardless of
  approval.
- **Back from a sub-agent — enforced.** The raw result is scanned before any of it reaches your
  context.
- **Inside your own session — prevention only.** A tool result enters the transcript before any hook
  runs. Where the [secret guard](secret-guard.md) is installed and can run, own-session reads are
  left to it, since it masks rather than asks. Where it is not, the consent gate asks before a
  credential-shaped read.

Stated exactly: secrets are never passed to a sub-agent, sub-agent output is scanned before it
enters context, and known-secret-path reads are gated in the main session. A command can still print
one by accident. Scanning is a net, not a wall — `trivy`'s default ruleset does not flag bare AWS
access-key pairs — so do not paste a credential into a brief to save a step.

The consent gate is cooperative, not a sandbox. It turns skipping the assessment from an omission
into a deliberate act. The real boundary is the tool allowlist and the worktree.

---

## The pieces, and which skill owns each

| Piece                                        | Skill                                                                                 |
| -------------------------------------------- | ------------------------------------------------------------------------------------- |
| Declare agents, narrow per repo, set primary | [`register-delegate-agents`](../../skills/personal/register-delegate-agents/SKILL.md) |
| Install dispatcher, adapters, gate, routing  | [`setup-delegate-agent`](../../skills/personal/setup-delegate-agent/SKILL.md)         |
| Assess, ask, brief, dispatch, verify, report | [`run-delegate-agent`](../../skills/personal/run-delegate-agent/SKILL.md)             |

## When it misbehaves

There is no `repair-` skill: everything the suite manages is files it wrote, so repair is "re-run
setup". Start with the read-only verifier, which exercises the consent gate with synthetic input and
resolves the cascade without ever dispatching or contacting a backend:

```text
bash "$SKILL/scripts/verify-delegate-agent.sh" "$REPO"
```

To see what a repo permits and why — each layer, whether it is committable, what was narrowed and by
which file, and any capability warnings:

```text
python3 "$SKILL/scripts/register-delegate-agents.py" list --scope .
```

Three states that look like bugs and are not:

- **Every dispatch is `blocked` with "secret scanner unavailable".** `trivy` is missing. That is the
  fail-closed contract working.
- **A run "succeeds" with `blocked` naming a tool call rendered as text.** Either the model lacks
  native function calling, or the adapter exposed it no tools. On `copilot`, a Claude-style tool
  name passed to `--available-tools` filters out every tool; the adapter maps intent onto permission
  kinds for exactly that reason.
- **A 400 from a translating gateway.** Claude Code speaks a richer protocol than most
  non-Anthropic backends accept, and each mismatch has a known environment-variable shim. Turn one
  on when you have the error that justifies it, not before — see
  [backend shims](../../skills/personal/setup-delegate-agent/references/backend-shims.md).
