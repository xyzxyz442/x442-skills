---
status: accepted
date: 2026-09-16
---

# A repo finds its board locally, and the user layer is opt-in

A developer works across several boards at once — one per trust boundary, each with its own
groups. We decided a repo resolves its board from **its own folder and at most two parents**,
detected once at setup and written down, and that the user-level `~/.agents/handoff.json` is
**allowed but not recommended**: read only when something names it, after one release in which
reading it implicitly still works and warns. This amends ADR 0002's per-machine layer anchored at
`$HOME`.

## Context

- A real workstation holds several boards side by side — personal projects, an employer, a
  client — and one workspace can physically contain another's
  (`workspace/.agents/handoff` above `workspace/acme/src/.agents/handoff`).
- `~/.agents/` is a shared namespace. Other skills and tools write there, so a handoff file in it
  can collide with something this repo does not own.
- Most project repos sit in one of two layouts: `workspace/src/<repo>` under a dedicated
  workspace folder, or `workspace/<repo>` in an isolated one. Board detection scanned the repo
  and exactly one parent.
- The edit gate resolves a board before every write to a handoff doc. Resolution has to be
  fast, offline, and the same answer every time — a filesystem walk on the hot path is none of
  those.
- The only ignore rule setup wrote was `.locks/` for an in-repo board. A board, or a per-user
  config, placed inside some other repository's worktree was committed by whoever ran
  `git add` next.

## Decision

- **Detect at setup, read at runtime.** Setup detects and writes the answer into config; the
  CLI and hooks only read config. Runtime precedence, highest first:
  1. `HANDOFF_BOARD_PATH`
  2. `<repo>/.agents/handoff.local.json` — per-user, never committed
  3. `<repo>/.agents/handoff.json` — the team's board and group, committed
  4. `<repo>/.agents/handoff/` — an in-repo board
- **Detection scans the repo and two parent levels**, `$ROOT/..` and `$ROOT/../..`. That covers
  both common layouts at level 1 and stops before a workspace that merely contains another one.
- **Exactly one candidate is proposed and confirmed. Zero or several stops and asks** — offer the
  candidates, a deeper scan or a named folder, an explicit path, or a new board. Detection never
  picks silently.
- **Where the answer is written follows who it belongs to.** A team decision goes to
  `.agents/handoff.json`; a single developer's choice goes to `.agents/handoff.local.json`.
- **The user layer is allowed, not recommended.** `~/.agents/handoff.json` stays a valid cascade
  layer, read when `handoff.local.json` or an environment variable names it.
- **Implicit reads are deprecated over one release.** For one release the user layer is still
  read when present, with a warning naming the opt-in. After it, only the opt-in reads it.
- **Tooling never writes to the user layer.** The repo-location cache — until now the `locations`
  map in `~/.agents/handoff.json`, written back by the location scan — moves into the board as
  `<board>/.locations.json`, per machine and ignored by the board's own `.gitignore`. A location
  belongs to one board on one disk, so the board is its home.
- **A legacy `locations` map is migrated on a prompt, never silently.** When the CLI finds entries
  for the current board in the user layer, an interactive command offers to move them into
  `<board>/.locations.json` and recommends it; a hook reports it in one line and never blocks.
  Accepting copies the entries and removes only those entries from the user map; the user file
  itself is never deleted. Declining leaves both, and the offer repeats.
- **Setup and verify detect what needs ignoring**, and suggest rather than write:
  - `handoff.local.json` inside a repo — ignore it.
  - A board a developer keeps for themselves inside a repo — offer `.git/info/exclude` (only
    this clone) or `.gitignore` (the whole team). Prefer the exclude file: `.gitignore` is
    committed, so it publishes one person's preference.
  - A board that is its own repository inside another repo's worktree — ignore it in the outer
    repo.
  - A board inside a workspace that is itself a repository, but not its own repo — ask: make it
    a repository (ADR 0005's rule for standalone boards) or ignore it in the workspace.

## Considered options

- **A user-level board registry as the default.** Rejected — the namespace is shared with other
  skills, and it is the one layer a teammate's checkout can never see, so the same repo resolves
  differently per machine.
- **Removing the user layer outright.** Rejected — it breaks any existing workspace that relies
  on it, for no gain once it is opt-in.
- **Unbounded upward search.** Rejected — it walks from a client repo into the enclosing
  workspace and resolves a board from a different trust boundary.
- **Detecting at runtime.** Rejected — it puts a filesystem walk on the edit gate's path and
  lets the answer change when a folder appears.
- **Writing ignore rules without asking.** Rejected — `.gitignore` is committed, and whether a
  board is private is the developer's call.
- **Caching locations in each member's `handoff.local.json`.** Rejected — it scatters one board's
  locations across every member repo, and a repo that is not yet wired has nowhere to hold them.
- **Migrating the legacy map automatically.** Rejected — it rewrites a file in a namespace other
  tools share, without the user seeing it.

## Consequences

- `detect-handoff.sh` gains a second parent level and an ambiguity report; the setup skill gains
  the stop-and-ask branch.
- The CLI's resolver reads `handoff.local.json` and emits the one-release deprecation warning
  when it falls through to the user layer.
- `register-cross-repo-handoff` keeps the user layer in its cascade, documented as opt-in.
- The location scan writes `<board>/.locations.json`; setup adds it to the board's `.gitignore`
  beside `.locks/`; the CLI gains the migration offer for a legacy `locations` map.
- The verifier gains checks for each ignore case above, reported as warnings — they describe a
  risk, not a broken install.
