#!/usr/bin/env bash
# setup-secret-guard.sh — install the secret guard, so credential files stay readable without
# their values reaching a transcript.
#
#   setup-secret-guard.sh [--home]        install the home layer (the one that matters)
#   setup-secret-guard.sh <repo>          install a repo's AGENTS.md block and pattern file
#   setup-secret-guard.sh ... --adopt     proceed even though the installed copy differs
#   setup-secret-guard.sh ... --dry-run   say what would change, write nothing
#
# The home layer is the load-bearing one. A leak is a property of the machine and the transcript
# rather than of a repository, so the guard has to be on for a repo nobody installed into.
# "Enforce it everywhere" is one install, not one per project. The repo layer only ADDS — extra
# path patterns and safe-key exceptions — and can never lower the floor. See ADR 0008.
#
# ADOPTION. This skill is canonical, and the copy it replaces may be the only one in existence:
# the payload it supersedes lived unversioned in one directory with no history behind it. So the
# installer hash-compares before writing, refuses on divergence without --adopt, and always backs
# up first. The honest limit, stated because it would otherwise look like a guarantee: the shipped
# payload is de-personalised, so the FIRST install on any machine always diverges and always needs
# --adopt. It defends against later silent drift, not against a bad first install.
#
# Idempotent: byte-compares before writing, so a second run leaves the tree clean.
# bash 3.2 compatible, which is what macOS ships.

set -euo pipefail

SKILL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD="${SKILL}/scripts/payload"
ASSETS="${SKILL}/assets"

die() {
  echo "setup-secret-guard: $1" >&2
  exit "${2:-1}"
}

MODE="home"
REPO=""
ADOPT=0
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --home) MODE="home" ;;
    --adopt) ADOPT=1 ;;
    --dry-run) DRY=1 ;;
    -h | --help)
      sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) die "unknown flag '$1'" 2 ;;
    *)
      MODE="repo"
      REPO="$1"
      ;;
  esac
  shift
done

command -v python3 > /dev/null 2>&1 || die "missing dependency 'python3' — the engine is Python" 69

STAMP="$(awk 'NR==1{print $2}' "${SKILL}/scripts/payload.version" 2> /dev/null || true)"
[ -n "$STAMP" ] || die "cannot read ${SKILL}/scripts/payload.version"

# ---------------------------------------------------------------- shared install primitive

BACKUP_DIR=""
DIVERGED=0

backup_of() { # backup_of <installed-file>
  [ -f "$1" ] || return 0
  if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="${HOME_DIR}/.secret-guard-backup/$(date +%Y%m%d-%H%M%S)"
    [ "$DRY" -eq 1 ] || mkdir -p "$BACKUP_DIR"
  fi
  [ "$DRY" -eq 1 ] || cp "$1" "${BACKUP_DIR}/$(basename "$1")"
}

install_file() { # install_file <src> <dst> [executable]
  local src="$1" dst="$2" exe="${3:-}"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    echo "  = ${dst} up to date"
    return 0
  fi
  if [ -f "$dst" ] && [ "$ADOPT" -eq 0 ]; then
    echo "  ! ${dst} differs from the payload this skill ships"
    DIVERGED=$((DIVERGED + 1))
    return 0
  fi
  if [ "$DRY" -eq 1 ]; then
    echo "  ~ would write ${dst}"
    return 0
  fi
  backup_of "$dst"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  if [ -n "$exe" ]; then chmod +x "$dst"; fi
  echo "  + ${dst}"
}

# ------------------------------------------------------------------------- the home layer

install_home() {
  HOME_DIR="${SECRET_GUARD_HOME:-$HOME/.claude}"
  echo "wiring the home layer at ${HOME_DIR}"

  install_file "${PAYLOAD}/secret_redact.py" "${HOME_DIR}/scripts/secret_redact.py"
  install_file "${PAYLOAD}/secret-file-guard.py" "${HOME_DIR}/scripts/secret-file-guard.py" x
  install_file "${PAYLOAD}/redact-view" "${HOME_DIR}/bin/redact-view" x
  install_file "${PAYLOAD}/secret-scan" "${HOME_DIR}/bin/secret-scan" x

  if [ "$DIVERGED" -gt 0 ]; then
    echo
    echo "Refusing to overwrite ${DIVERGED} file(s) that differ from what this skill ships."
    echo "That is either a local fix worth keeping or drift worth losing, and only you know which."
    echo "  inspect:  diff ${HOME_DIR}/scripts/secret_redact.py ${PAYLOAD}/secret_redact.py"
    echo "  proceed:  $0 --adopt          (the previous copy is backed up first)"
    echo
    echo "On a first install this is expected — the shipped payload resolves its own paths"
    echo "instead of hardcoding one machine's, so it can never be byte-identical to a hand-"
    echo "maintained copy. --adopt is the answer; the backup is why it is safe."
    # A dry run must show the WHOLE plan, including the settings merge below. Stopping here
    # would make --dry-run useless on exactly the machine that already has an install, which
    # is the one where previewing matters most.
    if [ "$DRY" -eq 0 ]; then
      exit 3
    fi
    echo
    echo "(--dry-run: continuing so the rest of the plan is visible; nothing is written)"
  fi

  if [ "$DRY" -eq 0 ]; then
    mkdir -p "${HOME_DIR}/scripts"
    printf '%s\n' "setup-secret-guard ${STAMP}" > "${HOME_DIR}/scripts/.secret-guard.version"
  fi

  DRYFLAG=""
  if [ "$DRY" -eq 1 ]; then DRYFLAG="--dry-run"; fi
  python3 "${SKILL}/scripts/merge-settings.py" \
    --file "${HOME_DIR}/settings.json" \
    --rules "${ASSETS}/deny-rules.json" \
    --guard "${HOME_DIR}/scripts/secret-file-guard.py" \
    ${DRYFLAG}

  if [ -n "$BACKUP_DIR" ]; then
    echo "  previous copies backed up to ${BACKUP_DIR}"
  fi
  echo
  if [ "$DRY" -eq 1 ]; then
    echo "Dry run only — nothing was written."
    if [ "$DIVERGED" -gt 0 ]; then
      echo "Re-run with --adopt to take the payload this skill ships, backing up yours first."
    fi
  else
    echo "Home layer wired. Every repo on this machine is now guarded, including ones that"
    echo "never installed anything. Check it with: ${SKILL}/scripts/verify-secret-guard.sh"
  fi
}

# ------------------------------------------------------------------------- the repo layer

install_repo() {
  [ -d "$REPO" ] || die "'$REPO' is not a directory"
  REPO="$(cd "$REPO" && pwd)"
  HOME_DIR="$REPO" # backups for a repo install stay inside the repo
  [ -f "${REPO}/AGENTS.md" ] || die "no AGENTS.md at ${REPO} — run initial-project first; this skill will not fabricate one"

  echo "wiring the repo layer at ${REPO}"

  if [ "$DRY" -eq 1 ]; then
    python3 "${SKILL}/scripts/splice-agents-block.py" \
      --file "${REPO}/AGENTS.md" --block "${ASSETS}/agents-secret-guard.md" --dry-run
  else
    python3 "${SKILL}/scripts/splice-agents-block.py" \
      --file "${REPO}/AGENTS.md" --block "${ASSETS}/agents-secret-guard.md"
  fi

  # The additions file is scaffolded once and never rewritten -- it is the repo's to own.
  local add="${REPO}/.agents/secret-guard.json"
  if [ -f "$add" ]; then
    echo "  = ${add} left alone (yours to edit)"
  elif [ "$DRY" -eq 1 ]; then
    echo "  ~ would scaffold ${add}"
  else
    mkdir -p "${REPO}/.agents"
    cat > "$add" << 'JSON'
{
  "_comment": [
    "Repo-level additions to the secret guard. This layer may only ADD.",
    "",
    "paths:     extra credential-shaped path patterns for this repo.",
    "safe_keys: key names whose values must NOT be masked here -- a public *.key file, a",
    "           webhook field holding a public URL. This SUPPRESSES masking, so treat an",
    "           addition as a security change and review it as one. It cannot remove a path",
    "           from the deny set; the floor is not lowerable from here."
  ],
  "paths": [],
  "safe_keys": []
}
JSON
    echo "  + ${add}"
  fi

  echo
  echo "Repo layer wired. The engine itself resolves from the home layer;"
  echo "run this without a path if it is not installed yet."
}

case "$MODE" in
  home) install_home ;;
  repo) install_repo ;;
esac
