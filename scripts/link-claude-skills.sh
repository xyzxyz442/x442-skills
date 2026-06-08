#!/usr/bin/env bash
set -euo pipefail

# Points Claude Code's skill directory (~/.claude/skills) at the generic install.
# Skills are installed once into ~/.agents/skills (via link-generic-skills.sh, run first
# below); this script then symlinks each x442- skill from there into
# ~/.claude/skills, so the tool dir tracks the generic location, not the repo.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
GENERIC="$HOME/.agents/skills"
DEST="$HOME/.claude/skills"

# Install (or refresh) the generic location first, so it is present to link from.
"$REPO/scripts/link-generic-skills.sh"

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

# Prune pass: remove stale *unprefixed* leftovers from a pre-prefix install.
# Deliberately narrow — a link is pruned only when ALL hold: it is a symlink,
# its name lacks the x442- prefix, a prefixed counterpart exists in $GENERIC,
# and it resolves back into $REPO or $GENERIC. Anything pointing elsewhere (e.g.
# another tool's skills) is left untouched. Removal is prompted when interactive
# and skipped (warned) otherwise — never auto-deleted without consent.
for link in "$DEST"/*; do
  [ -L "$link" ] || continue                  # symlinks only; never touch real dirs
  name="$(basename "$link")"
  case "$name" in x442-*) continue ;; esac     # only prune the unprefixed form
  [ -e "$GENERIC/x442-$name" ] || continue     # needs a prefixed counterpart
  resolved="$(readlink -f "$link" 2>/dev/null || true)"
  case "$resolved" in
    "$REPO"|"$REPO"/*|"$GENERIC"|"$GENERIC"/*) ;;   # same-context guard
    *) continue ;;
  esac

  if [ -t 0 ]; then
    printf 'stale unprefixed link: %s -> %s\n' "$link" "$resolved" >&2
    printf '  superseded by: %s/x442-%s\n' "$DEST" "$name" >&2
    printf '  remove it? [y/N] ' >&2
    read -r reply
    case "$reply" in
      [yY]|[yY][eE][sS])
        if command -v trash >/dev/null 2>&1; then trash "$link"; else unlink "$link"; fi
        echo "pruned $name" >&2
        ;;
      *) echo "kept $name (declined)" >&2 ;;
    esac
  else
    echo "stale $name — run interactively or remove manually: $link" >&2
  fi
done

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
