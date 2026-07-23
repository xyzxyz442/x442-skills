#!/usr/bin/env bash
# initialize.sh — workspace bootstrap for a repo wired by setup-project-tooling.
# Installs missing dependencies and repairs Husky hooks so a freshly cloned or freshly
# opened workspace is ready to commit. Idempotent: it only acts on what is missing or broken.
#
# Package-manager aware (npm/pnpm/yarn/bun, detected from the lockfile). Python tooling is
# resolved by scripts/py-tool.sh (uvx -> uv -> pipx -> .venv): with uv or pipx present this
# just pre-fetches the pinned tools, and without either it creates the .venv fallback and
# installs the versions py-tool.sh pins. Hooks are repaired by re-running the package.json
# hook-install command (`install:dev` by default), which delegates to scripts/husky.sh and
# regenerates the gitignored .husky/ hooks.
#
# Usage: ./initialize.sh [full|folder-open] [-f|--force]
#   full         Full bootstrap (default): deps + hooks (+ Python tool cache when applicable)
#   folder-open  Repair only what is missing/broken (used by the VS Code folderOpen task)
#   -f, --force  Proceed without prompting
#   -h, --help   Show usage information

set -euo pipefail

MODE="full"
MODE_SET=false
FORCE_MODE=false # reserved: proceed without prompting

NODE_MODULES_DIR="node_modules"
VENV_DIR=".venv"
HUSKY_SCRIPT="scripts/husky.sh"
PY_TOOL="scripts/py-tool.sh"

print_usage() {
  echo "Usage: $0 [full|folder-open] [-f|--force]"
  echo "  full         Full bootstrap (default): deps + hooks (+ Python tool cache when applicable)"
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

detect_hook_install_cmd() {
  # The skill installs hooks under `install:dev`, deliberately not `prepare` — that npm
  # lifecycle script fires on every plain install (CI and Docker builds included) and is
  # frequently owned by a DevOps pipeline. Prefer install:dev, fall back to prepare for repos
  # wired by an earlier version, then to whichever script invokes husky.
  if command_exists node && [ -f package.json ]; then
    node -e '
      const s = require("./package.json").scripts || {};
      for (const name of ["install:dev", "prepare"]) {
        if (s[name]) { console.log(name); process.exit(0); }
      }
      const found = Object.keys(s).find((k) => /husky/.test(s[k]));
      if (!found) process.exit(1);
      console.log(found);
    ' 2> /dev/null && return 0
  fi
  echo "install:dev"
}

pm_prepare() {
  # The skill gitignores .husky/ and regenerates hooks from a single package.json command
  # that delegates to scripts/husky.sh, so repairing hooks == re-running that command.
  local cmd
  cmd="$(detect_hook_install_cmd)"
  # The command invokes the dispatcher directly, so it has to be executable first.
  if [ -f "$HUSKY_SCRIPT" ] && [ ! -x "$HUSKY_SCRIPT" ]; then
    echo "Restoring the executable bit on $HUSKY_SCRIPT"
    chmod +x "$HUSKY_SCRIPT"
  fi
  echo "Regenerating Husky hooks ($1 run $cmd)..."
  "$1" run "$cmd"
}

has_broken_dev_hooks() {
  local hook_path
  # The generated hooks are one-line wrappers around the dispatcher, so a dispatcher that is
  # present but not executable is just as broken as a missing hook.
  if [ -f "$HUSKY_SCRIPT" ] && [ ! -x "$HUSKY_SCRIPT" ]; then
    return 0
  fi
  for hook_path in .husky/commit-msg .husky/pre-commit; do
    if [ ! -f "$hook_path" ] || [ ! -x "$hook_path" ]; then
      return 0
    fi
  done
  return 1
}

# section: python (uvx — no project .venv)
# The .venv excludes below are literal: this script no longer creates one, but a repo may keep
# its own for application dependencies and neither scan should descend into it.
is_python_project() {
  [ -f pyproject.toml ] && return 0
  find . -name '*.py' -not -path './node_modules/*' -not -path './.venv/*' -print -quit 2> /dev/null | grep -q .
}

has_sql() {
  find . -name '*.sql' -not -path './node_modules/*' -not -path './.venv/*' -print -quit 2> /dev/null | grep -q .
}

python_tools() {
  # ruff + black are always needed; sqlfluff only when the repo has SQL (python-stream flavor).
  local tools="ruff black"
  if has_sql; then
    tools="$tools sqlfluff"
  fi
  echo "$tools"
}

has_py_runner() {
  # scripts/py-tool.sh resolves uvx -> uv -> pipx -> .venv. The first three need nothing here.
  command_exists uvx || command_exists uv || command_exists pipx
}

py_tools_ready() {
  # With uv or pipx present the tools resolve on demand; only the venv fallback needs files
  # on disk before a commit can succeed.
  has_py_runner && return 0
  local tool
  for tool in $(python_tools); do
    [ -x "$VENV_DIR/bin/$tool" ] || return 1
  done
  return 0
}

bootstrap_python() {
  local tool specs=""

  [ -f "$PY_TOOL" ] || fail "$PY_TOOL is missing; re-run setup-project-tooling to install it."
  # The lint-staged commands invoke it directly, so it has to be executable.
  if [ ! -x "$PY_TOOL" ]; then
    echo "Restoring the executable bit on $PY_TOOL"
    chmod +x "$PY_TOOL"
  fi

  if has_py_runner; then
    # Pre-fetch through the same resolver the hooks use, so the first commit does not pay a
    # download inside a git hook. Pins come from py-tool.sh, never from this file.
    echo "Pre-fetching Python tools via $PY_TOOL..."
    for tool in $(python_tools); do
      echo "  $tool"
      "$PY_TOOL" "$tool" --version > /dev/null
    done
    return 0
  fi

  # No uv and no pipx: fall back to a traditional virtualenv, installing the versions
  # py-tool.sh pins so the fallback matches what the other runners would have used.
  command_exists python3 || fail "this repo's Python tooling needs uv, pipx or python3; none was found on PATH."
  for tool in $(python_tools); do
    specs="$specs $("$PY_TOOL" --spec "$tool")"
  done
  echo "uv and pipx not found; bootstrapping $VENV_DIR with python3 -m venv + pip..."
  [ -d "$VENV_DIR" ] || python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip
  # shellcheck disable=SC2086
  "$VENV_DIR/bin/pip" install $specs
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
      # `install:dev` is deliberately not an npm lifecycle script, so a plain install does
      # NOT regenerate the hooks — they still have to be installed explicitly below.
      pm_install "$pm"
      need_hooks=true
      acted=true
    fi
    if [ "$need_hooks" = true ]; then
      pm_prepare "$pm"
      acted=true
    fi
  fi

  if is_python_project && ! py_tools_ready; then
    echo "Python tooling is not runnable yet; bootstrapping"
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
