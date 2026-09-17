#!/usr/bin/env bash
# fake-tracker.sh — an issue-tracker adapter that never touches the network.
#
# Implements the adapter contract the handoff CLI speaks (ADR 0011): one operation as $1, a JSON
# request on stdin, a JSON reply on stdout, non-zero exit on failure. State lives in the JSON file
# named by $FAKE_TRACKER_STATE, so a test can seed issues, add comments, and assert on every call.
#
#   list      {"repo", "label"}                          -> [{"number","state","title","body","labels"}]
#   create    {"repo", "title", "body", "labels"}        -> {"number", "url"}
#   update    {"repo", "number", "title", "body", "labels", "state"}  -> {}
#   close     {"repo", "number", "comment"}              -> {}
#   comments  {"repo", "number"}                         -> [{"author", "body", "created_at"}]
#
# Test hooks: $FAKE_TRACKER_FAIL=<op> makes that operation exit 1. Every call is appended to the
# state's "calls" list as [op, request] so a test can count creates and updates.
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
if op == "list":
    out = [
        {k: i[k] for k in ("number", "state", "title", "body", "labels")}
        for i in db["issues"]
        if i.get("repo") == req.get("repo") and (not req.get("label") or req["label"] in i.get("labels", []))
    ]
elif op == "create":
    n = max([i["number"] for i in db["issues"]] + [0]) + 1
    db["issues"].append({
        "repo": req["repo"], "number": n, "state": "open", "title": req["title"],
        "body": req["body"], "labels": list(req.get("labels", [])), "comments": [],
    })
    out = {"number": n, "url": "https://tracker.invalid/%s/issues/%d" % (req["repo"], n)}
elif op == "update":
    i = issue(req["number"])
    for k in ("title", "body", "labels", "state"):
        if k in req:
            i[k] = req[k]
elif op == "close":
    i = issue(req["number"])
    i["state"] = "closed"
    if req.get("comment"):
        i["comments"].append({"author": "handoff-mirror", "body": req["comment"], "created_at": "2026-01-01T00:00:00Z"})
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
