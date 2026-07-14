#!/usr/bin/env bash
# grep-steer.sh — tool-neutral graph-first grep/find decision core.
# stdin: a raw shell command string. stdout: neutral hook JSON, or nothing to pass.
#   {"context":"..."}                          -> inject advice, allow the command
#   {"decision":"deny","reason":..,"context":..} -> block the command, answer inline
# emit.py maps this neutral shape to each tool's hook JSON. Ported from the original
# smart-grep-hook.sh; behavior is unchanged — only the protocol wrapping was removed.
#
# Decision ladder (first match wins):
#   1. Not a search command (grep/rg/find/fd/ack/ag)  -> pass silently
#   2. Command contains --graph-tried                 -> pass silently (explicit override)
#   3. Target is non-code (.md/.json/.yml/.log/...)   -> pass silently
#   4. No graph at all (local, or an in-scope sibling) -> pass silently
#   5. A graph can answer, one allowance per repo per hour:
#        a. first grep + hit  -> inject answer, ALLOW (one-shot lesson)
#        b. first grep + miss -> ALLOW, suggest the right tool for next time
#        c. later grep + hit  -> DENY with the answer inline (kills the retry loop)
#        d. later grep + miss -> pass silently
#
# The graph searched is the local one PLUS every in-scope sibling (cross-repo-scope.sh). Without
# the siblings, a grep into another checkout missed the local graph, and a miss reads as "the graph
# cannot help" — so the one path register-cross-repo-graph exists to stop was the one path this
# hook waved through. A sibling hit denies only when the command actually points INTO that sibling:
# a broad local grep that merely happens to match a sibling symbol still gets the hits as context,
# because the agent may legitimately want the local call sites.
set -uo pipefail

CMD="$(cat 2> /dev/null || true)"
[ -z "$CMD" ] && exit 0

# Tier 1 — only intercept search commands
case " $CMD " in
  *grep* | *" rg "* | *ripgrep* | *" find "* | *" fd "* | *" ack "* | *" ag "*) : ;;
  *) exit 0 ;;
esac

# Tier 2 — explicit override
case "$CMD" in *--graph-tried*) exit 0 ;; esac

# Tier 3 — non-code targets (graph can't index these)
case "$CMD" in
  *.md* | *.json* | *.yml* | *.yaml* | *.log* | *.jsonl* | *.txt* | *.csv* | *.lock* | \
    *node_modules* | */.git/* | */dist/* | */build/* | */.next/* | */__pycache__/*) exit 0 ;;
esac

# Tier 4 — detect graphs: this repo's, plus any in-scope sibling's (silence = no cross-repo scope)
HERE="$(cd "$(dirname "$0")" && pwd)"
HAVE_CRG=0
HAVE_GFY=0
[ -f .code-review-graph/graph.db ] && HAVE_CRG=1
[ -f graphify-out/graph.json ] && HAVE_GFY=1
SCOPE="$(bash "$HERE/cross-repo-scope.sh" 2> /dev/null || true)"
[ "$HAVE_CRG" = 0 ] && [ "$HAVE_GFY" = 0 ] && [ -z "$SCOPE" ] && exit 0

# Extract a search term: first non-flag word > 2 chars that is not a path
PATTERN="$(printf '%s' "$CMD" | python3 -c "import sys,shlex
try: parts=shlex.split(sys.stdin.read())
except Exception: parts=sys.stdin.read().split()
bases={'grep','egrep','fgrep','rg','ripgrep','ag','ack','fd','find'}
i=next((k for k,p in enumerate(parts) if p.rsplit('/',1)[-1] in bases),-1)
if i<0: sys.exit(0)
for p in parts[i+1:]:
    if not p.startswith('-') and len(p)>2 and '/' not in p:
        print(p[:60]); break" 2> /dev/null || true)"
[ -z "$PATTERN" ] && exit 0

query_crg() { # $1=db $2=pattern  (FTS5, falls back to LIKE; read-only)
  python3 - "$1" "$2" << 'PY' 2> /dev/null
import sqlite3, sys, os
db, pat = sys.argv[1], sys.argv[2]
if not os.path.exists(db): sys.exit(0)
try:
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=3)
    rows = []
    try:
        rows = c.execute(
            "SELECT n.kind,n.name,n.file_path,n.line_start "
            "FROM nodes_fts f JOIN nodes n ON n.id=f.rowid "
            "WHERE nodes_fts MATCH ? LIMIT 5", (pat,)).fetchall()
    except Exception:
        rows = []
    if not rows:
        rows = c.execute(
            "SELECT kind,name,file_path,line_start FROM nodes WHERE name LIKE ? LIMIT 5",
            (f"%{pat}%",)).fetchall()
    c.close()
    for kind, name, path, line in rows:
        print(f"[crg] {kind}  {name}  -> {path}:{line}")
except Exception:
    pass
PY
}

query_gfy() { # $1=graph.json $2=pattern
  python3 - "$1" "$2" << 'PY' 2> /dev/null
import json, sys, os
gfile, pat = sys.argv[1], sys.argv[2].lower()
if not os.path.exists(gfile): sys.exit(0)
try:
    g = json.load(open(gfile)); out = []
    for n in g.get('nodes', []):
        label = str(n.get('label', '')); nid = str(n.get('id', ''))
        if pat in label.lower() or pat in nid.lower():
            src = n.get('source_file', ''); loc = n.get('source_location', '') or n.get('line', '')
            out.append(f"[graphify] {n.get('file_type','node')}  {label}  -> {src}:{loc}")
    for r in out[:5]:
        print(r)
except Exception:
    pass
PY
}

# Does the command actually point INTO an in-scope sibling? (decides deny vs advise — see header)
# The command comes in as $2, NOT on stdin: the heredoc below already occupies stdin with the
# script itself, so a sys.stdin.read() here would silently return "" and match nothing.
target_alias() { # $1=scope lines  $2=command; stdout: alias of the sibling it targets, or nothing
  python3 - "$1" "$2" << 'PY' 2> /dev/null || true
import os, shlex, sys

scope = [ln.split("\t") for ln in sys.argv[1].splitlines() if "\t" in ln]
try:
    parts = shlex.split(sys.argv[2])
except Exception:
    parts = sys.argv[2].split()
for tok in parts:
    if tok.startswith("-"):
        continue
    p = os.path.realpath(os.path.join(os.getcwd(), os.path.expanduser(tok)))
    for alias, path in scope:
        root = os.path.realpath(path)
        if p == root or p.startswith(root + os.sep):
            print(alias)
            sys.exit(0)
PY
}

RESULT_LOCAL=""
[ "$HAVE_CRG" = 1 ] && RESULT_LOCAL="$RESULT_LOCAL$(query_crg .code-review-graph/graph.db "$PATTERN")
"
[ "$HAVE_GFY" = 1 ] && RESULT_LOCAL="$RESULT_LOCAL$(query_gfy graphify-out/graph.json "$PATTERN")
"
RESULT_LOCAL="$(printf '%s' "$RESULT_LOCAL" | sed '/^[[:space:]]*$/d')"

# Siblings: same query_crg, just pointed at their db. Label each hit with the alias so the agent
# can see which repo answered — and that the alias is one the AGENTS.md fence allows.
RESULT_SIB=""
XREPO_ALIAS=""
if [ -n "$SCOPE" ]; then
  XREPO_ALIAS="$(target_alias "$SCOPE" "$CMD")"
  while IFS="$(printf '\t')" read -r alias spath; do
    [ -n "$alias" ] || continue
    hits="$(query_crg "$spath/.code-review-graph/graph.db" "$PATTERN" | sed "s|^\[crg\]|[$alias]|")"
    [ -n "$hits" ] && RESULT_SIB="$RESULT_SIB$hits
"
  done << EOF
$SCOPE
EOF
  RESULT_SIB="$(printf '%s' "$RESULT_SIB" | sed '/^[[:space:]]*$/d')"
fi

RESULT="$(printf '%s\n%s' "$RESULT_LOCAL" "$RESULT_SIB" | sed '/^[[:space:]]*$/d')"

# Deny only on an answer the agent was actually reaching for: a local hit, or a sibling hit when the
# command points into that sibling. A broad local grep that merely matches a sibling symbol gets the
# hits as advice — the agent may want the local call sites, and denying that would be wrong.
DENYABLE="$RESULT_LOCAL"
[ -n "$XREPO_ALIAS" ] && DENYABLE="$RESULT_SIB"

HINT=""
if [ -n "$XREPO_ALIAS" ] || [ -n "$RESULT_SIB" ]; then
  HINT="cross_repo_search_tool(query='$PATTERN')"
  [ -f graphify-out/merged-graph.json ] \
    && HINT="$HINT or graphify query '$PATTERN' --graph graphify-out/merged-graph.json"
fi
if [ -z "$XREPO_ALIAS" ]; then
  [ "$HAVE_CRG" = 1 ] && HINT="${HINT:+$HINT or }semantic_search_nodes_tool(query='$PATTERN')"
  [ "$HAVE_GFY" = 1 ] && HINT="${HINT:+$HINT or }graphify query '$PATTERN' --graph graphify-out/graph.json"
fi

# One allowance per repo per hour
KEY="$(printf '%s' "$PWD" | { md5sum 2> /dev/null || md5 2> /dev/null; } | cut -c1-8)"
DIR="${HOME}/.cache/graph-steer-hook"
mkdir -p "$DIR" 2> /dev/null || true
SLOT="${DIR}/first-${KEY:-x}-$(date +%Y%m%d%H)"

emit_neutral() { # $1=context|deny  $2=text   (python does the JSON escaping)
  python3 - "$1" "$2" << 'PY'
import json, sys
mode, text = sys.argv[1], sys.argv[2]
if mode == "context":
    print(json.dumps({"context": text}))
elif mode == "deny":
    print(json.dumps({"decision": "deny", "reason": text, "context": text}))
PY
}

if [ ! -f "$SLOT" ]; then
  touch "$SLOT" 2> /dev/null || true
  if [ -n "$RESULT" ]; then
    emit_neutral context "Knowledge graph pre-answer for '$PATTERN':
$RESULT

If that's enough, skip the grep. Allowing this one (one-shot). Repeat code-symbol greps get denied when the graph can answer. Bypass anytime: append --graph-tried."
  else
    emit_neutral context "No graph hit for '$PATTERN' — grep proceeding (one-shot). Next time try: $HINT. Append --graph-tried to bypass permanently."
  fi
  exit 0
fi

if [ -n "$DENYABLE" ]; then
  emit_neutral deny "The knowledge graph already has this — no grep/retry needed:

$DENYABLE

Use: $HINT. Append --graph-tried to override."
  exit 0
fi

# A sibling answered, but the command was not aimed at that sibling — advise, never block.
if [ -n "$RESULT_SIB" ]; then
  emit_neutral context "An in-scope sibling repo's graph also has '$PATTERN':

$RESULT_SIB

Use: $HINT — no need to grep across the folder boundary."
fi
exit 0
