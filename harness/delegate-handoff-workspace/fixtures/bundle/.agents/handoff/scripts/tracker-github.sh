#!/usr/bin/env bash
# tracker-github.sh — the GitHub Issues adapter for a board's external tracker (ADR 0011).
#
# The handoff CLI speaks one contract to every tracker: one operation as $1, a JSON request on
# stdin, a JSON reply on stdout, non-zero exit on failure. This adapter implements it with the `gh`
# CLI, so authentication is whatever `gh auth` already holds — no token is read, passed, or stored
# by the board. Install `gh` and run `gh auth login` once; nothing else is configured here.
#
#   list      {"repo", "label"?}                    -> [{"number","state","title","body","labels","children"}]
#   create    {"repo", "title", "body", "labels", "assignees"?}  -> {"number", "url"}
#     "assignees" is the reviewer pointer projected outward. It is applied AFTER the issue exists,
#     as a separate non-fatal step -- see the create arm for why.
#   update    {"repo", "number", "title"?, "body"?, "labels"?, "managed", "children"?, "owned"?}
#                                                                -> {} or {"linked", "skipped"}
#     There is no reopen: an issue closed in the tracker while its handoff is still open is drift,
#     which the mirror reports and never reconciles (ADR 0014).
#   close     {"repo", "number", "comment"}                      -> {}
#   comments  {"repo", "number"}                                 -> [{"author", "body", "created_at"}]
#   visibility {"repo"}                                          -> {"visibility": "public"|"private"|"internal"}
#     A failure exits non-zero; the CLI treats that — and anything unrecognised — as public (ADR 0013).
#   whoami    {}                                                  -> {"login": "<active gh account>"}
#     ADR 0018's host-account guard: which account `gh` is actually logged into right now, asked
#     before mirror or export --to-issue send anything to a board that records a hostAccount. Reads
#     `gh api user --jq .login` — see https://cli.github.com/manual/gh_api. A failure exits non-zero;
#     the CLI treats that as "cannot confirm" and refuses, the same as a mismatch (ADR 0018 — writing
#     under an unconfirmed identity is the harm the guard exists to prevent).
#
# An update request names the label prefixes the mirror manages in "managed". Only labels carrying
# one of them are reconciled; a label a person added by hand is left alone.
#
# Sub-issue links (ADR 0014). "children" on an update is the set of child issue NUMBERS the board
# wants linked to this parent, and "owned" is every issue the mirror itself made, so only the
# mirror's own links are ever removed and a sub-issue someone attached by hand survives. An update
# carrying links has no "title"/"body"/"labels" at all, so it must not touch the issue text.
#
# Two identifier spaces meet here, and this is the only place that knows it: the PARENT is addressed
# by issue number in the path, while the CHILD is named by "sub_issue_id" -- its internal database
# id. `gh issue view --json id` returns the base64 GraphQL node id, which the REST endpoint rejects,
# so the id is read from the REST resource instead. `-F` (not `-f`) sends it as a JSON number.
#
# replace_parent is NEVER sent. A child has at most one parent, so sending it would silently steal a
# child someone had deliberately parented elsewhere; a refusal is reported and the run continues.
#
# Sources:
#   https://cli.github.com/manual/gh_issue
#   https://docs.github.com/en/rest/issues/sub-issues?apiVersion=2022-11-28 — sub_issue_id is the
#     child's database id; up to 100 sub-issues per parent, eight levels of nesting
#   https://cli.github.com/manual/gh_repo_view — `--json visibility` reports PUBLIC, PRIVATE or INTERNAL
#   https://docs.github.com/en/repositories/creating-and-managing-repositories/about-repositories#about-repository-visibility
#     — internal repositories are visible only to members of the owning enterprise
set -uo pipefail
op="${1:?usage: tracker-github.sh list|create|update|close|comments|visibility|whoami}"
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
print("labels=(%s)" % " ".join(shlex.quote(str(l)) for l in r.get("labels", [])))
print("managed=(%s)" % " ".join(shlex.quote(str(l)) for l in r.get("managed", [])))
print("children=(%s)" % " ".join(str(int(n)) for n in r.get("children", [])))
print("owned=(%s)" % " ".join(str(int(n)) for n in r.get("owned", [])))
print("assignees=(%s)" % " ".join(shlex.quote(str(a)) for a in r.get("assignees", [])))
# Presence, not emptiness: a link-only update omits the text fields entirely and must leave them be,
# while an empty "children" legitimately means "remove every link this mirror made".
for k in ("title", "body", "labels", "children"):
    print("has_%s=%d" % (k, 1 if k in r else 0))')" || {
  echo "tracker-github: unreadable request" >&2
  exit 2
}
# whoami names no repo at all — it asks about the logged-in account, not any repository.
if [ "$op" != whoami ]; then
  [ -n "$repo" ] || {
    echo "tracker-github: request names no repo" >&2
    exit 2
  }
fi

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

is_managed() { # label -> 0 when it carries a prefix the request names as managed
  local p
  for p in ${managed[@]+"${managed[@]}"}; do
    case "$1" in "$p"*) return 0 ;; esac
  done
  return 1
}

ensure_labels() { # labels... -> creates any that do not exist yet (idempotent)
  local l
  for l in "$@"; do
    gh label create "$l" --repo "$repo" --force > /dev/null 2>&1 || true
  done
}

CAP=100 # GitHub's documented maximum sub-issues per parent issue

child_db_id() { # issue-number -> that issue's REST database id
  # NOT `gh issue view --json id`: that is the base64 GraphQL node id and the sub-issues endpoint
  # rejects it. The REST resource carries the integer this API actually wants.
  gh api "/repos/$repo/issues/$1" --jq .id 2> /dev/null
}

reconcile_links() { # -> {"linked", "skipped"} on stdout
  local cur want_list keep add del id rc linked=0 skipped=0 n
  cur="$(gh issue view "$number" --repo "$repo" --json subIssues \
    --jq '.subIssues.nodes[].number' 2> /dev/null)" || cur=""
  # Links this mirror did not make are not its to remove, so they are kept and they count against
  # the cap before anything of ours is added.
  keep=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    grep -qxF "$n" <<< "$(printf '%s\n' ${owned[@]+"${owned[@]}"})" || keep="$keep$n"$'\n'
  done <<< "$cur"
  local room
  room=$((CAP - $(printf '%s' "$keep" | grep -c . || true)))
  [ "$room" -lt 0 ] && room=0
  want_list=""
  for n in ${children[@]+"${children[@]}"}; do
    if [ "$linked" -ge "$room" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    want_list="$want_list$n"$'\n'
    linked=$((linked + 1))
  done
  # Add what is wanted and absent; remove only our own links that are no longer wanted.
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    grep -qxF "$n" <<< "$cur" && continue
    id="$(child_db_id "$n")"
    [ -n "$id" ] || {
      echo "tracker-github: could not read a database id for issue #$n — not linked" >&2
      continue
    }
    # No replace_parent, ever: a 422 here means the child already belongs to someone else's parent,
    # and that is theirs to keep.
    gh api --method POST "/repos/$repo/issues/$number/sub_issues" -F "sub_issue_id=$id" > /dev/null 2>&1
    rc=$?
    [ $rc -eq 0 ] || echo "tracker-github: #$n was not linked under #$number (it may already have a parent)" >&2
  done <<< "$want_list"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    grep -qxF "$n" <<< "$(printf '%s\n' ${owned[@]+"${owned[@]}"})" || continue
    grep -qxF "$n" <<< "$want_list" && continue
    id="$(child_db_id "$n")"
    [ -n "$id" ] || continue
    gh api --method DELETE "/repos/$repo/issues/$number/sub_issue" -F "sub_issue_id=$id" > /dev/null 2>&1 \
      || echo "tracker-github: #$n was not unlinked from #$number" >&2
  done <<< "$cur"
  printf '{"linked": %d, "skipped": %d}' "$linked" "$skipped"
}

case "$op" in
  list)
    # Never `--label` on the server: GitHub's label-filtered listing lags a create by seconds, and a
    # caller that cannot see an issue it just made will make another. Filter here instead.
    # subIssues comes back in the same call (gh selects subIssues(first:100), which is exactly
    # GitHub's per-parent cap, so nothing is paginated away). Reporting "children" is what tells the
    # CLI this adapter can link at all -- there is no capability probe.
    gh issue list --repo "$repo" --state all --limit 1000 \
      --json number,state,title,body,labels,subIssues \
      | python3 -c 'import json, sys
want = sys.argv[1]
out = [{"number": i["number"], "state": i["state"].lower(), "title": i["title"], "body": i["body"],
        "labels": [l["name"] for l in i.get("labels", [])],
        "children": sorted(n["number"] for n in (i.get("subIssues") or {}).get("nodes", []))}
       for i in json.load(sys.stdin)]
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
    # The assignee is applied here rather than passed to `issue create` above, and the difference
    # matters: `gh issue create --assignee` fails the WHOLE create when the handle cannot be
    # assigned -- a typo, or someone who is simply not a collaborator on this repo. That would trade
    # a shared issue for a missing one, which is the wrong way round; the issue is the point and the
    # assignment is a courtesy. So it is a second step, and its failure is reported and survived.
    # The reply is printed either way, so the mirror records the issue it really made.
    if [ ${#assignees[@]} -gt 0 ]; then
      aargs=(issue edit)
      for a in ${assignees[@]+"${assignees[@]}"}; do aargs+=(--add-assignee "$a"); done
      quiet_gh "${aargs[@]}" "$url" > /dev/null 2>&1 \
        || echo "tracker-github: could not assign ${assignees[*]} on $url — is that a collaborator? The issue was still created." >&2
    fi
    printf '%s' "$url" | python3 -c 'import json, re, sys
u = sys.stdin.read().strip()
m = re.search(r"/issues/([0-9]+)", u)
if not m:
    sys.stderr.write("tracker-github: could not read an issue number from: %s\n" % u)
    sys.exit(1)
json.dump({"number": int(m.group(1)), "url": u}, sys.stdout)'
    ;;
  update)
    # The text half is skipped entirely when the request carries none of it, so a link-only update
    # cannot blank a title or body by passing an empty one.
    if [ "$has_title" = 1 ] || [ "$has_body" = 1 ] || [ "$has_labels" = 1 ]; then
      bf="$(body_file)"
      ensure_labels ${labels[@]+"${labels[@]}"}
      current="$(gh issue view "$number" --repo "$repo" --json labels | python3 -c 'import json, sys
print("\n".join(l["name"] for l in json.load(sys.stdin).get("labels", [])))')"
      args=(issue edit "$number" --repo "$repo")
      [ "$has_title" = 1 ] && args+=(--title "$title")
      [ "$has_body" = 1 ] && args+=(--body-file "$bf")
      for l in ${labels[@]+"${labels[@]}"}; do args+=(--add-label "$l"); done
      if [ "$has_labels" = 1 ]; then
        while IFS= read -r l; do
          [ -n "$l" ] || continue
          is_managed "$l" || continue
          # Here-string, not a pipe: under pipefail `printf | grep -q` fails whenever grep exits first.
          grep -qxF "$l" <<< "$(printf '%s\n' ${labels[@]+"${labels[@]}"})" || args+=(--remove-label "$l")
        done <<< "$current"
      fi
      quiet_gh "${args[@]}" > /dev/null || {
        rm -f "$bf"
        exit 1
      }
      rm -f "$bf"
    fi
    if [ "$has_children" = 1 ]; then
      reconcile_links
    else
      printf '{}'
    fi
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
  whoami)
    # No --repo: this is `gh`'s own logged-in identity, not scoped to any repository.
    login="$(quiet_gh api user --jq .login)" || exit 1
    printf '{"login": "%s"}' "$login"
    ;;
  *)
    echo "tracker-github: unknown operation $op" >&2
    exit 2
    ;;
esac
