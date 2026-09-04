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
#
# Self-test:  python3 emit.py --selftest
import argparse
import json
import sys


def translate(n, tool: str, event: str) -> dict:
    """One neutral decision -> one tool's hook JSON. {} means "say nothing" (pass / no-op).

    Pure: no stdin, no stdout, no argparse. That is what makes the per-tool contract table
    assertable -- see _selftest.
    """
    if not isinstance(n, dict):
        return {}

    decision = n.get("decision")
    context = n.get("context")
    reason = n.get("reason") or context
    sysmsg = n.get("systemMessage")

    out: dict = {}

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

    return out


def _selftest() -> int:
    """python3 emit.py --selftest

    The missing assertion class: NOTHING asserted the per-tool OUTPUT contract table. Each branch
    below is a claim about a vendor's hook protocol, and getting one wrong fails SILENTLY in the
    worst direction -- a deny rendered under the wrong key is not rejected by the tool, it is
    ignored, so the hook reports success and blocks nothing. verify-graph-hooks.sh checks only that
    the dispatcher emits VALID JSON, which a wrong-shaped deny also is.

    Mirrors extract.py's _selftest, which asserts the INPUT half of the same table.
    """
    deny = {"decision": "deny", "reason": "use the graph"}
    ctx = {"context": "graph says X"}

    # Claude: deny and context both ride inside hookSpecificOutput, and the event name differs
    # per event. permissionDecision is "block" -- NOT "deny", which is Copilot's spelling.
    got = translate(deny, "claude", "pretool")
    assert got == {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "block",
            "permissionDecisionReason": "use the graph",
        }
    }, got
    assert translate(ctx, "claude", "session") == {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "graph says X",
        }
    }
    # hookEventName alone is not worth emitting: a bare envelope with no decision and no context
    # is noise on every single tool call. len(hso) > 1 is what suppresses it.
    assert translate({}, "claude", "pretool") == {}

    # Gemini: deny is TOP-LEVEL, unlike Claude. Context still rides in hookSpecificOutput.
    assert translate(deny, "gemini", "pretool") == {
        "decision": "deny",
        "reason": "use the graph",
    }
    assert translate(ctx, "gemini", "pretool") == {
        "hookSpecificOutput": {"additionalContext": "graph says X"}
    }

    # Copilot: top-level, and "deny" not "block". THE asymmetry worth asserting -- preToolUse
    # cannot inject context, so a context-only decision must produce NOTHING rather than a
    # plausible-looking object the tool discards.
    assert translate(deny, "copilot", "pretool") == {
        "permissionDecision": "deny",
        "permissionDecisionReason": "use the graph",
    }
    assert (
        translate(ctx, "copilot", "pretool") == {}
    ), "no context injection on preToolUse"
    assert translate(ctx, "copilot", "session") == {"additionalContext": "graph says X"}
    # ...and on sessionStart, additionalContext is TOP-LEVEL, not nested like Claude's.
    assert "hookSpecificOutput" not in translate(ctx, "copilot", "session")

    # reason falls back to context, so a core that only sets context still denies with a message
    # rather than with a null reason.
    assert (
        translate({"decision": "deny", "context": "c"}, "claude", "pretool")[
            "hookSpecificOutput"
        ]["permissionDecisionReason"]
        == "c"
    )

    # deny WINS over context everywhere: a decision carrying both must not degrade to advice.
    for tool in ("claude", "gemini", "copilot", "antigravity"):
        both = translate(
            {"decision": "deny", "reason": "r", "context": "c"}, tool, "pretool"
        )
        assert "additionalContext" not in json.dumps(both), tool

    # systemMessage rides alongside on the tools that support it, and is NOT invented for
    # copilot, whose contract has no such field.
    assert translate({"systemMessage": "hi"}, "claude", "session") == {
        "systemMessage": "hi"
    }
    assert translate({"systemMessage": "hi"}, "copilot", "session") == {}

    # An unknown tool emits nothing rather than guessing a shape.
    assert translate(deny, "nonesuch", "pretool") == {}

    # Shape tolerance: {} for anything that is not a decision object, never an exception. A
    # raising hook is a broken tool call, which is worse than an unsteered one.
    for bad in (None, [], "", 3, "deny"):
        assert translate(bad, "claude", "pretool") == {}, repr(bad)

    print("emit.py selftest: OK")
    return 0


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

    out = translate(n, args.tool, args.event)
    if out:
        print(json.dumps(out))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    raise SystemExit(main())
