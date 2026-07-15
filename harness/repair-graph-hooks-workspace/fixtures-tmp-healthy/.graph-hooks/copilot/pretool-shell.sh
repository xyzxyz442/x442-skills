#!/usr/bin/env bash
# Copilot adapter wrapper. Copilot's .github/hooks/*.json "bash" field takes a script
# PATH (no inline args), so each kind gets a tiny fixed wrapper that delegates to the
# shared dispatcher. exec preserves stdin/stdout so the hook contract is unchanged.
exec bash "$(cd "$(dirname "$0")/.." && pwd)/hook.sh" --tool copilot --kind pretool-shell
