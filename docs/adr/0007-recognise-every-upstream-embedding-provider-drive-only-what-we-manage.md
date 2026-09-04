---
status: accepted
date: 2026-09-05
---

# Recognise every upstream embedding provider, drive only what we manage

`code-review-graph` accepts five embedding providers. `setup-embeddings.sh` offers two. A future
reader will find that gap and try to close it — either by adding the other three to the menu, or by
re-adding the allow-list that used to sit in `embed-provider.sh`. Both are wrong, for different
reasons, and the reasons are worth writing down because each was arrived at through a defect.

## Context

The graph-hooks suite wraps CRG's embedding layer. CRG owns the provider set
(`embeddings.py::_VALID_PROVIDERS` — `local`, `openai`, `google`, `minimax`, `voyage`), the
credential contract for each, and a deliberate safety property: cloud providers require **explicit
opt-in** and emit a one-time stderr warning about source-code egress before first use
(`embeddings.py:885-892`).

Two of our own mechanisms sat on top of that and each broke it in a different direction.

**We kept a copy of the list.** `embed-provider.sh::resolve()` and `embed-health.sh` both hardcoded
`local | openai | google | minimax`. Upstream had five. A repo explicitly configured with the fifth
resolved to nothing, the refresh hook exited 0, and its vectors rotted to keyword mode in silence —
while the health check reported the repo as "no embedding provider configured", misdescribing a
correct setup as an absent one. The copy is the whole defect: it can only ever be right until the
next upstream release.

**We manufactured the opt-in that upstream withholds.** `resolve()` selected `google` or `minimax`
from the bare presence of `GOOGLE_API_KEY` / `MINIMAX_API_KEY` in the environment. A developer with
such a key exported for an unrelated service, installing graph-hooks, would have this repo's source
sent to a cloud embedding API on every commit and every end-of-turn, billed to them. CRG's egress
warning could not save them: `graph-refresh.sh:33` runs the embed as
`nohup ... > /dev/null 2>&1`, so the warning had nowhere to go.

Those two are the same mistake wearing different clothes — re-implementing a decision that belongs
upstream, and doing it worse than upstream does.

## Decision

**Recognise every provider. Drive only the two we manage.**

- `resolve()` keeps **no list**. Any non-empty `CRG_EMBEDDING_PROVIDER` is passed through. Validity
  is CRG's to judge; it raises `ValueError` on an unknown name (`embeddings.py:905`).
- **Nothing is inferred from a bare cloud API key.** The only inference left is a complete
  `CRG_OPENAI_*` trio, which mirrors CRG's own no-provider default and is config `setup-embeddings.sh`
  wrote.
- `setup-embeddings.sh` continues to offer only `local` and the OpenAI-compatible path (with
  `ollama` / `lmstudio` as autofill presets over the latter). `google`, `minimax` and `voyage` are a
  **documented destination**, reached by setting env yourself — never a menu item.
- `embed-health.sh` checks **every** provider: that its credential reaches the MCP read path, and
  that its recorded identity matches what is configured. An unrecognised name is reported there.

## Why validation moved rather than vanished

"Let CRG validate loudly" is false on the hook path — its stderr goes to `/dev/null`. So
permissiveness lives on the **write** path, where a wrong name costs one failed embed, and
strictness lives on the **reporting** path, where output reaches a human at session start.

`embed-health.sh` therefore keeps two hand-maintained maps that `resolve()` refused to keep: `KNOWN`
(names CRG accepts) and `REQUIRED_ENV` (the credential each needs). The asymmetry is deliberate and
is the whole reason it is acceptable here — **these only ever raise a warning.** A stale entry costs
a spurious or missing warning. A stale entry in `resolve()` cost silent data rot. Drift is tolerable
exactly where its consequence is advisory.

## Consequences

- A repo that relied on cloud-key inference now reads as unrefreshable and is told so, with a
  `consent` line naming what used to happen. That is a deliberate, one-way break: the previous
  behaviour was the defect.
- We do not own a credential-prompt flow per cloud vendor, and do not re-drift when upstream adds a
  provider — it works on arrival, unmentioned by us.
- `embed-health.sh` needs an entry when upstream adds a provider, or its warning goes quiet for
  that one. The failure mode is a missing warning, not a broken repo.
- Vendor names remain legitimate as **input** (autofill, model discovery in `setup-embeddings.sh`)
  and are gone as **identity in output** — the tier banner reports the model, not a vendor guessed
  from a port number.

## Alternatives rejected

- **Add `google` / `minimax` / `voyage` to the menu.** Means owning a credential prompt and an
  `.mcp.json` mirror per vendor, and re-drifting on every upstream release — the trap we just left.
- **Keep the allow-list, just add `voyage`.** Fixes one name and preserves the mechanism that
  produced the defect.
- **Derive the list at runtime from the installed CRG package.** Correct but expensive: it means
  importing or shelling into CRG on a path that runs every turn and every commit, which
  `embed-provider.sh` exists to keep cheap (its header explains why it never imports torch).
- **Gate the key inference on `CRG_ACCEPT_CLOUD_EMBEDDINGS=1`.** Still infers a paid provider from
  ambient state, just with one more variable.
- **Honour a cloud key only from repo-local `embed.env`.** Has no user: `setup-embeddings.sh` never
  writes those keys there, so any such key is hand-added — and whoever hand-edits that file can add
  `CRG_EMBEDDING_PROVIDER` on the next line.
