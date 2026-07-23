#!/usr/bin/env bash
# embed-provider.sh — resolve which code-review-graph embedding provider this repo should use.
#
# Embeddings are an OPT-IN tier. `semantic_search_nodes_tool` falls back to keyword search when
# the embeddings table is empty (see CRG embeddings.py::semantic_search), so a repo with no
# provider configured is a supported state, not a broken one. Calling `code-review-graph embed`
# without a provider is a hard error that the refresh hooks would swallow into /dev/null, so we
# resolve first and skip cleanly instead.
#
# Modes:
#   (no args)  print the provider name to stdout, or nothing at all. Always exits 0.
#   --run      resolve, and if a provider is configured, exec the embed with the repo's env.
#
# Never imports torch: the "already embedded?" check is a read-only sqlite query. CRG's own
# provider lookup imports sentence_transformers merely to test availability, which is the cost
# this script exists to avoid on every turn and every commit.
set -uo pipefail

CFG=".code-review-graph/embed.env"
DB=".code-review-graph/graph.db"

# Repo-local config, not shell config. A post-commit hook fired from a GUI git client inherits
# no shell rc, so CRG_OPENAI_* has to live with the repo or cloud vectors silently go stale.
# `set -a` exports what we source, so an exec'd `code-review-graph embed` inherits it.
load_env() {
  [ -f "$CFG" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$CFG"
  set +a
}

# Provider recorded in the embeddings table, reduced to a bare name `--provider` accepts.
# The column stores an endpoint-aware identity ("local:all-MiniLM-L6-v2",
# "openai:qwen3-embedding@http://localhost:11434"), not a bare provider.
recorded_provider() {
  [ -f "$DB" ] || return 0
  python3 - "$DB" << 'PY' 2> /dev/null
import sqlite3, sys
try:
    c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=2)
    row = c.execute(
        "SELECT provider FROM embeddings GROUP BY provider ORDER BY count(*) DESC LIMIT 1"
    ).fetchone()
    print(row[0].split(":", 1)[0] if row and row[0] else "")
except Exception:
    pass
PY
}

# Search tier the READ path (semantic_search_nodes_tool) will actually get, judged from the vectors
# ALREADY in the graph — independent of the write-side resolve() above. Prints one space-separated
# line consumers (grep-steer, session-context) render as a per-search marker:
#   keyword           no vectors — semantic_search falls back to name matching (the floor)
#   local  <model>    vectors from CRG's built-in sentence-transformers provider (read by default)
#   custom <label>    vectors from an external / OpenAI-compatible provider (ollama, hosted)
# The custom label is "ollama" for a :11434 endpoint, else the endpoint host, else the model — a
# hint for the agent, not something it must parse. Preference order at setup is custom > local >
# keyword (resolve() above already writes custom-first); this only reports what is live now.
recorded_tier() {
  [ -f "$DB" ] || {
    printf 'keyword\n'
    return 0
  }
  python3 - "$DB" << 'PY' 2> /dev/null || printf 'keyword\n'
import sqlite3, sys
from urllib.parse import urlparse
try:
    c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=2)
    row = c.execute(
        "SELECT provider, count(*) FROM embeddings GROUP BY provider "
        "ORDER BY count(*) DESC LIMIT 1"
    ).fetchone()
except Exception:
    row = None
if not row or not row[0] or not row[1]:
    print("keyword"); raise SystemExit
bare, _, detail = row[0].partition(":")   # "openai:qwen3-embedding@http://localhost:11434"
if bare == "local":
    print("local " + (detail or "-")); raise SystemExit
model, _, endpoint = detail.partition("@")
if endpoint and ":11434" in endpoint:
    label = "ollama"
elif endpoint:
    label = urlparse(endpoint).hostname or endpoint
else:
    label = model or bare
print("custom " + label)
PY
}

resolve() {
  load_env

  case "${CRG_EMBEDDING_PROVIDER:-}" in
    local | openai | google | minimax)
      printf '%s' "$CRG_EMBEDDING_PROVIDER"
      return 0
      ;;
  esac

  if [ -n "${CRG_OPENAI_BASE_URL:-}" ] && [ -n "${CRG_OPENAI_API_KEY:-}" ] && [ -n "${CRG_OPENAI_MODEL:-}" ]; then
    printf 'openai'
    return 0
  fi
  [ -n "${GOOGLE_API_KEY:-}" ] && {
    printf 'google'
    return 0
  }
  [ -n "${MINIMAX_API_KEY:-}" ] && {
    printf 'minimax'
    return 0
  }

  # Auto-keep-fresh: a repo embedded earlier keeps its vectors current with no config. Only
  # `local` qualifies — the cloud providers raise ValueError when their env vars are absent,
  # so a recorded `openai:` with no embed.env must skip rather than crash on every turn.
  [ "$(recorded_provider)" = "local" ] && printf 'local'
  return 0
}

# Read-path tier report needs no write-side resolve — it only inspects recorded vectors.
if [ "${1:-}" = "--tier" ]; then
  recorded_tier
  exit 0
fi

PROV="$(resolve)"

if [ "${1:-}" != "--run" ]; then
  [ -n "$PROV" ] && printf '%s\n' "$PROV"
  exit 0
fi

command -v code-review-graph > /dev/null 2>&1 || exit 0
[ -n "$PROV" ] || exit 0
load_env
exec code-review-graph embed --provider "$PROV"
