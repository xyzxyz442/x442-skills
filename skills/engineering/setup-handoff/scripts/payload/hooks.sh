#!/usr/bin/env bash
# Handoff hooks — makes the claim/release protocol self-enforcing.
# Wired into each tool's hook config by setup-handoff (see the skill).
# Usage: hooks.sh --kind sessionstart|pretool-edit|posttool-edit|stop [--tool claude|gemini|copilot] [--repo <name>] [--project-dir <path>]
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

# hooks.sh lives at <board>/scripts/hooks.sh, so the board root is its PARENT — everything below
# (docs, .locks/, config) is resolved from there. The flat fallback covers a board installed before
# the restructure whose settings.json still points at <board>/hooks.sh: there is no sibling
# `handoff` CLI one level up, so DIR stays put and the old layout keeps working until the installer
# is re-run. Probe for the CLI rather than the directory name — a board may be installed anywhere.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SELF_DIR/../handoff" ]; then
  DIR="$(cd "$SELF_DIR/.." && pwd)"
else
  DIR="$SELF_DIR"
fi
LOCKS="$DIR/.locks"
KIND=""
REPO=""
TOOL="claude"
PROJECT_DIR=""
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
    --project-dir)
      PROJECT_DIR="${2:-}"
      shift 2
      ;;
    *) shift ;;
  esac
done

# Configuration comes from config.sh — see the precedence note there. Identity used to be
# DECLARED in the hook command as a HANDOFF_REPO= prefix; it is now DISCOVERED from the consuming
# repo's own config. Resolution order is deliberate: --project-dir is exact and tool-provided,
# the git toplevel is a cwd-dependent guess, and neither existing is correct for a standalone
# board operated directly.
#
# Spelled out as an if/elif/else rather than `. A 2>/dev/null || . B`: eval "$(fn)" returns 0 even
# when the command substitution itself failed with a 127 (function not found) — command
# substitution swallows a failed source's exit status, and `eval ""` then succeeds — so a chained
# `||` cannot fail closed here. It would leave handoff_config_load undefined, `eval` would still
# report success, and the script would run on to die under `set -u` with a raw
# "HC_TOPOLOGY: unbound variable". Each source attempt is checked on its own instead.
#
# Unlike the `handoff` CLI (which hard-exits when config.sh is missing), THIS hook must never
# hard-fail the user's editing session — a pretool hook that dies breaks ordinary edits — and must
# never silently disable the deny gate either. So a missing config.sh falls back to built-in
# defaults (the gate only needs to know the board directory, which it already has via $DIR; it
# does not need config to enforce leases), the degradation is recorded in CONFIG_MISSING, and
# (sessionstart only — pretool/posttool/stop stay silent and fast) it is surfaced to the user.
CONFIG_MISSING=0
# shellcheck disable=SC1091
if [ -f "$DIR/scripts/config.sh" ]; then
  . "$DIR/scripts/config.sh"
elif [ -f "$DIR/config.sh" ]; then
  . "$DIR/config.sh"
else
  CONFIG_MISSING=1
fi

if [ "$CONFIG_MISSING" = "1" ]; then
  HC_TOPOLOGY="single-repo"
  HC_REPO_NAME=""
  HC_GROUP=""
  HC_GROUPS=""
  HC_GROUP_LAYOUT=""
  HC_TTL_HOURS=4
  HC_ALLOW_VERIFY_CMD=0
  HC_BOARD_PATH=""
else
  REPO_DIR="$PROJECT_DIR"
  [ -z "$REPO_DIR" ] && REPO_DIR="$(git rev-parse --show-toplevel 2> /dev/null || true)"
  eval "$(handoff_config_load "$DIR" "$REPO_DIR")" || exit 0
fi

TOPOLOGY="$HC_TOPOLOGY"
TTL_HOURS="${HANDOFF_TTL_HOURS:-$HC_TTL_HOURS}"
[ -z "$REPO" ] && REPO="${HANDOFF_REPO:-$HC_REPO_NAME}"

# group sections — mirror the handoff CLI so the gate, session board, and lease lookups act inside
# this repo's own section. LAYOUT is board-global (config); GROUP is this repo's section, wired into
# the hook command as $HANDOFF_GROUP. Both empty on a flat board => every path is exactly as before.
LAYOUT="${HANDOFF_GROUP_LAYOUT:-$HC_GROUP_LAYOUT}"
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'; }
GROUP="${HANDOFF_GROUP:-$HC_GROUP}"
[ -n "$GROUP" ] && GROUP="$(slug "$GROUP")"
sec_dir() { if [ "$LAYOUT" = "subfolder" ] && [ -n "$GROUP" ]; then printf '%s' "$DIR/$GROUP"; else printf '%s' "$DIR"; fi; }
arch_file() { # id -> archived doc path in this section
  case "$LAYOUT" in
    subfolder) [ -n "$GROUP" ] && {
      printf '%s' "$DIR/$GROUP/archive/$1.md"
      return
    } ;;
    prefix) [ -n "$GROUP" ] && {
      printf '%s' "$DIR/archive/$GROUP--$1.md"
      return
    } ;;
  esac
  printf '%s' "$DIR/archive/$1.md"
}
each_doc() { # this section's active docs, one per line (space-safe)
  local f
  case "$LAYOUT" in
    subfolder) if [ -n "$GROUP" ]; then
      for f in "$DIR/$GROUP"/*-handoff.md; do [ -f "$f" ] && printf '%s\n' "$f"; done
      return
    fi ;;
    prefix) if [ -n "$GROUP" ]; then
      for f in "$DIR/$GROUP"--*-handoff.md; do [ -f "$f" ] && printf '%s\n' "$f"; done
      return
    fi ;;
  esac
  for f in "$DIR"/*-handoff.md; do [ -f "$f" ] && printf '%s\n' "$f"; done
}
# Locks live in the section dir, keyed on the doc's file stem (the id doc_id_of returns) — so a repo
# only reaps/touches/nags its own section's leases, and the key matches what the CLI wrote.
LOCKS="$(sec_dir)/.locks"

PAYLOAD="$(cat)"

# Strips one surrounding quote pair, matching the CLI's meta() — a quoted value (see the `verify:`
# field, which must be quoted to stay valid YAML) has to read the same in the hooks as in the tool.
meta() {
  sed -n '2,/^---$/p' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1 \
    | sed -e 's/^"\(.*\)"$/\1/;t' -e "s/^'\(.*\)'\$/\1/"
}
lock_session() { sed -n 's/^session=//p' "$LOCKS/$1/owner" 2> /dev/null; }
lock_owner() { sed -n 's/^owner=//p' "$LOCKS/$1/owner" 2> /dev/null; }
lock_expires() { sed -n 's/^expires=//p' "$LOCKS/$1/owner" 2> /dev/null || echo 0; }
lock_live() { [ -d "$LOCKS/$1" ] && [ "$(date +%s)" -lt "$(lock_expires "$1")" ]; }
is_archived() { [ -f "$(arch_file "$1")" ]; }

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
  # config never match, so they need no blacklist). A grouped board adds a subfolder level
  # ($DIR/<group>/<id>-handoff.md) or a prefixed flat name ($DIR/<group>--<id>-handoff.md, already
  # covered by the flat pattern). The generated indexes — board roll-up ($DIR/INDEX.md), prefix
  # sub-index ($DIR/INDEX-<group>.md), subfolder sub-index ($DIR/<group>/INDEX.md) — are gated so the
  # pretool handler can deny hand-edits of any generated index.
  case "$p" in
    "$DIR"/INDEX.md | "$DIR"/INDEX-*.md | "$DIR"/*/INDEX.md)
      printf 'INDEX'
      return 0
      ;;
    "$DIR"/*-handoff.md | "$DIR"/archive/*-handoff.md | "$DIR"/*/*-handoff.md | "$DIR"/*/archive/*-handoff.md) ;;
    *) return 1 ;;
  esac
  base="$(basename "$p" .md)"
  printf '%s' "$base"
}

# Board conditions that do NOT self-heal. reap_expired (above, run first) already clears any lease
# whose owner lacks a future expires= — including a lock directory with no owner file at all — so
# only a lease that is still VALID can be broken in a way worth reporting. Both checks below are
# answerable from this repo alone, with no reference to the skill that installed the board; that
# skill directory is unreachable from a consuming repo, which is why a stale-PAYLOAD check cannot
# live here at all and belongs in verify-setup-handoff.sh instead. Reports and stops: a session
# hook names the repair skill, it never repairs.
board_health() {
  local d id
  for d in "$LOCKS"/*; do
    [ -d "$d" ] || continue
    id="$(basename "$d")"
    # Checked across every layout's doc location rather than via arch_file, whose prefix-layout
    # path re-adds a group prefix the lock id already carries.
    [ -f "$(sec_dir)/$id.md" ] || [ -f "$(sec_dir)/archive/$id.md" ] || [ -f "$DIR/archive/$id.md" ] \
      || printf 'lease .locks/%s has no handoff doc — orphaned by a rename or delete\n' "$id"
  done
  if [ ! -f "$DIR/INDEX.md" ] && [ -n "$(each_doc)" ]; then
    printf 'INDEX.md is missing while handoff docs exist — the generated index is gone\n'
  fi
}

case "$KIND" in

  sessionstart)
    reap_expired # stale leases self-heal at the start of every session
    health="$(board_health)"
    out=""
    refs=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      id="$(basename "$f" .md)"
      # Standalone/reference docs and orchestrators are not claimable work — list them apart,
      # no lease nag. An orchestrator holds no work of its own; its children are the work.
      case "$(meta "$f" type)" in
        standalone | orchestrator)
          refs="${refs}- ${id} — $(meta "$f" title)"$'\n'
          continue
          ;;
      esac
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
    done < <(each_doc)
    [ -z "$out" ] && [ -z "$refs" ] && [ -z "$health" ] && [ "$CONFIG_MISSING" != "1" ] && exit 0
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
    [ -n "$health" ] && ctx="${ctx}

Board needs attention:
$(printf '%s\n' "$health" | sed 's/^/  - /')
  Repair: use the repair-handoff skill (re-running setup-handoff does not fix board state)."
    [ "$CONFIG_MISSING" = "1" ] && ctx="${ctx}

This board is missing scripts/config.sh — identity and settings are running on built-in defaults.
Re-run setup-handoff to update it."
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

    # Read the doc by its canonical path (the id alone can't be turned back into a path on a grouped
    # board — the stem may carry a group prefix, or the file may sit in a group subdir).
    cpath="$(cd "$(dirname "$path")" 2> /dev/null && pwd)/$(basename "$path")"
    # Standalone/reference docs are gate-exempt: they carry no lease and are freely editable.
    # An absent type means coordination (gated), so legacy docs behave exactly as before. Only an
    # existing doc can be standalone — a brand-new (not-yet-written) doc stays gated. Orchestrators
    # are exempt for the same reason: they carry no lease, only an index of the children that do.
    if [ -f "$cpath" ]; then
      case "$(meta "$cpath" type)" in standalone | orchestrator) exit 0 ;; esac
    fi

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
