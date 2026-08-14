#!/usr/bin/env bash
# embed-health.sh — the single definition of "this repo's embedding config is wrong".
#
# Embeddings have three moving parts that are configured in three different places and are only
# correct when they agree:
#
#   1. the WRITE path  — .code-review-graph/embed.env, read by the refresh hooks
#   2. the INDEX       — the provider identity recorded on the rows in embeddings
#   3. the READ path   — the MCP server's own env block (.mcp.json / .vscode/mcp.json)
#
# Every way these can disagree fails silently. A write/index disagreement re-embeds every node on
# every refresh forever; an unreachable endpoint makes each embed a no-op; a read-path disagreement
# leaves a graph full of vectors that semantic_search never looks at, because CRG's OpenAI provider
# raises ValueError without CRG_OPENAI_* and the tool swallows that into a keyword-mode answer.
# None of it errors, so none of it is visible without a check like this one.
#
# This file exists so that check has ONE definition. verify-graph-hooks.sh renders it as [warn]
# lines and session-context.sh renders it as a session-start notice; both ask this script rather
# than reimplementing the comparison, because two copies of "what counts as drifted" drift.
#
# Output: zero or more `code<TAB>message` lines, and nothing at all when healthy. Always exits 0 —
# an unhealthy embedding config is a warning, never a failure. Codes: drift | unreachable |
# readpath | cwd.
#
# Never imports torch and never calls the embedder: every check is a file read, one read-only
# sqlite query, or a 1-second localhost probe. It runs on every session start, so it stays cheap.
set -uo pipefail

CFG=".code-review-graph/embed.env"
DB=".code-review-graph/graph.db"

# A repo that never opted in has nothing to be wrong about. Keyword mode is a supported state.
[ -f "$DB" ] || [ -f "$CFG" ] || exit 0

# Repo-local config, not shell config — same reasoning as embed-provider.sh: a post-commit hook
# fired from a GUI git client inherits no shell rc. `set -a` exports so python sees them.
if [ -f "$CFG" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$CFG"
  set +a
fi

python3 - "$DB" << 'PY' 2> /dev/null
import json, os, sqlite3, sys
from urllib.parse import urlparse
from urllib.request import urlopen

DB = sys.argv[1]
problems = []


def probe_connect(path, timeout=2):
    """Status-probe open. See embed-provider.sh for why ro comes first and immutable is a fallback."""
    for extra in ("", "&immutable=1"):
        try:
            c = sqlite3.connect("file:%s?mode=ro%s" % (path, extra), uri=True, timeout=timeout)
            c.execute("SELECT count(*) FROM sqlite_master").fetchone()
            return c
        except sqlite3.Error:
            continue
    raise sqlite3.OperationalError("graph db unreadable")


def recorded():
    """(identity, count) of the dominant embedder in the index, or (None, 0)."""
    if not os.path.exists(DB):
        return None, 0
    try:
        c = probe_connect(DB)
        row = c.execute(
            "SELECT provider, count(*) FROM embeddings GROUP BY provider ORDER BY count(*) DESC LIMIT 1"
        ).fetchone()
        c.close()
    except Exception:
        return None, 0
    return (row[0], row[1]) if row and row[0] else (None, 0)


# ---- what the WRITE path is configured to do -------------------------------------------------
# Mirrors embed-provider.sh resolve(): an explicit provider wins, else a complete CRG_OPENAI_* trio
# means the OpenAI-compatible path. Anything else is "not configured" — which is only a problem if
# the index says otherwise.
base = (os.environ.get("CRG_OPENAI_BASE_URL") or "").rstrip("/")
model = os.environ.get("CRG_OPENAI_MODEL") or ""
key = os.environ.get("CRG_OPENAI_API_KEY") or ""
explicit = os.environ.get("CRG_EMBEDDING_PROVIDER") or ""

if explicit in ("local", "openai", "google", "minimax"):
    provider = explicit
elif base and model and key:
    provider = "openai"
else:
    provider = ""

# The identity CRG stamps on a row, so it can be compared with what is already in the table.
if provider == "openai":
    want = "openai:%s@%s" % (model, base)
elif provider == "local":
    want = "local:%s" % (os.environ.get("CRG_EMBEDDING_MODEL") or "")
else:
    want = ""

have, n = recorded()

# ---- 1. drift: the write path and the index disagree -----------------------------------------
if have and provider:
    # A local setup usually pins no model, and CRG stamps the row with whatever default it used.
    # Comparing the full identity there would report drift on a perfectly healthy repo, so compare
    # the bare provider unless the config actually names a model.
    if provider == "local" and not os.environ.get("CRG_EMBEDDING_MODEL"):
        mismatch = not have.startswith("local:")
    else:
        mismatch = have != want
    if mismatch:
        problems.append((
            "drift",
            "embedding provider drift — configured %r but the graph holds %d vector(s) from %r; "
            "every refresh re-embeds all of them" % (want or provider, n, have),
        ))
elif have and not provider and not have.startswith("local:"):
    # embed-provider.sh auto-keeps-fresh only for `local`; a recorded cloud/compatible identity with
    # no embed.env cannot refresh at all, so those vectors quietly rot against the moving code.
    problems.append((
        "drift",
        "the graph holds %d vector(s) from %r but no embedding provider is configured — "
        "they will not refresh" % (n, have),
    ))

# ---- 2. unreachable: the configured endpoint is not listening --------------------------------
# Only localhost is probed. A hosted endpoint would mean a network call on every session start, and
# its reachability is not this repo's business.
if provider == "openai" and base:
    host = urlparse(base).hostname or ""
    if host in ("localhost", "127.0.0.1", "::1", "0.0.0.0"):
        served = None
        try:
            body = urlopen(base.rstrip("/") + "/models", timeout=1).read()
            served = [m.get("id") for m in (json.loads(body).get("data") or [])]
        except Exception:
            problems.append((
                "unreachable",
                "no embedding server answering at %s — embeds are silently doing nothing" % base,
            ))

        # Reachable is not the same as usable. A server that has been reset, or had the model
        # removed, still answers /v1/models perfectly — it just no longer serves the one the config
        # names, so every embed fails while the endpoint looks healthy.
        if served is not None and model and model not in served:
            problems.append((
                "model",
                "%s no longer serves %r (has: %s) — embeds will fail"
                % (base, model, ", ".join(served[:4]) or "no models"),
            ))

# ---- 3. readpath: the MCP server cannot read what the write path produced ---------------------
# .mcp.json nests under "mcpServers"; VS Code's .vscode/mcp.json nests under "servers". Same server,
# two schemas, and either one can be the process that actually serves semantic_search.
MCP_FILES = ((".mcp.json", "mcpServers"), (".vscode/mcp.json", "servers"))
repo_root = os.path.realpath(".")

for path, top in MCP_FILES:
    if not os.path.exists(path):
        continue
    try:
        with open(path) as f:
            srv = (json.load(f).get(top) or {}).get("code-review-graph")
    except Exception:
        continue
    if not isinstance(srv, dict):
        continue
    env = srv.get("env") or {}

    # A cwd pointing outside this repo makes the server answer for a DIFFERENT codebase — the
    # queries succeed, the results are simply about the wrong project, which is the worst shape a
    # wrong answer can take.
    #
    # Editor variables like ${workspaceFolder} are the CORRECT way to write this in .vscode/mcp.json
    # and already mean "this repo", but only the editor can expand them. Flagging an unresolved
    # variable would report the idiomatic spelling as the bug, so leave those alone.
    cwd = srv.get("cwd")
    if cwd and "${" in cwd:
        cwd = None
    if cwd and os.path.realpath(os.path.expanduser(cwd)) != repo_root:
        problems.append((
            "cwd",
            "%s points the graph server at %s — queries here would answer for that repo, not this one"
            % (path, cwd),
        ))

    if provider == "openai":
        if not all(env.get(k) for k in ("CRG_OPENAI_BASE_URL", "CRG_OPENAI_API_KEY", "CRG_OPENAI_MODEL")):
            problems.append((
                "readpath",
                "%s has no CRG_OPENAI_* env — the server falls back to keyword mode and never reads "
                "these vectors" % path,
            ))
        elif (env["CRG_OPENAI_BASE_URL"].rstrip("/"), env["CRG_OPENAI_MODEL"]) != (base, model):
            problems.append((
                "readpath",
                "%s reads %s/%s but the vectors were written by %s/%s — no query will match them"
                % (path, env["CRG_OPENAI_BASE_URL"].rstrip("/"), env["CRG_OPENAI_MODEL"], base, model),
            ))
    elif provider == "local" and any(k.startswith("CRG_OPENAI_") for k in env):
        problems.append((
            "readpath",
            "%s still pins CRG_OPENAI_* but this repo embeds with the local provider — stale wiring"
            % path,
        ))

for code, msg in problems:
    print("%s\t%s" % (code, msg))
PY

exit 0
