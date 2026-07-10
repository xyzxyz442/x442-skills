#!/usr/bin/env bash
# setup-embeddings.sh — opt in to semantic search for the code knowledge graph.
#
# Embeddings are optional. Without them `semantic_search_nodes_tool` falls back to keyword
# search over node names, which is a quality difference, not an availability one. Enabling them
# costs either a ~2 GB PyTorch install (local provider) or a running Ollama daemon holding a
# multi-GB model. Neither is imposed: this script is never called by setup-graph-hooks.sh.
#
# Usage:
#   ./setup-embeddings.sh                       interactive menu (TTY) / --list (non-TTY)
#   ./setup-embeddings.sh --list                print detected state, change nothing
#   ./setup-embeddings.sh --provider ollama [--model NAME] [--base-url URL]
#   ./setup-embeddings.sh --provider local  [--model HF_ID]
#   ./setup-embeddings.sh --provider off        stop refreshing vectors
#   ./setup-embeddings.sh --yes                 assume yes for install prompts
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
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

# Probe the HTTP API, not `ollama list` — the API is what CRG will actually call. OLLAMA_HOST
# may be a bare host:port, which is not a URL.
ollama_base() {
  h="${OLLAMA_HOST:-}"
  [ -z "$h" ] && {
    printf 'http://localhost:11434'
    return 0
  }
  case "$h" in
    http://* | https://*) printf '%s' "${h%/}" ;;
    *) printf 'http://%s' "${h%/}" ;;
  esac
}

OLLAMA_BASE="$(ollama_base)"

ollama_up() { curl -sf --max-time 2 "$OLLAMA_BASE/api/tags" >/dev/null 2>&1; }

# Models whose /api/show capabilities include "embedding". A name-substring filter would both
# miss models and invent false positives, so ask the daemon.
ollama_embed_models() {
  names=$(curl -sf --max-time 2 "$OLLAMA_BASE/api/tags" 2>/dev/null |
    python3 -c 'import json,sys; [print(m["name"]) for m in json.load(sys.stdin).get("models",[])]' 2>/dev/null)
  [ -z "$names" ] && return 0
  for n in $names; do
    caps=$(curl -sf --max-time 5 "$OLLAMA_BASE/api/show" \
      -H 'Content-Type: application/json' -d "{\"model\":\"$n\"}" 2>/dev/null |
      python3 -c 'import json,sys; print(",".join(json.load(sys.stdin).get("capabilities") or []))' 2>/dev/null)
    case ",$caps," in *,embedding,*) printf '%s\n' "$n" ;; esac
  done
}

# Ask CRG's own interpreter, via its shebang, whether sentence-transformers is importable.
# find_spec resolves metadata without importing torch — the whole point of this file.
sentence_transformers_present() {
  crg=$(command -v code-review-graph 2>/dev/null) || return 1
  py=$(head -1 "$crg" 2>/dev/null | sed 's/^#!//')
  [ -x "$py" ] || return 1
  "$py" -c 'import importlib.util,sys; sys.exit(0 if importlib.util.find_spec("sentence_transformers") else 1)' 2>/dev/null
}

current_provider() { bash "$PROBE" 2>/dev/null; }

print_list() {
  if ollama_up; then
    models=$(ollama_embed_models | paste -sd, - 2>/dev/null)
    echo "ollama=up"
    echo "ollama_base=$OLLAMA_BASE"
    echo "ollama_models=${models:-}"
  else
    echo "ollama=down"
    echo "ollama_base=$OLLAMA_BASE"
    echo "ollama_models="
  fi
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
  printf '%s\n' "$1" >"$CFG"
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
  base="$1" model="$2"
  case "$base" in
    *localhost* | *127.0.0.1*) ;;
    *)
      echo
      echo "NOTE: $base is not localhost, so the API key is not written to .mcp.json."
      echo "      Export CRG_OPENAI_BASE_URL / CRG_OPENAI_API_KEY / CRG_OPENAI_MODEL in the"
      echo "      environment that launches the MCP server, or semantic search stays keyword-only."
      return 0
      ;;
  esac
  [ -f .mcp.json ] || {
    echo
    echo "NOTE: no .mcp.json here. Give the MCP server CRG_OPENAI_BASE_URL=$base/v1,"
    echo "      CRG_OPENAI_API_KEY=ollama, CRG_OPENAI_MODEL=$model — otherwise it reads keyword mode."
    return 0
  }
  python3 - "$base/v1" "$model" <<'PY'
import json, sys
base, model = sys.argv[1], sys.argv[2]
with open(".mcp.json") as f:
    cfg = json.load(f)
srv = cfg.get("mcpServers", {}).get("code-review-graph")
if srv is None:
    print("  = .mcp.json has no code-review-graph server — skipped")
    sys.exit(0)
env = srv.setdefault("env", {})
env.update({
    "CRG_OPENAI_BASE_URL": base,
    "CRG_OPENAI_API_KEY": "ollama",
    "CRG_OPENAI_MODEL": model,
})
with open(".mcp.json", "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("  ~ .mcp.json env updated for the MCP read path")
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
  [ -f .mcp.json ] || return 0
  python3 - <<'PY'
import json
with open(".mcp.json") as f:
    cfg = json.load(f)
srv = cfg.get("mcpServers", {}).get("code-review-graph", {})
env = srv.get("env", {})
if not any(k.startswith("CRG_OPENAI_") for k in env):
    raise SystemExit(0)
for k in [k for k in env if k.startswith("CRG_OPENAI_")]:
    del env[k]
if not env:
    srv.pop("env", None)
with open(".mcp.json", "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("  ~ .mcp.json env cleaned")
PY
}

# Delegate to the hooks' own gate rather than calling `code-review-graph embed` directly: it is
# the single place that loads embed.env into the environment (CRG raises ValueError without
# CRG_OPENAI_*), so the first embed exercises exactly the path every later refresh takes.
first_embed() {
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
    if command -v trash >/dev/null 2>&1; then trash "$CFG"; else mv "$CFG" "$CFG.disabled"; fi
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
  first_embed
  echo
  echo "The MCP server defaults to the local provider, so semantic_search_nodes_tool picks these"
  echo "vectors up with no further configuration."
}

apply_ollama() {
  base="${BASE_URL:-$OLLAMA_BASE}"
  ollama_up || {
    echo "No Ollama daemon reachable at $OLLAMA_BASE." >&2
    echo "Start it, or choose the local provider instead." >&2
    exit 1
  }

  models=$(ollama_embed_models)
  if [ -z "$models" ]; then
    echo "Ollama is running but has no embedding-capable model."
    echo "  ollama pull $DEFAULT_OLLAMA_MODEL"
    confirm "Pull $DEFAULT_OLLAMA_MODEL now?" || {
      echo "Skipped. Nothing changed."
      exit 0
    }
    ollama pull "$DEFAULT_OLLAMA_MODEL" || {
      echo "Pull failed." >&2
      exit 1
    }
    models=$(ollama_embed_models)
  fi

  m="$MODEL"
  if [ -z "$m" ]; then
    # Prefer the recommended model when present, else the first embedding-capable one.
    m=$(printf '%s\n' "$models" | grep "^${DEFAULT_OLLAMA_MODEL}" | head -1)
    [ -z "$m" ] && m=$(printf '%s\n' "$models" | head -1)
  fi
  echo "Provider: ollama (model $m, endpoint $base/v1)"

  # CRG_OPENAI_DIMENSION stays unset on purpose: CRG only sends a `dimensions` request param
  # when one is pinned, and the model should serve its native width.
  write_cfg "# Written by setup-embeddings.sh. Machine-local; .code-review-graph/.gitignore has '*'.
CRG_OPENAI_BASE_URL=$base/v1
CRG_OPENAI_API_KEY=ollama
CRG_OPENAI_MODEL=$m"
  first_embed
  sync_mcp_env "$base" "$m"
}

menu() {
  models=""
  echo "Semantic search for the code graph is OFF (keyword mode)."
  echo "Keyword mode works: semantic_search_nodes_tool falls back to name search."
  echo
  if ollama_up; then
    models=$(ollama_embed_models)
    if [ -n "$models" ]; then
      echo "Ollama is running at $OLLAMA_BASE with embedding-capable models:"
      printf '%s\n' "$models" | nl -w4 -s') '
      echo
      echo "  Enter a number to use that model (no PyTorch install), or:"
    else
      echo "Ollama is running at $OLLAMA_BASE but has no embedding model pulled."
      echo
      echo "  o) pull $DEFAULT_OLLAMA_MODEL and use it"
    fi
  else
    echo "No Ollama daemon at $OLLAMA_BASE."
    echo
  fi
  echo "  l) local provider, model $DEFAULT_LOCAL_MODEL (installs PyTorch, ~2 GB)"
  echo "  n) stay in keyword mode (default)"
  printf 'Choice: '
  read -r c
  case "$c" in
    [0-9]*)
      MODEL=$(printf '%s\n' "$models" | sed -n "${c}p")
      [ -z "$MODEL" ] && {
        echo "No such option."
        exit 2
      }
      apply_ollama
      ;;
    o | O) apply_ollama ;;
    l | L) apply_local ;;
    *) echo "Staying in keyword mode. Nothing changed." ;;
  esac
}

case "$PROVIDER" in
  off) apply_off ;;
  local) apply_local ;;
  ollama) apply_ollama ;;
  "")
    # Never prompt into a pipe: a non-TTY run reports and exits.
    if [ -t 0 ]; then menu; else print_list; fi
    ;;
  *)
    echo "unknown provider: $PROVIDER (want: off | local | ollama)" >&2
    exit 2
    ;;
esac
