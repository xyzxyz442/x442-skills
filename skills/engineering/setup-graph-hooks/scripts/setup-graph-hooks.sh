#!/usr/bin/env bash
# setup-graph-hooks.sh — wire the knowledge-graph hooks into ANY existing git repo.
#
#   * Idempotent: safe to re-run; never clobbers your settings.local.json or existing hooks.
#   * Works whether or not code-review-graph / graphify were ever used in this repo.
#   * Installs nothing heavy — only files + git hook wiring. Tools stay dormant until built.
#
# Keep these four files together in one folder, then run:
#     ./setup-graph-hooks.sh [/path/to/repo]      # defaults to the current directory
#       - setup-graph-hooks.sh   (this file)
#       - smart-grep-hook.sh
#       - post-commit
#       - settings.example.json
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$PWD}"
MARK="# graph-hooks-managed"

# 1. resolve the git root --------------------------------------------------------------
cd "$TARGET"
if ! ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "ERROR: '$TARGET' is not inside a git repository." >&2
  exit 1
fi
cd "$ROOT"
echo "Repo: $ROOT"
echo "Wiring files..."

# 2. scripts (repo-local so they travel with the repo) ---------------------------------
mkdir -p .claude/scripts
for s in smart-grep-hook.sh graph-cheatsheet.py; do
  if [ -f "$HERE/$s" ]; then
    cp "$HERE/$s" ".claude/scripts/$s"
    chmod +x ".claude/scripts/$s"
    echo "  + .claude/scripts/$s"
  else
    echo "  ! $s missing next to installer — its hook will no-op"
  fi
done

# 3. settings.example.json + activate a local copy (never overwrite an existing local) --
if [ -f "$HERE/settings.example.json" ]; then
  mkdir -p .claude
  cp "$HERE/settings.example.json" .claude/settings.example.json
  echo "  + .claude/settings.example.json"
  if [ -f .claude/settings.local.json ]; then
    echo "  = .claude/settings.local.json exists — left untouched (merge by hand if needed)"
  else
    cp .claude/settings.example.json .claude/settings.local.json
    echo "  + .claude/settings.local.json (activated)"
  fi
else
  echo "  ! settings.example.json missing next to installer — skipping"
fi

# 4. warn about stale hooks a previous 'code-review-graph install' may have left ---------
if [ -f .claude/settings.json ] && grep -q 'code-review-graph' .claude/settings.json 2>/dev/null; then
  echo "  ! .claude/settings.json has graph hooks in it — remove them so they don't"
  echo "    double-fire alongside settings.local.json (keep settings.json for permissions only)"
fi

# 5. git post-commit hook (husky-aware), appended idempotently --------------------------
install_hook() {
  dest="$1"
  if [ -f "$dest" ] && grep -q "$MARK" "$dest" 2>/dev/null; then
    echo "  = $dest already managed — left untouched"
    return
  fi
  if [ -s "$dest" ]; then
    # append to an existing hook, skipping our shebang to avoid a stray one mid-file
    { printf '\n%s\n' "$MARK"; tail -n +2 "$HERE/post-commit"; } >> "$dest"
  else
    # fresh file: shebang must be line 1, then our marker, then the body
    { head -n 1 "$HERE/post-commit"; printf '%s\n' "$MARK"; tail -n +2 "$HERE/post-commit"; } > "$dest"
  fi
  chmod +x "$dest"
  echo "  + $dest"
}

if [ -f "$HERE/post-commit" ]; then
  if [ -d .husky ] || { [ -f package.json ] && grep -q '"husky"' package.json 2>/dev/null; }; then
    mkdir -p .husky
    install_hook .husky/post-commit
  else
    mkdir -p .git/hooks
    install_hook .git/hooks/post-commit
  fi
else
  echo "  ! post-commit missing next to installer — skipping git hook"
fi

# 6. .gitignore (idempotent) ------------------------------------------------------------
touch .gitignore
for entry in ".code-review-graph/" "graphify-out/" ".claude/settings.local.json"; do
  grep -qxF "$entry" .gitignore 2>/dev/null || printf '%s\n' "$entry" >> .gitignore
done
echo "  = .gitignore ensured"

# 7. detect tools, print tailored next steps -------------------------------------------
HAVE_CRG=0; HAVE_GFY=0
if command -v code-review-graph >/dev/null 2>&1; then HAVE_CRG=1; fi
if command -v graphify >/dev/null 2>&1; then HAVE_GFY=1; fi

echo ""
echo "Tools:"
echo "  code-review-graph: $([ "$HAVE_CRG" = 1 ] && echo installed || echo 'not installed')"
echo "  graphify:          $([ "$HAVE_GFY" = 1 ] && echo installed || echo 'not installed')"
echo ""
echo "Next steps:"
if [ "$HAVE_CRG" = 0 ] && [ "$HAVE_GFY" = 0 ]; then
  echo "  No graph tool installed — hooks are wired and stay SILENT until you add one:"
  echo "    pipx install code-review-graph    # MCP + semantic search + embeddings"
  echo "    pipx install graphifyy            # CLI only; installed command is 'graphify'"
fi
if [ "$HAVE_CRG" = 1 ] && [ ! -d .code-review-graph ]; then
  echo "  Build CRG:        code-review-graph install && code-review-graph build && code-review-graph embed"
fi
if [ "$HAVE_CRG" = 1 ] && [ -d .code-review-graph ]; then
  echo "  CRG ready (graph present)."
fi
if [ "$HAVE_GFY" = 1 ] && [ ! -d graphify-out ]; then
  echo "  Build graphify:   graphify init . && graphify update ."
  echo "  graphify git hooks: graphify hook install   # its own post-commit/post-checkout"
fi
if [ "$HAVE_GFY" = 1 ] && [ -d graphify-out ]; then
  echo "  graphify ready (graph present)."
fi
echo ""
echo "Done. Re-run any time — this script is idempotent."
