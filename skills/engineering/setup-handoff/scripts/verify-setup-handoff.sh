#!/usr/bin/env bash
# verify-setup-handoff.sh — confirm the handoff protocol is installed AND its hooks fire.
# READ-ONLY: it never claims/releases and never fires the posttool hook (which would
# regenerate INDEX.md). It fires the read-only hook paths (sessionstart, and pretool on
# INDEX.md / an ordinary file) exactly as a tool would, and inspects the wired config.
#
# Usage: ./verify-setup-handoff.sh [/path/to/repo] [--json]   (path defaults to current dir)
#
# --json emits every finding as a machine-readable object instead of prose. This is not a
# convenience: roughly half of what this script checks is ADVISORY by design — staleness, size,
# weak evidence, a missing current state, a board with no remote — and none of it changes the exit
# code. A grader that reads only the exit status cannot see any of it, so those checks would ship
# untested and rot exactly the way the boards they describe did.
#
# Every finding carries a STABLE ID. The id names the CHECK, and `level` carries the outcome, so a
# grader asserts "board.git.remote came back warn" rather than matching on prose that any future
# rewording breaks. Where two outcomes of one check need different remediation, they get different
# ids (payload.version.behind vs payload.version.ahead) — same rule, applied where it earns itself.
set -uo pipefail

# Resolve this script's own directory to an ABSOLUTE path BEFORE the cd below. Everything the
# verifier reads from its own skill (payload.version, merge-hooks.py, splice-agents-block.py, the
# assets) must be reachable after we cd into the target repo. A bare `dirname "$0"` is relative to
# the ORIGINAL cwd, so invoking this script by a relative path silently broke every one of those
# reads once we moved -- and a missing file makes python3 exit 2, which the drift checks below
# would otherwise report as real drift.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

JSON=0
ARGS=""
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    *) ARGS="$a" ;;
  esac
done
TARGET="${ARGS:-$PWD}"
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
# Findings accumulate as TSV (level, id, section, message) and are rendered once at the end. TSV
# rather than JSON-per-line because bash cannot escape JSON safely and the renderer is python3
# anyway; tabs and newlines are stripped from the message so a field can never break the record.
FINDINGS="$(mktemp)"
SECTION=""
trap 'rm -f "$FINDINGS"' EXIT
section() { # human header AND the section label every finding below it carries
  SECTION="$1"
  echo
  echo "$1"
  printf '%s\n' "$(printf '%*s' "${#1}" '' | tr ' ' '-')"
}
emit() { # level id message
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$SECTION" "$(printf '%s' "$3" | tr '\t\n' '  ')" >> "$FINDINGS"
}
ok() { # id message
  emit pass "$1" "$2"
  printf '  [PASS] %s\n' "$2"
  P=$((P + 1))
}
bad() { # id message
  emit fail "$1" "$2"
  printf '  [FAIL] %s\n' "$2"
  F=$((F + 1))
}
warn() { # id message
  emit warn "$1" "$2"
  printf '  [warn] %s\n' "$2"
  W=$((W + 1))
}
# In --json mode the prose goes to /dev/null and the JSON document is written to the real stdout at
# the end. Redirecting the fd rather than guarding ~60 echo sites keeps ONE rendering path: the
# human output and the findings can never disagree, because they are produced by the same call.
if [ "$JSON" = 1 ]; then
  exec 3>&1 1> /dev/null
fi

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
    warn payload.version.unknown "payload version unknown (pre-versioning install) — re-run $skill"
  elif [ "$installed" -lt "$shipped" ] 2> /dev/null; then
    warn payload.version.behind "payload v$installed installed, skill ships v$shipped — re-run $skill"
  elif [ "$installed" -gt "$shipped" ] 2> /dev/null; then
    warn payload.version.ahead "payload v$installed installed is newer than the skill's v$shipped — this $skill copy is stale"
  else
    ok payload.version "payload v$installed matches the version $skill ships"
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
section "1. Payload present + executable"
if [ ! -d "$HD" ]; then
  bad install.present "handoff not installed (no $HD) — run setup-handoff"
  echo
  echo "Summary: $P passed, $W warnings, $F failed"
  exit 1
fi
# hooks.sh lives under scripts/ and the templates under templates/; a board installed before the
# layout restructure still has them flat, which is a warning (re-run the installer to migrate),
# not a failure — the CLI and hooks both fall back to the flat locations.
for f in handoff scripts/hooks.sh; do
  if [ -f "$HD/$f" ]; then
    [ -x "$HD/$f" ] && ok payload.file.executable "$f present and executable" || warn payload.file.executable "$f present but not executable (chmod +x)"
  elif [ -f "$HD/$(basename "$f")" ]; then
    warn payload.layout.flat "$(basename "$f") is at the board root (flat layout) — re-run setup-handoff to migrate to $f"
  else bad payload.file.present "$f missing"; fi
done
[ -f "$HD/README.md" ] && ok payload.readme "README.md present" || warn payload.readme "README.md missing"
# ANY of the three config names counts, newest first. The installer writes `handoff.json`; a board
# installed before the consolidation carries `config.json`, and one older still carries the KEY=value
# `config`. Requiring only the newest name would print "config missing" on every board that simply
# has not been re-installed — a warning that is always wrong trains readers to ignore the ones that
# are not. Which file is present, and whether it parses, is graded in section 2.
BOARD_CFG=""
for c in "$HD/handoff.json" "$HD/config.json" "$HD/config"; do
  [ -f "$c" ] && [ -z "$BOARD_CFG" ] && BOARD_CFG="$c"
done
if [ -n "$BOARD_CFG" ]; then
  ok board.config.present "board config present ($(basename "$BOARD_CFG"))"
else
  warn board.config.present "no board config (handoff.json, or the legacy config.json / config) — re-run setup-handoff"
fi
if [ -f "$HD/templates/handoff-doc-template.md" ]; then
  ok board.template.doc "templates/handoff-doc-template.md present"
elif [ -f "$HD/handoff-doc-template.md" ]; then
  warn board.template.doc.flat "handoff-doc-template.md is at the board root (flat layout) — re-run setup-handoff to migrate"
else warn board.template.doc "handoff-doc-template.md missing"; fi
if [ -f "$HD/templates/handoff-brief-template.md" ]; then
  ok board.template.brief "templates/handoff-brief-template.md present"
elif [ -f "$HD/handoff-brief-template.md" ]; then
  warn board.template.brief.flat "handoff-brief-template.md is at the board root (flat layout) — re-run setup-handoff to migrate"
else warn board.template.brief "handoff-brief-template.md missing — re-run setup-handoff"; fi
[ -d "$HD/archive" ] && ok board.archive "archive/ present" || warn board.archive "archive/ missing (created on first done)"
# The stamp now rides inside the board's own config rather than in a file of its own. Read from
# there first, then from the standalone `.version` that a board written before the consolidation
# still carries, so a stale board reports as behind rather than as unstamped.
installed_payload_version() {
  local v=""
  if [ -f "$HD/handoff.json" ] && command -v python3 > /dev/null 2>&1; then
    v="$(python3 -c 'import json,sys
try: d = json.load(open(sys.argv[1]))
except Exception: raise SystemExit(0)
g = d.get("_generated") or {}
print(str(g.get("payloadVersion") or "").split(" ")[-1])' "$HD/handoff.json" 2> /dev/null)"
  fi
  [ -n "$v" ] || v="$(awk 'NR==1{print $2}' "$HD/.version" 2> /dev/null)"
  printf '%s' "$v"
}
check_payload_version "$(installed_payload_version)" setup-handoff

# The DOCUMENT schema, which is a different number from the payload beside it and the only one that
# triggers a migration (ADR 0003). Reported in both directions: a board BEHIND the payload wants
# `handoff migrate`, a board AHEAD of it wants the payload updated first, and telling someone to do
# the wrong one of those wastes a whole-board rewrite.
CLI_SCHEMA="$(sed -n 's/^SCHEMA_VERSION=//p' "$SCRIPT_DIR/payload/handoff" 2> /dev/null | head -1)"
BOARD_SCHEMA=""
if [ -f "$HD/handoff.json" ] && command -v python3 > /dev/null 2>&1; then
  BOARD_SCHEMA="$(python3 -c 'import json,sys
try: d = json.load(open(sys.argv[1]))
except Exception: raise SystemExit(0)
v = d.get("schema")
print(v if isinstance(v, int) else "")' "$HD/handoff.json" 2> /dev/null)"
fi
if [ -n "$CLI_SCHEMA" ] && [ -n "$BOARD_SCHEMA" ]; then
  if [ "$BOARD_SCHEMA" -lt "$CLI_SCHEMA" ]; then
    warn board.schema.behind "board is document schema $BOARD_SCHEMA, this skill ships $CLI_SCHEMA — run './handoff migrate' (reads are unaffected; writes to newer docs are refused)"
  elif [ "$BOARD_SCHEMA" -gt "$CLI_SCHEMA" ]; then
    warn board.schema.ahead "board is document schema $BOARD_SCHEMA, NEWER than the $CLI_SCHEMA this skill ships — update the payload (re-run setup-handoff) before editing anything here"
  else
    ok board.schema "board document schema $BOARD_SCHEMA matches what the skill ships"
  fi
fi

section "2. Config, gitignore, AGENTS.md block"
TOPO=""
# CONFIG_JSON_BAD tracks whether the "not valid JSON" FAIL below already fired, so the resolver
# failure a few lines down (same root cause — it re-reads this same file) reports it once, not
# twice. Two FAILs for one malformed config.json would double-count the same underlying problem.
CONFIG_JSON_BAD=""
if [ -n "$BOARD_CFG" ]; then
  BOARD_CFG_NAME="$(basename "$BOARD_CFG")"
  if [ "$BOARD_CFG_NAME" != "config" ]; then
    if is_json "$BOARD_CFG"; then ok board.config.json_valid "$BOARD_CFG_NAME present and valid JSON"; else
      bad board.config.json_valid "$BOARD_CFG_NAME is not valid JSON"
      CONFIG_JSON_BAD=1
    fi
    # python3 is not optional once a JSON config exists: every read of it needs one.
    command -v python3 > /dev/null 2>&1 || bad board.config.python3 "$BOARD_CFG_NAME present but python3 missing — the board cannot read its own config"
    [ "$BOARD_CFG_NAME" = "config.json" ] \
      && warn board.config.legacy_name "board config is still config.json — re-run setup-handoff to consolidate it into handoff.json"
  else
    warn board.config.legacy_shell "legacy shell config (no handoff.json) — re-run setup-handoff to migrate"
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
      ok board.config.effective "effective config: topology=$HC_TOPOLOGY ttlHours=$HC_TTL_HOURS allowVerifyCmd=$HC_ALLOW_VERIFY_CMD group=${HC_GROUP:-none}"
      case "$HC_TOPOLOGY" in single-repo | cross-repo) ok board.config.topology "topology valid: $HC_TOPOLOGY" ;; *) bad board.config.topology "invalid topology: $HC_TOPOLOGY" ;; esac
      TOPO="$HC_TOPOLOGY"
    elif [ -n "$CONFIG_JSON_BAD" ]; then
      : # already reported as invalid JSON above — same root cause, don't double-FAIL
    else bad board.config.resolvable "config could not be resolved (malformed?): $_hc_out"; fi
  else warn board.config.resolver_present "scripts/config.sh missing — re-run setup-handoff"; fi
else bad board.config.present "config missing (no handoff.json)"; fi
# A typo'd key is inert and silent today; name it. Unknown keys are a warning, not a failure —
# a future payload may add keys this verifier predates. A file that fails to parse must NOT
# report either PASS or WARN here: exit 2 (distinct from the "found unknown keys" success path)
# is how the python side tells the shell "could not check" from "checked, found nothing" — the
# malformed-JSON FAIL above already covers that condition, so this check stays silent rather
# than printing a false PASS for a check it never actually performed.
if [ -n "$BOARD_CFG" ] && [ "$(basename "$BOARD_CFG")" != "config" ] && command -v python3 > /dev/null 2>&1; then
  UNKNOWN="$(python3 -c '
import json,sys
known={"topology","repoName","group","groups","groupLayout","ttlHours","allowVerifyCmd",
       "board","boardPath","environments","layout","boardRemote","locations","repo",
       "schema","_generated"}
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(2)
if not isinstance(d, dict): sys.exit(2)
print(",".join(sorted(set(d)-known)))' "$BOARD_CFG" 2> /dev/null)"
  RC=$?
  if [ "$RC" -eq 0 ]; then
    [ -n "$UNKNOWN" ] && warn board.config.unknown_keys "$BOARD_CFG_NAME has unknown key(s): $UNKNOWN" || ok board.config.unknown_keys "$BOARD_CFG_NAME keys all recognised"
  fi
fi
if [ "$TOPO" = "cross-repo" ]; then
  # A shared board lives outside the worktree and owns its own .gitignore, so a consumer `.locks/`
  # entry would be inert. What matters instead is the board's own substrate (ADR 0002): is it a
  # repository, does it have a remote, and does its lease rule match the answer? A board that
  # ignores `.locks/` while having a remote is the quiet failure — push-CAS still runs, still
  # commits nothing, and still reports success, so every machine believes it holds every lease.
  BOARD_TOP="$(git -C "$HD" rev-parse --show-toplevel 2> /dev/null || true)"
  if [ -z "$BOARD_TOP" ] || [ "$(cd "$BOARD_TOP" 2> /dev/null && pwd -P)" != "$(cd "$HD" && pwd -P)" ]; then
    warn board.git.own_repo "the board at $HD is not its own git repository — it has no history and cannot be shared. Re-run setup-handoff --board-only on it."
  else
    ok board.git.own_repo "the board is its own git repository"
    if [ -n "$(git -C "$HD" remote 2> /dev/null)" ]; then
      ok board.git.remote "the board has a remote — leases are shared state"
      grep -qxF '.locks/' "$HD/.gitignore" 2> /dev/null \
        && warn board.git.lease_visibility "the board has a remote but still gitignores .locks/ — leases never travel, so push-CAS excludes nobody. Remove that line (the CLI also repairs it on the next claim)." \
        || ok board.git.lease_visibility "the board's .locks/ is tracked, as a remote-backed board requires"
    else
      warn board.git.remote "the board at $HD has NO REMOTE — versioned, but it still reaches exactly one machine. Add one: git -C $HD remote add origin <url>"
      grep -qxF '.locks/' "$HD/.gitignore" 2> /dev/null \
        && ok board.git.lease_visibility "the board gitignores .locks/, as a local-only board should" \
        || warn board.git.lease_visibility "a local-only board should gitignore .locks/ (leases are machine state until the board has a remote)"
    fi
  fi
else
  grep -q '/.locks/' .gitignore 2> /dev/null && ok repo.gitignore.locks ".gitignore excludes .locks/" || warn repo.gitignore.locks ".gitignore missing a .locks/ entry — leases could get committed"
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
  warn agents.block.checkable "cannot check the AGENTS.md block: splice-agents-block.py not found beside this verifier"
else
  python3 "$SCRIPT_DIR/splice-agents-block.py" --check \
    --file "$ROOT/AGENTS.md" \
    --template "$SCRIPT_DIR/../assets/agents-handoff.md" \
    --handoff-dir "$HDREL" 2> /dev/null
  case $? in
    0) ok agents.block "AGENTS.md routing block present and matches the asset" ;;
    2) warn agents.block.drift "AGENTS.md routing block has drifted from the asset — re-run setup-handoff to refresh it" ;;
    3) bad agents.block "AGENTS.md routing block missing" ;;
    *) bad agents.block.malformed "AGENTS.md routing block malformed (duplicated/unbalanced markers) — fix by hand" ;;
  esac
fi

section "3. Wired tools + hard-enforcement primary"
WIRED=""
HARD=""
check_tool() { # name file marker_event
  local name="$1" file="$2"
  [ -f "$file" ] || return 0
  if grep -qE 'handoff/(scripts/)?hooks\.sh' "$file" 2> /dev/null; then
    if is_json "$file"; then
      ok tool.wired "$name wired + valid JSON: ${file#$ROOT/}"
      WIRED="${WIRED:+$WIRED }$name"
      # hard enforcement = a pretool-edit (deny) hook is wired for this tool
      local is_primary=0
      grep -q 'pretool-edit' "$file" 2> /dev/null && {
        HARD="${HARD:+$HARD }$name"
        is_primary=1
      }
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
        0) ok tool.hook.current "$name hook commands match what setup-handoff writes now" ;;
        2) warn tool.hook.current "$name hook commands have drifted — re-run setup-handoff to refresh them" ;;
        *) : ;; # 3 (not wired) is unreachable here; 99 = helper absent, stay silent
      esac
    else bad tool.config.json_valid "$name config invalid JSON: ${file#$ROOT/}"; fi
  fi
}
check_tool claude "$ROOT/.claude/settings.json"
check_tool claude "$ROOT/.claude/settings.local.json"
check_tool gemini "$ROOT/.gemini/settings.json"
check_tool copilot "$ROOT/.github/hooks/handoff.json"
[ -z "$WIRED" ] && bad tool.wired.any "no tool hooks wired (expected at least one)"
if [ -n "$HARD" ]; then
  ok tool.primary.hard "hard-enforcement primary wired (pretool deny): $HARD"
else
  warn tool.primary.hard "no hard-enforcement primary (advisory-only) — no tool has a pretool deny gate"
fi

section "4. Enforcement preflight (python3)"
if command -v python3 > /dev/null 2>&1; then
  ok enforcement.python3 "python3 present — the deny gate can parse hook payloads"
else
  [ -n "$HARD" ] && bad enforcement.python3 "python3 MISSING but hard enforcement is wired — the gate will fail safe (deny handoff-doc edits)" \
    || warn enforcement.python3 "python3 missing (advisory-only install; deny gate unavailable)"
fi

section "5. Hooks fire (read-only paths)"
HK="$HD/scripts/hooks.sh"
[ -f "$HK" ] || HK="$HD/hooks.sh" # flat (pre-restructure) board
if [ -f "$HK" ]; then
  # sessionstart: valid JSON context, or empty when no open handoffs — both fine.
  out=$(printf '{"session_id":"verify"}' | bash "$HK" --kind sessionstart --tool claude 2> /dev/null)
  if [ -z "$out" ]; then ok hook.sessionstart "sessionstart ran cleanly (no open handoffs)"; elif is_json_str "$out"; then ok hook.sessionstart "sessionstart emitted valid context JSON"; else bad hook.sessionstart "sessionstart emitted INVALID JSON"; fi

  # pretool on INDEX.md must DENY (generated) — proves the gate fires deterministically.
  out=$(printf '{"session_id":"verify","tool_input":{"file_path":"%s/INDEX.md"}}' "$HD" | bash "$HK" --kind pretool-edit --tool claude 2> /dev/null)
  if is_json_str "$out" && printf '%s' "$out" | grep -qE '"permissionDecision": *"deny"'; then ok hook.pretool.deny_index "pretool-edit denies editing generated INDEX.md"; else bad hook.pretool.deny_index "pretool-edit did NOT deny INDEX.md edit"; fi

  # pretool on an ordinary repo file must ALLOW (empty) — never block non-handoff files.
  out=$(printf '{"session_id":"verify","tool_input":{"file_path":"%s/src/app.js"}}' "$ROOT" | bash "$HK" --kind pretool-edit --tool claude 2> /dev/null)
  [ -z "$out" ] && ok hook.pretool.allow_ordinary "pretool-edit allows ordinary (non-handoff) files" || bad hook.pretool.allow_ordinary "pretool-edit wrongly acted on an ordinary file"
else
  bad hook.present "hooks.sh missing — cannot fire"
fi

section "6. handoff script runs"
# Board and binary are separate: <board>/handoff is a dispatcher that execs a CLI found via
# $HANDOFF_BIN, the user-level install, or the board's vendored copy. Report WHICH answered —
# "the CLI works" is not a useful finding when three of them could have run and the stale one did.
if [ -x "$HD/handoff" ]; then
  CLI_WHICH="$("$HD/handoff" --which 2> /dev/null | sed -n '1,2p' | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^CLI //' -e 's/ *$//')"
  if [ -n "$CLI_WHICH" ]; then
    ok cli.resolves "CLI resolves — $CLI_WHICH"
  else
    # Either nothing resolved (the dispatcher already said so on stderr) or this is a pre-split
    # board whose root file IS the CLI. Both run; neither can name its source.
    warn cli.resolves "could not determine which CLI answers for this board (pre-split board, or none resolves) — run: $HD/handoff --which"
  fi
  "$HD/handoff" list > /dev/null 2>&1 && ok cli.list "handoff list runs" || bad cli.list "handoff list failed"
  # export must be a recognized subcommand: a nonexistent id should reach id-resolution and fail
  # with "no such handoff", not fall through to the top-level usage catch-all (which would mean
  # export isn't wired into the dispatch at all).
  out=$("$HD/handoff" export __verify-nonexistent__ --no-claim 2>&1)
  if printf '%s' "$out" | grep -q 'no such handoff'; then
    ok cli.export "handoff export responds (recognized subcommand)"
  else
    bad cli.export "handoff export did not respond as expected: $out"
  fi
else warn cli.executable "handoff not executable"; fi

section "7. Document schema (advisory — ADR 0004)"
# Every finding in this section is ADVISORY. None of it blocks anything, and that is the design:
# `depends_on` is about whether work can start, and work legitimately starts out of order. What a
# board cannot survive is these things being invisible — the two live boards that motivated this
# schema recorded their dependency graph in prose, folded closure evidence into an activity log,
# and grew hand-rolled "Resolution (date)" headings because the template had nowhere to put the
# current state. Reporting is the whole intervention.
SCHEMA_DOCS=0 SCHEMA_STALE=0 SCHEMA_OLD=0 SCHEMA_NEW=0 SENS_RESTRICTED=0
fm() { sed -n '2,/^---$/p' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1; }

# The audit half of the write-path scanner (ADR 0005). The rules are LIFTED OUT OF THE SHIPPED CLI
# rather than restated here: two copies of a credential-pattern list is two copies that drift, and
# the one that drifts is always the one nobody runs interactively. The CLI cannot simply be sourced
# — the board's own copy may be an older payload that has no scanner at all, which is precisely the
# board this sweep is for — so its rules table is read as data.
#
# The sweep catches what the write path cannot: a secret pasted into a doc by hand, or committed
# before this payload was installed. It never prints what it matched, only which rule fired.
SECRET_RULES="$(awk "/cat << 'RULES'/{f=1;next} f&&/^RULES\$/{exit} f" "$SCRIPT_DIR/payload/handoff" 2> /dev/null)"
NOW_S="$(date +%s)"
while IFS= read -r doc; do
  [ -f "$doc" ] || continue
  SCHEMA_DOCS=$((SCHEMA_DOCS + 1))
  dname="$(basename "$doc")"
  dtype="$(fm "$doc" type)"
  dtype="${dtype:-coordination}"
  # An archived doc is closed. Its shape is history and nobody is going to restructure it, so only
  # the evidence check applies — that one is an audit question ("can this closure be re-checked?")
  # and it is the ONLY place it can be asked, since `done` archives the doc that carries it.
  darch=0
  case "$doc" in */archive/*) darch=1 ;; esac

  # A board id sitting in `blocked_on` is not wrong, it is just in the field that cannot be
  # checked. `depends_on` renders as a real edge and can be warned on at claim time; free text
  # cannot, which is why the two fields exist separately.
  bo=""
  [ "$darch" = 1 ] || bo="$(fm "$doc" blocked_on)"
  case "$bo" in
    "" | external* | decision* | 'external —'* | 'decision —'*) ;;
    *) warn doc.blocked_on.is_board_id "$dname: blocked_on names \"$bo\", which looks like a board id — that belongs in depends_on (blocked_on is for what the board cannot model)" ;;
  esac

  # Closure evidence that names no command, no file, and no commit is a claim about somebody's
  # memory. It is still recorded and still closes the doc; it just cannot be re-checked by the
  # next reader, which is the entire purpose of writing it down.
  vb="$(fm "$doc" verified_by)"
  vb="${vb%\"}"
  vb="${vb#\"}" # stored quoted so a file:line survives; compare the value, not the quoting
  if [ -n "$vb" ]; then
    # Deliberately generous. The question is not "is this good evidence" — no pattern can answer
    # that — it is "does this name ANYTHING a second person could go and look at". A colon-numbered
    # location, a path, a flagged command, a sha, or the words test/spec/commit all pass. What
    # fails is prose: "works now", "confirmed with the team", "looks right".
    case "$vb" in
      *:[0-9]* | */*[a-z]* | *' -'[a-z-]* | *' --'[a-z-]* | *test* | *spec* | *commit* | *sha* | *exit* | *'()'*) ;;
      *) warn doc.evidence.unverifiable "$dname: verified_by (\"$vb\") names no command, file reference, or commit — nobody can re-check it" ;;
    esac
  fi

  # `sensitivity` (ADR 0005). Absent reads as `normal` and is NOT reported — migrate deliberately
  # never backfills it, so on any board that predates this field every document would be flagged,
  # which teaches people to skip the section. Only a value that is neither of the two is a defect:
  # a typo'd `sensitivity: restrcted` reads as normal to every gate in the CLI, silently.
  dsens="$(fm "$doc" sensitivity)"
  case "$dsens" in
    "" | normal) ;;
    restricted) SENS_RESTRICTED=$((SENS_RESTRICTED + 1)) ;;
    *) warn doc.sensitivity.invalid "$dname: sensitivity is \"$dsens\", which is neither normal nor restricted — every gate in the CLI reads it as normal. Fix it or remove it." ;;
  esac

  # Credential sweep. A FAIL, not a warning, and the only one in this advisory section: everything
  # else here describes a board that is merely hard to work with, and this one describes material
  # that is already in git history and needs rotating, not editing.
  if [ -n "$SECRET_RULES" ]; then
    dhits="" dwaived=""
    while IFS="$(printf '\t')" read -r srule sre; do
      [ -n "$srule" ] || continue
      grep -Eq -- "$sre" "$doc" 2> /dev/null || continue
      # An override the CLI recorded on this doc's own activity log, naming this same rule, is a
      # decision somebody made and signed. Reporting it as a FAIL forever would mean a board with
      # one legitimate vendor example key can never come back clean, and a check that can never
      # pass gets ignored wholesale. It stays visible as a warning — never silent — because the
      # decision is auditable, not because it is right.
      if grep -q "secret-scan OVERRIDDEN.*($srule" "$doc" 2> /dev/null; then
        dwaived="${dwaived:+$dwaived, }$srule"
      else
        dhits="${dhits:+$dhits, }$srule"
      fi
    done <<< "$SECRET_RULES"
    [ -n "$dhits" ] \
      && bad doc.secret.detected "$dname: matches credential pattern(s) $dhits — this doc is in git history, so redact it AND rotate the credential. (Never paste the value into a handoff; record its name.)"
    [ -n "$dwaived" ] \
      && warn doc.secret.overridden "$dname: matches credential pattern(s) $dwaived, with a recorded --force-secret override on the doc — re-read the stated reason and confirm it still holds"
  fi

  # Rewritable current state. Its absence is why boards sprout "Resolution (date)" and "Execution
  # log (date)" headings: people need somewhere to say where things stand, and append-only activity
  # is not it.
  case "$dtype" in
    coordination | orchestrator)
      [ "$darch" = 1 ] && continue
      grep -q '^## Current state' "$doc" \
        || warn doc.current_state.missing "$dname: no '## Current state' section — a reader has to reconstruct where this stands from the activity log"
      ;;
  esac

  # Documents that predate the board's schema. Counted below rather than warned here, for the same
  # reason staleness is: a board mid-upgrade has many, and one warning each teaches people to skip
  # the section.
  dsch="$(fm "$doc" schema)"
  case "$dsch" in '' | *[!0-9]*) dsch=0 ;; esac
  [ -n "$CLI_SCHEMA" ] && [ "$dsch" -lt "$CLI_SCHEMA" ] && SCHEMA_OLD=$((SCHEMA_OLD + 1))
  [ -n "$CLI_SCHEMA" ] && [ "$dsch" -gt "$CLI_SCHEMA" ] && SCHEMA_NEW=$((SCHEMA_NEW + 1))

  # A bundle whose roster names documents that were never filed can never close, and until now
  # nothing said so. DETECT-ONLY, deliberately: declaring a roster before authoring its docs is
  # legitimate planning. The bug is never being told, and having no cheap way to close the gap —
  # `handoff children add --stub` is that way.
  if [ "$dtype" = "orchestrator" ] && [ "$darch" = 0 ]; then
    kids="$(sed -n 's/^children:[[:space:]]*//p' "$doc" | head -1 | tr -d '[]' | tr ',' ' ')"
    dangling=""
    for k in $kids; do
      [ -n "$k" ] || continue
      [ -f "$(dirname "$doc")/$k.md" ] || [ -f "$(dirname "$doc")/archive/$k.md" ] \
        || dangling="${dangling:+$dangling }$k"
    done
    if [ -n "$dangling" ]; then
      dcount="$(printf '%s' "$dangling" | wc -w | tr -d ' ')"
      dshow="$(printf '%s' "$dangling" | cut -d' ' -f1-5)"
      [ "$dcount" -gt 5 ] && dshow="$dshow … and $((dcount - 5)) more"
      warn bundle.children.dangling "$dname: $dcount child(ren) named but never filed ($dshow) — this bundle can never close. File them, or: handoff children add --stub $(basename "$doc" .md) <id>"
    else
      ok bundle.children.dangling "$dname: every child on its roster is a real doc"
    fi
  fi

  # Size. A document nobody will read coordinates nobody; the boards that motivated this carried
  # one of 1401 lines. Standalone/reference docs are exempt — length is what they are for.
  if [ "$dtype" != "standalone" ] && [ "$darch" = 0 ]; then
    lines="$(wc -l < "$doc" | tr -d ' ')"
    [ "${lines:-0}" -gt 400 ] \
      && warn doc.size.oversized "$dname: $lines lines — past ~400 a coordination doc has stopped being one unit of work; split it"
  fi

  # Staleness is COUNTED, never warned per document. A board with 143 open handoffs would emit 143
  # warnings and teach everyone to ignore the section.
  upd="$(fm "$doc" updated)"
  if [ -n "$upd" ] && [ "$darch" = 0 ] && [ "$(fm "$doc" status)" != "done" ]; then
    upd_s="$(date -j -f '%Y-%m-%d' "$upd" +%s 2> /dev/null || date -d "$upd" +%s 2> /dev/null || echo "")"
    [ -n "$upd_s" ] && [ "$(((NOW_S - upd_s) / 86400))" -gt 30 ] && SCHEMA_STALE=$((SCHEMA_STALE + 1))
  fi
done <<< "$(find "$HD" -maxdepth 3 -name '*-handoff.md' 2> /dev/null)"

if [ "$SCHEMA_DOCS" -eq 0 ]; then
  ok board.docs.none "no handoff docs on this board yet — nothing to check"
else
  # Reported at every count, including zero, and always as a PASS. Holding restricted work is not a
  # defect — it is the field doing its job — so this is an audit line, not a warning. What it
  # answers is "how much of this board must never leave it", which is the question somebody asks
  # before widening board membership or wiring up a delegated agent.
  ok board.sensitivity.restricted "$SENS_RESTRICTED of $SCHEMA_DOCS doc(s) are sensitivity: restricted — never exported, never delegated (a handling flag; board membership is the access boundary)"
  [ "$SCHEMA_STALE" -gt 0 ] \
    && warn board.staleness "$SCHEMA_STALE of $SCHEMA_DOCS open doc(s) have not been updated in over 30 days — the board is accumulating, not closing" \
    || ok board.staleness "no open doc has gone 30 days without an update"
  if [ "$SCHEMA_NEW" -gt 0 ]; then
    warn doc.schema.ahead "$SCHEMA_NEW of $SCHEMA_DOCS doc(s) are NEWER than schema $CLI_SCHEMA — this payload can read them but refuses to write them. Re-run setup-handoff."
  elif [ "$SCHEMA_OLD" -gt 0 ]; then
    warn doc.schema.behind "$SCHEMA_OLD of $SCHEMA_DOCS doc(s) predate schema $CLI_SCHEMA — run './handoff migrate'. Reads and writes both still work."
  else
    ok doc.schema "every doc is at schema ${CLI_SCHEMA:-?}"
  fi
fi

echo
echo "Summary: $P passed, $W warnings, $F failed"

if [ "$JSON" = 1 ]; then
  exec 1>&3
  python3 - "$FINDINGS" "$HD" "$ROOT" "$P" "$W" "$F" << 'PY'
import json, sys

path, board, root, npass, nwarn, nfail = sys.argv[1:7]
findings = []
with open(path) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 4:
            continue
        level, fid, section, message = parts
        findings.append({"id": fid, "level": level, "section": section, "message": message})

print(json.dumps({
    "tool": "verify-setup-handoff",
    # Bumped only when the SHAPE changes. A consumer pins this, not the set of ids: ids are added
    # over time by design, and a grader that broke every time a new check appeared would be
    # abandoned within a release.
    "schema": 1,
    "repo": root,
    "board": board,
    "summary": {"pass": int(npass), "warn": int(nwarn), "fail": int(nfail)},
    "findings": findings,
}, indent=2, sort_keys=True))
PY
fi
if [ "$F" -gt 0 ]; then exit 1; fi
exit 0
