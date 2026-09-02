---
name: x442-register-cross-repo-handoff
description: Use when several repos should coordinate handoffs together — a fleet, a monorepo's packages, or "these projects share a handoff board / group / workspace". Declare groups of peer repos in a .handoff-repos.json cascade, then sync to scaffold a standalone shared board (owned by no repo) and wire every member to its own sub-indexed section. Chains after setup-handoff.
---

# Register a cross-repo handoff fleet

Coordinate handoffs across a **group (or several groups) of peer repos** without seeding the board
from any one project. You declare the groups and their members in a `.handoff-repos.json` manifest
at a workspace directory; the sync scaffolds a standalone shared board and wires every member repo
to its own **sub-indexed section** of that board.

This is the multi-repo counterpart to [setup-handoff](../setup-handoff/SKILL.md), which installs a
single board into one repo. Chain after it: setup-handoff builds the board machinery; this skill
stands up a fleet of boards from a manifest and points many repos at them.

## When to use

- "These projects should share a handoff board" / "coordinate handoffs across the fleet".
- A workspace of sibling repos (frontend + backend + infra) that hand work to each other.
- A monorepo whose packages each want their own handoff section under one board.
- You want to organize handoffs by **group / category / workspace**, each with its own sub-index.

Do **not** use it for a single repo's own handoffs — that is plain `setup-handoff`.

## Preconditions

- `setup-handoff` present in this repo of skills (the sync reuses its installer).
- `python3` on PATH (the resolver, the AGENTS.md splicer, and the enforcement gate need it).
- Each member repo already has an `AGENTS.md` (run `initial-project` there first) — the sync
  refuses to fabricate one.

## The manifest: `.handoff-repos.json`

A cascade, lowest precedence first, nearest wins (exactly like `AGENTS.md` / `CLAUDE.md`):

1. **user** — `~/.agents/handoff-repos.json` (personal, uncommitted)
2. **workspace** — `<scope>/.handoff-repos.json` (the default; committed if the workspace is a repo)
3. **subdir** — `<dir>/.handoff-repos.json` for dirs between scope and where you sync from

Start from [`assets/handoff-repos.example.json`](assets/handoff-repos.example.json):

```json
{
  "version": 1,
  "board": "./.agents/handoff",
  "layout": "subfolder",
  "groups": {
    "auth-suite": {
      "repos": [
        { "alias": "api", "path": "./api", "audience": "api", "notes": "REST + auth" },
        { "alias": "web", "path": "./web" }
      ]
    },
    "infra": { "repos": [{ "alias": "k8s", "path": "./kubernetes" }] },
    "legacy": {
      "board": "./.agents/handoff-legacy",
      "repos": [{ "alias": "monolith", "path": "./monolith" }]
    }
  }
}
```

- **`board`** (top level, optional) — the default board hosting every group that does not override
  it; defaults to `<scope>/.agents/handoff`. Groups sharing a board become sub-indexed sections of
  it (`auth-suite` + `infra` above); a group with its own `board` gets a separate physical board
  (`legacy`). Paths resolve relative to the declaring manifest, so committed relatives are portable.
- **`layout`** (optional) — `subfolder` (default) puts each section in `<board>/<group>/`; `prefix`
  puts it in `<board>/<group>--<id>-handoff.md`. Recorded in the board config; the CLI and hooks
  branch on it.
- **group key** — a namespaced name (`^[a-z0-9][a-z0-9._-]*$`); it is the section name and the
  `HANDOFF_GROUP` identity wired into each member. `{ "remove": true }` as a group value
  un-inherits an inherited group.
- **`repos[]`** — `alias` (required, namespaced), `path` (required), `audience` (optional, defaults
  to the alias — the acts-next routing name), `notes` (optional). `{ "alias": "x", "remove": true }`
  drops a member from the group.

## Procedure

1. **Author the manifest** at the workspace root (copy the example, edit groups + paths).
2. **Preview**: `scripts/sync-cross-repo-handoff.sh --scope <workspace> --dry-run` — prints the
   boards it would scaffold and the repos it would wire; writes nothing. Resolve errors (a missing
   repo, a bad path) are surfaced here.
3. **Sync**: drop `--dry-run`. Choose tools + primary the same way setup-handoff does:
   `--tools claude,gemini,copilot --primary claude` (or `--primary none` for advisory-only). The
   sync scaffolds each board `--board-only`, wires each member (`--topology cross-repo --group …`),
   and splices the cross-repo-handoff block into each member's AGENTS.md. Re-runnable: byte-compares
   before writing, so a second run leaves every repo's `git status` clean.
4. **Verify**: `scripts/verify-cross-repo-handoff.sh --scope <workspace>` — read-only. Confirms each
   board is scaffolded with the expected group facts, each member is wired to its section, and the
   AGENTS.md blocks match the manifest. Exit 0 = healthy, exit 1 = broken (drift, missing wiring).
5. **Report** the boards, groups, and members wired, and how to work the board
   (`HANDOFF_GROUP=<group> handoff list` from a member shows only that repo's section — a hand-run
   command needs the group; the hooks already carry it).

Editing the manifest later is the same loop: change it, re-sync, re-verify. The verifier flags
**drift** (a manifest edited but never synced) as a failure.

## What the sync does (reuse map)

- Resolves the cascade with `scripts/manifest/resolve.py` (read-only; the same brain the verifier
  uses, so they cannot disagree).
- Scaffolds each distinct board via `setup-handoff.sh --board-only <path> --groups … --layout …
[--remote <url>]` — a standalone board owned by no repo. The board is **git-initialised
  non-optionally**: it is the board of record, and one that was never a repository has no history,
  no blame, and no recovery for documents that exist nowhere else. Declare its remote as
  `boardRemote` in the manifest and the sync passes it through; without one the board is versioned
  but still reaches exactly one machine, and the sync says so.
- Wires each member via `setup-handoff.sh <repo> --topology cross-repo --handoff-dir <board>
--group <group> …`, which installs the hooks, Claude `additionalDirectories`, and the standard
  handoff block. The section itself is written to the member's own `.agents/handoff.config.json`,
  **not** baked into the hook command — so renaming a group cannot strand a stale literal inside a
  tool config where nobody reading the board would see it.
- Splices the peer-listing block with `scripts/manifest/render.py`.
- Projects the resolved manifest into each board as `<board>/repos.json`, via
  `scripts/manifest/registry.py` — see **Brief repo identity** below.
- Records `<scope>/.agents/cross-repo-handoff-state.json` so a later `--prune` can report members
  that have left scope.

## Working the board

A member repo's section is selected by `HANDOFF_GROUP`. The wiring bakes it into each tool's hook
command, so the session board and the edit gate are scoped automatically — but a command run by
hand inherits nothing, so pass it:

```text
HANDOFF_GROUP=<group> ../.agents/handoff/handoff list                     # only this repo's section
HANDOFF_GROUP=<group> ../.agents/handoff/handoff new fix-x --audience web # hand off to a peer
HANDOFF_GROUP=<group> ../.agents/handoff/handoff claim fix-x "on it"
```

Leave it out on a sectioned board and the CLI says so rather than misleading you: `list` warns that
nothing it printed is scoped to you, and `claim`/`release` report which section actually holds the
id instead of "no such handoff". The rendered AGENTS.md block spells these commands out with the
repo's own group already filled in.

The board root `INDEX.md` is a **roll-up** across every section; each group also has its own
sub-index. The session board and edit gate a repo sees are filtered to its own group, so groups on
a shared board never collide, and ids may repeat across groups without clashing.

## Brief repo identity — `<board>/repos.json`

A delegation brief (`handoff export`) names `file:line` locations that plausibly exist in a
different repo and mean something else there, so the brief carries the target repo's **root commit**
and both the executor's preflight and `import --result` check it. On a grouped board the target is
whatever the handoff's `audience` names — a different repo from the one export runs in.

The board's CLI cannot resolve the cascade for itself: it ships inside the member repos, so it can
reach neither `resolve.py` nor `--scope`. The sync therefore writes the answer down where the CLI
can read it — `<board>/repos.json`, generated, never hand-edited:

```json
{
  "version": 2,
  "repos": [
    {
      "group": "auth-suite",
      "alias": "api",
      "audience": "api",
      "rootCommit": "4f2a1c9e…"
    }
  ]
}
```

**Schema 2 records identity and nothing else.** A repo's root commit is what it is on every
machine; a path is what it is on one. Schema 1 stored both, and that one `path` field is what
pinned a board to a single disk — `"../../../../acme-lib"` resolves nowhere else, so a board could
be committed, cloned, and still useless to the person who cloned it (ADR 0002).

Location is now a per-machine concern, resolved by the CLI in this order:

1. `~/.agents/handoff-locations.json` — the uncommitted map, beside the cascade's own user layer.
2. A schema-1 entry's `path`, if the file still has one. Still honoured, still unverified.
3. A bounded scan of `$WORKSPACE_ROOT` and the board's parent directories, one level deep, whose
   answer is cached back into the map.

`rootCommit` remains an **attestation, not a value to copy**: export reads the live root commit at
whatever location resolved and trusts it only when the two agree. Everything that can go wrong
degrades to
`repo_root_commit: unverified` with its own warning, and `import --result` then demands
`--force-repo` plus a human check — a moved checkout, a manifest edited without a re-sync, an
audience the registry does not declare, an audience claimed twice inside one group, an unreadable
or absent registry. Nothing falls back to matching the audience against a directory name.

Lookup is scoped to the **caller's own section**, the same fence every other command applies: two
groups sharing one board may each declare their own `api` without either becoming ambiguous, and a
group can never resolve a peer it does not list.

**Re-sync after any manifest change**, and after moving or re-cloning a member. Until you do, that
member's briefs render `unverified` — honest, but degraded.
`verify-cross-repo-handoff.sh` fails on registry drift, so it is what tells you.

A member with no attestable root commit at sync time (not on disk, not a git repo, no commits) gets
**no entry**, and the sync warns. An unattestable entry would be a guess, which is the thing this
file exists to eliminate.

A repo the registry identifies but this machine cannot locate reports `no-location` rather than
"not declared". The two look alike and are fixed differently: the first wants a clone (or an entry
in the location map), the second wants a manifest change and a re-sync.

## The board's remote

A board with a remote is **shared**; a board without one is merely **versioned**. The difference is
not cosmetic — it is what decides whether `claim` can exclude another machine at all, because the
lease primitive is `git push` acting as a compare-and-swap (ADR 0002).

```json
{
  "board": "./.agents/handoff",
  "boardRemote": "git@github.com:acme/acme-handoff-board.git"
}
```

Declarable per group as well as at the top level; two groups sharing one board must not declare
different remotes, and the resolver refuses rather than picking a winner. Put no credentials in the
URL — use an SSH remote or a credential helper.

One board per **trust boundary**, not per group: groups are sections inside a board. A board's
readers are everyone who can clone it, so the line worth drawing is the one an ACL already draws.

## Caveats

- **No seed, no fusion.** Each board is a plain shared directory; a member only reads/writes the
  board, it does not "own" it. Groups on one board are co-located but isolated (separate sections,
  leases, sub-indexes) — not merged.
- **The manifest is the fence.** A repo coordinates only with the peers its group lists. To add a
  peer, edit the manifest and re-sync — do not point a repo at a board by hand.
- **Give peers distinct `audience` values within a group.** Two members of the _same_ group
  answering to one audience make a handoff's target ambiguous, and `export` refuses to pick between
  them rather than flipping a coin — every brief aimed at that audience renders `unverified` until
  the manifest is fixed. Across groups the same audience is fine; lookup is section-scoped.
- **`--prune` is advisory.** The sync reports members that left scope but does not unwire them (that
  is a `merge-hooks` strip in the member repo); remove their hooks by hand if they should stop
  coordinating.
- **Secrets.** Handoff docs are committed to git history — never paste keys, secrets, or PII; record
  a name and supply the value out of band.

## Usage record

[docs/cross-repo-handoff-usage-record.md](../../../docs/cross-repo-handoff-usage-record.md) records a
real four-repo install on a shared board — the manifest used, the hook commands generated, the
subfolder/prefix path table, how several groups stay isolated on one board, and the gotchas found.

## Verification harness

`harness/register-cross-repo-handoff-workspace/` stands up a fixture workspace (groups sub-indexed
on a shared board plus a group on its own board, under both layouts) and grades the result with the
read-only `verify-cross-repo-handoff.sh`. See [docs/harness-structure.md](../../../docs/harness-structure.md).
