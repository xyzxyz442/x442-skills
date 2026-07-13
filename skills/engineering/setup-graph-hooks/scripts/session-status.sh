#!/usr/bin/env bash
# session-status.sh — SessionStart hook: print the code-review-graph status on session open.
# No-op when CRG is not installed. Logic lives here so the hook COMMAND string stays a stable thin
# wrapper that Claude Code can de-dupe across a home install and a repo install.
set -uo pipefail

command -v code-review-graph > /dev/null 2>&1 && code-review-graph status 2> /dev/null || true
exit 0
