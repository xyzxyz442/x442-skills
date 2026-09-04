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

# Every explicit name is honoured, including one this script has never heard of — the write path
# keeps no allow-list either (see embed-provider.sh::resolve). Validity is CRG's to judge; what
# belongs HERE is reporting, because this runs at session start where the user can see it.
KNOWN = ("local", "openai", "google", "minimax", "voyage")
if explicit:
    provider = explicit
elif base and model and key:
    provider = "openai"
else:
    provider = ""

# The credential each provider needs present in the READ path's environment. Advisory only: a name
# missing from this map costs a missed warning, never a false failure, which is why a hand-kept map
# is acceptable here and was not acceptable in resolve().
REQUIRED_ENV = {
    "openai": ("CRG_OPENAI_API_KEY", "CRG_OPENAI_BASE_URL", "CRG_OPENAI_MODEL"),
    "google": ("GOOGLE_API_KEY",),
    "minimax": ("MINIMAX_API_KEY",),
    "voyage": ("VOYAGE_API_KEY",),
    "local": (),
}

# The identity CRG stamps on a row, so it can be compared with what is already in the table.
# Only the two providers we DRIVE have an identity we can reconstruct: openai's carries the model
# and endpoint we wrote, local's carries the model. For a cloud provider reached by env we know the
# NAME and nothing else, so `want` is the bare name and the comparison below degrades to a prefix
# match. Leaving it empty (as this did until payload 3) made `have != want` true for every such
# repo, reporting drift on a perfectly healthy google/minimax/voyage config — the same
# "misdescribe a correct setup" failure this file exists to catch.
if provider == "openai":
    want = "openai:%s@%s" % (model, base)
elif provider == "local":
    want = "local:%s" % (os.environ.get("CRG_EMBEDDING_MODEL") or "")
else:
    want = provider

have, n = recorded()

# ---- 0a. unknown: an explicit provider name CRG will reject -----------------------------------
# resolve() passes any name through rather than keeping a stale copy of CRG's list, which trades a
# silent skip for one loud failure. The failure is only loud somewhere it can be seen, and the
# refresh hook is not that place — it runs under `nohup ... > /dev/null 2>&1`. So the report lands
# here. KNOWN can fall behind upstream; being wrong costs a spurious warning on a valid provider,
# not a broken embed, so it stays advisory.
if explicit and explicit not in KNOWN:
    problems.append((
        "unknown",
        "CRG_EMBEDDING_PROVIDER is %r, which code-review-graph does not accept (it knows %s) — "
        "every embed will fail, and the hook sends the error to /dev/null"
        % (explicit, ", ".join(KNOWN)),
    ))

# ---- 0b. consent: a cloud key present with no explicit provider -------------------------------
# Until payload 3, resolve() read GOOGLE_API_KEY / MINIMAX_API_KEY and SELECTED that provider, so an
# ambient key exported for something else silently shipped this repo's source to a cloud embedding
# API on every commit, billed to its owner, with CRG's egress warning routed to /dev/null. That
# inference is gone. This notice fires only for repos that were in exactly that state, so it stays
# quiet for everyone else, and says what it means rather than leaving it to a version number.
if not explicit:
    stray = sorted(k for k in ("GOOGLE_API_KEY", "MINIMAX_API_KEY", "VOYAGE_API_KEY")
                   if os.environ.get(k))
    if stray:
        problems.append((
            "consent",
            "%s present but CRG_EMBEDDING_PROVIDER is unset — before payload 3 this repo would "
            "have embedded against that cloud provider automatically, sending source off this "
            "machine without asking. It no longer does. Set CRG_EMBEDDING_PROVIDER explicitly if "
            "you actually want it" % " and ".join(stray),
        ))

# ---- 1. drift: the write path and the index disagree -----------------------------------------
if have and provider:
    # A local setup usually pins no model, and CRG stamps the row with whatever default it used.
    # Comparing the full identity there would report drift on a perfectly healthy repo, so compare
    # the bare provider unless the config actually names a model.
    if provider == "local" and not os.environ.get("CRG_EMBEDDING_MODEL"):
        mismatch = not have.startswith("local:")
    elif provider not in ("openai", "local"):
        # Bare-name comparison: `have` is "google:text-embedding-004" and all we know is "google".
        mismatch = have.split(":", 1)[0] != provider
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

    # "The write path and the read path must agree" is true for EVERY provider, not just the two
    # we drive. This used to run only for openai/local, so a repo embedding through a cloud
    # provider got no read-path check at all — the MCP server would sit in keyword mode over a
    # graph full of vectors and nothing would say so. The credential names come from REQUIRED_ENV;
    # the endpoint/model comparison below is openai-specific because it is the only provider whose
    # identity carries an endpoint.
    missing = [k for k in REQUIRED_ENV.get(provider, ()) if not env.get(k)]
    if provider and missing:
        problems.append((
            "readpath",
            "%s is missing %s — the graph server falls back to keyword mode and never reads these "
            "vectors" % (path, ", ".join(missing)),
        ))
    elif provider == "openai" and (
        (env["CRG_OPENAI_BASE_URL"].rstrip("/"), env["CRG_OPENAI_MODEL"]) != (base, model)
    ):
        problems.append((
            "readpath",
            "%s reads %s/%s but the vectors were written by %s/%s — no query will match them"
            % (path, env["CRG_OPENAI_BASE_URL"].rstrip("/"), env["CRG_OPENAI_MODEL"], base, model),
        ))

    if provider and provider != "openai" and any(k.startswith("CRG_OPENAI_") for k in env):
        problems.append((
            "readpath",
            "%s still pins CRG_OPENAI_* but this repo embeds with the %s provider — stale wiring"
            % (path, provider),
        ))

for code, msg in problems:
    print("%s\t%s" % (code, msg))
PY

exit 0
