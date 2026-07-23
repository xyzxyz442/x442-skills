#!/usr/bin/env bash
# setup-handoff.sh — install the lease-based handoff coordination protocol into a repo.
#
# Idempotent. Copies the tool-generic payload into <repo>/.agents/handoff/, writes the
# per-tool hook config for each chosen tool (merging, never clobbering), injects the
# AGENTS.md routing block, and (optionally) migrates a legacy .claude/handoff/ install.
#
# Usage:
#   setup-handoff.sh <repo> --tools claude,gemini,copilot --primary claude \
#       [--topology single-repo|cross-repo] [--handoff-dir <path>] \
#       [--migrate <legacy-dir>] [--allow-verify-cmd]
#
# The SKILL drives the interactive choices (detect tools, pick primary, pick topology,
# offer migration); this script is the non-interactive apply step.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD="$SKILL_DIR/scripts/payload"
ASSETS="$SKILL_DIR/assets"

die() {
  echo "setup-handoff: $*" >&2
  exit 1
}

REPO="" TOOLS="" PRIMARY="none" TOPOLOGY="single-repo" HANDOFF_DIR="" MIGRATE="" ALLOW_VERIFY=0
[ $# -gt 0 ] || die "usage: setup-handoff.sh <repo> --tools <list> --primary <tool|none> [opts]"
REPO="$1"
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --tools)
      TOOLS="${2:-}"
      shift 2
      ;;
    --primary)
      PRIMARY="${2:-none}"
      shift 2
      ;;
    --topology)
      TOPOLOGY="${2:-single-repo}"
      shift 2
      ;;
    --handoff-dir)
      HANDOFF_DIR="${2:-}"
      shift 2
      ;;
    --migrate)
      MIGRATE="${2:-}"
      shift 2
      ;;
    --allow-verify-cmd)
      ALLOW_VERIFY=1
      shift
      ;;
    *) die "unknown arg: $1" ;;
  esac
done

# --- preconditions --------------------------------------------------------------------
REPO="$(cd "$REPO" 2> /dev/null && git rev-parse --show-toplevel 2> /dev/null)" \
  || die "not a git working tree: refusing to install (run initial-project first)"
[ -f "$REPO/AGENTS.md" ] || die "no AGENTS.md at repo root — run initial-project first; not fabricating it here"
case "$TOPOLOGY" in single-repo | cross-repo) ;; *) die "bad --topology: $TOPOLOGY" ;; esac

# --- preflight: hard enforcement needs python3 ----------------------------------------
# The primary tool's deny gate parses the hook payload with python3. Refuse to designate
# a hard-enforcement primary unless python3 is present, so breakage is caught NOW, not
# silently at runtime. (Non-primary/advisory wiring has no deny, so it is exempt.)
if [ "$PRIMARY" != "none" ]; then
  command -v python3 > /dev/null 2>&1 \
    || die "primary tool '$PRIMARY' needs python3 for the enforcement gate, and python3 is not on PATH. Install python3, or re-run with --primary none for advisory-only wiring."
fi

# --- resolve the handoff dir + the path tools use to reach hooks.sh --------------------
if [ "$TOPOLOGY" = "cross-repo" ]; then
  [ -n "$HANDOFF_DIR" ] || HANDOFF_DIR="$(cd "$REPO/.." && pwd)/.agents/handoff"
  case "$HANDOFF_DIR" in /*) ;; *) HANDOFF_DIR="$(cd "$REPO/$HANDOFF_DIR" 2> /dev/null && pwd || echo "$REPO/$HANDOFF_DIR")" ;; esac
  HDEST="$HANDOFF_DIR"
  # path recorded in tool configs, relative to the repo when possible
  HDPATH="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$HDEST" "$REPO" 2> /dev/null || echo "$HDEST")"
else
  # single-repo (repo-level board). Location is configurable via --handoff-dir, but must live
  # INSIDE the repo (a shared parent dir is what --topology cross-repo is for).
  if [ -n "$HANDOFF_DIR" ]; then
    HDPATH="${HANDOFF_DIR#./}"
    HDPATH="${HDPATH%/}"
    case "$HDPATH" in
      /*) die "single-repo --handoff-dir must be a path inside the repo (e.g. .claude/handoff), got absolute: $HANDOFF_DIR — use --topology cross-repo for a shared parent dir" ;;
      "" | ../* | */../*) die "single-repo --handoff-dir must be inside the repo, got: $HANDOFF_DIR" ;;
    esac
    HDEST="$REPO/$HDPATH"
  else
    HDEST="$REPO/.agents/handoff"
    HDPATH=".agents/handoff"
  fi
fi

# --- optional migration from a legacy install -----------------------------------------
# Preserve docs, archive/, and history (git mv when possible), then re-point config below.
if [ -n "$MIGRATE" ]; then
  LEGACY="$MIGRATE"
  case "$LEGACY" in /*) ;; *) LEGACY="$REPO/$LEGACY" ;; esac
  [ -d "$LEGACY" ] || die "--migrate: no such legacy dir: $LEGACY"
  [ "$(cd "$LEGACY" && pwd)" = "$HDEST" ] && MIGRATE="" # already at the generic path
fi
if [ -n "$MIGRATE" ]; then
  echo "Migrating legacy handoff install: $LEGACY -> $HDEST"
  mkdir -p "$HDEST/archive"
  LEGREL="${LEGACY#$REPO/}"
  case "$HDEST" in "$REPO"/*) DEST_IN_REPO=1 ;; *) DEST_IN_REPO=0 ;; esac
  move_doc() { # src destdir — git mv (history) when both sides are in-repo, else copy
    local src="$1" dd="$2"
    [ -e "$src" ] || return 0
    if [ "$DEST_IN_REPO" = 1 ] && [ -n "$(git -C "$REPO" ls-files "$src" 2> /dev/null)" ]; then
      git -C "$REPO" mv "$src" "$dd/" 2> /dev/null || cp "$src" "$dd/"
    else
      cp "$src" "$dd/"
    fi
  }
  # durable docs + archive only — NEVER the ephemeral, machine-local .locks
  for f in "$LEGACY"/*.md; do move_doc "$f" "$HDEST"; done
  for a in "$LEGACY"/archive/*.md; do move_doc "$a" "$HDEST/archive"; done
  # de-register the legacy dir from the repo (removes tracked files from index + worktree)
  [ -n "$(git -C "$REPO" ls-files "$LEGREL" 2> /dev/null)" ] \
    && git -C "$REPO" rm -r -q --ignore-unmatch "$LEGREL" > /dev/null 2>&1 || true
  # relocate any leftover (untracked .locks, stray files) OUT of the repo — recoverable, not deleted
  [ -d "$LEGACY" ] && mv "$LEGACY" "${TMPDIR:-/tmp}/handoff-migrated-$$-$(basename "$LEGACY")" 2> /dev/null || true
fi

# --- migrate a FLAT board to the scripts/ + templates/ layout --------------------------
# Boards installed before the restructure keep machinery next to the docs. Move it into place
# before installing, so the payload copy below lands in one location instead of two. Docs, README,
# INDEX, config, archive/ and .locks/ all stay at the board root — only machinery moves. Uses git mv
# when the file is tracked so history follows the rename; the hook commands in each tool's settings
# are rewritten by merge-hooks.py further down (it recognizes both the old and new marker).
migrate_file() { # src dest
  [ -f "$1" ] || return 0
  [ -f "$2" ] && return 0 # already migrated; the payload install below refreshes it
  git -C "$REPO" mv -f "$1" "$2" > /dev/null 2>&1 || mv -f "$1" "$2"
}
if [ -f "$HDEST/hooks.sh" ] || [ -f "$HDEST/handoff-doc-template.md" ]; then
  echo "Migrating flat handoff layout -> scripts/ + templates/ in $HDEST"
  mkdir -p "$HDEST/scripts" "$HDEST/templates"
  migrate_file "$HDEST/hooks.sh" "$HDEST/scripts/hooks.sh"
  migrate_file "$HDEST/handoff-doc-template.md" "$HDEST/templates/handoff-doc-template.md"
  migrate_file "$HDEST/handoff-standalone-template.md" "$HDEST/templates/handoff-standalone-template.md"
  migrate_file "$HDEST/handoff-orchestrator-template.md" "$HDEST/templates/handoff-orchestrator-template.md"
fi

# --- install the payload --------------------------------------------------------------
mkdir -p "$HDEST/archive" "$HDEST/scripts" "$HDEST/templates"
install_file() { # src dest — copy only if changed, keep exec bit
  local s="$1" d="$2"
  if [ ! -f "$d" ] || ! cmp -s "$s" "$d"; then cp "$s" "$d"; fi
}
install_file "$PAYLOAD/handoff" "$HDEST/handoff"
install_file "$PAYLOAD/hooks.sh" "$HDEST/scripts/hooks.sh"
install_file "$PAYLOAD/README.md" "$HDEST/README.md"
install_file "$ASSETS/handoff-doc-template.md" "$HDEST/templates/handoff-doc-template.md"
install_file "$ASSETS/handoff-standalone-template.md" "$HDEST/templates/handoff-standalone-template.md"
install_file "$ASSETS/handoff-orchestrator-template.md" "$HDEST/templates/handoff-orchestrator-template.md"
chmod +x "$HDEST/handoff" "$HDEST/scripts/hooks.sh"

# config (committed): board-global facts only. TOPOLOGY (+ HANDOFF_ALLOW_VERIFY_CMD, appended
# below) are shared. REPO_NAME is a PER-CONSUMER fact — write it ONLY for a single-repo (in-repo)
# board. A shared cross-repo board must NOT bake one repo's name into its committed config, or the
# last installer to run clobbers every sibling's identity. Cross-repo consumers get their identity
# per-repo via $HANDOFF_REPO (baked into their hook command below).
REPO_NAME="$(basename "$REPO")"
{
  echo "# Generated by setup-handoff. Read by handoff + hooks.sh."
  echo "TOPOLOGY=$TOPOLOGY"
  [ "$TOPOLOGY" != "cross-repo" ] && echo "REPO_NAME=$REPO_NAME"
} > "$HDEST/config"

# .locks is machine-local — never commit it. Only meaningful for a single-repo (in-repo) board;
# a cross-repo board is a SHARED dir outside the worktree (git ignore can't act on a ../ path) that
# owns its own .gitignore, so the consumer entry would be inert. Key on TOPOLOGY, not a path prefix:
# on the first install the shared board does not exist yet, so HDEST resolves to the non-canonical
# "$REPO/../handoff" — which would spuriously match a "$REPO"/* test.
if [ "$TOPOLOGY" != "cross-repo" ]; then
  GI="$REPO/.gitignore"
  LOCK_IGNORE="$HDPATH/.locks/"
  if ! grep -qxF "$LOCK_IGNORE" "$GI" 2> /dev/null; then
    printf '%s\n' "$LOCK_IGNORE" >> "$GI"
  fi
fi

# --- per-tool hook wiring (python3 merge, non-clobbering) -----------------------------
render_and_merge() { # $1 = tool  $2 = is_primary(1|0)
  local tool="$1" primary="$2" cfg=""
  case "$tool" in
    claude)
      cfg="$REPO/.claude/settings.json"
      mkdir -p "$REPO/.claude"
      ;;
    gemini)
      cfg="$REPO/.gemini/settings.json"
      mkdir -p "$REPO/.gemini"
      ;;
    copilot)
      cfg="$REPO/.github/hooks/handoff.json"
      mkdir -p "$REPO/.github/hooks"
      ;;
    *)
      echo "  (skipping unknown tool: $tool)" >&2
      return 0
      ;;
  esac
  # Cross-repo: bake THIS repo's identity into its own hook command (per-consumer). Single-repo
  # leaves it empty so the command stays byte-identical (config REPO_NAME drives it).
  local repo_id=""
  [ "$TOPOLOGY" = "cross-repo" ] && repo_id="$(basename "$REPO")"
  HANDOFF_HDPATH="$HDPATH" HANDOFF_TOOL="$tool" HANDOFF_PRIMARY="$primary" HANDOFF_REPO="$repo_id" \
    python3 "$SKILL_DIR/scripts/merge-hooks.py" "$cfg" \
    && echo "  wired $tool ($([ "$primary" = 1 ] && echo 'hard enforcement' || echo advisory)): $cfg" \
    || echo "  WARN: could not wire $tool config: $cfg" >&2
}

IFS=',' read -r -a TOOL_ARR <<< "$TOOLS"
for t in "${TOOL_ARR[@]}"; do
  [ -n "$t" ] || continue
  if [ "$t" = "$PRIMARY" ]; then render_and_merge "$t" 1; else render_and_merge "$t" 0; fi
done

# cross-repo: grant the current repo read/exec access to the shared handoff dir via
# Claude's additionalDirectories (best-effort; only when claude is wired).
if [ "$TOPOLOGY" = "cross-repo" ] && printf '%s' "$TOOLS" | grep -q claude; then
  HANDOFF_HDPATH="$HDPATH" python3 "$SKILL_DIR/scripts/merge-hooks.py" "$REPO/.claude/settings.json" --add-dir || true
fi

# --- AGENTS.md routing block (idempotent) ---------------------------------------------
# The asset carries a PLACEHOLDER_HANDOFF_DIR token (prettier-safe, unlike a __x__ markdown token);
# substitute the real board path so the block advertises the correct commands (e.g. ../.claude/handoff
# for a shared board, not .agents/handoff).
if ! grep -q 'handoff:begin' "$REPO/AGENTS.md" 2> /dev/null; then
  printf '\n' >> "$REPO/AGENTS.md"
  sed "s|PLACEHOLDER_HANDOFF_DIR|$HDPATH|g" "$ASSETS/agents-handoff.md" >> "$REPO/AGENTS.md"
  echo "  injected AGENTS.md routing block"
fi

# record the verify-cmd opt-in for the SKILL to surface (does not itself run anything)
[ "$ALLOW_VERIFY" = 1 ] && echo "HANDOFF_ALLOW_VERIFY_CMD=1" >> "$HDEST/config"

echo "setup-handoff: installed at $HDEST (topology=$TOPOLOGY, tools=${TOOLS:-none}, primary=$PRIMARY)"
