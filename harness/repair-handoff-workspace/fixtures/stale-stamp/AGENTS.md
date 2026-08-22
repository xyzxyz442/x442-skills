# AGENTS

Shared guidelines.

@guidelines

<!-- handoff:begin (managed by setup-handoff — do not edit between markers) -->

## Handoff Coordination

This repo coordinates cross-session / cross-repo work through a lease-based **handoff board**
in `.agents/handoff/`. **Claim before you work. Release when you stop.**

Before starting any tracked work, check the board and claim your unit. `claim` fails if someone
holds a live lease — pick another handoff or tell the user who holds it. Do **not** edit a handoff
doc you do not hold the lease for (the hooks block it).

```text
.agents/handoff/handoff list
.agents/handoff/handoff claim HANDOFF_ID "what you're doing"
```

File a new handoff when your work hands off to another session/repo, or when you find work you
will not finish here (SEVERITY is low, medium, or high):

```text
.agents/handoff/handoff new HANDOFF_ID --title "..." --severity SEVERITY
```

Titles must not contain `:` — a colon breaks the doc's YAML frontmatter in markdown previews. Use
an em dash instead (`Handoff — auth suite`); the tool folds any colon you pass to `—` anyway, in
`--title`, `--note`, `--audience`, `--severity`, and `--blocked-on`.

Handoffs have a **type**. The default is `coordination` (the claim/release work item above). A
`standalone` handoff is a self-contained reference/knowledge doc (porting guide, eval report,
compaction brief) — it needs **no claim**, is freely editable, and is listed apart. Create one with
`--standalone`, or bring an existing file onto the board with `import`:

```text
.agents/handoff/handoff new HANDOFF_ID --standalone --title "..."
.agents/handoff/handoff import ./FILE.md --standalone
```

Handoff docs are **committed to the repo and its git history** — never paste keys, secrets,
passwords, or PII into one. Redact them; if the next agent needs a credential, prompt the user and
supply it via a safe channel (env var, secret-manager reference, or out-of-band), recording only
its name in the doc.

Release when you stop, with an honest status. `done` means **verified against the live code**,
not "the doc says resolved" — it requires `--verified-by`. `blocked` requires `--blocked-on`
(another handoff id, or "external: ..."). `INDEX.md` is generated; never hand-edit it.

```text
.agents/handoff/handoff release HANDOFF_ID --status open
.agents/handoff/handoff release HANDOFF_ID --status blocked --blocked-on OTHER_ID
.agents/handoff/handoff release HANDOFF_ID --status done --verified-by "how you verified live code"
```

Sending work to someone with no board access — a contractor, another team, an AI tool without this
protocol — goes through `export`/`import --result`, not a pasted doc:

```text
.agents/handoff/handoff export HANDOFF_ID --to WHO
.agents/handoff/handoff import --result .agents/handoff/briefs/HANDOFF_ID.brief.md
```

`export` claims the id and renders a self-contained brief to `.agents/handoff/briefs/` —
commit it so the executor can pull it. `import --result` splices their reported result onto the
doc but **never sets `status`** — `done` stays your call, made after you reproduce their evidence
yourself, the same as any other release.

Full protocol: [.agents/handoff/README.md](.agents/handoff/README.md).

<!-- handoff:end -->
