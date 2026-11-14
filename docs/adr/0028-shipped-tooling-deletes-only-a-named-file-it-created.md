---
status: accepted
date: 2026-11-15
---

# Shipped tooling deletes only a named file it created

The owner's rule is `trash`, never `rm`, and the shipped scripts used `rm` in about 60 places. We
decided the rule gets one narrow exception: shipped tooling may `rm -f` a single named file it
created itself, then `rmdir` the empty directory. It never deletes recursively, never deletes a
literal path, and never deletes a file it did not create. A temp tree whose contents the script
does not list by name is left for the OS to reap. `scripts/verify-no-rm.sh` enforces the shape.

## Context

- The installed handoff CLI, its hooks, the tracker adapter, the graph-hooks steer cache and every
  `verify-*.sh` delete scratch files with `rm -f`. Most are `mktemp` files removed after an atomic
  `mv`, or on the failure path. Two delete a lease's `owner` file and then `rmdir` the lease
  directory. One prunes a stale cache file.
- Comments in `hooks.sh` and `verify-graph-hooks.sh` already followed an unwritten rule: `rm -f`
  plus `rmdir`, never `rm -rf`. Four scripts broke it: `delegate-run` (`rm -rf` on an installed
  path), two handoff selftests (`rm -rf`), `verify-secret-guard.sh` (`find -delete`), and the
  `vscode-hooks.py` selftest (`shutil.rmtree`).
- A local edit in a consumer repo is lost on the next reinstall, so the question had to be
  settled at the source.
- Several of these run on hook paths, some on every tool call. `trash` is not installed on the
  Linux CI runners.

## Decision

- **The exception.** Shipped tooling may `rm -f` a single named file it created itself — a
  `mktemp` scratch file, its own lease file, its own cache file — and `rmdir` the directory that
  held it. Nothing else.
- **No recursive delete, anywhere.** Not `rm -r`, not `find -delete`, not `shutil.rmtree`. A script
  that writes a fixed set of names into a temp directory deletes those names and then `rmdir`s it
  (`delegate-run`). A temp tree with runtime-built names or subdirectories is left in `$TMPDIR` for
  the OS: macOS clears unused items there after a few days, and CI runners are discarded after each
  job.
- **Scope.** Every script under `scripts/` and `skills/*/*/scripts/`: installed payloads, the
  setup and verify scripts that run from a skill directory, and the selftests. A script that runs
  on the owner's machine from the skill directory has the same blast radius as an installed one.
  `git rm` is an index operation and is out of scope.
- **Enforcement is by shape.** `scripts/verify-no-rm.sh` runs at pre-commit (staged files) and in
  CI (whole tree). In shell it allows `rm -f` only when every argument starts with a quoted
  variable, and refuses any other flag, a literal or unquoted path, `find ... -delete`, and `rm`
  through `xargs` or `exec`. In Python it refuses `rmtree` and `removedirs`. It cannot prove the
  variable names a file the script created; review checks that.
- The exception is written into the house rules in `AGENTS.md` and into the owner's global
  instructions, so an agent reading either one finds it.

## Considered options

- **Remove `rm` completely.** Rejected: about 60 call sites. Fixed reusable scratch files race when
  several sessions run at once, and lease release would have to change from deleting the owner file
  to writing a released marker, which changes the lease protocol on every installed board. A large
  payload change for little safety gain.
- **Use `trash` in the tooling.** Rejected: slow on hooks that run on every tool call, it floods the
  system Trash with thousands of tiny files, and it is absent on CI.
- **`find -delete` behind a check that the tree is under `$TMPDIR`.** Rejected: still a recursive
  delete with a new name, so the gate would only hide it.

## Consequences

- `setup-delegate-agent` payload bump (`delegate-run`).
- Selftests leave their temp trees in `$TMPDIR`.
- A new gate, `scripts/verify-no-rm.sh`, wired into `scripts/husky.sh` and `.github/workflows/no-rm.yml`.
