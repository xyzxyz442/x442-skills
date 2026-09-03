#!/usr/bin/env bash
# verify-initial-project.sh — confirm the `initial-project` skill wired a repo correctly:
# shared guidelines in AGENTS.md, each per-tool entry file loading AGENTS.md the right way,
# and NO duplication of the shared guidance into a tool file. (Project dev tooling —
# commitlint, lint-staged, release-it — is verified by setup-project-tooling's own checker.)
#
# Read-only: it inspects files only. It never writes, never calls an LLM, never hits the
# network — so it is safe to run in CI or by hand, and respects the no-automated-LLM rule.
# It checks end-state + no-duplication (a proxy for the skill's idempotency: re-running the
# skill must not duplicate anything); it does not re-invoke the interactive skill itself.
#
# Usage: ./verify-initial-project.sh [/path/to/repo] [--json]   (path defaults to the current repo)
#
# --json emits every finding as a machine-readable object instead of prose. The advisory checks
# here — an uncited karpathy-guidelines link, a Copilot install with no .vscode/settings.json, a
# repo with no tool entry files yet — never move the exit code, so a grader reading only the exit
# status cannot see any of them. This is the channel that makes them gradeable.
#
# Every finding carries a STABLE ID. The id names the CHECK and `level` carries the outcome, so a
# grader asserts "tool.any_wired came back warn" rather than matching prose that any future
# rewording breaks. Where two outcomes of one check need different remediation they get different
# ids (tool.import.missing vs tool.import.duplicated) — same rule, applied where it earns itself.
set -uo pipefail

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
ROOT=$(git rev-parse --show-toplevel 2> /dev/null) || ROOT="$PWD"
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
# the end. Redirecting the fd rather than guarding every echo site keeps ONE rendering path: the
# human output and the findings can never disagree, because they are produced by the same call.
if [ "$JSON" = 1 ]; then
  exec 3>&1 1> /dev/null
fi

is_json() { python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1" 2> /dev/null; }

# A distinctive line from references/karpathy-guidelines.md. Its presence in a tool entry
# file means the shared guidance was copied where it must never live.
KARPATHY_PHRASE="Clean up only your own mess"

echo "Repo: $ROOT"
section "1. Shared guidelines in AGENTS.md"
if [ -f AGENTS.md ]; then
  ok agents.present "AGENTS.md present at repo root"
  if grep -qE '^#{1,6}[[:space:]]+Coding guidelines' AGENTS.md; then ok agents.coding_guidelines "AGENTS.md has a 'Coding guidelines' section"; else bad agents.coding_guidelines "AGENTS.md missing a 'Coding guidelines' section"; fi
  if grep -q 'karpathy-guidelines' AGENTS.md; then ok agents.karpathy_cited "AGENTS.md cites karpathy-guidelines"; else warn agents.karpathy_cited "AGENTS.md 'Coding guidelines' section does not cite karpathy-guidelines"; fi
  if grep -qE '^#{1,6}[[:space:]]+Commit conventions' AGENTS.md; then ok agents.commit_conventions "AGENTS.md has a 'Commit conventions' section"; else bad agents.commit_conventions "AGENTS.md missing a 'Commit conventions' section"; fi
  if grep -qE 'commit-guidelines|commitlint\.config\.mjs' AGENTS.md; then ok agents.commit_ruleset_cited "AGENTS.md cites the commit ruleset (commit-guidelines / commitlint.config.mjs)"; else warn agents.commit_ruleset_cited "AGENTS.md 'Commit conventions' section does not cite commit-guidelines / commitlint.config.mjs"; fi
else
  bad agents.present "AGENTS.md missing at repo root (the single source of truth)"
fi

section "2. Per-tool entry files load AGENTS.md"
WIRED=0
# Claude Code / Gemini CLI: load via a single @AGENTS.md Markdown import line.
for f in CLAUDE.md GEMINI.md; do
  [ -f "$f" ] || continue
  n=$(grep -c '@AGENTS\.md' "$f")
  if [ "$n" -eq 1 ]; then
    ok tool.import "$f imports @AGENTS.md (exactly one line)"
    WIRED=$((WIRED + 1))
  elif [ "$n" -eq 0 ]; then
    bad tool.import.missing "$f present but has no @AGENTS.md import line"
  else bad tool.import.duplicated "$f has $n @AGENTS.md lines (duplicated — expected exactly one)"; fi
done
# Antigravity: reads AGENTS.md natively (v1.20.3+). ANTIGRAVITY.md is optional, overrides-only.
if [ -f ANTIGRAVITY.md ]; then
  n=$(grep -c '@AGENTS\.md' ANTIGRAVITY.md)
  if [ "$n" -le 1 ]; then
    ok antigravity.present "ANTIGRAVITY.md present (Antigravity reads AGENTS.md natively; no import required)"
    WIRED=$((WIRED + 1))
  else bad antigravity.present "ANTIGRAVITY.md has $n @AGENTS.md lines (duplicated)"; fi
fi
# GitHub Copilot: prose link must be ../AGENTS.md because the file lives in .github/.
CP=.github/copilot-instructions.md
if [ -f "$CP" ]; then
  if grep -q '\.\./AGENTS\.md' "$CP"; then
    ok copilot.link "$CP links ../AGENTS.md"
    WIRED=$((WIRED + 1))
  elif grep -q 'AGENTS\.md' "$CP"; then
    bad copilot.link.wrong_path "$CP references AGENTS.md but not as ../AGENTS.md (wrong relative path from .github/)"
  else bad copilot.link.missing "$CP present but does not reference AGENTS.md"; fi
  if [ -f .vscode/settings.json ]; then
    if is_json .vscode/settings.json; then
      python3 -c "import json,sys; d=json.load(open('.vscode/settings.json')); loc=d.get('chat.agentFilesLocations',{}); sys.exit(0 if isinstance(loc,dict) and loc.get('.') is True else 1)" 2> /dev/null \
        && ok copilot.vscode.agent_files_locations ".vscode/settings.json lists the repo root in chat.agentFilesLocations" \
        || bad copilot.vscode.agent_files_locations ".vscode/settings.json missing chat.agentFilesLocations \".\": true"
    else bad copilot.vscode.json_valid ".vscode/settings.json is not valid JSON"; fi
  else warn copilot.vscode.present "Copilot wired but no .vscode/settings.json (root auto-load not configured)"; fi
fi
[ "$WIRED" -eq 0 ] && warn tool.any_wired "no tool entry files found yet (CLAUDE.md / GEMINI.md / ANTIGRAVITY.md / copilot-instructions.md)"

section "3. No duplication of the shared guidelines"
DUP=0
for f in CLAUDE.md GEMINI.md ANTIGRAVITY.md .github/copilot-instructions.md; do
  [ -f "$f" ] || continue
  if grep -qF "$KARPATHY_PHRASE" "$f" || grep -qE '^#{1,6}[[:space:]]+Coding guidelines' "$f"; then
    bad guidelines.no_duplication "$f duplicates shared guidance (Karpathy text / Coding-guidelines section belongs only in AGENTS.md)"
    DUP=1
  fi
done
[ "$DUP" -eq 0 ] && ok guidelines.no_duplication "no tool file copies the Karpathy guidelines or a Coding-guidelines section"

echo
echo "Summary: $P passed, $W warnings, $F failed"

if [ "$JSON" = 1 ]; then
  exec 1>&3
  python3 - "$FINDINGS" "$ROOT" "$P" "$W" "$F" << 'PY'
import json, sys

path, root, npass, nwarn, nfail = sys.argv[1:6]
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
    "tool": "verify-initial-project",
    # Bumped only when the SHAPE changes. A consumer pins this, not the set of ids: ids are added
    # over time by design, and a grader that broke every time a new check appeared would be
    # abandoned within a release.
    "schema": 1,
    "repo": root,
    "summary": {"pass": int(npass), "warn": int(nwarn), "fail": int(nfail)},
    "findings": findings,
}, indent=2, sort_keys=True))
PY
fi
if [ "$F" -gt 0 ]; then exit 1; fi
exit 0
