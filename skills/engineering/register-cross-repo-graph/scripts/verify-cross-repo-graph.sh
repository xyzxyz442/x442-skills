#!/usr/bin/env bash
# verify-cross-repo-graph.sh — confirm the cross-repo scope is coherent: the manifest cascade
# parses, every in-scope repo is on disk and queryable, CRG's registry agrees, the merged graph is
# fresh, and the AGENTS.md block matches the effective set.
#
# Usage: ./verify-cross-repo-graph.sh [/path/to/repo-or-subdir] [--json]   (path defaults to cwd)
#
# Fully read-only. Calls the same resolve.py the installer does, so the two can never disagree.
#
# --json emits every finding as a machine-readable object instead of prose. Most of what this
# checks is ADVISORY by design — a sibling with no graph yet, a stale merged graph, hooks that
# predate cross-repo support, an un-gitignored graphify-out/ — and none of it changes the exit
# code, so a grader reading only the exit status is blind to exactly the checks most likely to
# rot. This is the channel that makes them gradeable.
#
# Every finding carries a STABLE ID. The id names the CHECK and `level` carries the outcome, so a
# grader asserts "merged.stale came back warn" rather than matching prose that any future rewording
# breaks. Where two outcomes of one check need different remediation they get different ids
# (repo.graph_db.missing vs repo.graph_db.advertised_missing) — same rule, where it earns itself.
set -uo pipefail

JSON=0
ARGS=""
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    *) ARGS="$a" ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${ARGS:-$PWD}"
cd "$TARGET" 2> /dev/null || {
  echo "no such path: $TARGET" >&2
  exit 1
}
ROOT=$(git rev-parse --show-toplevel 2> /dev/null) || {
  echo "ERROR: not a git repo" >&2
  exit 1
}
SCOPE="$PWD"

P=0
F=0
W=0
# Findings accumulate as TSV (level, id, section, message) and are rendered once at the end. TSV
# rather than JSON-per-line because bash cannot escape JSON safely and the renderer is python3
# anyway; tabs and newlines are stripped from the message so a field can never break the record.
FINDINGS="$(mktemp)"
SECTION=""
trap 'rm -f "$FINDINGS"' EXIT
# This verifier's headers carry no dashed underline, unlike the other five, so section() prints
# exactly what the `echo; echo "..."` pairs printed before -- the human output must not move.
section() { # human header AND the section label every finding below it carries
  SECTION="$1"
  echo
  echo "$1"
}
emit() { # level id message
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$SECTION" "$(printf '%s' "$3" | tr '\t\n' '  ')" >> "$FINDINGS"
}
ok() { # id message
  emit pass "$1" "$2"
  printf '  [PASS] %s\n' "$2"
  P=$((P + 1))
}
bad() { # id message
  emit fail "$1" "$2"
  printf '  [FAIL] %s\n' "$2"
  F=$((F + 1))
}
warn() { # id message
  emit warn "$1" "$2"
  printf '  [warn] %s\n' "$2"
  W=$((W + 1))
}
# In --json mode the prose goes to /dev/null and the JSON document is written to the real stdout.
# Redirecting the fd rather than guarding every echo site keeps ONE rendering path: the human
# output and the findings can never disagree, because they are produced by the same call.
if [ "$JSON" = 1 ]; then
  exec 3>&1 1> /dev/null
fi

# This verifier has THREE exits (unreadable cascade, not-configured, and the normal end), and all
# three must render the same document -- an early exit that printed nothing would look to a grader
# exactly like a verifier that crashed. finish() is the single rendering path for all of them.
finish() { # exit-code [summary-suffix]
  echo
  echo "Summary: $P passed, $W warnings, $F failed${2:-}"
  if [ "$JSON" = 1 ]; then
    exec 1>&3
    python3 - "$FINDINGS" "$ROOT" "$P" "$W" "$F" << 'PY'
import json, sys

path, root, npass, nwarn, nfail = sys.argv[1:6]
findings = []
with open(path) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 4:
            continue
        level, fid, section, message = parts
        findings.append({"id": fid, "level": level, "section": section, "message": message})

print(json.dumps({
    "tool": "verify-cross-repo-graph",
    # Bumped only when the SHAPE changes. A consumer pins this, not the set of ids: ids are added
    # over time by design, and a grader that broke every time a new check appeared would be
    # abandoned within a release.
    "schema": 1,
    "repo": root,
    "summary": {"pass": int(npass), "warn": int(nwarn), "fail": int(nfail)},
    "findings": findings,
}, indent=2, sort_keys=True))
PY
  fi
  exit "$1"
}

EFF="$(python3 "$HERE/manifest/resolve.py" --scope "$SCOPE" --root "$ROOT" 2> /dev/null)"
q() { printf '%s' "$EFF" | python3 -c "$1" "${@:2}"; }

echo "Repo:  $ROOT"
echo "Scope: $(q 'import json,sys;print(json.load(sys.stdin)["scope_rel"])' 2> /dev/null || echo '?')"
section "Manifest cascade:"
if [ -z "$EFF" ]; then
  bad cascade.resolves "resolve.py produced no output — the cascade could not be read"
  finish 1
fi
NLAYERS="$(q 'import json,sys;print(sum(1 for l in json.load(sys.stdin)["layers"] if l["present"]))')"
if [ "$NLAYERS" = "0" ]; then
  # "Not opted in" is distinct from "broken": a repo with no .graph-repos.json anywhere in its
  # cascade simply has no cross-repo scope to verify. Reporting that as a [FAIL] (exit 1) made the
  # verifier unusable as a health probe — absence and breakage were indistinguishable. Report it as
  # a skip and exit clean; there is nothing to check until a manifest is declared.
  emit skip cascade.not_configured "no .graph-repos.json in the cascade — cross-repo access is not configured here"
  printf '  [skip] no .graph-repos.json in the cascade — cross-repo access is not configured here\n'
  printf '         declare siblings in .graph-repos.json, then run sync-cross-repo-graph.sh\n'
  finish 0 " (not configured — nothing to verify)"
fi
ok cascade.layers "$NLAYERS manifest(s) found and parsed"
q 'import json,sys
d=json.load(sys.stdin)
for l in d["layers"]:
    if l["present"]:
        print("         %-10s %s" % (l["layer"], l["file"]))'
while IFS= read -r e; do [ -n "$e" ] && bad cascade.error "$e"; done <<< "$(q 'import json,sys
for x in json.load(sys.stdin)["errors"]: print(x)')"
while IFS= read -r w; do [ -n "$w" ] && warn cascade.warning "$w"; done <<< "$(q 'import json,sys
for x in json.load(sys.stdin)["warnings"]: print(x)')"
while IFS= read -r s; do [ -n "$s" ] && warn cascade.shadowed "$s"; done <<< "$(q 'import json,sys
for s in json.load(sys.stdin)["shadowed"]:
    print("%s: the %s layer overrides the %s layer (override is intended? then ignore)" % (s["alias"], s["by_layer"], s["was_layer"]))')"

# ---- in-scope repos resolve and are queryable ------------------------------------------------
section "In-scope repos:"
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
  warn scope.empty "the cascade resolves to zero repos (all tombstoned, or every entry is dead)"
fi
while IFS=$'\t' read -r alias fpath has_db stale writable ignored; do
  [ -z "$alias" ] && continue
  if [ "$has_db" = "1" ]; then
    ok repo.graph_db "$alias -> $fpath (graph.db present)"
  elif printf ' %s ' "$BLOCK_ALIASES" | grep -q " $alias "; then
    bad repo.graph_db.advertised_missing "$alias is listed in AGENTS.md but has no graph.db — cross_repo_search silently skips it"
  else
    warn repo.graph_db.missing "$alias has no graph.db yet — build it: code-review-graph build --repo \"$fpath\""
  fi
  if [ "$stale" = "1" ]; then
    # A stale sibling is a warning in general, but a FAIL when the AGENTS.md block advertises the
    # alias: agents route to a graph that predates the sibling's HEAD, so a "0 failed" here would
    # certify hooks that hand out expired cross-repo answers. grep-steer advises-not-denies on a
    # stale sibling at runtime, but the advertised-yet-stale state is still a real defect to fix.
    if printf ' %s ' "$BLOCK_ALIASES" | grep -q " $alias "; then
      bad repo.graph_stale.advertised "$alias is advertised in AGENTS.md but its graph is stale (HEAD newer than graph.db) — agents get expired cross-repo answers; refresh in that repo: code-review-graph update"
    else
      warn repo.graph_stale "$alias graph may be stale (its HEAD is newer than graph.db) — refresh in that repo: code-review-graph update"
    fi
  fi
  [ "$writable" = "0" ] && warn repo.writable "$alias .code-review-graph/ is not writable — SQLite cannot open WAL, so cross_repo_search returns nothing"
  [ "$ignored" = "0" ] && warn repo.gitignored "$alias does not gitignore .code-review-graph/ — our reads leave -wal/-shm files in its working tree"
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
section "code-review-graph registry:"
REG="$(q 'import json,sys;print(json.load(sys.stdin)["registry_path"])')"
if [ ! -f "$REG" ]; then
  warn registry.present "no registry at $REG — run sync-cross-repo-graph.sh"
elif [ "$(q 'import json,sys;print(int(json.load(sys.stdin)["registry_ok"]))')" != "1" ]; then
  bad registry.json_valid "$REG is not valid JSON"
else
  # Guard: our graph-repos.json lives in the same directory. If registry.json ever grows OUR shape,
  # something clobbered CRG's own file and cross_repo_search will break.
  if [ "$(q 'import json,sys
d=json.load(sys.stdin)
print(int(any("remove" in r or "path" not in r for r in d["registry"])))')" = "1" ]; then
    bad registry.shape "$REG does not look like CRG's registry — did something write a graph-repos.json manifest over it?"
  else
    ok registry.shape "$REG has CRG's shape"
  fi
  while IFS=$'\t' read -r status alias detail; do
    [ -z "$alias" ] && continue
    case "$status" in
      ok) ok registry.entry "$alias registered -> $detail" ;;
      miss) bad registry.entry.missing "$alias is in scope but not registered — re-run sync-cross-repo-graph.sh" ;;
      conflict) bad registry.entry.conflict "$alias is registered to $detail, not the path your manifest declares" ;;
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
  [ "$FOREIGN" != "0" ] && ok registry.foreign "$FOREIGN registry entr(ies) belong to other projects — union by design, untouched"
fi

# ---- graphify merged graph --------------------------------------------------------------------
section "graphify merged graph:"
OUT="$ROOT/graphify-out/merged-graph.json"
NGFY="$(q 'import json,sys
d=json.load(sys.stdin)
print(sum(1 for e in d["effective"] if "graphify" in e["tools"] and e["has_gfy_json"]))')"
if [ "$NGFY" = "0" ]; then
  if [ -f "$OUT" ]; then
    warn merged.orphaned "no in-scope graphify repos, but $OUT exists — stale; remove with: trash \"$OUT\""
  else
    ok merged.consistent "no in-scope graphify repos and no merged graph (consistent)"
  fi
elif [ ! -f "$OUT" ]; then
  bad merged.present "$NGFY in-scope graphify repo(s) but no $OUT — run sync-cross-repo-graph.sh --merge-only"
elif ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUT" 2> /dev/null; then
  bad merged.json_valid "$OUT is not valid JSON — rebuild: sync-cross-repo-graph.sh --merge-only"
else
  ok merged.json_valid "$OUT present and parses ($NGFY repo(s) merged)"
  # Sibling mtimes come from the resolver, which already stat'ed them — re-stat'ing here is how the
  # verifier and the installer drift apart. Only the two paths the resolver does not model (this
  # repo's own graph and the merged output) are stat'ed locally.
  STALE="$(q 'import json,os,sys
d=json.load(sys.stdin)
out=os.path.join(d["root"], "graphify-out", "merged-graph.json")
mt=os.path.getmtime(out)
own=os.path.join(d["root"], "graphify-out", "graph.json")
newer=os.path.exists(own) and os.path.getmtime(own) > mt
newer = newer or any(
    e["gfy_mtime"] and e["gfy_mtime"] > mt
    for e in d["effective"] if "graphify" in e["tools"] and e["has_gfy_json"]
)
print(int(newer))')"
  [ "$STALE" = "1" ] && warn merged.stale "merged graph is older than one of its sources — rebuild: sync-cross-repo-graph.sh --merge-only"
fi
grep -qxF "graphify-out/" "$ROOT/.gitignore" 2> /dev/null || warn gitignore.graphify_out "graphify-out/ is not gitignored — the merged graph would be committed"

# ---- AGENTS.md block --------------------------------------------------------------------------
section "AGENTS.md block:"
if [ -z "$AGENTS_FILE" ]; then
  bad block.agents_md "no AGENTS.md at or above $SCOPE — run initial-project first"
else
  # grep -c already prints 0 on no-match (and exits 1), so `|| echo 0` would append a second 0.
  NB=$(grep -c 'cross-repo:begin' "$AGENTS_FILE" 2> /dev/null) || NB=0
  NE=$(grep -c 'cross-repo:end' "$AGENTS_FILE" 2> /dev/null) || NE=0
  if [ "$NB" = "0" ] && [ "$NE" = "0" ]; then
    if [ "$NEFF" = "0" ]; then
      ok block.present "no cross-repo block and no repos in scope (consistent)"
    else
      bad block.present "$NEFF repo(s) in scope but no cross-repo block in $AGENTS_FILE — run sync-cross-repo-graph.sh"
    fi
  elif [ "$NB" != "1" ] || [ "$NE" != "1" ]; then
    bad block.malformed "malformed cross-repo block in $AGENTS_FILE ($NB begin / $NE end markers) — fix by hand"
  else
    ok block.present "exactly one cross-repo block in $AGENTS_FILE"
    # Drift detector: someone edited a manifest and never re-synced.
    WANT="$(q 'import json,sys
d=json.load(sys.stdin)
print(" ".join(sorted(e["alias"] for e in d["effective"] if e["has_crg_db"] or e["has_gfy_json"])))')"
    HAVE="$(printf '%s' "$BLOCK_ALIASES" | xargs -n1 2> /dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
    if [ "$(printf '%s' "$WANT" | tr -s ' ')" = "$(printf '%s' "$HAVE" | tr -s ' ')" ]; then
      ok block.aliases "block lists exactly the in-scope aliases: ${WANT:-none}"
    else
      bad block.aliases "block drift — block lists [${HAVE:-none}] but the cascade resolves to [${WANT:-none}]; re-run sync-cross-repo-graph.sh"
    fi
    grep -q 'In-scope aliases' "$AGENTS_FILE" 2> /dev/null \
      || warn block.routing_rule "block is missing the in-scope routing rule — it was written by an older version; re-run sync"
  fi
  grep -q 'graph-hooks:begin' "$AGENTS_FILE" 2> /dev/null \
    || warn block.graph_hooks "no graph-hooks block in $AGENTS_FILE — this skill chains after setup-graph-hooks"
fi

# ---- steering: do the hooks actually route a cross-repo grep to the graph? ---------------------
# The regression this exists for: grep-steer used to query only the LOCAL graph, so a grep into a
# sibling missed, and a miss reads as "the graph cannot help" — the hook waved through the one path
# this whole skill exists to prevent. Assert it no longer passes silently.
section "Cross-repo steering:"
STEER="$ROOT/.graph-hooks/core/grep-steer.sh"
if [ ! -f "$STEER" ]; then
  warn steer.present "no .graph-hooks/core/grep-steer.sh — run setup-graph-hooks.sh to get graph-first steering"
else
  if [ -f "$ROOT/.graph-hooks/core/cross-repo-scope.sh" ]; then
    ok steer.cross_repo_scope "grep-steer can see the cross-repo scope"
  else
    bad steer.cross_repo_scope "grep-steer predates cross-repo support (no core/cross-repo-scope.sh) — greps into a sibling will NOT be steered; re-run setup-graph-hooks.sh"
  fi

  # A repo's hooks can be older than its cross-repo scope. That combination silently un-does the
  # fence, so it is worth naming rather than leaving the user to wonder why greps still run.
  if grep -q 'cross-repo paths' "$ROOT/.graph-hooks/core/session-context.sh" 2> /dev/null; then
    warn steer.session_context_stale "the session cheatsheet still tells agents to skip the graph for cross-repo paths — stale hooks; re-run setup-graph-hooks.sh"
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
        *"[$SIB_ALIAS]"*) ok steer.end_to_end "a grep into '$SIB_ALIAS' for '$SYM' is answered from its graph, not left to grep" ;;
        "") bad steer.end_to_end.silent "a grep into '$SIB_ALIAS' passes silently — the graph is not steering the cross-repo path" ;;
        *) bad steer.end_to_end.local_only "grep-steer answered a cross-repo grep without the '$SIB_ALIAS' graph — it searched only the local one" ;;
      esac
    fi
  fi
fi

# ---- tools ------------------------------------------------------------------------------------
section "Graph tools:"
command -v code-review-graph > /dev/null 2>&1 && ok tool.crg "code-review-graph installed" || warn tool.crg "code-review-graph not installed (cross_repo_search unavailable)"
command -v graphify > /dev/null 2>&1 && ok tool.graphify "graphify installed" || warn tool.graphify "graphify not installed (optional)"

if [ "$F" -gt 0 ]; then finish 1; fi
finish 0
