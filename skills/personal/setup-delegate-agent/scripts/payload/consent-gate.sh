#!/usr/bin/env bash
# consent-gate.sh — PreToolUse backstop for delegated dispatches.
#
#   consent-gate.sh --tool claude|gemini|copilot
#
# Reads a PreToolUse hook payload on stdin. Denies a shell command that would start a delegated
# run without recorded consent, and denies any attempt to reach the backend wrapper directly.
#
# Why a hook when delegate-run already enforces consent: the dispatcher can only guard its own
# front door. A session that calls `delegate-agent -p ...` straight from Bash skips the dispatcher
# entirely — same weights, same egress, no gate. This closes that path.
#
# Honest about its limits: this is a cooperative gate, not a sandbox. It raises skipping the
# assessment from an omission to a deliberate act; it cannot stop a determined caller who writes
# an approval record by hand. The security boundary is the tool allowlist and the worktree, not
# this script.
#
# Read-only: never writes, never dials the network, and exits 0 (allow) on anything it cannot parse.

set -euo pipefail

TOOL="claude"
while [ $# -gt 0 ]; do
  case "$1" in
    --tool)
      TOOL="${2:-claude}"
      shift 2
      ;;
    *) shift ;;
  esac
done

command -v python3 > /dev/null 2>&1 || exit 0
PAYLOAD="$(cat 2> /dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0

deny() {
  python3 - "$TOOL" "$1" << 'PY'
import json, sys
tool, msg = sys.argv[1], sys.argv[2]
if tool == "gemini":
    out = {"decision": "deny", "reason": msg}
elif tool == "copilot":
    out = {"hookSpecificOutput": {"hookEventName": "preToolUse",
                                  "permissionDecision": "deny",
                                  "permissionDecisionReason": msg}}
else:
    out = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                  "permissionDecision": "deny",
                                  "permissionDecisionReason": msg}}
print(json.dumps(out))
PY
  exit 0
}

# Extract the command string. Field names differ per tool, so try the known ones and give up
# quietly rather than guessing — a hook that fails closed on an unrecognised payload would block
# every unrelated shell command in the session.
CMD="$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or d.get("toolInput") or d.get("input") or {}
if isinstance(ti, dict):
    print(ti.get("command") or ti.get("cmd") or "")
' 2> /dev/null || true)"
[ -n "$CMD" ] || exit 0

# Direct use of the wrapper bypasses every check the dispatcher performs: consent, the
# never-delegate floor, the allowlist comparison, and round accounting.
if printf '%s' "$CMD" | grep -qE '(^|[/[:space:]])delegate-agent([[:space:]]|$)'; then
  deny "Do not invoke delegate-agent directly — it skips the consent gate, the never-delegate paths, and round accounting. Dispatch through delegate-run, which the run-delegate-agent skill drives."
fi

if printf '%s' "$CMD" | grep -qE '(^|[/[:space:]])delegate-run([[:space:]]|$)'; then
  # Recording consent and dry runs are the two safe subcommands: neither reaches a backend.
  printf '%s' "$CMD" | grep -qE -- '--approve([[:space:]]|=)' && exit 0
  printf '%s' "$CMD" | grep -qE -- '--dry-run([[:space:]]|$)' && exit 0
  printf '%s' "$CMD" | grep -qE -- '--approved([[:space:]]|=)' || deny \
    "This dispatch has no recorded consent. Assess the task first (fit, size, egress, risk), ask the user, then record it: delegate-run --approve <task-id> --class <class> --profile <p> --allow '<tools>'. See the run-delegate-agent skill."
fi

exit 0
