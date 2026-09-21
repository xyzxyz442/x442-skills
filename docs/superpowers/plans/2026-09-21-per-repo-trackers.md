# Per-repository trackers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route each handoff's mirrored issue to its pinned home repository's own tracker, project a summary by default, and refuse a second board mirroring into the same tracker.

**Architecture:** The handoff CLI (`payload/handoff`, bash with embedded python) gains a tracker-resolution layer keyed by a pass-scoped global `CUR_TRACKER` (the home alias). Every existing reader of the board's single `external` block goes through `tracker_setting`, which resolves `trackers[CUR_TRACKER]` or, in legacy mode, `external`. `handoff mirror` becomes a preflight plus one pass per tracker; each pass surveys only documents whose `home` matches. Issue markers gain a derived board identity, so a foreign board's issues are detected and refused.

**Tech Stack:** bash 3.2+/5, python3 (stdlib only), git, the fake tracker adapter `harness/lib/fake-tracker.sh`.

**Spec:** `docs/superpowers/specs/2026-09-21-per-repo-trackers-design.md`

## Global Constraints

- Branch: `feature/per-repo-trackers`. Never commit to `main`.
- Commit messages: Conventional Commits, lowercase imperative subject, no trailing period. **Scope must be one of** `setup, config, deps, feature, bug, docs, style, refactor, test, build, ci, release, other` (commitlint refuses anything else). End every message with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- Never use `rm`/`rm -rf` in anything you write or run; use `trash`. Existing `rm -f` of mktemp files inside the CLI is established idiom and may be kept in code you edit.
- No emojis in skill content (`SKILL.md`, references, docs, ADRs). Runtime strings printed by the CLI may keep the existing emoji style.
- No real repository, team or organization names anywhere committed. Use `acme`, `acme-api`, `acme-web`, `acme-lib`, `zeta` (`scripts/verify-standalone.sh` enforces this at pre-commit).
- No `:` inside any frontmatter value in markdown you write; use an em dash.
- In ```bash fences inside markdown, write placeholders in UPPERCASE (`ALIAS`, not `<alias>`) — prettier-plugin-sh rewrites `<name>` into redirects.
- Do not edit `harness/**/fixtures/**` by hand; `scripts/sync-fixture-boards.sh` owns them.
- `SCHEMA_VERSION` becomes `4`. `payload.version` moves from `setup-handoff 50` to `setup-handoff 51`. The pre-commit gate `scripts/verify-payload-version.sh --staged` refuses **any** commit that touches `scripts/payload/**` or `assets/**` without `payload.version` in the same commit, so the CLI work is one commit: **Tasks 1-5 end by staging (`git add`), not committing; Task 6 bumps the stamp, syncs fixtures and commits everything staged.** Never use `--no-verify`. Tasks 7-10 touch no payload and commit normally.
- The full legacy suite `handoff.selftest.sh` takes 8-10 minutes. Run it only where a task says so (Tasks 5, 6 and 10), never in a loop. The new suite `trackers.selftest.sh` is fast; run it after every change.
- Test discipline: every new assertion is seen to FAIL against the code before the change. Never edit the code under test to make a test pass by weakening it, and never delete or weaken an existing assertion. Two edits to existing assertions are permitted, and only in Task 5: adding `"projection": "full"` to a board config whose assertions expect `Context`/`Verify` text in an issue, and updating a literal marker string to the board-id form.

## File map

| File                                                                              | Responsibility                                             | Tasks |
| --------------------------------------------------------------------------------- | ---------------------------------------------------------- | ----- |
| `skills/engineering/setup-handoff/scripts/payload/handoff`                        | the CLI: resolution, `home`, identity, routing, projection | 1-6   |
| `skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`           | **new** fast suite for everything in this plan             | 1-8   |
| `skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh`            | legacy suite; only the two permitted edits                 | 5     |
| `harness/lib/fake-tracker.sh`                                                     | per-repository visibility for tests                        | 4     |
| `skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh`                | offline checks for trackers and `home`                     | 7     |
| `skills/engineering/setup-handoff/scripts/setup-handoff.sh`                       | preserve `trackers`, notices, workflow token               | 8     |
| `skills/engineering/setup-handoff/scripts/payload.version`                        | stamp bump                                                 | 6     |
| `.github/workflows/selftests.yml`                                                 | run the new suite in CI                                    | 1     |
| `docs/adr/0017-*.md`, `docs/adr/0011-*.md`, `CONTEXT.md`, skill docs, usage guide | documentation                                              | 9     |

---

### Task 1: Tracker resolution, per-tracker `allowPublic`, and the trust check

**Files:**

- Create: `skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`
- Modify: `skills/engineering/setup-handoff/scripts/payload/handoff` (the `external_setting` block at ~3393-3406, `board_allows_public` ~3470-3476, `public_refusal` ~3478-3481, every `external_setting` call site)
- Modify: `.github/workflows/selftests.yml`

**Interfaces:**

- Produces (bash, in `payload/handoff`):
  - global `CUR_TRACKER` — the home alias the current tracker operation targets; `""` in legacy mode
  - `tracker_mode` → prints `trackers` | `legacy` | `none`
  - `tracker_entry ALIAS` → prints that home's tracker as a JSON object, or nothing
  - `tracker_setting KEY` → string value of `KEY` in `tracker_entry "$CUR_TRACKER"`, or nothing (replaces `external_setting`, same call shape)
  - `tracker_aliases` → one alias per line whose tracker `kind` is `issues` (trackers mode), or a single empty line (legacy mode), or nothing
  - `board_allows_public` → exit 0 when `$CUR_TRACKER`'s tracker sets `allowPublic: true`
  - `trackers_trust_check` → returns 0, or dies naming the owners
- Produces (test file): helpers `chk`, `chk_contains`, `mkboard [OWNER]`, `tr_cfg BOARD JSON`, `tr_fn REPO CMD...`, `trh REPO SUBCOMMAND...`, `fq PYEXPR`, and globals `SRC`, `ST`

- [ ] **Step 1: Create the new suite with its scaffolding and the Task 1 assertions**

Create `skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`:

```bash
#!/usr/bin/env bash
# Self-test for per-repository trackers (ADR 0017). Read-only outside its own temp dirs.
# Run: bash trackers.selftest.sh
#
# A separate suite from handoff.selftest.sh on purpose: that one takes eight to ten minutes, and
# everything here is exercised after every edit. The freeze below is the same one it uses, for the
# same reason — a run spanning an edit to the payload must not mix two CLI versions.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$(cd "$HERE/../../assets" && pwd)"
SRC="$(mktemp -d)"
TPL="$SRC/templates"
mkdir -p "$TPL"
cp "$HERE/handoff" "$HERE/config.sh" "$HERE/dispatcher" "$HERE/tracker-github.sh" "$HERE/hooks.sh" "$SRC/"
cp "$HERE/../../../../../harness/lib/fake-tracker.sh" "$SRC/"
cp "$ASSETS"/handoff-*-template.md "$TPL/"
chmod +x "$SRC/handoff"
# Pinned so ownership never depends on whether the terminal exposes a session id.
export HANDOFF_SESSION_ID="trackers-selftest-$$"
unset HANDOFF_REPO HANDOFF_GROUP

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
mkboard() { # [owner] -> path to a repo whose board is at .agents/handoff
  local r owner="${1:-acme}"
  r="$(mktemp -d)"
  git -C "$r" init -q
  git -C "$r" config user.email "test@example.com"
  git -C "$r" config user.name "test"
  git -C "$r" remote add origin "git@github.com:$owner/board.git"
  printf 'x\n' > "$r/README.md"
  git -C "$r" add -A
  git -C "$r" commit -qm "initial commit"
  mkdir -p "$r/.agents/handoff/scripts" "$r/.agents/handoff/templates" "$r/.agents/handoff/archive"
  cp "$SRC/handoff" "$r/.agents/handoff/handoff"
  cp "$SRC/config.sh" "$r/.agents/handoff/scripts/config.sh"
  cp "$TPL"/handoff-*-template.md "$r/.agents/handoff/templates/"
  chmod +x "$r/.agents/handoff/handoff"
  printf '%s' "$r"
}
tr_cfg() { # board-dir json -> write it as that board's handoff.json
  printf '%s\n' "$2" > "$1/handoff.json"
}
tr_fn() { # repo command... -> run it with the board's CLI sourced (functions callable directly)
  local r="$1"
  shift
  # DIR is set explicitly, as handoff.selftest.sh does when it sources the CLI.
  (cd "$r" && HANDOFF_NO_MAIN=1 . ./.agents/handoff/handoff && DIR="$PWD/.agents/handoff" && eval "$@") 2>&1
}
ST="$(mktemp -d)/tracker.json"
trh() { # repo subcommand... -> the board CLI with the fake tracker wired in
  local r="$1"
  shift
  (cd "$r" && HANDOFF_TRACKER_ADAPTER="$SRC/fake-tracker.sh" FAKE_TRACKER_STATE="$ST" \
    ./.agents/handoff/handoff "$@") 2>&1
}
fq() { # python-expression over `db` (the fake tracker state) -> printed value
  # eval() is deliberate: every expression is a literal in this file, over a state file it made.
  python3 -c 'import json,sys
try: db = json.load(open(sys.argv[1]))
except Exception: db = {"issues": [], "calls": []}
db.setdefault("issues", []); db.setdefault("calls", [])
def in_repo(repo): return [i for i in db["issues"] if i["repo"] == repo]
def by(marker): return [i for i in db["issues"] if marker in i["body"]]
def calls(op, repo=None): return len([c for c in db["calls"] if c[0] == op and (repo is None or c[1].get("repo") == repo)])
print(eval(sys.argv[2]))' "$ST" "$1"
}
# A cross-repo board registering acme-api, acme-web and acme-lib, where acme-lib has no tracker.
TRACKERS_CFG='{ "topology": "cross-repo", "schema": 4,
  "_generated": { "repos": [ { "alias": "acme-api" }, { "alias": "acme-web" }, { "alias": "acme-lib" } ] },
  "trackers": {
    "acme-api": { "kind": "issues", "system": "github", "repo": "acme/acme-api", "refPattern": "#[0-9]+" },
    "acme-web": { "kind": "issues", "system": "github", "repo": "acme/acme-web", "refPattern": "#[0-9]+", "allowPublic": true },
    "acme-plan": { "kind": "sprints", "system": "github", "repo": "acme/plan", "refPattern": "PLAN-[0-9]+" } } }'

printf '\ntracker resolution and the trust check (ADR 0017)\n'
TR="$(mkboard)"
TRB="$TR/.agents/handoff"
tr_cfg "$TRB" '{ "topology": "cross-repo", "schema": 4,
  "_generated": { "repos": [ { "alias": "acme-api" }, { "alias": "acme-web" }, { "alias": "acme-lib" } ] },
  "trackers": {
    "acme-api": { "kind": "issues", "system": "github", "repo": "acme/acme-api", "refPattern": "#[0-9]+" },
    "acme-web": { "kind": "issues", "system": "github", "repo": "acme/acme-web", "refPattern": "#[0-9]+", "allowPublic": true },
    "acme-plan": { "kind": "sprints", "system": "github", "repo": "acme/plan", "refPattern": "PLAN-[0-9]+" } },
  "external": { "kind": "issues", "system": "github", "repo": "acme/board" } }'
chk "trackers mode wins over a leftover external" "trackers" "$(tr_fn "$TR" tracker_mode)"
chk "tracker_setting reads the home's own tracker" "acme/acme-web" "$(tr_fn "$TR" 'CUR_TRACKER=acme-web; tracker_setting repo')"
chk "an alias with no tracker resolves to nothing" "" "$(tr_fn "$TR" 'CUR_TRACKER=acme-lib; tracker_setting repo')"
chk "allowPublic is per tracker — set" "0" "$(tr_fn "$TR" 'CUR_TRACKER=acme-web; board_allows_public; echo $?' | tail -1)"
chk "allowPublic is per tracker — unset" "1" "$(tr_fn "$TR" 'CUR_TRACKER=acme-api; board_allows_public; echo $?' | tail -1)"
chk "only issue trackers are mirror passes" "acme-api acme-web" "$(tr_fn "$TR" tracker_aliases | tr '\n' ' ' | sed 's/ $//')"
chk "one owner passes the trust check" "ok" "$(tr_fn "$TR" 'trackers_trust_check && echo ok' | tail -1)"

tr_cfg "$TRB" "$(printf '%s' "$TRACKERS_CFG" | sed 's#acme/acme-web#zeta/acme-web#')"
chk_contains "two owners refuse" "$(tr_fn "$TR" trackers_trust_check)" "zeta"
chk_contains "the refusal names the rule" "$(tr_fn "$TR" trackers_trust_check)" "one board per trust boundary"

TZ="$(mkboard zeta)"
tr_cfg "$TZ/.agents/handoff" "$TRACKERS_CFG"
chk_contains "trackers owned apart from the board's remote refuse" "$(tr_fn "$TZ" trackers_trust_check)" "github.com/zeta"

TL="$(mkboard)"
tr_cfg "$TL/.agents/handoff" '{ "external": { "kind": "issues", "system": "github", "repo": "acme/backlog", "refPattern": "#[0-9]+" } }'
chk "a single-repo board with external is legacy mode" "legacy" "$(tr_fn "$TL" tracker_mode)"
chk "legacy mode resolves external for the empty alias" "acme/backlog" "$(tr_fn "$TL" 'CUR_TRACKER=""; tracker_setting repo')"
chk "legacy mode has exactly one unnamed pass" "1" "$(tr_fn "$TL" tracker_aliases | wc -l | tr -d ' ')"
TX="$(mkboard)"
tr_cfg "$TX/.agents/handoff" '{ "topology": "cross-repo", "external": { "kind": "issues", "system": "github", "repo": "acme/board" } }'
chk "a cross-repo board with only external routes nowhere" "none" "$(tr_fn "$TX" tracker_mode)"

printf '\n--- %d passed, %d failed ---\n' "$P" "$F"
[ "$F" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`
Expected: FAIL — `tracker_mode: command not found` (or empty output) on the first assertions; summary shows failures, exit non-zero.

- [ ] **Step 3: Replace `external_setting` with the resolution layer**

In `payload/handoff`, replace the comment block and function that begin at `# ADR 0011 — a board attaches AT MOST ONE external tracker` and end with the closing `}` of `external_setting()` with:

```bash
# ADR 0017 — a tracker attaches per REPOSITORY. A board declares `trackers` in its own committed
# handoff.json, keyed by the repository aliases its registry lists, and a handoff's `home` picks one.
# ADR 0011's single `external` block survives as LEGACY MODE on a single-repository board, where it
# serves every document; on a cross-repository board it routes nothing (the verifier says so).
# Everything is read from the BOARD file alone — a member repo's config must not be able to swap a
# tracker for its own, and ADR 0013 requires publishing policy to live where review sees it.
#
# CUR_TRACKER is the home alias the current tracker operation targets. Every command that reaches a
# tracker sets it first: `mirror` once per pass, `new --ref` and `export`/`import` from the doc's home.
CUR_TRACKER=""

tracker_mode() { # -> trackers | legacy | none
  [ -f "$DIR/handoff.json" ] && command -v python3 > /dev/null 2>&1 || {
    printf 'none'
    return 0
  }
  python3 -c 'import json,sys
try: d = json.load(open(sys.argv[1]))
except Exception: print("none"); raise SystemExit(0)
d = d if isinstance(d, dict) else {}
if isinstance(d.get("trackers"), dict): print("trackers")
elif isinstance(d.get("external"), dict) and sys.argv[2] != "cross-repo": print("legacy")
else: print("none")' "$DIR/handoff.json" "$TOPOLOGY" 2> /dev/null || printf 'none'
}

tracker_entry() { # alias -> that home's tracker as a JSON object, or nothing
  [ -f "$DIR/handoff.json" ] && command -v python3 > /dev/null 2>&1 || return 0
  python3 -c 'import json,sys
try: d = json.load(open(sys.argv[1]))
except Exception: raise SystemExit(0)
d = d if isinstance(d, dict) else {}
t = d.get("trackers")
if isinstance(t, dict):
    e = t.get(sys.argv[2])
elif isinstance(d.get("external"), dict) and sys.argv[3] != "cross-repo":
    e = d["external"]
else:
    e = None
if isinstance(e, dict): print(json.dumps(e))' "$DIR/handoff.json" "$1" "$TOPOLOGY" 2> /dev/null
}

tracker_setting() { # key -> CUR_TRACKER's tracker's <key> as a string, or nothing
  local e
  e="$(tracker_entry "$CUR_TRACKER")"
  [ -n "$e" ] || return 0
  printf '%s' "$e" | python3 -c 'import json,sys
v = json.load(sys.stdin).get(sys.argv[1])
print(v if isinstance(v, str) else "")' "$1"
}

# The passes `mirror` makes. A sprint tool is never mirrored (ADR 0011), so its entry is no pass at
# all — in trackers mode it is simply skipped; in legacy mode the single pass is still made and
# require_tracker refuses it with the sprint-tool message, exactly as before.
tracker_aliases() { # -> one alias per line, a single empty line (legacy), or nothing
  case "$(tracker_mode)" in
    legacy) printf '\n' ;;
    trackers)
      python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for alias, e in sorted((d.get("trackers") or {}).items()):
    if isinstance(e, dict) and e.get("kind") == "issues": print(alias)' "$DIR/handoff.json" 2> /dev/null
      ;;
  esac
}

# One board per trust boundary (ADR 0011), kept when trackers multiply (ADR 0017): every tracker on
# a board shares one host and owner, and a board with a remote shares it too. A board without a
# remote takes its owner from its trackers. Checked before anything is sent.
trackers_trust_check() { # -> 0, or dies naming the owners
  [ "$(tracker_mode)" = trackers ] || return 0
  local board_key owners
  board_key="$(board_owner_key "$DIR" | tr '[:upper:]' '[:lower:]')"
  owners="$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
keys = set()
for e in (d.get("trackers") or {}).values():
    if not isinstance(e, dict) or not isinstance(e.get("repo"), str) or "/" not in e["repo"]:
        continue
    system = e.get("system") or "github"
    host = "github.com" if system == "github" else system
    keys.add(("%s/%s" % (host, e["repo"].split("/")[0])).lower())
print(" ".join(sorted(keys)))' "$DIR/handoff.json" 2> /dev/null)"
  [ -n "$owners" ] || return 0
  case "$owners" in
    *" "*) die "this board's trackers belong to more than one owner ($owners) — one board per trust boundary (ADR 0011, ADR 0017). Give each owner its own board; nothing was sent." ;;
  esac
  [ -z "$board_key" ] || [ "$board_key" = "$owners" ] \
    || die "this board's remote is $board_key but its trackers belong to $owners — one board per trust boundary (ADR 0011, ADR 0017). Mirror from a board owned by $owners; nothing was sent."
  return 0
}
```

- [ ] **Step 4: Rename every call site and rewrite `board_allows_public` / `public_refusal`**

Run: `perl -pi -e 's/\bexternal_setting\b/tracker_setting/g' skills/engineering/setup-handoff/scripts/payload/handoff`

Then replace `board_allows_public` with:

```bash
board_allows_public() { # -> 0 when CUR_TRACKER's tracker sets allowPublic: true in the board's committed handoff.json
  local e
  e="$(tracker_entry "$CUR_TRACKER")"
  [ -n "$e" ] || return 1
  printf '%s' "$e" | python3 -c 'import json,sys
raise SystemExit(0 if json.load(sys.stdin).get("allowPublic") is True else 1)'
}
```

and in `public_refusal`, change the advice text from `set external.allowPublic: true in %s` to `set allowPublic: true on this tracker (trackers.%s, or external on a single-repository board) in %s`, adding `"${CUR_TRACKER:-ALIAS}"` as the matching printf argument before `"$DIR/handoff.json"`.

- [ ] **Step 5: Run the new suite to verify it passes**

Run: `bash skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`
Expected: every line `[PASS]`, `--- N passed, 0 failed ---`, exit 0.

- [ ] **Step 6: Wire the suite into CI**

In `.github/workflows/selftests.yml`, inside the `cli` job, after the `Run handoff.selftest.sh` step, add:

```yaml
- name: Run trackers.selftest.sh
  working-directory: skills/engineering/setup-handoff/scripts/payload
  run: /bin/bash trackers.selftest.sh
```

- [ ] **Step 7: Stage (the commit happens in Task 6)**

```bash
git add skills/engineering/setup-handoff/scripts/payload/handoff \
  skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh .github/workflows/selftests.yml
```

---

### Task 2: The `home` field, schema 4, and its migration

**Files:**

- Modify: `payload/handoff` — `SCHEMA_VERSION` (~801); `cmd_new` (usage ~1484, locals ~1481, flag loop, the `ext_ref` validation ~1583, the `external_ref` write ~1804); `import_result` protected keys (~1948-1980); `cmd_move` (after the trust check ~3355); `migrate_doc_3_to_4` (new, after `migrate_doc_2_to_3` ~4978); `cmd_migrate` step loop (~5103)
- Test: `payload/trackers.selftest.sh`

**Interfaces:**

- Consumes: `CUR_TRACKER`, `tracker_setting` (Task 1)
- Produces: frontmatter key `home`; `registered_aliases` → aliases one per line; `board_registers BOARD_DIR ALIAS` → 0 when that board may hold a doc homed at `ALIAS`; `migrate_doc_3_to_4 PATH` → 0 set or not needed, 1 unresolved

- [ ] **Step 1: Write the failing tests**

Insert before the final summary `printf` in `trackers.selftest.sh`:

```bash
printf '\nhome is pinned at new, validated, and backfilled by migrate (ADR 0017)\n'
TH="$(mkboard)"
THB="$TH/.agents/handoff"
tr_cfg "$THB" "$TRACKERS_CFG"
trh "$TH" new h-flag --title "Flag" --audience acme-web --home acme-api > /dev/null
chk "--home is written" "acme-api" "$(sed -n 's/^home: //p' "$THB/h-flag-handoff.md")"
chk "a new doc is stamped schema 4" "4" "$(sed -n 's/^schema: //p' "$THB/h-flag-handoff.md")"
trh "$TH" new h-aud --title "Audience" --audience acme-web > /dev/null
chk "home defaults to the audience" "acme-web" "$(sed -n 's/^home: //p' "$THB/h-aud-handoff.md")"
(
  export HANDOFF_REPO=acme-lib
  trh "$TH" new h-env --title "Env" --audience acme-web > /dev/null
)
chk "HANDOFF_REPO outranks the audience" "acme-lib" "$(sed -n 's/^home: //p' "$THB/h-env-handoff.md")"
chk_contains "an unregistered home is refused" "$(trh "$TH" new h-bad --title "Bad" --audience acme-web --home acme-nope)" "acme-nope"
chk "nothing is written for a refused home" "no" "$([ -f "$THB/h-bad-handoff.md" ] && echo yes || echo no)"
trh "$TH" new h-std --standalone --title "Ref" > /dev/null
chk "a standalone doc has no home" "" "$(sed -n 's/^home: //p' "$THB/h-std-handoff.md")"
trh "$TH" new h-orch --orchestrator --children h-flag --title "Bundle" > /dev/null
chk "an orchestrator with no --home and no HANDOFF_REPO has none" "" "$(sed -n 's/^home: //p' "$THB/h-orch-handoff.md")"

# move re-validates home against the target board's registry.
THT="$(mkboard)"
tr_cfg "$THT/.agents/handoff" '{ "topology": "cross-repo", "schema": 4, "_generated": { "repos": [ { "alias": "acme-web" } ] } }'
trh "$TH" claim h-flag "moving" > /dev/null
chk_contains "move refuses a board that does not register the home" \
  "$(trh "$TH" move h-flag --to "$THT/.agents/handoff")" "acme-api"
trh "$TH" release h-flag --status open > /dev/null

# migrate backfills: coordination from audience, orchestrator from its children's shared home.
TM="$(mkboard)"
TMB="$TM/.agents/handoff"
tr_cfg "$TMB" "$(printf '%s' "$TRACKERS_CFG" | sed 's/"schema": 4/"schema": 3/')"
cat > "$TMB/m-one-handoff.md" << 'DOC'
---
id: m-one-handoff
title: One
type: coordination
schema: 3
status: open
audience: acme-web
---

## Current state
DOC
sed 's/m-one/m-two/; s/^title: One/title: Two/' "$TMB/m-one-handoff.md" > "$TMB/m-two-handoff.md"
cat > "$TMB/m-bun-handoff.md" << 'DOC'
---
id: m-bun-handoff
title: Bundle
type: orchestrator
schema: 3
status: open
children: [m-one-handoff, m-two-handoff]
---

## Bundle
DOC
cat > "$TMB/m-none-handoff.md" << 'DOC'
---
id: m-none-handoff
title: Nobody
type: coordination
schema: 3
status: open
---

## Current state
DOC
git -C "$TM" add -A && git -C "$TM" commit -qm "seed schema-3 docs"
MIG_OUT="$(trh "$TM" migrate --yes)"
chk "migrate backfills home from the audience" "acme-web" "$(sed -n 's/^home: //p' "$TMB/m-one-handoff.md")"
chk "migrate gives an orchestrator its children's shared home" "acme-web" "$(sed -n 's/^home: //p' "$TMB/m-bun-handoff.md")"
chk "an unresolvable doc stays without a home" "" "$(sed -n 's/^home: //p' "$TMB/m-none-handoff.md")"
chk_contains "migrate names the doc it could not resolve" "$MIG_OUT" "m-none-handoff"
chk "migrate stamps schema 4" "4" "$(sed -n 's/^schema: //p' "$TMB/m-none-handoff.md")"
```

- [ ] **Step 2: Run to verify the new assertions fail**

Run: `bash skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`
Expected: Task 1 assertions PASS; the new block FAILs (`--home` is an unknown flag, schema is 3, migrate does not backfill).

- [ ] **Step 3: Schema bump and registry helpers**

Set `SCHEMA_VERSION=4`. Add after `tracker_setting` (Task 1 block):

```bash
registered_aliases() { # -> the repository aliases this board's registry lists, one per line
  [ -f "$DIR/handoff.json" ] && command -v python3 > /dev/null 2>&1 || return 0
  python3 -c 'import json,sys
try: d = json.load(open(sys.argv[1]))
except Exception: raise SystemExit(0)
g = d.get("_generated") if isinstance(d, dict) else None
for r in (g or {}).get("repos") or []:
    if isinstance(r, dict) and r.get("alias"): print(r["alias"])' "$DIR/handoff.json" 2> /dev/null
}

# Whether a board can hold a document homed at <alias>. Only a cross-repository board names its
# repositories, so only one can refuse; a single-repository board holds whatever it is given.
board_registers() { # board-dir alias -> 0 when yes
  python3 -c 'import json,sys
try: d = json.load(open(sys.argv[1] + "/handoff.json"))
except Exception: raise SystemExit(0)
if not isinstance(d, dict) or d.get("topology") != "cross-repo": raise SystemExit(0)
repos = (d.get("_generated") or {}).get("repos") or []
raise SystemExit(0 if any(isinstance(r, dict) and r.get("alias") == sys.argv[2] for r in repos) else 1)' "$1" "$2" 2> /dev/null
}
```

- [ ] **Step 4: `new --home`**

In `cmd_new`: add `local home=""` beside the other locals; add `[--home REPO]` after `[--audience REPO]` in the usage string; add to the flag loop, beside `--audience`:

```bash
      --home)
        require_value --home "$#" "${2:-}"
        home="$2"
        shift 2
        ;;
```

Immediately **before** the line `[ -n "${ext_ref:-}" ] && { ext_ref="$(validate_external_ref "$ext_ref")" || exit 3; }`, insert:

```bash
# ADR 0017 — the repository whose tracker owns this handoff's issue. Pinned here and never changed:
# `audience` moves with whoever acts next, the issue does not. Resolved before --ref, because the
# reference is checked against THIS home's tracker.
if [ "$type" != standalone ] && [ -z "$home" ]; then
  home="${HANDOFF_REPO:-}"
  [ -z "$home" ] && [ "$type" = coordination ] && home="$audience"
fi
if [ -n "$home" ]; then
  case "$home" in *[!A-Za-z0-9._-]*) die "--home '$home' is not a repository alias (letters, digits, dot, dash, underscore)." ;; esac
  [ "$type" = standalone ] && die "a standalone doc has no home — it is never mirrored (ADR 0017)."
  board_registers "$DIR" "$home" \
    || die "--home $home is not a repository this board registers ($(registered_aliases | tr '\n' ' ' | sed 's/ $//')) — pass one of those."
fi
CUR_TRACKER="$home"
```

Next to the existing `[ -n "${ext_ref:-}" ] && set_field "$target" external_ref "$ext_ref"` line, add:

```bash
[ -n "$home" ] && set_field "$target" home "$home"
```

- [ ] **Step 5: Protect `home` in `import --result`**

In `import_result`: add `deny_before_home` to the `local` declaration, `deny_before_home="$(meta "$f" home)"` beside the other captures, `|| [ "$(meta "$f" home)" != "$deny_before_home" ] \` into the comparison chain beside the `audience` comparison, and `home/` into the refusal message's key list (`verify/status/repos/audience/home/id/children/blocked_on`).

- [ ] **Step 6: `move` re-validates `home`**

In `cmd_move`, immediately after the line `move_check_trust "$f" "$id" "$to" "$to_remote" || across=...`, insert:

```bash
# ADR 0017 — a home names a repository of THIS board's registry. The target must register it too,
# or the doc lands homed at a repository that board has never heard of and can never mirror.
local fhome
fhome="$(meta "$f" home)"
[ -z "$fhome" ] || board_registers "$to" "$fhome" \
  || die "$id is homed at $fhome, which the target board does not register — nothing moved. Register $fhome there first (register-cross-repo-handoff)."
```

- [ ] **Step 7: `migrate_doc_3_to_4` and the step loop**

After `migrate_doc_2_to_3`, add:

```bash
# ADR 0017 — backfill `home`. A coordination doc takes its audience. An orchestrator takes the home
# its children share, read from each child's home or, not yet migrated, its audience — so the order
# docs are visited in cannot change the answer. Children that disagree, or no signal at all, leave
# it unset and say so: a guessed home would publish the doc into a repository nobody chose.
migrate_doc_3_to_4() { # path -> 0 when home was set or is not needed, 1 when it could not be resolved
  local f="$1" home="" c cf h mixed=0
  if ! is_standalone "$f" && [ -z "$(meta "$f" home)" ]; then
    if is_orchestrator "$f"; then
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        cf="$(doc_of "$c" 2> /dev/null)" || continue
        h="$(meta "$cf" home)"
        [ -n "$h" ] || h="$(meta "$cf" audience)"
        [ -n "$h" ] || continue
        if [ -z "$home" ]; then home="$h"; elif [ "$home" != "$h" ]; then mixed=1; fi
      done <<< "$(children_of "$f")"
      [ "$mixed" = 0 ] || home=""
    else
      home="$(meta "$f" audience)"
    fi
    [ -n "$home" ] && set_field "$f" home "$home"
  fi
  set_field "$f" schema 4
  if ! is_standalone "$f" && [ -z "$(meta "$f" home)" ]; then
    log_activity "$f" "migrated to schema 4 — no home could be resolved; set one to mirror this handoff"
    return 1
  fi
  log_activity "$f" "migrated to schema 4${home:+ (home: $home)}"
  return 0
}
```

In `cmd_migrate`, after the `if [ "$(doc_schema "$f")" -lt 3 ]; then ... fi` block, add:

```bash
if [ "$(doc_schema "$f")" -lt 4 ]; then
  if migrate_doc_3_to_4 "$f"; then
    echo "  migrated $(basename "$f" .md) (3 → 4)"
  else
    echo "  migrated $(basename "$f" .md) (3 → 4) — no home could be resolved; it stays unmirrored until one is set"
  fi
fi
```

- [ ] **Step 8: Run to verify it passes**

Run: `bash skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`
Expected: `0 failed`, exit 0.

- [ ] **Step 9: Stage**

```bash
git add skills/engineering/setup-handoff/scripts/payload/handoff skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh
```

---

### Task 3: Board identity and tracker ownership

**Files:**

- Modify: `payload/handoff` — new `board_identity`, `mirror_claim_tracker`; `mirror_render` marker; `mirror_plan` prefix and `same`; `cmd_mirror` and `drift_live` to normalize the listing
- Test: `payload/trackers.selftest.sh`

**Interfaces:**

- Consumes: `repo_root_commit DIR` (existing)
- Produces: `board_identity` → 12 lowercase hex digits; global `BOARD_ID`; `mirror_claim_tracker EXISTING_JSON` → normalized JSON on stdout, exit 4 with foreign ids on stderr; markers `<!-- handoff:BID/[SECTION/]ID -->`; `mirror_plan EXISTING DESIRED GONE` reads `BOARD_ID` from the environment of the caller (passed as argv)

- [ ] **Step 1: Write the failing tests**

Insert before the summary:

```bash
printf '\nboard identity and one mirroring board per tracker (ADR 0017)\n'
LEG_CFG='{ "external": { "kind": "issues", "system": "github", "repo": "acme/owned", "refPattern": "#[0-9]+" } }'
TO="$(mkboard)"
tr_cfg "$TO/.agents/handoff" "$LEG_CFG"
git -C "$TO" add -A && git -C "$TO" commit -qm "board"
BID="$(tr_fn "$TO" board_identity)"
chk "a board identity is 12 hex digits" "yes" "$(printf '%s' "$BID" | grep -Eqx '[0-9a-f]{12}' && echo yes || echo no)"
TOC="$(mktemp -d)/clone"
git clone -q "$TO" "$TOC"
chk "every clone of a board shares its identity" "$BID" "$(tr_fn "$TOC" board_identity)"
trh "$TO" new o-one --title "Owned" > /dev/null
trh "$TO" mirror > /dev/null
chk "the marker carries the board identity" "1" "$(fq "len(by('<!-- handoff:$BID/o-one-handoff -->'))")"

TF="$(mkboard)"
tr_cfg "$TF/.agents/handoff" "$LEG_CFG"
trh "$TF" new o-two --title "Foreign" > /dev/null
CREATES_BEFORE="$(fq "calls('create')")"
FOREIGN_OUT="$(trh "$TF" mirror)"
chk_contains "a second board mirroring the same tracker is refused" "$FOREIGN_OUT" "$BID"
chk "the refused pass sends nothing" "$CREATES_BEFORE" "$(fq "calls('create')")"

# An issue with a pre-identity marker is adopted, not duplicated.
TA="$(mkboard)"
tr_cfg "$TA/.agents/handoff" '{ "external": { "kind": "issues", "system": "github", "repo": "acme/adopt", "refPattern": "#[0-9]+" } }'
trh "$TA" new a-one --title "Adopt me" > /dev/null
python3 - "$ST" << 'PY'
import json, sys
p = sys.argv[1]
db = json.load(open(p))
n = max([i["number"] for i in db["issues"]] + [0]) + 1
db["issues"].append({"repo": "acme/adopt", "number": n, "state": "open", "title": "Adopt me",
                     "body": "old\n\n<!-- handoff:a-one-handoff -->\n", "labels": [], "comments": [],
                     "children": [], "assignees": []})
json.dump(db, open(p, "w"))
PY
ADOPT_N="$(fq "in_repo('acme/adopt')[0]['number']")"
trh "$TA" mirror > /dev/null
ABID="$(tr_fn "$TA" board_identity)"
chk "a legacy marker is adopted — no second issue" "1" "$(fq "len(in_repo('acme/adopt'))")"
chk "the adopted issue now carries the identity" "$ADOPT_N" "$(fq "by('<!-- handoff:$ABID/a-one-handoff -->')[0]['number']")"
```

- [ ] **Step 2: Run to verify the new assertions fail**

Run: `bash skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`
Expected: FAIL at `board_identity` (not defined) and the marker/foreign/adopt assertions.

- [ ] **Step 3: `board_identity` and `mirror_claim_tracker`**

Add after `trackers_trust_check`:

```bash
# ADR 0017 — which board a mirrored issue belongs to. Derived, never stored: the board repository's
# root commit plus the board's path inside it, so every clone agrees and a draft board kept in an
# ignored folder of the same repository does not. A board with no git history falls back to its
# physical path; such a board cannot be cloned, so nothing else can share the answer.
board_identity() { # -> 12 lowercase hex digits
  local top root rel
  top="$(board_git rev-parse --show-toplevel)"
  root="$(repo_root_commit "$DIR")"
  if [ -n "$top" ] && [ -n "$root" ]; then
    rel="$(python3 -c 'import os,sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))' "$DIR" "$top")"
    printf '%s:%s' "$root" "$rel"
  else
    printf 'path:%s' "$(cd "$DIR" && pwd -P)"
  fi | shasum -a 256 | cut -c1-12
}

# One board mirrors into a tracker (ADR 0017). Reads a tracker listing and returns it with every
# pre-identity marker ADOPTED for this board, or exits 4 naming the boards that already own issues
# there. An adopted row keeps its old body and carries _legacy, which mirror_plan treats as never
# `same`, so the next update rewrites the marker in the issue itself.
mirror_claim_tracker() { # existing-json -> normalized json; exit 4 with foreign ids on stderr
  python3 - "$1" "$BOARD_ID" << 'PY'
import json, re, sys
existing = json.loads(sys.argv[1] or "[]")
bid = sys.argv[2]
ours = re.compile(r"^[0-9a-f]{12}/")
foreign = set()
for i in existing:
    m = re.search(r"<!-- handoff:(.*?) -->", i.get("body", ""))
    if not m:
        continue
    marker = m.group(1)
    if ours.match(marker):
        if marker[:12] != bid:
            foreign.add(marker[:12])
        continue
    i["body"] = i["body"].replace(m.group(0), "<!-- handoff:%s/%s -->" % (bid, marker))
    i["_legacy"] = True
if foreign:
    sys.stderr.write(" ".join(sorted(foreign)))
    raise SystemExit(4)
print(json.dumps(existing))
PY
}
```

- [ ] **Step 4: Marker in `mirror_render`**

Change the python invocation line of `mirror_render` from

```bash
  python3 - "$f" "${GROUP:-}" "$kids" "$(doc_type "$f")" "$(doc_env "$f")" "$public" << 'PY'
```

to

```bash
  python3 - "$f" "${GROUP:-}" "$kids" "$(doc_type "$f")" "$(doc_env "$f")" "$public" "$BOARD_ID" << 'PY'
```

and inside it change

```python
path, group, kids, dtype, env, public = sys.argv[1:7]
```

```python
marker = "%s%s" % (group + "/" if group else "", doc_id)
```

to

```python
path, group, kids, dtype, env, public, bid = sys.argv[1:8]
```

```python
marker = "%s/%s%s" % (bid, group + "/" if group else "", doc_id)
```

- [ ] **Step 5: Prefix and `_legacy` in `mirror_plan`**

In `mirror_plan`, change the heredoc argv to pass `"$BOARD_ID"` after `"${GROUP:-}"`:

```bash
  python3 - "$1" "$2" "$3" "$(tracker_setting repo)" "${GROUP:-}" "$BOARD_ID" << 'PY'
```

and replace

```python
repo, group = sys.argv[4], sys.argv[5]
prefix = group + "/" if group else ""
```

with

```python
repo, group, bid = sys.argv[4], sys.argv[5], sys.argv[6]
# This board's markers in this section: BID/SECTION/ID, or BID/ID on an unsectioned board.
prefix = bid + "/" + (group + "/" if group else "")
```

In the `same = (...)` expression add `and not have.get("_legacy")` as its last conjunct. Replace the close-loop guard

```python
    if marker in wanted or not marker.startswith(prefix) or (group == "" and "/" in marker):
        continue
```

with

```python
    if marker in wanted or not marker.startswith(prefix) or "/" in marker[len(prefix):]:
        continue
```

- [ ] **Step 6: Normalize the listing in `cmd_mirror` and `drift_live`**

In `cmd_mirror`, directly after `existing="$(tracker_call list "{\"repo\": \"$repo\"}")" || exit 3`, insert:

```bash
BOARD_ID="$(board_identity)"
local claim_err
claim_err="$(mktemp)" || die "mktemp failed"
if ! existing="$(mirror_claim_tracker "$existing" 2> "$claim_err")"; then
  local owners
  owners="$(cat "$claim_err")"
  rm -f "$claim_err"
  die "$repo already carries issues mirrored by another board ($owners) — one board mirrors into a tracker (ADR 0017), and this one is $BOARD_ID. Nothing was sent. Mirror from that board, or move these handoffs onto it."
fi
rm -f "$claim_err"
```

In `drift_live`, directly after its `existing="$(tracker_call list ...)" || return 1`, insert:

```bash
BOARD_ID="$(board_identity)"
existing="$(mirror_claim_tracker "$existing" 2> /dev/null)" || {
  echo "handoff: $repo is mirrored by another board, so this board has no drift to report there (ADR 0017)." >&2
  return 1
}
```

- [ ] **Step 7: Run to verify it passes**

Run: `bash skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`
Expected: `0 failed`.

- [ ] **Step 8: Stage**

```bash
git add skills/engineering/setup-handoff/scripts/payload/handoff skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh
```

---

### Task 4: One mirror pass per tracker

**Files:**

- Modify: `harness/lib/fake-tracker.sh` (visibility branch)
- Modify: `payload/handoff` — `require_tracker` messages; `mirror_survey` (both loops); `cmd_mirror` split into `cmd_mirror` + `mirror_pass`; new `mirror_preflight`, `mirror_report_homeless`; `drift_live` loop
- Test: `payload/trackers.selftest.sh`

**Interfaces:**

- Consumes: `tracker_mode`, `tracker_aliases`, `trackers_trust_check`, `board_allows_public`, `board_identity`, `mirror_claim_tracker`
- Produces: `handoff mirror [--dry-run] [--repo ALIAS]`; global `MIRROR_MODE`; `mirror_pass DRY DRIFT_FILE` → 0, or 1 when a document was refused; `FAKE_TRACKER_PUBLIC_REPOS` (space-separated `owner/name` that read as public; overrides `FAKE_TRACKER_VISIBILITY` for listed repos)

- [ ] **Step 1: Per-repository visibility in the fake tracker**

In `harness/lib/fake-tracker.sh`, add to the header's test-hooks paragraph: `$FAKE_TRACKER_PUBLIC_REPOS=<owner/name ...> makes those repositories answer public, whatever $FAKE_TRACKER_VISIBILITY says.` Replace the visibility branch with:

```python
elif op == "visibility":
    public = os.environ.get("FAKE_TRACKER_PUBLIC_REPOS", "").split()
    if req.get("repo") in public:
        out = {"visibility": "public"}
    else:
        out = {"visibility": os.environ.get("FAKE_TRACKER_VISIBILITY", "private")}
```

- [ ] **Step 2: Write the failing tests**

Insert before the summary:

```bash
printf '\nmirror routes each handoff to its home tracker (ADR 0017)\n'
TP="$(mkboard)"
TPB="$TP/.agents/handoff"
tr_cfg "$TPB" "$TRACKERS_CFG"
trh "$TP" new r-api --title "Api work" --audience acme-api > /dev/null
trh "$TP" new r-web --title "Web work" --audience acme-web > /dev/null
trh "$TP" new r-lib --title "Lib work" --audience acme-lib > /dev/null
git -C "$TP" add -A && git -C "$TP" commit -qm "docs"
PASS_OUT="$(trh "$TP" mirror)"
chk "the api handoff lands in acme-api" "1" "$(fq "len([i for i in in_repo('acme/acme-api') if 'r-api-handoff' in i['body']])")"
chk "the web handoff lands in acme-web" "1" "$(fq "len([i for i in in_repo('acme/acme-web') if 'r-web-handoff' in i['body']])")"
chk "nothing crosses trackers" "0" "$(fq "len([i for i in in_repo('acme/acme-api') if 'r-web-handoff' in i['body']])")"
chk_contains "a home with no tracker is named, not sent" "$PASS_OUT" "r-lib-handoff"
chk "the sprint tracker is never a pass" "0" "$(fq "calls('list', 'acme/plan')")"

LIST_API_BEFORE="$(fq "calls('list', 'acme/acme-api')")"
trh "$TP" mirror --repo acme-web > /dev/null
chk "--repo limits the run to one tracker" "$LIST_API_BEFORE" "$(fq "calls('list', 'acme/acme-api')")"
chk_contains "--repo refuses an alias with no issue tracker" "$(trh "$TP" mirror --repo acme-lib)" "acme-lib"

# A pass for one tracker never closes another tracker's issues.
trh "$TP" claim r-web "closing" > /dev/null
trh "$TP" release r-web --status done --verified-by "checked by hand in test" > /dev/null
trh "$TP" mirror --repo acme-api > /dev/null
chk "the api pass leaves the web issue open" "open" "$(fq "[i for i in in_repo('acme/acme-web') if 'r-web-handoff' in i['body']][0]['state']")"
trh "$TP" mirror > /dev/null
chk "the web pass closes it" "closed" "$(fq "[i for i in in_repo('acme/acme-web') if 'r-web-handoff' in i['body']][0]['state']")"

# Public: checked for every tracker before anything is sent.
TQ="$(mkboard)"
tr_cfg "$TQ/.agents/handoff" "$TRACKERS_CFG"
trh "$TQ" new q-api --title "Q api" --audience acme-api > /dev/null
trh "$TQ" new q-web --title "Q web" --audience acme-web > /dev/null
git -C "$TQ" add -A && git -C "$TQ" commit -qm "docs"
CREATES_BEFORE="$(fq "calls('create')")"
PUB_OUT="$(cd "$TQ" && HANDOFF_TRACKER_ADAPTER="$SRC/fake-tracker.sh" FAKE_TRACKER_STATE="$ST" \
  FAKE_TRACKER_PUBLIC_REPOS="acme/acme-api" ./.agents/handoff/handoff mirror 2>&1)"
chk_contains "a public tracker without allowPublic refuses the run" "$PUB_OUT" "acme/acme-api"
chk "and nothing is sent to any tracker" "$CREATES_BEFORE" "$(fq "calls('create')")"
PUB2_OUT="$(cd "$TQ" && HANDOFF_TRACKER_ADAPTER="$SRC/fake-tracker.sh" FAKE_TRACKER_STATE="$ST" \
  FAKE_TRACKER_PUBLIC_REPOS="acme/acme-web" ./.agents/handoff/handoff mirror 2>&1)"
chk "a public tracker with allowPublic sends only share: public docs" "0" \
  "$(fq "len([i for i in in_repo('acme/acme-web') if 'q-web-handoff' in i['body']])")"
chk "the private tracker is unaffected" "1" "$(fq "len([i for i in in_repo('acme/acme-api') if 'q-api-handoff' in i['body']])")"

# Schema gate: routing needs home.
TS="$(mkboard)"
tr_cfg "$TS/.agents/handoff" "$(printf '%s' "$TRACKERS_CFG" | sed 's/"schema": 4/"schema": 3/')"
chk_contains "a trackers board below schema 4 refuses and names migrate" "$(trh "$TS" mirror)" "migrate"
```

- [ ] **Step 3: Run to verify the new assertions fail**

Run: `bash skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`
Expected: FAIL — `cross-repo` board with only `trackers` reaches `require_tracker`'s "declares no external tracker"; `--repo` is an unknown flag.

- [ ] **Step 4: Scope `mirror_survey` to the pass's home**

At the top of **both** `while IFS= read -r f` loops in `mirror_survey` (the `each_doc` loop and the `each_archive` loop), right after `base="$(basename "$f" .md)"`, insert:

```bash
# ADR 0017 — a pass sees only the documents homed at its tracker. Everything the plan decides
# (create, update, close) is built from this subset, so a pass can never close another
# repository's issue: that issue's document is not in the set it reasons about.
if [ "${MIRROR_MODE:-}" = trackers ] && [ "$(meta "$f" home)" != "$CUR_TRACKER" ]; then
  continue
fi
```

- [ ] **Step 5: Generic `require_tracker` messages**

In `require_tracker`, replace the three `die` messages that mention `external` with:

```bash
[ -f "$DIR/handoff.json" ] || die "this board declares no tracker (no trackers or external block in handoff.json)."
kind="$(tracker_setting kind)"
[ -n "$kind" ] || die "no tracker is declared for ${CUR_TRACKER:-this board} in $DIR/handoff.json (ADR 0017)."
```

keep the sprint-tool `die` as is, and change the repo message to `"the tracker for ${CUR_TRACKER:-this board} names no repo in $DIR/handoff.json — name the repository the issues belong in (owner/name)."`. The literal text `external.repo` must stay in the legacy message path for the existing suite; append ` (external.repo on a single-repository board)` to that sentence.

- [ ] **Step 6: Split `cmd_mirror` into preflight, passes, and one drift write**

Rename the current `cmd_mirror` to `mirror_pass` and change it as follows:

1. Its signature becomes `mirror_pass() { # dry(0|1) drift-rows-file -> 0, or 1 when a document was refused`, starting with `local dry="$1" drift_all="$2"` and **deleting** its flag-parsing `while` loop and its sectioned-board check (both move to the new `cmd_mirror`).
2. After `repo="$(require_tracker mirror)" || exit 3`, add `[ "${MIRROR_MODE:-}" = trackers ] && echo "— ${CUR_TRACKER} → $repo"`.
3. Delete the whole public-refusal `if tracker_is_public ...; then ... fi` block and replace it with:

```bash
local public=0
tracker_is_public "$repo" && public=1
```

(the refusal now happens in `mirror_preflight`, before any pass sends anything). 4. Replace `[ "$dry" = 1 ] || write_drift_report "$drift"` with `cat "$drift" >> "$drift_all"`. 5. Delete the lines `[ "$dry" = 1 ] && echo "(dry run — nothing was sent)"` and the `[ "$refused" = 0 ] || { ... return 1 }` block, and end the function with `return "$refused"`.

Then add the new functions and the new `cmd_mirror`:

```bash
# ADR 0013 per tracker: every tracker a run will touch is asked for its visibility BEFORE any pass
# sends anything, so a public tracker without allowPublic refuses the whole run instead of stopping
# it half-way through. The listing of already-mirrored issues is kept, for the person who decides.
mirror_preflight() { # aliases -> 0, or dies
  local alias repo existing already
  while IFS= read -r alias; do
    CUR_TRACKER="$alias"
    repo="$(require_tracker mirror)" || exit 3
    tracker_adapter > /dev/null || exit 3
    tracker_is_public "$repo" || continue
    board_allows_public && continue
    existing="$(tracker_call list "{\"repo\": \"$repo\"}")" || exit 3
    already="$(printf '%s' "$existing" | python3 -c 'import json, re, sys
rows = ["#%d (%s) %s" % (i["number"], i.get("state", ""), i.get("title", ""))
        for i in json.load(sys.stdin) if re.search(r"<!-- handoff:.*? -->", i.get("body", ""))]
print(chr(10).join("         " + r for r in rows))')"
    die "$(public_refusal "$repo" "mirroring this board")${already:+
       Issues this mirror has already put there, for review (nothing was closed or deleted):
$already}"
  done <<< "$1"
}

# Documents that no pass will carry, named so a run never drops one silently.
mirror_report_homeless() { # aliases
  local f h a found
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_standalone "$f" && continue
    h="$(meta "$f" home)"
    if [ -z "$h" ]; then
      printf 'skip %s — no home; set one to mirror it\n' "$(basename "$f" .md)"
      continue
    fi
    found=0
    while IFS= read -r a; do [ "$a" = "$h" ] && found=1; done <<< "$1"
    [ "$found" = 1 ] || printf 'skip %s — home %s has no issue tracker\n' "$(basename "$f" .md)" "$h"
  done < <(each_doc)
}

# `handoff mirror [--dry-run] [--repo ALIAS]` (ADR 0011 level 3, routed per repository by ADR 0017).
cmd_mirror() {
  local dry=0 only=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)
        dry=1
        shift
        ;;
      --repo)
        require_value --repo "$#" "${2:-}"
        only="$2"
        shift 2
        ;;
      *) die "unknown flag: $1 (usage: handoff mirror [--dry-run] [--repo ALIAS])" ;;
    esac
  done
  if board_is_grouped && [ -z "$GROUP" ]; then
    die "this board is sectioned ($BOARD_GROUPS); mirror one section at a time: HANDOFF_GROUP=<section> handoff mirror"
  fi
  MIRROR_MODE="$(tracker_mode)"
  [ "$MIRROR_MODE" != none ] || die "this board declares no tracker (no trackers block in $DIR/handoff.json; a single-repository board may use external) — nothing to mirror into."
  local aliases a known
  aliases="$(tracker_aliases)"
  if [ "$MIRROR_MODE" = trackers ]; then
    [ "$(board_schema)" -ge 4 ] \
      || die "this board is schema $(board_schema); routing by home needs schema 4 — run './handoff migrate' first (ADR 0017)."
    trackers_trust_check
    if [ -n "$only" ]; then
      known=0
      while IFS= read -r a; do [ "$a" = "$only" ] && known=1; done <<< "$aliases"
      [ "$known" = 1 ] || die "--repo $only has no issue tracker on this board (issue trackers: $(printf '%s' "$aliases" | tr '\n' ' ' | sed 's/ $//'))."
      aliases="$only"
    fi
    if [ -z "$aliases" ]; then
      echo "This board declares no issue trackers — nothing to mirror."
      return 0
    fi
    mirror_report_homeless "$aliases"
  else
    [ -z "$only" ] || die "--repo needs a board with per-repository trackers (ADR 0017)."
  fi
  mirror_preflight "$aliases"
  local drift_all refused=0 alias
  drift_all="$(mktemp)" || die "mktemp failed"
  while IFS= read -r alias; do
    CUR_TRACKER="$alias"
    mirror_pass "$dry" "$drift_all" || refused=1
  done <<< "$aliases"
  # One drift file per run, from every pass: a handoff has one home, so its #N is unambiguous.
  [ "$dry" = 1 ] || write_drift_report "$drift_all"
  rm -f "$drift_all"
  [ "$dry" = 1 ] && echo "(dry run — nothing was sent)"
  [ "$refused" = 0 ] || {
    echo "handoff mirror: one or more documents were refused (see above) — redact them and re-run." >&2
    return 1
  }
  return 0
}
```

Note: `mirror_preflight` in legacy mode runs once with `CUR_TRACKER=""`, which preserves the existing sprint-tool and missing-repo refusals and the public listing.

- [ ] **Step 7: `drift_live` over every pass**

Rename the current `drift_live` to `drift_live_pass` (no other change), then add:

```bash
drift_live() { # -> rows from every pass, id<TAB>number<TAB>board-status<TAB>tracker-state
  local alias rc=0
  MIRROR_MODE="$(tracker_mode)"
  [ "$MIRROR_MODE" != none ] || return 1
  while IFS= read -r alias; do
    CUR_TRACKER="$alias"
    drift_live_pass || rc=1
  done <<< "$(tracker_aliases)"
  return "$rc"
}
```

- [ ] **Step 8: Run to verify it passes**

Run: `bash skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`
Expected: `0 failed`.

- [ ] **Step 9: Stage**

```bash
git add harness/lib/fake-tracker.sh skills/engineering/setup-handoff/scripts/payload/handoff \
  skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh
```

---

### Task 5: Summary projection and the audience label

**Files:**

- Modify: `payload/handoff` — `mirror_render`, `MANAGED` in `mirror_plan` and `mirror_links`, `mirror_survey`'s call to `mirror_render`
- Modify: `payload/handoff.selftest.sh` — only the permitted edits
- Test: `payload/trackers.selftest.sh`

**Interfaces:**

- Consumes: `tracker_setting projection`
- Produces: `mirror_render PATH PUBLIC PROJECTION`; label `audience:ALIAS`; managed prefix `audience:`

- [ ] **Step 1: Write the failing tests**

Insert before the summary:

```bash
printf '\nsummary projection by default, and the audience label (ADR 0017)\n'
TJ="$(mkboard)"
TJB="$TJ/.agents/handoff"
tr_cfg "$TJB" "$(printf '%s' "$TRACKERS_CFG" | sed 's#"repo": "acme/acme-web", #"repo": "acme/acme-web", "projection": "full", #')"
trh "$TJ" new j-api --title "Proj api" --audience acme-api > /dev/null
trh "$TJ" new j-web --title "Proj web" --audience acme-web > /dev/null
for d in j-api j-web; do
  python3 - "$TJB/$d-handoff.md" << 'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = t.replace("## Current state\n", "## Current state\n\nSTATE-TEXT\n", 1)
t = t.replace("## Context\n", "## Context\n\nCONTEXT-TEXT\n", 1)
t = t.replace("## Verify\n", "## Verify\n\nVERIFY-TEXT\n", 1)
t = t.rstrip("\n") + "\n\n## Ruled out\n\nRULED-OUT-TEXT\n"
open(p, "w").write(t)
PY
done
git -C "$TJ" add -A && git -C "$TJ" commit -qm "docs"
trh "$TJ" mirror > /dev/null
API_BODY="$(fq "[i for i in in_repo('acme/acme-api') if 'j-api-handoff' in i['body']][0]['body']")"
WEB_BODY="$(fq "[i for i in in_repo('acme/acme-web') if 'j-web-handoff' in i['body']][0]['body']")"
chk_contains "summary sends Current state" "$API_BODY" "STATE-TEXT"
chk "summary omits Context" "no" "$(case "$API_BODY" in *CONTEXT-TEXT*) echo yes ;; *) echo no ;; esac)"
chk "summary omits Verify" "no" "$(case "$API_BODY" in *VERIFY-TEXT*) echo yes ;; *) echo no ;; esac)"
chk_contains "full sends Context" "$WEB_BODY" "CONTEXT-TEXT"
chk_contains "full sends Verify" "$WEB_BODY" "VERIFY-TEXT"
chk "Ruled out never leaves the board" "no" "$(case "$WEB_BODY$API_BODY" in *RULED-OUT-TEXT*) echo yes ;; *) echo no ;; esac)"
chk "the audience is a label" "True" "$(fq "'audience:acme-api' in [i for i in in_repo('acme/acme-api') if 'j-api-handoff' in i['body']][0]['labels']")"

# An audience flip relabels the same issue; it never moves.
J_NUM="$(fq "[i for i in in_repo('acme/acme-api') if 'j-api-handoff' in i['body']][0]['number']")"
python3 -c 'import sys
p = sys.argv[1]
open(p, "w").write(open(p).read().replace("\naudience: acme-api\n", "\naudience: acme-web\n", 1))' "$TJB/j-api-handoff.md"
git -C "$TJ" add -A && git -C "$TJ" commit -qm "flip"
trh "$TJ" mirror > /dev/null
chk "the flipped handoff keeps its issue" "$J_NUM" "$(fq "[i for i in in_repo('acme/acme-api') if 'j-api-handoff' in i['body']][0]['number']")"
chk "and gains the new audience label" "True" "$(fq "'audience:acme-web' in [i for i in in_repo('acme/acme-api') if 'j-api-handoff' in i['body']][0]['labels']")"
chk "the old audience label is gone" "False" "$(fq "'audience:acme-api' in [i for i in in_repo('acme/acme-api') if 'j-api-handoff' in i['body']][0]['labels']")"
chk "no issue appears in the audience's tracker" "0" "$(fq "len([i for i in in_repo('acme/acme-web') if 'j-api-handoff' in i['body']])")"
```

- [ ] **Step 2: Run to verify the new assertions fail**

Run: `bash skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`
Expected: FAIL on "summary omits Context", "summary omits Verify", and the audience-label assertions.

- [ ] **Step 3: Render by projection, add the audience label**

In `mirror_survey`, change `rendered="$(mirror_render "$f" "$public")"` to:

```bash
rendered="$(mirror_render "$f" "$public" "$(tracker_setting projection)")"
```

In `mirror_render`, change the signature comment to `# doc-path public(0|1) projection(summary|full) -> JSON line`, the first line to `local f="$1" public="${2:-0}" projection="${3:-summary}" kids="" c cf`, append `"$projection"` to the heredoc argv (after `"$BOARD_ID"`), and inside python change the unpack to `path, group, kids, dtype, env, public, bid, projection = sys.argv[1:9]`. Replace

```python
    for name in ("Current state", "Context", "Verify"):
```

with

```python
    # ADR 0017 — a summary unless the tracker opted into more. `## Ruled out`, notes and evidence
    # are in neither list, so they never leave the board.
    names = ("Current state", "Context", "Verify") if projection == "full" else ("Current state",)
    for name in names:
```

After the `labels.append("env:%s" % env)` line (inside the non-orchestrator `else`), add:

```python
    if meta.get("audience"):
        labels.append("audience:%s" % meta["audience"])
```

In both `MANAGED = [...]` lists (in `mirror_plan` and `mirror_links`), add `"audience:"`.

- [ ] **Step 4: Run the new suite**

Run: `bash skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`
Expected: `0 failed`.

- [ ] **Step 5: Run the legacy suite once and apply only the permitted edits**

Run: `bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh 2>&1 | grep -E '\[FAIL\]|passed'`

For each `[FAIL]`: if the assertion expects `Context` or `Verify` content in an issue (for example the `m-leak` credential-in-Context refusal), add `"projection": "full"` to the JSON passed to that block's config helper (`mi_ext`, or the block's own `handoff.json` write); if it matches a literal marker string such as `<!-- handoff:m-open-handoff -->`, change it to a substring that omits the `<!-- handoff:` prefix. Make **no** other change to that file. Any failure not explained by one of these two causes is a defect in Tasks 1-5: stop, report it with the assertion text, and fix the CLI, not the test.

Re-run the legacy suite once after the edits. Expected: `--- N passed, 0 failed ---`.

- [ ] **Step 6: Stage**

```bash
git add skills/engineering/setup-handoff/scripts/payload/handoff \
  skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh \
  skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
```

---

### Task 6: References, delegation and replies follow the home

**Files:**

- Modify: `payload/handoff` — `export_to_issue`, `export_bundle_to_issue`, `import_result_from_issue`
- Test: `payload/trackers.selftest.sh`

**Interfaces:**

- Consumes: `CUR_TRACKER` set by `cmd_new` (Task 2) for `--ref`
- Produces: delegation into `trackers[home]`; bundle export refuses children homed elsewhere

- [ ] **Step 1: Write the failing tests**

Insert before the summary:

```bash
printf '\n--ref, export --to-issue and import follow the home (ADR 0017)\n'
TD="$(mkboard)"
TDB="$TD/.agents/handoff"
tr_cfg "$TDB" "$TRACKERS_CFG"
chk_contains "a ref is checked against the home's pattern — refused" \
  "$(trh "$TD" new d-bad --title "Bad ref" --audience acme-api --ref "PLAN-3")" "#[0-9]+"
trh "$TD" new d-ok --title "Good ref" --audience acme-api --ref "#12" > /dev/null
chk "a ref matching the home's pattern is stored" "#12" "$(sed -n 's/^external_ref: //p' "$TDB/d-ok-handoff.md" | tr -d '"')"
trh "$TD" new d-work --title "Delegate me" --audience acme-web > /dev/null
git -C "$TD" add -A && git -C "$TD" commit -qm "docs"
trh "$TD" export d-work --to-issue > /dev/null
chk "export --to-issue opens the issue in the home's tracker" "acme/acme-web" \
  "$(fq "[c[1]['repo'] for c in db['calls'] if c[0] == 'create'][-1]")"
trh "$TD" import --result --from-issue d-work > /dev/null
chk "import --from-issue reads the home's tracker" "acme/acme-web" \
  "$(fq "[c[1]['repo'] for c in db['calls'] if c[0] == 'comments'][-1]")"
trh "$TD" new d-k1 --title "Kid one" --audience acme-api > /dev/null
trh "$TD" new d-k2 --title "Kid two" --audience acme-web > /dev/null
trh "$TD" new d-bun --orchestrator --children d-k1,d-k2 --home acme-api --title "Mixed bundle" > /dev/null
git -C "$TD" add -A && git -C "$TD" commit -qm "bundle"
chk_contains "a bundle whose children live in other trackers is not delegated as one" \
  "$(trh "$TD" export d-bun --to-issue)" "d-k2-handoff"
```

- [ ] **Step 2: Run to verify the new assertions fail**

Run: `bash skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`
Expected: FAIL on the export/import repo assertions (no home is set as `CUR_TRACKER`, so no tracker resolves) and on the mixed bundle.

- [ ] **Step 3: Set `CUR_TRACKER` from the document**

At the top of the bodies of `export_to_issue`, `export_bundle_to_issue` and `import_result_from_issue`, after their argument `local` lines and after the doc path is known, add:

```bash
# ADR 0017 — a document reaches the tracker of its home, nowhere else.
CUR_TRACKER="$(meta "$doc" home)"
```

(Use the function's own variable holding the doc path; in `import_result_from_issue` resolve it with `doc_of "$id"` first if the function does not already hold it.)

In `export_bundle_to_issue`, right after that line, add:

```bash
if [ "$(tracker_mode)" = trackers ]; then
  local kid kf away=""
  while IFS= read -r kid; do
    [ -n "$kid" ] || continue
    kf="$(doc_of "$kid" 2> /dev/null)" || continue
    [ "$(meta "$kf" home)" = "$CUR_TRACKER" ] || away="${away:+$away, }$kid ($(meta "$kf" home))"
  done <<< "$(children_of "$doc")"
  [ -z "$away" ] || die "$id is homed at $CUR_TRACKER, but these children live in other trackers: $away. A delegated bundle is one tracker's parent and children (ADR 0017) — export those children on their own."
fi
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`
Expected: `0 failed`.

- [ ] **Step 5: Run the legacy suite once**

Run: `bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh 2>&1 | grep -E '\[FAIL\]|passed'`
Expected: `0 failed`. A failure here is a defect in this task — fix the CLI.

- [ ] **Step 6: Bump the stamp, sync fixtures, and commit the CLI change**

Change `skills/engineering/setup-handoff/scripts/payload.version` to `setup-handoff 51`, then:

```bash
bash scripts/sync-fixture-boards.sh
git add skills/engineering/setup-handoff/scripts/payload/handoff \
  skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh \
  skills/engineering/setup-handoff/scripts/payload.version harness
git status --short
git commit -m "feat(feature): route each handoff to its home repository's tracker

The mirror resolves a tracker per repository from the board's committed
trackers map, pins a handoff's home at creation, stamps issues with the
board identity so a second board is refused, and projects a summary by
default. Schema 4 adds home; migrate backfills it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

Expected: pre-commit prints `[PASS]` for standalone, payload version and fixture boards. `git status --short` before the commit shows only the files of Tasks 1-6.

---

### Task 7: Verifier checks

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh` — known keys (~297-299), the tracker block (~573-609), the per-doc loop (~654-661), the public audit line (~846-850)
- Test: `payload/trackers.selftest.sh`

**Interfaces:**

- Produces finding ids: `board.trackers.kind`, `board.trackers.pattern`, `board.trackers.repo`, `board.trackers.adapter`, `board.trackers.owner`, `board.trackers.unknown-alias`, `board.external.legacy`, `doc.home.missing`, `doc.home.unregistered`; `board.external.public` reports per tracker

- [ ] **Step 1: Write the failing tests**

Insert before the summary:

```bash
printf '\nthe verifier checks trackers and homes offline (ADR 0017)\n'
VERIFY="$HERE/../verify-setup-handoff.sh"
vids() { # repo -> "level:id" for every finding
  bash "$VERIFY" "$1" --json 2> /dev/null | python3 -c 'import json,sys
for f in json.load(sys.stdin)["findings"]: print("%s:%s" % (f["level"], f["id"]))'
}
TV="$(mkboard)"
TVB="$TV/.agents/handoff"
tr_cfg "$TVB" "$(printf '%s' "$TRACKERS_CFG" | sed 's#"acme-plan"#"acme-ghost"#; s#acme/acme-web#zeta/acme-web#')"
cat > "$TVB/v-none-handoff.md" << 'DOC'
---
id: v-none-handoff
title: No home
type: coordination
schema: 4
status: open
---

## Current state
DOC
cat > "$TVB/v-away-handoff.md" << 'DOC'
---
id: v-away-handoff
title: Away
type: coordination
schema: 4
status: open
home: acme-nowhere
---

## Current state
DOC
VIDS="$(vids "$TV")"
chk_contains "mixed owners warn" "$VIDS" "warn:board.trackers.owner"
chk_contains "a tracker keyed by an unregistered alias warns" "$VIDS" "warn:board.trackers.unknown-alias"
chk_contains "a doc with no home warns" "$VIDS" "warn:doc.home.missing"
chk_contains "a doc homed at an unregistered alias warns" "$VIDS" "warn:doc.home.unregistered"
chk "the trackers key is recognised" "no" "$(case "$VIDS" in *warn:board.config.unknown_keys*) echo yes ;; *) echo no ;; esac)"
TW="$(mkboard)"
tr_cfg "$TW/.agents/handoff" '{ "topology": "cross-repo", "schema": 4, "external": { "kind": "issues", "system": "github", "repo": "acme/board", "refPattern": "#[0-9]+" } }'
chk_contains "external on a cross-repo board is legacy" "$(vids "$TW")" "warn:board.external.legacy"
```

- [ ] **Step 2: Run to verify the new assertions fail**

Run: `bash skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`
Expected: FAIL on every assertion of the new block (and `unknown_keys` reports `trackers`).

- [ ] **Step 3: Implement the checks**

1. Add `"trackers"` to the `known={...}` set.
2. After the existing `if [ "${EXT_PRESENT:-0}" = 1 ]; then ... fi` block, add:

```bash
# ADR 0017 — trackers per repository. Each entry is checked like `external` above, then the board as a
# whole: one owner, keyed by aliases the registry lists. Offline, like everything here.
TRK_PRESENT=0 TRK_PUBLIC="" TRK_ALIASES="" REG_ALIASES="" TRK_PATTERNS=""
if [ -f "$HD/handoff.json" ] && command -v python3 > /dev/null 2>&1; then
  TRK_REPORT="$(
    python3 - "$HD/handoff.json" "$(git -C "$HD" config --get remote.origin.url 2> /dev/null)" << 'PY'
import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
t = d.get("trackers") if isinstance(d, dict) else None
reg = [r.get("alias") for r in ((d.get("_generated") or {}).get("repos") or []) if isinstance(r, dict) and r.get("alias")]
print("REG\x1f" + " ".join(reg))
if isinstance(d.get("external"), dict) and d.get("topology") == "cross-repo" and not isinstance(t, dict):
    print("LEGACY")
if not isinstance(t, dict):
    raise SystemExit(0)
print("PRESENT")
owners = set()
for alias, e in sorted(t.items()):
    if not isinstance(e, dict):
        continue
    s = lambda k: e.get(k) if isinstance(e.get(k), str) else ""
    print("ENTRY\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s" % (alias, s("kind"), s("refPattern"), s("repo"), s("system"),
                                            "1" if e.get("allowPublic") is True else "0"))
    if "/" in s("repo"):
        host = "github.com" if (s("system") or "github") == "github" else s("system")
        owners.add(("%s/%s" % (host, s("repo").split("/")[0])).lower())
m = re.search(r"github\.com[:/]([^/]+)/", sys.argv[2] or "")
if m:
    owners_board = "github.com/" + m.group(1).lower()
    if owners and owners != {owners_board}:
        print("OWNER\x1fboard remote %s, trackers %s" % (owners_board, " ".join(sorted(owners))))
elif len(owners) > 1:
    print("OWNER\x1ftrackers %s" % " ".join(sorted(owners)))
PY
  )"
  while IFS=$'\x1f' read -r kind a b c dd ee ff; do
    case "$kind" in
      REG) REG_ALIASES="$a" ;;
      LEGACY) warn board.external.legacy "external is set on a cross-repository board and routes nothing — declare trackers per repository instead (ADR 0017)" ;;
      PRESENT) TRK_PRESENT=1 ;;
      OWNER) warn board.trackers.owner "this board's trackers cross a trust boundary ($a) — one board per owner (ADR 0011, ADR 0017); the mirror refuses until they agree" ;;
      ENTRY)
        TRK_ALIASES="$TRK_ALIASES $a"
        TRK_PATTERNS="$TRK_PATTERNS$a=$c"$'\n'
        case "$b" in issues | sprints) ;; *) warn board.trackers.kind "trackers.$a kind is \"$b\" — use issues or sprints" ;; esac
        [ -n "$c" ] || warn board.trackers.pattern "trackers.$a has no refPattern — new --ref will refuse every reference for docs homed there"
        [ "$b" != issues ] || [ -n "$dd" ] || warn board.trackers.repo "trackers.$a is an issue tracker with no repo — mirror and export --to-issue refuse it"
        [ -z "$ee" ] || [ -f "$HD/scripts/tracker-$ee.sh" ] || warn board.trackers.adapter "no adapter for trackers.$a system '$ee' at scripts/tracker-$ee.sh"
        [ "$ff" = 1 ] && TRK_PUBLIC="${TRK_PUBLIC:+$TRK_PUBLIC, }$a"
        case " $REG_ALIASES " in *" $a "*) ;; *) [ "$TOPO" = cross-repo ] && warn board.trackers.unknown-alias "trackers.$a is not a repository this board registers ($REG_ALIASES)" ;; esac
        ;;
    esac
  done <<< "$TRK_REPORT"
  [ "$TRK_PRESENT" = 1 ] && ok board.trackers "trackers declared for:$TRK_ALIASES"
fi
```

Every record is separated by `\x1f`, never a tab: `read` collapses consecutive tabs, so an entry with an empty `refPattern` would shift every field after it (the existing `external` reader uses `\x1f` for the same reason).

If the verifier stops before its document-schema section on this bare fixture (it has no AGENTS.md or hooks), read its early `bad`/`exit` paths and add the minimum it needs to `TV` and `TW` — never loosen the verifier to suit the test.

3. In the per-doc loop, after the `xref` block, add:

```bash
# ADR 0017 — on a trackers board every live coordination or orchestrator doc needs a home the
# registry knows, or no pass will ever carry it.
if [ "$TRK_PRESENT" = 1 ] && [ "$darch" = 0 ] && [ "$dtype" != standalone ]; then
  dhome="$(fm "$doc" home)"
  if [ -z "$dhome" ]; then
    warn doc.home.missing "$dname: no home — it is never mirrored. Set one of:$TRK_ALIASES"
  else
    case " $REG_ALIASES " in *" $dhome "*) ;; *) [ "$TOPO" = cross-repo ] && warn doc.home.unregistered "$dname: home $dhome is not a repository this board registers ($REG_ALIASES)" ;; esac
  fi
fi
```

and change the `xref` pattern lookup so that on a trackers board it uses the doc's home pattern: before the `if [ -n "$xref" ]` block, add

```bash
DOC_PATTERN="$EXT_PATTERN"
if [ "$TRK_PRESENT" = 1 ]; then
  DOC_PATTERN="$(printf '%s' "$TRK_PATTERNS" | sed -n "s/^$(fm "$doc" home)=//p" | head -1)"
fi
```

and use `$DOC_PATTERN` in place of `$EXT_PATTERN` inside that block.

4. Replace the public audit condition so it also covers trackers:

```bash
if [ "${EXT_PUBLIC:-0}" = 1 ] || [ -n "$TRK_PUBLIC" ]; then
  warn board.external.public "this board allows publishing to a public tracker (${TRK_PUBLIC:-external}) — docs marked share: public: ${SHARED_PUBLIC:-none}"
fi
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh`
Expected: `0 failed`.

- [ ] **Step 5: Run the setup-handoff harness grader**

Run: `python3 harness/setup-handoff-workspace/grade.py 2>&1 | tail -15`
Expected: the same pass/fail set as on `main` (the five by-design failures recorded for handoff evals are pre-existing and unchanged). If the set differs, run the same command in a `git worktree` of `main` to see which findings are new.

- [ ] **Step 6: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh
git commit -m "feat(feature): verify trackers and homes offline"
```

---

### Task 8: Installer — preserve `trackers`, name the new default, workflow token

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/setup-handoff.sh` (~280-288 policy preservation; ~625-645 `--with-mirror-workflow`)
- Test: `skills/engineering/setup-handoff/scripts/setup-handoff.selftest.sh`

**Interfaces:**

- Consumes: board `handoff.json` `trackers`
- Produces: re-install keeps `trackers`; a notice when `external` has no `projection`; a notice on a cross-repo board with leftover `external`; the workflow picks `GITHUB_TOKEN` only when every tracker repo is the board's own repo, else `HANDOFF_TRACKER_TOKEN`

- [ ] **Step 1: Read the installer selftest's board fixture helper**

Run: `grep -n "^[a-z_]*() {" skills/engineering/setup-handoff/scripts/setup-handoff.selftest.sh | head -20` and `grep -n "external" skills/engineering/setup-handoff/scripts/setup-handoff.selftest.sh`. Use the same helper the existing `external`-survives-reinstall assertion uses.

- [ ] **Step 2: Write the failing test**

Next to the existing assertion that `external` survives a re-install, add an assertion of the same shape for `trackers`: seed the board's `handoff.json` with `"trackers": {"acme-api": {"kind": "issues", "system": "github", "repo": "acme/acme-api"}}`, re-run the installer exactly as that neighbouring assertion does, and check:

```bash
chk "trackers survive a re-install" "acme/acme-api" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["trackers"]["acme-api"]["repo"])' "$BOARD/handoff.json")"
```

(`$BOARD` is whatever variable the neighbouring assertion uses for the board path.)

- [ ] **Step 3: Run to verify it fails**

Run: `bash skills/engineering/setup-handoff/scripts/setup-handoff.selftest.sh 2>&1 | grep -E 'trackers survive|passed'`
Expected: `[FAIL] trackers survive a re-install`.

- [ ] **Step 4: Preserve `trackers` and print the notices**

After the `ext = existing.get("external")` preservation lines, add:

```python
# ADR 0017 — trackers per repository are board policy too, and publishing policy (allowPublic) must
# never be reverted by a re-install (ADR 0013).
trk = existing.get("trackers")
if isinstance(trk, dict):
    cfg["trackers"] = trk
if isinstance(ext, dict) and cfg.get("topology") == "cross-repo" and not isinstance(trk, dict):
    sys.stderr.write("note: external is set on a cross-repository board and routes nothing now. Declare trackers per repository (setup-handoff SKILL.md, per-repository trackers) — confirm each one.\n")
if isinstance(ext, dict) and "projection" not in ext and not isinstance(trk, dict):
    sys.stderr.write("note: the mirror now sends a summary (Current state only) by default. Set external.projection to full to keep sending Context and Verify.\n")
```

(If `sys` is not imported in that heredoc, add `import sys`.)

In the `--with-mirror-workflow` section, replace the `tracker=` python with one that prints every tracker repo:

```python
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
repos = [e.get("repo") for e in (cfg.get("trackers") or {}).values() if isinstance(e, dict) and e.get("kind") == "issues" and e.get("repo")]
if not repos and isinstance(cfg.get("external"), dict) and cfg["external"].get("repo"):
    repos = [cfg["external"]["repo"]]
print(" ".join(sorted(set(repos))))
```

change the `die` message to `"--with-mirror-workflow: this board declares no issue tracker (trackers, or external on a single-repository board), so there is nothing for the workflow to mirror into."`, and replace the token decision with:

```bash
if [ "$tracker" = "$repo" ]; then
  token_expr='${{ secrets.GITHUB_TOKEN }}'
  token_note="The tracker is this workflow's own repository, so the built-in GITHUB_TOKEN suffices."
else
  token_expr='${{ secrets.HANDOFF_TRACKER_TOKEN }}'
  token_note="The trackers ($tracker) are not only this workflow's repository, so set a repository secret named HANDOFF_TRACKER_TOKEN with issues:write on each of them. Only the name appears here."
fi
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash skills/engineering/setup-handoff/scripts/setup-handoff.selftest.sh 2>&1 | grep -E '\[FAIL\]|passed'`
Expected: `0 failed`.

- [ ] **Step 6: Sync fixtures and commit**

Run: `bash scripts/sync-fixture-boards.sh && bash scripts/sync-fixture-boards.sh --check`
Expected: the check passes.

```bash
git add skills/engineering/setup-handoff/scripts/setup-handoff.sh \
  skills/engineering/setup-handoff/scripts/setup-handoff.selftest.sh harness
git commit -m "feat(setup): keep per-repository trackers across a re-install"
```

---

### Task 9: Documentation

**Files:**

- Create: `docs/adr/0017-a-tracker-attaches-per-repository-and-one-board-mirrors-into-it.md`
- Modify: `docs/adr/0011-boards-have-no-roles-and-trackers-attach-per-board.md` (status pointer)
- Modify: `CONTEXT.md`
- Modify: `skills/engineering/setup-handoff/SKILL.md`, `skills/engineering/run-handoff/SKILL.md`, `skills/engineering/delegate-handoff/SKILL.md`, `skills/engineering/setup-handoff/scripts/payload/README.md`
- Modify: `docs/usage/` handoff guide (find it with `ls docs/usage`)

- [ ] **Step 1: ADR 0017**

Write the ADR in the house format (frontmatter `status: accepted`, `date: 2026-09-21`; sections Context, Decision, Considered options, Consequences), carrying decisions 1-7 and the rejected alternatives from the spec verbatim in substance. It refines ADR 0011 (one tracker per board becomes one per repository; the board has no tracker of its own on a cross-repository board) and keeps ADR 0013's double opt-in per tracker.

- [ ] **Step 2: ADR 0011 pointer**

Change its frontmatter `status: accepted` to `status: accepted — refined by ADR 0017` (em dash, no colon inside the value), and add one sentence under Decision's tracker bullet: "ADR 0017 attaches a tracker per repository on a cross-repository board."

- [ ] **Step 3: CONTEXT.md**

- Rewrite **External tracker**: "The project tracker a handoff's issue is mirrored into — the one declared for its **home** repository on the board. A sprint tool is referenced, never mirrored. Never the board."
- Add **Home**: "The repository whose tracker owns a handoff's issue, pinned when the handoff is created and never changed. Distinguished from **Audience**, which names the repository acting next and changes freely." `_Avoid_: owner repo, target repo`
- Add **Projection**: "How much of a handoff its issue carries — `summary` (Current state) by default, or `full` (adds Context and Verify) where a tracker opts in. Ruled out, notes and evidence never leave the board." `_Avoid_: sync level, detail level`
- Add **Board identity**: "The derived name a mirrored issue carries so one tracker is mirrored by one board — every clone of a board shares it." `_Avoid_: board id field`
- Extend the draft-board note: "A board a developer keeps for their own drafts is an ordinary board with no role of its own, and never mirrors."

- [ ] **Step 4: Skill docs**

- `setup-handoff/SKILL.md`: a "Per-repository trackers" section — the `trackers` shape (use `acme-*`), the one-owner rule, `projection`, the upgrade procedure for a cross-repository board with a leftover `external` (ask the user before each change; pre-fill each registered repository's tracker from its `origin`; list issues already in the retired board-level tracker for the user to close by hand; never close them), and the CI secret name `HANDOFF_TRACKER_TOKEN`.
- `run-handoff/SKILL.md`: the split convention — "A quick audience flip only relabels the issue. Work another team owns becomes a child handoff homed in that team's repository (`new --home ALIAS`, under an orchestrator or ordered with `--after`)."
- `delegate-handoff/SKILL.md`: "`export --to-issue` opens the issue in the tracker of the handoff's home; a bundle is delegated as one only when all its children share that home."
- `payload/README.md`: document `new --home`, `mirror --repo`, `projection`, and the marker's board identity.

- [ ] **Step 5: Usage guide example**

In the handoff usage guide, add one worked example: a team board (private remote, owner `acme`) registering `acme-api` and `acme-web` with a tracker each, and two maintainers each keeping a local draft board that never mirrors, moving work to the team board with `handoff move ID --to TEAM_BOARD`.

- [ ] **Step 6: Gates and commit**

Run: `bash scripts/verify-standalone.sh && npx prettier --check CONTEXT.md docs/adr/0017-*.md skills/engineering/*/SKILL.md`
Expected: pass (run `npx prettier --write` on the files you changed if the check fails, then re-check).

```bash
git add docs/adr CONTEXT.md skills/engineering docs/usage
git commit -m "docs(docs): record per-repository trackers in ADR 0017 and the glossary"
```

---

### Task 10: Full verification

- [ ] **Step 1: Run every suite once**

```bash
bash skills/engineering/setup-handoff/scripts/payload/trackers.selftest.sh 2>&1 | tail -2
bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh 2>&1 | grep -E '\[FAIL\]|passed'
bash skills/engineering/setup-handoff/scripts/payload/config.selftest.sh 2>&1 | tail -2
bash skills/engineering/setup-handoff/scripts/setup-handoff.selftest.sh 2>&1 | grep -E '\[FAIL\]|passed'
```

Expected: every suite `0 failed`. Run the legacy suite with `env -u CLAUDE_CODE_SESSION_ID` as well if any lease assertion fails — ambient session ids have caused false failures before.

- [ ] **Step 2: Repository gates**

```bash
bash scripts/verify-standalone.sh
bash scripts/verify-payload-version.sh
bash scripts/sync-fixture-boards.sh --check
```

Expected: all pass.

- [ ] **Step 3: Report**

Report each suite's pass/fail counts verbatim. Do not merge; the branch goes to code review next.
