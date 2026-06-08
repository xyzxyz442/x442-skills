#!/usr/bin/env bash
# setup-graph-hooks.sh — wire the tool-generic knowledge-graph hooks into ANY git repo.
#
#   ./setup-graph-hooks.sh [/path/to/repo] [--tools a,b,c] [--primary <tool>]
#
#     --tools    comma list of: claude,gemini,copilot,antigravity   (default: claude)
#     --primary  the ONE tool that owns the per-turn graph refresh   (default: claude if
#                wired, else the first tool; "none" = refresh only on git commit)
#
# Layers installed:
#   1. Universal (always): .graph-hooks/ shared cores+dispatcher, git post-commit refresh,
#      .gitignore entries, and .code-review-graphignore / .graphifyignore.
#   2. Per chosen tool: its native hook config (from config/render.py), merged into the
#      tool's settings file (config/merge.py) — never clobbering unrelated keys. Only the
#      --primary tool gets the end-of-turn refresh, so N tools never duplicate the build.
#
# Idempotent and non-destructive: re-runnable; never deletes files; legacy scripts are only
# reported, never removed. Every hook silently no-ops when a tool or graph is absent.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$PWD"; TOOLS="claude"; PRIMARY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tools)   TOOLS="${2:-}"; shift 2 ;;
    --primary) PRIMARY="${2:-}"; shift 2 ;;
    --tools=*)   TOOLS="${1#*=}"; shift ;;
    --primary=*) PRIMARY="${1#*=}"; shift ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  TARGET="$1"; shift ;;
  esac
done

MARK="# graph-hooks-managed"
VALID="claude gemini copilot antigravity"
is_valid() { case " $VALID " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# normalize TOOLS (comma -> space), validate
TOOLS_LIST=""
IFS=',' read -r -a _t <<< "$TOOLS"
for t in "${_t[@]}"; do
  t="$(printf '%s' "$t" | tr -d '[:space:]')"; [ -z "$t" ] && continue
  is_valid "$t" || { echo "ERROR: unknown tool '$t' (valid: $VALID)" >&2; exit 2; }
  case " $TOOLS_LIST " in *" $t "*) : ;; *) TOOLS_LIST="${TOOLS_LIST:+$TOOLS_LIST }$t" ;; esac
done
[ -z "$TOOLS_LIST" ] && { echo "ERROR: no valid tools in --tools" >&2; exit 2; }

# default / validate primary
if [ -z "$PRIMARY" ]; then
  case " $TOOLS_LIST " in *" claude "*) PRIMARY="claude" ;; *) PRIMARY="${TOOLS_LIST%% *}" ;; esac
fi
if [ "$PRIMARY" != "none" ]; then
  case " $TOOLS_LIST " in
    *" $PRIMARY "*) : ;;
    *) echo "ERROR: --primary '$PRIMARY' is not in --tools ($TOOLS_LIST)" >&2; exit 2 ;;
  esac
fi

# resolve git root
cd "$TARGET"
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: '$TARGET' is not inside a git repository." >&2; exit 1; }
cd "$ROOT"
echo "Repo:    $ROOT"
echo "Tools:   $TOOLS_LIST"
echo "Primary: $PRIMARY  (owns the per-turn graph refresh)"
echo

# ---- Layer 1: shared .graph-hooks tree -------------------------------------------------
echo "Layer 1 — universal:"
mkdir -p .graph-hooks
cp -R "$HERE/graph-hooks/." .graph-hooks/
find .graph-hooks -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} +
echo "  + .graph-hooks/ (cores + dispatcher + copilot wrappers)"

# ---- Layer 1: git post-commit hook (husky-aware), appended idempotently ----------------
install_hook() {
  dest="$1"
  if [ -f "$dest" ] && grep -q "$MARK" "$dest" 2>/dev/null; then
    echo "  = $dest already managed — left untouched"; return
  fi
  if [ -s "$dest" ]; then
    { printf '\n%s\n' "$MARK"; tail -n +2 "$HERE/post-commit"; } >> "$dest"
  else
    { head -n 1 "$HERE/post-commit"; printf '%s\n' "$MARK"; tail -n +2 "$HERE/post-commit"; } > "$dest"
  fi
  chmod +x "$dest"; echo "  + $dest"
}
if [ -f "$HERE/post-commit" ]; then
  if [ -d .husky ] || { [ -f package.json ] && grep -q '"husky"' package.json 2>/dev/null; }; then
    mkdir -p .husky; install_hook .husky/post-commit
  else
    mkdir -p .git/hooks; install_hook .git/hooks/post-commit
  fi
else
  echo "  ! post-commit missing next to installer — skipping git hook"
fi

# ---- Layer 1: .gitignore (idempotent) --------------------------------------------------
touch .gitignore
for entry in ".code-review-graph/" "graphify-out/" ".claude/settings.local.json"; do
  grep -qxF "$entry" .gitignore 2>/dev/null || printf '%s\n' "$entry" >> .gitignore
done
echo "  = .gitignore ensured"

# ---- Layer 1: graph ignore files (idempotent; never clobber a customized one) ----------
if [ -f "$HERE/graphignore" ]; then
  for ignore in .code-review-graphignore .graphifyignore; do
    if [ -f "$ignore" ]; then echo "  = $ignore exists — left untouched"
    else cp "$HERE/graphignore" "$ignore"; echo "  + $ignore"; fi
  done
else
  echo "  ! graphignore template missing next to installer — skipping ignore files"
fi

# ---- Layer 2: per-tool hook config -----------------------------------------------------
echo
echo "Layer 2 — per-tool hooks:"
render() { python3 "$HERE/config/render.py" --tool "$1" --primary "$PRIMARY"; }
merge()  { python3 "$HERE/config/merge.py" --file "$1" >/dev/null; }

for t in $TOOLS_LIST; do
  case "$t" in
    claude)
      mkdir -p .claude
      # Merge into BOTH the committed template and the active local copy. merge.py replaces
      # only the "hooks" subtree (preserving any user keys), so a --primary change correctly
      # drops the stale Stop/endturn from whichever file previously owned it — no stale second
      # refresh owner. The active file Claude Code actually reads is settings.local.json.
      render claude | merge .claude/settings.example.json
      render claude | merge .claude/settings.local.json
      echo "  + .claude/settings.example.json + settings.local.json (claude hooks)"
      ;;
    gemini)
      render gemini | merge .gemini/settings.json
      echo "  + .gemini/settings.json (gemini hooks)"
      ;;
    copilot)
      mkdir -p .github/hooks
      render copilot | merge .github/hooks/graph.json
      echo "  + .github/hooks/graph.json (copilot hooks)"
      ;;
    antigravity)
      # RISK GATE: contract unverified -> write inert .example only, never activate.
      mkdir -p .agents
      render antigravity | python3 "$HERE/config/merge.py" --file .agents/hooks.json.example >/dev/null
      echo "  ~ .agents/hooks.json.example written (INERT)"
      echo "    TODO(antigravity-hooks): verify the .agents/hooks.json contract against a live"
      echo "    Antigravity install, then rename .example -> .agents/hooks.json to activate."
      ;;
  esac
done

# ---- legacy migration note (non-destructive) -------------------------------------------
LEGACY=""
for s in smart-grep-hook.sh graph-cheatsheet.py stop-graph-update.sh read-glob-nudge.sh session-status.sh session-setup-nudge.sh; do
  [ -f ".claude/scripts/$s" ] && LEGACY="${LEGACY:+$LEGACY }$s"
done
if [ -n "$LEGACY" ]; then
  echo
  echo "Note: legacy hook scripts in .claude/scripts/ are now superseded by .graph-hooks/ and"
  echo "      unused. Safe to remove (use 'trash', not 'rm -rf'): $LEGACY"
fi

# ---- tool detection + next steps -------------------------------------------------------
HAVE_CRG=0; HAVE_GFY=0
command -v code-review-graph >/dev/null 2>&1 && HAVE_CRG=1
command -v graphify >/dev/null 2>&1 && HAVE_GFY=1
echo
echo "Graph tools:"
echo "  code-review-graph: $([ "$HAVE_CRG" = 1 ] && echo installed || echo 'not installed')"
echo "  graphify:          $([ "$HAVE_GFY" = 1 ] && echo installed || echo 'not installed')"
echo
echo "Next steps:"
if [ "$HAVE_CRG" = 0 ] && [ "$HAVE_GFY" = 0 ]; then
  echo "  No graph tool installed — hooks are wired and stay SILENT until you add one:"
  echo "    pipx install code-review-graph    # MCP + semantic search + embeddings"
  echo "    pipx install graphifyy            # CLI only; installed command is 'graphify'"
fi
[ "$HAVE_CRG" = 1 ] && [ ! -d .code-review-graph ] && echo "  Build CRG:      code-review-graph install && code-review-graph build && code-review-graph embed"
[ "$HAVE_GFY" = 1 ] && [ ! -d graphify-out ] && echo "  Build graphify: graphify init . && graphify update ."
echo
echo "Done. Re-run any time — this script is idempotent. Verify with: ./verify-graph-hooks.sh"
