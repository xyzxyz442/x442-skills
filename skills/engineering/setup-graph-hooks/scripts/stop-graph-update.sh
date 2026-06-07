#!/usr/bin/env bash
# stop-graph-update.sh — Stop hook: refresh the code-review-graph once per AI turn.
# PID-guarded per-repo so overlapping turns never stack; embed runs detached. No-op if CRG is
# not installed or the graph is not built. Logic lives here (not inline in settings) so the hook
# COMMAND string stays a stable thin wrapper — Claude Code de-dupes identical command strings, so
# a home install and a repo install collapse to a single fire instead of double-running.
set -uo pipefail

command -v code-review-graph >/dev/null 2>&1 || exit 0
[ -d .code-review-graph ] || exit 0

PF="/tmp/crg-claude-$(pwd | { md5sum 2>/dev/null || md5 2>/dev/null; } | cut -c1-8).pid"
if [ -f "$PF" ] && kill -0 "$(cat "$PF" 2>/dev/null)" 2>/dev/null; then
  exit 0   # an update for this repo is already running
fi

{ code-review-graph update --skip-flows 2>/dev/null && nohup code-review-graph embed >/dev/null 2>&1 & } &
echo $! > "$PF"
exit 0
