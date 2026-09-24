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
has() { # haystack needle -> yes | no   (a function: `case` inside $() trips bash 3.2's parser)
  case "$1" in
    *"$2"*) echo yes ;;
    *) echo no ;;
  esac
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
# Line count AND content: an error message is one line too, so the count alone would pass vacuously.
chk "legacy mode has exactly one unnamed pass" "1:" \
  "$(tr_fn "$TL" 'printf "%s:%s" "$(tracker_aliases | wc -l | tr -d " ")" "$(tracker_aliases)"')"
TX="$(mkboard)"
tr_cfg "$TX/.agents/handoff" '{ "topology": "cross-repo", "external": { "kind": "issues", "system": "github", "repo": "acme/board" } }'
chk "a cross-repo board with only external routes nowhere" "none" "$(tr_fn "$TX" tracker_mode)"

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
chk "a standalone doc has no home" "yes:" "$([ -f "$THB/h-std-handoff.md" ] && echo yes):$(sed -n 's/^home: //p' "$THB/h-std-handoff.md" 2> /dev/null)"
trh "$TH" new h-orch --orchestrator --children h-flag --title "Bundle" > /dev/null
chk "an orchestrator with no --home and no HANDOFF_REPO has none" "" "$(sed -n 's/^home: //p' "$THB/h-orch-handoff.md")"
chk "the orchestrator exists (so the empty home above is not vacuous)" "yes" "$([ -f "$THB/h-orch-handoff.md" ] && echo yes || echo no)"

# move re-validates home against the target board's registry.
THT="$(mkboard)"
tr_cfg "$THT/.agents/handoff" '{ "topology": "cross-repo", "schema": 4, "_generated": { "repos": [ { "alias": "acme-web" } ] } }'
trh "$TH" claim h-flag "moving" > /dev/null
chk_contains "move refuses a board that does not register the home" \
  "$(trh "$TH" move h-flag --to "$THT/.agents/handoff")" "homed at acme-api"
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
chk_contains "migrate names the doc it could not resolve" "$MIG_OUT" "m-none-handoff (3 → 4) — no home"
chk "migrate stamps schema 4" "4" "$(sed -n 's/^schema: //p' "$TMB/m-none-handoff.md")"

printf '\nboard identity and one mirroring board per tracker (ADR 0017)\n'
LEG_CFG='{ "external": { "kind": "issues", "system": "github", "repo": "acme/owned", "refPattern": "#[0-9]+" } }'
TO="$(mkboard)"
tr_cfg "$TO/.agents/handoff" "$LEG_CFG"
git -C "$TO" add -A && git -C "$TO" commit -qm "board"
BID="$(tr_fn "$TO" board_identity)"
chk "a board identity is 12 hex digits" "yes" "$(printf '%s' "$BID" | grep -Eqx '[0-9a-f]{12}' && echo yes || echo no)"
TOC="$(mktemp -d)/clone"
git clone -q "$TO" "$TOC"
is_bid() { printf '%s' "$1" | grep -Eqx '[0-9a-f]{12}'; }
TOC_ID="$(tr_fn "$TOC" board_identity)"
chk "every clone of a board shares its identity" "yes" "$(is_bid "$BID" && [ "$TOC_ID" = "$BID" ] && echo yes || echo no)"
TOD="$(mktemp -d)/draft"
mkdir -p "$(dirname "$TOD")" && cp -R "$TO" "$TOD" && mkdir -p "$TOD/drafts" && cp -R "$TOD/.agents" "$TOD/drafts/"
TOD_ID="$(cd "$TOD/drafts" && HANDOFF_NO_MAIN=1 . ./.agents/handoff/handoff && DIR="$PWD/.agents/handoff" && board_identity 2>&1)"
chk "a board at another path in the same repository is a different board" "yes" \
  "$(is_bid "$TOD_ID" && is_bid "$BID" && [ "$TOD_ID" != "$BID" ] && echo yes || echo no)"
trh "$TO" new o-one --title "Owned" > /dev/null
trh "$TO" mirror > /dev/null
chk "the marker carries the board identity" "1" "$(fq "len(by('<!-- handoff:$BID/o-one-handoff -->'))")"

TF="$(mkboard)"
tr_cfg "$TF/.agents/handoff" "$LEG_CFG"
trh "$TF" new o-two --title "Foreign" > /dev/null
CREATES_BEFORE="$(fq "calls('create')")"
FOREIGN_OUT="$(trh "$TF" mirror)"
chk_contains "a second board mirroring the same tracker is refused" "$FOREIGN_OUT" "another board ($BID)"
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
chk_contains "a home with no tracker is named, not sent" "$PASS_OUT" "r-lib-handoff — home acme-lib has no issue tracker"
chk "the sprint tracker is never a pass" "0" "$(fq "calls('list', 'acme/plan')")"

LIST_API_BEFORE="$(fq "calls('list', 'acme/acme-api')")"
LIST_WEB_BEFORE="$(fq "calls('list', 'acme/acme-web')")"
trh "$TP" mirror --repo acme-web > /dev/null
chk "--repo limits the run to one tracker" "$LIST_API_BEFORE" "$(fq "calls('list', 'acme/acme-api')")"
chk "--repo still runs the tracker it names" "yes" "$([ "$(fq "calls('list', 'acme/acme-web')")" -gt "$LIST_WEB_BEFORE" ] && echo yes || echo no)"
chk_contains "--repo refuses an alias with no issue tracker" "$(trh "$TP" mirror --repo acme-lib)" "--repo acme-lib has no issue tracker"

# A pass for one tracker never closes another tracker's issues.
trh "$TP" claim r-web "closing" > /dev/null
trh "$TP" release r-web --status done --verified-by "checked src/web.ts:12 by hand in test" > /dev/null
trh "$TP" mirror --repo acme-api > /dev/null
chk "the api pass leaves the web issue open" "open" "$(fq "[i for i in in_repo('acme/acme-web') if 'r-web-handoff' in i['body']][0]['state']")"
trh "$TP" mirror > /dev/null
chk "the web pass closes it" "closed" "$(fq "[i for i in in_repo('acme/acme-web') if 'r-web-handoff' in i['body']][0]['state']")"

# Public: checked for every tracker before anything is sent. A fresh tracker state: acme-api
# already carries TP's issues, and a second board mirroring into it is refused by design.
ST_SAVE="$ST"
ST="$(mktemp -d)/tracker.json"
TQ="$(mkboard)"
tr_cfg "$TQ/.agents/handoff" "$TRACKERS_CFG"
trh "$TQ" new q-api --title "Q api" --audience acme-api > /dev/null
trh "$TQ" new q-web --title "Q web" --audience acme-web > /dev/null
git -C "$TQ" add -A && git -C "$TQ" commit -qm "docs"
CREATES_BEFORE="$(fq "calls('create')")"
PUB_OUT="$(cd "$TQ" && HANDOFF_TRACKER_ADAPTER="$SRC/fake-tracker.sh" FAKE_TRACKER_STATE="$ST" \
  FAKE_TRACKER_PUBLIC_REPOS="acme/acme-api" ./.agents/handoff/handoff mirror 2>&1)"
chk_contains "a public tracker without allowPublic refuses the run" "$PUB_OUT" "acme/acme-api is public"
chk "and nothing is sent to any tracker" "$CREATES_BEFORE" "$(fq "calls('create')")"
(cd "$TQ" && HANDOFF_TRACKER_ADAPTER="$SRC/fake-tracker.sh" FAKE_TRACKER_STATE="$ST" \
  FAKE_TRACKER_PUBLIC_REPOS="acme/acme-web" ./.agents/handoff/handoff mirror > /dev/null 2>&1)
chk "a public tracker with allowPublic sends only share: public docs" "0" \
  "$(fq "len([i for i in in_repo('acme/acme-web') if 'q-web-handoff' in i['body']])")"
chk "the private tracker is unaffected" "1" "$(fq "len([i for i in in_repo('acme/acme-api') if 'q-api-handoff' in i['body']])")"
ST="$ST_SAVE"

# Schema gate: routing needs home.
TS="$(mkboard)"
tr_cfg "$TS/.agents/handoff" "$(printf '%s' "$TRACKERS_CFG" | sed 's/"schema": 4/"schema": 3/')"
chk_contains "a trackers board below schema 4 refuses and names migrate" "$(trh "$TS" mirror)" "routing by home needs schema 4"

printf '\nsummary projection by default, and the audience label (ADR 0017)\n'
ST_SAVE="$ST"
ST="$(mktemp -d)/tracker.json"
TJ="$(mkboard)"
TJB="$TJ/.agents/handoff"
tr_cfg "$TJB" "$(printf '%s' "$TRACKERS_CFG" | sed 's#"repo": "acme/acme-web", #"repo": "acme/acme-web", "projection": "full", #')"
trh "$TJ" new j-api --title "Proj api" --audience acme-api > /dev/null
trh "$TJ" new j-web --title "Proj web" --audience acme-web > /dev/null
for d in j-api j-web; do
  python3 - "$TJB/$d-handoff.md" << 'PY'
import sys
p = sys.argv[1]
t = open(p).read()
for head, text in (("## Current state\n", "STATE-TEXT"), ("## Context\n", "CONTEXT-TEXT"), ("## Verify\n", "VERIFY-TEXT")):
    assert head in t, head
    t = t.replace(head, head + "\n" + text + "\n", 1)
t = t.rstrip("\n") + "\n\n## Ruled out\n\nRULED-OUT-TEXT\n"
open(p, "w").write(t)
PY
done
git -C "$TJ" add -A && git -C "$TJ" commit -qm "docs"
trh "$TJ" mirror > /dev/null
API_BODY="$(fq "[i for i in in_repo('acme/acme-api') if 'j-api-handoff' in i['body']][0]['body']")"
WEB_BODY="$(fq "[i for i in in_repo('acme/acme-web') if 'j-web-handoff' in i['body']][0]['body']")"
chk_contains "summary sends Current state" "$API_BODY" "STATE-TEXT"
chk "summary omits Context" "no" "$(has "$API_BODY" CONTEXT-TEXT)"
chk "summary omits Verify" "no" "$(has "$API_BODY" VERIFY-TEXT)"
chk_contains "full sends Context" "$WEB_BODY" "CONTEXT-TEXT"
chk_contains "full sends Verify" "$WEB_BODY" "VERIFY-TEXT"
chk "Ruled out never leaves the board" "no" "$(has "$WEB_BODY$API_BODY" RULED-OUT-TEXT)"
chk "the audience is a label" "True" "$(fq "'audience:acme-api' in [i for i in in_repo('acme/acme-api') if 'j-api-handoff' in i['body']][0]['labels']")"

# An audience flip relabels the same issue; it never moves.
J_NUM="$(fq "[i for i in in_repo('acme/acme-api') if 'j-api-handoff' in i['body']][0]['number']")"
python3 -c 'import sys
p = sys.argv[1]
t = open(p).read()
assert "\naudience: acme-api\n" in t
open(p, "w").write(t.replace("\naudience: acme-api\n", "\naudience: acme-web\n", 1))' "$TJB/j-api-handoff.md"
git -C "$TJ" add -A && git -C "$TJ" commit -qm "flip"
trh "$TJ" mirror > /dev/null
chk "the flipped handoff keeps its issue" "$J_NUM" "$(fq "[i for i in in_repo('acme/acme-api') if 'j-api-handoff' in i['body']][0]['number']")"
chk "and gains the new audience label" "True" "$(fq "'audience:acme-web' in [i for i in in_repo('acme/acme-api') if 'j-api-handoff' in i['body']][0]['labels']")"
chk "the old audience label is gone" "False" "$(fq "'audience:acme-api' in [i for i in in_repo('acme/acme-api') if 'j-api-handoff' in i['body']][0]['labels']")"
chk "no issue appears in the audience's tracker" "0" "$(fq "len([i for i in in_repo('acme/acme-web') if 'j-api-handoff' in i['body']])")"
ST="$ST_SAVE"

printf '\n--ref, export --to-issue and import follow the home (ADR 0017)\n'
ST_SAVE="$ST"
ST="$(mktemp -d)/tracker.json"
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
ST="$ST_SAVE"

printf '\nthe verifier checks trackers and homes offline (ADR 0017)\n'
VERIFY="$HERE/../verify-setup-handoff.sh"
vids() { # repo -> "level:id" for every finding
  bash "$VERIFY" "$1" --json 2> /dev/null | python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: raise SystemExit(0)
for f in d.get("findings", []): print("%s:%s" % (f["level"], f["id"]))'
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
chk "the verifier reached its document checks (so the ids below are not vacuous)" "yes" "$(has "$VIDS" "doc.")"
chk_contains "mixed owners warn" "$VIDS" "warn:board.trackers.owner"
chk_contains "a tracker keyed by an unregistered alias warns" "$VIDS" "warn:board.trackers.unknown-alias"
chk_contains "a doc with no home warns" "$VIDS" "warn:doc.home.missing"
chk_contains "a doc homed at an unregistered alias warns" "$VIDS" "warn:doc.home.unregistered"
chk "the trackers key is recognised" "no" "$(has "$VIDS" "warn:board.config.unknown_keys")"
TW="$(mkboard)"
tr_cfg "$TW/.agents/handoff" '{ "topology": "cross-repo", "schema": 4, "external": { "kind": "issues", "system": "github", "repo": "acme/board", "refPattern": "#[0-9]+" } }'
chk_contains "external on a cross-repo board is legacy" "$(vids "$TW")" "warn:board.external.legacy"

printf '\nwhat a board identity refuses to guess, and what a reference may still point at (ADR 0017)\n'
ST_SAVE="$ST"
ST="$(mktemp -d)/tracker.json"
# A SHALLOW clone reports the commit it fetched as the repository's root, so an identity derived
# from it changes after every push — which is how a CI mirror would refuse the tracker its own
# previous run had written. The board says so instead of guessing.
TSH_SRC="$(mkboard)"
tr_cfg "$TSH_SRC/.agents/handoff" '{ "external": { "kind": "issues", "system": "github", "repo": "acme/shallow", "refPattern": "#[0-9]+" } }'
trh "$TSH_SRC" new s-one --title "Shallow work" > /dev/null
git -C "$TSH_SRC" add -A && git -C "$TSH_SRC" commit -qm "docs"
TSH="$(mktemp -d)/clone"
git clone -q --depth 1 "file://$TSH_SRC" "$TSH"
chk "the fixture really is shallow (so the refusal below is not vacuous)" "true" "$(git -C "$TSH" rev-parse --is-shallow-repository)"
SHALLOW_CREATES="$(fq "calls('create')")"
chk_contains "a shallow board refuses to mirror rather than mint a drifting identity" \
  "$(trh "$TSH" mirror)" "shallow clone"
chk "and sends nothing" "$SHALLOW_CREATES" "$(fq "calls('create')")"
chk "a full clone of the same board still mirrors" "yes" \
  "$(trh "$TSH_SRC" mirror > /dev/null && echo yes || echo no)"

# A standalone doc carries no home, but a REFERENCE is a pointer, not a projection: it is checked
# against every tracker the board declares. Losing that would take ADR 0011's level 1 away from
# reference docs the moment a board moved to per-repository trackers.
TRF="$(mkboard)"
TRFB="$TRF/.agents/handoff"
tr_cfg "$TRFB" "$TRACKERS_CFG"
trh "$TRF" new r-ref --standalone --title "Reference" --ref "#31" > /dev/null
chk "a standalone doc may still point at a ticket" "#31" "$(sed -n 's/^external_ref: //p' "$TRFB/r-ref-handoff.md" | tr -d '"')"
trh "$TRF" new r-plan --standalone --title "Sprint reference" --ref "PLAN-9" > /dev/null
chk "including one in the board's sprint tool" "PLAN-9" "$(sed -n 's/^external_ref: //p' "$TRFB/r-plan-handoff.md" | tr -d '"')"
chk_contains "but not a reference no declared tracker would take" \
  "$(trh "$TRF" new r-bad --standalone --title "Bad" --ref "nonsense ref")" "does not match"

# A home taken from the environment is a deliberate identity, not free text. It never refuses the
# write, but the person running the command has not seen it, so it is said out loud.
TEV="$(mkboard)"
TEVB="$TEV/.agents/handoff"
tr_cfg "$TEVB" "$TRACKERS_CFG"
EV_OUT="$(cd "$TEV" && HANDOFF_REPO=acme-typo HANDOFF_TRACKER_ADAPTER="$SRC/fake-tracker.sh" \
  FAKE_TRACKER_STATE="$ST" ./.agents/handoff/handoff new e-one --title "Typo home" --audience acme-api 2>&1)"
chk_contains "an unregistered home from the environment is named" "$EV_OUT" "acme-typo"
chk "but the doc is still written" "acme-typo" "$(sed -n 's/^home: //p' "$TEVB/e-one-handoff.md")"
ST="$ST_SAVE"

printf '\ntracker rules synthesize a per-repository entry from a group (ADR 0020)\n'
RULES_CFG='{ "topology": "cross-repo", "schema": 4,
  "groups": ["fleet"],
  "_generated": { "repos": [
    { "alias": "acme-api", "group": "fleet", "origin": "github.com/acme/acme-api" },
    { "alias": "acme-web", "group": "fleet", "origin": "github.com/acme/acme-web" },
    { "alias": "acme-noorigin", "group": "fleet" },
    { "alias": "acme-lab", "group": "fleet", "origin": "gitlab.com/acme/acme-lab" } ] },
  "trackerRules": { "fleet": { "kind": "issues", "system": "github", "projection": "summary" } } }'
TRU="$(mkboard)"
TRUB="$TRU/.agents/handoff"
tr_cfg "$TRUB" "$RULES_CFG"
chk "trackerRules alone puts the board in trackers mode" "trackers" "$(tr_fn "$TRU" tracker_mode)"
chk "a rule synthesizes repo for a registered member" "acme/acme-api" "$(tr_fn "$TRU" 'CUR_TRACKER=acme-api; tracker_setting repo')"
chk "refPattern defaults for a synthesized issues entry" "#[0-9]+" "$(tr_fn "$TRU" 'CUR_TRACKER=acme-api; tracker_setting refPattern')"
chk "a second member under the same rule needs no config" "acme/acme-web" "$(tr_fn "$TRU" 'CUR_TRACKER=acme-web; tracker_setting repo')"
chk "a member with no recorded origin resolves to nothing" "" "$(tr_fn "$TRU" 'CUR_TRACKER=acme-noorigin; tracker_setting repo')"
# A rule names a SYSTEM, and a member's origin names a HOST. A GitLab member under a github rule must
# never have its path reused as a GitHub repository — that would mirror into whatever repository
# happens to hold the same path on a host the member does not live on.
chk "a member whose origin is on another host than the rule's system resolves to nothing" "" \
  "$(tr_fn "$TRU" 'CUR_TRACKER=acme-lab; tracker_setting repo')"
chk "mirror aliases include every registered member with a rule and a matching origin" "acme-api acme-web" "$(tr_fn "$TRU" tracker_aliases | tr '\n' ' ' | sed 's/ $//')"

printf '\nmirror --dry-run plans through a rule-derived tracker; a second member needs no config (ADR 0020)\n'
# A fresh tracker state: acme/acme-api and acme/acme-web already carry issues mirrored by OTHER
# boards earlier in this suite (a different board id), and a second board's pass into the same
# repo is refused by design (ADR 0017) — exactly what the "Public" block above isolates against.
ST_SAVE="$ST"
ST="$(mktemp -d)/tracker.json"
trh "$TRU" new u-api --title "Api" --audience acme-api > /dev/null
trh "$TRU" new u-web --title "Web" --audience acme-web > /dev/null
trh "$TRU" new u-none --title "No origin" --audience acme-noorigin > /dev/null
git -C "$TRU" add -A && git -C "$TRU" commit -qm "docs"
DRY_OUT="$(trh "$TRU" mirror --dry-run)"
chk_contains "the dry run plans an issue for the first member" "$DRY_OUT" "create u-api-handoff"
chk_contains "and for the second member, added under the same rule with no config change" "$DRY_OUT" "create u-web-handoff"
chk_contains "a member with no origin is named, never silently dropped" "$DRY_OUT" "u-none-handoff — home acme-noorigin has no issue tracker"
ST="$ST_SAVE"

printf '\na per-repository entry overrides its group rule for that member only (ADR 0020)\n'
OVERRIDE_CFG='{ "topology": "cross-repo", "schema": 4,
  "groups": ["fleet"],
  "_generated": { "repos": [
    { "alias": "acme-api", "group": "fleet", "origin": "github.com/acme/acme-api" },
    { "alias": "acme-web", "group": "fleet", "origin": "github.com/acme/acme-web" } ] },
  "trackers": { "acme-api": { "kind": "issues", "system": "github", "repo": "override/acme-api", "refPattern": "TIX-[0-9]+" } },
  "trackerRules": { "fleet": { "kind": "issues", "system": "github" } } }'
TOV="$(mkboard)"
tr_cfg "$TOV/.agents/handoff" "$OVERRIDE_CFG"
chk "the per-repo entry wins for the member it names" "override/acme-api" "$(tr_fn "$TOV" 'CUR_TRACKER=acme-api; tracker_setting repo')"
chk "and keeps its own refPattern, not the rule default" "TIX-[0-9]+" "$(tr_fn "$TOV" 'CUR_TRACKER=acme-api; tracker_setting refPattern')"
chk "the rule still applies to the member it does not name" "acme/acme-web" "$(tr_fn "$TOV" 'CUR_TRACKER=acme-web; tracker_setting repo')"

printf '\nallowPublic is never part of a rule — mirror refuses, naming the group (ADR 0020)\n'
PUB_RULE_CFG='{ "topology": "cross-repo", "schema": 4,
  "groups": ["fleet"],
  "_generated": { "repos": [ { "alias": "acme-api", "group": "fleet", "origin": "github.com/acme/acme-api" } ] },
  "trackerRules": { "fleet": { "kind": "issues", "system": "github", "allowPublic": true } } }'
TPR="$(mkboard)"
tr_cfg "$TPR/.agents/handoff" "$PUB_RULE_CFG"
trh "$TPR" new p-one --title "One" --audience acme-api > /dev/null
git -C "$TPR" add -A && git -C "$TPR" commit -qm "docs"
PR_CREATES_BEFORE="$(fq "calls('create')")"
PR_OUT="$(trh "$TPR" mirror)"
chk_contains "mirror refuses a rule that sets allowPublic, naming the group" "$PR_OUT" "fleet"
chk_contains "and cites ADR 0020" "$PR_OUT" "ADR 0020"
chk "nothing was sent" "$PR_CREATES_BEFORE" "$(fq "calls('create')")"
DRY_PR_OUT="$(trh "$TPR" mirror --dry-run)"
chk_contains "a dry run refuses too, before anything is planned" "$DRY_PR_OUT" "fleet"

printf '\na rule-derived tracker on a public repo still needs a per-repository opt-in (ADR 0013, ADR 0020)\n'
ST_SAVE="$ST"
ST="$(mktemp -d)/tracker.json"
PUBM_CFG='{ "topology": "cross-repo", "schema": 4, "groups": ["fleet"],
  "_generated": { "repos": [ { "alias": "acme-api", "group": "fleet", "origin": "github.com/acme/acme-api" } ] },
  "trackerRules": { "fleet": { "kind": "issues", "system": "github" } } }'
TPM="$(mkboard)"
tr_cfg "$TPM/.agents/handoff" "$PUBM_CFG"
trh "$TPM" new m-one --title "One" --audience acme-api > /dev/null
git -C "$TPM" add -A && git -C "$TPM" commit -qm "docs"
CREATES_BEFORE="$(fq "calls('create')")"
PUBM_OUT="$(cd "$TPM" && HANDOFF_TRACKER_ADAPTER="$SRC/fake-tracker.sh" FAKE_TRACKER_STATE="$ST" \
  FAKE_TRACKER_PUBLIC_REPOS="acme/acme-api" ./.agents/handoff/handoff mirror 2>&1)"
chk_contains "a public repo under a bare rule refuses — no allowPublic anywhere" "$PUBM_OUT" "acme/acme-api is public"
chk "nothing is sent" "$CREATES_BEFORE" "$(fq "calls('create')")"

# The same repo, with a per-repository entry that opts in AND a doc marked share: public.
PUBM_CFG2='{ "topology": "cross-repo", "schema": 4, "groups": ["fleet"],
  "_generated": { "repos": [ { "alias": "acme-api", "group": "fleet", "origin": "github.com/acme/acme-api" } ] },
  "trackers": { "acme-api": { "kind": "issues", "system": "github", "repo": "acme/acme-api", "refPattern": "#[0-9]+", "allowPublic": true } },
  "trackerRules": { "fleet": { "kind": "issues", "system": "github" } } }'
tr_cfg "$TPM/.agents/handoff" "$PUBM_CFG2"
trh "$TPM" new m-pub --title "Public" --audience acme-api --share public > /dev/null
git -C "$TPM" add -A && git -C "$TPM" commit -qm "share"
(cd "$TPM" && HANDOFF_TRACKER_ADAPTER="$SRC/fake-tracker.sh" FAKE_TRACKER_STATE="$ST" \
  FAKE_TRACKER_PUBLIC_REPOS="acme/acme-api" ./.agents/handoff/handoff mirror > /dev/null 2>&1)
chk "a per-repo allowPublic plus a doc marked share: public is sent" "1" \
  "$(fq "len([i for i in in_repo('acme/acme-api') if 'm-pub-handoff' in i['body']])")"
ST="$ST_SAVE"

printf '\nthe one-owner check applies to rule-derived trackers too (ADR 0011, ADR 0017, ADR 0020)\n'
OWNER_CFG='{ "topology": "cross-repo", "schema": 4, "groups": ["fleet"],
  "_generated": { "repos": [
    { "alias": "acme-api", "group": "fleet", "origin": "github.com/acme/acme-api" },
    { "alias": "zeta-web", "group": "fleet", "origin": "github.com/zeta/acme-web" } ] },
  "trackerRules": { "fleet": { "kind": "issues", "system": "github" } } }'
TOW="$(mkboard)"
tr_cfg "$TOW/.agents/handoff" "$OWNER_CFG"
OWNER_OUT="$(tr_fn "$TOW" trackers_trust_check)"
chk_contains "a member whose origin belongs to another owner refuses, naming acme" "$OWNER_OUT" "github.com/acme"
chk_contains "and naming zeta" "$OWNER_OUT" "github.com/zeta"

printf '\nthe verifier checks tracker rules offline (ADR 0020)\n'
TVR="$(mkboard)"
tr_cfg "$TVR/.agents/handoff" '{ "topology": "cross-repo", "schema": 4, "groups": ["fleet"],
  "_generated": { "repos": [ { "alias": "acme-api", "group": "fleet", "origin": "github.com/acme/acme-api" } ] },
  "trackerRules": { "fleet": { "kind": "issues", "system": "github", "allowPublic": true }, "ghost": { "kind": "issues", "system": "github" }, "bad": "not-an-object" } }'
VIDS_R="$(vids "$TVR")"
chk_contains "a rule with allowPublic fails" "$VIDS_R" "fail:board.trackerRules.allowPublic"
chk_contains "a rule naming an undeclared group warns" "$VIDS_R" "warn:board.trackerRules.group"
chk_contains "a malformed rule fails shape" "$VIDS_R" "fail:board.trackerRules.shape"
chk "trackerRules is a recognised config key" "no" "$(has "$VIDS_R" "warn:board.config.unknown_keys")"

printf '\n--- %d passed, %d failed ---\n' "$P" "$F"
[ "$F" -eq 0 ]
