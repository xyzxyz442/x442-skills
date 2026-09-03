#!/usr/bin/env bash
# verify-graph-hooks.sh — confirm the tool-generic graph hooks are installed AND fire.
# Read-only except that exercising the refresh may kick off the (idempotent, locked)
# background graph update. Discovers which tools are wired from their config files and
# fires the shared dispatcher with each tool's stdin shape, exactly as the tool would.
#
# Usage: ./verify-graph-hooks.sh [/path/to/repo] [--json]      (path defaults to current dir)
#
# --json emits every finding as a machine-readable object instead of prose. Most of what this
# checks is ADVISORY by design — a missing copilot hook, a partial embed, a graph that is not
# built, hooks that predate the search-tier ladder — and none of it changes the exit code, so a
# grader reading only the exit status is blind to exactly the checks most likely to rot. This is
# the channel that makes them gradeable.
#
# Every finding carries a STABLE ID. The id names the CHECK and `level` carries the outcome, so a
# grader asserts "embeddings.partial came back warn" rather than matching prose that any future
# rewording breaks. Where two outcomes of one check need different remediation they get different
# ids (payload.version.behind vs payload.version.ahead) — same rule, where it earns itself.
set -uo pipefail

# Resolve this script's own directory to an ABSOLUTE path BEFORE the cd below: payload.version
# lives beside this script, and a bare `dirname "$0"` is relative to the ORIGINAL cwd, so invoking
# the verifier by a relative path made the stamp unreadable and check_payload_version return
# silently — drift reported as nothing at all.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

JSON=0
ARGS=""
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    *) ARGS="$a" ;;
  esac
done
TARGET="${ARGS:-$PWD}"
cd "$TARGET" 2> /dev/null || {
  echo "no such path: $TARGET" >&2
  exit 1
}
ROOT=$(git rev-parse --show-toplevel 2> /dev/null) || {
  echo "ERROR: not a git repo" >&2
  exit 1
}
cd "$ROOT"
export CLAUDE_PROJECT_DIR="$ROOT"

P=0
F=0
W=0
# Findings accumulate as TSV (level, id, section, message) and are rendered once at the end. TSV
# rather than JSON-per-line because bash cannot escape JSON safely and the renderer is python3
# anyway; tabs and newlines are stripped from the message so a field can never break the record.
FINDINGS="$(mktemp)"
SECTION=""
trap 'rm -f "$FINDINGS"' EXIT
# The underline is DERIVED from the title rather than typed beside it -- section 6's hand-typed
# rule was one dash short of its heading, and deriving it is how that stops being possible.
section() { # human header AND the section label every finding below it carries
  SECTION="$1"
  echo
  echo "$1"
  printf '%s\n' "$(printf '%*s' "${#1}" '' | tr ' ' '-')"
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
# In --json mode the prose goes to /dev/null and the JSON document is written to the real stdout at
# the end. Redirecting the fd rather than guarding every echo site keeps ONE rendering path: the
# human output and the findings can never disagree, because they are produced by the same call.
if [ "$JSON" = 1 ]; then
  exec 3>&1 1> /dev/null
fi

# Compare the installed payload stamp against the version this skill ships. A behind-but-working
# install is a WARNING, never a FAIL — it still functions, it just predates a payload change, and
# reserving the non-zero exit for real breakage keeps the harness contract meaningful. Silent when
# the skill's own payload.version is unreadable, which is what happens if the verifier is copied
# somewhere detached from its skill directory: unknown is not the same as behind.
check_payload_version() { # installed-version skill-name   (caller reads the stamp; shapes differ)
  local installed="$1" skill="$2" shipped
  shipped="$(awk 'NR==1{print $2}' "$SCRIPT_DIR/payload.version" 2> /dev/null)"
  [ -n "$shipped" ] || return 0
  if [ -z "$installed" ]; then
    warn payload.version.unknown "payload version unknown (pre-versioning install) — re-run $skill"
  elif [ "$installed" -lt "$shipped" ] 2> /dev/null; then
    warn payload.version.behind "payload v$installed installed, skill ships v$shipped — re-run $skill"
  elif [ "$installed" -gt "$shipped" ] 2> /dev/null; then
    warn payload.version.ahead "payload v$installed installed is newer than the skill's v$shipped — this $skill copy is stale"
  else
    ok payload.version "payload v$installed matches the version $skill ships"
  fi
}

# Two shapes, two names. They used to share the name `is_json` across the verify scripts with
# different argument meanings (a file path in some, a JSON string in others) — one copy-paste away
# from a check that silently always passes.
is_json() { python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1" 2> /dev/null; }
is_json_str() { printf '%s' "$1" | python3 -c "import json,sys; json.load(sys.stdin)" 2> /dev/null; }

# Semantic search is an opt-in tier, so ZERO embeddings is a healthy state, not a defect:
# CRG's semantic_search() falls back to keyword search over node names. Only a half-finished
# embed, or vectors the hooks can no longer refresh, deserve a warning.
check_embeddings() {
  read -r EMB NODES NPROV EPROV EDETAIL <<< "$(
    python3 - << 'PY' 2> /dev/null
import sqlite3


# Status-probe open: plain ro first (the only variant correct on a WAL graph — immutable=1 ignores
# the -wal), immutable=1 only as a fallback for a database needing journal rollback, where a
# read-only open raises CANTOPEN and this check would misreport keyword mode on a repo full of
# live vectors.
def probe_connect(path, timeout=2):
    for extra in ("", "&immutable=1"):
        try:
            c = sqlite3.connect("file:%s?mode=ro%s" % (path, extra), uri=True, timeout=timeout)
            c.execute("SELECT count(*) FROM sqlite_master").fetchone()
            return c
        except sqlite3.Error:
            continue
    raise sqlite3.OperationalError("graph db unreadable")


try:
    c = probe_connect(".code-review-graph/graph.db")
    nodes = c.execute("SELECT count(*) FROM nodes WHERE kind!='File'").fetchone()[0]
    emb = c.execute("SELECT count(*) FROM embeddings").fetchone()[0]
    # EVERY provider, not just the most common one. Reporting only the dominant provider hides a
    # mixed table, which is the failure worth catching: vectors from two models are incomparable,
    # and _cosine_similarity in CRG returns 0.0 on a width mismatch instead of raising, so mixing
    # degrades retrieval silently, with a healthy-looking embedding count.
    # NOTE: no apostrophes or backticks anywhere in this heredoc. It sits inside a $(...), and bash
    # lexes the substitution body for quotes even though the delimiter is quoted, so a lone
    # apostrophe is a syntax error at source time.
    rows = c.execute("SELECT provider, count(*) FROM embeddings GROUP BY provider "
                     "ORDER BY count(*) DESC").fetchall()
    # Fields are whitespace-split by read, and a provider string ("openai:model@host") has no
    # spaces, but it does have colons, so the per-provider detail joins on "|" and "=" instead.
    print(emb, nodes, len(rows),
          (rows[0][0] if rows and rows[0][0] else "-"),
          "|".join(f"{p or '-'}={n}" for p, n in rows) or "-")
except Exception:
    print(0, 0, 0, "-", "-")
PY
  )"

  if [ "${EMB:-0}" = 0 ]; then
    ok embeddings.mode "semantic search: keyword mode (0 embeddings — optional; ./setup-embeddings.sh to enable)"
    return 0
  fi

  # One embedder owns the index. CRG re-embeds a node when its provider identity changes, but a
  # plain `embed` appends and never purges rows written by a previous provider — and each row
  # autocommits, so an interrupted switch leaves the table split. Nothing downstream notices:
  # EmbeddingStore.count() ignores provider, so a search sees "vectors exist", gets zero rows back
  # from its provider-filtered query, and quietly degrades to FTS/keyword. This is a FAIL, not a
  # warning — the graph looks healthy while retrieval is broken.
  if [ "${NPROV:-1}" -gt 1 ]; then
    bad embeddings.providers "semantic search: ${NPROV} embedding providers in one index (${EDETAIL}) — vector families are incomparable and searches silently degrade; fix: re-embed under one provider (./setup-embeddings.sh)"
  elif [ "${EMB:-0}" -lt "${NODES:-0}" ]; then
    warn embeddings.partial "semantic search: ${EMB}/${NODES} nodes embedded — interrupted embed; fix: code-review-graph embed"
  else
    ok embeddings.mode "semantic search: vector mode (${EMB} embeddings, provider=${EPROV})"
  fi

  # Everything else that can be wrong with an embedding setup — the write path disagreeing with the
  # index, an endpoint that stopped answering, a READ path that cannot see the vectors at all — is
  # defined once in .graph-hooks/core/embed-health.sh and merely rendered here. The session-start
  # notice renders that same output, so the verifier and the banner cannot drift apart on what
  # "misconfigured" means, which is exactly what two hand-maintained copies of the comparison did.
  #
  # Optional core, following embed-provider.sh (which this script has always used without
  # presence-checking): an install predating it reports nothing rather than failing.
  #
  # The inline checks this replaces probed "$BASE/api/tags" for liveness — an endpoint only Ollama
  # serves, so a perfectly healthy LM Studio endpoint was reported as "ollama not reachable".
  HEALTH=""
  [ -f .graph-hooks/core/embed-health.sh ] && HEALTH=$(bash .graph-hooks/core/embed-health.sh 2> /dev/null)
  if [ -n "$HEALTH" ]; then
    # A here-doc, not a pipe: `warn` increments a counter the summary reads, and a pipeline would
    # run the loop in a subshell where those increments are discarded.
    TAB=$(printf '\t')
    while IFS="$TAB" read -r _code msg; do
      [ -n "${msg:-}" ] && warn embeddings.health "$msg"
    done << EOF
$HEALTH
EOF
  else
    # The READ path is a different process from the refresh hooks: CRG's OpenAI provider needs
    # CRG_OPENAI_* in the MCP server's own environment, and the tool's `provider` argument defaults
    # to `local` regardless. Health found nothing wrong with that wiring, so say so positively.
    case "$EPROV" in
      openai:* | google:* | minimax:*)
        ok embeddings.read_path "MCP read path configured — call the tool with provider=\"${EPROV%%:*}\" to use these vectors"
        ;;
    esac
  fi
}

echo "Repo: $ROOT"
section "1. Shared layer (.graph-hooks)"
HOOK=".graph-hooks/hook.sh"
if [ -f "$HOOK" ]; then [ -x "$HOOK" ] && ok dispatcher.executable "dispatcher present and executable: $HOOK" || warn dispatcher.executable "$HOOK present but not executable (chmod +x)"; else bad dispatcher.present "dispatcher missing: $HOOK"; fi
for f in core/grep-steer.sh core/read-nudge.sh core/session-context.sh core/graph-refresh.sh core/cross-repo-scope.sh core/extract.py core/emit.py; do
  if [ -f ".graph-hooks/$f" ]; then [ -x ".graph-hooks/$f" ] && ok core.executable "$f present and executable" || warn core.executable "$f present but not executable"; else bad core.present "$f missing"; fi
done
for f in pretool-shell.sh pretool-read.sh sessionstart.sh endturn.sh; do
  [ -f ".graph-hooks/copilot/$f" ] && ok copilot.hooks "copilot/$f present" || warn copilot.hooks "copilot/$f missing (copilot hooks would no-op)"
done
check_payload_version "$(awk 'NR==1{print $2}' .graph-hooks/.version 2> /dev/null)" setup-graph-hooks

# git hook + gitignore
GH=""
[ -f .husky/post-commit ] && GH=.husky/post-commit
[ -z "$GH" ] && [ -f .git/hooks/post-commit ] && GH=.git/hooks/post-commit
if [ -n "$GH" ]; then grep -q 'graph-hooks-managed' "$GH" 2> /dev/null && ok git.post_commit "post-commit installed: $GH" || warn git.post_commit "post-commit exists but no managed marker: $GH"; else warn git.post_commit.missing "no post-commit hook — commit-time refresh won't run"; fi
# tr -d '\r' first: a CRLF .gitignore stores ".code-review-graph/\r", which no whole-line match
# equals, so this warned "missing" on repos that excluded it correctly.
for e in ".code-review-graph/" "graphify-out/"; do tr -d '\r' < .gitignore 2> /dev/null | grep -qxF "$e" && ok gitignore.excludes ".gitignore excludes $e" || warn gitignore.excludes ".gitignore missing $e"; done

section "2. Wired tools + config validity"
WIRED=""
add_wired() { WIRED="${WIRED:+$WIRED }$1"; }
# claude
CSET=""
[ -f .claude/settings.local.json ] && CSET=.claude/settings.local.json
[ -z "$CSET" ] && [ -f .claude/settings.example.json ] && CSET=.claude/settings.example.json
if [ -n "$CSET" ] && grep -q '\-\-tool claude' "$CSET" 2> /dev/null; then
  is_json "$CSET" && {
    ok tool.wired "claude wired + valid JSON: $CSET"
    add_wired claude
  } || bad tool.config.json_valid "claude config invalid JSON: $CSET"
fi
# gemini
if [ -f .gemini/settings.json ] && grep -q '\-\-tool gemini' .gemini/settings.json 2> /dev/null; then
  is_json .gemini/settings.json && {
    ok tool.wired "gemini wired + valid JSON: .gemini/settings.json"
    add_wired gemini
  } || bad tool.config.json_valid "gemini config invalid JSON"
fi
# copilot
if [ -f .github/hooks/graph.json ]; then
  is_json .github/hooks/graph.json && {
    ok tool.wired "copilot wired + valid JSON: .github/hooks/graph.json"
    add_wired copilot
  } || bad tool.config.json_valid "copilot config invalid JSON"
fi
# antigravity (inert by design)
[ -f .agents/hooks.json ] && warn antigravity.active "ACTIVE .agents/hooks.json present — contract is UNVERIFIED; confirm before trusting"
[ -f .agents/hooks.json.example ] && ok antigravity.example "antigravity example present and inert (not activated) — expected"
[ -z "$WIRED" ] && bad tool.any_wired "no tool hooks wired (expected at least one of claude/gemini/copilot)"

section "3. Dispatcher fires per tool"
payload() { # $1=tool $2=kind
  case "$1:$2" in
    copilot:pretool-shell) printf '{"toolArgs":{"command":"grep -rn something src/app.ts"}}' ;;
    copilot:pretool-read) printf '{"toolArgs":{"file_path":"src/app.ts"}}' ;;
    *:pretool-shell) printf '{"tool_input":{"command":"grep -rn something src/app.ts"}}' ;;
    *:pretool-read) printf '{"tool_input":{"file_path":"src/app.ts"}}' ;;
    *) printf '{}' ;;
  esac
}
for t in $WIRED; do
  for k in pretool-shell pretool-read sessionstart; do
    out=$(payload "$t" "$k" | bash "$HOOK" --tool "$t" --kind "$k" 2> /dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      bad hook.fires.exit "$t/$k exited $rc"
    elif [ -z "$out" ]; then
      ok hook.fires "$t/$k ran cleanly (no output — correct with no graph / no match)"
    elif is_json_str "$out"; then
      if printf '%s' "$out" | grep -q '"permissionDecision":"\(deny\|block\)"\|"decision":"deny"'; then
        ok hook.fires "$t/$k emitted a valid BLOCK decision (graph hit)"
      else ok hook.fires "$t/$k emitted valid context JSON"; fi
    else bad hook.fires.invalid_json "$t/$k emitted INVALID JSON: $(printf '%s' "$out" | head -c 60)"; fi
  done
done

section "4. Single refresh owner (no duplicate builds)"
OWNERS=""
grep -q '\-\-kind endturn' "${CSET:-/dev/null}" 2> /dev/null && OWNERS="${OWNERS:+$OWNERS }claude"
grep -q '\-\-kind endturn' .gemini/settings.json 2> /dev/null && OWNERS="${OWNERS:+$OWNERS }gemini"
grep -q 'endturn.sh' .github/hooks/graph.json 2> /dev/null && OWNERS="${OWNERS:+$OWNERS }copilot"
N=$(printf '%s\n' $OWNERS | grep -c . || true)
if [ "${N:-0}" -le 1 ]; then ok refresh.single_owner "exactly ${N:-0} end-of-turn refresh owner${OWNERS:+ ($OWNERS)} — no duplication"; else bad refresh.single_owner "MULTIPLE refresh owners ($OWNERS) — would duplicate the graph build"; fi

# lock smoke test: a held lock makes a second refresh a no-op
KEY="$(pwd | { md5sum 2> /dev/null || md5 2> /dev/null; } | cut -c1-8)"
LK="${TMPDIR:-/tmp}/crg-graph-${KEY:-x}.lock"
if mkdir "$LK" 2> /dev/null; then
  out=$(bash .graph-hooks/core/graph-refresh.sh 2> /dev/null)
  rc=$?
  rmdir "$LK" 2> /dev/null || true
  [ "$rc" = 0 ] && [ -z "$out" ] && ok refresh.lock_dedup "graph-refresh no-ops while the repo-global lock is held" || warn refresh.lock_dedup "graph-refresh unexpected under held lock (rc=$rc)"
else
  warn refresh.lock_dedup.untestable "could not take lock dir to test refresh dedup"
fi

section "5. Tools and graph state"
if command -v code-review-graph > /dev/null 2>&1; then
  ok tool.crg "code-review-graph installed"
  if [ -f .code-review-graph/graph.db ]; then
    ok graph.built "CRG graph built"
    check_embeddings
  else
    warn graph.built "CRG graph not built — run: code-review-graph build (register MCP separately, scoped: --platform <tool> --no-hooks --no-instructions --no-skills)"
  fi
else
  warn tool.crg "code-review-graph not installed (hooks stay silent until it is)"
fi
if command -v graphify > /dev/null 2>&1; then
  ok tool.graphify "graphify installed"
  [ -f graphify-out/graph.json ] && ok graphify.built "graphify graph built" || warn graphify.built "graphify graph not built — run: graphify update ."
else
  warn tool.graphify "graphify not installed (optional)"
fi

section "6. Search-tier marker (vector-first: custom > local > keyword)"
TIERBIN=".graph-hooks/core/embed-provider.sh"
if [ -f "$TIERBIN" ]; then
  TIER="$(bash "$TIERBIN" --tier 2> /dev/null | head -1)"
  case "${TIER%% *}" in
    keyword) ok tier.resolves "search tier resolves: keyword (name match — vectors off; ./setup-embeddings.sh to enable)" ;;
    local) ok tier.resolves "search tier resolves: vector/local (${TIER#* } — read by default)" ;;
    custom) ok tier.resolves "search tier resolves: vector/custom (${TIER#* } — pin provider=\"openai\" to read it)" ;;
    *) bad tier.resolves "embed-provider.sh --tier returned unexpected '$TIER' (want keyword|local|custom)" ;;
  esac
else
  bad tier.provider_script "$TIERBIN missing — session banner + grep pre-answers cannot mark the search tier"
fi
# The AGENTS.md routing block must carry the tier ladder so the agent knows to pin custom vectors,
# and the search_mode rule so it can tell a degraded answer from a good one. Each sentinel marks a
# revision of the asset; a block missing one predates it and step 5 of the skill will refresh it.
if [ -f AGENTS.md ] && grep -q 'graph-hooks:begin' AGENTS.md 2> /dev/null; then
  grep -qi 'search tier' AGENTS.md 2> /dev/null \
    && ok block.search_tier "AGENTS.md routing block documents the search-tier ladder" \
    || warn block.search_tier "AGENTS.md graph-hooks block predates the search-tier ladder — re-run setup-graph-hooks to refresh it"
  grep -q 'search_mode' AGENTS.md 2> /dev/null \
    && ok block.search_mode "AGENTS.md routing block documents the search_mode honesty rule" \
    || warn block.search_mode "AGENTS.md graph-hooks block predates the search_mode rule (routing still reads as a CRG->graphify->grep chain) — re-run setup-graph-hooks to refresh it"
fi

echo
echo "Summary: $P passed, $W warnings, $F failed"

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
    "tool": "verify-graph-hooks",
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
if [ "$F" -gt 0 ]; then exit 1; fi
exit 0
