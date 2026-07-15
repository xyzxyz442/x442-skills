#!/usr/bin/env python3
# emit.py — translate a NEUTRAL hook decision into a specific tool's hook JSON.
#
#   emit.py --tool <name> --event <pretool|session>
#
# The other half of the per-tool protocol table (see extract.py). Reads a neutral
# decision object on stdin (emitted by a behavior core) and writes the tool-specific
# JSON on stdout. Empty stdin / unknown shape -> print nothing (pass / no-op).
#
# Neutral schema (all keys optional):
#   {"decision": "deny",        # block the tool call
#    "reason": "...",           # deny reason (falls back to context)
#    "context": "...",          # advice to inject as additional context
#    "systemMessage": "..."}    # session-level system message
#
# Per-tool output contracts (sources cited in SKILL.md):
#   Claude Code   PreToolUse deny  -> hookSpecificOutput.permissionDecision="block"
#                 context          -> hookSpecificOutput.additionalContext
#   Gemini CLI    BeforeTool deny  -> {"decision":"deny","reason":...}
#                 context          -> hookSpecificOutput.additionalContext
#   GitHub Copilot preToolUse deny -> {"permissionDecision":"deny","permissionDecisionReason":...}
#                 (no context injection on preToolUse; sessionStart uses additionalContext)
#   Antigravity   UNVERIFIED — best-effort mirror of Claude/Gemini; not activated by the
#                 installer until its contract is confirmed (TODO(antigravity-hooks)).
import argparse
import json
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tool", required=True)
    ap.add_argument("--event", required=True, choices=["pretool", "session"])
    args = ap.parse_args()

    raw = sys.stdin.read().strip()
    if not raw:
        return 0
    try:
        n = json.loads(raw)
    except Exception:
        return 0
    if not isinstance(n, dict):
        return 0

    decision = n.get("decision")
    context = n.get("context")
    reason = n.get("reason") or context
    sysmsg = n.get("systemMessage")

    out: dict = {}
    tool, event = args.tool, args.event

    if tool == "claude":
        hso = {"hookEventName": "PreToolUse" if event == "pretool" else "SessionStart"}
        if decision == "deny":
            hso["permissionDecision"] = "block"
            hso["permissionDecisionReason"] = reason
        elif context:
            hso["additionalContext"] = context
        if len(hso) > 1:
            out["hookSpecificOutput"] = hso
        if sysmsg:
            out["systemMessage"] = sysmsg

    elif tool == "gemini":
        if decision == "deny":
            out["decision"] = "deny"
            out["reason"] = reason
        elif context:
            out["hookSpecificOutput"] = {"additionalContext": context}
        if sysmsg:
            out["systemMessage"] = sysmsg

    elif tool == "copilot":
        if event == "pretool":
            if decision == "deny":
                out["permissionDecision"] = "deny"
                out["permissionDecisionReason"] = reason
            # context-only on preToolUse cannot be injected -> allow silently
        else:  # session
            if context:
                out["additionalContext"] = context

    elif tool == "antigravity":  # UNVERIFIED — see module header
        if decision == "deny":
            out["permissionDecision"] = "deny"
            out["permissionDecisionReason"] = reason
        elif context:
            out["hookSpecificOutput"] = {"additionalContext": context}
        if sysmsg:
            out["systemMessage"] = sysmsg

    if out:
        print(json.dumps(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
