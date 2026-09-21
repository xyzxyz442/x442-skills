# Per-repository trackers for a shared board — design

Date — 2026-09-21
Status — approved, pre-implementation
Branch — `feature/per-repo-trackers`

## Problem

A shared board coordinates several repositories, but ADR 0011 lets it attach **at most one**
external tracker. On a cross-repo board that tracker is usually the board repository itself, so
every member's work is mirrored into one place that the members' own teams never look at. What a
team actually watches is its own repository's issue tracker.

The wanted arrangement is:

- The **board stays the full record** — leases, evidence, `## Ruled out`, notes, restricted
  documents — whether or not it has a git remote. It is where detail lives and where status changes.
- **Each member repository's own issue tracker** receives a one-way projection of the handoffs that
  belong to it, and nothing else.
- The detail that is not fit for a repository's readers — possibly the whole internet — stays on
  the board.

Three facts about the current CLI shape the change:

| Today                                                                  | Consequence                                            |
| ---------------------------------------------------------------------- | ------------------------------------------------------ |
| `handoff.json` holds one `external` block per board                    | every section mirrors into the same repository         |
| the mirror renders `Current state`, `Context` and `Verify` into issues | detail leaves the board on every mirror run            |
| an issue is matched only by `<!-- handoff:<section>/<id> -->`          | two boards mirroring one tracker cannot see each other |

## Decisions

Fixed during brainstorming; the rest of the design depends on them.

1. **A handoff's issue lives in its home repository, and the home never changes.** A new
   document field, `home`, is pinned at `new`. `audience` — who acts next — keeps changing freely
   and is projected as a label; it never moves the issue.
2. **An audience flip relabels; work another team owns is split.** A quick flip updates the
   `audience:<alias>` label and the assignee (the `reviewer` pointer, ADR 0016). Work the other team
   genuinely owns becomes a child handoff homed in that team's repository, under an orchestrator or
   ordered with `--after`. No pointer issues.
3. **One owner per board, enforced.** Every tracker on a board shares one host and owner; if the
   board has a git remote, that owner matches too. This keeps ADR 0011's one board per trust
   boundary. An organization's work gets its own board.
4. **The board has no tracker of its own.** A handoff whose home declares no tracker stays on the
   board. The board-level `external` block is retired on multi-repo boards.
5. **Summary projection by default.** An issue carries the title, labels and `Current state`.
   A tracker opts into `full` (adds `Context` and `Verify`) explicitly.
6. **One board mirrors into a tracker.** Several maintainers share one team board, which mirrors;
   each keeps a draft board of their own (ADR 0011) that never mirrors and feeds the team board
   with `handoff move`. A second board's mirror run into the same tracker is refused.
7. **Trackers are declared in the board's committed `handoff.json`**, keyed by repository alias.
   Setup suggests each entry from the repository's `origin`; nothing is inferred at run time.

### Rejected alternatives

- **Routing by `audience`** — the issue would hop repositories with every flip and split one
  handoff's history across trackers.
- **One issue in every repository in `repos`** — N issues per handoff multiplies drift.
- **Pointer issues in the audience repository** — an extra issue per flip, split discussion, PRs
  linked to the wrong number.
- **A mixed-owner board** — one board holding several organizations' records puts one employer's
  restricted material on another owner's disk and possibly remote. Rejected in ADR 0011; nothing
  here reopens it.
- **Trackers declared in the group cascade** — the cascade has uncommittable layers, so
  `allowPublic` could come from a file review never sees. ADR 0013 forbids that.
- **Trackers inferred from `origin`** — registering a repository would start publishing into it
  with no one deciding. Kept only as the setup suggestion.

## Configuration

`handoff.json` gains `trackers`, keyed by the aliases already in `_generated.repos[].alias`:

```json
"trackers": {
  "acme-api": { "kind": "issues", "system": "github", "repo": "acme/acme-api",
                "refPattern": "#[0-9]+", "projection": "summary" },
  "acme-lib": { "kind": "issues", "system": "github", "repo": "acme/acme-lib",
                "refPattern": "#[0-9]+", "allowPublic": true }
}
```

- Each entry carries today's `external` fields — `kind` (`issues` | `sprints`), `system`, `repo`,
  `refPattern`, `allowPublic` — plus `projection` (`summary` | `full`, default `summary`).
- A `sprints` entry is reference-only, as ADR 0011 already rules: `--ref` validates against it; it
  is never mirrored or delegated to.
- An alias with no entry is never mirrored.
- `trackers` is board policy. It survives a re-install and is never written from
  `handoff.local.json` or the environment (ADR 0013).
- A board that is not a git repository gets `boardId`, a generated identifier written once. A git
  board's identity is its root commit, which the registry already records for members.

### Trust check

Before any send, and offline in the verifier: every `trackers[*].repo` shares one host and owner,
and, when the board has a git remote, that owner equals the remote's. A mismatch refuses and names
both owners. A board without a remote takes its owner from its trackers.

### Legacy `external`

- **Single-repository board** (in-repo boards): read as `trackers[<that repo>]`. Behavior is
  unchanged except the projection default, which the upgrade names (see Migration).
- **Multi-repository board**: not used for routing. The verifier warns `board.external.legacy`.

## Document

- New frontmatter key `home: <alias>`, set by `new` from `--home`, else `HANDOFF_REPO`, else the
  first entry of `repos`. `new` refuses an alias the board does not register.
- Immutable after `new`. `import --result` adds `home` to its protected keys.
- `move --to` re-validates `home` against the target board's registry and refuses an alias that
  board does not register.
- `home` selects the mirror target, validates `external_ref` (`trackers[home].refPattern`), and
  names where `export --to-issue` opens a delegation issue.
- Coordination and orchestrator documents carry `home`. An orchestrator's children may each have a
  different one. Standalone and reference documents carry none and are never mirrored.
- Adding `home` bumps the **document schema from 3 to 4** (ADR 0003): an older CLI refuses to write a
  schema-4 document.

## Mirror

### Routing

`handoff mirror` groups mirrorable documents by `home` and runs one pass per tracker. Each pass
keeps every existing gate: open only, not restricted, secret-scanned, visibility asked on every run,
double opt-in on a public repository (ADR 0013). A document whose `home` has no tracker is skipped
and named in `--dry-run` output. `--repo <alias>` limits a run to one tracker.

A pass surveys **only** the documents homed at its tracker. Its desired, gone and own-reference sets
— the inputs that decide which issues are created, updated and closed — are built from that subset,
and visibility (the `public` flag) is asked for that tracker alone. A document is never treated as
gone from a tracker it is not homed in, so a pass cannot close another repository's issues.

### Projection

| Rendered into the issue         | `summary` | `full` |
| ------------------------------- | --------- | ------ |
| title, labels, footer, marker   | yes       | yes    |
| `Current state`                 | yes       | yes    |
| `Context`, `Verify`             | no        | yes    |
| `## Ruled out`, notes, evidence | never     | never  |

Labels gain `audience:<alias>`. An orchestrator's issue is unchanged apart from routing — its body
is the bundle and checklist, which carry no detail.

### Ownership

- The hidden marker becomes `<!-- handoff:<board-id>/<section>/<id> -->`.
- A pass that finds a marker from another board id refuses the whole pass for that tracker, names
  the owning board, and sends nothing.
- An issue with the old marker (`<section>/<id>`) is adopted and rewritten on the first run, only
  while no other board id has claimed that tracker.

### Bundles across repositories

An orchestrator's children may be homed in different repositories. Sub-issue links are made across
repositories where the tracker accepts them; where it refuses, the checklist remains and the failure
is reported as today (ADR 0014 — the adapter owns the gap). Before relying on it, confirm GitHub's
current constraints on cross-repository sub-issues against its documentation and record them in the
adapter.

### Drift and CI

Tracker drift is still reported, never reconciled; the drift file gains a tracker column. The mirror
workflow template runs every pass and needs a token with issue write access on each member
repository, documented by secret name only.

## Migration

- The schema-4 CLI reads schema-3 boards. `mirror` refuses a board below schema 4 and names
  `migrate`.
- `migrate` (confirmed, one board at a time) backfills `home` from `audience`, else `repos[0]`,
  and lists every document it could not resolve, which stays unmirrored.
- Setup's upgrade path converts `external` with confirmation:
  - single-repository board — to `trackers[<that repo>]`, naming the new `summary` default and
    offering `full` to keep today's issue bodies;
  - multi-repository board — removes `external` and offers each registered repository a tracker
    pre-filled from its `origin`.
- Issues already mirrored into a retired board-level tracker are **listed for a person to close**,
  never closed or deleted automatically (the stance ADR 0013 takes for a repository turned public).
- The payload version is bumped (`scripts/verify-payload-version.sh`), and the fixture boards are
  refreshed (`scripts/sync-fixture-boards.sh`).

Rolling this out to existing boards is operational work outside this repository and is tracked on
the board, not here (standalone rule). Every step that publishes — a first mirror run against a new
tracker, a first push to a board remote — waits for explicit confirmation.

## Verification

### Verifier (offline)

| Check                          | Fires when                                                           |
| ------------------------------ | -------------------------------------------------------------------- |
| `board.trackers.owner`         | tracker owners differ, or differ from the board remote's owner       |
| `board.trackers.unknown-alias` | a tracker key is not a registered alias                              |
| `board.external.legacy`        | `external` remains on a multi-repository board                       |
| `board.id.missing`             | a non-git board has no `boardId`                                     |
| `doc.home.missing`             | a coordination or orchestrator doc on a schema-4 board has no `home` |
| `doc.home.unregistered`        | `home` names an alias the board does not register                    |

`board.external.public` stays and reports per tracker.

### Harness and selftests

With the existing fake tracker provider — graders never touch the network:

- two homes route to two trackers, and a pass for one never closes the other's issues;
- `summary` omits `Context` and `Verify`; `full` includes them; `## Ruled out` never appears;
- an audience flip changes the label and never the tracker;
- a foreign board id refuses the pass and sends nothing;
- mixed owners refuse before any send;
- a single-repository legacy `external` behaves as before;
- `migrate` backfills `home` and reports the unresolved;
- a public tracker still sends only `share: public` documents.

Each new selftest is seen to fail against the current CLI before the change lands.

## Documentation

- **ADR 0017** — a tracker attaches per repository, and one board mirrors into it. Refines ADR 0011;
  ADR 0011 gains a pointer.
- **CONTEXT.md** — **External tracker** becomes per repository; new terms **Home** (the repository
  whose tracker owns a handoff's issue, distinguished from **Audience**) and **Projection**
  (`summary` / `full`); a draft board never mirrors.
- **run-handoff** — the split convention for work another team owns.
- **delegate-handoff** — `export --to-issue` targets `trackers[home]`.
- **setup-handoff** — tracker prompts, the `external` → `trackers` upgrade, the CI token name.
- **Usage guide** — one worked example: a team board with draft boards.

## Out of scope

- Mirroring into a sprint tool — reference-only, as today.
- New tracker adapters — the adapter interface does not change, so any adapter gains per-repository
  routing.
- Moving an issue when `home` changes — `home` cannot change.
