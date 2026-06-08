#!/usr/bin/env bash
# Copilot adapter wrapper (session start). See pretool-shell.sh for why a wrapper is needed.
exec bash "$(cd "$(dirname "$0")/.." && pwd)/hook.sh" --tool copilot --kind sessionstart
