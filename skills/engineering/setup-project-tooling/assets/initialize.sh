#!/usr/bin/env bash
# initialize.sh — workspace bootstrap for a repo wired by setup-project-tooling.
# Installs missing dependencies and repairs Husky hooks so a freshly cloned or freshly
# opened workspace is ready to commit. Idempotent: it only acts on what is missing or broken.
#
# Package-manager aware (npm/pnpm/yarn/bun, detected from the lockfile) and, for Python
# projects, bootstraps a .venv preferring uv and falling back to pip. Hooks are repaired by
# re-running the package.json `prepare` script, which regenerates the gitignored .husky/ hooks.
#
# Usage: ./initialize.sh [full|folder-open] [-f|--force]
#   full         Full bootstrap (default): deps + hooks (+ Python venv when applicable)
#   folder-open  Repair only what is missing/broken (used by the VS Code folderOpen task)
#   -f, --force  Proceed without prompting
#   -h, --help   Show usage information

set -euo pipefail

MODE="full"
MODE_SET=false
FORCE_MODE=false # reserved: proceed without prompting

NODE_MODULES_DIR="node_modules"
VENV_DIR=".venv"

print_usage() {
  echo "Usage: $0 [full|folder-open] [-f|--force]"
  echo "  full         Full bootstrap (default): deps + hooks (+ Python venv when applicable)"
  echo "  folder-open  Repair only what is missing/broken (VS Code folderOpen task)"
  echo "  -f, --force  Proceed without prompting"
  echo "  -h, --help   Show usage information"
}

fail() {
  echo "Error: $1" >&2
  exit 1
}

command_exists() {
  command -v "$1" > /dev/null 2>&1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      full | folder-open)
        if [ "$MODE_SET" = true ]; then
          print_usage >&2
          fail "Mode already provided: $MODE"
        fi
        MODE="$1"
        MODE_SET=true
        shift
        ;;
      -f | --force)
        FORCE_MODE=true
        shift
        ;;
      -h | --help)
        print_usage
        exit 0
        ;;
      *)
        print_usage >&2
        fail "Unknown option: $1"
        ;;
    esac
  done
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

ensure_pm_launcher() {
  local pm="$1"
  if command_exists "$pm"; then
    echo "Using $pm from PATH"
    return 0
  fi
  # yarn/pnpm can be provisioned by corepack; npm ships with Node; bun must be installed.
  case "$pm" in
    yarn | pnpm)
      if command_exists corepack; then
        echo "Enabling corepack to provide $pm"
        corepack enable "$pm"
        return 0
      fi
      fail "$pm or corepack is required. Install Node.js and retry."
      ;;
    *)
      fail "$pm is required but was not found on PATH."
      ;;
  esac
}

pm_install() {
  echo "Installing Node dependencies with $1..."
  "$1" install
}

pm_prepare() {
  # The skill gitignores .husky/ and regenerates hooks from the package.json `prepare`
  # script, so repairing hooks == re-running prepare.
  echo "Regenerating Husky hooks ($1 run prepare)..."
  "$1" run prepare
}

has_broken_dev_hooks() {
  local hook_path
  for hook_path in .husky/commit-msg .husky/pre-commit; do
    if [ ! -f "$hook_path" ] || [ ! -x "$hook_path" ]; then
      return 0
    fi
  done
  return 1
}

# section: python (uv-first, pip fallback)
is_python_project() {
  [ -f pyproject.toml ] && return 0
  find . -name '*.py' -not -path './node_modules/*' -not -path "./$VENV_DIR/*" -print -quit 2> /dev/null | grep -q .
}

has_sql() {
  find . -name '*.sql' -not -path './node_modules/*' -not -path "./$VENV_DIR/*" -print -quit 2> /dev/null | grep -q .
}

python_tools() {
  # black is always needed; sqlfluff only when the repo has SQL (python-stream flavor).
  local tools="black"
  if has_sql; then
    tools="$tools sqlfluff"
  fi
  echo "$tools"
}

venv_missing_tools() {
  local t
  for t in $(python_tools); do
    [ -x "$VENV_DIR/bin/$t" ] || return 0
  done
  return 1
}

bootstrap_python() {
  local tools
  tools="$(python_tools)"
  if command_exists uv; then
    echo "Bootstrapping Python venv with uv..."
    uv venv
    # shellcheck disable=SC2086
    uv pip install $tools
  elif command_exists python3; then
    echo "uv not found; bootstrapping Python venv with python3 -m venv + pip..."
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip
    # shellcheck disable=SC2086
    "$VENV_DIR/bin/pip" install $tools
  else
    fail "Python is required for this repo but neither uv nor python3 was found."
  fi
}

# section: execution
run_full_bootstrap() {
  if [ -f package.json ]; then
    local pm
    pm="$(detect_pm)"
    ensure_pm_launcher "$pm"
    pm_install "$pm"
    pm_prepare "$pm"
  fi

  if is_python_project; then
    bootstrap_python
  fi

  echo "Project bootstrap completed successfully."
}

run_folder_open_bootstrap() {
  local acted=false

  if [ -f package.json ]; then
    local pm need_install=false need_hooks=false
    pm="$(detect_pm)"

    if [ ! -d "$NODE_MODULES_DIR" ]; then
      echo "$NODE_MODULES_DIR is missing; will install dependencies"
      need_install=true
    fi
    if has_broken_dev_hooks; then
      echo "Husky hooks are missing or not executable; will repair"
      need_hooks=true
    fi

    if [ "$need_install" = true ] || [ "$need_hooks" = true ]; then
      ensure_pm_launcher "$pm"
    fi
    if [ "$need_install" = true ]; then
      pm_install "$pm" # runs prepare -> regenerates hooks
      need_hooks=false
      acted=true
    fi
    if [ "$need_hooks" = true ]; then
      pm_prepare "$pm"
      acted=true
    fi
  fi

  if is_python_project && { [ ! -d "$VENV_DIR" ] || venv_missing_tools; }; then
    echo "Python venv missing or incomplete; bootstrapping"
    bootstrap_python
    acted=true
  fi

  if [ "$acted" = true ]; then
    echo "Folder-open bootstrap completed successfully."
  else
    echo "Project bootstrap is already healthy. No issues detected."
  fi
}

# code-review-graph / graphify setup is owned by the setup-graph-hooks skill, not this script.

parse_args "$@"

case "$MODE" in
  full)
    run_full_bootstrap
    ;;
  folder-open)
    run_folder_open_bootstrap
    ;;
esac
