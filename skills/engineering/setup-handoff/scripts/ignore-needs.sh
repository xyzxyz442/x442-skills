#!/usr/bin/env bash
# ignore-needs.sh — list every place a board or per-user handoff config could be committed by
# accident (ADR 0010). READ-ONLY: it reports, it never writes an ignore rule.
#
# Usage: ./ignore-needs.sh <repo-root> [board-dir]
#
# One TSV line per need:  <id> TAB <repo-to-ignore-in> TAB <path-relative-to-that-repo> TAB <message>
#
#   repo.ignore.local_config       .agents/handoff.local.json is in the repo and not ignored
#   repo.ignore.personal_board     the board handoff.local.json names sits in the repo, not ignored
#   repo.ignore.nested_board_repo  the board is its own repository inside this repo's worktree
#   board.git.inside_workspace_repo the board sits in some other repository without being its own
#
# verify-setup-handoff.sh turns each line into a warning; setup-handoff.sh prints it as a
# suggestion and writes a rule only when --ignore names where. Both read this one list, so they
# cannot disagree about what needs ignoring.
set -uo pipefail

REPO="${1:?usage: ignore-needs.sh <repo-root> [board-dir]}"
BOARD="${2:-}"
REPO="$(cd "$REPO" 2> /dev/null && pwd -P)" || exit 0

phys() { (cd "$1" 2> /dev/null && pwd -P); }
toplevel() { git -C "$1" rev-parse --show-toplevel 2> /dev/null | while IFS= read -r t; do phys "$t"; done; }
# Ignored or tracked is decided by git, not by grepping .gitignore: a rule can live in any
# .gitignore up the tree, in .git/info/exclude, or in core.excludesFile.
ignored() { git -C "$1" check-ignore -q -- "$2" 2> /dev/null; }
tracked() { git -C "$1" ls-files --error-unmatch -- "$2" > /dev/null 2>&1; }
need() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

LOCAL="$REPO/.agents/handoff.local.json"
if [ -f "$LOCAL" ]; then
  if tracked "$REPO" .agents/handoff.local.json; then
    need repo.ignore.local_config "$REPO" .agents/handoff.local.json \
      ".agents/handoff.local.json is COMMITTED — it is one developer's choice. Untrack it (git rm --cached) and ignore it."
  elif ! ignored "$REPO" .agents/handoff.local.json; then
    need repo.ignore.local_config "$REPO" .agents/handoff.local.json \
      ".agents/handoff.local.json is not ignored — the next git add commits one developer's choice for everyone."
  fi

  # The board a developer named for themselves. Only a board INSIDE the repo can be committed here.
  PERSONAL="$(python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
v = d.get("board") or d.get("boardPath") if isinstance(d, dict) else ""
print(v if isinstance(v, str) else "")' "$LOCAL" 2> /dev/null)"
  if [ -n "$PERSONAL" ]; then
    case "$PERSONAL" in /*) ;; *) PERSONAL="$REPO/$PERSONAL" ;; esac
    P="$(phys "$PERSONAL")"
    case "$P" in
      "$REPO"/*)
        REL="${P#"$REPO"/}/"
        ignored "$REPO" "$REL" \
          || need repo.ignore.personal_board "$REPO" "$REL" \
            "the board handoff.local.json names ($REL) is inside the repo and not ignored. Prefer .git/info/exclude — .gitignore is committed, so it publishes one person's preference."
        ;;
    esac
  fi
fi

[ -n "$BOARD" ] || exit 0
B="$(phys "$BOARD")" || exit 0
BTOP="$(toplevel "$B")"

# A board that is its own repository, inside this repo's worktree: the outer repo sees it as an
# embedded repository, and `git add -A` records a gitlink to it.
if [ "$BTOP" = "$B" ] && [ "$B" != "$REPO" ]; then
  case "$B" in
    "$REPO"/*)
      REL="${B#"$REPO"/}/"
      ignored "$REPO" "$REL" \
        || need repo.ignore.nested_board_repo "$REPO" "$REL" \
          "the board at $REL is its own git repository inside this repo's worktree — ignore it here, or git add records it as an embedded repo."
      ;;
  esac
fi

# A board inside some OTHER repository that is not its own: typically a workspace folder that is a
# repo. Whoever commits in that workspace commits the board. The fix is a choice, so it is asked:
# make the board a repository (ADR 0005's rule for a standalone board), or ignore it there.
if [ -n "$BTOP" ] && [ "$BTOP" != "$B" ] && [ "$BTOP" != "$REPO" ]; then
  REL="${B#"$BTOP"/}/"
  ignored "$BTOP" "$REL" \
    || need board.git.inside_workspace_repo "$BTOP" "$REL" \
      "the board at $B sits inside the repository $BTOP without being its own. Ask: make it a repository (setup-handoff --board-only), or ignore $REL in $BTOP."
fi
exit 0
