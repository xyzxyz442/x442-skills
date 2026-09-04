#!/usr/bin/env bash
# consent-gate.sh — PreToolUse gate for delegation and credential exposure.
#
#   consent-gate.sh --tool claude|gemini|copilot
#
# Reads a PreToolUse payload on stdin and emits a permission decision. Three jobs:
#
#   1. deny a dispatch that skipped the consent gate
#   2. deny reaching the backend wrapper directly, which would skip consent, the never-delegate
#      paths, the secret scans, and round accounting
#   3. gate reads of credential-shaped paths
#
# The asymmetry in (3) is deliberate. A read heading into a DISPATCH is denied outright: exposing
# a third party to your credentials is not a call you get to make on their behalf. A read in your
# own session only ASKS, because that is your own informed consent to give — and because a blanket
# deny would block ordinary work like checking whether a .env has the right keys.
#
# Honest about its ceiling: this is a cooperative gate, not a sandbox. It cannot stop a command
# that prints a secret without naming a secret path (`env`, a build that echoes a var, a stack
# trace). And nothing can redact a secret after the fact — a tool result enters the transcript
# before any hook runs, and that transcript persists to disk. Prevention is the only lever.
#
# Read-only. Exits 0 (allow) on anything it cannot parse: a gate that failed closed on an
# unrecognised payload would block every unrelated command in the session.
#
# WITHOUT python3 the gate degrades, it does not surrender. It used to `exit 0` here, which threw
# away the never-delegate paths, the credential-path checks and the consent requirement in one
# line -- and none of the rules below actually need an interpreter, only the JSON reading and
# writing around them did. So the degraded lane supplies both in awk and bash and then runs the
# SAME rules against the SAME three fields. Every decision it reaches says it is degraded,
# because a control that quietly weakens is one you trust further than it has earned.
#
# The first attempt at this scanned the whole raw payload instead of extracting the fields, and
# it was worse than useless: `"command":"delegate-run ..."` puts a quote where the boundary
# regexes expect a slash or a space, so every bare dispatch sailed through -- while an ordinary
# Read whose unrelated context mentioned `delegate-agent` was denied outright. A gate that
# fails open on its own subject and closed on everyone else is not a degraded gate.

set -euo pipefail

TOOL="claude"
while [ $# -gt 0 ]; do
  case "$1" in
    --tool)
      TOOL="${2:-claude}"
      shift 2
      ;;
    *) shift ;;
  esac
done

# A delegate must never be gated by the hooks it inherited from the repo it is working in. This
# gate governs the ORCHESTRATOR's decision to delegate; the delegate's own tool use is already
# bounded by its allowlist. Worse, an "ask" inside a headless run has nobody to answer it, so
# leaving this out turns an inherited hook into a hang.
[ "${DELEGATE_DEPTH:-0}" -ge 1 ] && exit 0

HAVE_PY=1
command -v python3 > /dev/null 2>&1 || HAVE_PY=0
PAYLOAD="$(cat 2> /dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0

# Appended to every reason a degraded gate emits. The operator needs to know the decision came
# from a weaker check than the one they installed -- and, since a degraded gate is coarser, why
# they may be seeing a prompt they would not normally get.
DEGRADED_NOTE=""
if [ "$HAVE_PY" -eq 0 ]; then
  DEGRADED_NOTE=" [DEGRADED -- python3 is unavailable, so this decision came from a raw-text scan of the payload rather than its parsed fields. Install python3 to restore the full gate.]"
fi

# bash cannot serialise JSON safely in general; it can serialise THESE strings, which are fixed
# literals in this file. The escaping is belt-and-braces for a future edit that adds one with a
# quote in it.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

decide() { # decide <deny|ask> <reason>
  local msg="$2$DEGRADED_NOTE"
  if [ "$HAVE_PY" -eq 0 ]; then
    local d e ev
    d="$(json_escape "$1")"
    e="$(json_escape "$msg")"
    if [ "$TOOL" = "gemini" ]; then
      printf '{"decision": "%s", "reason": "%s"}\n' "$d" "$e"
    else
      if [ "$TOOL" = "copilot" ]; then ev="preToolUse"; else ev="PreToolUse"; fi
      printf '{"hookSpecificOutput": {"hookEventName": "%s", "permissionDecision": "%s", "permissionDecisionReason": "%s"}}\n' "$ev" "$d" "$e"
    fi
    exit 0
  fi
  python3 - "$TOOL" "$1" "$msg" << 'PY'
import json, sys
tool, decision, msg = sys.argv[1], sys.argv[2], sys.argv[3]
if tool == "gemini":
    out = {"decision": decision, "reason": msg}
else:
    ev = "preToolUse" if tool == "copilot" else "PreToolUse"
    out = {"hookSpecificOutput": {"hookEventName": ev,
                                  "permissionDecision": decision,
                                  "permissionDecisionReason": msg}}
print(json.dumps(out))
PY
  exit 0
}

# Field names differ per tool; try the known ones and give up quietly rather than guessing.
EXTRACT='
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or d.get("toolInput") or d.get("input") or {}
name = d.get("tool_name") or d.get("toolName") or ""
cmd = ti.get("command") or ti.get("cmd") or "" if isinstance(ti, dict) else ""
path = ti.get("file_path") or ti.get("path") or "" if isinstance(ti, dict) else ""
print(name); print(cmd); print(path)
'
# The python-free reader for the same three fields. Character scan, not a regex: a JSON string
# ends at the first unescaped quote, and `--brief "cat foo"` inside a command is exactly the
# case a regex gets wrong.
JEXTRACT='
function unesc(v,   o, i, n, c) {
  o = ""; n = length(v)
  for (i = 1; i <= n; i++) {
    c = substr(v, i, 1)
    if (c == "\\" && i < n) {
      i++
      c = substr(v, i, 1)
      if (c == "n") c = "\n"
      else if (c == "t") c = "\t"
      else if (c == "r") c = "\r"
      else if (c == "u") { o = o "\\u"; continue }
    }
    o = o c
  }
  return o
}
function findval(s, key,   p, i, n, c, out) {
  p = index(s, "\"" key "\"")
  if (p == 0) return ""
  i = p + length(key) + 2
  n = length(s)
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == " " || c == "\t" || c == "\n" || c == ":") { i++ } else { break }
  }
  if (substr(s, i, 1) != "\"") return ""
  i++
  out = ""
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\\") { out = out c substr(s, i + 1, 1); i += 2; continue }
    if (c == "\"") break
    out = out c
    i++
  }
  return unesc(out)
}
function pick(s, a, b,   v) { v = findval(s, a); if (v == "") v = findval(s, b); return v }
{ doc = doc $0 "\n" }
END {
  print pick(doc, "tool_name", "toolName")
  print pick(doc, "command", "cmd")
  print pick(doc, "file_path", "path")
}
'
if [ "$HAVE_PY" -eq 1 ]; then
  FIELDS="$(printf '%s' "$PAYLOAD" | python3 -c "$EXTRACT" 2> /dev/null || true)"
  TOOL_NAME="$(printf '%s\n' "$FIELDS" | sed -n 1p)"
  CMD="$(printf '%s\n' "$FIELDS" | sed -n 2p)"
  FILE_PATH="$(printf '%s\n' "$FIELDS" | sed -n 3p)"
else
  # No json module, so read the three fields with awk. It walks the payload as characters rather
  # than pattern-matching it, so an escaped quote inside a command value does not end the string
  # early. Weaker than the real parser in one way that matters: it takes the FIRST occurrence of
  # each key wherever it appears, with no notion of `tool_input` nesting. That is the honest
  # limit of the degraded lane -- and it is the same three fields, so every rule below is the
  # rule the parsed lane runs.
  FIELDS="$(printf '%s' "$PAYLOAD" | awk "$JEXTRACT" 2> /dev/null || true)"
  TOOL_NAME="$(printf '%s\n' "$FIELDS" | sed -n 1p)"
  CMD="$(printf '%s\n' "$FIELDS" | sed -n 2p)"
  FILE_PATH="$(printf '%s\n' "$FIELDS" | sed -n 3p)"
fi

# Credential-shaped paths. Deliberately short: a floor, matched against the intersection of what
# is gitignored and what looks like a secret. Content scanning at the dispatch boundary is the
# real check; this only catches the obvious reach for a known credential file.
# Boundary is start-of-string, a slash, whitespace, '=', or a quote — a path arrives as
# `cat .env` or `--task .env` just as often as `/etc/.env`, and anchoring only on ^ or / misses
# both. Quotes earn their place twice: `cat ".env"` is an ordinary command the unquoted form
# missed, and in degraded mode the haystack is raw JSON, where every value ends at a `"`.
Q="\"'"
B="(^|[[:space:]/=${Q}])"
E="(\$|[./[:space:]${Q}])"
SECRET_RE="${B}\.env${E}|\.pem($|[^a-z])|\.key($|[^a-z])|${B}secrets?/|id_rsa|${B}\.ssh/|credentials?\.json"

if [ -n "$CMD" ]; then
  # (2) direct backend invocation
  if printf '%s' "$CMD" | grep -qE '(^|[/[:space:]])delegate-agent([[:space:]]|$)'; then
    decide deny "Do not invoke delegate-agent directly — it skips the consent gate, the never-delegate paths, the secret scans, and round accounting. Dispatch through delegate-run, which the run-delegate-agent skill drives."
  fi

  if printf '%s' "$CMD" | grep -qE '(^|[/[:space:]])delegate-run([[:space:]]|$)'; then
    # Recording consent and dry runs never reach a backend.
    printf '%s' "$CMD" | grep -qE -- '--(approve|dry-run)([[:space:]]|=|$)' && exit 0
    # (3, dispatch-bound) a dispatch that names a credential path is refused outright.
    if printf '%s' "$CMD" | grep -qE "$SECRET_RE"; then
      decide deny "This dispatch names a credential-shaped path. Secrets are never sent to a delegated agent — that exposure is not yours to consent to on its behalf. Remove the path from the brief."
    fi
    # (1) consent
    printf '%s' "$CMD" | grep -qE -- '--approved([[:space:]]|=)' || decide deny \
      "This dispatch has no recorded consent. Assess the task first (fit, size, party, risk), ask the user, then record it: delegate-run --approve TASK_ID --class CLASS --allow '<tools>'. See the run-delegate-agent skill."
    exit 0
  fi

  # (3, main session) reading a credential in your own session asks rather than denies.
  if printf '%s' "$CMD" | grep -qE "$SECRET_RE"; then
    decide ask "This command reads a credential-shaped path. Anything it prints enters this transcript, which persists to disk and cannot be redacted afterwards. Allow only if you meant to."
  fi
fi

if [ -n "$FILE_PATH" ] && [ "$TOOL_NAME" = "Read" ]; then
  if printf '%s' "$FILE_PATH" | grep -qE "$SECRET_RE"; then
    decide ask "Reading a credential-shaped path puts its contents in this transcript, which persists to disk and cannot be redacted afterwards. Allow only if you meant to."
  fi
fi

exit 0
