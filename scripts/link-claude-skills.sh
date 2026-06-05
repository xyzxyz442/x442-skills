#!/usr/bin/env bash
set -euo pipefail

# Points Claude Code's skill directory (~/.claude/skills) at the generic install.
# Skills are installed once into ~/.agents/skills (via link-skills.sh, run first
# below); this script then symlinks each x442- skill from there into
# ~/.claude/skills, so the tool dir tracks the generic location, not the repo.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
GENERIC="$HOME/.agents/skills"
DEST="$HOME/.claude/skills"

# Install (or refresh) the generic location first, so it is present to link from.
"$REPO/scripts/link-skills.sh"

# If DEST is a symlink into the repo or the generic dir, linking into it would
# write back into a tree we read from. Detect and bail out instead.
if [ -L "$DEST" ]; then
  resolved="$(readlink -f "$DEST")"
  case "$resolved" in
    "$REPO"|"$REPO"/*|"$GENERIC"|"$GENERIC"/*)
      echo "error: $DEST is a symlink into $resolved." >&2
      echo "Remove it and re-run; the script will recreate it as a real dir." >&2
      exit 1
      ;;
  esac
fi

mkdir -p "$DEST"

for src in "$GENERIC"/x442-*; do
  [ -e "$src" ] || continue   # no matches: glob stays literal, skip it
  name="$(basename "$src")"
  target="$DEST/$name"

  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "skip $name: $target exists and is not a symlink (remove it manually to relink)" >&2
    continue
  fi

  ln -sfn "$src" "$target"
  echo "linked $name -> $src"
done
