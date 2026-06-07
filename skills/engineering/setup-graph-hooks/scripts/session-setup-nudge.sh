#!/usr/bin/env bash
# session-setup-nudge.sh — SessionStart hook: if the CRG CLI is installed but no graph is built
# yet in this repo, emit a one-line systemMessage prompting setup. No-op otherwise. Logic lives
# here so the hook COMMAND string stays a stable thin wrapper that Claude Code can de-dupe.
set -uo pipefail

if command -v code-review-graph >/dev/null 2>&1 \
   && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
   && [ ! -d .code-review-graph ]; then
  printf '{"systemMessage":"Graph tool installed but not yet initialized. Ask me to set up: code-review-graph (code-review-graph install)"}'
fi
exit 0
