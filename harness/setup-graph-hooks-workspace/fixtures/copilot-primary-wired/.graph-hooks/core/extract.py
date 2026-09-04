#!/usr/bin/env python3
# extract.py — pull a field out of ANY tool's hook stdin payload, protocol-aware.
#
#   extract.py --tool <name> --field <command|readtarget>
#
# Half of the per-tool protocol table (the other half is emit.py). Reads the tool's
# hook JSON on stdin and prints the requested field as plain text — which the behavior
# cores consume without knowing which tool produced it.
#
# The container of tool arguments differs by tool:
#   Claude / Gemini / Antigravity -> "tool_input"   (snake_case)
#   GitHub Copilot                -> "toolArgs"      (camelCase)
# Extraction is shape-tolerant (it tries both, then top level), so a contract drift in
# one tool degrades to "no match" rather than a crash. --tool is accepted for clarity
# and future per-tool divergence.
#
# Self-test:  python3 extract.py --selftest
import argparse
import json
import sys


def args_container(payload):
    """The dict holding a tool's arguments, or None when the payload has no usable shape.

    The fallback ORDER is the contract: `tool_input` before `toolArgs` before the payload
    itself. A Copilot payload carries only `toolArgs`, so reversing these two would read a
    Claude payload's arguments out of the wrong key and silently extract nothing.
    """
    if not isinstance(payload, dict):
        return None
    for key in ("tool_input", "toolArgs"):
        v = payload.get(key)
        if v is not None:
            return v if isinstance(v, dict) else None
    return payload


def extract(payload, field: str) -> str:
    """The requested field as plain text; "" when the payload does not carry it.

    Never raises. A behavior core reads this as "no match" and waves the call through, so a
    contract drift in one tool degrades instead of breaking the tool it hooks.
    """
    ti = args_container(payload)
    if ti is None:
        return ""
    if field == "command":
        return ti.get("command", "") or ""
    if field == "readtarget":
        parts = [
            str(ti.get("file_path") or ""),
            str(ti.get("pattern") or ""),
            str(ti.get("path") or ""),
        ]
        return " ".join(p for p in parts if p)
    return ""


def _selftest() -> int:
    """python3 extract.py --selftest

    The missing assertion class: NOTHING asserted the per-tool container table. This module and
    emit.py are the two halves of it, and every entry is a claim about a vendor's hook contract --
    Claude/Gemini/Antigravity send snake_case `tool_input`, Copilot sends camelCase `toolArgs`.
    Read the wrong key and extraction returns "", which a behavior core cannot distinguish from
    "the user did not grep for anything": the hook waves the call through and looks healthy while
    steering nothing. That is invisible to every integration test in the harness, because a hook
    that no-ops and a hook that correctly found no match produce identical output.

    Mirrors emit.py's _selftest, which asserts the OUTPUT half of the same table. A change to the
    container order here must be mirrored there.
    """
    # The container table, per tool.
    claude = {"tool_input": {"command": "grep -rn foo src/"}}
    copilot = {"toolArgs": {"command": "grep -rn foo src/"}}
    bare = {"command": "grep -rn foo src/"}
    for name, payload in (("claude", claude), ("copilot", copilot), ("bare", bare)):
        assert extract(payload, "command") == "grep -rn foo src/", name

    # Order matters: when BOTH containers are present, tool_input wins. A payload carrying both
    # is what a vendor sending a renamed key during a migration looks like.
    both = {"tool_input": {"command": "right"}, "toolArgs": {"command": "wrong"}}
    assert extract(both, "command") == "right"

    # An explicitly present but non-dict container is NOT a reason to fall through to the top
    # level -- that would read a sibling key as a tool argument.
    assert extract({"tool_input": "oops", "command": "leak"}, "command") == ""

    # readtarget joins the three shapes a read/search target arrives in, in a stable order,
    # skipping the empty ones. The order is what the cores' substring matching sees.
    assert extract({"tool_input": {"file_path": "a.ts"}}, "readtarget") == "a.ts"
    assert (
        extract({"tool_input": {"pattern": "Foo", "path": "src/"}}, "readtarget")
        == "Foo src/"
    )
    assert (
        extract(
            {"tool_input": {"file_path": "a.ts", "pattern": "Foo", "path": "src/"}},
            "readtarget",
        )
        == "a.ts Foo src/"
    )
    assert extract({"tool_input": {}}, "readtarget") == ""

    # Shape tolerance: degrade to "", never raise. Each of these is a real payload a tool has
    # sent at some point (null argument object, list body, missing key, wrong type).
    for payload in (None, [], "", 3, {}, {"tool_input": None}, {"tool_input": []}):
        assert extract(payload, "command") == "", repr(payload)
        assert extract(payload, "readtarget") == "", repr(payload)
    # A non-string command is stringified by the caller, not here; assert we return it as-is
    # rather than crashing on .strip() somewhere downstream.
    assert extract({"tool_input": {"command": 0}}, "command") == ""

    # An unknown field is "" too, not a KeyError -- --field is choices-constrained at the CLI,
    # but the cores import this module directly.
    assert extract(claude, "nonesuch") == ""

    print("extract.py selftest: OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tool", default="")
    ap.add_argument("--field", required=True, choices=["command", "readtarget"])
    args = ap.parse_args()

    try:
        payload = json.loads(sys.stdin.read())
    except Exception:
        return 0
    print(extract(payload, args.field))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    raise SystemExit(main())
