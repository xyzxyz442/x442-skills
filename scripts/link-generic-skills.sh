#!/usr/bin/env bash
set -euo pipefail

# Links all skills in the repository into the generic, tool-agnostic skills
# directory (~/.agents/skills) used by AGENTS.md-aware CLIs. This is the default
# target when no tool-specific path applies; use link-claude-skills.sh for the
# Claude Code-specific location (~/.claude/skills).

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/.agents/skills"

# If the dest is a symlink that resolves into this repo, we'd end up writing the
# per-skill symlinks back into the repo's own skills/ tree. Detect and bail out
# instead of polluting the working copy.
if [ -L "$DEST" ]; then
  resolved="$(readlink -f "$DEST")"
  case "$resolved" in
    "$REPO"|"$REPO"/*)
      echo "error: $DEST is a symlink into this repo ($resolved)." >&2
      echo "Remove it (rm \"$DEST\") and re-run; the script will recreate it as a real dir." >&2
      exit 1
      ;;
  esac
fi

mkdir -p "$DEST"

find "$REPO/skills" -name SKILL.md \
  -not -path '*/node_modules/*' \
  -not -path '*/deprecated/*' \
  -not -path '*/in-progress/*' \
  -not -path '*/personal/*' \
  -print0 |
while IFS= read -r -d '' skill_md; do
  src="$(dirname "$skill_md")"
  # Prefix the linked name with x442- so it can't collide with a built-in or
  # third-party skill of the same name (e.g. init) in ~/.agents/skills.
  name="x442-$(basename "$src")"
  target="$DEST/$name"

  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "skip $name: $target exists and is not a symlink (remove it manually to relink)" >&2
    continue
  fi

  ln -sfn "$src" "$target"
  echo "linked $name -> $src"
done
