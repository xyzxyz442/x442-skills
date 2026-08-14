#!/usr/bin/env bash
# setup-embeddings.sh — opt in to semantic search for the code knowledge graph.
#
# Embeddings are optional. Without them `semantic_search_nodes_tool` falls back to keyword
# search over node names, which is a quality difference, not an availability one. Enabling them
# costs either a ~2 GB PyTorch install (local provider) or a running model server holding a
# multi-GB model. Neither is imposed: this script is never called by setup-graph-hooks.sh.
#
# Any OpenAI-compatible server works. Ollama (:11434) and LM Studio (:1234) are auto-detected and
# offered by name; anything else is reachable with --provider openai --base-url URL.
#
# Usage:
#   ./setup-embeddings.sh                       interactive menu (TTY) / --list (non-TTY)
#   ./setup-embeddings.sh --list                print detected state, change nothing
#   ./setup-embeddings.sh --provider ollama   [--model NAME] [--base-url URL]
#   ./setup-embeddings.sh --provider lmstudio [--model NAME] [--base-url URL]
#   ./setup-embeddings.sh --provider openai    --base-url URL [--model NAME]
#   ./setup-embeddings.sh --provider local  [--model HF_ID]
#   ./setup-embeddings.sh --provider off        stop refreshing vectors
#   ./setup-embeddings.sh --yes                 assume yes for install prompts
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2> /dev/null) || {
  echo "ERROR: not a git repo" >&2
  exit 1
}
cd "$ROOT" || exit 1

CFG=".code-review-graph/embed.env"
PROBE=".graph-hooks/core/embed-provider.sh"
[ -f "$PROBE" ] || PROBE="$(cd "$(dirname "$0")" && pwd)/graph-hooks/core/embed-provider.sh"

DEFAULT_OLLAMA_MODEL="qwen3-embedding"
DEFAULT_LOCAL_MODEL="all-MiniLM-L6-v2"

PROVIDER=""
MODEL=""
BASE_URL=""
ASSUME_YES=0
LIST_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST_ONLY=1 ;;
    --provider)
      PROVIDER="${2:-}"
      shift
      ;;
    --model)
      MODEL="${2:-}"
      shift
      ;;
    --base-url)
      BASE_URL="${2:-}"
      shift
      ;;
    --yes | -y) ASSUME_YES=1 ;;
    -h | --help)
      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# ---- detection ------------------------------------------------------------------------

# Any OpenAI-compatible server will do, because CRG only ever speaks /v1/embeddings to it. What
# differs between them is how you ask "which of your models can embed?" — /v1/models answers with
# bare ids and no type, and a name-substring guess would both miss models and invent false ones. So
# each flavor gets its own listing call, and every step after that is identical:
#
#   ollama    /api/tags + /api/show  ->  capabilities contains "embedding"
#   lmstudio  /api/v0/models         ->  type == "embeddings"
#   openai    /v1/models             ->  untyped; the user picks from everything
#
# Probe the HTTP API, never a vendor CLI — the API is what CRG will actually call.
TAB=$(printf '\t')

# A bare host:port is legal in OLLAMA_HOST but is not a URL.
normalize_base() {
  case "$1" in
    http://* | https://*) printf '%s' "${1%/}" ;;
    *) printf 'http://%s' "${1%/}" ;;
  esac
}

ollama_base() {
  [ -n "${OLLAMA_HOST:-}" ] && {
    normalize_base "$OLLAMA_HOST"
    return 0
  }
  printf 'http://localhost:11434'
}

OLLAMA_BASE="$(ollama_base)"
LMSTUDIO_BASE="http://localhost:1234"

# Which flavor answers here, if any. Order is load-bearing and counter-intuitive:
#
#   /api/v0/models  is served ONLY by LM Studio (Ollama 404s), so it must be asked FIRST.
#   /api/tags       looks Ollama-specific but is not — LM Studio ships an Ollama-compatibility
#                   shim that answers it 200 with an empty model list. Probing it first therefore
#                   misidentifies LM Studio as Ollama and then finds none of its models.
#   /v1/models      every OpenAI-compatible server answers, so it is the last resort.
endpoint_flavor() {
  curl -sf --max-time 2 "$1/api/v0/models" > /dev/null 2>&1 && {
    printf 'lmstudio'
    return 0
  }
  curl -sf --max-time 2 "$1/api/tags" > /dev/null 2>&1 && {
    printf 'ollama'
    return 0
  }
  curl -sf --max-time 2 "$1/v1/models" > /dev/null 2>&1 && {
    printf 'openai'
    return 0
  }
  return 1
}

# The key each server conventionally expects. None of them authenticate a localhost caller, but CRG
# raises ValueError on an empty key, so something has to be there.
flavor_key() {
  case "$1" in
    ollama) printf 'ollama' ;;
    lmstudio) printf 'lm-studio' ;;
    *) printf 'local' ;;
  esac
}

endpoint_models() { # $1=base  $2=flavor  -> embedding-capable model names, one per line
  case "$2" in
    ollama)
      names=$(curl -sf --max-time 2 "$1/api/tags" 2> /dev/null \
        | python3 -c 'import json,sys; [print(m["name"]) for m in json.load(sys.stdin).get("models",[])]' 2> /dev/null)
      [ -z "$names" ] && return 0
      for n in $names; do
        caps=$(curl -sf --max-time 5 "$1/api/show" \
          -H 'Content-Type: application/json' -d "{\"model\":\"$n\"}" 2> /dev/null \
          | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin).get("capabilities") or []))' 2> /dev/null)
        case ",$caps," in *,embedding,*) printf '%s\n' "$n" ;; esac
      done
      ;;
    lmstudio)
      curl -sf --max-time 3 "$1/api/v0/models" 2> /dev/null \
        | python3 -c 'import json,sys; [print(m["id"]) for m in json.load(sys.stdin).get("data",[]) if m.get("type")=="embeddings"]' 2> /dev/null
      ;;
    *)
      curl -sf --max-time 3 "$1/v1/models" 2> /dev/null \
        | python3 -c 'import json,sys; [print(m["id"]) for m in json.load(sys.stdin).get("data",[])]' 2> /dev/null
      ;;
  esac
}

# Every reachable endpoint as `base<TAB>flavor<TAB>model,model`. An explicit --base-url is probed
# first so a deliberate choice takes the menu's first slot.
discover_endpoints() {
  seen=""
  cands="$OLLAMA_BASE $LMSTUDIO_BASE"
  [ -n "$BASE_URL" ] && cands="$(normalize_base "$BASE_URL") $cands"
  for b in $cands; do
    case "$seen" in *"|$b|"*) continue ;; esac
    seen="$seen|$b|"
    f=$(endpoint_flavor "$b") || continue
    m=$(endpoint_models "$b" "$f" | paste -sd, - 2> /dev/null)
    printf '%s%s%s%s%s\n' "$b" "$TAB" "$f" "$TAB" "${m:-}"
  done
}

# Ask CRG's own interpreter, via its shebang, whether sentence-transformers is importable.
# find_spec resolves metadata without importing torch — the whole point of this file.
sentence_transformers_present() {
  crg=$(command -v code-review-graph 2> /dev/null) || return 1
  py=$(head -1 "$crg" 2> /dev/null | sed 's/^#!//')
  [ -x "$py" ] || return 1
  "$py" -c 'import importlib.util,sys; sys.exit(0 if importlib.util.find_spec("sentence_transformers") else 1)' 2> /dev/null
}

current_provider() { bash "$PROBE" 2> /dev/null; }

print_list() {
  found=0
  while IFS="$TAB" read -r b f m; do
    [ -z "$b" ] && continue
    found=$((found + 1))
    echo "endpoint=$b flavor=$f models=${m:-}"
  done << EOF
$(discover_endpoints)
EOF
  [ "$found" = 0 ] && echo "endpoint="
  sentence_transformers_present && echo "sentence_transformers=yes" || echo "sentence_transformers=no"
  cur=$(current_provider)
  echo "current=${cur:-none}"
}

if [ "$LIST_ONLY" = 1 ]; then
  print_list
  exit 0
fi

# ---- apply ----------------------------------------------------------------------------

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$1"
  read -r a
  case "$a" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

write_cfg() {
  mkdir -p .code-review-graph
  printf '%s\n' "$1" > "$CFG"
  echo "  + $CFG"
  # .code-review-graph/.gitignore already contains '*', so this is untracked by construction.
}

# embed.env feeds the WRITE path (the refresh hooks). The READ path is the MCP server, a
# separate long-lived process that never sees it: CRG's OpenAI provider raises ValueError
# without CRG_OPENAI_*, so semantic_search silently answers in keyword mode and the vectors we
# just wrote are never read. Mirror the config into .mcp.json's env block to close that.
#
# Only for a localhost endpoint. .mcp.json is committed, so a hosted provider's real API key
# must never be written here — we print instructions instead.
sync_mcp_env() {
  base="$1" model="$2" key="$3"
  case "$base" in
    *localhost* | *127.0.0.1*) ;;
    *)
      echo
      echo "NOTE: $base is not localhost, so the API key is not written to any MCP config."
      echo "      Export CRG_OPENAI_BASE_URL / CRG_OPENAI_API_KEY / CRG_OPENAI_MODEL in the"
      echo "      environment that launches the MCP server, or semantic search stays keyword-only."
      return 0
      ;;
  esac
  if [ ! -f .mcp.json ] && [ ! -f .vscode/mcp.json ]; then
    echo
    echo "NOTE: no .mcp.json or .vscode/mcp.json here. Give the MCP server"
    echo "      CRG_OPENAI_BASE_URL=$base/v1, CRG_OPENAI_API_KEY=$key, CRG_OPENAI_MODEL=$model —"
    echo "      otherwise it reads keyword mode."
    return 0
  fi
  python3 - "$base/v1" "$model" "$key" << 'PY'
import json, os, sys
base, model, key = sys.argv[1], sys.argv[2], sys.argv[3]
# The same server, described by two schemas: .mcp.json nests it under "mcpServers", VS Code's
# .vscode/mcp.json under "servers". Either process can be the one actually serving semantic_search,
# so both are kept in step — when they disagree, the winner reads vectors from an endpoint that
# never wrote them and quietly answers in keyword mode.
for path, top in ((".mcp.json", "mcpServers"), (".vscode/mcp.json", "servers")):
    if not os.path.exists(path):
        continue
    try:
        with open(path) as f:
            cfg = json.load(f)
    except (OSError, ValueError) as exc:
        print("  ! %s unreadable (%s) — left alone" % (path, exc))
        continue
    srv = (cfg.get(top) or {}).get("code-review-graph")
    if not isinstance(srv, dict):
        print("  = %s has no code-review-graph server — skipped" % path)
        continue
    env = srv.setdefault("env", {})
    env.update({
        "CRG_OPENAI_BASE_URL": base,
        "CRG_OPENAI_API_KEY": key,
        "CRG_OPENAI_MODEL": model,
    })
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    print("  ~ %s env updated for the MCP read path" % path)
PY
  echo
  echo "IMPORTANT: restart the MCP server (or your editor) to pick up the new env."
  echo "Then call the tool with the provider pinned — CRG defaults to 'local' and would"
  echo "otherwise ignore these vectors entirely:"
  echo "    semantic_search_nodes_tool(query=..., provider=\"openai\", model=\"$model\")"
}

# The local provider needs no env anywhere: CRG's default provider IS local, so the MCP server
# picks the vectors up with no extra wiring. Strip any Ollama env we previously injected.
unsync_mcp_env() {
  python3 - << 'PY'
import json, os
for path, top in ((".mcp.json", "mcpServers"), (".vscode/mcp.json", "servers")):
    if not os.path.exists(path):
        continue
    try:
        with open(path) as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        continue
    srv = (cfg.get(top) or {}).get("code-review-graph")
    if not isinstance(srv, dict):
        continue
    env = srv.get("env") or {}
    stale = [k for k in env if k.startswith("CRG_OPENAI_")]
    if not stale:
        continue
    for k in stale:
        del env[k]
    if not env:
        srv.pop("env", None)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    print("  ~ %s env cleaned" % path)
PY
}

# One embedder owns the index. CRG re-embeds any node whose provider identity changed, so a
# COMPLETE switch converges by itself — but every row autocommits, so an INTERRUPTED switch leaves
# the table split between two embedders. That state is the dangerous one: vectors from different
# models are incomparable, EmbeddingStore.count() ignores provider, so a later search sees "vectors
# exist", gets nothing back from its provider-filtered query, and quietly degrades to FTS/keyword
# with no error. Clearing first turns that failure mode into a partial single-provider index, which
# verify-graph-hooks.sh reports honestly as an interrupted embed.
#
# CRG refresh_embeddings() is deliberately NOT the tool here: it refuses when the recorded identity
# differs from the requested one ("Refresh never silently migrates an index to another model or
# endpoint"), which is precisely what a provider switch is. It guards same-identity refreshes;
# migrating between embedders is ours to do.
purge_foreign_vectors() { # $1=provider  $2=model — drop vectors no longer comparable with these
  [ -f .code-review-graph/graph.db ] || return 0
  python3 - "$1" "$2" << 'PY'
import sqlite3, sys

want = "%s:%s" % (sys.argv[1], sys.argv[2])
try:
    c = sqlite3.connect(".code-review-graph/graph.db", timeout=5)
    rows = c.execute("SELECT provider, count(*) FROM embeddings GROUP BY provider").fetchall()
except sqlite3.Error as exc:
    # A missing embeddings table is a genuine no-op: nothing has been embedded yet. Anything
    # else — overwhelmingly a write lock held by the background refresh, which blocks reads too
    # under an exclusive transaction — means we cannot tell whether foreign vectors are present.
    # Guessing "none" would wave the embed through into a split index, so refuse instead.
    if "no such table" in str(exc).lower():
        sys.exit(0)
    sys.stderr.write("  ! could not read the existing vectors: %s\n" % exc)
    sys.exit(1)
foreign = [(p or "-", n) for p, n in rows if not (p or "").startswith(want)]
if rows and foreign:
    total = sum(n for _, n in rows)
    detail = ", ".join("%s (%d)" % (p, n) for p, n in foreign)
    # A FAILED clear must not read as a successful one. The likeliest cause is a background
    # refresh holding the write lock, and embedding into a table we did not manage to clear
    # produces exactly the split index this whole step exists to prevent.
    try:
        c.execute("DELETE FROM embeddings")
        c.commit()
    except sqlite3.Error as exc:
        sys.stderr.write("  ! could not clear the existing vectors: %s\n" % exc)
        sys.exit(1)
    print("  ~ cleared %d vector(s) written by a different embedder: %s" % (total, detail))
    print("    they cannot be compared with %s vectors, so every node is re-embedded" % want)
c.close()
PY
}

# Delegate to the hooks' own gate rather than calling `code-review-graph embed` directly: it is
# the single place that loads embed.env into the environment (CRG raises ValueError without
# CRG_OPENAI_*), so the first embed exercises exactly the path every later refresh takes.
first_embed() { # $1=provider  $2=model
  purge_foreign_vectors "$1" "$2" || {
    echo
    echo "Refusing to embed: vectors from a different embedder are still in the index." >&2
    echo "Something else is probably writing the graph right now (the end-of-turn refresh" >&2
    echo "runs its embed in the background). Wait for it to finish, then re-run this." >&2
    exit 1
  }
  echo
  echo "Running the first embed in the foreground so you see it succeed or fail."
  bash "$PROBE" --run || {
    echo
    echo "Embed failed. The graph still answers in keyword mode; nothing is broken." >&2
    exit 1
  }
}

apply_off() {
  if [ -f "$CFG" ]; then
    if command -v trash > /dev/null 2>&1; then trash "$CFG"; else mv "$CFG" "$CFG.disabled"; fi
    echo "  - $CFG removed"
  fi
  unsync_mcp_env
  echo "Semantic search disabled. Existing vectors are left in place but will no longer refresh."
  echo "Run verify-graph-hooks.sh to see them reported as stale."
}

apply_local() {
  m="${MODEL:-$DEFAULT_LOCAL_MODEL}"
  if ! sentence_transformers_present; then
    echo "The local provider needs sentence-transformers (pulls PyTorch, roughly 2 GB)."
    echo "  pipx inject code-review-graph sentence-transformers"
    confirm "Install it now?" || {
      echo "Skipped. Nothing changed."
      exit 0
    }
    pipx inject code-review-graph sentence-transformers || {
      echo "Install failed." >&2
      exit 1
    }
  fi
  echo "Provider: local (model $m)"
  echo "First run downloads the model (~90 MB) into ~/.cache/huggingface."
  cfg="CRG_EMBEDDING_PROVIDER=local"
  [ -n "$MODEL" ] && cfg="$cfg
CRG_EMBEDDING_MODEL=$m"
  write_cfg "$cfg"
  unsync_mcp_env
  first_embed local "$m"
  echo
  echo "The MCP server defaults to the local provider, so semantic_search_nodes_tool picks these"
  echo "vectors up with no further configuration."
}

# One apply path for every OpenAI-compatible backend. Only model DISCOVERY is flavor-specific
# (endpoint_models above); the config written, the purge, the embed and the read-path sync are
# identical — so there is exactly one place where switching providers can go wrong, and it is
# exercised the same way no matter which backend you pick.
apply_endpoint() { # $1=base  $2=flavor
  base="$1" flavor="$2"
  key=$(flavor_key "$flavor")

  models=$(endpoint_models "$base" "$flavor")
  if [ -z "$models" ]; then
    if [ "$flavor" = ollama ]; then
      echo "Ollama is running at $base but has no embedding-capable model."
      echo "  ollama pull $DEFAULT_OLLAMA_MODEL"
      confirm "Pull $DEFAULT_OLLAMA_MODEL now?" || {
        echo "Skipped. Nothing changed."
        exit 0
      }
      ollama pull "$DEFAULT_OLLAMA_MODEL" || {
        echo "Pull failed." >&2
        exit 1
      }
      models=$(endpoint_models "$base" "$flavor")
    else
      # LM Studio downloads through its own UI and a generic endpoint exposes no pull API, so
      # there is nothing useful to offer here beyond saying which backend came up empty.
      echo "$flavor at $base serves no embedding model." >&2
      echo "Download one there (or choose another backend), then re-run this." >&2
      exit 1
    fi
  fi

  m="$MODEL"
  if [ -z "$m" ]; then
    # Prefer the recommended model when present, else the first embedding-capable one.
    m=$(printf '%s\n' "$models" | grep "^${DEFAULT_OLLAMA_MODEL}" | head -1)
    [ -z "$m" ] && m=$(printf '%s\n' "$models" | head -1)
  fi
  echo "Provider: $flavor (model $m, endpoint $base/v1)"

  # CRG_OPENAI_DIMENSION stays unset on purpose: CRG only sends a `dimensions` request param
  # when one is pinned, and the model should serve its native width.
  write_cfg "# Written by setup-embeddings.sh. Machine-local; .code-review-graph/.gitignore has '*'.
CRG_OPENAI_BASE_URL=$base/v1
CRG_OPENAI_API_KEY=$key
CRG_OPENAI_MODEL=$m"
  first_embed openai "$m"
  sync_mcp_env "$base" "$m" "$key"
}

# Resolve a named backend to a reachable endpoint. Keeps `--provider ollama` working unchanged,
# adds `--provider lmstudio`, and lets `--provider openai --base-url URL` reach anything else.
# The flavor is taken from what actually answers, not from the name, so a mislabelled port still
# lists its models correctly.
apply_named() { # $1=ollama|lmstudio|openai
  case "$1" in
    ollama) base="${BASE_URL:-$OLLAMA_BASE}" ;;
    lmstudio) base="${BASE_URL:-$LMSTUDIO_BASE}" ;;
    *)
      base="${BASE_URL:-}"
      [ -z "$base" ] && {
        echo "--provider openai needs --base-url URL" >&2
        exit 2
      }
      ;;
  esac
  base=$(normalize_base "$base")
  f=$(endpoint_flavor "$base") || {
    echo "Nothing answering at $base." >&2
    echo "Start the server, or choose the local provider instead." >&2
    exit 1
  }
  apply_endpoint "$base" "$f"
}

menu() {
  echo "Semantic search for the code graph is OFF (keyword mode)."
  echo "Keyword mode works: semantic_search_nodes_tool falls back to name search."
  echo
  echo "Detected embedding backends:"
  # Every (endpoint, model) pair gets one number. Backend and model are not independent choices —
  # a model only exists on the server that serves it — so offering them as one list avoids the
  # state where someone picks Ollama and then a model only LM Studio has.
  i=0
  OPTS=""
  while IFS="$TAB" read -r b f m; do
    [ -z "$b" ] && continue
    if [ -z "$m" ]; then
      echo "  $f at $b — running, but serves no embedding model"
      continue
    fi
    echo "  $f at $b:"
    for one in $(printf '%s' "$m" | tr ',' ' '); do
      i=$((i + 1))
      printf '   %2d) %s\n' "$i" "$one"
      OPTS="$OPTS$i$TAB$b$TAB$f$TAB$one
"
    done
  done << EOF
$(discover_endpoints)
EOF
  [ "$i" = 0 ] && echo "  none reachable (looked at $OLLAMA_BASE and $LMSTUDIO_BASE)"
  echo
  echo "  l) local provider, model $DEFAULT_LOCAL_MODEL (installs PyTorch, ~2 GB)"
  echo "  n) stay in keyword mode (default)"
  printf 'Choice: '
  read -r c
  case "$c" in
    [0-9]*)
      sel=$(printf '%s' "$OPTS" | awk -F"$TAB" -v n="$c" '$1 == n { print $2 "\t" $3 "\t" $4 }')
      [ -z "$sel" ] && {
        echo "No such option."
        exit 2
      }
      MODEL=$(printf '%s' "$sel" | cut -f3)
      apply_endpoint "$(printf '%s' "$sel" | cut -f1)" "$(printf '%s' "$sel" | cut -f2)"
      ;;
    l | L) apply_local ;;
    *) echo "Staying in keyword mode. Nothing changed." ;;
  esac
}

case "$PROVIDER" in
  off) apply_off ;;
  local) apply_local ;;
  ollama | lmstudio | openai) apply_named "$PROVIDER" ;;
  "")
    # Never prompt into a pipe: a non-TTY run reports and exits.
    if [ -t 0 ]; then menu; else print_list; fi
    ;;
  *)
    echo "unknown provider: $PROVIDER (want: off | local | ollama | lmstudio | openai)" >&2
    exit 2
    ;;
esac
