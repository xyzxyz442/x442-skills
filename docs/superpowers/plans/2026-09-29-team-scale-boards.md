# Team-scale boards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one dedicated board work for a team of dozens: `depends_on` crosses groups as
`group/id`, `--local-board` warns before it takes a checkout off the team board, and the verifier
catches a `handle` that is not the tracker login.

**Architecture:** Four small, independent changes to the `setup-handoff` payload and installer.
The CLI gains four helpers (`dep_read`, `dep_norm`, `dep_csv`, `dep_path`) that every `depends_on`
reader and writer goes through; `move_dependents_of` walks every section; the installer and verifier
each gain one advisory message. One payload bump (66 → 67) and the docs close it out.

**Tech Stack:** bash (must run under macOS `/bin/bash` 3.2 — CI does), python3 one-liners for JSON,
the repo's own selftest suites (`chk`/`chk_contains`).

**Spec:** [docs/superpowers/specs/2026-09-29-team-scale-boards-design.md](../specs/2026-09-29-team-scale-boards-design.md)
— decisions in ADR 0021, 0022, 0023.

## Global Constraints

- bash 3.2 compatible: no `mapfile`/`readarray`, no `${var,,}`, no associative arrays, no `;&`.
- Never `rm`/`rm -rf` in any shipped file or command; use `trash`. Existing `rm -f "$staged"` lines
  in the CLI are pre-existing and stay as they are.
- No `:` in any frontmatter value. The separator for a qualified id is `/`, never `:`.
- Canonical qualified spelling: `group/id-handoff`; a qualified entry naming the caller's own group
  is stored bare.
- `depends_on` stays advisory (ADR 0004): `claim` warns and proceeds.
- Payload version: `setup-handoff 66` → `setup-handoff 67`. No schema bump (`SCHEMA_VERSION=4`
  stays).
- Commits: Conventional Commits per `commitlint.config.mjs`; scope from its `scope-enum`
  (`feature`, `bug`, `docs`, `test`, …). End every message with the `Co-Authored-By` trailer the
  session provides.
- No real org, team, repo or product names anywhere (standalone rule, enforced at pre-commit). Test
  and doc examples use `libs`, `api`, `acme-*`, `dev-a`.
- If a commit fails with `node: command not found`, prepend `/opt/homebrew/bin` to `PATH` and retry.
  Never `--no-verify`.

## Review Focus

1. **A hand-edited `depends_on: [Libs/Shared-DTO]`** (mixed case) — expected to read as
   `libs/shared-dto-handoff` and resolve. Pinned in Task 1 (`dep_read` case test).
2. **A bare id in another group's doc during `move`** — `api`'s bare `x` must not match `libs/x`.
   Pinned in Task 2.
3. **A board with a layout but no `groups` list** — the qualified form is refused ("this board has no
   groups"), not accepted blind. Covered by `board_is_grouped` in Task 1's flat-board test.
4. **`--local-board` pointing at the team board itself** — no warning (same board). Pinned in Task 3.
5. **`handle: "@dev-a"` with `hostAccount: dev-a`** — equal after stripping `@`; no warning. Pinned in
   Task 4.

## File map

| File                                                                   | Change                                                                                                       |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `skills/engineering/setup-handoff/scripts/payload/handoff`             | `dep_*` helpers; `depends_of`, `warn_open_dependencies`, `new --after`, `children_csv`, `move_dependents_of` |
| `skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh` | cross-group cases                                                                                            |
| `skills/engineering/setup-handoff/scripts/setup-handoff.sh`            | `--local-board` guard                                                                                        |
| `skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh`     | `handle` vs `hostAccount` warning                                                                            |
| `skills/engineering/setup-handoff/scripts/setup-handoff.selftest.sh`   | guard and verifier cases                                                                                     |
| `skills/engineering/setup-handoff/scripts/payload.version`             | 66 → 67                                                                                                      |
| harness fixture boards                                                 | re-synced by `scripts/sync-fixture-boards.sh`                                                                |
| `skills/engineering/setup-handoff/SKILL.md`                            | own-board guidance                                                                                           |
| `skills/engineering/run-handoff/SKILL.md`                              | `depends_on` paragraph                                                                                       |
| `skills/engineering/setup-handoff/scripts/payload/README.md`           | `depends_on` field row                                                                                       |
| `docs/usage/handoff.md`                                                | Situations 2 and 6, team scenario, onboarding checklist                                                      |

---

### Task 0: Branch

- [ ] **Step 1: Branch from main**

```bash
git switch -c feature/team-scale-boards
```

The ADRs 0021–0023, the `CONTEXT.md` edit, the spec and this plan are already in the working tree;
they go in Task 5's docs commit. Unrelated untracked files (`docs/usage/delegate*`) are not part of
this branch — never `git add -A`.

---

### Task 1: Qualified `depends_on` in the CLI

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/payload/handoff` — `depends_of` (~line 768),
  `children_csv` (~line 1041), `cmd_new`'s `dlist` (~line 1830), `warn_open_dependencies`
  (~line 3361)
- Test: `skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh` — new block after the
  ADR 0019 grouped-board block (after `mkshared_grouped` and its checks, ~line 1800)

**Interfaces:**

- Produces (all in `handoff`, defined together just above `depends_of`):
  - `dep_read ENTRY` → prints `id-handoff` or `group/id-handoff`; returns 1 on an unusable entry. No
    group validation.
  - `dep_norm ENTRY` → like `dep_read`, plus validation against the board's groups, and a qualified
    entry naming `$GROUP` collapses to bare. Prints the reason on stderr and returns 1 when refused.
  - `dep_csv "a, g/b"` → `"a-handoff, g/b-handoff"`; returns 1 on the first refused element.
  - `dep_path ENTRY active|archive` → the path the entry names (filed or not).
  - `dep_group_hosted GROUP` → 0 if the board's `groups` include it.
- Consumes: existing `slug`, `norm_id`, `resolve_id`, `doc_file`, `arch_file`, `each_group`,
  `board_is_grouped`, `$GROUP`.

- [ ] **Step 1: Write the failing tests**

Add to `handoff.selftest.sh`, after the ADR 0019 grouped-board checks:

```bash
printf '\ndepends_on across groups — a qualified id names the other section (ADR 0021)\n'
XG="$(mkshared)"
printf '{\n  "topology": "cross-repo",\n  "ttlHours": 4,\n  "groupLayout": "subfolder",\n  "groups": ["libs", "api"]\n}\n' > "$XG/handoff.json"
xg() { # group subcommand... -> run the board CLI acting in that section
  local g="$1"
  shift
  HANDOFF_GROUP="$g" "$XG/handoff" "$@" 2>&1
}
xg libs new shared-dto --title "Shared DTO" > /dev/null
xg api new consume-dto --title "Consume DTO" --after libs/shared-dto > /dev/null
chk "a qualified --after keeps its group" "depends_on: [libs/shared-dto-handoff]" \
  "$(grep '^depends_on:' "$XG/api/consume-dto-handoff.md")"

XG_CLAIM="$(xg api claim consume-dto "start")"
chk_contains "claim finds the prerequisite in the other group" "$XG_CLAIM" "libs/shared-dto-handoff (open)"
chk "and never calls it unfiled" "0" "$(printf '%s' "$XG_CLAIM" | grep -c 'not filed')"
xg api release consume-dto --status open "stopping" > /dev/null

xg libs claim shared-dto "land it" > /dev/null
xg libs release shared-dto --status done --verified-by "bash dto.test.sh — 4 passed, 0 failed" > /dev/null
XG_CLAIM2="$(xg api claim consume-dto "again")"
chk "a landed prerequisite in another group raises no warning" "0" \
  "$(printf '%s' "$XG_CLAIM2" | grep -c 'prerequisites')"
xg api release consume-dto --status open "stopping" > /dev/null

XG_BAD="$(xg api new bad-group --title "Bad group" --after nope/x)"
chk_contains "an unknown group is refused by name" "$XG_BAD" "names group 'nope'"
chk "and nothing is written" "no" "$([ -f "$XG/api/bad-group-handoff.md" ] && echo yes || echo no)"

xg api new own-group --title "Own group" --after api/local-thing > /dev/null
chk "a qualified entry naming its own group is stored bare" "depends_on: [local-thing-handoff]" \
  "$(grep '^depends_on:' "$XG/api/own-group-handoff.md")"

chk_contains "more than one '/' is refused" \
  "$(xg api new too-deep --title "Too deep" --after a/b/c)" "more than one '/'"

xg api new plain --title "Plain" --after own-group > /dev/null
chk "a bare --after inside one section is unchanged" "depends_on: [own-group-handoff]" \
  "$(grep '^depends_on:' "$XG/api/plain-handoff.md")"

chk "a hand-edited mixed-case entry reads canonically" "libs/shared-dto-handoff" \
  "$(cd "$XG" && HANDOFF_NO_MAIN=1 HANDOFF_GROUP=api . ./handoff && dep_read 'Libs/Shared-DTO')"

chk_contains "a bundle refuses a child in another group" \
  "$(xg api new bundle-x --title "Bundle" --orchestrator --children libs/x)" "stays within one group"

XF="$(mkshared)"
chk_contains "a flat board refuses the qualified form" \
  "$("$XF/handoff" new flat-q --title "Flat" --after libs/x 2>&1)" "this board has no groups"
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd skills/engineering/setup-handoff/scripts/payload && /bin/bash handoff.selftest.sh 2>&1 | grep -A20 'depends_on across groups'`

Expected: FAIL on "keeps its group" (got `[libs-shared-dto-handoff]`), "finds the prerequisite"
(got `not filed`), "unknown group", "more than one '/'", "mixed-case" (`dep_read` not found),
"bundle refuses", "flat board refuses". "unchanged" PASSES — it is the regression guard.

Do not change a test to make it pass. If a case fails for a reason other than the one listed (for
example `new --orchestrator` wants other flags), fix the test's invocation, re-run, and confirm it
still fails for the listed reason before implementing.

- [ ] **Step 3: Add the helpers**

Insert immediately above the `depends_of()` definition (above its comment block):

```bash
# ADR 0021 — a depends_on entry is a bare id (the caller's own section) or GROUP/ID (another section
# of this board). `/` cannot survive slug() or norm_id(), so it is an unambiguous separator; `:`
# would break unquoted frontmatter. Readers canonicalise and report; only the writer (dep_norm)
# refuses, because a reader that refused would hide a hand-edited edge instead of showing it.
dep_read() { # stored entry -> "id-handoff" | "group/id-handoff"; non-zero on an unusable entry
  local g id
  case "$1" in
    */*/*) return 1 ;;
    */*)
      g="$(slug "${1%%/*}")"
      [ -n "$g" ] || return 1
      id="$(norm_id "${1#*/}")" || return 1
      printf '%s/%s' "$g" "$id"
      ;;
    *) norm_id "$1" ;;
  esac
}
dep_group_hosted() { # group -> 0 if this board's config lists it
  local g
  while IFS= read -r g; do [ "$g" = "$1" ] && return 0; done < <(each_group)
  return 1
}
# The writer's rules: a group the board does not host is a typo, refused by name; a qualified entry
# naming the caller's own group is stored bare, so one edge has one spelling. A bare id goes through
# resolve_id exactly as before, keeping its pre-slug legacy fallback.
dep_norm() { # entry -> canonical entry; non-zero with the reason on stderr
  local e="$1" c g
  case "$e" in
    */*/*)
      echo "handoff: '$e' has more than one '/' — write GROUP/ID" >&2
      return 1
      ;;
    */*)
      c="$(dep_read "$e")" || {
        echo "handoff: '$e' needs a letter or digit on each side of the '/'" >&2
        return 1
      }
      g="${c%%/*}"
      board_is_grouped || {
        echo "handoff: '$e' names group '$g', but this board has no groups" >&2
        return 1
      }
      dep_group_hosted "$g" || {
        echo "handoff: '$e' names group '$g', which this board does not host ($(each_group | tr '\n' ' ' | sed 's/ $//'))" >&2
        return 1
      }
      [ "$g" = "$GROUP" ] && c="${c#*/}"
      printf '%s' "$c"
      ;;
    *) resolve_id "$e" ;;
  esac
}
dep_csv() { # "a, g/b" -> "a-handoff, g/b-handoff"; non-zero on the first refused element
  local raw="$1" out="" c n
  local IFS=','
  for c in $raw; do
    c="${c#"${c%%[![:space:]]*}"}" # strip leading whitespace
    c="${c%"${c##*[![:space:]]}"}" # strip trailing whitespace
    [ -n "$c" ] || continue
    n="$(dep_norm "$c")" || return 1
    out="${out:+$out, }$n"
  done
  printf '%s' "$out"
}
dep_path() { # entry active|archive -> the path that entry names, whether or not it is filed
  local id="${1#*/}" g="$GROUP"
  case "$1" in */*) g="${1%%/*}" ;; esac
  if [ "$2" = archive ]; then arch_file "$id" "$g"; else doc_file "$id" "$g"; fi
}
```

- [ ] **Step 4: Route `depends_of` through `dep_read`**

In `depends_of`, both loops contain this line:

```bash
[ -n "$one" ] && norm_id "$one" 2> /dev/null && echo
```

Replace **both** occurrences with:

```bash
[ -n "$one" ] && dep_read "$one" 2> /dev/null && echo
```

and change the function's header comment from `# path -> newline-separated child ids (canonicalized)`
to `# path -> newline-separated entries, bare or group/ (canonicalized, ADR 0021)`.

- [ ] **Step 5: Route `new --after` through `dep_csv`**

In `cmd_new`, replace:

```bash
dlist="$(children_csv "$depends")" || die "unusable id in --after: '$depends' (each needs at least one letter or digit)"
```

with:

```bash
dlist="$(dep_csv "$depends")" || die "unusable entry in --after: '$depends' (see above; a bare id is this section, GROUP/ID another)"
```

- [ ] **Step 6: Refuse `/` in `--children`**

In `children_csv`, after the two whitespace-strip lines and the `[ -n "$c" ] || continue` line,
before `c="$(resolve_id "$c")"`, insert:

```bash
case "$c" in */*)
  echo "handoff: child '$c' names another group — a bundle stays within one group (ADR 0021); link across groups with --after GROUP/ID" >&2
  return 1
  ;;
esac
```

- [ ] **Step 7: Resolve prerequisites through `dep_path`**

In `warn_open_dependencies`, replace the body of the `while` loop:

```bash
    [ -n "$dep" ] || continue
    if [ -f "$(doc_file "$dep")" ]; then
      df="$(doc_file "$dep")"
    elif [ -f "$(arch_file "$dep")" ]; then
      continue # archived means landed
    else
```

with:

```bash
    [ -n "$dep" ] || continue
    if [ -f "$(dep_path "$dep" active)" ]; then
      df="$(dep_path "$dep" active)"
    elif [ -f "$(dep_path "$dep" archive)" ]; then
      continue # archived means landed
    else
```

The rest of the loop is unchanged.

- [ ] **Step 8: Run the suite**

Run: `cd skills/engineering/setup-handoff/scripts/payload && /bin/bash handoff.selftest.sh 2>&1 | tail -3`

Expected: `--- N passed, 0 failed ---`. Every new case passes, and no existing case regressed. If a
pre-existing case fails, re-run once before investigating — an edit mid-run mixes CLI versions (the
suite freezes one payload copy per run).

- [ ] **Step 9: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/payload/handoff \
  skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
git commit -m "feat(feature): let depends_on name another group as group/id

A grouped board resolved every depends_on entry in the caller's own
section, so a consumer group could not name a library group's handoff,
and a/b was silently folded into a non-existent id (ADR 0021)."
```

---

### Task 2: `move` names dependents in every section

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/payload/handoff` — `move_dependents_of` (~line 3891)
- Test: `handoff.selftest.sh`, appended to Task 1's block (it reuses `$XG`)

**Interfaces:**

- Consumes: `depends_of` (Task 1: entries are bare or `group/…`), `each_group`, `each_doc`,
  `board_is_grouped`, `grouped`, `$GROUP`.
- Produces: `move_dependents_of ID` → comma-separated dependents; own-section ones bare, others
  `group/id-handoff`. Its one caller (the `Still on this board and depending on it` message) is
  unchanged.

- [ ] **Step 1: Write the failing tests**

Append to Task 1's block:

```bash
xg libs new x --title "Libs x" > /dev/null
xg api new x --title "Api x" > /dev/null
xg api new uses-own-x --title "Uses api x" --after x > /dev/null
chk "move names a dependent in another group" "api/consume-dto-handoff" \
  "$(cd "$XG" && HANDOFF_NO_MAIN=1 HANDOFF_GROUP=libs . ./handoff && move_dependents_of shared-dto-handoff)"
chk "a bare id in another group's doc is that group's, not the mover's" "" \
  "$(cd "$XG" && HANDOFF_NO_MAIN=1 HANDOFF_GROUP=libs . ./handoff && move_dependents_of x-handoff)"
chk "an own-section dependent is still named bare" "uses-own-x-handoff" \
  "$(cd "$XG" && HANDOFF_NO_MAIN=1 HANDOFF_GROUP=api . ./handoff && move_dependents_of x-handoff)"
```

- [ ] **Step 2: Run and watch them fail**

Run: `cd skills/engineering/setup-handoff/scripts/payload && /bin/bash handoff.selftest.sh 2>&1 | grep -E 'move names|bare id in another|own-section dependent'`

Expected: "move names a dependent in another group" FAILS (got empty — only `libs` is walked). The
other two pass today and are the regression guards.

- [ ] **Step 3: Replace `move_dependents_of`**

Replace the whole function (keep the comment above it, updating its second line) with:

```bash
# Docs left here that depended on it now point at a pointer. depends_on cannot follow it across
# boards, so name the ones to rewrite rather than leave them reading as satisfied. Every section is
# walked (ADR 0021): a bare entry means the section it sits in, a qualified one names its own.
move_dependents_of() { # id -> "a-handoff, api/b-handoff", or nothing
  local id="$1" want="$1" dependents="" sec other e label
  grouped && want="$GROUP/$id"
  while IFS= read -r sec; do
    while IFS= read -r other; do
      [ -n "$other" ] || continue
      while IFS= read -r e; do
        [ -n "$e" ] || continue
        case "$e" in */*) ;; *) [ -n "$sec" ] && e="$sec/$e" ;; esac
        [ "$e" = "$want" ] || continue
        label="$(basename "$other" .md)"
        [ -n "$sec" ] && [ "$sec" != "$GROUP" ] && label="$sec/$label"
        dependents="${dependents:+$dependents, }$label"
        break
      done <<< "$(depends_of "$other")"
    done < <(each_doc "$sec")
  done < <(if board_is_grouped; then each_group; else printf '\n'; fi)
  printf '%s' "$dependents"
}
```

On a flat board the outer loop runs once with `sec=""`, `each_doc ""` walks the flat board, and
entries compare bare against the bare id — today's behaviour.

- [ ] **Step 4: Run the suite**

Run: `cd skills/engineering/setup-handoff/scripts/payload && /bin/bash handoff.selftest.sh 2>&1 | tail -3`

Expected: `--- N passed, 0 failed ---`.

- [ ] **Step 5: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/payload/handoff \
  skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
git commit -m "feat(feature): name dependents in every group when a handoff moves

move_dependents_of walked only the mover's own section, so a consumer
group's qualified edge was left reading as satisfied by a pointer."
```

---

### Task 3: `--local-board` warns before leaving the team board

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/setup-handoff.sh` — the `--local-board` block
  (~line 826), before the `python3 -c` write
- Test: `skills/engineering/setup-handoff/scripts/setup-handoff.selftest.sh`, a new block before the
  final `printf '\n--- %d passed…'`

**Interfaces:**

- Consumes: `$REPO`, `$LOCAL_BOARD`, `$_lb_abs` (already computed in the block).
- Produces: a stderr/stdout message beginning `setup-handoff: this checkout claims on`. Exit status
  unchanged (0).

- [ ] **Step 1: Write the failing tests**

```bash
printf '\n--local-board over a committed team board warns first (ADR 0022)\n'
LB="$(mkparentrepo)"
LB_TEAM="$(mkgitboard)"
"$INSTALLER" --board-only "$LB_TEAM" > /dev/null 2>&1
LB_OWN="$(mkgitboard)"
"$INSTALLER" --board-only "$LB_OWN" > /dev/null 2>&1
mkdir -p "$LB/.agents"
printf '{\n  "board": "%s"\n}\n' "$LB_TEAM" > "$LB/.agents/handoff.json"
LB_OUT="$("$INSTALLER" "$LB" --local-board "$LB_OWN" 2>&1)"
LB_ST=$?
chk_contains "names the board the checkout stops claiming on" "$LB_OUT" "claims on $LB_TEAM today"
chk_contains "and offers the boards map instead" "$LB_OUT" '"boards"'
chk "still records the choice and exits 0" "0 yes" \
  "$LB_ST $(grep -qF "$LB_OWN" "$LB/.agents/handoff.local.json" && echo yes || echo no)"
LB_SAME="$("$INSTALLER" "$LB" --local-board "$LB_TEAM" 2>&1)"
chk "pointing at the team board itself is silent" "0" "$(printf '%s' "$LB_SAME" | grep -c 'claims on')"
LB2="$(mkparentrepo)"
LB2_OUT="$("$INSTALLER" "$LB2" --local-board "$LB_OWN" 2>&1)"
chk "no team board, no warning" "0" "$(printf '%s' "$LB2_OUT" | grep -c 'claims on')"
```

If `--board-only` on an `mkgitboard` path without a remote exits non-zero here, check how the
existing `--board-only` cases in this file prepare their board and copy that preparation. Confirm
`[ -f "$LB_TEAM/scripts/config.sh" ] || [ -f "$LB_TEAM/config.sh" ]` holds before trusting the
cases.

- [ ] **Step 2: Run and watch them fail**

Run: `cd skills/engineering/setup-handoff/scripts && /bin/bash setup-handoff.selftest.sh 2>&1 | grep -A6 'local-board over a committed'`

Expected: "names the board" and "offers the boards map" FAIL; the other three pass (guards).

- [ ] **Step 3: Add the guard**

In `setup-handoff.sh`, inside `if [ -n "$LOCAL_BOARD" ]; then`, directly after the
`[ -f "$_lb_abs/scripts/config.sh" ] || … || die …` check and before `python3 -c 'import json, os, sys`,
insert:

```bash
# ADR 0022 — handoff.local.json's board outranks the committed one, so recording a developer's own
# board here moves every claim in this checkout onto it, where the team does not look. Say so
# before writing. A warning, not a refusal: taking one checkout off the team board can be meant.
_team=""
if [ -f "$REPO/.agents/handoff.json" ]; then
  _team="$(python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
v = (d.get("board") or d.get("boardPath") or "") if isinstance(d, dict) else ""
sys.stdout.write(v if isinstance(v, str) else "")' "$REPO/.agents/handoff.json")"
fi
[ -z "$_team" ] && [ -d "$REPO/.agents/handoff" ] && _team=".agents/handoff"
if [ -n "$_team" ]; then
  case "$_team" in /*) _team_abs="$_team" ;; *) _team_abs="$REPO/$_team" ;; esac
  _team_abs="$(cd "$_team_abs" 2> /dev/null && pwd || printf '%s' "$_team_abs")"
  _lb_real="$(cd "$_lb_abs" && pwd)"
  if [ "$_team_abs" != "$_lb_real" ]; then
    _lb_remote="$(git -C "$_lb_abs" remote get-url origin 2> /dev/null || true)"
    echo "setup-handoff: this checkout claims on $_team_abs today. Recording $LOCAL_BOARD as its board"
    echo "  moves every claim, list and hook here onto it, where the rest of the team does not look."
    echo "  To keep claiming on the team board and still reach it, record it in the boards map instead —"
    echo "  in .agents/handoff.local.json, \"boards\": { \"${_lb_remote:-<its remote>}\": \"$_lb_abs\" } (ADR 0022)."
  fi
fi
```

- [ ] **Step 4: Run the suite**

Run: `cd skills/engineering/setup-handoff/scripts && /bin/bash setup-handoff.selftest.sh 2>&1 | tail -3`

Expected: `--- N passed, 0 failed ---`.

- [ ] **Step 5: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/setup-handoff.sh \
  skills/engineering/setup-handoff/scripts/setup-handoff.selftest.sh
git commit -m "feat(feature): warn before --local-board takes a checkout off the team board

handoff.local.json outranks the committed board, so recording a draft
board moved every claim onto a board nobody else reads (ADR 0022)."
```

---

### Task 4: Verifier warns when `handle` is not the host account

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh` — the ADR 0018
  per-developer python block (~line 406)
- Test: `setup-handoff.selftest.sh`, a new block after Task 3's

**Interfaces:**

- Produces: warning id `repo.local_config.handle_not_host_account`, message containing
  `differs from hostAccount`.

- [ ] **Step 1: Write the failing tests**

```bash
printf '\nhandle versus hostAccount (ADR 0023)\n'
HV="$(mkparentrepo)"
"$INSTALLER" "$HV" --tools claude --primary none > /dev/null 2>&1
printf '{\n  "handle": "dev-b",\n  "hostAccount": "dev-a"\n}\n' > "$HV/.agents/handoff.local.json"
chk_contains "a handle that is not the host account warns" \
  "$(bash "$HERE/verify-setup-handoff.sh" "$HV" 2>&1)" "differs from hostAccount"
printf '{\n  "handle": "@dev-a",\n  "hostAccount": "dev-a"\n}\n' > "$HV/.agents/handoff.local.json"
chk "equal after the @ is stripped is silent" "0" \
  "$(bash "$HERE/verify-setup-handoff.sh" "$HV" 2>&1 | grep -c 'differs from hostAccount')"
printf '{\n  "handle": "dev-b"\n}\n' > "$HV/.agents/handoff.local.json"
chk "no hostAccount is silent" "0" \
  "$(bash "$HERE/verify-setup-handoff.sh" "$HV" 2>&1 | grep -c 'differs from hostAccount')"
```

- [ ] **Step 2: Run and watch them fail**

Run: `cd skills/engineering/setup-handoff/scripts && /bin/bash setup-handoff.selftest.sh 2>&1 | grep -A4 'handle versus hostAccount'`

Expected: the first case FAILS; the two silent cases pass.

- [ ] **Step 3: Add the check**

In the python program of the ADR 0018 block, after the `hostAccount` shape check and before
`b = d.get("boards")`, insert:

```python
hd = d.get("handle")
if isinstance(h, str) and h and isinstance(hd, str) and hd and hd.lstrip("@") != h:
    print("repo.local_config.handle_not_host_account|handle %s differs from hostAccount %s — assignments naming you target the handle, and the two are usually the same login (ADR 0023)" % (hd, h))
```

and extend the block's leading comment with one line: `# A handle that is not the host account's
login makes reviewer assignment fail silently (ADR 0023).`

- [ ] **Step 4: Run the suite**

Run: `cd skills/engineering/setup-handoff/scripts && /bin/bash setup-handoff.selftest.sh 2>&1 | tail -3`

Expected: `--- N passed, 0 failed ---`.

- [ ] **Step 5: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh \
  skills/engineering/setup-handoff/scripts/setup-handoff.selftest.sh
git commit -m "feat(feature): warn when a developer's handle is not their host account

The reviewer assignment is non-fatal by design, so a handle that is not
the tracker login notified nobody and said nothing (ADR 0023)."
```

---

### Task 5: Payload bump, fixtures, and documentation

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/payload.version`
- Modify: harness fixture boards (via the sync script)
- Modify: `skills/engineering/setup-handoff/scripts/payload/README.md:350`,
  `skills/engineering/run-handoff/SKILL.md:226-228`, `skills/engineering/setup-handoff/SKILL.md:206-222`,
  `docs/usage/handoff.md`
- Add (already written): `docs/adr/0021-*.md`, `docs/adr/0022-*.md`, `docs/adr/0023-*.md`,
  `CONTEXT.md` edit, the spec, this plan

- [ ] **Step 1: Bump the payload**

Set `skills/engineering/setup-handoff/scripts/payload.version` to exactly:

```text
setup-handoff 67
```

- [ ] **Step 2: Re-sync the fixture boards and check**

```bash
bash scripts/sync-fixture-boards.sh
bash scripts/sync-fixture-boards.sh --check
bash scripts/verify-payload-version.sh
```

Expected: the check exits 0; the payload-version gate passes.

- [ ] **Step 3: Payload README field row**

In `payload/README.md` line 350, replace `**Board ids only**, as a list.` with
`**Board ids only**, as a list — `group/id` for a handoff in another group of the same board (ADR 0021).`
and replace `Set it with `new --after <id>`.` with
`Set it with `new --after <id>`or`--after <group>/<id>`.`

- [ ] **Step 4: run-handoff paragraph**

In `run-handoff/SKILL.md`, after the sentence ending `means _this cannot start before that lands_.`
(line 227), insert:

```markdown
On a board with groups, a bare id means your own group; name a handoff in another group as
`group/id` — `--after libs/shared-dto`. A group the board does not host is refused, and a bundle's
children stay in one group ([ADR 0021](../../../docs/adr/0021-a-dependency-across-groups-names-its-group.md)).
```

- [ ] **Step 5: setup-handoff own-board guidance**

In `setup-handoff/SKILL.md`, in "A developer's own board is a choice, not a role", after the
three-item list, insert:

```markdown
Whichever layout, the path must not be one detection finds first — not `.agents/handoff` (or the
other detected spellings) in the repo or its two parents — or setup proposes it in place of the team
board ([ADR 0022](../../../docs/adr/0022-the-team-board-is-the-one-setup-finds-and-a-developers-own-board-is-reached-by-name.md)).
`.agents/handoff-<handle>` beside the team board is safe.

**When the checkout belongs to a team board, record the own board in the `boards` map, not with
`--local-board`.** `--local-board` makes it this checkout's board, and every claim then lands where
the team does not look; setup warns before it does that. Reach the own board through its own CLI
and promote a draft with `handoff move --to`.
```

and change the sentence `Create it with `--board-only <path>` if it does not exist, then record it
for this checkout only:` to `Create it with `--board-only <path>` if it does not exist. When it is
the only board this checkout uses, record it for this checkout:`.

- [ ] **Step 6: Usage guide**

In `docs/usage/handoff.md`:

1. Situation 2, after the paragraph ending `with their own `--verified-by`.`, add:

```markdown
**Telling the junior it is theirs.** The board names one person, the reviewer. File with
`--reviewer` naming yourself, then add the junior as an assignee on the mirrored issue — the mirror
never reconciles assignees, so that stays. The junior claims on the board when they start; until
then the issue is what says the work is expected of them
([ADR 0023](../adr/0023-who-does-the-work-is-told-through-the-tracker-and-the-board-names-only-the-reviewer.md)).
```

2. Situation 6, after the `--after` bullet, add:

```markdown
- **Across groups on one board, qualify the id**: `handoff new consume-dto --after libs/shared-dto`.
  A bare id always means your own group — ids repeat across groups, so nothing guesses — and a group
  the board does not host is refused
  ([ADR 0021](../adr/0021-a-dependency-across-groups-names-its-group.md)).
```

3. "A team, several groups, and a library owned elsewhere": replace the sentence beginning
   `Alice sketches ideas on her own personal board, declared as this board's child,` with:

```markdown
Alice sketches ideas on her own board, declared as this board's child and cloned at
`workspace/.agents/handoff-alice` — beside the team board's clone at `workspace/.agents/handoff`,
which is the one every repo under `workspace/src/` finds. She records it in the `boards` map of her
`handoff.local.json`, not with `--local-board`, so her checkouts keep claiming on the team board, and
moves one across — naming the target — when the team should see it
([ADR 0022](../adr/0022-the-team-board-is-the-one-setup-finds-and-a-developers-own-board-is-reached-by-name.md)).
When the app needs a change in a platform library first, Bob files it with
`--after platform/<id>`, and his claim reports whether it has landed.
```

4. At the end of that section (after `groups as the team needs.`), add:

```markdown
**Bringing a team onto a board.** Before the first members join:

- Each member's `handle` is exactly their tracker login; mirror one test handoff naming each of them
  as reviewer and confirm each was assigned. The verifier warns when `handle` and `hostAccount`
  differ.
- Start with two groups that depend on each other and a few people, including a senior and a junior.
- Watch three things in the first weeks: claims that exhaust the three push retries (the signal to
  give a busy group its own board), `TRACKER-DRIFT.md` growing, and implementers asking what to do
  anywhere other than the handoff and its issue (the evidence ADR 0023 waits for).
```

- [ ] **Step 7: Format and lint the docs**

```bash
./node_modules/.bin/prettier --write docs/usage/handoff.md docs/adr/0021-*.md docs/adr/0022-*.md \
  docs/adr/0023-*.md docs/superpowers/specs/2026-09-29-team-scale-boards-design.md \
  docs/superpowers/plans/2026-09-29-team-scale-boards.md CONTEXT.md \
  skills/engineering/run-handoff/SKILL.md skills/engineering/setup-handoff/SKILL.md \
  skills/engineering/setup-handoff/scripts/payload/README.md
bash scripts/verify-standalone.sh
```

Expected: prettier rewrites at most table padding; `verify-standalone.sh` passes.

- [ ] **Step 8: Run both suites once more**

```bash
(cd skills/engineering/setup-handoff/scripts/payload && /bin/bash handoff.selftest.sh 2>&1 | tail -1)
(cd skills/engineering/setup-handoff/scripts && /bin/bash setup-handoff.selftest.sh 2>&1 | tail -1)
```

Expected: both `--- N passed, 0 failed ---`.

- [ ] **Step 9: Commit**

Stage by name — never `git add -A` (unrelated untracked files are in the tree):

```bash
git add skills/engineering/setup-handoff/scripts/payload.version harness/ \
  skills/engineering/setup-handoff/scripts/payload/README.md \
  skills/engineering/run-handoff/SKILL.md skills/engineering/setup-handoff/SKILL.md \
  docs/usage/handoff.md docs/adr/0021-*.md docs/adr/0022-*.md docs/adr/0023-*.md CONTEXT.md \
  docs/superpowers/specs/2026-09-29-team-scale-boards-design.md \
  docs/superpowers/plans/2026-09-29-team-scale-boards.md
git status --short # confirm nothing under docs/usage/delegate* or docs/usage/diagrams is staged
git commit -m "docs(docs): record team-scale board decisions and bump payload to 67

ADR 0021 (qualified depends_on), 0022 (team board placement, own board
by name), 0023 (implementer told through the tracker). Usage guide gains
the cross-group dependency, the own-board wiring and an onboarding list."
```
