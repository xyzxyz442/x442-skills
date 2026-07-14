#!/usr/bin/env bash
# Copilot adapter wrapper (read nudge). See pretool-shell.sh for why a wrapper is needed.
exec bash "$(cd "$(dirname "$0")/.." && pwd)/hook.sh" --tool copilot --kind pretool-read
