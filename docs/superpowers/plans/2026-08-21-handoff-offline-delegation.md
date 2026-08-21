# Offline Handoff Delegation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an orchestrator hand a self-contained execution brief to a developer who has the repo but not the handoff board, and bring their reported result back onto the board without ever trusting their status claim.

**Architecture:** Two new subcommands in the `handoff` bash CLI. `export` renders a board doc plus an inlined executor contract into `.agents/handoff/briefs/<id>.brief.md`, claims the lease, and stamps who has it. `import --result` validates a returned brief against a stack of refusals — repo identity first — then splices its Result block into the doc and flags it for review. A markdown-only `delegate-handoff` skill carries the judgment the CLI cannot encode.

**Tech Stack:** Bash 3.2-compatible (macOS ships it), `awk` for frontmatter edits, `git` for repo identity, the existing `render_tmpl` template filler, and the `config.selftest.sh` PASS/FAIL self-test pattern.

**Spec:** [docs/superpowers/specs/2026-08-21-handoff-offline-delegation-design.md](../specs/2026-08-21-handoff-offline-delegation-design.md)

## Global Constraints

Every task's requirements implicitly include these.

- **Branch:** `feature/handoff-offline-delegation`. Already created; do not branch again.
- **Edit the source of truth, never the installed copy.** All CLI work happens in `skills/engineering/setup-handoff/scripts/payload/handoff`. `.agents/handoff/handoff` is an installed artifact and is refreshed in Task 6. Editing it directly creates drift that nothing will catch until the version check fires.
- **Portability:** no `sed -i`, no GNU-only `date` flags, no `readlink -f`. Frontmatter edits go through `awk` via the existing `set_field`. Bash 3.2 — no associative arrays, no `${var^^}`.
- **No `:` in any frontmatter value.** Values land as unquoted YAML. Free text goes through `fold_colons` first.
- **Value-taking flags must use a guard.** `require_value` exists in `setup-handoff.sh` but not yet in the payload CLI; Task 1 adds it there. Every new value-taking flag calls it. An unguarded `${2:-}` lets `--to --no-claim` silently set `to="--no-claim"`.
- **Formatting:** `.editorconfig` — UTF-8, LF, 2-space indent, final newline. Run `npx prettier --write` on any `.md` before committing; the pre-commit hook will do it anyway and restage.
- **Commit scopes are a fixed enum:** `setup, config, deps, feature, bug, docs, style, refactor, test, build, ci, release, other`. `handoff` is **not** a valid scope. Use `feature` for CLI work, `docs` for documentation, `test` for harness work.
- **Standalone rule:** no foreign project names anywhere. Use `acme-api`, `acme-lib`, `svc-a`. `scripts/verify-standalone.sh` runs on pre-commit against staged files.
- **No emojis in skill content.** The CLI's existing output emojis (`🔒`, `⚠️`) are program output, not skill content, and stay.

### Deferred decision — temp-directory cleanup in the self-test

The repo's house rule forbids `rm -rf`, but the existing `config.selftest.sh` cleans its own `mktemp -d` with `trap 'rm -rf "$T"' EXIT`. This plan **matches the existing file** for consistency within the payload. If the reviewer prefers, swap every self-test cleanup to `command -v trash >/dev/null && trash "$T" || rm -rf "$T"` in Task 1 and keep it consistent thereafter. Do not mix the two.

---

## File Structure

**Created:**

| Path                                                                   | Responsibility                                      |
| ---------------------------------------------------------------------- | --------------------------------------------------- |
| `skills/engineering/setup-handoff/assets/handoff-brief-template.md`    | The brief's shape — placeholders only, no logic     |
| `skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh` | Every deterministic test for export and import      |
| `skills/engineering/delegate-handoff/SKILL.md`                         | The judgment half — when to delegate, how to review |
| `harness/delegate-handoff-workspace/`                                  | Eval fixtures, cases, grader                        |

**Modified:**

| Path                                                               | Change                                                                                                     |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| `skills/engineering/setup-handoff/scripts/payload/handoff`         | `require_value`, identity helpers, `cmd_export`, `cmd_import --result`, `list`/`release` changes, dispatch |
| `skills/engineering/setup-handoff/scripts/setup-handoff.sh`        | Install the brief template, create `briefs/`                                                               |
| `skills/engineering/setup-handoff/scripts/payload.version`         | `setup-handoff 2` to `setup-handoff 3`                                                                     |
| `skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh` | Check the new template and `briefs/` are installed                                                         |
| `skills/engineering/setup-handoff/assets/agents-handoff.md`        | Document the delegation loop in the AGENTS block                                                           |
| `skills/engineering/setup-handoff/scripts/payload/README.md`       | Protocol docs for export/import                                                                            |
| `skills/engineering/repair-handoff/SKILL.md`                       | Orphaned-delegation drift check                                                                            |
| `AGENTS.md`, `skills/README.md`                                    | Catalog row for `delegate-handoff`                                                                         |

---

## Task 1: Source guard and repo identity helpers

The CLI runs its dispatch `case` at file scope, so sourcing it executes `cmd_list`. The self-test needs to call pure helpers directly. Guarding the dispatch is the smallest change that makes the whole file testable.

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/payload/handoff` (add helpers near `slug()` at line 67; guard dispatch at line 1387)
- Create: `skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh`

**Interfaces:**

- Consumes: `REPO_DIR` (set at line 42), `die`, `sec_dir`
- Produces: `repo_root_commit [dir] -> sha|""`, `repo_origin_norm <url> -> host/owner/repo`, `briefs_dir [group] -> path`, `require_value <flag> <argcount> <val>`

- [ ] **Step 1: Write the failing self-test**

Create `skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh`:

```bash
#!/usr/bin/env bash
# Self-test for the handoff CLI's export/import round-trip. Read-only outside its own temp dirs.
# Run: bash handoff.selftest.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$(cd "$HERE/../../assets" && pwd)"
P=0
F=0

chk() { # label expected actual
  if [ "$2" = "$3" ]; then
    printf '  [PASS] %s\n' "$1"
    P=$((P + 1))
  else
    printf '  [FAIL] %s (want %s, got %s)\n' "$1" "$2" "$3"
    F=$((F + 1))
  fi
}

chk_contains() { # label haystack needle
  case "$2" in
    *"$3"*)
      printf '  [PASS] %s\n' "$1"
      P=$((P + 1))
      ;;
    *)
      printf '  [FAIL] %s (missing %s)\n' "$1" "$3"
      F=$((F + 1))
      ;;
  esac
}

# Sourcing the CLI must not run a command. HANDOFF_NO_MAIN is the guard added in this task.
HANDOFF_NO_MAIN=1
export HANDOFF_NO_MAIN
# shellcheck disable=SC1091
. "$HERE/handoff"

printf '\nrepo_origin_norm\n'
chk "ssh form" "github.com/acme/acme-api" "$(repo_origin_norm 'git@github.com:acme/acme-api.git')"
chk "https form" "github.com/acme/acme-api" "$(repo_origin_norm 'https://github.com/acme/acme-api.git')"
chk "https with credentials" "github.com/acme/acme-api" "$(repo_origin_norm 'https://user:tok@github.com/acme/acme-api.git')"
chk "no .git suffix" "github.com/acme/acme-api" "$(repo_origin_norm 'https://github.com/acme/acme-api')"
chk "trailing slash" "github.com/acme/acme-api" "$(repo_origin_norm 'https://github.com/acme/acme-api/')"
chk "no colon survives" "" "$(repo_origin_norm 'git@github.com:acme/acme-api.git' | tr -cd ':')"

printf '\n--- %d passed, %d failed ---\n' "$P" "$F"
[ "$F" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
```

Expected: the CLI runs `cmd_list` on source (or errors), and `repo_origin_norm: command not found` for every check.

- [ ] **Step 3: Add the helpers**

In `skills/engineering/setup-handoff/scripts/payload/handoff`, immediately after `slug()` (line 67):

```bash
# Guard for every value-taking flag in the subcommand arg loops below. A value that is missing (the
# flag was the last argument) or that itself looks like a flag is never accepted silently: without
# this, `export ID --to --no-claim` sets to="--no-claim" and silently skips the claim. Mirrors
# setup-handoff.sh's guard of the same name and fails hard for the same reason. $2 is the caller's
# "$#" from before this flag's own shift; $3 is the candidate value.
require_value() {
  local flag="$1" argcount="$2" val="$3"
  [ "$argcount" -lt 2 ] && die "$flag needs a value (got nothing — it was the last argument)"
  case "$val" in
    --*) die "$flag needs a value (got the flag \"$val\")" ;;
  esac
}

# --- repo identity ----------------------------------------------------------------------
# A brief names file:line locations, and those paths plausibly exist in a DIFFERENT repo where they
# mean something else. Identity therefore travels inside the brief and is checked on both sides.
#
# The root commit is the key rather than the remote URL: it survives renames, remote moves, and
# mirror pushes, and a fork matching it is the correct answer because a fork is the same lineage.
repo_root_commit() { # [dir] -> sha of the first commit, or "" outside a git repo
  git -C "${1:-${REPO_DIR:-.}}" rev-list --max-parents=0 HEAD 2> /dev/null | tail -1
}

# Normalize a remote URL to bare host/owner/repo. This is a CORRECTNESS requirement, not cosmetics:
# the SSH form "git@github.com:acme/acme-api.git" carries a ":" that would break the brief's
# frontmatter under the board's no-colon rule. Strips scheme, embedded credentials, the ":" that
# separates host from path in the SSH form, the ".git" suffix, and any trailing slash.
# Known limitation: an https URL carrying an explicit port renders as host/port/owner/repo. Ports
# on git remotes are rare enough that special-casing them would cost more than it buys.
repo_origin_norm() { # url -> host/owner/repo
  printf '%s' "$1" | sed \
    -e 's#^[a-zA-Z+][a-zA-Z0-9+.-]*://##' \
    -e 's#^[^/@]*@##' \
    -e 's#:#/#' \
    -e 's#\.git$##' \
    -e 's#/*$##'
}

# Briefs live beside the section's archive, so a grouped board keeps each section's briefs separate.
briefs_dir() { printf '%s/briefs' "$(sec_dir "${1:-${GROUP:-}}")"; }
```

- [ ] **Step 4: Guard the dispatch**

At line 1387, wrap the dispatch. Replace `case "${1:-list}" in` with:

```bash
# Sourcing this file (the self-test does) must not execute a subcommand. Any other entry point is
# unaffected: HANDOFF_NO_MAIN is set by nothing but the self-test.
if [ -z "${HANDOFF_NO_MAIN:-}" ]; then
  case "${1:-list}" in
```

and close it after `esac` with `fi`. Indent the `case` body by two spaces to keep `.editorconfig` and shellcheck happy.

- [ ] **Step 5: Run the self-test to verify it passes**

```bash
bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
```

Expected: `6 passed, 0 failed`, exit 0.

- [ ] **Step 6: Confirm normal invocation still works**

```bash
.agents/handoff/handoff list
```

Expected: the board listing, unchanged. (This runs the _installed_ copy, which is still the old one — that is correct at this stage and proves nothing broke. Task 6 refreshes it.)

- [ ] **Step 7: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/payload/handoff \
  skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
git commit -m "feat(feature): add repo identity helpers and a sourceable guard to the handoff CLI"
```

---

## Task 2: Brief template and section extraction

**Files:**

- Create: `skills/engineering/setup-handoff/assets/handoff-brief-template.md`
- Modify: `skills/engineering/setup-handoff/scripts/payload/handoff` (add `doc_section` after `meta`, line 269)
- Modify: `skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh`

**Interfaces:**

- Consumes: `meta`, `render_tmpl`, `tmpl_path`
- Produces: `doc_section <path> <heading> -> body lines under "## <heading>"`

- [ ] **Step 1: Write the failing test**

Append to `handoff.selftest.sh`, before the summary block:

```bash
printf '\ndoc_section\n'
DS="$(mktemp -d)"
trap 'rm -rf "$DS"' EXIT
cat > "$DS/doc.md" << 'DOCEOF'
---
id: rbac-gap-handoff
---

## Context

symptom leads to cause

## Where

src/auth/tenant.ts:88

## Verify

run the suite
DOCEOF
chk "extracts a middle section" "src/auth/tenant.ts:88" "$(doc_section "$DS/doc.md" Where | tr -d '\n')"
chk "extracts the last section" "run the suite" "$(doc_section "$DS/doc.md" Verify | tr -d '\n')"
chk "absent section is empty" "" "$(doc_section "$DS/doc.md" Decisions | tr -d '\n')"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
```

Expected: three FAILs with `doc_section: command not found`.

- [ ] **Step 3: Implement `doc_section`**

In the payload CLI, immediately after `meta()` (line 269):

```bash
# Extract one "## Heading" section's body from a doc, heading excluded. Used to lift Context /
# Where / Verify / Decisions out of a board doc and into a brief. Blank leading and trailing lines
# are trimmed so the rendered brief has no ragged gaps between sections.
doc_section() { # path heading -> body lines
  awk -v h="## $2" '
    $0 == h { inside = 1; next }
    inside && /^## / { inside = 0 }
    inside { print }
  ' "$1" | awk '
    { line[NR] = $0 }
    END {
      first = 1; last = NR
      while (first <= NR && line[first] ~ /^[[:space:]]*$/) first++
      while (last >= first && line[last] ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print line[i]
    }
  '
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
```

Expected: `9 passed, 0 failed`.

- [ ] **Step 5: Create the brief template**

Create `skills/engineering/setup-handoff/assets/handoff-brief-template.md`. Placeholders are filled by `render_tmpl`, which substitutes literally and cannot be broken by any character in a value.

````markdown
---
brief: 1
handoff: PLACEHOLDER_ID
title: PLACEHOLDER_TITLE
severity: PLACEHOLDER_SEVERITY
repo_name: PLACEHOLDER_REPO_NAME
repo_origin: PLACEHOLDER_REPO_ORIGIN
repo_root_commit: PLACEHOLDER_ROOT_COMMIT
source_commit: PLACEHOLDER_SOURCE_COMMIT
source_branch: PLACEHOLDER_SOURCE_BRANCH
exported: PLACEHOLDER_EXPORTED
branch: PLACEHOLDER_BRANCH
result_status:
result_by:
result_at:
---

<!-- NEVER COMMIT SECRETS. This brief is committed to the repo and its git history.
     Never paste keys, API tokens, passwords, confidential data, or PII into the Result
     block. If you need a credential, ask for it out of band and record only its NAME. -->

# PLACEHOLDER_TITLE

## 0. Preflight — confirm you are in the right repository

This brief names specific file paths. Those paths may also exist in a different repository, where
they mean something else. Run this before making a single edit:

```sh
[ "$(git rev-list --max-parents=0 HEAD | tail -1)" = "PLACEHOLDER_ROOT_COMMIT" ] \
  && echo "OK — correct repo" || echo "WRONG REPO — do not proceed"
```

If it prints `WRONG REPO`, stop and return this brief unexecuted. Expected repository —
`PLACEHOLDER_REPO_NAME` at `PLACEHOLDER_REPO_ORIGIN`.

PLACEHOLDER_PREFLIGHT_NOTE

## 1. Your assignment

### Context

PLACEHOLDER_CONTEXT

### Where

PLACEHOLDER_WHERE

### Decisions already made

PLACEHOLDER_DECISIONS

## 2. Executor contract

These are not suggestions. They replace the tooling that normally enforces them.

- Do exactly the scope in section 1. If it grows, **stop** and report `partial` with what you
  found. Do not expand scope on your own judgment.
- Do not relitigate anything under Decisions. Those are settled.
- Work on branch `PLACEHOLDER_BRANCH`. Use conventional commits. Open a pull request. **Do not
  merge it.**
- `done` means you verified against live code. Evidence must name a command and its output, or a
  `file:line` you checked. "Looks correct" is not evidence.
- Never paste secrets, keys, or PII anywhere in this file. It is committed to git history.
- Do not edit anything under the handoff directory except this brief's Result block.
- Never delete with `rm`. Use `trash`.
- If you are blocked, report `blocked` and name the blocker. Guessing is worse than blocking.

## 3. Repo rules

Read these in the checkout — they are authoritative and they are not copied here:

- `AGENTS.md` — shared conventions, and the tool-specific file it points to
- The commit convention and branch naming rules referenced from `AGENTS.md`

## 4. Dependencies

PLACEHOLDER_DEPENDENCIES

## 5. Definition of done

PLACEHOLDER_VERIFY

## 6. Result — fill this in

Set `result_status`, `result_by`, and `result_at` in the frontmatter above, then complete every
subsection. Leave the marker comments in place; they are how this gets read back.

<!-- handoff:result:begin -->

### Status

<!-- done | partial | blocked — must match result_status in the frontmatter -->

### What changed

### Evidence

<!-- A command and its output, or a file:line you checked. Not "looks correct". -->

### Commits and PR

### Open questions and follow-ups

<!-- handoff:result:end -->
````

- [ ] **Step 6: Commit**

```bash
npx prettier --write skills/engineering/setup-handoff/assets/handoff-brief-template.md
git add skills/engineering/setup-handoff/assets/handoff-brief-template.md \
  skills/engineering/setup-handoff/scripts/payload/handoff \
  skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
git commit -m "feat(feature): add the handoff brief template and section extraction"
```

---

## Task 3: `handoff export`

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/payload/handoff` (add `cmd_export` after `cmd_import`, line 816; add dispatch arm)
- Modify: `skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh`

**Interfaces:**

- Consumes: `resolve_id`, `doc_of`, `no_such`, `is_standalone`, `is_orchestrator`, `children_of`, `doc_section`, `meta`, `set_field`, `render_tmpl`, `tmpl_path`, `briefs_dir`, `repo_root_commit`, `repo_origin_norm`, `require_value`, `cmd_claim`, `cmd_index`, `today`, `fold_colons`
- Produces: `cmd_export <id> [--to WHO] [--out DIR] [--branch NAME] [--no-claim]`, writing `$(briefs_dir)/<id>.brief.md` and stamping `delegated_to` / `delegated_at` / `brief`

- [ ] **Step 1: Write the failing test**

Add a board factory and export tests to `handoff.selftest.sh`, before the summary block:

```bash
# A throwaway board inside its own git repo. The board must be a real git repo because export
# reads repo identity from it.
mkboard() { # -> path to the repo root
  local r
  r="$(mktemp -d)"
  git -C "$r" init -q
  git -C "$r" config user.email "test@example.com"
  git -C "$r" config user.name "test"
  git -C "$r" remote add origin "git@github.com:acme/acme-api.git"
  printf 'x\n' > "$r/README.md"
  git -C "$r" add -A
  git -C "$r" commit -qm "initial commit"
  mkdir -p "$r/.agents/handoff/scripts" "$r/.agents/handoff/templates" "$r/.agents/handoff/archive"
  cp "$HERE/handoff" "$r/.agents/handoff/handoff"
  cp "$HERE/config.sh" "$r/.agents/handoff/scripts/config.sh"
  cp "$ASSETS"/handoff-*-template.md "$r/.agents/handoff/templates/"
  chmod +x "$r/.agents/handoff/handoff"
  printf '%s' "$r"
}

hb() { # repo subcommand... -> run the board CLI from inside that repo
  (cd "$1" && shift && ./.agents/handoff/handoff "$@") 2>&1
}

printf '\ncmd_export\n'
R="$(mkboard)"
BOARD="$R/.agents/handoff"
hb "$R" new rbac-gap --title "RBAC gap on tenant switch" --severity high > /dev/null
BRIEF="$BOARD/briefs/rbac-gap-handoff.brief.md"

hb "$R" export rbac-gap --to "Alice" > /dev/null
chk "brief was written" "yes" "$([ -f "$BRIEF" ] && echo yes || echo no)"
chk "brief names the handoff" "rbac-gap-handoff" "$(sed -n 's/^handoff: //p' "$BRIEF" | head -1)"
chk "brief carries root commit" "$(git -C "$R" rev-list --max-parents=0 HEAD | tail -1)" \
  "$(sed -n 's/^repo_root_commit: //p' "$BRIEF" | head -1)"
chk "origin normalized" "github.com/acme/acme-api" "$(sed -n 's/^repo_origin: //p' "$BRIEF" | head -1)"
chk "no colon in frontmatter values" "" "$(sed -n '2,/^---$/p' "$BRIEF" | sed 's/^[a-z_]*://' | tr -cd ':')"
chk "default branch" "fix/rbac-gap-handoff" "$(sed -n 's/^branch: //p' "$BRIEF" | head -1)"
chk "result_status ships empty" "" "$(sed -n 's/^result_status:[[:space:]]*//p' "$BRIEF" | head -1)"
chk_contains "result markers present" "$(cat "$BRIEF")" "<!-- handoff:result:begin -->"

DOC="$BOARD/rbac-gap-handoff.md"
chk "doc records the delegate" "Alice" "$(sed -n 's/^delegated_to: //p' "$DOC" | head -1)"
chk "doc records the brief path" "yes" "$(grep -q '^brief: ' "$DOC" && echo yes || echo no)"
chk "export took the lease" "yes" "$([ -d "$BOARD/.locks/rbac-gap-handoff" ] && echo yes || echo no)"
chk "status untouched by export" "open" "$(sed -n 's/^status: //p' "$DOC" | head -1)"

chk_contains "flag guard rejects a swallowed flag" "$(hb "$R" export rbac-gap --to --no-claim)" \
  "--to needs a value"

hb "$R" new port-guide --standalone --title "Porting guide" > /dev/null
chk_contains "standalone refused" "$(hb "$R" export port-guide)" "standalone"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
```

Expected: every export check FAILs; the CLI prints its usage line because `export` is not a known subcommand.

- [ ] **Step 3: Implement `cmd_export`**

In the payload CLI, after `cmd_import` ends (line 816):

```bash
# Render a board doc into a self-contained execution brief for someone who has the repo but not the
# board — no leases, no hooks, no skills. The brief inlines the executor contract that those would
# otherwise carry, and it carries repo identity so it cannot be run against the wrong checkout.
cmd_export() {
  local id="${1:?usage: handoff export <id> [--to WHO] [--out DIR] [--branch NAME] [--no-claim]}"
  shift
  local raw_id="$id" to="" outdir="" branch="" do_claim=1
  id="$(resolve_id "$id")" || die "unusable id: '$raw_id' (needs at least one letter or digit)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --to)
        require_value --to "$#" "${2:-}"
        to="$(fold_colons "$2")"
        shift 2
        ;;
      --out)
        require_value --out "$#" "${2:-}"
        outdir="$2"
        shift 2
        ;;
      --branch)
        require_value --branch "$#" "${2:-}"
        branch="$2"
        shift 2
        ;;
      --no-claim)
        do_claim=0
        shift
        ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  local f
  f="$(doc_of "$id")" || no_such "$id"
  is_standalone "$f" && die "$id is a standalone/reference handoff — it holds no work to delegate. Send the file itself."
  [ "$(meta "$f" status)" = "done" ] && die "$id is already done — nothing to delegate"

  if is_orchestrator "$f"; then
    export_bundle "$id" "$f" "$to" "$outdir" "$branch" "$do_claim"
    return
  fi
  export_one "$id" "$f" "$to" "$outdir" "$branch" "$do_claim"
}

# Resolve identity for the repo a brief targets. On a flat board that is this repo. On a grouped
# board the doc's audience names a DIFFERENT repo, and if it is not reachable on disk we record
# "unverified" rather than fabricate a SHA — a fabricated SHA would make a wrong-repo run look
# verified, which is worse than no guard at all.
brief_identity() { # doc-path -> "name|origin|rootsha|note"
  local f="$1" target="${REPO_DIR:-}" name origin root note=""
  local aud
  aud="$(meta "$f" audience)"
  if [ -n "$aud" ] && [ "$aud" != "$REPO_NAME" ]; then
    if [ -d "${REPO_DIR:-.}/../$aud/.git" ]; then
      target="$(cd "${REPO_DIR:-.}/../$aud" && pwd)"
    else
      target=""
    fi
  fi
  if [ -z "$target" ]; then
    printf '%s|%s|%s|%s' "${aud:-unknown}" "unverified" "unverified" \
      "> **Warning** — the target repository was not reachable when this brief was rendered, so the root-commit check above cannot pass. Confirm by name and remote instead, and ask the sender before proceeding."
    return
  fi
  name="$(basename "$target")"
  origin="$(repo_origin_norm "$(git -C "$target" config --get remote.origin.url 2> /dev/null || echo "")")"
  root="$(repo_root_commit "$target")"
  printf '%s|%s|%s|%s' "$name" "${origin:-unknown}" "${root:-unverified}" "$note"
}

# Resolve blocked_on and, for a bundle child, its siblings into readable lines. A brief's reader
# cannot query the board, so a bare id would be meaningless to them.
brief_dependencies() { # doc-path -> markdown lines
  local f="$1" b out="" bf
  b="$(meta "$f" blocked_on)"
  if [ -n "$b" ]; then
    case "$b" in
      external*) out="- Blocked on something off the board — $b" ;;
      *)
        bf="$(doc_of "$(resolve_id "$b")" 2> /dev/null || true)"
        if [ -n "$bf" ] && [ -f "$bf" ]; then
          out="- Blocked on \`$b\` — $(meta "$bf" title) (status — $(meta "$bf" status))"
        else
          out="- Blocked on \`$b\` (not resolvable from this board)"
        fi
        ;;
    esac
  fi
  [ -n "$out" ] || out="None. This unit stands alone."
  printf '%s' "$out"
}

export_one() { # id doc to outdir branch do_claim
  local id="$1" f="$2" to="$3" outdir="$4" branch="$5" do_claim="$6"
  local name origin root note
  IFS='|' read -r name origin root note <<< "$(brief_identity "$f")"
  [ -n "$branch" ] || branch="fix/$id"

  local dest_dir dest
  dest_dir="${outdir:-$(briefs_dir)}"
  mkdir -p "$dest_dir" || die "could not create $dest_dir"
  dest="$dest_dir/$id.brief.md"

  local tmpl
  tmpl="$(tmpl_path handoff-brief-template.md)"
  [ -f "$tmpl" ] || die "brief template missing from this board — re-run setup-handoff to update it"

  render_tmpl "$tmpl" \
    "PLACEHOLDER_ID=$id" \
    "PLACEHOLDER_TITLE=$(meta "$f" title)" \
    "PLACEHOLDER_SEVERITY=$(meta "$f" severity)" \
    "PLACEHOLDER_REPO_NAME=$name" \
    "PLACEHOLDER_REPO_ORIGIN=$origin" \
    "PLACEHOLDER_ROOT_COMMIT=$root" \
    "PLACEHOLDER_SOURCE_COMMIT=$(git -C "${REPO_DIR:-.}" rev-parse --short HEAD 2> /dev/null || echo unknown)" \
    "PLACEHOLDER_SOURCE_BRANCH=$(git -C "${REPO_DIR:-.}" rev-parse --abbrev-ref HEAD 2> /dev/null || echo unknown)" \
    "PLACEHOLDER_EXPORTED=$(today)" \
    "PLACEHOLDER_BRANCH=$branch" \
    "PLACEHOLDER_PREFLIGHT_NOTE=$note" \
    "PLACEHOLDER_CONTEXT=$(doc_section "$f" Context)" \
    "PLACEHOLDER_WHERE=$(doc_section "$f" Where)" \
    "PLACEHOLDER_DECISIONS=$(doc_section "$f" Decisions)" \
    "PLACEHOLDER_VERIFY=$(doc_section "$f" Verify)" \
    "PLACEHOLDER_DEPENDENCIES=$(brief_dependencies "$f")" \
    > "$dest" || die "could not write $dest"

  set_field "$f" delegated_to "${to:-unassigned}"
  set_field "$f" delegated_at "$(today)"
  set_field "$f" brief "${dest#"$REPO_DIR"/}"
  log_activity "$f" "exported as a brief for ${to:-an external executor}"

  if [ "$do_claim" -eq 1 ]; then
    cmd_claim "$id" "delegated to ${to:-an external executor}" > /dev/null \
      || die "could not claim $id — resolve the lease before delegating, so the board does not read as free while someone works it"
  fi

  echo "Wrote $dest"
  echo "🔒 Before committing — redact secrets/keys/PII, then commit the brief so the executor can pull it."
  cmd_index
}

export_bundle() { # id doc to outdir branch do_claim
  local id="$1" f="$2" to="$3" outdir="$4" branch="$5" do_claim="$6"
  local dest_dir cover kid kf n=0
  dest_dir="${outdir:-$(briefs_dir)}"
  mkdir -p "$dest_dir" || die "could not create $dest_dir"
  cover="$dest_dir/$id.cover.md"
  {
    echo "# Bundle — $(meta "$f" title)"
    echo
    echo "You have been given a bundle of related units. Each has its own brief; read this first."
    echo
    echo "## Bundle"
    echo
    doc_section "$f" Bundle
    echo
    echo "## Sequencing"
    echo
    doc_section "$f" Sequencing
    echo
    echo "## Units"
    echo
  } > "$cover"

  while IFS= read -r kid; do
    [ -n "$kid" ] || continue
    kf="$(doc_of "$kid" 2> /dev/null || true)"
    if [ -z "$kf" ] || [ ! -f "$kf" ]; then
      echo "⚠️  child $kid has no doc on this board — skipped" >&2
      continue
    fi
    export_one "$kid" "$kf" "$to" "$outdir" "" "$do_claim" > /dev/null
    echo "- \`$kid\` — $(meta "$kf" title) — brief at \`$kid.brief.md\`" >> "$cover"
    n=$((n + 1))
  done <<< "$(children_of "$f")"

  echo "Wrote $cover and $n child brief(s) in $dest_dir"
  echo "🔒 Before committing — redact secrets/keys/PII, then commit the briefs."
  cmd_index
}
```

- [ ] **Step 4: Add the dispatch arm**

Inside the guarded `case`, after the `import)` arm:

```bash
    export)
      shift
      cmd_export "$@"
      ;;
```

Update the usage string in the `*)` arm to include:

```text
export <id> [--to WHO] [--out DIR] [--branch NAME] [--no-claim]
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
```

Expected: all export checks PASS.

- [ ] **Step 6: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/payload/handoff \
  skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
git commit -m "feat(feature): add handoff export for offline execution briefs"
```

---

## Task 4: `handoff import --result`

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/payload/handoff` (`cmd_import` at line 724 gains a `--result` branch; new `import_result`)
- Modify: `skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh`

**Interfaces:**

- Consumes: everything from Task 3, plus `is_archived`, `arch_file`
- Produces: `import_result <file> [--force-repo]`, splicing the Result and stamping `result_from` / `result_at` / `result_claimed` / `review`

- [ ] **Step 1: Write the failing test**

Append to `handoff.selftest.sh`:

```bash
printf '\nimport --result\n'
fill_brief() { # brief-file status -> fill the frontmatter and Result block
  local b="$1" st="$2" t
  t="$(mktemp)"
  sed -e "s/^result_status:.*/result_status: $st/" \
    -e "s/^result_by:.*/result_by: Alice/" \
    -e "s/^result_at:.*/result_at: 2026-08-22/" "$b" > "$t"
  awk '
    /<!-- handoff:result:begin -->/ {
      print
      print ""
      print "### Status"
      print ""
      print "done"
      print ""
      print "### What changed"
      print ""
      print "Guarded the tenant switch."
      print ""
      print "### Evidence"
      print ""
      print "Ran npm test -- tenant; 14 passing."
      print ""
      print "### Commits and PR"
      print ""
      print "abc1234, PR #42"
      print ""
      print "### Open questions and follow-ups"
      print ""
      print "None."
      print ""
      skip = 1
      next
    }
    /<!-- handoff:result:end -->/ { skip = 0 }
    !skip { print }
  ' "$t" > "$b"
  rm -f "$t"
}

fill_brief "$BRIEF" done
hb "$R" import --result "$BRIEF" > /dev/null
DOC="$BOARD/rbac-gap-handoff.md"
chk "status still NOT done" "open" "$(sed -n 's/^status: //p' "$DOC" | head -1)"
chk "claim recorded as a claim" "done" "$(sed -n 's/^result_claimed: //p' "$DOC" | head -1)"
chk "reporter recorded" "Alice" "$(sed -n 's/^result_from: //p' "$DOC" | head -1)"
chk "flagged for review" "pending" "$(sed -n 's/^review: //p' "$DOC" | head -1)"
chk_contains "result spliced into the doc" "$(cat "$DOC")" "Guarded the tenant switch."

hb "$R" import --result "$BRIEF" > /dev/null
chk "re-import does not duplicate" "1" "$(grep -c 'Guarded the tenant switch.' "$DOC")"

printf '\nimport --result refusals\n'
WRONG="$(mktemp)"
sed 's/^repo_root_commit: .*/repo_root_commit: 0000000000000000000000000000000000000000/' "$BRIEF" > "$WRONG"
chk_contains "wrong repo refused" "$(hb "$R" import --result "$WRONG")" "different repository"

BADV="$(mktemp)"
sed 's/^brief: 1$/brief: 99/' "$BRIEF" > "$BADV"
chk_contains "unknown format refused" "$(hb "$R" import --result "$BADV")" "brief format"

R2="$(mkboard)"
hb "$R2" new other-thing --title "Other" --severity low > /dev/null
hb "$R2" export other-thing > /dev/null
UNFILLED="$R2/.agents/handoff/briefs/other-thing-handoff.brief.md"
chk_contains "unfilled result refused" "$(hb "$R2" import --result "$UNFILLED")" "not filled in"

SECRET="$(mktemp)"
sed 's/Ran npm test -- tenant; 14 passing./token AKIAIOSFODNN7EXAMPLE/' "$BRIEF" > "$SECRET"
chk_contains "secret-bearing result refused" "$(hb "$R" import --result "$SECRET")" "looks like a credential"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
```

Expected: every `import --result` check FAILs — `cmd_import` treats `--result` as its source file argument and dies on `no such file`.

- [ ] **Step 3: Route `--result` in `cmd_import`**

Replace the first two lines of `cmd_import`'s body (the `local` declarations and `src=` assignment, line 725-727) with:

```bash
# Two commands under one verb, with INVERTED preconditions: plain `import` refuses an id that is
# already on the board, `--result` refuses one that is not. Routed here rather than as its own
# subcommand to keep the export/import pair symmetric for the caller.
if [ "${1:-}" = "--result" ]; then
  shift
  import_result "$@"
  return
fi
local src="" id="" title="" type="standalone" severity="" note="" group="${HANDOFF_GROUP:-}"
src="${1:?usage: handoff import <file> [--id ID] ... | handoff import --result <file> [--force-repo]}"
shift
```

- [ ] **Step 4: Implement `import_result`**

Immediately before `cmd_import`:

```bash
# Read a returned brief back onto the board. Everything in the file was written OUTSIDE this repo's
# tooling, so the refusals below are the substance of this command, not defensive padding.
#
# The one thing it never does is write `status`. The executor's claim lands in `result_claimed`,
# beside a `status` it did not change: `done` stays a reviewer action backed by evidence the
# reviewer reproduced. That is the whole protocol, preserved across a trust boundary.
import_result() {
  local src="" force_repo=0
  src="${1:?usage: handoff import --result <file> [--force-repo]}"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --force-repo)
        force_repo=1
        shift
        ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [ -f "$src" ] || die "no such file: $src"

  local ver
  ver="$(meta "$src" brief)"
  [ "$ver" = "1" ] || die "unknown brief format '$ver' — this CLI reads brief format 1. Update the board (re-run setup-handoff) or the brief."

  # Repo guard FIRST. A brief names file:line locations that may exist in another repo and mean
  # something else there; landing its result on a same-named handoff would be silent corruption.
  local want_root have_root
  want_root="$(meta "$src" repo_root_commit)"
  have_root="$(repo_root_commit)"
  if [ "$want_root" = "unverified" ]; then
    [ "$force_repo" -eq 1 ] \
      || die "this brief was rendered without a verified repo identity — confirm it targets $(basename "${REPO_DIR:-.}") by hand, then re-run with --force-repo"
    echo "⚠️  Importing a brief with an unverified repo identity because --force-repo was given."
  elif [ "$want_root" != "$have_root" ]; then
    die "this brief targets a different repository ($(meta "$src" repo_name) at $(meta "$src" repo_origin)) — refusing to import it here"
  fi

  local id f
  id="$(resolve_id "$(meta "$src" handoff)")" || die "brief names an unusable handoff id"
  if is_archived "$id"; then
    die "$id is already archived at $(arch_file "$id") — reopen it before importing a result"
  fi
  f="$(doc_of "$id")" || no_such "$id"

  local claimed
  claimed="$(meta "$src" result_status)"
  case "$claimed" in
    done | partial | blocked) ;;
    "") die "the brief's result_status is empty — it was not filled in" ;;
    *) die "bad result_status '$claimed' (expected done, partial, or blocked)" ;;
  esac

  local body
  body="$(awk '
    /<!-- handoff:result:begin -->/ { inside = 1; next }
    /<!-- handoff:result:end -->/   { inside = 0 }
    inside { print }
  ' "$src")"
  # A block that still carries only headings and the template comments is not a result.
  local substance
  substance="$(printf '%s\n' "$body" | grep -v '^###' | grep -v '^[[:space:]]*<!--' | tr -d '[:space:]')"
  [ -n "$substance" ] || die "the brief's Result block was not filled in"

  # The returned text is untrusted and about to enter git history permanently.
  if printf '%s\n' "$body" | grep -Eqi '(AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[baprs]-[A-Za-z0-9-]{10,})'; then
    die "the Result block looks like a credential was pasted into it — redact the brief and re-run. Nothing was written."
  fi

  if [ "$claimed" = "done" ] \
    && [ -z "$(printf '%s\n' "$body" | awk '/^### Commits and PR/{c=1;next} /^###/{c=0} c' | tr -d '[:space:]')" ]; then
    echo "⚠️  The brief claims done but names no commit or PR. Treat the evidence with extra suspicion."
  fi

  local src_commit head_commit
  src_commit="$(meta "$src" source_commit)"
  head_commit="$(git -C "${REPO_DIR:-.}" rev-parse --short HEAD 2> /dev/null || echo "")"
  if [ -n "$src_commit" ] && [ -n "$head_commit" ] && [ "$src_commit" != "$head_commit" ]; then
    echo "⚠️  Brief was rendered at $src_commit; HEAD is $head_commit. The Where anchors may have moved."
  fi

  splice_result "$f" "$body"
  set_field "$f" result_from "$(fold_colons "$(meta "$src" result_by)")"
  set_field "$f" result_at "$(meta "$src" result_at)"
  set_field "$f" result_claimed "$claimed"
  set_field "$f" review pending
  log_activity "$f" "result reported by $(meta "$src" result_by) claiming $claimed — awaiting review"

  echo "Imported the reported result into $f."
  echo "Board status is UNCHANGED — the report is a claim, not a verdict."
  echo "Review the PR, reproduce the evidence, then close it yourself:"
  echo "  handoff release $id --status done --verified-by \"<how YOU verified live code>\""
  cmd_index
}

# Replace (or append) the doc's reported-result block. Bounded by the same marker pair the brief
# uses, which is what makes a re-import replace rather than stack up a second copy.
splice_result() { # doc-path body
  local f="$1" body="$2" t
  t="$(mktemp)" || die "mktemp failed"
  if grep -q '<!-- handoff:result:begin -->' "$f"; then
    awk -v b="$body" '
      /<!-- handoff:result:begin -->/ { print; print ""; print b; skip = 1; next }
      /<!-- handoff:result:end -->/   { skip = 0 }
      !skip { print }
    ' "$f" > "$t" && cat "$t" > "$f"
  else
    {
      cat "$f"
      printf '\n## Result (reported)\n\n'
      printf '<!-- Reported by an external executor and spliced in by `handoff import --result`.\n'
      printf '     It is a CLAIM about live code, not a verified board status. -->\n\n'
      printf '<!-- handoff:result:begin -->\n\n%s\n\n<!-- handoff:result:end -->\n' "$body"
    } > "$t" && cat "$t" > "$f"
  fi
  rm -f "$t"
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
```

Expected: all import checks PASS, including all five refusals.

- [ ] **Step 6: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/payload/handoff \
  skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
git commit -m "feat(feature): read a returned brief back onto the board without trusting its status"
```

---

## Task 5: `list` markers and `release` interactions

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/payload/handoff` (`cmd_list` line 817, `cmd_release` line 953)
- Modify: `skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh`

**Interfaces:**

- Consumes: `meta`, `set_field`
- Produces: no new functions; `list` output gains delegation and review markers, `release` clears `review` and warns on copied evidence

- [ ] **Step 1: Write the failing test**

```bash
printf '\nlist and release\n'
chk_contains "list shows the delegate" "$(hb "$R" list)" "Alice"
chk_contains "list shows review pending" "$(hb "$R" list)" "review"

OUT="$(hb "$R" release rbac-gap --status done --verified-by "Ran npm test -- tenant; 14 passing.")"
chk_contains "warns on copied evidence" "$OUT" "identical to the reported evidence"
```

- [ ] **Step 2: Run it to verify it fails**

Expected: three FAILs — `list` has no markers and `release` emits no warning.

- [ ] **Step 3: Add the `list` markers**

In `cmd_list`, where each row's trailing annotations are assembled, append before the row is printed:

```bash
# Delegation and review markers. A delegated row is NOT free even though its lease may look
# ordinary, and a review-pending row is waiting on the reader rather than on the executor —
# both are things a board reader acts on differently.
local deleg review_flag extra=""
deleg="$(meta "$f" delegated_to)"
review_flag="$(meta "$f" review)"
[ -n "$deleg" ] && [ "$(meta "$f" review)" != "done" ] && extra="$extra  → $deleg"
[ "$review_flag" = "pending" ] && extra="$extra  ⇤ review"
```

then include `$extra` in the printed row. Match the surrounding `printf` style exactly — read the existing row assembly before editing rather than guessing its field order.

- [ ] **Step 4: Add the `release` behavior**

In `cmd_release`, after `--verified-by` is parsed and before the status is written:

```bash
# Closing `done` with the executor's own evidence string is trusting the report with extra steps.
# A warning, never a refusal: the reviewer may legitimately have re-run the very same command.
if [ "$status" = "done" ] && [ -n "$verified_by" ] && [ "$(meta "$f" review)" = "pending" ]; then
  if grep -Fq -- "$verified_by" "$f" 2> /dev/null; then
    echo "⚠️  Your --verified-by is identical to the reported evidence already in the doc."
    echo "    'done' means YOU verified against live code. If you re-ran it yourself, say so."
  fi
fi
```

and in `finish_release`, before `cmd_index`:

```bash
# A closed handoff is no longer awaiting review; leaving the flag set would make a reopened doc
# read as pending against a review that already happened.
[ -n "${1:-}" ] && [ -f "$(doc_of "$1" 2> /dev/null || echo /dev/null)" ] \
  && set_field "$(doc_of "$1")" review done
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
```

Expected: all checks PASS.

- [ ] **Step 6: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/payload/handoff \
  skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
git commit -m "feat(feature): surface delegated and review-pending handoffs in list and release"
```

---

## Task 6: Installer, version bump, verifier, propagation

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/setup-handoff.sh` (lines 216-223, 315-319, 355-362)
- Modify: `skills/engineering/setup-handoff/scripts/payload.version`
- Modify: `skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh`
- Modify: `.agents/handoff/handoff` and 8 harness fixture copies (by re-running the installer, never by hand)

- [ ] **Step 1: Install the brief template and create `briefs/`**

At each of the three template-install sites (lines 216-223, 315-319, 355-362), add the brief template alongside the existing three. At lines 216 and 355, add `briefs` to the `mkdir -p` list:

```bash
mkdir -p "$HDEST/archive" "$HDEST/scripts" "$HDEST/templates" "$HDEST/briefs"
```

and after the orchestrator template line:

```bash
install_file "$ASSETS/handoff-brief-template.md" "$HDEST/templates/handoff-brief-template.md"
```

At the flat-layout migration site (line 315-319), add:

```bash
migrate_file "$HDEST/handoff-brief-template.md" "$HDEST/templates/handoff-brief-template.md"
```

- [ ] **Step 2: Bump the payload version**

```bash
printf 'setup-handoff 3\n' > skills/engineering/setup-handoff/scripts/payload.version
```

- [ ] **Step 3: Add verifier checks**

In `verify-setup-handoff.sh`, alongside the existing template checks, add checks that `templates/handoff-brief-template.md` exists in the installed board and that the installed `handoff` responds to `export`. Follow the file's existing `[PASS]`/`[FAIL]` output contract exactly — the harness graders parse it.

- [ ] **Step 4: Refresh the nine installed copies**

Re-run the installer into each. **Do not `cp` the payload** — the installer is what keeps `.version` and the wiring consistent.

```bash
bash skills/engineering/setup-handoff/scripts/setup-handoff.sh --board-only
for d in harness/repair-handoff-workspace/fixtures/healthy \
  harness/repair-handoff-workspace/fixtures/missing-index \
  harness/repair-handoff-workspace/fixtures/orphaned-lease \
  harness/repair-handoff-workspace/fixtures/stale-stamp \
  harness/run-handoff-workspace/fixtures/board-wired \
  harness/setup-handoff-workspace/fixtures/advisory-wired \
  harness/setup-handoff-workspace/fixtures/claude-wired \
  harness/setup-handoff-workspace/fixtures/legacy-config; do
  bash skills/engineering/setup-handoff/scripts/setup-handoff.sh --board-only --handoff-dir "$d/.agents/handoff"
done
```

**Do not touch `harness/setup-handoff-workspace/fixtures/legacy-install/.claude/handoff/handoff`.** It is a deliberately stale 217-byte pre-migration stub; refreshing it destroys the condition the migration case tests.

- [ ] **Step 5: Verify nothing drifted**

```bash
# The eight refreshed fixtures plus the live board must all match the payload byte for byte.
find . -name handoff -type f -not -path "./.git/*" -not -path "*legacy-install*" -exec md5sum {} \; | awk '{print $1}' | sort -u | wc -l
```

Expected: `1`.

- [ ] **Step 6: Run every affected verifier and self-test**

```bash
bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
bash skills/engineering/setup-handoff/scripts/payload/config.selftest.sh
bash skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh
```

Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "setup(setup): install the brief template and bump the handoff payload to 3"
```

---

## Task 7: The `delegate-handoff` skill and documentation

**Files:**

- Create: `skills/engineering/delegate-handoff/SKILL.md`
- Modify: `skills/engineering/setup-handoff/assets/agents-handoff.md`, `skills/engineering/setup-handoff/scripts/payload/README.md`, `skills/engineering/repair-handoff/SKILL.md`, `AGENTS.md`, `skills/README.md`

- [ ] **Step 1: Write the skill**

Create `skills/engineering/delegate-handoff/SKILL.md`. Frontmatter — remember **no `:` in any value**:

```markdown
---
name: x442-delegate-handoff
description: >-
  Use when handing a handoff to someone outside the board — a contractor, a junior dev, another
  team, or any AI tool without the protocol installed. Renders a self-contained execution brief
  carrying the rules the hooks and skills would otherwise enforce, then reads their reported result
  back without letting it close anything. Chains after run-handoff.
---
```

Body sections, in this order:

1. **When to delegate, and when not.** Delegate a unit whose Where you read rather than guessed. Do not delegate to defer specifying it — a brief made from a vague handoff produces a stranger guessing further, at more expense.
2. **The brief-ability check**, as a checklist: Context links symptom to root cause; Where names `file:line` you opened; Verify is runnable by someone who was not in the conversation; Decisions are settled and written down.
3. **Exporting**, with the command and what each flag does.
4. **What to send**, including that the brief must be committed so the executor can pull it.
5. **Reviewing the return** — read the PR diff first, the Result second, deliberately in that order so the report does not frame the code. Reproduce the evidence yourself.
6. **Importing and closing.**
7. **Anti-patterns**: closing `done` on the executor's evidence string; delegating a bundle with an empty Sequencing section; re-exporting after a scope change instead of amending and re-sending; exporting a handoff that was never specified well enough to delegate.

- [ ] **Step 2: Add the drift check to `repair-handoff`**

In `skills/engineering/repair-handoff/SKILL.md`, add an orphaned-delegation check to its existing check list: a doc with `delegated_at` older than the lease TTL, no `result_at`, and either a missing `brief` file or no lease, is a delegation that never came back. The repair is to contact the executor or release the lease and re-file.

- [ ] **Step 3: Document the loop in the AGENTS block and the board README**

Add a short delegation subsection to `assets/agents-handoff.md` (inside the managed markers) and a fuller protocol section to `scripts/payload/README.md`. Both must state the load-bearing rule plainly: **import never sets status; `done` remains a reviewer action.**

- [ ] **Step 4: Add the catalog rows**

Add a `delegate-handoff` row to the Skill Index table in `AGENTS.md` and to `skills/README.md`, status `experimental`, ships `markdown only`, chaining after `run-handoff`.

- [ ] **Step 5: Verify the house rules**

```bash
npx prettier --write "skills/engineering/delegate-handoff/SKILL.md" AGENTS.md skills/README.md
bash scripts/verify-standalone.sh
grep -n ':' skills/engineering/delegate-handoff/SKILL.md | sed -n '1,12p'
```

Expected: prettier clean; standalone check passes for the staged files; no `:` inside any frontmatter _value_ (the `name:`/`description:` key separators are fine).

- [ ] **Step 6: Commit**

```bash
git add skills/engineering/delegate-handoff AGENTS.md skills/README.md \
  skills/engineering/setup-handoff/assets/agents-handoff.md \
  skills/engineering/setup-handoff/scripts/payload/README.md \
  skills/engineering/repair-handoff/SKILL.md
git commit -m "docs(docs): add the delegate-handoff skill and document the delegation loop"
```

---

## Task 8: Harness workspace

**Files:**

- Create: `harness/delegate-handoff-workspace/{evals/evals.json,grade.py,fixtures/}`

- [ ] **Step 1: Build the fixtures**

Four boards under `harness/delegate-handoff-workspace/fixtures/`, each a self-contained repo per the `isolated_git_target` contract in [docs/harness-structure.md](../../harness-structure.md):

| Fixture            | State                                                              |
| ------------------ | ------------------------------------------------------------------ |
| `exportable`       | One open coordination handoff with a complete Context/Where/Verify |
| `bundle`           | An orchestrator with three children                                |
| `returned-clean`   | A board plus a correctly filled brief                              |
| `returned-hostile` | Three briefs — unfilled, wrong-repo, and secret-bearing            |

- [ ] **Step 2: Write the grader**

`grade.py`, modeled on `harness/run-handoff-workspace/grade.py`. It must wrap the target with `isolated_git_target` and score:

- a brief was produced with a matching `repo_root_commit`
- the doc carries `delegated_to` and holds a lease
- after importing the clean return, `status` is **still** `open` and `review` is `pending`
- each hostile brief is refused, and the doc is byte-identical afterwards

That last assertion is the important one: a refusal that still mutated the doc is a failed refusal.

- [ ] **Step 3: Write the eval cases**

`evals/evals.json`, following the existing schema. Include the pre-state (unwired board scores 0.00) so the A/B delta is meaningful.

- [ ] **Step 4: Run the grader against the fixtures**

```bash
python3 harness/delegate-handoff-workspace/grade.py
```

Expected: post-state fixtures score 1.00, pre-state scores 0.00.

- [ ] **Step 5: Commit**

```bash
git add harness/delegate-handoff-workspace
git commit -m "test(test): add the delegate-handoff eval workspace"
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: brief location and format (2), executor contract (2), repo identity and both enforcement points (1, 3, 4), cross-repo degradation (3, via `brief_identity`), export incl. orchestrator fan-out (3), the full import refusal table (4), board state fields (3, 4), `list`/`release` (5), the skill (7), testing (1-5, 8), propagation (6), build order (task order). The `--out` flag is implemented in 3 but not separately tested; acceptable, it shares `export_one`'s path handling.

**Placeholder scan.** No TBD or "handle edge cases". Two steps intentionally say _read the surrounding code before editing_ rather than quoting a line to replace — Task 5 Step 3 (`cmd_list`'s row assembly) and Task 7 Step 2 (`repair-handoff`'s check list) — because both edit a formatted region whose exact current shape must be matched, and a quoted snippet would go stale.

**Type consistency.** `repo_origin_norm`, `repo_root_commit`, `briefs_dir`, `require_value`, `doc_section`, `brief_identity`, `brief_dependencies`, `export_one`, `export_bundle`, `import_result`, `splice_result` are each defined once and called with the arity declared in their Interfaces block. The brief's `result_status`/`result_by` map to the doc's `result_claimed`/`result_from` exactly once, in `import_result` Step 4, matching the spec.

**Known gap carried forward.** The three open choices in the spec (`import --result` vs `handoff result`, `--branch` default, unreachable-target degradation) are implemented as the spec's recommended option. Reversing any of them touches only Task 3 or Task 4.
