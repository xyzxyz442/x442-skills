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

Full protocol: [.agents/handoff/README.md](.agents/handoff/README.md).

<!-- handoff:end -->
