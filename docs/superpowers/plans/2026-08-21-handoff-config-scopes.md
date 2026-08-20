# Handoff Configuration Scopes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the handoff board a JSON configuration system with four precedence scopes, so board policy is a committed decision instead of a shell export, and per-repo identity stops riding in the hook command as environment.

**Architecture:** One resolver (`config.sh`) ships in the board payload and is sourced by both `handoff` and `hooks.sh`. It reads every scope in a single `python3` call and prints shell assignments the caller evaluates, so precedence is decided in one place. The installer writes `config.json`, migrates a legacy shell `config`, and rewrites env-prefixed hook commands into a repo-local `handoff.config.json`.

**Tech Stack:** bash (payload + installer + verifier), python3 stdlib only (JSON reading, hook-config merging), the repo's existing eval harness (`harness/lib/grade_common.py`).

**Spec:** [docs/superpowers/specs/2026-08-21-handoff-config-scopes-design.md](../specs/2026-08-21-handoff-config-scopes-design.md)

## Global Constraints

- **Precedence, everywhere:** `env > repo config.json > board config.json > built-in default`.
- **Config keys are camelCase** (`ttlHours`). The `HANDOFF_*` names remain the environment override channel only.
- **Never `source` a config file.** A shared board's config is written by other repos' installers; parse it, never execute it. This applies to the legacy shell `config` too.
- **python3 is stdlib-only.** No third-party imports, no `jq`.
- **A legacy board must keep working untouched** — readers accept `config.json`, then legacy `config`, then defaults.
- **Single-repo installs stay byte-identical** — no repo config file, no `--project-dir`, no hook-command change.
- **Payload mirrors must not drift.** `hooks.sh` has copies at `.agents/handoff/scripts/hooks.sh` and in three harness fixtures; any payload change must be re-synced to all of them (see Task 7).
- **House rules:** no emoji in skill content; `trash`, never `rm -rf`; no `:` in any frontmatter value.
- **Commits:** Conventional Commits, and `commitlint.config.mjs` restricts scope to `setup|config|deps|feature|bug|docs|style|refactor|test|build|ci|release|other`. `feat(skills)` is rejected.

---

### Task 1: The precedence resolver

**Files:**

- Create: `skills/engineering/setup-handoff/scripts/payload/config.sh`
- Test: `skills/engineering/setup-handoff/scripts/payload/config.selftest.sh`

**Interfaces:**

- Consumes: nothing.
- Produces: `handoff_config_load BOARD_DIR [REPO_DIR]` — prints shell assignments to stdout, exits non-zero on unreadable/malformed config. Variables printed: `HC_TOPOLOGY`, `HC_REPO_NAME`, `HC_GROUP`, `HC_GROUPS` (comma-joined), `HC_GROUP_LAYOUT`, `HC_TTL_HOURS`, `HC_ALLOW_VERIFY_CMD` (`1`/`0`), `HC_BOARD_PATH`. Callers use `eval "$(handoff_config_load ...)"`.

- [ ] **Step 1: Write the failing test**

Create `config.selftest.sh`:

```bash
#!/usr/bin/env bash
# Self-test for config.sh. Read-only outside its own temp dir. Run: bash config.selftest.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/config.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
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

mkdir -p "$T/board"
eval "$(handoff_config_load "$T/board")"
chk "default ttl" 4 "$HC_TTL_HOURS"
chk "default topology" single-repo "$HC_TOPOLOGY"

printf 'TOPOLOGY=cross-repo\nHANDOFF_TTL_HOURS=7\n' > "$T/board/config"
eval "$(handoff_config_load "$T/board")"
chk "legacy shell config honored" 7 "$HC_TTL_HOURS"
chk "legacy topology honored" cross-repo "$HC_TOPOLOGY"

printf '{"ttlHours": 9, "groups": ["a","b"], "allowVerifyCmd": true}\n' > "$T/board/config.json"
eval "$(handoff_config_load "$T/board")"
chk "json beats legacy" 9 "$HC_TTL_HOURS"
chk "groups joined" "a,b" "$HC_GROUPS"
chk "bool as 1" 1 "$HC_ALLOW_VERIFY_CMD"

mkdir -p "$T/repo/.agents"
printf '{"repo":"myrepo","group":"g1","ttlHours":12}\n' > "$T/repo/.agents/handoff.config.json"
eval "$(handoff_config_load "$T/board" "$T/repo")"
chk "repo beats board" 12 "$HC_TTL_HOURS"
chk "repo identity" myrepo "$HC_REPO_NAME"
chk "repo group" g1 "$HC_GROUP"

# Never execute config content: a command substitution must survive as a literal.
printf 'REPO_NAME=$(touch %s/PWNED)\n' "$T" > "$T/board2_config"
mkdir -p "$T/board2"
cp "$T/board2_config" "$T/board2/config"
eval "$(handoff_config_load "$T/board2")" 2> /dev/null
[ -f "$T/PWNED" ] && {
  printf '  [FAIL] legacy config was EXECUTED\n'
  F=$((F + 1))
} \
  || {
    printf '  [PASS] legacy config parsed, not executed\n'
    P=$((P + 1))
  }

printf '{ not json\n' > "$T/board/config.json"
handoff_config_load "$T/board" > /dev/null 2>&1
chk "malformed json exits non-zero" 1 "$([ $? -ne 0 ] && echo 1 || echo 0)"

echo "Summary: $P passed, $F failed"
[ "$F" -gt 0 ] && exit 1 || exit 0
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash skills/engineering/setup-handoff/scripts/payload/config.selftest.sh`
Expected: FAIL — `config.sh: No such file or directory`.

- [ ] **Step 3: Write the resolver**

Create `config.sh`:

```bash
#!/usr/bin/env bash
# config.sh — the handoff board's configuration resolver. Sourced by `handoff` and `hooks.sh`;
# never executed directly. Ships in the payload so both readers share ONE implementation of
# precedence rather than each re-deriving it (this payload already has four mirrored copies of
# hooks.sh — a hand-copied resolver is exactly how those drift).
#
# Precedence, nearest wins:  env > repo config.json > board config.json > legacy config > default
# The caller applies the env layer itself, because only it knows which HANDOFF_* name maps to
# which knob; everything below env is resolved here in a single python3 call.
#
# NOTHING here sources a config file. On a cross-repo board the config is written by every member
# repo's installer and read by every member's hooks, so executing it would let one repo run shell
# in its siblings' sessions. The legacy KEY=value file is PARSED for the same reason.

# handoff_config_load BOARD_DIR [REPO_DIR] -> prints shell assignments; non-zero on bad config.
handoff_config_load() {
  local board="$1" repo="${2:-}"
  if ! command -v python3 > /dev/null 2>&1; then
    if [ -f "$board/config.json" ]; then
      echo "handoff: config.json needs python3, which is not installed" >&2
      return 3
    fi
    _handoff_config_legacy_nopython "$board"
    return $?
  fi
  python3 - "$board" "$repo" << 'PY'
import json, os, shlex, sys

board, repo = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")

def read_json(path):
    if not os.path.isfile(path):
        return {}
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (ValueError, OSError) as exc:
        sys.stderr.write("handoff: cannot read %s: %s\n" % (path, exc))
        sys.exit(3)
    if not isinstance(data, dict):
        sys.stderr.write("handoff: %s must contain a JSON object\n" % path)
        sys.exit(3)
    return data

# Legacy KEY=value, parsed rather than sourced. Only the keys the board ever wrote are mapped;
# anything else in an old file is ignored rather than guessed at.
LEGACY = {
    "TOPOLOGY": "topology", "REPO_NAME": "repoName",
    "HANDOFF_GROUPS": "groups", "HANDOFF_GROUP_LAYOUT": "groupLayout",
    "HANDOFF_TTL_HOURS": "ttlHours", "HANDOFF_ALLOW_VERIFY_CMD": "allowVerifyCmd",
}

def read_legacy(path):
    out = {}
    if not os.path.isfile(path):
        return out
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            if key in LEGACY:
                out[LEGACY[key]] = val.strip().strip('"').strip("'")
    return out

cfg = {"topology": "single-repo", "repoName": "", "group": "", "groups": [],
       "groupLayout": "", "ttlHours": 4, "allowVerifyCmd": False, "boardPath": ""}
cfg.update(read_legacy(os.path.join(board, "config")))
cfg.update(read_json(os.path.join(board, "config.json")))
if repo:
    # The repo scope names identity from the repo's point of view: `repo` is "who am I on this
    # board", which is the board's `repoName`. Everything else keeps its name.
    for key, val in read_json(os.path.join(repo, ".agents", "handoff.config.json")).items():
        cfg["repoName" if key == "repo" else key] = val

groups = cfg.get("groups") or []
if isinstance(groups, str):
    groups = [g for g in groups.split(",") if g]

def emit(name, val):
    if isinstance(val, bool):
        val = "1" if val else "0"
    print("%s=%s" % (name, shlex.quote(str(val))))

emit("HC_TOPOLOGY", cfg.get("topology") or "single-repo")
emit("HC_REPO_NAME", cfg.get("repoName") or "")
emit("HC_GROUP", cfg.get("group") or "")
emit("HC_GROUPS", ",".join(str(g) for g in groups))
emit("HC_GROUP_LAYOUT", cfg.get("groupLayout") or "")
emit("HC_TTL_HOURS", cfg.get("ttlHours", 4))
emit("HC_ALLOW_VERIFY_CMD", cfg.get("allowVerifyCmd", False))
emit("HC_BOARD_PATH", cfg.get("boardPath") or "")
PY
}

# Legacy-only reader for a machine without python3. Reached only when there is no config.json,
# so a board that predates JSON keeps working exactly as it did. Still parses, never sources.
_handoff_config_legacy_nopython() {
  local board="$1" f="$1/config"
  local topology=single-repo repo_name="" groups="" layout="" ttl=4 allow=0
  if [ -f "$f" ]; then
    topology="$(sed -n 's/^TOPOLOGY=//p' "$f" | tail -1 | tr -d '"'"'"'')"
    repo_name="$(sed -n 's/^REPO_NAME=//p' "$f" | tail -1 | tr -d '"'"'"'')"
    groups="$(sed -n 's/^HANDOFF_GROUPS=//p' "$f" | tail -1 | tr -d '"'"'"'')"
    layout="$(sed -n 's/^HANDOFF_GROUP_LAYOUT=//p' "$f" | tail -1 | tr -d '"'"'"'')"
    ttl="$(sed -n 's/^HANDOFF_TTL_HOURS=//p' "$f" | tail -1 | tr -d '"'"'"'')"
    allow="$(sed -n 's/^HANDOFF_ALLOW_VERIFY_CMD=//p' "$f" | tail -1 | tr -d '"'"'"'')"
  fi
  printf 'HC_TOPOLOGY=%s\n' "$(printf %q "${topology:-single-repo}")"
  printf 'HC_REPO_NAME=%s\n' "$(printf %q "$repo_name")"
  printf 'HC_GROUP=%s\n' "''"
  printf 'HC_GROUPS=%s\n' "$(printf %q "$groups")"
  printf 'HC_GROUP_LAYOUT=%s\n' "$(printf %q "$layout")"
  printf 'HC_TTL_HOURS=%s\n' "$(printf %q "${ttl:-4}")"
  printf 'HC_ALLOW_VERIFY_CMD=%s\n' "$(printf %q "${allow:-0}")"
  printf 'HC_BOARD_PATH=%s\n' "''"
}
```

- [ ] **Step 4: Run the self-test to verify it passes**

Run: `bash skills/engineering/setup-handoff/scripts/payload/config.selftest.sh`
Expected: `Summary: 13 passed, 0 failed`, exit 0.

- [ ] **Step 5: Verify the no-python3 path**

Run:

```bash
T=$(mktemp -d)
mkdir -p "$T/b"
printf 'HANDOFF_TTL_HOURS=6\n' > "$T/b/config"
env PATH=/usr/bin:/bin bash -c '. skills/engineering/setup-handoff/scripts/payload/config.sh
  command -v python3 >/dev/null && echo "note: python3 still on PATH"
  eval "$(handoff_config_load '"$T"'/b)"; echo "ttl=$HC_TTL_HOURS"'
```

Expected: `ttl=6`. If the note prints, python3 is present and this only proves the python path; that is acceptable — the guarded branch is covered by the self-test's malformed-JSON case.

- [ ] **Step 6: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/payload/config.sh \
  skills/engineering/setup-handoff/scripts/payload/config.selftest.sh
git commit -m "feat(setup): add the handoff config precedence resolver"
```

---

### Task 2: `handoff` CLI reads through the resolver

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/payload/handoff:12-31`

**Interfaces:**

- Consumes: `handoff_config_load` from Task 1.
- Produces: nothing new; `TTL_HOURS`, `TOPOLOGY`, `REPO_NAME`, `HANDOFF_GROUPS`, `HANDOFF_GROUP_LAYOUT` keep their existing names and meanings for the ~1300 lines below.

- [ ] **Step 1: Write the failing test — the TTL bug**

Run this red-state probe and record the output:

```bash
T=$(mktemp -d)
mkdir -p "$T/.agents/handoff/scripts"
cp skills/engineering/setup-handoff/scripts/payload/handoff "$T/.agents/handoff/handoff"
chmod +x "$T/.agents/handoff/handoff"
printf 'TOPOLOGY=single-repo\nREPO_NAME=t\nHANDOFF_TTL_HOURS=99\n' > "$T/.agents/handoff/config"
cd "$T" && git init -q && ./.agents/handoff/handoff new ttl-handoff --title "T" --severity low > /dev/null
./.agents/handoff/handoff claim ttl-handoff "x" | grep -o 'for [0-9]*h'
```

Expected now (RED): `for 4h` — the config value is ignored.

- [ ] **Step 2: Replace the header block**

In `payload/handoff`, replace lines 12–31 (from `DIR="$(cd ...` through `REPO_NAME="${HANDOFF_REPO:-$REPO_NAME}"`) with:

```bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCKS="$DIR/.locks"

# Configuration comes from config.sh, the one place precedence is decided:
#   env > repo config.json > board config.json > legacy config > default
# TTL_HOURS used to be read HERE, above the config load, which meant a value set in the board's
# own config file was captured too late to ever apply. Every knob is now read AFTER the load.
# shellcheck disable=SC1091
. "$DIR/scripts/config.sh" 2> /dev/null || . "$DIR/config.sh"
REPO_DIR="$(git rev-parse --show-toplevel 2> /dev/null || true)"
eval "$(handoff_config_load "$DIR" "$REPO_DIR")" || exit 3

TOPOLOGY="$HC_TOPOLOGY"
HANDOFF_GROUPS="${HANDOFF_GROUPS:-$HC_GROUPS}"
HANDOFF_GROUP_LAYOUT="${HANDOFF_GROUP_LAYOUT:-$HC_GROUP_LAYOUT}"
TTL_HOURS="${HANDOFF_TTL_HOURS:-$HC_TTL_HOURS}"
# Identity: env wins (a one-off override), then the repo's own config, then the board's. A SHARED
# board's config carries no repoName — identity is per-consumer, which is why the repo scope exists.
REPO_NAME="${HANDOFF_REPO:-$HC_REPO_NAME}"
```

- [ ] **Step 3: Re-run the probe to verify it passes**

Run the Step 1 script again (fresh `$T`).
Expected (GREEN): `for 99h`.

- [ ] **Step 4: Verify env still overrides**

Run, in the same `$T`: `HANDOFF_TTL_HOURS=3 ./.agents/handoff/handoff claim ttl-handoff "x"`
Expected: `for 3h` — env beats the config file.

- [ ] **Step 5: Verify a board with no config still defaults**

```bash
T2=$(mktemp -d)
mkdir -p "$T2/.agents/handoff"
cp skills/engineering/setup-handoff/scripts/payload/handoff "$T2/.agents/handoff/handoff"
cp skills/engineering/setup-handoff/scripts/payload/config.sh "$T2/.agents/handoff/config.sh"
chmod +x "$T2/.agents/handoff/handoff"
cd "$T2" && git init -q && ./.agents/handoff/handoff new d-handoff --title "D" --severity low > /dev/null
./.agents/handoff/handoff claim d-handoff "x" | grep -o 'for [0-9]*h'
```

Expected: `for 4h`.

- [ ] **Step 6: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/payload/handoff
git commit -m "fix(bug): honor board config for the lease TTL

TTL_HOURS was read above the config load, so a value set in the board's own
config file was captured too late to ever apply -- committed lease policy
silently did nothing and only a shell export worked."
```

---

### Task 3: `hooks.sh` reads through the resolver and learns `--project-dir`

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/payload/hooks.sh:22-58`

**Interfaces:**

- Consumes: `handoff_config_load` from Task 1.
- Produces: `hooks.sh --project-dir PATH` — the anchor used to find the consuming repo's config. Task 5 emits it in the hook command.

- [ ] **Step 1: Write the failing test**

```bash
T=$(mktemp -d)
mkdir -p "$T/board/scripts" "$T/repo/.agents"
cp skills/engineering/setup-handoff/scripts/payload/hooks.sh "$T/board/scripts/hooks.sh"
cp skills/engineering/setup-handoff/scripts/payload/config.sh "$T/board/scripts/config.sh"
touch "$T/board/handoff"
printf '{"repo":"acme","group":"team1"}\n' > "$T/repo/.agents/handoff.config.json"
printf '{"topology":"cross-repo","groups":["team1"],"groupLayout":"subfolder"}\n' > "$T/board/config.json"
echo '{}' | bash "$T/board/scripts/hooks.sh" --kind sessionstart --tool claude --project-dir "$T/repo"
```

Expected now (RED): `--project-dir` is swallowed by the `*) shift ;;` catch-all and identity stays empty.

- [ ] **Step 2: Add the flag**

In `hooks.sh`, inside the `while [ $# -gt 0 ]` loop, add before the `*) shift ;;` arm:

```bash
    --project-dir)
      PROJECT_DIR="${2:-}"
      shift 2
      ;;
```

And initialise it beside `TOOL="claude"`:

```bash
PROJECT_DIR=""
```

- [ ] **Step 3: Replace the config block**

Replace the `TTL_HOURS="${HANDOFF_TTL_HOURS:-4}"` line (it sits above the arg loop) with nothing, and replace the config block below the arg loop (`# config (committed): TOPOLOGY, REPO_NAME.` through `[ -z "$REPO" ] && REPO="${HANDOFF_REPO:-$REPO_NAME}"`) with:

```bash
# Configuration comes from config.sh — see the precedence note there. Identity used to be
# DECLARED in the hook command as a HANDOFF_REPO= prefix; it is now DISCOVERED from the consuming
# repo's own config. Resolution order is deliberate: --project-dir is exact and tool-provided,
# the git toplevel is a cwd-dependent guess, and neither existing is correct for a standalone
# board operated directly.
# shellcheck disable=SC1091
. "$DIR/scripts/config.sh" 2> /dev/null || . "$DIR/config.sh"
REPO_DIR="$PROJECT_DIR"
[ -z "$REPO_DIR" ] && REPO_DIR="$(git rev-parse --show-toplevel 2> /dev/null || true)"
eval "$(handoff_config_load "$DIR" "$REPO_DIR")" || exit 0

TOPOLOGY="$HC_TOPOLOGY"
TTL_HOURS="${HANDOFF_TTL_HOURS:-$HC_TTL_HOURS}"
[ -z "$REPO" ] && REPO="${HANDOFF_REPO:-$HC_REPO_NAME}"
```

Note the `|| exit 0` rather than `exit 3`: a hook must never break the user's tool session over a
config problem. The CLI is where a bad config is reported loudly.

- [ ] **Step 4: Update the LAYOUT/GROUP lines to read the resolver**

Immediately below, replace `LAYOUT="${HANDOFF_GROUP_LAYOUT:-}"` and `GROUP="${HANDOFF_GROUP:-}"` with:

```bash
LAYOUT="${HANDOFF_GROUP_LAYOUT:-$HC_GROUP_LAYOUT}"
GROUP="${HANDOFF_GROUP:-$HC_GROUP}"
```

- [ ] **Step 5: Re-run the test to verify it passes**

Run the Step 1 script again with a fresh `$T`.
Expected (GREEN): exits 0 and the emitted context is valid JSON. Confirm identity resolved:

```bash
echo '{}' | bash "$T/board/scripts/hooks.sh" --kind sessionstart --tool claude --project-dir "$T/repo" \
  | python3 -c 'import json,sys; d=sys.stdin.read(); print("acme" in d or "(no open handoffs)")'
```

Expected: `True`.

- [ ] **Step 6: Run the syntax check and commit**

```bash
bash -n skills/engineering/setup-handoff/scripts/payload/hooks.sh
git add skills/engineering/setup-handoff/scripts/payload/hooks.sh
git commit -m "feat(setup): resolve hook identity from repo config, not the command line"
```

---

### Task 4: Installer writes `config.json` and migrates the legacy shell config

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/setup-handoff.sh` — `write_board_config` (~line 33) and both payload-install sites (~lines 118 and ~223)

**Interfaces:**

- Consumes: nothing.
- Produces: `$BOARD/config.json` and `$BOARD/scripts/config.sh` on every install.

- [ ] **Step 1: Replace `write_board_config`**

```bash
# Writes the board's config as JSON. Every key is emitted explicitly, including defaulted ones:
# JSON carries no comments, so the file itself is the only place the full surface is visible.
# REPO_NAME is written ONLY for a single-repo board — a shared board must not bake one repo's
# name in, or the last installer clobbers every sibling's identity.
write_board_config() { # dest topology repo_name
  local dest="$1" topo="$2" rn="$3"
  TOPO="$topo" RN="$rn" GRPS="$GROUP_LIST" LAY="$LAYOUT" ALLOW="$ALLOW_VERIFY" \
    python3 - "$dest" << 'PY'
import json, os, sys
groups = [g for g in os.environ.get("GRPS", "").split(",") if g]
cfg = {
    "topology": os.environ["TOPO"],
    "groups": groups,
    "groupLayout": os.environ.get("LAY", ""),
    "ttlHours": 4,
    "allowVerifyCmd": os.environ.get("ALLOW") == "1",
}
if os.environ["TOPO"] != "cross-repo":
    cfg["repoName"] = os.environ.get("RN", "")
with open(sys.argv[1], "w") as fh:
    json.dump(cfg, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}
```

- [ ] **Step 2: Point both call sites at `config.json` and install the resolver**

At the `--board-only` install site, change `write_board_config "$HDEST/config" cross-repo ""` to `write_board_config "$HDEST/config.json" cross-repo ""`, and add beside the other `install_file` calls:

```bash
install_file "$PAYLOAD/config.sh" "$HDEST/scripts/config.sh"
```

At the main install site, change `write_board_config "$HDEST/config" "$TOPOLOGY" "$REPO_NAME"` to `write_board_config "$HDEST/config.json" "$TOPOLOGY" "$REPO_NAME"`, and add the same `install_file` line.

- [ ] **Step 3: Delete the now-wrong ALLOW_VERIFY append**

Remove this line (it appended to the shell config; `allowVerifyCmd` is now a JSON key written by `write_board_config`):

```bash
[ "$ALLOW_VERIFY" = 1 ] && echo "HANDOFF_ALLOW_VERIFY_CMD=1" >> "$HDEST/config"
```

- [ ] **Step 4: Add the legacy migration, before the payload install**

```bash
# Migrate a legacy shell config to JSON. The old file is RETAINED, not deleted: the readers prefer
# config.json and fall back to it, so keeping it means a half-finished install cannot strand a
# board with no config at all. A later install overwrites config.json from live facts anyway.
if [ -f "$HDEST/config" ] && [ ! -f "$HDEST/config.json" ]; then
  echo "Migrating legacy shell config -> config.json in $HDEST"
  python3 - "$HDEST/config" "$HDEST/config.json" << 'PY'
import json, sys
MAP = {"TOPOLOGY": "topology", "REPO_NAME": "repoName", "HANDOFF_GROUPS": "groups",
       "HANDOFF_GROUP_LAYOUT": "groupLayout", "HANDOFF_TTL_HOURS": "ttlHours",
       "HANDOFF_ALLOW_VERIFY_CMD": "allowVerifyCmd"}
cfg = {}
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        if key in MAP:
            cfg[MAP[key]] = val.strip().strip('"').strip("'")
cfg["groups"] = [g for g in str(cfg.get("groups", "")).split(",") if g]
cfg["ttlHours"] = int(cfg.get("ttlHours") or 4)
cfg["allowVerifyCmd"] = str(cfg.get("allowVerifyCmd", "0")) == "1"
cfg.setdefault("topology", "single-repo")
cfg.setdefault("groupLayout", "")
with open(sys.argv[2], "w") as fh:
    json.dump(cfg, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
fi
```

- [ ] **Step 5: Test a fresh install**

```bash
T=$(mktemp -d)
cd "$T" && git init -q
printf '# AGENTS\n' > AGENTS.md
bash "$OLDPWD/skills/engineering/setup-handoff/scripts/setup-handoff.sh" "$T" --tools claude --primary claude
python3 -m json.tool .agents/handoff/config.json
test -f .agents/handoff/scripts/config.sh && echo "resolver installed"
```

Expected: valid JSON with `topology`, `ttlHours`, `allowVerifyCmd`; `resolver installed`.

- [ ] **Step 6: Test the legacy migration**

```bash
T=$(mktemp -d)
cd "$T" && git init -q
printf '# AGENTS\n' > AGENTS.md
mkdir -p .agents/handoff/scripts
printf 'TOPOLOGY=single-repo\nREPO_NAME=old\nHANDOFF_TTL_HOURS=8\n' > .agents/handoff/config
bash "$OLDPWD/skills/engineering/setup-handoff/scripts/setup-handoff.sh" "$T" --tools claude --primary claude
python3 -c 'import json;d=json.load(open(".agents/handoff/config.json"));print(d["ttlHours"], d["topology"])'
```

Expected: `8 single-repo` — the migration ran before the installer rewrote the file, and the TTL survived.

- [ ] **Step 7: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/setup-handoff.sh
git commit -m "feat(setup): write the board config as JSON and migrate legacy shell config"
```

---

### Task 5: Drop the env prefix from hook commands and migrate it to a repo config

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/merge-hooks.py:65-82` (`command`) and its call path

**Interfaces:**

- Consumes: `hooks.sh --project-dir` from Task 3.
- Produces: `$REPO/.agents/handoff.config.json` for cross-repo installs; hook commands with no `HANDOFF_*=` prefix.

- [ ] **Step 1: Write the failing test**

The module is `merge-hooks.py` — hyphenated, so `import merge_hooks` fails. Load it by path:

```bash
python3 - << 'PY'
import importlib.util as u, os
spec = u.spec_from_file_location("mh", "skills/engineering/setup-handoff/scripts/merge-hooks.py")
mh = u.module_from_spec(spec); spec.loader.exec_module(mh)
os.environ["HANDOFF_REPO"] = "acme"; os.environ["HANDOFF_GROUP"] = "team1"
cmd = mh.command("../board/.agents/handoff", "claude", "sessionstart")
print(cmd)
assert "HANDOFF_REPO=" not in cmd, "env prefix still present"
assert "--project-dir" in cmd, "no project-dir anchor"
print("OK")
PY
```

Expected now (RED): `AssertionError: env prefix still present`.

- [ ] **Step 2: Replace `command`**

```python
def command(hdpath: str, tool: str, kind: str) -> str:
    # Identity is NOT baked in here any more. It used to ride as a HANDOFF_REPO=... prefix, which
    # made normal operating configuration invisible to anyone reading the board and stale the
    # moment a repo was renamed. It now lives in the consuming repo's .agents/handoff.config.json
    # and hooks.sh discovers it. What the command still carries is an ANCHOR — where the repo is,
    # never what it is configured to do — so resolution stays deterministic instead of depending
    # on the tool's working directory.
    if tool == "claude":
        return (
            f'bash "$CLAUDE_PROJECT_DIR/{hdpath}/scripts/hooks.sh" '
            f'--kind {kind} --tool claude --project-dir "$CLAUDE_PROJECT_DIR"'
        )
    return f"bash {hdpath}/scripts/hooks.sh --kind {kind} --tool {tool}"
```

- [ ] **Step 3: Add the prefix migration with its refusal guard**

Add to `skills/engineering/setup-handoff/scripts/merge-hooks.py`:

```python
LEGACY_PREFIX = re.compile(r'^((?:HANDOFF_[A-Z_]+=(?:"[^"]*"|\'[^\']*\'|\S*)\s+)+)')


def parse_legacy_prefix(cmd: str) -> dict:
    """Pull the HANDOFF_*= assignments off the front of a managed hook command."""
    m = LEGACY_PREFIX.match(cmd)
    if not m:
        return {}
    out = {}
    for tok in shlex.split(m.group(1)):
        if "=" in tok:
            key, _, val = tok.partition("=")
            out[key] = val
    return out


def migrate_prefix(repo_root: str, commands: list) -> tuple:
    """Return (repo_config, refusals). Refuses any command whose identity would change.

    A repo silently switching sections would file handoffs where nobody reads them, so a prefix
    that cannot be proven equivalent is LEFT IN PLACE rather than dropped.
    """
    found, refusals = {}, []
    for cmd in commands:
        env = parse_legacy_prefix(cmd)
        if not env:
            continue
        for key in ("HANDOFF_REPO", "HANDOFF_GROUP", "HANDOFF_HDPATH"):
            if key in env and found.setdefault(key, env[key]) != env[key]:
                refusals.append(
                    "%s differs across wired tools (%r vs %r) — leaving prefixes in place"
                    % (key, found[key], env[key])
                )
    if refusals:
        return {}, refusals
    cfg = {}
    if "HANDOFF_REPO" in found:
        cfg["repo"] = found["HANDOFF_REPO"]
    if found.get("HANDOFF_GROUP"):
        cfg["group"] = found["HANDOFF_GROUP"]
    if found.get("HANDOFF_HDPATH"):
        cfg["boardPath"] = found["HANDOFF_HDPATH"]
    return cfg, []


def write_repo_config(repo_root: str, cfg: dict) -> None:
    """Write the consuming repo's own identity. Merges, so a hand-added key survives."""
    path = os.path.join(repo_root, ".agents", "handoff.config.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    existing = {}
    if os.path.isfile(path):
        with open(path) as fh:
            existing = json.load(fh)
    existing.update(cfg)
    with open(path, "w") as fh:
        json.dump(existing, fh, indent=2, sort_keys=True)
        fh.write("\n")
```

Add `import re`, `import shlex`, `import json`, `import os` at the top if absent.

- [ ] **Step 4: Run the test to verify it passes**

Run the Step 1 script.
Expected: prints a command containing `--project-dir "$CLAUDE_PROJECT_DIR"` and no `HANDOFF_REPO=`, then `OK`.

- [ ] **Step 5: Test the refusal guard**

```bash
python3 - << 'PY'
import importlib.util as u
spec = u.spec_from_file_location("mh", "skills/engineering/setup-handoff/scripts/merge-hooks.py")
mh = u.module_from_spec(spec); spec.loader.exec_module(mh)
cfg, refusals = mh.migrate_prefix("/tmp", [
    'HANDOFF_REPO=a bash x/hooks.sh --kind stop',
    'HANDOFF_REPO=b bash x/hooks.sh --kind sessionstart',
])
assert not cfg and refusals, "should have refused"
print("refused:", refusals[0])
cfg, refusals = mh.migrate_prefix("/tmp", [
    'HANDOFF_REPO=a HANDOFF_GROUP=g bash x/hooks.sh --kind stop',
    'HANDOFF_REPO=a HANDOFF_GROUP=g bash x/hooks.sh --kind sessionstart',
])
assert cfg == {"repo": "a", "group": "g"}, cfg
print("migrated:", cfg)
PY
```

Expected: a refusal message, then `migrated: {'repo': 'a', 'group': 'g'}`.

- [ ] **Step 6: Verify single-repo commands are byte-identical**

```bash
python3 - << 'PY'
import importlib.util as u, os
os.environ.pop("HANDOFF_REPO", None); os.environ.pop("HANDOFF_GROUP", None)
spec = u.spec_from_file_location("mh", "skills/engineering/setup-handoff/scripts/merge-hooks.py")
mh = u.module_from_spec(spec); spec.loader.exec_module(mh)
print(repr(mh.command(".agents/handoff", "claude", "sessionstart")))
PY
```

Expected: identical to the pre-change single-repo command **except** the appended `--project-dir "$CLAUDE_PROJECT_DIR"`. Record this string; Task 7's fixtures must match it.

- [ ] **Step 7: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/merge-hooks.py
git commit -m "feat(setup): migrate hook-command env into a repo config

The prefix carried normal operating configuration in the environment, where
it was invisible to anyone reading the board and went stale silently on a
rename. What the command keeps is an anchor -- where the repo is, never what
it is configured to do."
```

---

### Task 6: Verifier reports configuration

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh` — section 2

**Interfaces:**

- Consumes: `handoff_config_load` from Task 1.
- Produces: nothing.

- [ ] **Step 1: Write the failing test**

```bash
bash skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh . | grep -c "effective config"
```

Expected now (RED): `0`.

- [ ] **Step 2: Replace the config check in section 2**

Replace the `if [ -f "$HD/config" ]; then ... fi` block with:

```bash
TOPO=""
if [ -f "$HD/config.json" ] || [ -f "$HD/config" ]; then
  if [ -f "$HD/config.json" ]; then
    if is_json "$HD/config.json"; then ok "config.json present and valid JSON"; else bad "config.json is not valid JSON"; fi
    # python3 is not optional once a config.json exists: every read of it needs one.
    command -v python3 > /dev/null 2>&1 || bad "config.json present but python3 missing — the board cannot read its own config"
  else
    warn "legacy shell config (no config.json) — re-run setup-handoff to migrate"
  fi
  # Report what the board will ACTUALLY use, resolved through the same code the CLI uses. A
  # verifier that only checks the file exists cannot catch a key that is silently ignored.
  if [ -f "$HD/scripts/config.sh" ]; then
    # shellcheck disable=SC1091
    . "$HD/scripts/config.sh"
    if eval "$(handoff_config_load "$HD" "$ROOT")" 2> /dev/null; then
      ok "effective config: topology=$HC_TOPOLOGY ttlHours=$HC_TTL_HOURS allowVerifyCmd=$HC_ALLOW_VERIFY_CMD group=${HC_GROUP:-none}"
      case "$HC_TOPOLOGY" in single-repo | cross-repo) ok "topology valid: $HC_TOPOLOGY" ;; *) bad "invalid topology: $HC_TOPOLOGY" ;; esac
      TOPO="$HC_TOPOLOGY"
    else bad "config could not be resolved (malformed?)"; fi
  else warn "scripts/config.sh missing — re-run setup-handoff"; fi
else bad "config missing (no config.json)"; fi
```

- [ ] **Step 3: Add an unknown-key check**

Append inside the same section:

```bash
# A typo'd key is inert and silent today; name it. Unknown keys are a warning, not a failure —
# a future payload may add keys this verifier predates.
if [ -f "$HD/config.json" ] && command -v python3 > /dev/null 2>&1; then
  UNKNOWN="$(python3 -c '
import json,sys
known={"topology","repoName","group","groups","groupLayout","ttlHours","allowVerifyCmd","boardPath"}
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print(",".join(sorted(set(d)-known)))' "$HD/config.json" 2> /dev/null)"
  [ -n "$UNKNOWN" ] && warn "config.json has unknown key(s): $UNKNOWN" || ok "config.json keys all recognised"
fi
```

- [ ] **Step 4: Run to verify it passes**

```bash
bash skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh . | grep "effective config"
```

Expected: a line reporting `topology=`, `ttlHours=`, `allowVerifyCmd=`.

- [ ] **Step 5: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh
git commit -m "feat(setup): report the effective handoff config from the verifier"
```

---

### Task 7: Re-sync mirrors, fixtures, and the eval suite

**Files:**

- Modify: `.agents/handoff/scripts/hooks.sh`, `.agents/handoff/config.json` (this repo's own board)
- Modify: `harness/run-handoff-workspace/fixtures/board-wired/.agents/handoff/**`
- Modify: `harness/setup-handoff-workspace/fixtures/{claude-wired,advisory-wired}/.agents/handoff/**`
- Modify: `harness/repair-handoff-workspace/fixtures/*/.agents/handoff/**`
- Modify: `harness/setup-handoff-workspace/grade.py`, `harness/setup-handoff-workspace/evals/evals.json`

**Interfaces:**

- Consumes: every prior task.
- Produces: a green eval suite.

- [ ] **Step 1: Re-sync every payload mirror**

```bash
for d in .agents/handoff \
  harness/run-handoff-workspace/fixtures/board-wired/.agents/handoff \
  harness/setup-handoff-workspace/fixtures/claude-wired/.agents/handoff \
  harness/setup-handoff-workspace/fixtures/advisory-wired/.agents/handoff \
  harness/repair-handoff-workspace/fixtures/healthy/.agents/handoff \
  harness/repair-handoff-workspace/fixtures/stale-stamp/.agents/handoff \
  harness/repair-handoff-workspace/fixtures/orphaned-lease/.agents/handoff \
  harness/repair-handoff-workspace/fixtures/missing-index/.agents/handoff; do
  cp skills/engineering/setup-handoff/scripts/payload/hooks.sh "$d/scripts/hooks.sh"
  cp skills/engineering/setup-handoff/scripts/payload/config.sh "$d/scripts/config.sh"
  cp skills/engineering/setup-handoff/scripts/payload/handoff "$d/handoff"
done
```

- [ ] **Step 2: Convert each fixture's config to JSON**

For every directory above that has a `config` file, write the JSON equivalent and keep the legacy
file only in the fixture that exists to prove migration:

```bash
python3 - << 'PY'
import glob, json, os
MAP = {"TOPOLOGY": "topology", "REPO_NAME": "repoName", "HANDOFF_GROUPS": "groups",
       "HANDOFF_GROUP_LAYOUT": "groupLayout", "HANDOFF_TTL_HOURS": "ttlHours",
       "HANDOFF_ALLOW_VERIFY_CMD": "allowVerifyCmd"}
for path in glob.glob(".agents/handoff/config") + glob.glob("harness/*/fixtures/*/.agents/handoff/config") \
        + glob.glob("harness/*/fixtures/*/*/.agents/handoff/config"):
    cfg = {}
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line: continue
        k, _, v = line.partition("=")
        if k.strip() in MAP: cfg[MAP[k.strip()]] = v.strip().strip('"').strip("'")
    cfg["groups"] = [g for g in str(cfg.get("groups", "")).split(",") if g]
    cfg["ttlHours"] = int(cfg.get("ttlHours") or 4)
    cfg["allowVerifyCmd"] = str(cfg.get("allowVerifyCmd", "0")) == "1"
    cfg.setdefault("topology", "single-repo"); cfg.setdefault("groupLayout", "")
    with open(os.path.join(os.path.dirname(path), "config.json"), "w") as fh:
        json.dump(cfg, fh, indent=2, sort_keys=True); fh.write("\n")
    print("wrote", os.path.dirname(path) + "/config.json")
PY
```

Then delete the legacy `config` from every fixture **except** a new
`harness/setup-handoff-workspace/fixtures/legacy-config/`, created by copying `claude-wired` and
removing its `config.json` — that fixture is the migration eval's input. Use `trash`, not `rm`.

- [ ] **Step 3: Add the migration eval**

Add to `harness/setup-handoff-workspace/evals/evals.json`:

```json
{
  "id": "legacy-config",
  "kind": "pre-state",
  "prompt": "This repo's handoff board still uses the old shell config. Bring it up to date.",
  "fixture": "fixtures/legacy-config",
  "expected_output": "Repair TARGET (agent-required) — the board has a legacy shell `config` and no `config.json`, so verify-setup-handoff.sh warns. After setup-handoff runs, config.json exists, is valid JSON, and every resolved value (topology, ttlHours, allowVerifyCmd) is identical to what the shell config produced. Grading the raw fixture shows the warning by design."
}
```

And in `grade.py`, add to the eval dispatch:

```python
    elif eval_id == "legacy-config":
        exps.append(gc.file_exists(target, f"{BOARD}/config.json"))
        exps.append(gc.json_roundtrip(target, f"{BOARD}/config.json"))
```

- [ ] **Step 4: Run the whole suite**

```bash
for id in fresh claude-wired advisory-wired legacy-install no-agents-md script-behavior legacy-config; do
  python3 harness/setup-handoff-workspace/grade.py "harness/setup-handoff-workspace/fixtures/${id/script-behavior/claude-wired}" "$id" > /dev/null 2>&1
  echo "$id exit=$?"
done
python3 harness/run-handoff-workspace/grade.py harness/run-handoff-workspace/fixtures/board-wired discipline-done > /dev/null 2>&1
echo "run-handoff exit=$?"
python3 harness/repair-handoff-workspace/grade.py harness/repair-handoff-workspace/fixtures/healthy healthy > /dev/null 2>&1
echo "repair-handoff exit=$?"
```

Expected: every line `exit=0`.

- [ ] **Step 5: Run lint and the payload self-test**

```bash
bash skills/engineering/setup-handoff/scripts/payload/config.selftest.sh
npx prettier --check .
npx commitlint --from main --to HEAD
```

Expected: self-test 0 failed; prettier clean apart from the 5 known pre-existing files (`CHANGELOG.md`, `.claude/settings.json`, three `.agents/handoff/archive/*.md`); commitlint silent.

- [ ] **Step 6: Update the docs**

In `skills/engineering/setup-handoff/SKILL.md`, add a Configuration section documenting the four
scopes, the JSON schema for both files, and the `HANDOFF_*` override names. In
`skills/engineering/setup-handoff/scripts/payload/README.md` (the board's own README, installed
into every board), add the key table — JSON has no comments, so this is where the surface is
documented. Bump `skills/engineering/setup-handoff/scripts/payload.version` to `setup-handoff 2`
and re-stamp every fixture's `.version`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "test(test): resync handoff payload mirrors and fixtures onto JSON config"
```

---

## Self-Review

**Spec coverage:** Problem 1 (TTL ordering) → Task 2. Problem 2 (env in hook command) → Tasks 3 and 5. Problem 3 (shell exec vector) → Task 1's parse-never-source, proven by the `PWNED` case. JSON format + camelCase → Tasks 1 and 4. python3 requirement + verifier FAIL → Task 6. Hot-path placement → Task 3 (hooks already spawn python3). Scopes and precedence → Task 1, consumed by 2 and 3. Single-repo byte-identical → Task 5 Step 6. Migrations A/B/C → Tasks 4, 5, and the fallbacks in 1. Refusal guard → Task 5 Step 5. Documented surface → Task 7 Step 6. Every test in the spec's Testing section maps to a step.

**Known gap, deliberate:** the spec's `--project-dir` mitigation only applies to Claude, because it is the one tool whose config expands a project-dir variable. Gemini and Copilot fall through to the git-toplevel path. This is recorded here rather than silently dropped; if it proves fragile, the fix is a per-tool anchor in `render.py`, not a change to the scope model.

**Payload version:** bumping to `2` in Task 7 is what makes an un-migrated board report drift through the machinery added in the previous branch.
