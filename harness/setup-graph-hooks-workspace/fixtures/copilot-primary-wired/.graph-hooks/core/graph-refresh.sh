#!/usr/bin/env bash
# graph-refresh.sh — tool-neutral once-per-turn code-review-graph refresh. No stdin/stdout.
# Wired into the end-of-turn event of the single PRIMARY tool only (setup --primary), so N
# wired tools never trigger N graph builds. Belt-and-suspenders against a stray concurrent
# refresh (a second tool, or two sessions on one repo): a repo-global mkdir lock guards the
# brief check-and-launch, and a repo-global PID file skips when a refresh is already running.
#
# mkdir is used as the portable lock primitive on purpose — macOS ships no `flock`, but
# `mkdir` is atomic everywhere. No-op unless code-review-graph is installed and built.
set -uo pipefail

command -v code-review-graph > /dev/null 2>&1 || exit 0
[ -d .code-review-graph ] || exit 0

KEY="$(pwd | { md5sum 2> /dev/null || md5 2> /dev/null; } | cut -c1-8)"
TMP="${TMPDIR:-/tmp}"
LK="$TMP/crg-graph-${KEY:-x}.lock" # repo-global, tool-independent (shared across tools)
PF="$TMP/crg-graph-${KEY:-x}.pid"

# Grab the launch lock atomically; if another launcher holds it right now, skip silently.
mkdir "$LK" 2> /dev/null || exit 0
trap 'rmdir "$LK" 2>/dev/null || true' EXIT

# If a refresh for this repo is already running (any tool/session), skip.
if [ -f "$PF" ] && kill -0 "$(cat "$PF" 2> /dev/null)" 2> /dev/null; then
  exit 0
fi

# `embed` is an opt-in tier: embed-provider.sh --run resolves the configured provider and
# no-ops when there is none. Without the gate, every turn on a repo with no embedding provider
# spawned a doomed `code-review-graph embed` (a hard error, swallowed by the redirect below)
# and paid a sentence-transformers/torch import to discover it had nothing to do.
{ code-review-graph update --skip-flows 2> /dev/null && nohup bash .graph-hooks/core/embed-provider.sh --run > /dev/null 2>&1 & } &
echo $! > "$PF"
exit 0
