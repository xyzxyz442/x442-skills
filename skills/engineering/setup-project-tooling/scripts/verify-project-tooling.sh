#!/usr/bin/env bash
# verify-project-tooling.sh — confirm the `setup-project-tooling` skill wired a repo correctly:
# commit conventions (commitlint + local hook), staged-file lint/format (lint-staged),
# editor/workspace config (.editorconfig + .vscode), and release automation (release-it) when wired.
#
# Read-only: it inspects files only. It never writes, never calls an LLM, never hits the network —
# safe to run in CI or by hand. It checks end-state, not the interactive skill itself; release-it
# is optional per profile, so its absence is a warning, not a failure.
#
# Usage: ./verify-project-tooling.sh [/path/to/repo]   (defaults to the current repo)
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

echo "Repo: $ROOT"
echo
echo "1. Commit conventions (commitlint)"
echo "----------------------------------"
if [ -f commitlint.config.mjs ]; then
  ok "commitlint.config.mjs present at repo root"
  # Local commit-msg enforcement: committed .husky/commit-msg OR a prepare script that generates it.
  if [ -f .husky/commit-msg ]; then ok ".husky/commit-msg present (committed local hook)"
  elif [ -f package.json ] && grep -qE '\.husky/commit-msg|commitlint --edit' package.json; then ok "commit-msg hook generated at install time (package.json prepare script)"
  else bad "no local commit-msg enforcement (.husky/commit-msg absent and no prepare script generates it)"; fi
else
  bad "commitlint.config.mjs missing at repo root"
fi

echo
echo "2. Declared tooling in package.json"
echo "-----------------------------------"
if [ -f package.json ] && is_json package.json; then
  ok "package.json is valid JSON"
  python3 - <<'PY' 2>/dev/null
import json,sys
d=json.load(open("package.json"))
dev=d.get("devDependencies",{})
need={"@commitlint/cli","@commitlint/config-conventional","husky","lint-staged","prettier","prettier-plugin-sh"}
prep=d.get("scripts",{}).get("prepare","")
sys.exit(0 if need.issubset(dev) and "husky" in prep else 1)
PY
  if [ $? -eq 0 ]; then ok "package.json has commitlint/husky/lint-staged/prettier(+sh) devDeps + a husky-invoking prepare script"; else bad "package.json missing commitlint/husky/lint-staged/prettier(+sh) devDeps or a husky-invoking prepare script"; fi
else
  bad "package.json missing or invalid JSON (needed for the Node-rooted tooling)"
fi

echo
echo "3. Staged-file lint/format (lint-staged)"
echo "----------------------------------------"
LS=0
if [ -f package.json ] && is_json package.json; then
  python3 -c "import json,sys; sys.exit(0 if 'lint-staged' in json.load(open('package.json')) else 1)" 2>/dev/null && { ok "lint-staged config found (package.json key)"; LS=1; }
fi
if [ "$LS" -eq 0 ]; then
  for f in .lintstagedrc .lintstagedrc.json .lintstagedrc.yaml .lintstagedrc.yml .lintstagedrc.js .lintstagedrc.cjs .lintstagedrc.mjs lint-staged.config.js lint-staged.config.mjs lint-staged.config.cjs; do
    [ -f "$f" ] && { ok "lint-staged config found ($f)"; LS=1; break; }
  done
fi
[ "$LS" -eq 0 ] && bad "no lint-staged config (package.json 'lint-staged' key or .lintstagedrc* file)"
# SQL profile: if a .sqlfluff exists it should declare a dialect.
if [ -f .sqlfluff ]; then
  if grep -qE '^[[:space:]]*dialect[[:space:]]*=' .sqlfluff; then ok ".sqlfluff present with a dialect"; else bad ".sqlfluff present but no dialect set"; fi
fi

echo
echo "4. Editor + workspace"
echo "---------------------"
if [ -f .editorconfig ]; then ok ".editorconfig present"; else bad ".editorconfig missing"; fi
if [ -f .prettierrc ]; then
  if is_json .prettierrc; then ok ".prettierrc present and valid JSON"; else bad ".prettierrc is not valid JSON"; fi
else
  warn ".prettierrc absent (base Prettier config not written)"
fi
if [ -f .prettierignore ]; then ok ".prettierignore present"; else warn ".prettierignore absent"; fi
if [ -f .gitignore ] && grep -qE '^[[:space:]]*\.husky/?[[:space:]]*$' .gitignore; then ok ".gitignore ignores .husky (regenerated hooks stay untracked)"; else warn ".gitignore does not ignore .husky (base .gitignore not applied)"; fi
if [ -f .vscode/settings.json ]; then
  if is_json .vscode/settings.json; then ok ".vscode/settings.json present and valid JSON"; else bad ".vscode/settings.json is not valid JSON"; fi
else
  warn ".vscode/settings.json absent (editor format-on-save not configured)"
fi
if [ -f .vscode/extensions.json ]; then
  if is_json .vscode/extensions.json; then ok ".vscode/extensions.json present and valid JSON"; else bad ".vscode/extensions.json is not valid JSON"; fi
else
  warn ".vscode/extensions.json absent (no recommended extensions)"
fi
if [ -f .vscode/tasks.json ]; then
  if is_json .vscode/tasks.json; then ok ".vscode/tasks.json present and valid JSON"; else bad ".vscode/tasks.json is not valid JSON"; fi
else
  warn ".vscode/tasks.json absent (no workspace-bootstrap task)"
fi
if [ -f initialize.sh ]; then
  if [ -x initialize.sh ]; then ok "initialize.sh present and executable"; else bad "initialize.sh present but not executable (chmod +x)"; fi
else
  warn "initialize.sh absent (workspace bootstrap not wired)"
fi

echo
echo "5. Release automation (release-it) — optional per profile"
echo "---------------------------------------------------------"
if [ -f .release-it.json ]; then
  if is_json .release-it.json; then ok ".release-it.json present and valid JSON"; else bad ".release-it.json is not valid JSON"; fi
  if [ -f package.json ] && grep -q '"release"' package.json; then ok "package.json has a release script"; else bad ".release-it.json present but no release script in package.json"; fi
else
  warn ".release-it.json absent — release automation not wired (skip if intentional)"
fi

echo
echo "Summary: $P passed, $W warnings, $F failed"
if [ "$F" -gt 0 ]; then exit 1; fi
exit 0
