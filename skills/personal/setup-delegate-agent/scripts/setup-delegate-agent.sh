#!/usr/bin/env bash
# setup-delegate-agent.sh — wire a repo to dispatch work to the agents its cascade already permits.
#
#   setup-delegate-agent.sh <repo> [--tools claude,gemini,copilot] [--dry-run]
#
# Installs the machinery — dispatcher, wrapper, adapters, resolver, consent hook — and renders the
# AGENTS.md routing block from whatever .agents/delegate.json resolves to. It never invents an
# agent; declaring one is register-delegate-agents' job.
#
# Idempotent: byte-compares before writing, so a second run leaves `git status` clean. Writes only
# inside <repo>. bash 3.2 compatible, which is what macOS ships.

set -euo pipefail
SKILL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="${SKILL}/assets"
PAYLOAD="${SKILL}/scripts/payload"
RESOLVER="${SKILL}/scripts/manifest/resolve.py"

die() {
  echo "setup-delegate-agent: $1" >&2
  exit "${2:-1}"
}
install_file() {
  local s="$1" d="$2"
  mkdir -p "$(dirname "$d")"
  if [ ! -f "$d" ] || ! cmp -s "$s" "$d"; then
    cp "$s" "$d"
    echo "  + ${d#"$REPO"/}"
  else
    echo "  = ${d#"$REPO"/} up to date"
  fi
}

REPO="${1:?usage: setup-delegate-agent.sh <repo> [--tools ...] [--dry-run]}"
shift || true
TOOLS="claude"
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
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

REPO="$(cd "$REPO" 2> /dev/null && git rev-parse --show-toplevel 2> /dev/null)" \
  || die "not a git working tree: refusing to install (run initial-project first)"
[ -f "$REPO/AGENTS.md" ] || die "no AGENTS.md at repo root — run initial-project first; not fabricating it here"
command -v python3 > /dev/null 2>&1 || die "python3 is required" 69
command -v jq > /dev/null 2>&1 || die "jq is required (brew install jq)" 69

# Resolve BEFORE writing anything. A block advertising an agent that does not resolve is worse
# than no block: it tells the assistant a route exists that will fail on first use.
RESOLVED="$(cd "$REPO" && python3 "$RESOLVER" --scope "$REPO" 2> /dev/null)" || {
  echo "setup-delegate-agent: no usable agent resolved in this scope." >&2
  (cd "$REPO" && python3 "$RESOLVER" --scope "$REPO" 2> /dev/null) \
    | jq -r '.errors[]? | "  error: " + .' >&2 || true
  echo "  Declare one with the register-delegate-agents skill, then re-run." >&2
  exit 78
}
NAGENTS="$(printf '%s' "$RESOLVED" | jq '.agents | length')"
[ "$NAGENTS" -gt 0 ] || die "the cascade resolves zero agents in this scope — nothing to wire" 78

if [ "$DRY" -eq 1 ]; then
  printf '%s' "$RESOLVED" | jq -c '{primary, default, agents:[.agents[]|{name,adapter,party}], never:(.never_delegate|length)}'
  echo "would wire tools: $TOOLS"
  exit 0
fi

echo "wiring $REPO ($NAGENTS agent(s), default: $(printf '%s' "$RESOLVED" | jq -r '.default // "none"'))"

BIN="${REPO}/.agents/bin"
install_file "${PAYLOAD}/delegate-agent" "${BIN}/delegate-agent"
install_file "${PAYLOAD}/delegate-run" "${BIN}/delegate-run"
install_file "${PAYLOAD}/consent-gate.sh" "${BIN}/consent-gate.sh"
# One source of truth: the verifier reads the skill's copy, the runtime reads this one, and the
# byte-compare is what keeps them from drifting apart.
install_file "$RESOLVER" "${BIN}/resolve-backends.py"
for a in "${PAYLOAD}"/adapters/*.sh; do
  install_file "$a" "${BIN}/adapters/$(basename "$a")"
done
chmod +x "${BIN}/delegate-agent" "${BIN}/delegate-run" "${BIN}/consent-gate.sh" "${BIN}"/adapters/*.sh
install_file "${ASSETS}/delegate-to-agent.md" "${REPO}/.claude/agents/delegate-to-agent.md"

python3 - "$REPO/AGENTS.md" "$ASSETS/agents-delegate.md" "$RESOLVED" << 'PY'
import json, pathlib, sys

agents_md = pathlib.Path(sys.argv[1])
block = pathlib.Path(sys.argv[2]).read_text()
r = json.loads(sys.argv[3])
agents = r["agents"]

order = {n: i for i, n in enumerate(r.get("prefer", []))}
agents = sorted(agents, key=lambda a: order.get(a["name"], 999))
rows = ["| # | Agent | Adapter | Model | Context | Party | Good for |",
        "| --- | --- | --- | --- | --- | --- | --- |"]
for i, a in enumerate(agents, 1):
    ctx = f"{round(a['context'] / 1000)}k" if a.get("context") else "—"
    kinds = ", ".join(f"`{k}`" for k in a.get("kinds", [])) or "—"
    rows.append(f"| {i} | `{a['name']}` | `{a['adapter']}` | `{a['model']}` | {ctx} "
                f"| **{a['party']}** | {kinds} |")
roster = "\n".join(rows)

mode = r.get("mode", "manual")
if mode == "auto":
    auto_kinds = sorted({k for a in agents for k in a.get("auto_approve", [])})
    listed = ", ".join(f"`{k}`" for k in auto_kinds) or "nothing yet"
    mode_note = (f"Auto mode dispatches **without asking** only for pre-approved kinds ({listed}), "
                 f"and only when the dispatch is read-only or worktree-isolated. Everything else "
                 f"still prompts.")
elif mode == "off":
    mode_note = "**Delegation is disabled in this scope.** Do the work here."
else:
    mode_note = "Manual mode — every dispatch prompts before it runs."

# The predicate is not cosmetic. Whether sensitivity is a reason to delegate or a reason not to
# depends entirely on who else ends up seeing the code, so render the half that is true here.
if any(a["party"] == "third-party" for a in agents):
    note = ("**At least one agent here is third-party — code sent to it reaches someone who cannot "
            "already see it.** Delegate to those on cost and volume only; anything confidential "
            "stays with the orchestrator, however mechanical it looks.")
    decision = ("may_escalate = complexity(task) > CEILING\n"
                "delegate     = not may_escalate\n"
                "               # sensitivity NEVER routes to a third-party agent")
elif all(a["party"] == "local" for a in agents):
    note = ("Every agent here runs on this machine, so delegated work does not leave. Sensitivity "
            "is a reason to prefer them, not to avoid them.")
    decision = ("must_stay_local = sensitivity(task) >= CONFIDENTIAL\n"
                "may_escalate    = complexity(task)  >  LOCAL_CEILING\n"
                "delegate        = must_stay_local or not may_escalate")
else:
    note = ("Every agent here is either on this machine or already sees this code as your primary "
            "assistant, so delegating adds no new observer.")
    decision = ("may_escalate = complexity(task) > CEILING\n"
                "delegate     = not may_escalate")

never = r.get("never_delegate", [])
never_txt = ", ".join(f"`{n}`" for n in never[:4]) + (", …" if len(never) > 4 else "")

block = (block
         .replace("PLACEHOLDER_PRIMARY", f"`{r.get('primary') or 'unset'}`")
         .replace("PLACEHOLDER_MODE_NOTE", mode_note)
         .replace("PLACEHOLDER_MODE", f"`{mode}`")
         .replace("PLACEHOLDER_ROSTER", roster)
         .replace("PLACEHOLDER_PARTY_NOTE", note)
         .replace("PLACEHOLDER_DECISION", decision)
         .replace("PLACEHOLDER_NEVER", never_txt))

text = agents_md.read_text() if agents_md.exists() else ""
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
    agents_md.write_text(new)
    print("  + AGENTS.md delegate block")
else:
    print("  = AGENTS.md delegate block up to date")
PY

OLDIFS="$IFS"
IFS=','
for t in $TOOLS; do
  IFS="$OLDIFS"
  [ -n "$t" ] || continue
  python3 - "$REPO" "$t" << 'PY'
import json, pathlib, sys

repo, tool = pathlib.Path(sys.argv[1]), sys.argv[2]
CMD = ('bash "$CLAUDE_PROJECT_DIR/.agents/bin/consent-gate.sh" --tool ' + tool) if tool == "claude" \
    else ('bash .agents/bin/consent-gate.sh --tool ' + tool)
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
# Strip only OUR managed group, matched on the script name. Anything else in this file belongs to
# another skill or to the user, and rewriting it would make this installer a source of data loss.
groups = [g for g in hooks.get(event, [])
          if not any("consent-gate.sh" in (h.get("command") or "") for h in g.get("hooks", []))]
groups.append({"matcher": "Bash|Read", "hooks": [{"type": "command", "command": CMD}]})
hooks[event] = groups
new = json.dumps(data, indent=2) + "\n"
if not path.exists() or path.read_text() != new:
    path.write_text(new)
    print(f"  + {rel} ({event} consent gate)")
else:
    print(f"  = {rel} up to date")
PY
  IFS=','
done
IFS="$OLDIFS"

GI="${REPO}/.gitignore"
touch "$GI"
for entry in ".agents/delegate/" ".delegate-agent/"; do
  grep -qxF "$entry" "$GI" 2> /dev/null || {
    printf '%s\n' "$entry" >> "$GI"
    echo "  + .gitignore $entry"
  }
done

echo
THIRD="$(printf '%s' "$RESOLVED" | jq -r '[.agents[]|select(.party=="third-party")|.name]|join(", ")')"
[ -n "$THIRD" ] && echo "NOTE: third-party agent(s) permitted here: ${THIRD} — code sent to them leaves this machine."
command -v trivy > /dev/null 2>&1 \
  || echo "WARNING: trivy is not installed. Dispatches fail closed without it (brew install trivy)."
exit 0
