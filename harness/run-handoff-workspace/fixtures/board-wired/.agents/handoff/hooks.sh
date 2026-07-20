#!/usr/bin/env bash
# Handoff hooks — makes the claim/release protocol self-enforcing.
# Wired into each tool's hook config by setup-handoff (see the skill).
# Usage: hooks.sh --kind sessionstart|pretool-edit|posttool-edit|stop [--tool claude|gemini|copilot] [--repo <name>]
#
# Every kind reads the hook's JSON payload on stdin. Identity is the payload's
# session_id, which `handoff claim` records verbatim into .locks/<id>/owner as
# `session=` — that equality is the whole basis of the lease gate.
#
# JSON is parsed with python3 (this repo standardises on python3, not jq), with a
# sed fallback. FAIL-SAFE: if the payload cannot be parsed for a handoff-doc edit,
# the edit is DENIED (never silently allowed) — but ordinary repo files are never
# blocked. setup-handoff refuses hard enforcement unless python3 is present, so
# this path is only reached if the toolchain breaks after install.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCKS="$DIR/.locks"
TTL_HOURS="${HANDOFF_TTL_HOURS:-4}"
KIND=""
REPO=""
TOOL="claude"
while [ $# -gt 0 ]; do
  case "$1" in
    --kind)
      KIND="${2:-}"
      shift 2
      ;;
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --tool)
      TOOL="${2:-}"
      shift 2
      ;;
    *) shift ;;
  esac
done

# config (committed): TOPOLOGY, REPO_NAME. On a SHARED (cross-repo) board the config carries no
# REPO_NAME — the consuming repo's identity is its own, passed per-repo via $HANDOFF_REPO (baked
# into the hook command by setup-handoff). So env identity wins over the shared config value.
TOPOLOGY="single-repo"
REPO_NAME=""
# shellcheck disable=SC1091
[ -f "$DIR/config" ] && . "$DIR/config"
[ -z "$REPO" ] && REPO="${HANDOFF_REPO:-$REPO_NAME}"

PAYLOAD="$(cat)"

meta() { sed -n '2,/^---$/p' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1; }
lock_session() { sed -n 's/^session=//p' "$LOCKS/$1/owner" 2> /dev/null; }
lock_owner() { sed -n 's/^owner=//p' "$LOCKS/$1/owner" 2> /dev/null; }
lock_expires() { sed -n 's/^expires=//p' "$LOCKS/$1/owner" 2> /dev/null || echo 0; }
lock_live() { [ -d "$LOCKS/$1" ] && [ "$(date +%s)" -lt "$(lock_expires "$1")" ]; }
is_archived() { [ -f "$DIR/archive/$1.md" ]; }

# --- payload field extraction: python3 first (repo standard), sed fallback ------------
py_field() { # $1 = session|path
  printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
w = sys.argv[1]
if w == "session":
    print(d.get("session_id") or d.get("sessionId") or "")
else:
    ti = d.get("tool_input") or d.get("toolArgs") or {}
    tr = d.get("tool_response") or {}
    print(ti.get("file_path") or ti.get("filePath") or tr.get("filePath") or "")
' "$1" 2> /dev/null
}
sed_field() { # $1 = session|path  (best-effort, no python3)
  case "$1" in
    session) printf '%s' "$PAYLOAD" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 ;;
    path) printf '%s' "$PAYLOAD" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 ;;
  esac
}
field() {
  local v=""
  command -v python3 > /dev/null 2>&1 && v="$(py_field "$1")"
  [ -z "$v" ] && v="$(sed_field "$1")"
  printf '%s' "$v"
}

# --- per-tool JSON emit (shapes per setup-graph-hooks' documented table) ---------------
# All emit helpers pass their strings as argv into json.dumps — no eval, and json.dumps
# handles every escaping concern. `mode` selects the JSON shape, `$TOOL` the per-tool keys.
_emit() { # $1 = mode (deny|context|stop)  $2 = payload string  ($TOOL from env)
  python3 - "$TOOL" "$1" "$2" << 'PY' 2> /dev/null
import json, sys
tool, mode, s = sys.argv[1], sys.argv[2], sys.argv[3]
if mode == "deny":
    if tool == "gemini":
        o = {"decision": "deny", "reason": s}
    elif tool == "copilot":
        o = {"hookSpecificOutput": {"hookEventName": "preToolUse",
             "permissionDecision": "deny", "permissionDecisionReason": s}}
    else:
        o = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
             "permissionDecision": "deny", "permissionDecisionReason": s}}
elif mode == "context":
    ev = "sessionStart" if tool == "copilot" else "SessionStart"
    o = {"hookSpecificOutput": {"hookEventName": ev, "additionalContext": s}}
else:  # stop
    o = {"systemMessage": s}
print(json.dumps(o))
PY
}
deny() { # reason -> emit this tool's deny decision and stop the edit
  _emit deny "$1"
  # sed-free fallback if python3 is gone: emit a minimal valid Claude deny.
  command -v python3 > /dev/null 2>&1 \
    || printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "handoff lease not verifiable — install python3"
  exit 0
}
emit_context() { _emit context "$1"; }

# --- self-maintaining lease lifecycle -------------------------------------------------
reap_expired() { # auto-reap: clear leases whose TTL has passed (self-heal crashed sessions)
  for d in "$LOCKS"/*/; do
    [ -d "$d" ] || continue
    local exp
    exp="$(sed -n 's/^expires=//p' "$d/owner" 2> /dev/null || echo 0)"
    if [ "$(date +%s)" -ge "${exp:-0}" ]; then
      # remove the lease files then the now-empty dir (rmdir only removes empty dirs — no `rm -rf`)
      rm -f "$d"/owner 2> /dev/null
      rmdir "$d" 2> /dev/null || true
    fi
  done
  return 0
}
touch_my_leases() { # auto-touch: extend every lease held by THIS session so active work never expires
  local sess="$1"
  [ -n "$sess" ] || return 0
  for d in "$LOCKS"/*/; do
    [ -d "$d" ] || continue
    [ "$(sed -n 's/^session=//p' "$d/owner" 2> /dev/null)" = "$sess" ] || continue
    local t
    t="$(mktemp)" || continue
    grep -v '^expires=' "$d/owner" > "$t"
    echo "expires=$(($(date +%s) + TTL_HOURS * 3600))" >> "$t"
    cat "$t" > "$d/owner"
    rm -f "$t"
  done
  return 0
}

# id of the handoff doc a path refers to, or empty if the path isn't a gated doc.
doc_id_of() {
  local p="$1" base d
  # canonicalize the directory part so a ../ or symlinked path still matches $DIR
  # (which is a realpath) — otherwise a doc referenced via `repo/../.agents/handoff/x.md`
  # would slip past the gate. The file itself may not exist yet (a new doc); its dir does.
  d="$(cd "$(dirname "$p")" 2> /dev/null && pwd)" && p="$d/$(basename "$p")"
  # Handoff docs are exactly the files named <id>-handoff.md (whitelist — templates, README, and
  # config never match, so they need no blacklist). INDEX.md is not a handoff doc but is still gated
  # so the pretool handler can deny hand-edits of the generated index.
  case "$p" in
    "$DIR"/INDEX.md)
      printf 'INDEX'
      return 0
      ;;
    "$DIR"/*-handoff.md | "$DIR"/archive/*-handoff.md) ;;
    *) return 1 ;;
  esac
  base="$(basename "$p" .md)"
  printf '%s' "$base"
}

case "$KIND" in

  sessionstart)
    reap_expired # stale leases self-heal at the start of every session
    out=""
    refs=""
    for f in "$DIR"/*-handoff.md; do
      [ -f "$f" ] || continue
      id="$(basename "$f" .md)"
      # Standalone/reference docs are not claimable work — list them apart, no lease nag.
      if [ "$(meta "$f" type)" = "standalone" ]; then
        refs="${refs}- ${id} — $(meta "$f" title)"$'\n'
        continue
      fi
      aud="$(meta "$f" audience)"
      # cross-repo: only surface what THIS repo must act on next.
      [ "$TOPOLOGY" = "cross-repo" ] && [ -n "$REPO" ] && [ -n "$aud" ] && [ "$aud" != "$REPO" ] && continue
      line="- ${id} — $(meta "$f" status) · $(meta "$f" severity) · $(meta "$f" title)"
      if lock_live "$id"; then
        line="$line [🔒 HELD by $(lock_owner "$id") — do not work on it]"
      elif [ -d "$LOCKS/$id" ]; then
        line="$line [⚠️ stale lease from $(lock_owner "$id") — reclaimable]"
      fi
      if [ "$(meta "$f" status)" = "blocked" ]; then
        bo="$(meta "$f" blocked_on)"
        [ -n "$bo" ] && is_archived "${bo%% *}" && line="$line [✅ UNBLOCKED — ${bo%% *} is done]"
      fi
      out="${out}${line}"$'\n'
    done
    [ -z "$out" ] && [ -z "$refs" ] && exit 0
    # Relative board path for the hint. Cross-repo bakes HANDOFF_HDPATH (e.g. ../.claude/handoff)
    # into the hook command; single-repo uses the default in-repo location.
    hd="${HANDOFF_HDPATH:-.agents/handoff}"
    ctx="Handoffs for \`${REPO:-this repo}\` (from ${hd}/):"
    [ -n "$out" ] && ctx="${ctx}

Open (claim before working — editing a doc without its lease is blocked):
${out}"
    [ -n "$refs" ] && ctx="${ctx}

Standalone / reference (no claim needed — edit freely):
${refs}"
    ctx="${ctx}
Claim: \`${hd}/handoff claim <id> \"note\"\`. Release when you stop."
    emit_context "$ctx"
    ;;

  pretool-edit)
    path="$(field path)"
    if [ -z "$path" ]; then
      # FAIL-SAFE: couldn't parse the path. Only refuse if the payload clearly targets
      # the handoff dir — never block ordinary files over a broken parser.
      case "$PAYLOAD" in
        *"$DIR"* | */.agents/handoff/*)
          deny "Cannot verify handoff-lease ownership (could not parse the hook payload — is python3 present?). Refusing this edit to fail safe. Fix the toolchain, or claim the handoff first."
          ;;
        *) exit 0 ;;
      esac
    fi
    id="$(doc_id_of "$path")" || exit 0

    [ "$id" = "INDEX" ] && deny "INDEX.md is generated — never hand-edit it. Change the handoff doc's frontmatter, then run: .agents/handoff/handoff index"

    # Standalone/reference docs are gate-exempt: they carry no lease and are freely editable.
    # An absent type means coordination (gated), so legacy docs behave exactly as before. Only an
    # existing doc can be standalone — a brand-new (not-yet-written) doc stays gated.
    [ -f "$DIR/$id.md" ] && [ "$(meta "$DIR/$id.md" type)" = "standalone" ] && exit 0

    session="$(field session)"
    if lock_live "$id"; then
      # A legacy lease with no recorded session can't be matched; allow rather than
      # lock out the rightful holder. New leases always carry session=, so the gate is exact.
      [ -z "$(lock_session "$id")" ] && exit 0
      [ "$(lock_session "$id")" = "$session" ] && exit 0
      deny "'$id' is CLAIMED by $(lock_owner "$id"). Do not work on it and do not edit its doc — pick another handoff, or tell the user who holds it."
    fi
    if [ -d "$LOCKS/$id" ]; then
      deny "'$id' has a STALE lease from $(lock_owner "$id"). Take it over first: .agents/handoff/handoff claim $id \"note\" — the takeover gets logged."
    fi
    deny "You do not hold the lease on '$id'. Claim it before editing: .agents/handoff/handoff claim $id \"what you're doing\" — then re-try this edit."
    ;;

  posttool-edit)
    session="$(field session)"
    touch_my_leases "$session" # active work keeps its lease alive
    path="$(field path)"
    [ -n "$path" ] || exit 0
    doc_id_of "$path" > /dev/null || exit 0
    "$DIR/handoff" index > /dev/null 2>&1 || true # index can never drift from the docs
    ;;

  stop)
    session="$(field session)"
    held=""
    for d in "$LOCKS"/*/; do
      [ -d "$d" ] || continue
      id="$(basename "$d")"
      [ "$(lock_session "$id")" = "$session" ] && held="${held}${id} "
    done
    [ -z "$held" ] && exit 0
    held="${held% }"
    _emit stop "⚠️  You still hold handoff lease(s): ${held}
Release so others are not blocked: .agents/handoff/handoff release <id> --status open|blocked|done"
    ;;
esac
exit 0
