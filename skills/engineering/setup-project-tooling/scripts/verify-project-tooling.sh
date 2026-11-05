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
# Usage: ./verify-project-tooling.sh [/path/to/repo] [--json]   (path defaults to the current repo)
#
# --json emits every finding as a machine-readable object instead of prose. Most of section 4-6 is
# ADVISORY by design — an absent .prettierrc, no .vscode config, no .gitattributes, release-it not
# wired — and none of it changes the exit code, so a grader reading only the exit status is blind
# to exactly the checks most likely to rot. This is the channel that makes them gradeable.
#
# Every finding carries a STABLE ID. The id names the CHECK and `level` carries the outcome, so a
# grader asserts "gitattributes.eol_lf came back warn" rather than matching prose that any future
# rewording breaks. Where two outcomes of one check need different remediation they get different
# ids (payload.version.behind vs payload.version.ahead) — same rule, applied where it earns itself.
set -uo pipefail

# Resolve this script's own directory to an ABSOLUTE path BEFORE the cd below: payload.version
# lives beside this script, and a bare `dirname "$0"` is relative to the ORIGINAL cwd, so invoking
# the verifier by a relative path made the stamp unreadable and check_payload_version return
# silently — drift reported as nothing at all.
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
# VS Code reads its .vscode/*.json files as JSONC: `//` and `/* */` comments and trailing commas
# are legal there, and a repo's own extensions.json often carries them. Strict JSON failed those
# files as invalid. Comments are stripped outside strings only, so a URL's `//` survives.
is_jsonc() {
  python3 - "$1" 2> /dev/null << 'PY'
import json, re, sys
src = open(sys.argv[1]).read()
out, i, n = [], 0, len(src)
while i < n:
    c = src[i]
    if c == '"':
        j = i + 1
        while j < n and src[j] != '"':
            j += 2 if src[j] == "\\" else 1
        out.append(src[i:j + 1]); i = j + 1
    elif src.startswith("//", i):
        while i < n and src[i] != "\n": i += 1
    elif src.startswith("/*", i):
        end = src.find("*/", i + 2)
        i = n if end < 0 else end + 2
    else:
        out.append(c); i += 1
json.loads(re.sub(r",(\s*[]}])", r"\1", "".join(out)))
PY
}

echo "Repo: $ROOT"
section "1. Commit conventions (commitlint)"
if [ -f commitlint.config.mjs ]; then
  ok commitlint.config "commitlint.config.mjs present at repo root"
  # Local commit-msg enforcement, in order: a committed .husky/commit-msg; the scripts/husky.sh
  # dispatcher installed by a package.json command; or the legacy echo-fragment chain, which is
  # still accepted so a repo that has not re-run the skill does not fail CI.
  if [ -f .husky/commit-msg ]; then
    ok hook.commit_msg ".husky/commit-msg present (committed local hook)"
  elif [ -f scripts/husky.sh ] && grep -q 'commitlint --edit' scripts/husky.sh && [ -f package.json ] && grep -q 'husky\.sh install' package.json; then
    ok hook.commit_msg "commit-msg hook generated at install time (scripts/husky.sh install)"
    if [ -x scripts/husky.sh ]; then
      ok husky.executable "scripts/husky.sh is executable"
    else bad husky.executable "scripts/husky.sh is not executable (the generated hooks invoke it directly)"; fi
  elif [ -f package.json ] && grep -qE '\.husky/commit-msg|commitlint --edit' package.json; then
    ok hook.commit_msg "commit-msg hook generated at install time (legacy package.json hook chain)"
    warn hook.legacy_chain "legacy hook chain detected; re-run setup-project-tooling to migrate to scripts/husky.sh"
  else bad hook.commit_msg "no local commit-msg enforcement (.husky/commit-msg absent and no command generates it)"; fi

  # core.hooksPath must name a directory that EXISTS, and one that is TRACKED.
  #
  # A hook file present in this checkout proves nothing on its own. core.hooksPath lives in
  # .git/config and is shared by every worktree of a clone, so if it names a generated,
  # gitignored directory (husky's own .husky/_ is exactly that), a linked worktree inherits the
  # setting, finds nothing there, and git runs NO hook — not commit-msg, not pre-commit, not
  # post-commit. Nothing reports it. Commits land unchecked and look identical to checked ones.
  #
  # Both halves matter, so both are checked: a path that does not resolve here is already broken,
  # and a path that resolves but is gitignored is broken in every worktree but this one.
  hp="$(git config core.hooksPath 2> /dev/null || true)"
  if [ -z "$hp" ]; then
    ok hooks.path "core.hooksPath unset — git uses .git/hooks, which every worktree shares"
  elif [ ! -d "$hp" ]; then
    bad hooks.path.missing "core.hooksPath is '$hp' but no such directory exists — git runs NO hook here; fix: re-run setup-project-tooling"
  elif git check-ignore -q "$hp" 2> /dev/null; then
    bad hooks.path.ignored "core.hooksPath is '$hp', which is gitignored — hooks run in this checkout but in NO worktree; fix: track it and re-run setup-project-tooling"
  else
    ok hooks.path "core.hooksPath is '$hp' — present and tracked, so worktrees get the hooks too"
  fi
else
  bad commitlint.config "commitlint.config.mjs missing at repo root"
fi
# This skill has no single payload directory, so its stamp rides as a marker comment in
# scripts/husky.sh — the one shipped file that is unambiguously ours and always present.
check_payload_version \
  "$(sed -n 's/^# x442-payload-version: [^ ][^ ]* //p' scripts/husky.sh 2> /dev/null | head -1)" \
  setup-project-tooling

section "2. Declared tooling in package.json"
if [ -f package.json ] && is_json package.json; then
  ok package_json.valid "package.json is valid JSON"
  python3 - << 'PY' 2> /dev/null
import json,sys
d=json.load(open("package.json"))
dev=d.get("devDependencies",{})
need={"@commitlint/cli","@commitlint/config-conventional","lint-staged","prettier","prettier-plugin-sh"}
# `husky` is NOT required. Since payload 2 the installer sets core.hooksPath itself, with
# `git config`, and the hooks it writes are complete shell scripts that call the dispatcher
# directly — nothing invokes the husky binary any more. Demanding the package made every wired
# repo carry a dependency it never runs, and reported a repo that removed it as broken.
#
# The hook-install command may carry any name (prepare, install:dev, setup, ...), so match the
# INSTALLER it runs, not a script name and not a vendor name. The previous test looked for the
# substring "husky" in a script value, which our own `scripts/husky.sh install` satisfied by
# FILENAME — it would equally have passed a repo that lists husky and wires nothing, and failed a
# repo that wires hooks correctly from a script not named after husky.
#
# What actually proves the hooks are wired is core.hooksPath naming a tracked directory that
# exists, and hooks.path above checks exactly that. This check stays deliberately narrow: is
# there a script that runs the hook installer at all?
installs_hooks=any(
    ".sh install" in v or "husky install" in v or v.strip().endswith("install-hooks")
    for v in d.get("scripts",{}).values()
)
sys.exit(0 if need.issubset(dev) and installs_hooks else 1)
PY
  if [ $? -eq 0 ]; then ok devdeps.declared "package.json has commitlint/lint-staged/prettier(+sh) devDeps + a hook-install script"; else bad devdeps.declared "package.json missing commitlint/lint-staged/prettier(+sh) devDeps or a hook-install script"; fi
else
  bad package_json.valid "package.json missing or invalid JSON (needed for the Node-rooted tooling)"
fi

section "3. Staged-file lint/format (lint-staged)"
LS=0
if [ -f package.json ] && is_json package.json; then
  python3 -c "import json,sys; sys.exit(0 if 'lint-staged' in json.load(open('package.json')) else 1)" 2> /dev/null && {
    ok lintstaged.config "lint-staged config found (package.json key)"
    LS=1
  }
fi
if [ "$LS" -eq 0 ]; then
  for f in .lintstagedrc .lintstagedrc.json .lintstagedrc.yaml .lintstagedrc.yml .lintstagedrc.js .lintstagedrc.cjs .lintstagedrc.mjs lint-staged.config.js lint-staged.config.mjs lint-staged.config.cjs; do
    [ -f "$f" ] && {
      ok lintstaged.config "lint-staged config found ($f)"
      LS=1
      break
    }
  done
fi
[ "$LS" -eq 0 ] && bad lintstaged.config "no lint-staged config (package.json 'lint-staged' key or .lintstagedrc* file)"
# SQL profile: if a .sqlfluff exists it should declare a dialect.
if [ -f .sqlfluff ]; then
  if grep -qE '^[[:space:]]*dialect[[:space:]]*=' .sqlfluff; then ok sqlfluff.dialect ".sqlfluff present with a dialect"; else bad sqlfluff.dialect ".sqlfluff present but no dialect set"; fi
fi

section "4. Editor + workspace"
if [ -f .editorconfig ]; then ok editorconfig.present ".editorconfig present"; else bad editorconfig.present ".editorconfig missing"; fi
if [ -f .prettierrc ]; then
  if is_json .prettierrc; then ok prettierrc.valid ".prettierrc present and valid JSON"; else bad prettierrc.valid ".prettierrc is not valid JSON"; fi
else
  warn prettierrc.present ".prettierrc absent (base Prettier config not written)"
fi
if [ -f .prettierignore ]; then ok prettierignore.present ".prettierignore present"; else warn prettierignore.present ".prettierignore absent"; fi
if [ -f .vscode/settings.json ]; then
  if is_jsonc .vscode/settings.json; then ok vscode.settings.valid ".vscode/settings.json present and valid JSON"; else bad vscode.settings.valid ".vscode/settings.json is not valid JSON (comments and trailing commas are allowed)"; fi
else
  warn vscode.settings.present ".vscode/settings.json absent (editor format-on-save not configured)"
fi
if [ -f .vscode/extensions.json ]; then
  if is_jsonc .vscode/extensions.json; then ok vscode.extensions.valid ".vscode/extensions.json present and valid JSON"; else bad vscode.extensions.valid ".vscode/extensions.json is not valid JSON (comments and trailing commas are allowed)"; fi
else
  warn vscode.extensions.present ".vscode/extensions.json absent (no recommended extensions)"
fi
if [ -f .vscode/tasks.json ]; then
  if is_jsonc .vscode/tasks.json; then ok vscode.tasks.valid ".vscode/tasks.json present and valid JSON"; else bad vscode.tasks.valid ".vscode/tasks.json is not valid JSON (comments and trailing commas are allowed)"; fi
else
  warn vscode.tasks.present ".vscode/tasks.json absent (no workspace-bootstrap task)"
fi
if [ -f initialize.sh ]; then
  if [ -x initialize.sh ]; then ok initialize.executable "initialize.sh present and executable"; else bad initialize.executable "initialize.sh present but not executable (chmod +x)"; fi
else
  warn initialize.present "initialize.sh absent (workspace bootstrap not wired)"
fi

section "5. Git hygiene (.gitignore + .gitattributes)"
if [ -f .gitignore ]; then
  ok gitignore.present ".gitignore present"
  # Inverted at payload 2. Ignoring .husky/ used to be correct, because core.hooksPath pointed at
  # husky's generated .husky/_ and the hook files were regenerated on every install. It now points
  # at .husky/ itself, and those files are repo state that every worktree needs — so ignoring the
  # directory is the DEFECT, and ignoring only the vestigial .husky/_ is the fix.
  # Ask git rather than matching lines: `.husky/*`, `.husky/**` and `/.husky` hide the hooks as
  # surely as `.husky/`, and a regex for every spelling is a regex that misses the next one.
  # --no-index matters — without it an already-tracked hook never reads as ignored. Outside a git
  # work tree there is nothing to ask, so fall back to the line match.
  if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    HUSKY_HIDDEN=0
    git check-ignore -q --no-index .husky/commit-msg 2> /dev/null && HUSKY_HIDDEN=1
  else
    HUSKY_HIDDEN=0
    grep -qE '^[[:space:]]*/?\.husky(/|/\*|/\*\*)?[[:space:]]*$' .gitignore && HUSKY_HIDDEN=1
  fi
  if [ "$HUSKY_HIDDEN" = 1 ]; then
    bad gitignore.husky ".gitignore ignores .husky/ — the hooks cannot be committed, so no worktree runs them; fix: ignore only .husky/_ and re-run setup-project-tooling"
  elif grep -qE '^[[:space:]]*\.husky/_/?[[:space:]]*$' .gitignore; then
    ok gitignore.husky ".gitignore ignores .husky/_ only — the hook files stay tracked"
  else
    warn gitignore.husky ".gitignore does not mention .husky/_ (husky's generated helper dir will show as untracked)"
  fi
else
  warn gitignore.present ".gitignore absent (base ignore set not applied)"
fi
# Line endings. Everything this skill ships to a repo — scripts/husky.sh, initialize.sh,
# scripts/py-tool.sh, the generated .husky/ hooks — is a `#!/usr/bin/env bash` payload, and a CRLF
# checkout turns that shebang into `bash\r`, failing inside a git hook with a "no such file" naming
# a file that exists. Ask git for the effective attribute instead of pattern-matching, so a blanket
# `* text=auto eol=lf` counts as much as an explicit `*.sh` rule; grep only outside a work tree.
if [ -f .gitattributes ]; then
  ok gitattributes.present ".gitattributes present"
  EOL=""
  if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    EOL=$(git check-attr eol -- probe.sh 2> /dev/null | sed 's/.*: //')
  fi
  if [ "$EOL" = "lf" ]; then
    ok gitattributes.eol_lf ".gitattributes forces LF on *.sh (shebangs survive a Windows checkout)"
  elif [ -z "$EOL" ] && grep -qE '^[[:space:]]*(\*|\*\.sh)[[:space:]].*eol=lf' .gitattributes; then
    ok gitattributes.eol_lf ".gitattributes declares eol=lf covering *.sh"
  else
    warn gitattributes.eol_lf ".gitattributes does not force LF on *.sh (a CRLF checkout breaks the shipped hook payloads)"
  fi
else
  warn gitattributes.present ".gitattributes absent (line endings not normalized; a CRLF checkout breaks the shipped .sh payloads)"
fi

# Unity (draft module, see "Unity (draft — in progress)" in SKILL.md). Silent on any other repo.
# Probes are paths that need not exist: check-ignore --no-index and check-attr answer for a path
# from the rules alone, so an empty Assets/ is graded the same as a full one.
UPM_ASMDEF=""
if [ -f package.json ] && [ ! -d ProjectSettings ]; then
  UPM_ASMDEF=$(find . -maxdepth 3 -name '*.asmdef' -not -path './node_modules/*' 2> /dev/null | head -1)
fi
if [ -f ProjectSettings/ProjectVersion.txt ] && [ -d Assets ]; then
  section "5b. Unity project (draft module)"
  ok unity.detected "Unity project (ProjectSettings/ProjectVersion.txt + Assets/)"
  if [ -f pyproject.toml ] || [ -f tsconfig.json ]; then
    warn unity.mixed "Unity plus a second language's project file — the Unity module does not cover mixed repos yet; apply the common base with the Unity guards only"
  fi
  if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    for probe in Library/x UserSettings/x; do
      if git check-ignore -q --no-index "$probe" 2> /dev/null; then
        ok "unity.ignore.${probe%%/*}" ".gitignore ignores ${probe%%/*}/"
      else
        bad "unity.ignore.${probe%%/*}" ".gitignore does not ignore ${probe%%/*}/ — Unity regenerates it, and committing it bloats every clone; a regenerated .gitignore body drops it"
      fi
    done
    if git check-ignore -q --no-index Assets/x.cs.meta 2> /dev/null; then
      bad unity.meta_tracked ".gitignore ignores *.meta under Assets/ — Unity loses every asset reference on the next clone (toptal's csharp/visualstudio templates carry an unanchored *.meta)"
    else
      ok unity.meta_tracked "*.meta files under Assets/ stay tracked"
    fi
    if git check-ignore -q --no-index Assets/Scripts/x.cs 2> /dev/null; then
      bad unity.scripts_tracked ".gitignore ignores Assets/Scripts/ — an unanchored [Ss]cripts rule (virtualenv template) swallows the project's code"
    else
      ok unity.scripts_tracked "Assets/Scripts/ stays tracked"
    fi
    if [ "$(git check-attr merge -- x.unity 2> /dev/null | sed 's/.*: //')" = unityyamlmerge ]; then
      ok unity.yaml_merge ".gitattributes routes Unity YAML through unityyamlmerge"
    else
      warn unity.yaml_merge ".gitattributes does not set merge=unityyamlmerge on *.unity (scene and prefab merges fall back to text)"
    fi
    # Probe C#, not *.sh: the base check above already covers the scripts, and *.cs is what a
    # Windows editor rewrites to CRLF when only the scripts are pinned.
    if [ "$(git check-attr eol -- x.cs 2> /dev/null | sed 's/.*: //')" = lf ]; then
      ok unity.eol_lf ".gitattributes keeps every text file LF (*.cs included), so a Windows clone checks out LF"
    else
      warn unity.eol_lf ".gitattributes does not force LF on *.cs — add \`* text=auto eol=lf\` ABOVE the Unity rules (a Windows clone checks out CRLF)"
    fi
    # The placement mistake the eol probe cannot see: a `* text=auto` AFTER the Unity rules still
    # gives *.cs LF, but it overrides upstream's -text on every binary, LFS-routed or not.
    if [ "$(git check-attr text -- x.png 2> /dev/null | sed 's/.*: //')" = unset ]; then
      ok unity.binary_not_text "binaries stay -text (no later \`*\` text rule overrides the Unity rules)"
    else
      warn unity.binary_not_text "*.png is not -text — a \`* text\` rule placed after the Unity rules overrides them; move it above"
    fi
    if [ "$(git check-attr filter -- x.png 2> /dev/null | sed 's/.*: //')" = lfs ]; then
      HOOKS_DIR="$(git config core.hooksPath 2> /dev/null || true)"
      case "${HOOKS_DIR%/}" in
        .husky/_) HOOKS_DIR=.husky ;;
        "") HOOKS_DIR="$(git rev-parse --git-common-dir)/hooks" ;;
      esac
      for hook in pre-push post-checkout post-commit post-merge; do
        if grep -q "git lfs $hook" "${HOOKS_DIR%/}/$hook" 2> /dev/null; then
          ok "unity.lfs.$hook" "LFS $hook hook present in ${HOOKS_DIR%/}/"
        elif [ "$hook" = pre-push ]; then
          bad unity.lfs.pre-push "binaries route through Git LFS but ${HOOKS_DIR%/}/pre-push does not run git lfs pre-push — a push sends pointers without objects"
        else
          warn "unity.lfs.$hook" "binaries route through Git LFS but ${HOOKS_DIR%/}/$hook does not run git lfs $hook (git lfs install stops short when a post-commit already exists)"
        fi
      done
    fi
  else
    warn unity.git "not a git work tree — Unity ignore and attribute checks skipped"
  fi
  if [ -f Packages/manifest.json ]; then
    if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(1 if {'devDependencies','scripts','lint-staged'} & set(d) else 0)" Packages/manifest.json 2> /dev/null; then
      ok unity.manifest "Packages/manifest.json carries no npm keys"
    else
      bad unity.manifest "Packages/manifest.json has npm keys (devDependencies, scripts or lint-staged) or does not parse — it is Unity's package manifest; move them to the root package.json"
    fi
  fi
elif [ -n "$UPM_ASMDEF" ]; then
  section "5b. Unity project (draft module)"
  warn unity.upm_package "a root package.json beside ${UPM_ASMDEF#./} and no ProjectSettings/ — this looks like a Unity package, whose package.json is Unity's manifest; the Unity module does not cover package repos yet"
fi

section "6. Release automation (release-it) — optional per profile"
if [ -f .release-it.json ]; then
  if is_json .release-it.json; then ok releaseit.valid ".release-it.json present and valid JSON"; else bad releaseit.valid ".release-it.json is not valid JSON"; fi
  if [ -f package.json ] && grep -q '"release"' package.json; then ok releaseit.release_script "package.json has a release script"; else bad releaseit.release_script ".release-it.json present but no release script in package.json"; fi
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
    *.md) ok releaseit.changelog_infile "changelog infile is a markdown path ($INFILE)" ;;
    *) warn releaseit.changelog_infile "changelog infile '$INFILE' has no .md extension — the plugin writes markdown, so it renders as plain text and .prettierignore's CHANGELOG.md entry will not match" ;;
  esac
else
  warn releaseit.present ".release-it.json absent — release automation not wired (skip if intentional)"
fi
# Legacy commit/release stack. standard-version is deprecated upstream and release-it covers it;
# the skill always offers the migration, so a repo that still carries the stack either declined it
# or has not re-run the skill. Advisory only — keeping it is a legitimate choice.
LEGACY=""
if [ -f package.json ]; then
  LEGACY=$(python3 -c "
import json,re
p=json.load(open('package.json'))
deps={**p.get('dependencies',{}),**p.get('devDependencies',{})}
legacy=re.compile(r'^(commitizen|standard-version|commit-and-tag-version|conventional-changelog-.+|cz-.+|@commitlint/cz-commitlint)$')
hits=sorted(d for d in deps if legacy.match(d) and d!='conventional-changelog-conventionalcommits')
if isinstance(p.get('config'),dict) and 'commitizen' in p['config']: hits.append('config.commitizen')
print(' '.join(hits))" 2> /dev/null)
fi
for f in .czrc .cz.json .versionrc .versionrc.json .versionrc.js .versionrc.cjs; do
  [ -f "$f" ] && LEGACY="${LEGACY:+$LEGACY }$f"
done
if [ -n "$LEGACY" ]; then
  warn legacy.release_tooling "legacy commit/release tooling present ($LEGACY) — re-run setup-project-tooling to migrate to release-it, or ignore if kept on purpose"
else
  ok legacy.release_tooling "no commitizen / standard-version leftovers"
fi

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
    "tool": "verify-project-tooling",
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
