#!/usr/bin/env bash
# verify-setup-handoff.sh — confirm the handoff protocol is installed AND its hooks fire.
# READ-ONLY: it never claims/releases and never fires the posttool hook (which would
# regenerate INDEX.md). It fires the read-only hook paths (sessionstart, and pretool on
# INDEX.md / an ordinary file) exactly as a tool would, and inspects the wired config.
#
# Usage: ./verify-setup-handoff.sh [/path/to/repo]      (defaults to current dir)
set -uo pipefail

# Resolve this script's own directory to an ABSOLUTE path BEFORE the cd below. Everything the
# verifier reads from its own skill (payload.version, merge-hooks.py, splice-agents-block.py, the
# assets) must be reachable after we cd into the target repo. A bare `dirname "$0"` is relative to
# the ORIGINAL cwd, so invoking this script by a relative path silently broke every one of those
# reads once we moved -- and a missing file makes python3 exit 2, which the drift checks below
# would otherwise report as real drift.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TARGET="${1:-$PWD}"
cd "$TARGET" 2> /dev/null || {
  echo "no such path: $TARGET" >&2
  exit 1
}
ROOT=$(git rev-parse --show-toplevel 2> /dev/null) || {
  echo "ERROR: not a git repo" >&2
  exit 1
}
cd "$ROOT"

P=0
F=0
W=0
ok() {
  printf '  [PASS] %s\n' "$1"
  P=$((P + 1))
}
bad() {
  printf '  [FAIL] %s\n' "$1"
  F=$((F + 1))
}
warn() {
  printf '  [warn] %s\n' "$1"
  W=$((W + 1))
}

# Compare the installed payload stamp against the version this skill ships. A behind-but-working
# install is a WARNING, never a FAIL — it still functions, it just predates a payload change, and
# reserving the non-zero exit for real breakage keeps the harness contract meaningful. Silent when
# the skill's own payload.version is unreadable, which is what happens if the verifier is copied
# somewhere detached from its skill directory: unknown is not the same as behind.
check_payload_version() { # installed-version skill-name   (caller reads the stamp; shapes differ)
  local installed="$1" skill="$2" shipped
  shipped="$(awk 'NR==1{print $2}' "$SCRIPT_DIR/payload.version" 2> /dev/null)"
  [ -n "$shipped" ] || return 0
  if [ -z "$installed" ]; then
    warn "payload version unknown (pre-versioning install) — re-run $skill"
  elif [ "$installed" -lt "$shipped" ] 2> /dev/null; then
    warn "payload v$installed installed, skill ships v$shipped — re-run $skill"
  elif [ "$installed" -gt "$shipped" ] 2> /dev/null; then
    warn "payload v$installed installed is newer than the skill's v$shipped — this $skill copy is stale"
  else
    ok "payload v$installed matches the version $skill ships"
  fi
}

is_json() { python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1" 2> /dev/null; }
is_json_str() { printf '%s' "$1" | python3 -c "import json,sys; json.load(sys.stdin)" 2> /dev/null; }

# Locate the handoff dir: the default repo-level path, else derive the configured location
# from any wired tool config (honors a custom --handoff-dir and any primary tool).
HD="$ROOT/.agents/handoff"
if [ ! -d "$HD" ]; then
  for CF in .claude/settings.json .claude/settings.local.json .gemini/settings.json .github/hooks/handoff.json; do
    [ -f "$ROOT/$CF" ] || continue
    # hooks.sh lives at <board>/scripts/hooks.sh; a board wired before the layout restructure has
    # it at <board>/hooks.sh. Match either, then strip the right number of path segments — one
    # dirname too few would point the verifier at the scripts/ subdir instead of the board.
    DERIVED=$(grep -o '[^"]*handoff/\(scripts/\)\?hooks\.sh' "$ROOT/$CF" 2> /dev/null | head -1)
    [ -n "$DERIVED" ] || continue
    D="${DERIVED##*CLAUDE_PROJECT_DIR/}"
    D="${D#bash }"
    case "$D" in */scripts/hooks.sh) D="$(dirname "$(dirname "$D")")" ;; *) D="$(dirname "$D")" ;; esac
    case "$D" in /*) HD="$D" ;; *) HD="$ROOT/$D" ;; esac
    break
  done
fi
# resolve any ../ or symlinks so paths we build match the hook's realpath $DIR
[ -d "$HD" ] && HD="$(cd "$HD" && pwd)"

echo "Repo: $ROOT"
echo "Handoff dir: $HD"
echo
echo "1. Payload present + executable"
echo "-------------------------------"
if [ ! -d "$HD" ]; then
  bad "handoff not installed (no $HD) — run setup-handoff"
  echo
  echo "Summary: $P passed, $W warnings, $F failed"
  exit 1
fi
# hooks.sh lives under scripts/ and the templates under templates/; a board installed before the
# layout restructure still has them flat, which is a warning (re-run the installer to migrate),
# not a failure — the CLI and hooks both fall back to the flat locations.
for f in handoff scripts/hooks.sh; do
  if [ -f "$HD/$f" ]; then
    [ -x "$HD/$f" ] && ok "$f present and executable" || warn "$f present but not executable (chmod +x)"
  elif [ -f "$HD/$(basename "$f")" ]; then
    warn "$(basename "$f") is at the board root (flat layout) — re-run setup-handoff to migrate to $f"
  else bad "$f missing"; fi
done
[ -f "$HD/README.md" ] && ok "README.md present" || warn "README.md missing"
# EITHER config file counts. The installer writes config.json; only a board predating that carries
# the legacy KEY=value `config`, so requiring the legacy name printed "config missing" on every
# freshly installed board — a warning that is always wrong trains readers to ignore the ones that
# are not. Which file is present, and whether it parses, is graded in section 2.
if [ -f "$HD/config.json" ] || [ -f "$HD/config" ]; then
  ok "board config present"
else
  warn "no board config (config.json or legacy config) — re-run setup-handoff"
fi
if [ -f "$HD/templates/handoff-doc-template.md" ]; then
  ok "templates/handoff-doc-template.md present"
elif [ -f "$HD/handoff-doc-template.md" ]; then
  warn "handoff-doc-template.md is at the board root (flat layout) — re-run setup-handoff to migrate"
else warn "handoff-doc-template.md missing"; fi
if [ -f "$HD/templates/handoff-brief-template.md" ]; then
  ok "templates/handoff-brief-template.md present"
elif [ -f "$HD/handoff-brief-template.md" ]; then
  warn "handoff-brief-template.md is at the board root (flat layout) — re-run setup-handoff to migrate"
else warn "handoff-brief-template.md missing — re-run setup-handoff"; fi
[ -d "$HD/archive" ] && ok "archive/ present" || warn "archive/ missing (created on first done)"
check_payload_version "$(awk 'NR==1{print $2}' "$HD/.version" 2> /dev/null)" setup-handoff

echo
echo "2. Config, gitignore, AGENTS.md block"
echo "-------------------------------------"
TOPO=""
# CONFIG_JSON_BAD tracks whether the "not valid JSON" FAIL below already fired, so the resolver
# failure a few lines down (same root cause — it re-reads this same file) reports it once, not
# twice. Two FAILs for one malformed config.json would double-count the same underlying problem.
CONFIG_JSON_BAD=""
if [ -f "$HD/config.json" ] || [ -f "$HD/config" ]; then
  if [ -f "$HD/config.json" ]; then
    if is_json "$HD/config.json"; then ok "config.json present and valid JSON"; else
      bad "config.json is not valid JSON"
      CONFIG_JSON_BAD=1
    fi
    # python3 is not optional once a config.json exists: every read of it needs one.
    command -v python3 > /dev/null 2>&1 || bad "config.json present but python3 missing — the board cannot read its own config"
  else
    warn "legacy shell config (no config.json) — re-run setup-handoff to migrate"
  fi
  # Report what the board will ACTUALLY use, resolved through the same code the CLI uses. A
  # verifier that only checks the file exists cannot catch a key that is silently ignored.
  if [ -f "$HD/scripts/config.sh" ]; then
    # shellcheck disable=SC1091
    . "$HD/scripts/config.sh"
    # `eval "$(handoff_config_load ...)"` reports the exit status of eval, not of the function:
    # eval of an empty string still succeeds. So capture the output FIRST and check the capture's
    # own status — only then eval it — or a malformed config.json (or a missing python3) leaves
    # every HC_* var unset while this branch still reports success.
    if _hc_out="$(handoff_config_load "$HD" "$ROOT" 2>&1)"; then
      eval "$_hc_out"
      ok "effective config: topology=$HC_TOPOLOGY ttlHours=$HC_TTL_HOURS allowVerifyCmd=$HC_ALLOW_VERIFY_CMD group=${HC_GROUP:-none}"
      case "$HC_TOPOLOGY" in single-repo | cross-repo) ok "topology valid: $HC_TOPOLOGY" ;; *) bad "invalid topology: $HC_TOPOLOGY" ;; esac
      TOPO="$HC_TOPOLOGY"
    elif [ -n "$CONFIG_JSON_BAD" ]; then
      : # already reported as "config.json is not valid JSON" above — same root cause, don't double-FAIL
    else bad "config could not be resolved (malformed?): $_hc_out"; fi
  else warn "scripts/config.sh missing — re-run setup-handoff"; fi
else bad "config missing (no config.json)"; fi
# A typo'd key is inert and silent today; name it. Unknown keys are a warning, not a failure —
# a future payload may add keys this verifier predates. A file that fails to parse must NOT
# report either PASS or WARN here: exit 2 (distinct from the "found unknown keys" success path)
# is how the python side tells the shell "could not check" from "checked, found nothing" — the
# malformed-JSON FAIL above already covers that condition, so this check stays silent rather
# than printing a false PASS for a check it never actually performed.
if [ -f "$HD/config.json" ] && command -v python3 > /dev/null 2>&1; then
  UNKNOWN="$(python3 -c '
import json,sys
known={"topology","repoName","group","groups","groupLayout","ttlHours","allowVerifyCmd","boardPath"}
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(2)
if not isinstance(d, dict): sys.exit(2)
print(",".join(sorted(set(d)-known)))' "$HD/config.json" 2> /dev/null)"
  RC=$?
  if [ "$RC" -eq 0 ]; then
    [ -n "$UNKNOWN" ] && warn "config.json has unknown key(s): $UNKNOWN" || ok "config.json keys all recognised"
  fi
fi
if [ "$TOPO" = "cross-repo" ]; then
  # Shared board lives outside the worktree and owns its own .gitignore; a consumer .locks/ entry
  # would be inert, so its absence is correct — not a warning.
  ok ".gitignore .locks/ check skipped (cross-repo: shared board self-ignores its .locks/)"
else
  grep -q '/.locks/' .gitignore 2> /dev/null && ok ".gitignore excludes .locks/" || warn ".gitignore missing a .locks/ entry — leases could get committed"
fi
# Content-aware, not presence-only: a block that exists but predates an asset change still reads
# as installed while advertising commands the CLI no longer documents (agents-block-drift-handoff).
# Delegated to splice-agents-block.py --check so the marker/render semantics live in one place.
# Drift is a WARNING, not a FAIL, on the same principle as the payload stamp above: the block still
# works, it is just behind, and re-running the installer now refreshes it.
# Markers carry their `<!-- ` opener: bare `handoff:begin` is a substring of `cross-repo-handoff:begin`,
# so the old check passed on a repo that had only the sibling skill's block.
HDREL="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$HD" "$ROOT" 2> /dev/null || echo ".agents/handoff")"
if [ ! -f "$SCRIPT_DIR/splice-agents-block.py" ]; then
  warn "cannot check the AGENTS.md block: splice-agents-block.py not found beside this verifier"
else
python3 "$SCRIPT_DIR/splice-agents-block.py" --check \
  --file "$ROOT/AGENTS.md" \
  --template "$SCRIPT_DIR/../assets/agents-handoff.md" \
  --handoff-dir "$HDREL" 2> /dev/null
case $? in
  0) ok "AGENTS.md routing block present and matches the asset" ;;
  2) warn "AGENTS.md routing block has drifted from the asset — re-run setup-handoff to refresh it" ;;
  3) bad "AGENTS.md routing block missing" ;;
  *) bad "AGENTS.md routing block malformed (duplicated/unbalanced markers) — fix by hand" ;;
esac
fi

echo
echo "3. Wired tools + hard-enforcement primary"
echo "-----------------------------------------"
WIRED=""
HARD=""
check_tool() { # name file marker_event
  local name="$1" file="$2"
  [ -f "$file" ] || return 0
  if grep -qE 'handoff/(scripts/)?hooks\.sh' "$file" 2> /dev/null; then
    if is_json "$file"; then
      ok "$name wired + valid JSON: ${file#$ROOT/}"
      WIRED="${WIRED:+$WIRED }$name"
      # hard enforcement = a pretool-edit (deny) hook is wired for this tool
      local is_primary=0
      grep -q 'pretool-edit' "$file" 2> /dev/null && { HARD="${HARD:+$HARD }$name"; is_primary=1; }
      # Content, not presence: the installer rewrites these on every run, so they only go stale
      # when nobody re-runs it — and the payload stamp cannot see that, because it covers the
      # payload FILES, not the wiring written around them. Compare against what the skill would
      # write now, checking against this file's OWN primary/advisory shape so an advisory tool is
      # not reported as missing the hard-enforcement hooks it is not supposed to have.
      if [ ! -f "$SCRIPT_DIR/merge-hooks.py" ]; then
        rc=99
      else
        HANDOFF_HDPATH="$HDREL" HANDOFF_TOOL="$name" HANDOFF_PRIMARY="$is_primary" \
          python3 "$SCRIPT_DIR/merge-hooks.py" "$file" --check 2> /dev/null
        rc=$?
      fi
      case $rc in
        0) ok "$name hook commands match what setup-handoff writes now" ;;
        2) warn "$name hook commands have drifted — re-run setup-handoff to refresh them" ;;
        *) : ;;   # 3 (not wired) is unreachable here; 99 = helper absent, stay silent
      esac
    else bad "$name config invalid JSON: ${file#$ROOT/}"; fi
  fi
}
check_tool claude "$ROOT/.claude/settings.json"
check_tool claude "$ROOT/.claude/settings.local.json"
check_tool gemini "$ROOT/.gemini/settings.json"
check_tool copilot "$ROOT/.github/hooks/handoff.json"
[ -z "$WIRED" ] && bad "no tool hooks wired (expected at least one)"
if [ -n "$HARD" ]; then
  ok "hard-enforcement primary wired (pretool deny): $HARD"
else
  warn "no hard-enforcement primary (advisory-only) — no tool has a pretool deny gate"
fi

echo
echo "4. Enforcement preflight (python3)"
echo "----------------------------------"
if command -v python3 > /dev/null 2>&1; then
  ok "python3 present — the deny gate can parse hook payloads"
else
  [ -n "$HARD" ] && bad "python3 MISSING but hard enforcement is wired — the gate will fail safe (deny handoff-doc edits)" \
    || warn "python3 missing (advisory-only install; deny gate unavailable)"
fi

echo
echo "5. Hooks fire (read-only paths)"
echo "-------------------------------"
HK="$HD/scripts/hooks.sh"
[ -f "$HK" ] || HK="$HD/hooks.sh" # flat (pre-restructure) board
if [ -f "$HK" ]; then
  # sessionstart: valid JSON context, or empty when no open handoffs — both fine.
  out=$(printf '{"session_id":"verify"}' | bash "$HK" --kind sessionstart --tool claude 2> /dev/null)
  if [ -z "$out" ]; then ok "sessionstart ran cleanly (no open handoffs)"; elif is_json_str "$out"; then ok "sessionstart emitted valid context JSON"; else bad "sessionstart emitted INVALID JSON"; fi

  # pretool on INDEX.md must DENY (generated) — proves the gate fires deterministically.
  out=$(printf '{"session_id":"verify","tool_input":{"file_path":"%s/INDEX.md"}}' "$HD" | bash "$HK" --kind pretool-edit --tool claude 2> /dev/null)
  if is_json_str "$out" && printf '%s' "$out" | grep -qE '"permissionDecision": *"deny"'; then ok "pretool-edit denies editing generated INDEX.md"; else bad "pretool-edit did NOT deny INDEX.md edit"; fi

  # pretool on an ordinary repo file must ALLOW (empty) — never block non-handoff files.
  out=$(printf '{"session_id":"verify","tool_input":{"file_path":"%s/src/app.js"}}' "$ROOT" | bash "$HK" --kind pretool-edit --tool claude 2> /dev/null)
  [ -z "$out" ] && ok "pretool-edit allows ordinary (non-handoff) files" || bad "pretool-edit wrongly acted on an ordinary file"
else
  bad "hooks.sh missing — cannot fire"
fi

echo
echo "6. handoff script runs"
echo "----------------------"
if [ -x "$HD/handoff" ]; then
  "$HD/handoff" list > /dev/null 2>&1 && ok "handoff list runs" || bad "handoff list failed"
  # export must be a recognized subcommand: a nonexistent id should reach id-resolution and fail
  # with "no such handoff", not fall through to the top-level usage catch-all (which would mean
  # export isn't wired into the dispatch at all).
  out=$("$HD/handoff" export __verify-nonexistent__ --no-claim 2>&1)
  if printf '%s' "$out" | grep -q 'no such handoff'; then
    ok "handoff export responds (recognized subcommand)"
  else
    bad "handoff export did not respond as expected: $out"
  fi
else warn "handoff not executable"; fi

echo
echo "Summary: $P passed, $W warnings, $F failed"
if [ "$F" -gt 0 ]; then exit 1; fi
exit 0
