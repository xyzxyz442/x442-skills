#!/usr/bin/env bash
# py-tool.sh — run a pinned Python tool without assuming how it is installed.
#
# Resolution order: uvx (or `uv tool run`) -> `pipx run` -> the repo's .venv. The first one
# available wins, so a machine with uv gets ephemeral, cached, correctly pinned tools and a
# machine with neither uv nor pipx still works from a traditional virtualenv.
#
# Versions are pinned HERE and nowhere else. package.json and .lintstagedrc.json name the tool
# only, so bumping a formatter is a one-line edit in this file rather than a hunt across
# several config files that can silently disagree.
#
# Usage: scripts/py-tool.sh <tool> [args...]     run the tool
#        scripts/py-tool.sh --spec <tool>        print its pip requirement specifier
#        scripts/py-tool.sh --tools              list the tools this script knows
#   <tool> is ruff, black or sqlfluff.

set -euo pipefail

RUFF_VERSION="0.15.22"
BLACK_VERSION="26.5.1"
SQLFLUFF_VERSION="4.2.2"

VENV_DIR=".venv"

print_usage() {
  echo "Usage: $0 <tool> [args...]   run a pinned Python tool (ruff | black | sqlfluff)"
  echo "       $0 --spec <tool>      print the pip requirement specifier, e.g. ruff==0.0.0"
  echo "       $0 --tools            list the known tools"
}

fail() {
  echo "Error: $1" >&2
  exit 1
}

command_exists() {
  command -v "$1" > /dev/null 2>&1
}

tool_version() {
  case "$1" in
    ruff) echo "$RUFF_VERSION" ;;
    black) echo "$BLACK_VERSION" ;;
    sqlfluff) echo "$SQLFLUFF_VERSION" ;;
    *) fail "unknown tool '$1' (expected ruff, black or sqlfluff)" ;;
  esac
}

run_tool() {
  local tool="$1"
  shift
  local version
  version="$(tool_version "$tool")"

  if command_exists uvx; then
    exec uvx "$tool@$version" "$@"
  elif command_exists uv; then
    exec uv tool run "$tool@$version" "$@"
  elif command_exists pipx; then
    exec pipx run --spec "$tool==$version" "$tool" "$@"
  elif [ -x "$VENV_DIR/bin/$tool" ]; then
    # Traditional virtualenv fallback. The pin is not enforced here — whatever the venv holds
    # is what runs — so `initialize.sh` installs the pinned specs when it creates the venv.
    exec "$VENV_DIR/bin/$tool" "$@"
  fi

  fail "cannot run '$tool': no uv, no pipx, and no $VENV_DIR/bin/$tool.
  Install uv (recommended):  curl -LsSf https://astral.sh/uv/install.sh | sh
  or pipx:                   python3 -m pip install --user pipx
  or create the virtualenv:  ./initialize.sh full"
}

main() {
  if [ "$#" -eq 0 ]; then
    print_usage >&2
    fail "no tool given."
  fi

  case "$1" in
    -h | --help)
      print_usage
      ;;
    --tools)
      echo "ruff black sqlfluff"
      ;;
    --spec)
      [ "$#" -ge 2 ] || fail "--spec needs a tool name."
      echo "$2==$(tool_version "$2")"
      ;;
    -*)
      print_usage >&2
      fail "unknown option: $1"
      ;;
    *)
      run_tool "$@"
      ;;
  esac
}

main "$@"
