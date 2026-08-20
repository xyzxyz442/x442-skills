#!/usr/bin/env bash
# claude adapter — Claude Code. Prompt on stdin; schema inline; per-tool allowlist.
set -euo pipefail
ACTION="${1:?build|parse}"
SPEC="$(cat)"
g() { printf '%s' "$SPEC" | jq -r "$1 // empty"; }

case "$ACTION" in
  env)
    b="$(g '.base_url')"
    # A configDir supplies its own endpoint via the CLI's settings.json; setting it here too would
    # give the child two sources of truth for where its traffic goes.
    [ -n "$b" ] && [ -z "$(g '.config_dir')" ] && printf 'ANTHROPIC_BASE_URL=%s\n' "$b"
    exit 0
    ;;
  build)
    [ "$(g '.strict_mcp')" = "true" ] && printf '%s\n' '--strict-mcp-config'
    printf '%s\n' '-p' '--output-format' 'json'
    s="$(g '.schema_file')"
    [ -n "$s" ] && [ -f "$s" ] && printf '%s\n' '--json-schema' "$(cat "$s")"
    printf '%s\n' '--max-turns' "$(g '.max_turns')"
    printf '%s\n' '--permission-mode' "$(g '.mode')"
    printf '%s\n' '--allowedTools' "$(g '.allow_tools')"
    printf '%s\n' '--disallowedTools' 'WebFetch,WebSearch'
    [ "$(g '.worktree')" = "true" ] && printf '%s\n' '--worktree'
    r="$(g '.resume')"
    [ -n "$r" ] && printf '%s\n' '--resume' "$r"
    m="$(g '.model')"
    [ -n "$m" ] && printf '%s\n' '--model' "$m"
    exit 0
    ;;
  parse)
    raw="$(g '.raw_file')"
    jq -c '{result: (.result // ""), session_id: (.session_id // "")}' "$raw"
    ;;
  *)
    echo "claude adapter: unknown action $ACTION" >&2
    exit 64
    ;;
esac
