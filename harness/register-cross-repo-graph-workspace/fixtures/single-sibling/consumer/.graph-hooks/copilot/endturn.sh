#!/usr/bin/env bash
# Copilot adapter wrapper (end-of-turn refresh; wired only when Copilot is the --primary
# refresh owner). See pretool-shell.sh for why a wrapper is needed.
exec bash "$(cd "$(dirname "$0")/.." && pwd)/hook.sh" --tool copilot --kind endturn
