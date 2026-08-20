#!/usr/bin/env bash
# copilot adapter — GitHub Copilot CLI. Prompt as an ARGUMENT; per-tool allowlist; no schema.
#
# Reaches any OpenAI-compatible endpoint through BYOK, which is what makes it usable for a local
# model: `COPILOT_PROVIDER_BASE_URL` activates it, GitHub auth is not required, and an API key is
# optional for local providers. That matters because an Anthropic-protocol CLI cannot talk to a
# local OpenAI server at all.
#
# The ask-back contract is best-effort here: nothing forces the final message into the
# {status, question} shape the dispatcher looks for, so a blocked sub-agent may return prose.
set -euo pipefail
ACTION="${1:?build|parse}"
SPEC="$(cat)"
g() { printf '%s' "$SPEC" | jq -r "$1 // empty"; }

case "$ACTION" in
  env)
    # BYOK is activated by the base URL alone. Without one, copilot uses GitHub's own routing and
    # these are all unset, which is the correct behaviour for a hosted Copilot agent.
    b="$(g '.base_url')"
    if [ -n "$b" ]; then
      printf 'COPILOT_PROVIDER_BASE_URL=%s\n' "$b"
      printf 'COPILOT_PROVIDER_TYPE=%s\n' "$(printf '%s' "$SPEC" | jq -r '.provider_type // "openai"')"
      m="$(g '.model')"
      [ -n "$m" ] && printf 'COPILOT_MODEL=%s\n' "$m"
    fi
    exit 0
    ;;
  build)
    printf '%s\n' '-p' "$(cat "$(g '.prompt_file')")"
    printf '%s\n' '--silent' '--output-format' 'json'
    m="$(g '.model')"
    [ -n "$m" ] && printf '%s\n' '--model' "$m"
    # copilot scopes by permission KIND, not by tool name. --available-tools takes real tool
    # names and disables everything else, so passing a Claude-style list ("Read,Grep,Glob") there
    # silently exposes ZERO tools — the model then imitates a tool call in prose and nothing runs.
    # Map the dispatch intent onto the kinds copilot actually understands instead.
    printf '%s\n' '--allow-all-tools'
    printf '%s\n' '--deny-tool' 'url'
    case "$(g '.mode')" in
      acceptEdits) printf '%s\n' '--deny-tool' 'shell' ;;
      *) printf '%s\n' '--deny-tool' 'shell' '--deny-tool' 'write' ;;
    esac
    r="$(g '.resume')"
    [ -n "$r" ] && printf '%s\n' '--resume' "$r"
    exit 0
    ;;
  parse)
    raw="$(g '.raw_file')"
    # copilot streams JSONL: the assistant message arrives as `assistant.message_delta` events and
    # the session id only appears on the terminal `result` event. Reading a single `.content` field
    # therefore returns nothing, which reads as a successful empty answer.
    result="$(jq -rs '[.[]? | select(.type=="assistant.message_delta") | (.data.delta // .data.content // "")] | join("")' < "$raw" 2> /dev/null || true)"
    if [ -z "$result" ]; then
      result="$(jq -rs '[.[]? | select(.type=="assistant.message") | .data.content] | last // ""' < "$raw" 2> /dev/null || true)"
    fi
    sid="$(jq -rs '[.[]? | (.sessionId // .data.sessionId // empty)] | last // ""' < "$raw" 2> /dev/null || true)"
    jq -nc --arg r "$result" --arg s "$sid" '{result:$r, session_id:$s}'
    ;;
  *)
    echo "copilot adapter: unknown action $ACTION" >&2
    exit 64
    ;;
esac
