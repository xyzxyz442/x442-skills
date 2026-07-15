#!/usr/bin/env bash
# sync-cross-repo-graph.sh — hydrate this project's cross-repo graph scope from the
# .graph-repos.json cascade, and rewrite the AGENTS.md <!-- cross-repo --> block in place.
#
#   ./sync-cross-repo-graph.sh [/path/to/repo-or-subdir] [--tools crg,graphify]
#                              [--build never|missing|force] [--prune] [--merge-only]
#                              [--no-agents] [--agents-file <path>] [--dry-run]
#
#     --tools        which tool paths to hydrate            (default: crg,graphify)
#     --build        foreign graph missing: never | missing | force   (default: never)
#                    `never` only PRINTS the build command — building writes into someone
#                    else's checkout, so the skill offers it; this script never forces it.
#     --prune        also unregister aliases THIS repo registered that have left the scope
#     --merge-only   rebuild the graphify merged graph and nothing else
#     --no-agents    skip the AGENTS.md block
#     --dry-run      print what would change; write nothing; always exit 0
#
# ADDITIVE BY DESIGN. CRG's registry (~/.code-review-graph/registry.json) is machine-global and
# shared with your other projects. We only ever ADD to it and never unregister an entry we did not
# register. Scope is therefore enforced IN CONTEXT — by the in-scope alias list in the AGENTS.md
# block — not by the registry. graphify sidesteps the problem entirely with a per-project merged
# graph at <root>/graphify-out/merged-graph.json.
#
# Idempotent: re-runnable, byte-compares before writing, never deletes a repo's files.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
TARGET="$PWD"
TOOLS="crg,graphify"
BUILD="never"
PRUNE=0
MERGE_ONLY=0
AGENTS=1
AGENTS_FILE=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tools)
      TOOLS="${2:-}"
      shift 2
      ;;
    --build)
      BUILD="${2:-}"
      shift 2
      ;;
    --agents-file)
      AGENTS_FILE="${2:-}"
      shift 2
      ;;
    --tools=*)
      TOOLS="${1#*=}"
      shift
      ;;
    --build=*)
      BUILD="${1#*=}"
      shift
      ;;
    --agents-file=*)
      AGENTS_FILE="${1#*=}"
      shift
      ;;
    --prune)
      PRUNE=1
      shift
      ;;
    --merge-only)
      MERGE_ONLY=1
      shift
      ;;
    --no-agents)
      AGENTS=0
      shift
      ;;
    --dry-run)
      DRY=1
      shift
      ;;
    -*)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
    *)
      TARGET="$1"
      shift
      ;;
  esac
done
case "$BUILD" in never | missing | force) : ;; *)
  echo "ERROR: --build must be never|missing|force" >&2
  exit 2
  ;;
esac
want() { case ",$TOOLS," in *",$1,"*) return 0 ;; *) return 1 ;; esac }
want crg || want graphify || {
  echo "ERROR: --tools must include crg and/or graphify" >&2
  exit 2
}

cd "$TARGET"
ROOT=$(git rev-parse --show-toplevel 2> /dev/null) || {
  echo "ERROR: '$TARGET' is not inside a git repository." >&2
  exit 1
}
SCOPE="$PWD"
RC=0
say() { [ "$DRY" = 1 ] && printf '  would: %s\n' "$1" || printf '  %s\n' "$2"; }

# ---- resolve the cascade (the shared brain: the verifier calls the same resolver) ------------
EFF="$(python3 "$HERE/manifest/resolve.py" --scope "$SCOPE" --root "$ROOT")" || RC=1
q() { printf '%s' "$EFF" | python3 -c "$1" "${@:2}"; }

echo "Repo:  $ROOT"
echo "Scope: $(q 'import json,sys;print(json.load(sys.stdin)["scope_rel"])')"
echo "Tools: $TOOLS"
echo

# CRG's home holds its registry, its lock, and the USER layer of our cascade. It may not exist yet
# on a fresh machine (CRG creates it lazily on first register), so create it up front rather than
# as a side effect of taking the lock — otherwise the user layer has nowhere to live.
CRG_HOME="$(dirname "$(q 'import json,sys;print(json.load(sys.stdin)["registry_path"])')")"
USER_MANIFEST="$CRG_HOME/graph-repos.json"
if [ ! -d "$CRG_HOME" ]; then
  say "mkdir -p $CRG_HOME" "+ $CRG_HOME created"
  [ "$DRY" = 0 ] && mkdir -p "$CRG_HOME"
fi

echo "Manifest cascade (user -> project -> subdir; nearest wins):"
q 'import json,sys
d=json.load(sys.stdin)
for l in d["layers"]:
    print("  %s %-8s %s" % ("+" if l["present"] else "-", l["layer"], l["file"]))'

if [ "$(q 'import json,sys;print(sum(1 for l in json.load(sys.stdin)["layers"] if l["present"]))')" = "0" ]; then
  echo
  echo "No .graph-repos.json anywhere in the cascade — nothing to sync."
  echo "Bootstrap one:"
  echo "    # project layer — committed, team-shared (the usual choice)"
  echo "    cp \"$SKILL/assets/graph-repos.example.json\" \"$ROOT/.graph-repos.json\""
  echo "    # user layer — personal, visible to every project on this machine"
  echo "    cp \"$SKILL/assets/graph-repos.example.json\" \"$USER_MANIFEST\""
  echo "Then edit it and re-run this script."
  exit 0
fi

echo
echo "Effective scope:"
q 'import json,sys
d=json.load(sys.stdin)
for e in d["effective"]:
    print("  = %-24s %s  [%s]" % (e["alias"], e["path"], e["layer"]))
for e in d["dead"]:
    print("  ! %-24s %s  MISSING (declared in %s)" % (e["alias"], e["path"], e["manifest"]))
for s in d["shadowed"]:
    print("  ~ %s overridden by the %s layer (was %s)" % (s["alias"], s["by_layer"], s["was_layer"]))
for t in d["tombstones"]:
    print("  - %s removed by the %s layer" % (t["alias"], t["layer"]))
for w in d["warnings"]:
    print("  [warn] %s" % w)
for x in d["errors"]:
    print("  [ERROR] %s" % x)'

CONFIRMED=""
MERGED=""

# ---- CRG phase (additive; locked, because `register` read-modify-writes one global file) ------
crg_registry() { printf '%s' "$EFF" | python3 -c 'import json,sys;print(json.load(sys.stdin)["registry_path"])'; }
LOCK="$(dirname "$(crg_registry)")/.sync.lock"
lock_acquire() {
  mkdir -p "$(dirname "$LOCK")" 2> /dev/null || return 1
  for _ in $(seq 1 50); do
    mkdir "$LOCK" 2> /dev/null && return 0
    sleep 0.1
  done
  return 1
}
lock_release() { rmdir "$LOCK" 2> /dev/null || true; }

if [ "$MERGE_ONLY" = 0 ] && want crg; then
  echo
  echo "code-review-graph (registry is a machine-global union — we only add):"
  if ! command -v code-review-graph > /dev/null 2>&1; then
    echo "  [warn] code-review-graph not installed — skipping the CRG path"
  elif [ "$DRY" = 0 ] && ! lock_acquire; then
    echo "  [warn] another sync holds $LOCK — skipping the CRG path"
  else
    trap lock_release EXIT
    while IFS=$'\t' read -r alias fpath has_db; do
      [ -z "$alias" ] && continue

      if [ "$has_db" != "1" ] && [ "$BUILD" != "never" ]; then
        say "code-review-graph build --repo $fpath" "building $alias …"
        [ "$DRY" = 0 ] && { code-review-graph build --repo "$fpath" > /dev/null 2>&1 || true; }
        [ -f "$fpath/.code-review-graph/graph.db" ] && has_db=1
      fi

      # cross_repo_search_tool SILENTLY SKIPS a registered repo whose graph.db is absent, so
      # registering one would put an alias in AGENTS.md that can never answer. Don't.
      if [ "$has_db" != "1" ]; then
        echo "  ! $alias PENDING — no graph yet, not registered and not listed in AGENTS.md"
        echo "      build it:  code-review-graph build --repo \"$fpath\""
        RC=1
        continue
      fi

      held="$(printf '%s' "$EFF" | python3 -c '
import json,sys
d=json.load(sys.stdin)
a=sys.argv[1]
print(next((r.get("path","") for r in d["registry"] if r.get("alias")==a), ""))' "$alias")"

      if [ "$held" = "$fpath" ]; then
        echo "  = $alias already registered"
      elif [ -n "$held" ]; then
        # The registry is a union we do not own. Another project holds this alias — never clobber.
        echo "  ! $alias is registered to $held by another project — rename the alias in your manifest"
        RC=1
        continue
      else
        say "code-review-graph register $fpath --alias $alias" "+ $alias registered"
        [ "$DRY" = 0 ] && code-review-graph register "$fpath" --alias "$alias" > /dev/null
      fi

      # A sibling refreshes its own graph.db only if setup-graph-hooks wired a post-commit hook
      # there. Without it, its graph silently drifts behind its code and our cross-repo reads go
      # stale — grep-steer now advises-not-denies on a stale sibling, but the block still advertises
      # an alias that answers from an out-of-date graph. Name the two ways to keep it current now,
      # rather than let the user discover the drift as a [warn]/[FAIL] in the verifier later.
      if [ ! -d "$fpath/.graph-hooks" ]; then
        echo "  [warn] $alias has no .graph-hooks/ — nothing refreshes its graph, so it will drift stale"
        echo "      keep it fresh: run setup-graph-hooks in $fpath, or add it to CRG's watch daemon:"
        echo "      code-review-graph daemon add \"$fpath\""
      fi
      CONFIRMED="${CONFIRMED:+$CONFIRMED,}$alias"
    done <<< "$(q 'import json,sys
d=json.load(sys.stdin)
for e in d["effective"]:
    if "crg" in e["tools"]:
        print("%s\t%s\t%s" % (e["alias"], e["path"], int(e["has_crg_db"])))')"

    if [ "$PRUNE" = 1 ]; then
      STATE="$ROOT/.code-review-graph/cross-repo-state.json"
      if [ -f "$STATE" ]; then
        while IFS= read -r gone; do
          [ -z "$gone" ] && continue
          say "code-review-graph unregister $gone" "- $gone unregistered (left this repo's scope)"
          [ "$DRY" = 0 ] && code-review-graph unregister "$gone" > /dev/null 2>&1 || true
        done <<< "$(python3 -c '
import json,sys
# Only ever prune what THIS repo registered — never another project unregisters entry.
state=json.load(open(sys.argv[1]))
keep={a for a in sys.argv[2].split(",") if a}
for r in state.get("crg_registered", []):
    if r["alias"] not in keep:
        print(r["alias"])' "$STATE" "$CONFIRMED")"
      fi
    fi
    lock_release
    trap - EXIT
  fi
fi

# ---- graphify phase (per-project merged graph — no shared global state) -----------------------
if want graphify; then
  echo
  echo "graphify (per-project merged graph):"
  if ! command -v graphify > /dev/null 2>&1; then
    echo "  [warn] graphify not installed — skipping the graphify path"
  elif [ ! -f "$ROOT/graphify-out/graph.json" ]; then
    echo "  [warn] this repo has no graphify-out/graph.json — build it first: graphify update ."
  else
    SRCS=""
    MERGED=""
    while IFS=$'\t' read -r alias gjson; do
      [ -z "$alias" ] && continue
      SRCS="$SRCS \"$gjson\""
      MERGED="${MERGED:+$MERGED,}$alias"
    done <<< "$(q 'import json,sys
d=json.load(sys.stdin)
for e in d["effective"]:
    if "graphify" in e["tools"] and e["has_gfy_json"]:
        print("%s\t%s" % (e["alias"], e["gfy_json"]))')"

    # Foreign graphify graph missing: report it, and offer/obey --build (AST-only, no LLM cost).
    while IFS= read -r miss; do
      [ -z "$miss" ] && continue
      if [ "$BUILD" != "never" ]; then
        say "graphify update $miss" "building graphify graph for $miss …"
        [ "$DRY" = 0 ] && { graphify update "$miss" > /dev/null 2>&1 || true; }
      else
        echo "  ! $miss has no graphify-out/graph.json — not merged"
        echo "      build it:  graphify update \"$miss\""
      fi
    done <<< "$(q 'import json,sys
d=json.load(sys.stdin)
for e in d["effective"]:
    if "graphify" in e["tools"] and not e["has_gfy_json"]:
        print(e["path"])')"

    OUT="$ROOT/graphify-out/merged-graph.json"
    if [ -z "$MERGED" ]; then
      echo "  = no in-scope graphify repos — nothing to merge"
      [ -f "$OUT" ] && echo "      stale merged graph left behind; remove with: trash \"$OUT\""
    else
      # Rebuilt from scratch every run: a pure function of its inputs, so idempotency is structural.
      say "graphify merge-graphs <own> $MERGED --out $OUT" "~ merged graph: this repo + $MERGED"
      [ "$DRY" = 0 ] && eval graphify merge-graphs "\"$ROOT/graphify-out/graph.json\"" $SRCS --out "\"$OUT\"" > /dev/null
    fi
  fi
fi

# ---- AGENTS.md block, rewritten in place from what we CONFIRMED (never from intent) ----------
if [ "$AGENTS" = 1 ] && [ "$MERGE_ONLY" = 0 ]; then
  echo
  echo "AGENTS.md:"
  if [ -z "$AGENTS_FILE" ]; then
    d="$SCOPE"
    while [ "$d" != "$(dirname "$ROOT")" ] && [ -n "$d" ]; do
      [ -f "$d/AGENTS.md" ] && {
        AGENTS_FILE="$d/AGENTS.md"
        break
      }
      [ "$d" = "$ROOT" ] && break
      d="$(dirname "$d")"
    done
    [ -z "$AGENTS_FILE" ] && AGENTS_FILE="$ROOT/AGENTS.md"
  fi

  # A subdir layer scopes ONE package. Folding its repos into the root AGENTS.md would leak that
  # scope repo-wide and make the block thrash between packages. Refuse instead.
  SUBDIR_ENTRIES="$(q 'import json,sys
d=json.load(sys.stdin)
print(sum(1 for e in d["effective"] if e["layer"] not in ("user","project")))')"
  if [ "$SUBDIR_ENTRIES" != "0" ] && [ "$AGENTS_FILE" = "$ROOT/AGENTS.md" ] && [ "$SCOPE" != "$ROOT" ]; then
    echo "  ! $SCOPE contributes subdirectory-scoped repos but has no AGENTS.md of its own."
    echo "    Writing them to the root AGENTS.md would leak package scope repo-wide. Either:"
    echo "      - create $SCOPE/AGENTS.md, or"
    echo "      - move those entries to $ROOT/.graph-repos.json and sync from the root."
    RC=1
  else
    DRYF=""
    [ "$DRY" = 1 ] && DRYF="--dry-run"
    printf '%s' "$EFF" | python3 "$HERE/manifest/render.py" \
      --template "$SKILL/assets/agents-cross-repo.md" --file "$AGENTS_FILE" \
      --confirmed "$CONFIRMED" --merged "$MERGED" $DRYF || RC=1
  fi
fi

# ---- state: the ledger of what THIS repo owns in the global registry ------------------------
# It ACCUMULATES: an alias that leaves the scope stays in the ledger, because that is the only
# record that we — not another project — put it in the registry. Without that memory --prune would
# have nothing to act on. --prune is what settles the ledger back down to the current scope.
if [ "$DRY" = 0 ] && [ "$MERGE_ONLY" = 0 ]; then
  mkdir -p "$ROOT/.code-review-graph"
  printf '%s' "$EFF" | python3 -c '
import json,os,sys
d=json.load(sys.stdin)
conf={a for a in sys.argv[1].split(",") if a}
merged={a for a in sys.argv[2].split(",") if a}
path, pruned = sys.argv[3], sys.argv[4] == "1"

owned = {}
if os.path.exists(path):
    try:
        for r in json.load(open(path)).get("crg_registered", []):
            owned[r["alias"]] = r["path"]
    except Exception:
        pass
for e in d["effective"]:
    if e["alias"] in conf:
        owned[e["alias"]] = e["path"]
if pruned:  # --prune just unregistered everything outside the current scope
    owned = {a: p for a, p in owned.items() if a in conf}

state = {
  "version": 1,
  "scope": d["scope_rel"],
  "in_scope_aliases": sorted(conf | merged),
  "crg_registered": [{"alias": a, "path": p} for a, p in sorted(owned.items())],
  "graphify_merged": sorted(merged),
}
with open(path, "w") as f:
    json.dump(state, f, indent=2); f.write("\n")
' "$CONFIRMED" "$MERGED" "$ROOT/.code-review-graph/cross-repo-state.json" "$PRUNE"
fi

echo
if [ "$DRY" = 1 ]; then
  echo "Dry run — nothing was written."
  exit 0
fi
echo "In scope: ${CONFIRMED:-none} (CRG) · ${MERGED:-none} (graphify merged graph)"
[ "$RC" != 0 ] && echo "Some entries need attention (see ! lines above)."
echo "Done. Re-run any time — this script is idempotent. Verify with: ./verify-cross-repo-graph.sh"
exit "$RC"
