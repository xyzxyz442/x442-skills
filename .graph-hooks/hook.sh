#!/usr/bin/env bash
# hook.sh — single dispatcher for the knowledge-graph hooks across AI tools.
#
#   Usage: hook.sh --tool <claude|gemini|copilot|antigravity> \
#                  --kind <pretool-shell|pretool-read|sessionstart|endturn>
#
# Reads the tool's hook JSON on stdin, runs the shared behavior core, and emits that
# tool's hook JSON on stdout. ALL per-tool protocol knowledge lives in core/extract.py
# (stdin field names) and core/emit.py (stdout JSON shape); ALL behavior lives in
# core/*.sh. This wrapper is intentionally thin and stable so its command string never
# changes across versions — Claude Code de-dupes identical command strings, so a home
# install and a repo install collapse to a SINGLE fire instead of double-running.
#
# Every path silently no-ops when a graph or tool is absent, so it is safe on any repo.
set -uo pipefail

TOOL=""; KIND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tool) TOOL="${2:-}"; shift 2 ;;
    --kind) KIND="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

DIR="$(cd "$(dirname "$0")" && pwd)"
CORE="$DIR/core"
INPUT="$(cat 2>/dev/null || true)"

case "$KIND" in
  pretool-shell)
    CMD="$(printf '%s' "$INPUT" | python3 "$CORE/extract.py" --tool "$TOOL" --field command 2>/dev/null || true)"
    [ -z "$CMD" ] && exit 0
    printf '%s' "$CMD" | bash "$CORE/grep-steer.sh" \
      | python3 "$CORE/emit.py" --tool "$TOOL" --event pretool 2>/dev/null || true
    ;;
  pretool-read)
    T="$(printf '%s' "$INPUT" | python3 "$CORE/extract.py" --tool "$TOOL" --field readtarget 2>/dev/null || true)"
    [ -z "$T" ] && exit 0
    printf '%s' "$T" | bash "$CORE/read-nudge.sh" \
      | python3 "$CORE/emit.py" --tool "$TOOL" --event pretool 2>/dev/null || true
    ;;
  sessionstart)
    bash "$CORE/session-context.sh" \
      | python3 "$CORE/emit.py" --tool "$TOOL" --event session 2>/dev/null || true
    ;;
  endturn)
    # Heavy refresh — wired for the primary tool only (see setup-graph-hooks.sh --primary).
    bash "$CORE/graph-refresh.sh" 2>/dev/null || true
    ;;
  *)
    exit 0
    ;;
esac
exit 0
