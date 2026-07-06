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
# Usage: ./verify-initial-project.sh [/path/to/repo]   (defaults to the current repo)
set -uo pipefail

TARGET="${1:-$PWD}"
cd "$TARGET" 2>/dev/null || { echo "no such path: $TARGET"; exit 1; }
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT="$PWD"
cd "$ROOT"

P=0; F=0; W=0
ok()   { printf '  [PASS] %s\n' "$1"; P=$((P+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; F=$((F+1)); }
warn() { printf '  [warn] %s\n' "$1"; W=$((W+1)); }
is_json() { python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1" 2>/dev/null; }

# A distinctive line from references/karpathy-guidelines.md. Its presence in a tool entry
# file means the shared guidance was copied where it must never live.
KARPATHY_PHRASE="Clean up only your own mess"

echo "Repo: $ROOT"
echo
echo "1. Shared guidelines in AGENTS.md"
echo "---------------------------------"
if [ -f AGENTS.md ]; then
  ok "AGENTS.md present at repo root"
  if grep -qE '^#{1,6}[[:space:]]+Coding guidelines' AGENTS.md; then ok "AGENTS.md has a 'Coding guidelines' section"; else bad "AGENTS.md missing a 'Coding guidelines' section"; fi
  if grep -q 'karpathy-guidelines' AGENTS.md; then ok "AGENTS.md cites karpathy-guidelines"; else warn "AGENTS.md 'Coding guidelines' section does not cite karpathy-guidelines"; fi
  if grep -qE '^#{1,6}[[:space:]]+Commit conventions' AGENTS.md; then ok "AGENTS.md has a 'Commit conventions' section"; else bad "AGENTS.md missing a 'Commit conventions' section"; fi
  if grep -qE 'commit-guidelines|commitlint\.config\.mjs' AGENTS.md; then ok "AGENTS.md cites the commit ruleset (commit-guidelines / commitlint.config.mjs)"; else warn "AGENTS.md 'Commit conventions' section does not cite commit-guidelines / commitlint.config.mjs"; fi
else
  bad "AGENTS.md missing at repo root (the single source of truth)"
fi

echo
echo "2. Per-tool entry files load AGENTS.md"
echo "--------------------------------------"
WIRED=0
# Claude Code / Gemini CLI: load via a single @AGENTS.md Markdown import line.
for f in CLAUDE.md GEMINI.md; do
  [ -f "$f" ] || continue
  n=$(grep -c '@AGENTS\.md' "$f")
  if [ "$n" -eq 1 ]; then ok "$f imports @AGENTS.md (exactly one line)"; WIRED=$((WIRED+1))
  elif [ "$n" -eq 0 ]; then bad "$f present but has no @AGENTS.md import line"
  else bad "$f has $n @AGENTS.md lines (duplicated — expected exactly one)"; fi
done
# Antigravity: reads AGENTS.md natively (v1.20.3+). ANTIGRAVITY.md is optional, overrides-only.
if [ -f ANTIGRAVITY.md ]; then
  n=$(grep -c '@AGENTS\.md' ANTIGRAVITY.md)
  if [ "$n" -le 1 ]; then ok "ANTIGRAVITY.md present (Antigravity reads AGENTS.md natively; no import required)"; WIRED=$((WIRED+1))
  else bad "ANTIGRAVITY.md has $n @AGENTS.md lines (duplicated)"; fi
fi
# GitHub Copilot: prose link must be ../AGENTS.md because the file lives in .github/.
CP=.github/copilot-instructions.md
if [ -f "$CP" ]; then
  if grep -q '\.\./AGENTS\.md' "$CP"; then ok "$CP links ../AGENTS.md"; WIRED=$((WIRED+1))
  elif grep -q 'AGENTS\.md' "$CP"; then bad "$CP references AGENTS.md but not as ../AGENTS.md (wrong relative path from .github/)"
  else bad "$CP present but does not reference AGENTS.md"; fi
  if [ -f .vscode/settings.json ]; then
    if is_json .vscode/settings.json; then
      python3 -c "import json,sys; d=json.load(open('.vscode/settings.json')); loc=d.get('chat.agentFilesLocations',{}); sys.exit(0 if isinstance(loc,dict) and loc.get('.') is True else 1)" 2>/dev/null \
        && ok ".vscode/settings.json lists the repo root in chat.agentFilesLocations" \
        || bad ".vscode/settings.json missing chat.agentFilesLocations \".\": true"
    else bad ".vscode/settings.json is not valid JSON"; fi
  else warn "Copilot wired but no .vscode/settings.json (root auto-load not configured)"; fi
fi
[ "$WIRED" -eq 0 ] && warn "no tool entry files found yet (CLAUDE.md / GEMINI.md / ANTIGRAVITY.md / copilot-instructions.md)"

echo
echo "3. No duplication of the shared guidelines"
echo "------------------------------------------"
DUP=0
for f in CLAUDE.md GEMINI.md ANTIGRAVITY.md .github/copilot-instructions.md; do
  [ -f "$f" ] || continue
  if grep -qF "$KARPATHY_PHRASE" "$f" || grep -qE '^#{1,6}[[:space:]]+Coding guidelines' "$f"; then
    bad "$f duplicates shared guidance (Karpathy text / Coding-guidelines section belongs only in AGENTS.md)"; DUP=1
  fi
done
[ "$DUP" -eq 0 ] && ok "no tool file copies the Karpathy guidelines or a Coding-guidelines section"

echo
echo "Summary: $P passed, $W warnings, $F failed"
if [ "$F" -gt 0 ]; then exit 1; fi
exit 0
