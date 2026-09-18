#!/usr/bin/env bash
# fake-tracker.sh — an issue-tracker adapter that never touches the network.
#
# Implements the adapter contract the handoff CLI speaks (ADR 0011): one operation as $1, a JSON
# request on stdin, a JSON reply on stdout, non-zero exit on failure. State lives in the JSON file
# named by $FAKE_TRACKER_STATE, so a test can seed issues, add comments, and assert on every call.
#
#   list      {"repo", "label"}                          -> [{"number","state","title","body","labels","children"}]
#   create    {"repo", "title", "body", "labels"}        -> {"number", "url"}
#   update    {"repo", "number", "title", "body", "labels", "managed", "children", "owned"}
#                                                        -> {} or {"linked", "skipped"}
#     No reopen: a closed issue whose handoff is still open is drift, reported and never
#     reconciled (ADR 0014), so nothing ever asks an adapter to change an issue's state.
#   close     {"repo", "number", "comment"}              -> {}
#   comments  {"repo", "number"}                         -> [{"author", "body", "created_at"}]
#   visibility {"repo"}                                  -> {"visibility": $FAKE_TRACKER_VISIBILITY, default "private"}
#
# Sub-issue links (ADR 0014): "children" holds this issue's linked child NUMBERS. Reporting it on
# `list` is what tells the CLI this adapter supports links at all — an adapter that omits it is never
# asked to link. On `update`, "children" is the set the board wants; only links to issues the mirror
# itself made -- the CLI names them in "owned" -- are reconciled, so a child a person attached by
# hand survives every run.
#
# Test hooks: $FAKE_TRACKER_FAIL=<op> makes that operation exit 1. $FAKE_TRACKER_NO_LINKS=1 makes it
# an adapter with no link support. $FAKE_TRACKER_LINK_CAP=<n> caps links per parent, to exercise
# overflow. Every call is appended to the state's "calls" list as [op, request] so a test can count
# creates and updates.
set -uo pipefail
op="${1:?usage: fake-tracker.sh <op>}"
state="${FAKE_TRACKER_STATE:?FAKE_TRACKER_STATE must name a JSON state file}"
[ "${FAKE_TRACKER_FAIL:-}" = "$op" ] && {
  echo "fake-tracker: injected failure on $op" >&2
  exit 1
}
# The request is read here, not inside python: the heredoc below IS python's stdin.
req="$(cat)"
python3 - "$op" "$state" "$req" << 'PY'
import json, os, sys

op, state = sys.argv[1], sys.argv[2]
req = json.loads(sys.argv[3] or "{}")
try:
    with open(state) as fh:
        db = json.load(fh)
except (OSError, ValueError):
    db = {}
db.setdefault("issues", [])
db.setdefault("calls", [])
db["calls"].append([op, req])


def issue(number):
    for i in db["issues"]:
        if i["number"] == number and i.get("repo") == req.get("repo"):
            return i
    sys.stderr.write("fake-tracker: no issue #%s in %s\n" % (number, req.get("repo")))
    sys.exit(1)


out = {}
links = not os.environ.get("FAKE_TRACKER_NO_LINKS")
if op == "list":
    out = []
    for i in db["issues"]:
        if i.get("repo") != req.get("repo"):
            continue
        if req.get("label") and req["label"] not in i.get("labels", []):
            continue
        row = {k: i[k] for k in ("number", "state", "title", "body", "labels")}
        # Absent, not empty, when this adapter does not do links: the CLI distinguishes the two.
        if links:
            row["children"] = sorted(i.get("children", []))
        out.append(row)
elif op == "create":
    n = max([i["number"] for i in db["issues"]] + [0]) + 1
    db["issues"].append({
        "repo": req["repo"], "number": n, "state": "open", "title": req["title"],
        "body": req["body"], "labels": list(req.get("labels", [])), "comments": [], "children": [],
    })
    out = {"number": n, "url": "https://tracker.invalid/%s/issues/%d" % (req["repo"], n)}
elif op == "update":
    i = issue(req["number"])
    for k in ("title", "body"):
        if k in req:
            i[k] = req[k]
    if "labels" in req:
        # Like the real adapter: labels outside the managed prefixes are a person's, and stay.
        managed = tuple(req.get("managed", []))
        kept = [l for l in i.get("labels", []) if not (managed and l.startswith(managed)) and l not in req["labels"]]
        i["labels"] = kept + list(req["labels"])
    if "children" in req and links:
        want = [int(n) for n in req["children"]]

        # A link the mirror did not make is not the mirror's to remove (ADR 0014, Decision 4). The
        # CLI says which issues are its own in "owned" -- the adapter never re-derives it.
        owned = set(req.get("owned") or [])
        theirs = [n for n in i.get("children", []) if n not in owned]
        cap = os.environ.get("FAKE_TRACKER_LINK_CAP")
        skipped = 0
        if cap:
            room = max(int(cap) - len(theirs), 0)
            skipped = max(len(want) - room, 0)
            want = want[:room]
        i["children"] = sorted(set(theirs) | set(want))
        out = {"linked": len(want), "skipped": skipped}
elif op == "close":
    i = issue(req["number"])
    i["state"] = "closed"
    if req.get("comment"):
        i["comments"].append({"author": "handoff-mirror", "body": req["comment"], "created_at": "2026-01-01T00:00:00Z"})
elif op == "visibility":
    out = {"visibility": os.environ.get("FAKE_TRACKER_VISIBILITY", "private")}
elif op == "comments":
    out = issue(req["number"]).get("comments", [])
else:
    sys.stderr.write("fake-tracker: unknown op %s\n" % op)
    sys.exit(2)

with open(state + ".tmp", "w") as fh:
    json.dump(db, fh, indent=2)
os.replace(state + ".tmp", state)
json.dump(out, sys.stdout)
PY
