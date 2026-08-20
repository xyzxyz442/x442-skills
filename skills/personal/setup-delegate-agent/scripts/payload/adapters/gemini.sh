#!/usr/bin/env bash
# gemini adapter — Gemini CLI. Prompt as an ARGUMENT; policy engine, not a flat allowlist; no schema.
#
# UNVERIFIED against a live backend. Gemini's tool control is a policy engine rather than a list,
# so the approved tool set is carried as an approval MODE, not enforced name by name.
set -euo pipefail
ACTION="${1:?build|parse}"
SPEC="$(cat)"
g() { printf '%s' "$SPEC" | jq -r "$1 // empty"; }

case "$ACTION" in
  build)
    printf '%s\n' '-p' "$(cat "$(g '.prompt_file')")"
    printf '%s\n' '-o' 'json'
    m="$(g '.model')"
    [ -n "$m" ] && printf '%s\n' '-m' "$m"
    case "$(g '.mode')" in
      acceptEdits) printf '%s\n' '--approval-mode' 'auto_edit' ;;
      plan) printf '%s\n' '--approval-mode' 'plan' ;;
      *) printf '%s\n' '--approval-mode' 'default' ;;
    esac
    r="$(g '.resume')"
    [ -n "$r" ] && printf '%s\n' '--session-id' "$r"
    exit 0
    ;;
  parse)
    raw="$(g '.raw_file')"
    result="$(jq -r '(.response // .result // .text // "")' < "$raw" 2> /dev/null || true)"
    sid="$(jq -r '(.session_id // .sessionId // "")' < "$raw" 2> /dev/null || true)"
    jq -nc --arg r "$result" --arg s "$sid" '{result:$r, session_id:$s}'
    ;;
  *)
    echo "gemini adapter: unknown action $ACTION" >&2
    exit 64
    ;;
esac
