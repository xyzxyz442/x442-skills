#!/usr/bin/env bash
# tracker-github.sh — the GitHub Issues adapter for a board's external tracker (ADR 0011).
#
# The handoff CLI speaks one contract to every tracker: one operation as $1, a JSON request on
# stdin, a JSON reply on stdout, non-zero exit on failure. This adapter implements it with the `gh`
# CLI, so authentication is whatever `gh auth` already holds — no token is read, passed, or stored
# by the board. Install `gh` and run `gh auth login` once; nothing else is configured here.
#
#   list      {"repo", "label"?}                                 -> [{"number","state","title","body","labels"}]
#   create    {"repo", "title", "body", "labels"}                -> {"number", "url"}
#   update    {"repo", "number", "title", "body", "labels", "state"?}  -> {}
#   close     {"repo", "number", "comment"}                      -> {}
#   comments  {"repo", "number"}                                 -> [{"author", "body", "created_at"}]
#   visibility {"repo"}                                          -> {"visibility": "public"|"private"|"internal"}
#     A failure exits non-zero; the CLI treats that — and anything unrecognised — as public (ADR 0013).
#
# Labels the mirror manages carry a known prefix (handoff-, status:, severity:, env:, section:,
# type:). On update only those are reconciled; a label a person added by hand is left alone.
# Source: https://cli.github.com/manual/gh_issue
set -uo pipefail
op="${1:?usage: tracker-github.sh list|create|update|close|comments|visibility}"
command -v gh > /dev/null 2>&1 || {
  echo "tracker-github: the gh CLI is not installed — https://cli.github.com, then gh auth login" >&2
  exit 2
}
req="$(cat)"

# Request fields as shell-quoted assignments: parsed by python, quoted by shlex, so a title or body
# can never become shell syntax.
eval "$(printf '%s' "$req" | python3 -c 'import json, shlex, sys
r = json.load(sys.stdin)
print("repo=%s" % shlex.quote(str(r.get("repo", ""))))
print("number=%s" % shlex.quote(str(r.get("number", ""))))
print("title=%s" % shlex.quote(str(r.get("title", ""))))
print("label=%s" % shlex.quote(str(r.get("label", ""))))
print("comment=%s" % shlex.quote(str(r.get("comment", ""))))
print("want_state=%s" % shlex.quote(str(r.get("state", ""))))
print("labels=(%s)" % " ".join(shlex.quote(str(l)) for l in r.get("labels", [])))')" || {
  echo "tracker-github: unreadable request" >&2
  exit 2
}
[ -n "$repo" ] || {
  echo "tracker-github: request names no repo" >&2
  exit 2
}

body_file() { # -> path of a temp file holding the request body
  local f
  f="$(mktemp)" || exit 1
  printf '%s' "$req" | python3 -c 'import json, sys; sys.stdout.write(json.load(sys.stdin).get("body", ""))' > "$f"
  printf '%s' "$f"
}

# gh reports success ("✓ Closed issue …") on stderr, which would leak into every mirror run's output.
# Keep stderr only when the command fails, so real errors still reach the operator.
quiet_gh() { # gh-args... -> gh's stdout; its stderr only on failure
  local err rc
  err="$(mktemp)" || return 1
  gh "$@" 2> "$err"
  rc=$?
  [ $rc -eq 0 ] || cat "$err" >&2
  rm -f "$err"
  return $rc
}

ensure_labels() { # labels... -> creates any that do not exist yet (idempotent)
  local l
  for l in "$@"; do
    gh label create "$l" --repo "$repo" --force > /dev/null 2>&1 || true
  done
}

case "$op" in
  list)
    # Never `--label` on the server: GitHub's label-filtered listing lags a create by seconds, and a
    # caller that cannot see an issue it just made will make another. Filter here instead.
    gh issue list --repo "$repo" --state all --limit 1000 \
      --json number,state,title,body,labels \
      | python3 -c 'import json, sys
want = sys.argv[1]
out = [{"number": i["number"], "state": i["state"].lower(), "title": i["title"], "body": i["body"],
        "labels": [l["name"] for l in i.get("labels", [])]} for i in json.load(sys.stdin)]
json.dump([i for i in out if not want or want in i["labels"]], sys.stdout)' "$label"
    ;;
  create)
    bf="$(body_file)"
    ensure_labels "${labels[@]}"
    args=(issue create --repo "$repo" --title "$title" --body-file "$bf")
    for l in "${labels[@]}"; do args+=(--label "$l"); done
    url="$(quiet_gh "${args[@]}")" || {
      rm -f "$bf"
      exit 1
    }
    rm -f "$bf"
    printf '%s' "$url" | python3 -c 'import json, re, sys
u = sys.stdin.read().strip()
m = re.search(r"/issues/([0-9]+)", u)
if not m:
    sys.stderr.write("tracker-github: could not read an issue number from: %s\n" % u)
    sys.exit(1)
json.dump({"number": int(m.group(1)), "url": u}, sys.stdout)'
    ;;
  update)
    bf="$(body_file)"
    ensure_labels "${labels[@]}"
    current="$(gh issue view "$number" --repo "$repo" --json labels | python3 -c 'import json, sys
print("\n".join(l["name"] for l in json.load(sys.stdin).get("labels", [])))')"
    args=(issue edit "$number" --repo "$repo" --title "$title" --body-file "$bf")
    for l in "${labels[@]}"; do args+=(--add-label "$l"); done
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      case "$l" in handoff-* | status:* | severity:* | env:* | section:* | type:*) ;; *) continue ;; esac
      # Here-string, not a pipe: under pipefail `printf | grep -q` fails whenever grep exits first.
      grep -qxF "$l" <<< "$(printf '%s\n' "${labels[@]}")" || args+=(--remove-label "$l")
    done <<< "$current"
    quiet_gh "${args[@]}" > /dev/null || {
      rm -f "$bf"
      exit 1
    }
    rm -f "$bf"
    [ "$want_state" = open ] && { quiet_gh issue reopen "$number" --repo "$repo" > /dev/null || exit 1; }
    printf '{}'
    ;;
  close)
    quiet_gh issue close "$number" --repo "$repo" ${comment:+--comment "$comment"} > /dev/null || exit 1
    printf '{}'
    ;;
  visibility)
    quiet_gh repo view "$repo" --json visibility | python3 -c 'import json, sys
json.dump({"visibility": str(json.load(sys.stdin).get("visibility", "")).lower()}, sys.stdout)' || exit 1
    ;;
  comments)
    gh issue view "$number" --repo "$repo" --json comments | python3 -c 'import json, sys
out = [{"author": (c.get("author") or {}).get("login", ""), "body": c.get("body", ""),
        "created_at": c.get("createdAt", "")} for c in json.load(sys.stdin).get("comments", [])]
json.dump(out, sys.stdout)'
    ;;
  *)
    echo "tracker-github: unknown operation $op" >&2
    exit 2
    ;;
esac
