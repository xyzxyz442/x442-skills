#!/usr/bin/env bash
# verify-cross-repo-handoff.sh — read-only health probe for a cross-repo handoff fleet.
#
#   verify-cross-repo-handoff.sh <dir> | --scope <dir> [--from <dir>] [--json]
#
# Confirms the manifest cascade parses, each board is scaffolded with the expected group facts, each
# member repo is wired to its board + section, the AGENTS.md block matches the resolved set, and
# each board's handoff.json still projects the manifest (the file `handoff export` resolves a
# cross-repo brief's target repo from — drift there is what silently degrades every brief).
# Distinguishes "not configured" (no manifest -> exit 0) from "broken" (-> exit 1). Writes nothing.
#
# --json emits every finding as a machine-readable object instead of prose. This is not a
# convenience: a chunk of what this script checks is ADVISORY by design — a missing sub-index, a
# registry advisory, a board with no remote — and none of it changes the exit code. A grader that
# reads only the exit status cannot see any of it, so those checks would ship untested and rot
# exactly the way the boards they describe did.
#
# Every finding carries a STABLE ID. The id names the CHECK, and `level` carries the outcome, so a
# grader asserts "board.groups came back fail" rather than matching on prose that any future
# rewording breaks. Where two outcomes of one check need genuinely different remediation, they get
# different ids — the same rule sibling verify-setup-handoff.sh follows, applied here only where it
# earns itself.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVE="$SKILL_DIR/scripts/manifest/resolve.py"
REGISTRY="$SKILL_DIR/scripts/manifest/registry.py"
# The payload's own config resolver, used here instead of grepping a filename. Board facts live in
# handoff.json on any board the current installer wrote, in a legacy config.json or KEY=value
# `config` on older ones, and a member repo's own identity lives in its .agents/handoff.json — with a
# precedence between them. This file already decides all of that for `handoff` and `hooks.sh`;
# re-deriving it here is how this verifier came to report FAIL on every healthy board.
#
# Prefer the SKILL's copy over the board's: it is current by construction, and auditing a board is
# not a reason to execute shell that lives inside it. The board's copy is only a fallback for a
# checkout where the setup-handoff sibling is absent.
PAYLOAD_CONFIG_SH="$SKILL_DIR/../setup-handoff/scripts/payload/config.sh"

SCOPE="" FROM="" JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --scope)
      SCOPE="${2:-}"
      shift 2
      ;;
    --from)
      FROM="${2:-}"
      shift 2
      ;;
    --json)
      JSON=1
      shift 1
      ;;
    -*)
      echo "verify: unknown arg: $1" >&2
      exit 2
      ;;
    *)
      # A BARE positional is the scope. The sibling verify-setup-handoff.sh takes its target that
      # way, and harness/lib/grade_common.py's verify_findings() invokes every verifier as
      # `bash <script> <target> --json` — so without this, one shared grader helper could not drive
      # both verifiers and this one's findings would be ungradeable. `--scope` still works and still
      # wins; this only stops the positional form from being an error.
      [ -n "$SCOPE" ] || SCOPE="$1"
      shift 1
      ;;
  esac
done
[ -n "$SCOPE" ] || {
  echo "usage: verify-cross-repo-handoff.sh <dir> | --scope <dir> [--from <dir>] [--json]" >&2
  exit 2
}
[ -n "$FROM" ] || FROM="$SCOPE"
command -v python3 > /dev/null 2>&1 || {
  echo "verify: python3 required" >&2
  exit 2
}

PASS=0 WARN=0 FAIL=0
# Findings accumulate as TSV (level, id, section, message) and are rendered once at the end, mirroring
# verify-setup-handoff.sh. TSV rather than JSON-per-line because bash cannot escape JSON safely and
# the renderer is python3 anyway; tabs and newlines are stripped from the message so a field can never
# break the record.
FINDINGS="$(mktemp)"
SECTION=""
trap 'rm -f "$FINDINGS"' EXIT
section() { # human header AND the section label every finding below it carries
  SECTION="$1"
  echo "$1"
  printf '%s\n' "$(printf '%*s' "${#1}" '' | tr ' ' '-')"
}
emit() { # level id message
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$SECTION" "$(printf '%s' "$3" | tr '\t\n' '  ')" >> "$FINDINGS"
}
pass() { # id message
  emit pass "$1" "$2"
  echo "  [PASS] $2"
  PASS=$((PASS + 1))
}
warn() { # id message
  emit warn "$1" "$2"
  echo "  [warn] $2"
  WARN=$((WARN + 1))
}
fail() { # id message
  emit fail "$1" "$2"
  echo "  [FAIL] $2"
  FAIL=$((FAIL + 1))
}
# In --json mode the prose goes to /dev/null and the JSON document is written to the real stdout at
# the end. Redirecting the fd rather than guarding every echo site keeps ONE rendering path: the
# human output and the findings can never disagree, because they are produced by the same call.
if [ "$JSON" = 1 ]; then
  exec 3>&1 1> /dev/null
fi
# Renders the accumulated findings as JSON on the REAL stdout (fd 3). Callers must `exec 1>&3` first
# — this is called from both the "not configured" short-circuit and the normal end of script, so it
# is a function rather than inlined once.
render_json() {
  python3 - "$FINDINGS" "$SCOPE" "$FROM" "$PASS" "$WARN" "$FAIL" << 'PY'
import json, sys

path, scope, from_, npass, nwarn, nfail = sys.argv[1:7]
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
    "tool": "verify-cross-repo-handoff",
    # Bumped only when the SHAPE changes. A consumer pins this, not the set of ids: ids are added
    # over time by design, and a grader that broke every time a new check appeared would be
    # abandoned within a release.
    "schema": 1,
    "scope": scope,
    "from": from_,
    "summary": {"pass": int(npass), "warn": int(nwarn), "fail": int(nfail)},
    "findings": findings,
}, indent=2, sort_keys=True))
PY
}

# Print one board's (optionally one member repo's) effective config as HC_* assignments, via the
# payload resolver. Non-zero + no output when it cannot be resolved, so a caller must branch on the
# status BEFORE eval-ing: `eval "$(f)"` reports eval's own status, never the callee's, and a silent
# empty eval would leave the PREVIOUS board's HC_* values in scope and grade this board on them.
board_config() { # board-dir [repo-dir] -> HC_* assignments
  local board="$1" repo="${2:-}" src=""
  : > "$CFG_ERR"
  if [ -f "$PAYLOAD_CONFIG_SH" ]; then
    src="$PAYLOAD_CONFIG_SH"
  elif [ -f "$board/scripts/config.sh" ]; then
    src="$board/scripts/config.sh"
  else
    echo "no config resolver found (setup-handoff payload missing beside this skill, and the board ships none)" > "$CFG_ERR"
    return 1
  fi
  # shellcheck disable=SC1090
  . "$src" || return 1
  # The resolver names the offending file and the parse error on stderr. Captured rather than let
  # loose so it lands INSIDE the [FAIL] line it explains, instead of as a stray line between checks
  # that reads like output from whichever check happens to print next.
  handoff_config_load "$board" "$repo" 2> "$CFG_ERR"
}

# The captured reason from the last board_config call, or the caller's fallback wording.
cfg_reason() { # fallback -> one-line reason
  local r
  r="$(tail -1 "$CFG_ERR" 2> /dev/null)"
  printf '%s' "${r:-$1}"
}

# "not configured" short-circuit: no manifest anywhere in the cascade. Still print a Summary line so
# the harness (which parses exactly that line) sees a clean, gradeable result rather than no output.
# Any layer of the cascade, under either name. A workspace that declares its fleet in the current
# `.agents/handoff.json` is configured just as much as one still using `.handoff-repos.json`.
if [ ! -f "$SCOPE/.agents/handoff.json" ] && [ ! -f "$SCOPE/.handoff-repos.json" ] \
  && [ ! -f "$HOME/.agents/handoff.json" ] && [ ! -f "$HOME/.agents/handoff-repos.json" ]; then
  echo "verify: no handoff manifest in scope or user layer — nothing to verify (not configured)."
  # A finding, not just an empty document. "Not configured" and "the verifier produced nothing" are
  # different states with the same all-zero summary, and a grader reading only the summary cannot
  # tell them apart — which is the exact blindness --json exists to remove. The human line above is
  # unchanged; this only gives the machine reader the same sentence. Mirrors the sibling's
  # `board.docs.none`.
  SECTION="0. manifest cascade"
  emit pass manifest.not_configured "no handoff manifest in scope or user layer — nothing to verify"
  PASS=1
  echo "Summary: 1 passed, 0 warnings, 0 failed"
  if [ "$JSON" = 1 ]; then
    exec 1>&3
    render_json
  fi
  exit 0
fi

RESOLVED="$(mktemp)"
CFG_ERR="$(mktemp)"
trap 'rm -f "$RESOLVED" "$CFG_ERR" "$FINDINGS"' EXIT
python3 "$RESOLVE" --scope "$SCOPE" --from "$FROM" > "$RESOLVED"
RES_RC=$?

section "1. manifest cascade"
# parse errors are FAILs (a missing repo, bad JSON, bad alias)
while IFS= read -r line; do [ -n "$line" ] && fail manifest.cascade.error "$line"; done < <(
  python3 - "$RESOLVED" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for e in d.get("errors", []):
    print(e)
PY
)
[ "$RES_RC" = 0 ] && pass manifest.cascade.resolves "cascade resolves with no errors"
while IFS= read -r line; do [ -n "$line" ] && warn manifest.cascade.warning "$line"; done < <(
  python3 - "$RESOLVED" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for w in d.get("warnings", []):
    print(w)
PY
)

echo
section "2. boards"
# BOARD<TAB>path<TAB>groups_csv<TAB>layout
while IFS=$'\t' read -r path groups layout; do
  [ -n "$path" ] || continue
  if [ -x "$path/handoff" ] && [ -f "$path/scripts/hooks.sh" ]; then
    pass board.payload "board $path has payload"
  else
    fail board.payload "board $path missing payload (handoff / scripts/hooks.sh) — run the sync"
    continue
  fi
  if hc="$(board_config "$path")" && [ -n "$hc" ]; then
    eval "$hc"
    if [ "$HC_TOPOLOGY" = "cross-repo" ]; then pass board.topology "board $path is cross-repo"; else fail board.topology "board $path topology is '${HC_TOPOLOGY:-unset}', not cross-repo"; fi
    want="$(printf '%s' "$groups" | tr ',' '\n' | sort | paste -sd, -)"
    got="$(printf '%s' "$HC_GROUPS" | tr ',' '\n' | sort | paste -sd, -)"
    if [ "$want" = "$got" ]; then pass board.groups "board $path hosts groups: $want"; else fail board.groups "board $path groups drift (config: '${got:-unset}', manifest: '$want') — re-run the sync"; fi
    if [ "$HC_GROUP_LAYOUT" = "$layout" ]; then pass board.layout "board $path layout=$layout"; else fail board.layout "board $path layout drift (config: '${HC_GROUP_LAYOUT:-unset}', manifest: '$layout')"; fi
  else
    fail board.config "board $path config could not be read — $(cfg_reason "no handoff.json and no legacy config file") — re-run the sync"
  fi
  # sub-index + roll-up presence (generated on first CLI use; absence is a warn, not a fail)
  [ -f "$path/INDEX.md" ] || warn board.rollup_index "board $path has no roll-up INDEX.md yet (created on first handoff command)"
  for g in $(printf '%s' "$groups" | tr ',' ' '); do
    if [ "$layout" = "prefix" ]; then sidx="$path/INDEX-$g.md"; else sidx="$path/$g/INDEX.md"; fi
    [ -f "$sidx" ] || warn board.subindex "group $g has no sub-index yet ($sidx — created on first handoff command)"
  done
done < <(
  python3 - "$RESOLVED" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for b in d["boards"]:
    print("\t".join([b["path"], ",".join(sorted(b["groups"])), d["layout"]]))
PY
)

echo
section "3. member repos"
# MEMBER<TAB>group<TAB>board<TAB>alias<TAB>repo<TAB>exists<TAB>has_agents
while IFS=$'\t' read -r group board alias repo exists has_agents; do
  [ -n "$alias" ] || continue
  if [ "$exists" != 1 ]; then
    fail member.exists "$group/$alias — $repo not on disk"
    continue
  fi
  if [ "$has_agents" != 1 ]; then
    fail member.agents_md "$group/$alias — no AGENTS.md"
    continue
  fi
  if grep -q 'cross-repo-handoff:begin' "$repo/AGENTS.md" 2> /dev/null; then
    # the block must name this repo's own group
    if sed -n '/cross-repo-handoff:begin/,/cross-repo-handoff:end/p' "$repo/AGENTS.md" | grep -q "\`$group\` section"; then
      pass member.agents_block "$group/$alias AGENTS.md block present + scoped to $group"
    else
      fail member.agents_block "$group/$alias AGENTS.md block does not name the $group section — re-run the sync"
    fi
  else
    fail member.agents_block "$group/$alias missing the cross-repo-handoff AGENTS.md block — re-run the sync"
  fi
  # Wired and scoped are two different facts and are checked separately. The group used to be baked
  # into the hook command as HANDOFF_GROUP=<group>; it is not any more — merge-hooks.py writes it to
  # the member's own .agents/handoff.json so a rename cannot leave a stale literal buried in
  # a tool config. Grepping the old literal made every correctly-wired member read as broken.
  cfg="$repo/.claude/settings.json"
  if [ -f "$cfg" ]; then
    if grep -q '/scripts/hooks.sh' "$cfg"; then
      pass member.claude_hook "$group/$alias claude hooks invoke the board"
    else
      fail member.claude_hook "$group/$alias claude settings.json has no handoff hook — re-run the sync"
    fi
  else
    warn member.claude_hook "$group/$alias has no .claude/settings.json (claude not wired — advisory only if another tool is primary)"
  fi
  if hc="$(board_config "$board" "$repo")" && [ -n "$hc" ]; then
    eval "$hc"
    if [ "$HC_GROUP" = "$group" ]; then
      pass member.section "$group/$alias resolves to section $group"
    else
      fail member.section "$group/$alias resolves to section '${HC_GROUP:-unset}', not $group — re-run the sync"
    fi
  else
    fail member.config "$group/$alias config could not be read — $(cfg_reason "no readable board config, and no $repo/.agents/handoff.json") — re-run the sync"
  fi
done < <(
  python3 - "$RESOLVED" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for g in d["groups"]:
    for m in g["members"]:
        print("\t".join([g["group"], g["board"], m["alias"], m["path"],
                         "1" if m["exists"] else "0", "1" if m["has_agents_md"] else "0"]))
PY
)

echo
section "4. board repo registries"
# `handoff export` resolves a handoff's `audience` through the `_generated` block of the board's
# handoff.json (or, on a board not yet re-synced, the standalone repos.json it replaced). It is
# generated, never hand-edited, so ANY difference from the manifest is drift — and drift here is
# invisible at export time: every affected brief just quietly renders repo_root_commit: unverified.
# registry.py builds the expected bytes, the same call the sync writes with, so the two cannot
# disagree about what "correct" means.
while IFS= read -r bpath; do
  [ -n "$bpath" ] || continue
  # stdout carries the verdict; stderr carries registry.py's advisories (an unattestable member, an
  # audience claimed twice). Both are folded into one stream so neither is lost, then classified —
  # an advisory is a warn, because a correctly projected file can legitimately carry one.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *"matches the manifest"*) pass registry.projection "$line" ;;
      *"missing"* | *"drift"*) fail registry.projection "$line" ;;
      *) warn registry.advisory "$line" ;;
    esac
  done <<< "$(python3 "$REGISTRY" --resolved "$RESOLVED" --board "$bpath" --check 2>&1)"
done < <(
  python3 - "$RESOLVED" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for b in d["boards"]:
    print(b["path"])
PY
)

echo
section "5. board substrate (git, remote, lease visibility)"
# A standalone board is the board of record: it holds documents that exist nowhere else, and it is
# the thing every member repo coordinates through. Three properties decide whether it can actually
# do that job, and each one fails silently on its own (ADR 0002).
while IFS= read -r bpath; do
  [ -n "$bpath" ] || continue
  [ -d "$bpath" ] || continue
  btop="$(git -C "$bpath" rev-parse --show-toplevel 2> /dev/null || true)"
  if [ -z "$btop" ] || [ "$(cd "$btop" 2> /dev/null && pwd -P)" != "$(cd "$bpath" && pwd -P)" ]; then
    fail substrate.git_repo "$bpath is not its own git repository — no history, no blame, no recovery for the documents on it. Re-run the sync."
    continue
  fi
  pass substrate.git_repo "$bpath is its own git repository"
  if [ -n "$(git -C "$bpath" remote 2> /dev/null)" ]; then
    pass substrate.remote "$bpath has a remote — the board is shared, not merely versioned"
    # The quiet one. With `.locks/` ignored, every claim still commits, still pushes, and still
    # reports success — while carrying no lease, so push-CAS excludes nobody and two machines can
    # hold the same handoff without either being told.
    if grep -qxF '.locks/' "$bpath/.gitignore" 2> /dev/null; then
      warn substrate.lease_visibility "$bpath has a remote but still gitignores .locks/ — leases never travel. Remove that line (the CLI repairs it on the next claim)."
    else
      pass substrate.lease_visibility "$bpath tracks .locks/, as a remote-backed board requires"
    fi
  else
    warn substrate.remote "$bpath has NO REMOTE — versioned, but it still reaches exactly one machine. Declare one as \"boardRemote\" in the manifest, or: git -C $bpath remote add origin <url>"
  fi
done < <(
  python3 - "$RESOLVED" << 'BOARDS'
import json, sys
d = json.load(open(sys.argv[1]))
for b in d["boards"]:
    print(b["path"])
BOARDS
)

echo
echo "Summary: $PASS passed, $WARN warnings, $FAIL failed"

if [ "$JSON" = 1 ]; then
  exec 1>&3
  render_json
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
