#!/usr/bin/env bash
# codex adapter — OpenAI Codex CLI. Prompt on stdin; schema from a file; SANDBOX, not a tool list.
#
# `--oss --local-provider lmstudio` is what makes a local OpenAI-compatible server reachable:
# LM Studio serves /v1/chat/completions, which an Anthropic-protocol CLI cannot talk to at all.
set -euo pipefail
ACTION="${1:?build|parse}"
SPEC="$(cat)"
g() { printf '%s' "$SPEC" | jq -r "$1 // empty"; }

case "$ACTION" in
  env) exit 0 ;;
  build)
    printf '%s\n' 'exec' '--json' '--skip-git-repo-check'
    printf '%s\n' '-o' "$(g '.last_message_file')"
    s="$(g '.schema_file')"
    [ -n "$s" ] && [ -f "$s" ] && printf '%s\n' '--output-schema' "$s"
    m="$(g '.model')"
    [ -n "$m" ] && printf '%s\n' '-m' "$m"
    lp="$(g '.local_provider')"
    [ -n "$lp" ] && printf '%s\n' '--oss' '--local-provider' "$lp"
    # Sandbox levels are the only scoping codex offers. Anything that may write gets
    # workspace-write; everything else stays read-only. Deliberately coarse, and the resolver
    # warns that the approved tool list is approximated rather than enforced.
    case "$(g '.mode')" in
      acceptEdits) printf '%s\n' '-s' 'workspace-write' ;;
      *) printf '%s\n' '-s' 'read-only' ;;
    esac
    printf '%s\n' '-'
    exit 0
    ;;
  parse)
    raw="$(g '.raw_file')"
    last="$(g '.last_message_file')"
    result=""
    [ -f "$last" ] && result="$(cat "$last")"
    # Session id appears in the JSONL event stream; field name varies by version, so take the
    # first non-empty of the known spellings rather than assuming one.
    sid="$(jq -rs '[.[]? | (.session_id // .sessionId // .conversation_id // empty)] | first // ""' \
      < "$raw" 2> /dev/null || true)"
    jq -nc --arg r "$result" --arg s "$sid" '{result:$r, session_id:$s}'
    ;;
  *)
    echo "codex adapter: unknown action $ACTION" >&2
    exit 64
    ;;
esac
