#!/usr/bin/env python3
"""merge-settings.py — put the secret guard's hook and deny rules into a tool settings file.

    merge-settings.py --file <settings.json> --rules <deny-rules.json> --guard <path> \\
                      [--inventory <path>] [--dry-run]
    merge-settings.py --selftest

JSON carries no comments, so a managed block cannot be marked in the file the way it is in
AGENTS.md. Instead the installer keeps an **inventory** beside the settings — the exact rules
it added last time — and on each run removes only what it previously owned and no longer ships.
Anything absent from the inventory was put there by a person and is never touched.

That asymmetry is the whole design: adding a deny rule is safe, removing one is not. A rule
this tool did not add is a rule it must not remove, and a duplicate it did not create is
reported rather than deleted, because a deny rule removed on a guess is a silent hole.

The hook entry is matched by the script it runs, not by position, so re-running relocates
nothing and a user's own Bash hooks in the same matcher survive.
"""

import argparse
import json
import os
import sys

HOOK_MATCHER = "Bash|Grep"
HOOK_MARK = "secret-file-guard.py"


def _load(path, default):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read().strip()
    except OSError:
        return default
    if not text:
        return default
    return json.loads(text)


def merge_hook(settings, guard_path):
    """Install (or refresh) the PreToolUse entry, leaving sibling hooks alone."""
    hooks = settings.setdefault("hooks", {})
    pre = hooks.setdefault("PreToolUse", [])
    command = 'python3 "%s"' % guard_path
    entry = {
        "type": "command",
        "command": command,
        "timeout": 5,
        "statusMessage": "Checking for credential exposure...",
    }
    for group in pre:
        if not isinstance(group, dict):
            continue
        inner = group.get("hooks") or []
        for i, h in enumerate(inner):
            if isinstance(h, dict) and HOOK_MARK in str(h.get("command", "")):
                if inner[i] == entry and group.get("matcher") == HOOK_MATCHER:
                    return False
                inner[i] = entry
                group["matcher"] = HOOK_MATCHER
                return True
    pre.append({"matcher": HOOK_MATCHER, "hooks": [entry]})
    return True


def merge_deny(settings, rules, previous):
    """Union our rules into permissions.deny; drop only rules we added and no longer ship.

    Returns (changed, duplicates) where duplicates are entries appearing more than once that
    we do not own -- reported, never removed.
    """
    perms = settings.setdefault("permissions", {})
    deny = perms.setdefault("deny", [])
    ours = ["Read(%s)" % p for p in rules.get("read", [])]
    ours += ["Edit(%s)" % p for p in rules.get("edit", [])]

    before = list(deny)
    stale = [r for r in previous if r not in ours]
    deny[:] = [r for r in deny if r not in stale]
    for rule in ours:
        if rule not in deny:
            deny.append(rule)

    seen, dupes = set(), []
    for r in deny:
        if r in seen and r not in ours:
            dupes.append(r)
        seen.add(r)
    deny[:] = list(dict.fromkeys(deny))
    return deny != before, sorted(set(dupes))


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--file", required=True)
    ap.add_argument("--rules", required=True)
    ap.add_argument("--guard", required=True)
    ap.add_argument("--inventory")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    settings = _load(args.file, {})
    if not isinstance(settings, dict):
        print("merge-settings: %s is not a JSON object" % args.file, file=sys.stderr)
        return 1
    rules = _load(args.rules, {})
    inventory_path = args.inventory or (
        os.path.join(
            os.path.dirname(os.path.abspath(args.file)), ".secret-guard-rules.json"
        )
    )
    previous = _load(inventory_path, [])
    if not isinstance(previous, list):
        previous = []

    hook_changed = merge_hook(settings, args.guard)
    deny_changed, dupes = merge_deny(settings, rules, previous)

    for d in dupes:
        print("  ! duplicate deny rule not managed here, left in place: %s" % d)

    if not (hook_changed or deny_changed):
        print("  = settings up to date")
        return 0
    if args.dry_run:
        print("  ~ would update %s" % args.file)
        return 0

    owned = ["Read(%s)" % p for p in rules.get("read", [])]
    owned += ["Edit(%s)" % p for p in rules.get("edit", [])]
    os.makedirs(os.path.dirname(os.path.abspath(args.file)) or ".", exist_ok=True)
    with open(args.file, "w", encoding="utf-8") as fh:
        json.dump(settings, fh, indent=2)
        fh.write("\n")
    with open(inventory_path, "w", encoding="utf-8") as fh:
        json.dump(owned, fh, indent=2)
        fh.write("\n")
    print("  + %s (hook%s deny rules)" % (args.file, " and" if hook_changed else ","))
    return 0


def _selftest():
    import tempfile

    fails = []

    def check(label, cond):
        print("  %-52s %s" % (label, "ok" if cond else "FAIL"))
        if not cond:
            fails.append(label)

    rules = {"read": ["**/.env"], "edit": ["**/*.pem"]}

    # A user's own settings must survive, including their own Bash hook.
    settings = {
        "permissions": {"deny": ["Read(**/private.txt)"], "allow": ["Bash(ls:*)"]},
        "hooks": {
            "PreToolUse": [
                {
                    "matcher": "Bash",
                    "hooks": [{"type": "command", "command": "echo mine"}],
                }
            ]
        },
        "env": {"KEEP": "1"},
    }
    merge_hook(settings, "/x/secret-file-guard.py")
    changed, dupes = merge_deny(settings, rules, [])
    check(
        "user's unrelated deny rule survives",
        "Read(**/private.txt)" in settings["permissions"]["deny"],
    )
    check(
        "user's allow list survives", settings["permissions"]["allow"] == ["Bash(ls:*)"]
    )
    check("unrelated top-level keys survive", settings.get("env") == {"KEEP": "1"})
    check(
        "user's own PreToolUse hook survives",
        any(
            h.get("command") == "echo mine"
            for g in settings["hooks"]["PreToolUse"]
            for h in g.get("hooks", [])
        ),
    )
    check(
        "our rules were added",
        "Read(**/.env)" in settings["permissions"]["deny"]
        and "Edit(**/*.pem)" in settings["permissions"]["deny"],
    )
    check("deny merge reported a change", changed)
    check("no duplicates reported on a clean merge", dupes == [])

    # Idempotence: a second identical run changes nothing.
    owned = ["Read(**/.env)", "Edit(**/*.pem)"]
    h2 = merge_hook(settings, "/x/secret-file-guard.py")
    d2, _ = merge_deny(settings, rules, owned)
    check("second run is a no-op (hook)", h2 is False)
    check("second run is a no-op (deny)", d2 is False)
    check(
        "hook appears exactly once",
        sum(
            1
            for g in settings["hooks"]["PreToolUse"]
            for h in g.get("hooks", [])
            if HOOK_MARK in str(h.get("command", ""))
        )
        == 1,
    )

    # A rule we used to own and no longer ship is withdrawn; one we never owned is not.
    settings2 = {"permissions": {"deny": ["Read(**/legacy)", "Read(**/theirs)"]}}
    merge_deny(settings2, rules, ["Read(**/legacy)"])
    check(
        "withdraws a rule we previously owned",
        "Read(**/legacy)" not in settings2["permissions"]["deny"],
    )
    check(
        "keeps a rule we never owned",
        "Read(**/theirs)" in settings2["permissions"]["deny"],
    )

    # A duplicate we do not own is reported, and deduplicated without losing the rule.
    settings3 = {"permissions": {"deny": ["Read(//**/.env)", "Read(//**/.env)"]}}
    _, dupes3 = merge_deny(settings3, rules, [])
    check("reports an unmanaged duplicate", dupes3 == ["Read(//**/.env)"])
    check(
        "keeps the unmanaged rule itself",
        "Read(//**/.env)" in settings3["permissions"]["deny"],
    )

    # An absent settings file is created rather than refused.
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, "settings.json")
        r = os.path.join(d, "rules.json")
        with open(r, "w", encoding="utf-8") as fh:
            json.dump(rules, fh)
        rc = main(["--file", f, "--rules", r, "--guard", "/x/secret-file-guard.py"])
        written = _load(f, {})
        check("creates an absent settings file", rc == 0 and os.path.isfile(f))
        check(
            "written file is valid and carries our rule",
            "Read(**/.env)" in written.get("permissions", {}).get("deny", []),
        )
        check(
            "inventory written beside it",
            os.path.isfile(os.path.join(d, ".secret-guard-rules.json")),
        )

    if fails:
        print("merge-settings selftest FAILED (%d)" % len(fails))
        return 1
    print("merge-settings selftest OK")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    sys.exit(main(sys.argv[1:]))
