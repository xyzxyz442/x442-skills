#!/usr/bin/env bash
# verify-cross-repo-graph.sh — confirm the cross-repo scope is coherent: the manifest cascade
# parses, every in-scope repo is on disk and queryable, CRG's registry agrees, the merged graph is
# fresh, and the AGENTS.md block matches the effective set.
#
# Usage: ./verify-cross-repo-graph.sh [/path/to/repo-or-subdir]      (defaults to current dir)
#
# Fully read-only. Calls the same resolve.py the installer does, so the two can never disagree.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$PWD}"
cd "$TARGET" 2> /dev/null || {
  echo "no such path: $TARGET"
  exit 1
}
ROOT=$(git rev-parse --show-toplevel 2> /dev/null) || {
  echo "ERROR: not a git repo"
  exit 1
}
SCOPE="$PWD"

P=0
F=0
W=0
ok() {
  printf '  [PASS] %s\n' "$1"
  P=$((P + 1))
}
bad() {
  printf '  [FAIL] %s\n' "$1"
  F=$((F + 1))
}
warn() {
  printf '  [warn] %s\n' "$1"
  W=$((W + 1))
}

EFF="$(python3 "$HERE/manifest/resolve.py" --scope "$SCOPE" --root "$ROOT" 2> /dev/null)"
q() { printf '%s' "$EFF" | python3 -c "$1" "${@:2}"; }

echo "Repo:  $ROOT"
echo "Scope: $(q 'import json,sys;print(json.load(sys.stdin)["scope_rel"])' 2> /dev/null || echo '?')"
echo

echo "Manifest cascade:"
if [ -z "$EFF" ]; then
  bad "resolve.py produced no output — the cascade could not be read"
  echo
  echo "Summary: $P passed, $W warnings, $F failed"
  exit 1
fi
NLAYERS="$(q 'import json,sys;print(sum(1 for l in json.load(sys.stdin)["layers"] if l["present"]))')"
if [ "$NLAYERS" = "0" ]; then
  bad "no .graph-repos.json in the cascade — run sync-cross-repo-graph.sh for a bootstrap hint"
else
  ok "$NLAYERS manifest(s) found and parsed"
  q 'import json,sys
d=json.load(sys.stdin)
for l in d["layers"]:
    if l["present"]:
        print("         %-10s %s" % (l["layer"], l["file"]))'
fi
while IFS= read -r e; do [ -n "$e" ] && bad "$e"; done <<< "$(q 'import json,sys
for x in json.load(sys.stdin)["errors"]: print(x)')"
while IFS= read -r w; do [ -n "$w" ] && warn "$w"; done <<< "$(q 'import json,sys
for x in json.load(sys.stdin)["warnings"]: print(x)')"
while IFS= read -r s; do [ -n "$s" ] && warn "$s"; done <<< "$(q 'import json,sys
for s in json.load(sys.stdin)["shadowed"]:
    print("%s: the %s layer overrides the %s layer (override is intended? then ignore)" % (s["alias"], s["by_layer"], s["was_layer"]))')"

# ---- in-scope repos resolve and are queryable ------------------------------------------------
echo
echo "In-scope repos:"
BLOCK_ALIASES=""
AGENTS_FILE=""
d="$SCOPE"
while [ -n "$d" ]; do
  [ -f "$d/AGENTS.md" ] && {
    AGENTS_FILE="$d/AGENTS.md"
    break
  }
  [ "$d" = "$ROOT" ] && break
  d="$(dirname "$d")"
done
[ -n "$AGENTS_FILE" ] && BLOCK_ALIASES="$(sed -n '/cross-repo:begin/,/cross-repo:end/p' "$AGENTS_FILE" 2> /dev/null \
  | grep -oE '^\| `[a-z0-9][a-z0-9._-]*`' | tr -d '|` ' | sort | tr '\n' ' ')"

NEFF="$(q 'import json,sys;print(len(json.load(sys.stdin)["effective"]))')"
if [ "$NEFF" = "0" ] && [ "$NLAYERS" != "0" ]; then
  warn "the cascade resolves to zero repos (all tombstoned, or every entry is dead)"
fi
while IFS=$'\t' read -r alias fpath has_db stale writable ignored; do
  [ -z "$alias" ] && continue
  if [ "$has_db" = "1" ]; then
    ok "$alias -> $fpath (graph.db present)"
  elif printf ' %s ' "$BLOCK_ALIASES" | grep -q " $alias "; then
    bad "$alias is listed in AGENTS.md but has no graph.db — cross_repo_search silently skips it"
  else
    warn "$alias has no graph.db yet — build it: code-review-graph build --repo \"$fpath\""
  fi
  [ "$stale" = "1" ] && warn "$alias graph may be stale (its HEAD is newer than graph.db) — refresh in that repo: code-review-graph update"
  [ "$writable" = "0" ] && warn "$alias .code-review-graph/ is not writable — SQLite cannot open WAL, so cross_repo_search returns nothing"
  [ "$ignored" = "0" ] && warn "$alias does not gitignore .code-review-graph/ — our reads leave -wal/-shm files in its working tree"
done <<< "$(q 'import json,sys,os
d=json.load(sys.stdin)
for e in d["effective"]:
    stale = int(bool(e["has_crg_db"] and e["head_ct"] and e["db_mtime"] and e["head_ct"] > e["db_mtime"]))
    writable = "" if e["writable"] is None else int(e["writable"])
    gi = os.path.join(e["path"], ".gitignore")
    try:
        ignored = int(".code-review-graph/" in open(gi).read())
    except OSError:
        ignored = 0
    print("%s\t%s\t%s\t%s\t%s\t%s" % (e["alias"], e["path"], int(e["has_crg_db"]), stale, writable, ignored))')"

# ---- CRG registry: still CRG's, and it agrees with our scope ----------------------------------
echo
echo "code-review-graph registry:"
REG="$(q 'import json,sys;print(json.load(sys.stdin)["registry_path"])')"
if [ ! -f "$REG" ]; then
  warn "no registry at $REG — run sync-cross-repo-graph.sh"
elif [ "$(q 'import json,sys;print(int(json.load(sys.stdin)["registry_ok"]))')" != "1" ]; then
  bad "$REG is not valid JSON"
else
  # Guard: our graph-repos.json lives in the same directory. If registry.json ever grows OUR shape,
  # something clobbered CRG's own file and cross_repo_search will break.
  if [ "$(q 'import json,sys
d=json.load(sys.stdin)
print(int(any("remove" in r or "path" not in r for r in d["registry"])))')" = "1" ]; then
    bad "$REG does not look like CRG's registry — did something write a graph-repos.json manifest over it?"
  else
    ok "$REG has CRG's shape"
  fi
  while IFS=$'\t' read -r status alias detail; do
    [ -z "$alias" ] && continue
    case "$status" in
      ok) ok "$alias registered -> $detail" ;;
      miss) bad "$alias is in scope but not registered — re-run sync-cross-repo-graph.sh" ;;
      conflict) bad "$alias is registered to $detail, not the path your manifest declares" ;;
    esac
  done <<< "$(q 'import json,sys
d=json.load(sys.stdin)
reg={r.get("alias"): r.get("path") for r in d["registry"]}
for e in d["effective"]:
    if "crg" not in e["tools"] or not e["has_crg_db"]:
        continue
    held = reg.get(e["alias"])
    if held == e["path"]:
        print("ok\t%s\t%s" % (e["alias"], e["path"]))
    elif held is None:
        print("miss\t%s\t" % e["alias"])
    else:
        print("conflict\t%s\t%s" % (e["alias"], held))')"
  FOREIGN="$(q 'import json,sys
d=json.load(sys.stdin)
mine={e["alias"] for e in d["effective"]}
print(sum(1 for r in d["registry"] if r.get("alias") not in mine))')"
  [ "$FOREIGN" != "0" ] && ok "$FOREIGN registry entr(ies) belong to other projects — union by design, untouched"
fi

# ---- graphify merged graph --------------------------------------------------------------------
echo
echo "graphify merged graph:"
OUT="$ROOT/graphify-out/merged-graph.json"
NGFY="$(q 'import json,sys
d=json.load(sys.stdin)
print(sum(1 for e in d["effective"] if "graphify" in e["tools"] and e["has_gfy_json"]))')"
if [ "$NGFY" = "0" ]; then
  if [ -f "$OUT" ]; then
    warn "no in-scope graphify repos, but $OUT exists — stale; remove with: trash \"$OUT\""
  else
    ok "no in-scope graphify repos and no merged graph (consistent)"
  fi
elif [ ! -f "$OUT" ]; then
  bad "$NGFY in-scope graphify repo(s) but no $OUT — run sync-cross-repo-graph.sh --merge-only"
elif ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUT" 2> /dev/null; then
  bad "$OUT is not valid JSON — rebuild: sync-cross-repo-graph.sh --merge-only"
else
  ok "$OUT present and parses ($NGFY repo(s) merged)"
  STALE="$(q 'import json,os,sys
d=json.load(sys.stdin)
out=os.path.join(d["root"], "graphify-out", "merged-graph.json")
mt=os.path.getmtime(out)
srcs=[os.path.join(d["root"], "graphify-out", "graph.json")]
srcs += [e["gfy_json"] for e in d["effective"] if "graphify" in e["tools"] and e["has_gfy_json"]]
print(int(any(os.path.exists(s) and os.path.getmtime(s) > mt for s in srcs)))')"
  [ "$STALE" = "1" ] && warn "merged graph is older than one of its sources — rebuild: sync-cross-repo-graph.sh --merge-only"
fi
grep -qxF "graphify-out/" "$ROOT/.gitignore" 2> /dev/null || warn "graphify-out/ is not gitignored — the merged graph would be committed"

# ---- AGENTS.md block --------------------------------------------------------------------------
echo
echo "AGENTS.md block:"
if [ -z "$AGENTS_FILE" ]; then
  bad "no AGENTS.md at or above $SCOPE — run initial-project first"
else
  # grep -c already prints 0 on no-match (and exits 1), so `|| echo 0` would append a second 0.
  NB=$(grep -c 'cross-repo:begin' "$AGENTS_FILE" 2> /dev/null) || NB=0
  NE=$(grep -c 'cross-repo:end' "$AGENTS_FILE" 2> /dev/null) || NE=0
  if [ "$NB" = "0" ] && [ "$NE" = "0" ]; then
    if [ "$NEFF" = "0" ]; then
      ok "no cross-repo block and no repos in scope (consistent)"
    else
      bad "$NEFF repo(s) in scope but no cross-repo block in $AGENTS_FILE — run sync-cross-repo-graph.sh"
    fi
  elif [ "$NB" != "1" ] || [ "$NE" != "1" ]; then
    bad "malformed cross-repo block in $AGENTS_FILE ($NB begin / $NE end markers) — fix by hand"
  else
    ok "exactly one cross-repo block in $AGENTS_FILE"
    # Drift detector: someone edited a manifest and never re-synced.
    WANT="$(q 'import json,sys
d=json.load(sys.stdin)
print(" ".join(sorted(e["alias"] for e in d["effective"] if e["has_crg_db"] or e["has_gfy_json"])))')"
    HAVE="$(printf '%s' "$BLOCK_ALIASES" | xargs -n1 2> /dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
    if [ "$(printf '%s' "$WANT" | tr -s ' ')" = "$(printf '%s' "$HAVE" | tr -s ' ')" ]; then
      ok "block lists exactly the in-scope aliases: ${WANT:-none}"
    else
      bad "block drift — block lists [${HAVE:-none}] but the cascade resolves to [${WANT:-none}]; re-run sync-cross-repo-graph.sh"
    fi
    grep -q 'In-scope aliases' "$AGENTS_FILE" 2> /dev/null \
      || warn "block is missing the in-scope routing rule — it was written by an older version; re-run sync"
  fi
  grep -q 'graph-hooks:begin' "$AGENTS_FILE" 2> /dev/null \
    || warn "no graph-hooks block in $AGENTS_FILE — this skill chains after setup-graph-hooks"
fi

# ---- steering: do the hooks actually route a cross-repo grep to the graph? ---------------------
# The regression this exists for: grep-steer used to query only the LOCAL graph, so a grep into a
# sibling missed, and a miss reads as "the graph cannot help" — the hook waved through the one path
# this whole skill exists to prevent. Assert it no longer passes silently.
echo
echo "Cross-repo steering:"
STEER="$ROOT/.graph-hooks/core/grep-steer.sh"
if [ ! -f "$STEER" ]; then
  warn "no .graph-hooks/core/grep-steer.sh — run setup-graph-hooks.sh to get graph-first steering"
else
  if [ -f "$ROOT/.graph-hooks/core/cross-repo-scope.sh" ]; then
    ok "grep-steer can see the cross-repo scope"
  else
    bad "grep-steer predates cross-repo support (no core/cross-repo-scope.sh) — greps into a sibling will NOT be steered; re-run setup-graph-hooks.sh"
  fi

  # A repo's hooks can be older than its cross-repo scope. That combination silently un-does the
  # fence, so it is worth naming rather than leaving the user to wonder why greps still run.
  if grep -q 'cross-repo paths' "$ROOT/.graph-hooks/core/session-context.sh" 2> /dev/null; then
    warn "the session cheatsheet still tells agents to skip the graph for cross-repo paths — stale hooks; re-run setup-graph-hooks.sh"
  fi

  # End-to-end: take a real symbol out of an in-scope sibling's graph and try to grep for it.
  # HOME is redirected so the hook's once-per-hour allowance file is a throwaway — otherwise this
  # check would burn the user's real slot and its result would depend on whether they had grepped.
  SIB="$(printf '%s' "$EFF" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for e in d["effective"]:
    if e.get("has_crg_db"):
        print(e["alias"] + "\t" + e["path"]); break' 2> /dev/null)"
  SIB_ALIAS="${SIB%%	*}"
  SIB_PATH="${SIB#*	}"
  if [ -n "$SIB_ALIAS" ] && [ -f "$SIB_PATH/.code-review-graph/graph.db" ]; then
    SYM="$(sqlite3 "$SIB_PATH/.code-review-graph/graph.db" \
      "SELECT name FROM nodes WHERE kind!='File' AND length(name)>3 LIMIT 1;" 2> /dev/null)"
    if [ -n "$SYM" ]; then
      TH="$(mktemp -d)"
      OUT="$(cd "$ROOT" && printf '%s' "grep -rn \"$SYM\" $SIB_PATH" \
        | HOME="$TH" bash "$STEER" 2> /dev/null)"
      rmdir "$TH" 2> /dev/null || true
      # Assert on the ALIAS TAG, not the symbol name: grep-steer's "No graph hit for '<sym>'" miss
      # message also contains the symbol, so matching the name would pass on the very failure this
      # check exists to catch. Only a real sibling hit is tagged "[<alias>]".
      case "$OUT" in
        *"[$SIB_ALIAS]"*) ok "a grep into '$SIB_ALIAS' for '$SYM' is answered from its graph, not left to grep" ;;
        "") bad "a grep into '$SIB_ALIAS' passes silently — the graph is not steering the cross-repo path" ;;
        *) bad "grep-steer answered a cross-repo grep without the '$SIB_ALIAS' graph — it searched only the local one" ;;
      esac
    fi
  fi
fi

# ---- tools ------------------------------------------------------------------------------------
echo
echo "Graph tools:"
command -v code-review-graph > /dev/null 2>&1 && ok "code-review-graph installed" || warn "code-review-graph not installed (cross_repo_search unavailable)"
command -v graphify > /dev/null 2>&1 && ok "graphify installed" || warn "graphify not installed (optional)"

echo
echo "Summary: $P passed, $W warnings, $F failed"
[ "$F" -gt 0 ] && exit 1 || exit 0
