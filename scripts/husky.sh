#!/usr/bin/env bash
# x442-payload-version: setup-project-tooling 1
# husky.sh — git-hook dispatcher for a repo wired by setup-project-tooling.
#
# The marker line above is this skill's payload stamp. setup-project-tooling has no single
# payload directory — its assets scatter across scripts/, .husky/, and root configs — so the
# version rides in the one file that is unambiguously the skill's and always present. Keep it
# on line 2, byte-identical to scripts/payload.version, so a one-line read finds it. An ABSENT
# marker means a pre-versioning install, not a corrupt one.
#
# One script owns both halves of the hook lifecycle: `install` generates the gitignored
# .husky/ hook files, and the per-hook sub-commands are what those generated files execute.
# Each hook is a single line that calls back into this script with git's own arguments, so
# hook logic lives here in reviewable shell instead of JSON-escaped fragments in package.json.
#
# Wired into package.json as one command (npm lifecycle `prepare` by default):
#   "prepare": "scripts/husky.sh install"
#
# Usage: scripts/husky.sh <command> [args...]
#   install      Run husky, then (re)generate .husky/commit-msg and .husky/pre-commit
#   commit-msg   Hook body: lint the commit message  (git passes the message file as $1)
#   pre-commit   Hook body: run the staged-file checks (standalone rule, then lint-staged)
#   -h, --help   Show usage information

set -euo pipefail

# Hooks to generate. The generated file calls back as `$SELF <hook> "$@"`; git runs hooks
# from the repo root, so a repo-relative path resolves.
HOOKS="commit-msg pre-commit"
SELF="scripts/husky.sh"

print_usage() {
  echo "Usage: $0 <command> [args...]"
  echo "  install      Run husky, then (re)generate .husky/commit-msg and .husky/pre-commit"
  echo "  commit-msg   Hook body: lint the commit message (git passes the message file as \$1)"
  echo "  pre-commit   Hook body: run the staged-file checks (standalone rule, then lint-staged)"
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
  echo "Running husky..."
  pm_exec husky
  mkdir -p .husky
  local hook
  for hook in $HOOKS; do
    hook_body "$hook" > ".husky/$hook"
    chmod +x ".husky/$hook"
    echo "Wrote .husky/$hook"
  done
  [ -f "$SELF" ] && chmod +x "$SELF"
  echo "Husky hooks installed."
}

# section: hook bodies
run_commit_msg() {
  [ "$#" -ge 1 ] || fail "commit-msg expects the commit message file (git passes it as \$1)."
  pm_exec commitlint --edit "$1"
}

run_pre_commit() {
  # The standalone rule is a hard gate, not a lint: a foreign-project reference that reaches
  # main is a path that breaks on every other machine. Staged files only, so the hook stays fast.
  if [ -x scripts/verify-standalone.sh ]; then
    echo "husky: verify-standalone"
    scripts/verify-standalone.sh --staged
  fi
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
