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
- Scaffolds each distinct board via `setup-handoff.sh --board-only <path> --groups … --layout …`
  — a standalone board owned by no repo.
- Wires each member via `setup-handoff.sh <repo> --topology cross-repo --handoff-dir <board>
--group <group> …`, which installs the hooks (with `HANDOFF_GROUP` baked in), Claude
  `additionalDirectories`, and the standard handoff block.
- Splices the peer-listing block with `scripts/manifest/render.py`.
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

## Caveats

- **No seed, no fusion.** Each board is a plain shared directory; a member only reads/writes the
  board, it does not "own" it. Groups on one board are co-located but isolated (separate sections,
  leases, sub-indexes) — not merged.
- **The manifest is the fence.** A repo coordinates only with the peers its group lists. To add a
  peer, edit the manifest and re-sync — do not point a repo at a board by hand.
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
