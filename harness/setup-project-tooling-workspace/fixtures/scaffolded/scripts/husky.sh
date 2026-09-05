#!/usr/bin/env bash
# x442-payload-version: setup-project-tooling 2
# husky.sh — git-hook dispatcher for a repo wired by setup-project-tooling.
#
# The marker line above is this skill's payload stamp. setup-project-tooling has no single
# payload directory — its assets scatter across scripts/, .husky/, and root configs — so the
# version rides in the one file that is unambiguously the skill's and always present. Keep it
# on line 2, byte-identical to scripts/payload.version, so a one-line read finds it. An ABSENT
# marker means a pre-versioning install, not a corrupt one.
#
# One script owns both halves of the hook lifecycle: `install` writes the .husky/ hook files
# and points core.hooksPath at them, and the per-hook sub-commands are what those files execute.
# Each hook is a single line that calls back into this script with git's own arguments, so
# hook logic lives here in reviewable shell instead of JSON-escaped fragments in package.json.
#
# COMMIT .husky/. The hook files are repo state, not user state: identical for everyone, and
# tracking them is what makes a git worktree work. core.hooksPath lives in .git/config and is
# shared by every worktree of a clone, so an untracked hooks directory leaves a worktree pointing
# at something it does not have — and git then runs NO hook at all, silently.
#
# HOW TO WIRE THE INSTALL. `prepare` is the npm lifecycle script this would normally use, but it
# also runs on install in CI, which can break a CI workflow that does not want git hooks. A repo
# with that problem should use a plain script it calls deliberately instead:
#   "prepare":    "scripts/husky.sh install"   # automatic, fires on every install
#   "install:dev": "<pm> install && scripts/husky.sh install"   # manual, CI-safe
# Pick one. With the manual form, a FRESH CLONE needs it run once; worktrees of that clone then
# inherit core.hooksPath and find the tracked hooks with no further action.
#
# Usage: scripts/husky.sh <command> [args...]
#   install      Point core.hooksPath at .husky/ and (re)generate the hook files
#   commit-msg   Hook body: lint the commit message  (git passes the message file as $1)
#   pre-commit   Hook body: run the staged-file checks
#   -h, --help   Show usage information

set -euo pipefail

# Hooks to generate. The generated file calls back as `$SELF <hook> "$@"`; git runs hooks
# from the repo root, so a repo-relative path resolves.
HOOKS="commit-msg pre-commit"
SELF="scripts/husky.sh"

print_usage() {
  echo "Usage: $0 <command> [args...]"
  echo "  install      Point core.hooksPath at .husky/ and (re)generate the hook files"
  echo "  commit-msg   Hook body: lint the commit message (git passes the message file as \$1)"
  echo "  pre-commit   Hook body: run the staged-file checks"
  echo "  -h, --help   Show usage information"
}

fail() {
  echo "Error: $1" >&2
  exit 1
}

command_exists() {
  command -v "$1" > /dev/null 2>&1
}

# section: node package manager (detect from lockfile)
detect_pm() {
  if [ -f pnpm-lock.yaml ]; then
    echo "pnpm"
  elif [ -f yarn.lock ]; then
    echo "yarn"
  elif [ -f bun.lockb ]; then
    echo "bun"
  else
    echo "npm"
  fi
}

pm_exec() {
  # Resolve a locally installed binary. `npx` cannot see local bins under Yarn PnP or a
  # strict pnpm store, so each manager gets its own exec form.
  case "$(detect_pm)" in
    pnpm) pnpm exec "$@" ;;
    yarn) yarn exec "$@" ;;
    bun) bunx "$@" ;;
    *) npx --no -- "$@" ;;
  esac
}

has_script() {
  [ -f package.json ] || return 1
  command_exists node || fail "node is required to run hook steps but was not found on PATH."
  node -e 'const s=require("./package.json").scripts||{};process.exit(s[process.argv[1]]?0:1)' "$1" 2> /dev/null
}

run_step() {
  # Run a package.json script as a hook step, skipping it when the repo does not define it:
  # a Python or base-only repo has no `lint`, and a missing script must not block every
  # commit. Add a step by adding a `run_step` line to the hook function below.
  local script="$1"
  shift
  if ! has_script "$script"; then
    echo "husky: skipping '$script' (no such package.json script)"
    return 0
  fi
  echo "husky: $script"
  "$(detect_pm)" run "$script" -- "$@"
}

# section: install
hook_body() {
  # Single command, with git's hook arguments passed through.
  printf '#!/bin/sh\n\n%s %s "$@"\n' "$SELF" "$1"
}

install_hooks() {
  [ -f package.json ] || fail "no package.json in $(pwd); run this from the repo root."

  # core.hooksPath points at .husky ITSELF, not husky's generated .husky/_ helper directory.
  #
  # The hooks this script writes are complete shell scripts that call back into it directly —
  # they never source husky's `_/husky.sh` — so the `_` layer only ever supplied the hooksPath
  # value. Owning that value here buys the thing husky cannot give us: `.husky/` can be TRACKED,
  # and a tracked hooks directory exists in every git worktree with no install step at all.
  #
  # That is not a nicety. core.hooksPath lives in .git/config and is shared by every worktree of
  # a clone, while `.husky/_` was generated and gitignored — so a linked worktree inherited a
  # hooksPath naming a directory it did not have, and git ran NO hook at all. Not commitlint, not
  # lint-staged, not verify-standalone.sh, and not setup-graph-hooks' post-commit refresh. It
  # failed silently, which is the worst way for a guardrail to fail.
  #
  # `husky` the package is deliberately no longer invoked: calling it would reset core.hooksPath
  # back to .husky/_ and undo this on the next install.
  git rev-parse --git-dir > /dev/null 2>&1 || fail "not a git repository; cannot set core.hooksPath."
  git config core.hooksPath .husky
  echo "Set core.hooksPath to .husky"

  mkdir -p .husky
  local hook
  for hook in $HOOKS; do
    hook_body "$hook" > ".husky/$hook"
    chmod +x ".husky/$hook"
    echo "Wrote .husky/$hook"
  done
  [ -f "$SELF" ] && chmod +x "$SELF"

  # A gitignored .husky/ reintroduces the exact defect this layout exists to remove, so say so.
  if git check-ignore -q .husky 2> /dev/null; then
    echo "WARNING: .husky/ is gitignored — commit it, or worktrees will silently run no hooks." >&2
  fi
  echo "Git hooks installed in .husky/. Commit them."
}

# section: hook bodies
run_commit_msg() {
  [ "$#" -ge 1 ] || fail "commit-msg expects the commit message file (git passes it as \$1)."
  pm_exec commitlint --edit "$1"
}

run_pre_commit() {
  run_step lint-staged --concurrent false
}

# section: execution
main() {
  if [ "$#" -eq 0 ]; then
    print_usage >&2
    fail "no command given."
  fi
  local command="$1"
  shift
  case "$command" in
    install)
      install_hooks
      ;;
    commit-msg)
      run_commit_msg "$@"
      ;;
    pre-commit)
      run_pre_commit "$@"
      ;;
    -h | --help)
      print_usage
      ;;
    *)
      print_usage >&2
      fail "Unknown command: $command"
      ;;
  esac
}

main "$@"
