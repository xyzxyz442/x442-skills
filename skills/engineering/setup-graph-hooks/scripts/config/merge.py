#!/usr/bin/env python3
# merge.py — merge a rendered hook config (read from stdin) into a tool's native settings
# file, adding only the hook groups THIS skill owns and preserving everything else the file
# already had. Round-trips JSON; never sed-splices.
#
#   render.py --tool gemini --primary claude | merge.py --file .gemini/settings.json
#
# "Owns" is the whole contract. The settings file belongs to the user, and on Gemini it is the
# same file setup-handoff wires its enforcement hooks into. So a hook group is ours only if it
# invokes our own dispatcher (see is_managed); everything else is carried through untouched.
# Ours is refreshed in the slot it already holds, so a re-run, or a --primary change, converges
# instead of duplicating, reordering, or leaving a stale second refresh owner behind.
#
# Self-test:  python3 merge.py --selftest
import argparse
import json
import os
import subprocess
import sys


# Recognizing OUR hook group must be specific enough that we never delete an UNRELATED one. Two
# shapes exist because the tools differ: claude/gemini/antigravity take a command STRING (which
# always resolves and runs `.graph-hooks/hook.sh --kind <kind>`), copilot takes a script PATH
# into our per-kind wrapper directory. Requiring the `--kind ` flag alongside the dispatcher path
# is the guard that keeps another tool's `hooks.sh` — setup-handoff's, notably — out of scope.
DISPATCHER = ".graph-hooks/hook.sh"
KIND_FLAG = "--kind "
WRAPPER_DIR = ".graph-hooks/copilot/"


def is_managed(entry) -> bool:
    """True iff `entry` is one of OUR hook entries or a group containing one."""
    if not isinstance(entry, dict):
        return False
    cmd = entry.get("command")
    if isinstance(cmd, str) and DISPATCHER in cmd and KIND_FLAG in cmd:
        return True
    script = entry.get("bash")
    if isinstance(script, str) and WRAPPER_DIR in script:
        return True
    return any(is_managed(h) for h in entry.get("hooks") or [])


def replace_managed(entries, ours: list) -> list:
    """Swap our current groups into the slots our old ones occupy; leave every other entry put.

    Stripping ours and re-appending would be simpler and is what setup-handoff's merge did, but
    the two installers share .gemini/settings.json: each re-append walks its own groups past the
    other's, so alternating installs churn the file forever with no change of meaning. Holding
    the slot makes an install a fixed point no matter who else writes the file.
    """
    out, queue = [], list(ours)
    for e in entries or []:
        if not is_managed(e):
            out.append(e)
        elif queue:
            out.append(queue.pop(0))  # our old group's slot, our new group's content
    out.extend(queue)  # more than last time (a --primary handover) -> the rest go at the end
    return out


def merge_hooks(existing: dict, rendered: dict) -> dict:
    """Our groups, freshly written, into whatever else the file already has under "hooks"."""
    out: dict = {}
    for ev, entries in existing.items():
        if not isinstance(entries, list):
            out[ev] = entries  # a scalar under an event name is not ours to interpret
            continue
        ours = rendered.get(ev) if isinstance(rendered.get(ev), list) else []
        merged = replace_managed(entries, ours)
        # An event that is empty ONLY because we just removed our group is an event we no longer
        # wire (a --primary handover); drop the key rather than leave a dangling [].
        if merged or ev in rendered:
            out[ev] = merged
    for ev, entries in rendered.items():
        if not isinstance(entries, list):
            out[ev] = entries
        elif not isinstance(out.get(ev), list):
            out[ev] = list(entries)  # an event this file did not have yet
    return out


HERE = os.path.dirname(os.path.abspath(__file__))


def _render(tool: str, primary: str) -> str:
    r = subprocess.run([sys.executable, os.path.join(HERE, "render.py"),
                        "--tool", tool, "--primary", primary],
                       capture_output=True, text=True)
    assert r.returncode == 0, f"render {tool}: {r.stderr}"
    return r.stdout


def _merge_into(path: str, tool: str, primary: str) -> dict:
    """Run this script exactly as the installer does, and hand back the resulting file."""
    r = subprocess.run([sys.executable, __file__, "--file", path],
                       input=_render(tool, primary), capture_output=True, text=True)
    assert r.returncode == 0, f"merge {tool}: {r.stderr}"
    with open(path) as f:
        return json.load(f)


def _write(path: str, data: dict) -> None:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def _commands(node) -> list:
    """Every command string and script path anywhere under a hooks object."""
    if isinstance(node, dict):
        out = []
        for k, v in node.items():
            if k in ("command", "bash") and isinstance(v, str):
                out.append(v)
            else:
                out.extend(_commands(v))
        return out
    if isinstance(node, list):
        return [c for item in node for c in _commands(item)]
    return []


def _selftest() -> int:
    """python3 merge.py --selftest

    This merge decides what an installer is allowed to DELETE from a settings file that the user
    and at least one other skill also write. It used to replace the whole "hooks" subtree while
    both its call sites claimed the opposite, so a successful install silently deleted a user's
    own hooks and — on Gemini, where setup-handoff writes the same .gemini/settings.json — every
    handoff enforcement hook. See hook-config-merge-clobber-handoff.

    The assertion that names that bug is the first one here: a hook group we did not write
    survives the merge. Its sibling, setup-handoff/scripts/merge-hooks.py, asserts the same
    thing about its own predicate; this file had no assertions at all.
    """
    import tempfile

    user_guard = {"matcher": "Bash",
                  "hooks": [{"type": "command", "command": "bash .claude/my-guard.sh"}]}
    user_end = {"hooks": [{"type": "command", "command": "bash .claude/on-session-end.sh"}]}

    with tempfile.TemporaryDirectory() as tmp:
        # --- 1. A user's own hooks, in an event we wire and one we do not ------------------
        f = os.path.join(tmp, "settings.local.json")
        _write(f, {"permissions": {"allow": ["Bash(git status)"]},
                   "hooks": {"PreToolUse": [user_guard], "SessionEnd": [user_end]}})
        after = _merge_into(f, "claude", "claude")

        assert after["permissions"] == {"allow": ["Bash(git status)"]}, "sibling top-level key"
        assert user_guard in after["hooks"]["PreToolUse"], \
            "a user's own group in an event we ALSO wire must survive"
        assert after["hooks"]["SessionEnd"] == [user_end], \
            "an event we do not wire at all must survive whole"
        assert "sessionstart" in json.dumps(after["hooks"]["SessionStart"]), "ours landed"
        assert after["hooks"].get("Stop"), "the primary owns the end-of-turn refresh"

        # --- 2. Re-running the installer changes nothing -----------------------------------
        before_bytes = open(f).read()
        _merge_into(f, "claude", "claude")
        assert open(f).read() == before_bytes, "a re-run must leave the file byte-identical"

        # --- 2b. ...even when another installer has since written the same file ------------
        # setup-handoff wires .gemini/settings.json too, and its own merge appends its groups at
        # the end of each shared event. If we then re-append ours, the two installers walk their
        # groups past each other forever and every install dirties the tree. Our groups stay
        # where they are; only their content is refreshed.
        data = json.load(open(f))
        data["hooks"]["PreToolUse"].append(data["hooks"]["PreToolUse"].pop(0))
        data["hooks"]["SessionStart"].insert(0, user_guard)
        _write(f, data)
        reordered = open(f).read()
        _merge_into(f, "claude", "claude")
        assert open(f).read() == reordered, \
            "a re-run must not reorder groups another installer placed around ours"

        # --- 3. Dropping --primary drops OUR endturn group, not the event's other tenants ---
        data = json.load(open(f))
        data["hooks"]["Stop"].append(user_guard)
        _write(f, data)
        after = _merge_into(f, "claude", "none")
        assert user_guard in after["hooks"]["Stop"], "a foreign group in Stop is not ours to drop"
        assert "endturn" not in json.dumps(after["hooks"]), \
            "our stale refresh group must go when we stop being primary"

        # --- 4. The reachable cross-skill case: setup-handoff's hooks, same Gemini file -----
        g = os.path.join(tmp, "gemini.json")
        handoff = [
            ("SessionStart", "sessionstart", None),
            ("AfterTool", "posttool-edit", "Edit|Write|MultiEdit"),
            ("BeforeTool", "pretool-edit", "Edit|Write|MultiEdit"),
            ("AfterAgent", "stop", None),
        ]
        hooks = {}
        for ev, kind, matcher in handoff:
            grp = {"hooks": [{"type": "command", "command":
                              f"bash .agents/handoff/scripts/hooks.sh --kind {kind} --tool gemini"}]}
            if matcher:
                grp["matcher"] = matcher
            hooks.setdefault(ev, []).append(grp)
        _write(g, {"hooks": hooks})
        after = _merge_into(g, "gemini", "gemini")
        kept = [c for c in _commands(after["hooks"]) if "handoff/scripts/hooks.sh" in c]
        assert len(kept) == 4, f"all four handoff hooks must survive, kept {len(kept)}"
        assert "pretool-shell" in json.dumps(after["hooks"]), "and ours landed alongside them"

        # --- 5. Copilot's flat schema: hook entries are not wrapped in groups ---------------
        c = os.path.join(tmp, "graph.json")
        theirs = {"type": "command", "bash": ".github/hooks/mine.sh", "timeoutSec": 5}
        _write(c, {"version": 1, "hooks": {"preToolUse": [theirs], "postToolUse": [theirs]}})
        after = _merge_into(c, "copilot", "copilot")
        assert theirs in after["hooks"]["preToolUse"], "a flat foreign entry must survive"
        assert after["hooks"]["postToolUse"] == [theirs], "an event we do not wire survives whole"
        assert any(".graph-hooks/copilot/" in x for x in _commands(after["hooks"])), "ours landed"

        # --- 6. A non-list value under "hooks" is carried, not crashed on -------------------
        a = os.path.join(tmp, "hooks.json.example")
        _write(a, {"hooks": {"PreToolUse": [user_guard]}})
        after = _merge_into(a, "antigravity", "none")
        assert after["hooks"]["_UNVERIFIED"], "the renderer's own scalar survives the merge"
        assert user_guard in after["hooks"]["PreToolUse"], "and so does theirs"

        # --- 7. An unparseable target is refused, never overwritten -------------------------
        bad = os.path.join(tmp, "broken.json")
        open(bad, "w").write("{not json")
        r = subprocess.run([sys.executable, __file__, "--file", bad],
                           input=_render("claude", "claude"), capture_output=True, text=True)
        assert r.returncode == 2 and open(bad).read() == "{not json", "hand-broken JSON is left alone"

    # --- 8. The predicate itself: ours is always ours, nobody else's ever is ----------------
    for mine in (json.loads(_render(t, t))["hooks"] for t in ("claude", "gemini", "copilot")):
        for groups in mine.values():
            if isinstance(groups, list) and groups:
                assert all(is_managed(g) for g in groups), f"must recognize what we just wrote: {groups!r}"

    for foreign in (
        {"hooks": [{"type": "command",
                    "command": "bash .agents/handoff/scripts/hooks.sh --kind stop --tool claude"}]},
        {"hooks": [{"type": "command", "command": "bash .agents/bin/consent-gate.sh --tool claude"}]},
        {"hooks": [{"type": "command", "command": "bash .claude/my-guard.sh"}]},
        {"type": "command", "bash": ".github/hooks/mine.sh"},
        {"hooks": []},
        {},
        "not-a-dict",
    ):
        assert not is_managed(foreign), f"must NOT claim another tool's hook: {foreign!r}"

    # An event we no longer wire renders nothing for it, which is how a --primary handover
    # removes our stale group — and the one case where this must delete rather than replace.
    ours = json.loads(_render("claude", "claude"))["hooks"]["SessionStart"][0]
    theirs = {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash x.sh"}]}
    assert replace_managed([theirs, ours], []) == [theirs], "drops ours, keeps theirs, in order"
    assert replace_managed([theirs, ours], [ours]) == [theirs, ours], "ours keeps its slot"
    assert replace_managed([ours, theirs], [ours]) == [ours, theirs], "and so does theirs"
    assert replace_managed([theirs], [ours]) == [theirs, ours], "a first install appends"
    assert replace_managed([], []) == [] and replace_managed(None, []) == [], \
        "empty input is not an error"
    assert replace_managed(["junk", {"no": "hooks"}], []) == ["junk", {"no": "hooks"}], \
        "malformed entries are skipped, never crashed on — humans hand-edit these files"

    print("merge (graph-hooks config) selftest OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    args = ap.parse_args()

    try:
        rendered = json.load(sys.stdin)
    except Exception as e:  # noqa: BLE001
        print(f"merge: invalid rendered JSON: {e}", file=sys.stderr)
        return 1
    if not isinstance(rendered, dict):
        print("merge: rendered config is not an object", file=sys.stderr)
        return 1

    target: dict = {}
    if os.path.exists(args.file):
        try:
            with open(args.file) as f:
                loaded = json.load(f)
            target = loaded if isinstance(loaded, dict) else {}
        except Exception:  # noqa: BLE001
            print(f"merge: existing {args.file} is not valid JSON — left untouched", file=sys.stderr)
            return 2

    for k, v in rendered.items():
        if k == "hooks" and isinstance(v, dict) and isinstance(target.get("hooks"), dict):
            target["hooks"] = merge_hooks(target["hooks"], v)
        else:
            target[k] = v

    os.makedirs(os.path.dirname(args.file) or ".", exist_ok=True)
    text = json.dumps(target, indent=2) + "\n"
    # Write only on a real change. The installer re-runs on every repair, and rewriting a file
    # whose content is unchanged dirties the working tree with a diff carrying no meaning —
    # which buries the wiring change that does. Same reason as setup-handoff's merge-hooks.py.
    try:
        with open(args.file) as f:
            unchanged = json.load(f) == target
    except (OSError, ValueError):
        unchanged = False
    if not unchanged:
        with open(args.file, "w") as f:
            f.write(text)
    print(args.file)
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    raise SystemExit(main())
