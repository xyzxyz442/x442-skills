#!/usr/bin/env bash
# setup-delegate-agent.sh — wire a repo to delegate mechanical work to a cheaper backend.
#
#   setup-delegate-agent.sh <repo> [--profile NAME] [--tools claude,gemini,copilot] [--dry-run]
#   setup-delegate-agent.sh --write-user-manifest <path>   (bootstrap; only after the user agrees)
#
# Installs the payload into <repo>/.agents/bin/, the broker subagent into .claude/agents/, the
# consent-gate hook into each named tool's settings, and a managed routing block into AGENTS.md.
#
# Idempotent: byte-compares before writing, so a second run leaves `git status` clean.
# Never writes a credential, and never touches anything outside <repo> except the user manifest,
# and that only via --write-user-manifest.

set -euo pipefail

SKILL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="${SKILL}/assets"
PAYLOAD="${SKILL}/scripts/payload"
RESOLVER_SRC="${SKILL}/scripts/manifest/resolve.py"

die() {
  echo "setup-delegate-agent: $1" >&2
  exit "${2:-1}"
}

install_file() {
  local s="$1" d="$2"
  mkdir -p "$(dirname "$d")"
  if [ ! -f "$d" ] || ! cmp -s "$s" "$d"; then
    cp "$s" "$d"
    echo "  + $(basename "$d")"
  else
    echo "  = $(basename "$d") up to date"
  fi
}

# ------------------------------------------------------------------ bootstrap-only entry ---
if [ "${1:-}" = "--write-user-manifest" ]; then
  DEST="${2:?--write-user-manifest needs a path}"
  [ -e "$DEST" ] && die "$DEST already exists — refusing to overwrite backend config"
  mkdir -p "$(dirname "$DEST")"
  cp "${ASSETS}/delegate-backends.example.json" "$DEST"
  chmod 600 "$DEST"
  echo "wrote $DEST (mode 600) — edit it to match your backends, then re-run setup"
  exit 0
fi

REPO="${1:?usage: setup-delegate-agent.sh <repo> [--profile NAME] [--tools ...]}"
shift || true
PROFILE=""
TOOLS="claude"
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --tools)
      TOOLS="$2"
      shift 2
      ;;
    --dry-run)
      DRY=1
      shift
      ;;
    *) die "unknown option $1" ;;
  esac
done

# --------------------------------------------------------------------------- preconditions ---
REPO="$(cd "$REPO" 2> /dev/null && git rev-parse --show-toplevel 2> /dev/null)" \
  || die "not a git working tree: refusing to install (run initial-project first)"
[ -f "$REPO/AGENTS.md" ] || die "no AGENTS.md at repo root — run initial-project first; not fabricating it here"
command -v python3 > /dev/null 2>&1 || die "python3 is required" 69
command -v jq > /dev/null 2>&1 || die "jq is required (brew install jq)" 69

MISSING_TIMEOUT=0
command -v timeout > /dev/null 2>&1 || command -v gtimeout > /dev/null 2>&1 || MISSING_TIMEOUT=1

# Resolve the backend config BEFORE writing anything. A block that advertises a profile which does
# not resolve is worse than no block: it tells the agent a route exists that will fail on first use.
RESOLVED="$(python3 "$RESOLVER_SRC" --scope "$REPO" --root "$REPO" 2> /dev/null)" || {
  echo "setup-delegate-agent: no usable backend profile resolved." >&2
  python3 "$RESOLVER_SRC" --scope "$REPO" --root "$REPO" 2> /dev/null \
    | jq -r '.errors[]? | "  error: " + .' >&2 || true
  echo "  Bootstrap one with: $0 --write-user-manifest ~/.agents/delegate-backends.json" >&2
  exit 78
}
[ -n "$PROFILE" ] || PROFILE="$(printf '%s' "$RESOLVED" | jq -r '.default // empty')"
[ -n "$PROFILE" ] || die "no --profile given and the manifest sets no default" 78
P="$(printf '%s' "$RESOLVED" | jq -c --arg n "$PROFILE" '.profiles[] | select(.name==$n)')"
[ -n "$P" ] || die "profile '$PROFILE' is not permitted in this scope" 78

EGRESS="$(printf '%s' "$P" | jq -r '.egress')"
MODEL="$(printf '%s' "$P" | jq -r '.model')"

if [ "$DRY" -eq 1 ]; then
  printf '%s' "$RESOLVED" | jq -c '{default, profiles: [.profiles[].name], never: (.never_delegate|length)}'
  echo "would wire: profile=$PROFILE egress=$EGRESS tools=$TOOLS"
  exit 0
fi

echo "wiring $REPO (profile: $PROFILE, egress: $EGRESS)"

# -------------------------------------------------------------------------------- payload ---
BIN="${REPO}/.agents/bin"
install_file "${PAYLOAD}/delegate-agent" "${BIN}/delegate-agent"
install_file "${PAYLOAD}/delegate-run" "${BIN}/delegate-run"
install_file "${PAYLOAD}/consent-gate.sh" "${BIN}/consent-gate.sh"
# One source of truth: the verifier reads the skill's copy, the runtime reads this one, and the
# byte-compare above is what keeps them from drifting apart.
install_file "$RESOLVER_SRC" "${BIN}/resolve-backends.py"
chmod +x "${BIN}/delegate-agent" "${BIN}/delegate-run" "${BIN}/consent-gate.sh"

install_file "${ASSETS}/delegate-to-agent.md" "${REPO}/.claude/agents/delegate-to-agent.md"

# ------------------------------------------------------------------------- AGENTS.md block ---
python3 - "$REPO/AGENTS.md" "$ASSETS/agents-delegate.md" "$P" "$RESOLVED" << 'PY'
import json, pathlib, sys

agents = pathlib.Path(sys.argv[1])
block = pathlib.Path(sys.argv[2]).read_text()
p = json.loads(sys.argv[3])
resolved = json.loads(sys.argv[4])

# The predicate is not cosmetic. On a local backend, sensitivity is a reason to delegate (the work
# stays on this machine). On a remote one it is the opposite: shipping secrets to a hosted endpoint
# because the config called it "the cheap tier" is exfiltration. Render the half that is true.
if p["egress"] == "local":
    decision = (
        "must_stay_local  = sensitivity(task) >= CONFIDENTIAL\n"
        "may_escalate     = complexity(task)  >  LOCAL_CEILING\n"
        "delegate         = must_stay_local or not may_escalate"
    )
    note = (
        "This backend runs on this machine, so work sent to it does not leave. Sensitivity is a "
        "reason to prefer it, not to avoid it."
    )
else:
    decision = (
        "may_escalate = complexity(task) > CEILING\n"
        "delegate     = not may_escalate       # sensitivity NEVER routes here"
    )
    note = (
        "**This backend is remote — code sent to it leaves this machine.** Delegate on cost and "
        "volume only. Anything confidential stays with the orchestrator, no matter how mechanical "
        "it looks."
    )

never = resolved.get("never_delegate", [])
never_txt = ", ".join(f"`{n}`" for n in never[:4]) + (", …" if len(never) > 4 else "")

# Context limits are configured in decimal (CLAUDE_CODE_MAX_CONTEXT_TOKENS=256000), so divide by
# 1000, not 1024 — otherwise a 256000-token window renders as "250k" and reads like a typo.
ctx = p["context"]
block = (block
         .replace("PLACEHOLDER_PROFILE", p["name"])
         .replace("PLACEHOLDER_MODEL", p["model"])
         .replace("PLACEHOLDER_CONTEXT_K", f"{round(ctx / 1000)}k")
         .replace("PLACEHOLDER_EGRESS_NOTE", note)
         .replace("PLACEHOLDER_EGRESS", p["egress"])
         .replace("PLACEHOLDER_DECISION", decision)
         .replace("PLACEHOLDER_NEVER", never_txt))

text = agents.read_text() if agents.exists() else ""
BEG, END = "<!-- delegate:begin", "<!-- delegate:end -->"
nb, ne = text.count(BEG), text.count(END)
if nb != ne or nb > 1:
    sys.exit(f"malformed managed block in AGENTS.md ({nb} begin / {ne} end markers) — fix by hand")
if nb == 0:
    new = (text.rstrip("\n") + "\n\n" if text.strip() else "") + block
else:
    i, j = text.index(BEG), text.index(END) + len(END)
    new = text[:i] + block.strip() + "\n" + text[j:].lstrip("\n")
if new != text:
    agents.write_text(new)
    print("  + AGENTS.md delegate block")
else:
    print("  = AGENTS.md delegate block up to date")
PY

# ----------------------------------------------------------------------------- hook wiring ---
IFS=',' read -r -a TOOL_LIST <<< "$TOOLS"
for t in "${TOOL_LIST[@]}"; do
  [ -n "$t" ] || continue
  python3 - "$REPO" "$t" << 'PY'
import json, pathlib, sys

repo, tool = pathlib.Path(sys.argv[1]), sys.argv[2]
CMD = 'bash "$CLAUDE_PROJECT_DIR/.agents/bin/consent-gate.sh" --tool ' + tool
if tool != "claude":
    CMD = 'bash .agents/bin/consent-gate.sh --tool ' + tool

EVENT = {"claude": ("PreToolUse", ".claude/settings.json"),
         "gemini": ("BeforeTool", ".gemini/settings.json"),
         "copilot": ("preToolUse", ".github/hooks/delegate.json")}
if tool not in EVENT:
    sys.exit(f"  ! unknown tool {tool} — skipped")
event, rel = EVENT[tool]
path = repo / rel
path.parent.mkdir(parents=True, exist_ok=True)
data = {}
if path.exists():
    try:
        data = json.loads(path.read_text())
    except Exception as e:
        sys.exit(f"  ! {rel} is not valid JSON ({e}) — refusing to rewrite it")

hooks = data.setdefault("hooks", {}) if tool != "copilot" else data
groups = hooks.get(event, [])
# Strip only OUR managed group, matched on the script name. Anything else in this file belongs to
# another skill or to the user, and rewriting it would make this installer a source of data loss.
groups = [g for g in groups
          if not any("consent-gate.sh" in (h.get("command") or "")
                     for h in g.get("hooks", []))]
groups.append({"matcher": "Bash", "hooks": [{"type": "command", "command": CMD}]})
hooks[event] = groups

new = json.dumps(data, indent=2) + "\n"
if not path.exists() or path.read_text() != new:
    path.write_text(new)
    print(f"  + {rel} ({event} consent gate)")
else:
    print(f"  = {rel} up to date")
PY
done

# ------------------------------------------------------------------------------ gitignore ---
GI="${REPO}/.gitignore"
touch "$GI"
for entry in ".agents/delegate/" ".delegate-agent/"; do
  grep -qxF "$entry" "$GI" 2> /dev/null || {
    printf '%s\n' "$entry" >> "$GI"
    echo "  + .gitignore $entry"
  }
done

echo
echo "done. profile=$PROFILE egress=$EGRESS"
[ "$MISSING_TIMEOUT" -eq 1 ] \
  && echo "WARNING: no 'timeout' on PATH — dispatches will refuse to run. Fix: brew install coreutils"
[ "$EGRESS" = "remote" ] \
  && echo "NOTE: '$PROFILE' is REMOTE ($MODEL) — the routing block tells agents that code sent there leaves this machine."
exit 0
