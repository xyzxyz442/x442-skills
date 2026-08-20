#!/usr/bin/env bash
# copilot adapter — GitHub Copilot CLI. Prompt as an ARGUMENT; per-tool allowlist; no schema.
#
# UNVERIFIED against a live backend. The flags come from `copilot --help` on this machine; the
# ask-back contract in particular is best-effort here, because nothing forces the final message
# into the {status, question} shape the dispatcher looks for.
set -euo pipefail
ACTION="${1:?build|parse}"
SPEC="$(cat)"
g() { printf '%s' "$SPEC" | jq -r "$1 // empty"; }

case "$ACTION" in
  build)
    printf '%s\n' '-p' "$(cat "$(g '.prompt_file')")"
    printf '%s\n' '--silent' '--output-format' 'json'
    m="$(g '.model')"
    [ -n "$m" ] && printf '%s\n' '--model' "$m"
    # --available-tools is the hard bound (the model cannot see anything else); --allow-tool
    # additionally suppresses the confirmation prompt, which a headless run cannot answer.
    tools="$(g '.allow_tools')"
    if [ -n "$tools" ]; then
      printf '%s\n' '--available-tools' "$tools" '--allow-tool' "$tools"
    fi
    r="$(g '.resume')"
    [ -n "$r" ] && printf '%s\n' '--resume' "$r"
    exit 0
    ;;
  parse)
    raw="$(g '.raw_file')"
    # JSONL: one object per line. Take the last line carrying text, and the first session id seen.
    result="$(jq -rs '[.[]? | (.content // .text // .message // empty)] | last // ""' < "$raw" 2> /dev/null || true)"
    sid="$(jq -rs '[.[]? | (.session_id // .sessionId // empty)] | first // ""' < "$raw" 2> /dev/null || true)"
    jq -nc --arg r "$result" --arg s "$sid" '{result:$r, session_id:$s}'
    ;;
  *)
    echo "copilot adapter: unknown action $ACTION" >&2
    exit 64
    ;;
esac
