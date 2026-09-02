# Plan — make the handoff board shareable

Executes `handoff-suite-board-sharing-handoff` (phase 1 of the handoff suite redesign).
Decisions: [ADR 0002](../adr/0002-board-of-record-is-a-git-repo.md). Do not relitigate them here.

## Global context

The board is a directory of markdown plus a `.locks/` tree, read constantly and written
occasionally. Phase 1 does not change that shape. It adds three things:

1. **A remote**, so the board can leave one machine.
2. **`git push` as the lease primitive** — a rejected non-fast-forward push means someone
   claimed first. `claim` is strict (no network, no claim); `release` is optimistic and must
   work offline.
3. **Root-commit repo identity**, so `repos.json` stops encoding one machine's disk layout.

Everything is keyed on **whether the board repo has a remote**. A local-only board must keep
behaving exactly as it does today: leases ignored, no network on any path.

Files in play:

- `skills/engineering/setup-handoff/scripts/payload/handoff` — the CLI (`claim`, `release`,
  `lock_state`, `board_repo_entry`)
- `skills/engineering/setup-handoff/scripts/payload/config.sh` — config resolution
- `skills/engineering/setup-handoff/scripts/setup-handoff.sh` — installer, `.gitignore` branch
- `skills/engineering/register-cross-repo-handoff/scripts/sync-cross-repo-handoff.sh` — scaffolds
  the standalone board
- `skills/engineering/register-cross-repo-handoff/scripts/manifest/registry.py` — writes `repos.json`
- both `verify-*.sh` — drift detection

## Task 1 — board git substrate helpers

Add one place that answers "is this board a git repo, does it have a remote, are leases shared".
Every later task branches on these instead of re-deriving.

- `board_git()` — `git -C "$DIR"` wrapper.
- `board_is_repo()` — the board dir is the root of a worktree.
- `board_has_remote()` — at least one remote configured.
- `leases_shared()` — `board_is_repo && board_has_remote`. This is the single switch.

Cache the answers in a variable resolved once per invocation; `list` and `index` must not pay
for repeated `git` calls.

**Verify**: on the current local-only board `leases_shared` is false and no `git` command is
issued on the claim path.

## Task 2 — lease expiry from commit time

`lock_state` currently trusts `expires=` written by the claiming machine's wall clock. Across
machines that is not comparable.

- Write `ttl_hours=` into the owner file alongside the existing fields.
- On a shared board, derive the base time from `git log -1 --format=%ct -- <owner file>` and
  compute `exp = commit_time + ttl_hours * 3600`.
- Fall back to the recorded `expires=` when the file is untracked or git cannot answer, so a
  local-only board is byte-for-byte unchanged in behavior.

**Verify**: a committed lease whose `expires=` field is hand-edited into the far future is still
reported expired once its commit time plus TTL has passed.

## Task 3 — lease visibility follows topology

The board `.gitignore` currently holds `.locks/`. On a remote-backed board that rule makes the
lease unshareable, which silently converts push-CAS into a no-op.

- `setup-handoff.sh` keeps writing the consumer-side rule only for single-repo boards (unchanged).
- The board's own `.gitignore` gains/loses `.locks/` according to `leases_shared`.
- The CLI repairs it on the claim path rather than refusing: a board that just gained a remote
  otherwise blocks every claim until someone hand-edits a file. Report the change; never do it
  silently.

**Verify**: `git check-ignore .locks/` is a hit on a local-only board and a miss on a
remote-backed one.

## Task 4 — `claim` as compare-and-swap

On a shared board, in order:

1. Refuse early if the network is unusable — strict, per ADR 0002.
2. Fetch and fast-forward the board so the local view of the leases is current.
3. Take the local lock (the existing atomic `mkdir`), write the owner file.
4. Commit the lease and push.
5. A rejected non-fast-forward push means someone claimed first: undo the local commit and the
   lock directory, then fail with who holds it.

A local-only board skips all five and runs exactly today's path.

**Verify**: two clones of one board; `claim` on the second after the first has claimed and pushed
fails rather than succeeding locally. With the remote unreachable, `claim` refuses with an
explicit message.

## Task 5 — `release` is optimistic

Release records something that already happened, so it must never fail on the network.

- Clear the lock, commit, attempt the push.
- A failed push is a warning naming the retry, not an error; the release itself has succeeded.

**Verify**: with the remote unreachable, `release` still succeeds and says the push is pending.

## Task 6 — root-commit identity, per-machine location

`repos.json` identifies members by a path relative to the board. That is the mechanism pinning a
board to one disk.

- `registry.py` writes schema `version: 2`: `group`, `alias`, `audience`, `rootCommit`. No `path`.
- The CLI resolves a member by root commit through, in order: the per-machine map at
  `~/.agents/handoff-locations.json` (uncommitted, matching the `~/.agents/handoff-repos.json`
  cascade layer), then a discovery scan of `$WORKSPACE_ROOT` whose results are cached back into
  that map.
- A v1 registry still reads: its `path` is accepted only when the checkout there actually has the
  recorded root commit, which is the existing attestation.

**Verify**: `repos.json` resolves members on a machine whose checkout layout differs from the
authoring machine's, and no per-machine value appears in any committed file.

## Task 7 — `git init` and bootstrap

- A standalone shared board is `git init`-ed at scaffold time — non-optional. A nested board only
  warns.
- Setup clones an absent board to a conventional location so a teammate needs no configuration.

**Verify**: a board scaffolded fresh is a git repository with a remote, and `handoff claim` on it
produces a commit that is pushed.

## Task 8 — verifiers and payload stamp

- `verify-setup-handoff.sh` and `verify-cross-repo-handoff.sh` report the drift each task
  introduces (lease visibility wrong for the topology, a v1 registry, a standalone board with no
  remote).
- Bump `scripts/payload.version`; every mirrored copy of the payload is re-synced from it.
