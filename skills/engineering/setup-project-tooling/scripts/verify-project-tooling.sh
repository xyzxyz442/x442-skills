#!/usr/bin/env bash
# verify-project-tooling.sh — confirm the `setup-project-tooling` skill wired a repo correctly:
# commit conventions (commitlint + local hook), staged-file lint/format (lint-staged),
# editor/workspace config (.editorconfig + .vscode), git hygiene (.gitignore + .gitattributes), and
# release automation (release-it) when wired.
#
# Read-only: it inspects files only. It never writes, never calls an LLM, never hits the network —
# safe to run in CI or by hand. It checks end-state, not the interactive skill itself; release-it
# is optional per profile, so its absence is a warning, not a failure.
#
# Usage: ./verify-project-tooling.sh [/path/to/repo]   (defaults to the current repo)
set -uo pipefail

TARGET="${1:-$PWD}"
cd "$TARGET" 2> /dev/null || {
  echo "no such path: $TARGET" >&2
  exit 1
}
ROOT=$(git rev-parse --show-toplevel 2> /dev/null) || ROOT="$PWD"
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
is_json() { python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1" 2> /dev/null; }

echo "Repo: $ROOT"
echo
echo "1. Commit conventions (commitlint)"
echo "----------------------------------"
if [ -f commitlint.config.mjs ]; then
  ok "commitlint.config.mjs present at repo root"
  # Local commit-msg enforcement, in order: a committed .husky/commit-msg; the scripts/husky.sh
  # dispatcher installed by a package.json command; or the legacy echo-fragment chain, which is
  # still accepted so a repo that has not re-run the skill does not fail CI.
  if [ -f .husky/commit-msg ]; then
    ok ".husky/commit-msg present (committed local hook)"
  elif [ -f scripts/husky.sh ] && grep -q 'commitlint --edit' scripts/husky.sh && [ -f package.json ] && grep -q 'husky\.sh install' package.json; then
    ok "commit-msg hook generated at install time (scripts/husky.sh install)"
    if [ -x scripts/husky.sh ]; then
      ok "scripts/husky.sh is executable"
    else bad "scripts/husky.sh is not executable (the generated hooks invoke it directly)"; fi
  elif [ -f package.json ] && grep -qE '\.husky/commit-msg|commitlint --edit' package.json; then
    ok "commit-msg hook generated at install time (legacy package.json hook chain)"
    warn "legacy hook chain detected; re-run setup-project-tooling to migrate to scripts/husky.sh"
  else bad "no local commit-msg enforcement (.husky/commit-msg absent and no command generates it)"; fi
else
  bad "commitlint.config.mjs missing at repo root"
fi

echo
echo "2. Declared tooling in package.json"
echo "-----------------------------------"
if [ -f package.json ] && is_json package.json; then
  ok "package.json is valid JSON"
  python3 - << 'PY' 2> /dev/null
import json,sys
d=json.load(open("package.json"))
dev=d.get("devDependencies",{})
need={"@commitlint/cli","@commitlint/config-conventional","husky","lint-staged","prettier","prettier-plugin-sh"}
# The hook-install command defaults to `prepare` but may carry any name (install:dev, setup, ...),
# so look for the command that invokes husky rather than for a fixed script name.
installs_hooks=any("husky" in v for v in d.get("scripts",{}).values())
sys.exit(0 if need.issubset(dev) and installs_hooks else 1)
PY
  if [ $? -eq 0 ]; then ok "package.json has commitlint/husky/lint-staged/prettier(+sh) devDeps + a husky-invoking hook-install command"; else bad "package.json missing commitlint/husky/lint-staged/prettier(+sh) devDeps or a husky-invoking hook-install command"; fi
else
  bad "package.json missing or invalid JSON (needed for the Node-rooted tooling)"
fi

echo
echo "3. Staged-file lint/format (lint-staged)"
echo "----------------------------------------"
LS=0
if [ -f package.json ] && is_json package.json; then
  python3 -c "import json,sys; sys.exit(0 if 'lint-staged' in json.load(open('package.json')) else 1)" 2> /dev/null && {
    ok "lint-staged config found (package.json key)"
    LS=1
  }
fi
if [ "$LS" -eq 0 ]; then
  for f in .lintstagedrc .lintstagedrc.json .lintstagedrc.yaml .lintstagedrc.yml .lintstagedrc.js .lintstagedrc.cjs .lintstagedrc.mjs lint-staged.config.js lint-staged.config.mjs lint-staged.config.cjs; do
    [ -f "$f" ] && {
      ok "lint-staged config found ($f)"
      LS=1
      break
    }
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
echo "5. Git hygiene (.gitignore + .gitattributes)"
echo "--------------------------------------------"
if [ -f .gitignore ]; then
  ok ".gitignore present"
  if grep -qE '^[[:space:]]*\.husky/?[[:space:]]*$' .gitignore; then ok ".gitignore ignores .husky (regenerated hooks stay untracked)"; else warn ".gitignore does not ignore .husky (base .gitignore not applied)"; fi
else
  warn ".gitignore absent (base ignore set not applied)"
fi
# Line endings. Everything this skill ships to a repo — scripts/husky.sh, initialize.sh,
# scripts/py-tool.sh, the generated .husky/ hooks — is a `#!/usr/bin/env bash` payload, and a CRLF
# checkout turns that shebang into `bash\r`, failing inside a git hook with a "no such file" naming
# a file that exists. Ask git for the effective attribute instead of pattern-matching, so a blanket
# `* text=auto eol=lf` counts as much as an explicit `*.sh` rule; grep only outside a work tree.
if [ -f .gitattributes ]; then
  ok ".gitattributes present"
  EOL=""
  if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    EOL=$(git check-attr eol -- probe.sh 2> /dev/null | sed 's/.*: //')
  fi
  if [ "$EOL" = "lf" ]; then
    ok ".gitattributes forces LF on *.sh (shebangs survive a Windows checkout)"
  elif [ -z "$EOL" ] && grep -qE '^[[:space:]]*(\*|\*\.sh)[[:space:]].*eol=lf' .gitattributes; then
    ok ".gitattributes declares eol=lf covering *.sh"
  else
    warn ".gitattributes does not force LF on *.sh (a CRLF checkout breaks the shipped hook payloads)"
  fi
else
  warn ".gitattributes absent (line endings not normalized; a CRLF checkout breaks the shipped .sh payloads)"
fi

echo
echo "6. Release automation (release-it) — optional per profile"
echo "---------------------------------------------------------"
if [ -f .release-it.json ]; then
  if is_json .release-it.json; then ok ".release-it.json present and valid JSON"; else bad ".release-it.json is not valid JSON"; fi
  if [ -f package.json ] && grep -q '"release"' package.json; then ok "package.json has a release script"; else bad ".release-it.json present but no release script in package.json"; fi
  # The conventional-changelog plugin writes markdown to whatever `infile` names, extension and
  # all. An extension-less "CHANGELOG" renders as plain text on GitHub and slips past every
  # markdown-keyed tool (prettier infers no parser for it, so .prettierignore's CHANGELOG.md entry
  # never applies). Warn rather than fail: the path is the repo's to choose.
  INFILE=$(python3 -c "
import json,sys
p=json.load(open('.release-it.json')).get('plugins',{}).get('@release-it/conventional-changelog',{})
print(p.get('infile','') if isinstance(p,dict) else '')" 2> /dev/null)
  case "$INFILE" in
    "") : ;;
    *.md) ok "changelog infile is a markdown path ($INFILE)" ;;
    *) warn "changelog infile '$INFILE' has no .md extension — the plugin writes markdown, so it renders as plain text and .prettierignore's CHANGELOG.md entry will not match" ;;
  esac
else
  warn ".release-it.json absent — release automation not wired (skip if intentional)"
fi

echo
echo "Summary: $P passed, $W warnings, $F failed"
if [ "$F" -gt 0 ]; then exit 1; fi
exit 0
