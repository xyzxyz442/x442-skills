#!/usr/bin/env bash
# verify-delegate-agent.sh — read-only health check for an installed delegation setup.
#
#   verify-delegate-agent.sh [/path/to/repo]
#
# READ-ONLY: never writes, never dials a backend, never dispatches. It exercises the consent gate
# with synthetic stdin (which only prints JSON) and resolves the manifest (which is itself
# read-only), so running it can never change what it is measuring.
#
# Exits non-zero if any [FAIL]. Warnings never fail: a missing optional tool or a backend that is
# merely unconfigured is information, not breakage.

set -uo pipefail

REPO="${1:-$PWD}"
REPO="$(cd "$REPO" 2> /dev/null && git rev-parse --show-toplevel 2> /dev/null)" || {
  echo "verify-delegate-agent: '${1:-$PWD}' is not inside a git repository." >&2
  exit 1
}
SKILL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

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

BIN="${REPO}/.agents/bin"

echo "verify-delegate-agent: $REPO"
echo
echo "## 1. payload"
echo "-------------"
for f in delegate-agent delegate-run consent-gate.sh; do
  if [ -f "${BIN}/${f}" ]; then
    if [ -x "${BIN}/${f}" ]; then ok "$f installed and executable"; else bad "$f is not executable"; fi
    bash -n "${BIN}/${f}" 2> /dev/null && ok "$f parses" || bad "$f has a syntax error"
  else
    bad "$f is missing from .agents/bin/"
  fi
done
if [ -f "${BIN}/resolve-backends.py" ]; then
  if cmp -s "${SKILL}/scripts/manifest/resolve.py" "${BIN}/resolve-backends.py"; then
    ok "resolver matches the skill's copy"
  else
    # Drift here means the installed runtime and the verifier disagree about which profiles exist,
    # which is exactly the disagreement the single-source copy exists to prevent.
    warn "resolve-backends.py differs from the skill's resolve.py — re-run setup to resync"
  fi
else
  bad "resolve-backends.py is missing from .agents/bin/"
fi

echo
echo "## 2. dependencies"
echo "------------------"
command -v python3 > /dev/null 2>&1 && ok "python3 present" || bad "python3 missing"
command -v jq > /dev/null 2>&1 && ok "jq present" || bad "jq missing (brew install jq)"
if command -v timeout > /dev/null 2>&1 || command -v gtimeout > /dev/null 2>&1; then
  ok "timeout present"
else
  bad "no timeout/gtimeout on PATH — every dispatch will refuse to run (brew install coreutils)"
fi
command -v claude > /dev/null 2>&1 && ok "claude CLI present" \
  || warn "claude CLI not on PATH — delegate-agent cannot start a backend"

echo
echo "## 3. backend configuration"
echo "---------------------------"
RESOLVED=""
if [ -f "${SKILL}/scripts/manifest/resolve.py" ]; then
  RESOLVED="$(python3 "${SKILL}/scripts/manifest/resolve.py" --scope "$REPO" --root "$REPO" 2> /dev/null)"
  RC=$?
  if [ -n "$RESOLVED" ]; then
    NPROF="$(printf '%s' "$RESOLVED" | jq -r '.profiles | length' 2> /dev/null || echo 0)"
    if [ "$RC" -eq 0 ] && [ "$NPROF" -gt 0 ]; then
      ok "manifest resolves ($NPROF profile(s): $(printf '%s' "$RESOLVED" | jq -r '[.profiles[].name]|join(", ")'))"
    else
      bad "manifest resolved no usable profile"
    fi
    while IFS= read -r e; do [ -n "$e" ] && bad "config: $e"; done \
      <<< "$(printf '%s' "$RESOLVED" | jq -r '.errors[]?' 2> /dev/null)"
    while IFS= read -r w; do [ -n "$w" ] && warn "config: $w"; done \
      <<< "$(printf '%s' "$RESOLVED" | jq -r '.warnings[]?' 2> /dev/null)"
    NEVER="$(printf '%s' "$RESOLVED" | jq -r '.never_delegate | length' 2> /dev/null || echo 0)"
    [ "$NEVER" -gt 0 ] && ok "never-delegate floor active ($NEVER pattern(s))" \
      || bad "never-delegate list is empty — the built-in floor did not load"
  else
    bad "resolver produced no output"
  fi
else
  bad "resolver missing from the skill"
fi

echo
echo "## 4. AGENTS.md routing block"
echo "-----------------------------"
A="${REPO}/AGENTS.md"
if [ -f "$A" ]; then
  nb=$(grep -c '<!-- delegate:begin' "$A" 2> /dev/null || echo 0)
  ne=$(grep -c '<!-- delegate:end -->' "$A" 2> /dev/null || echo 0)
  if [ "$nb" -eq 1 ] && [ "$ne" -eq 1 ]; then
    ok "managed block present exactly once"
    grep -q 'PLACEHOLDER_' "$A" && bad "block still contains unsubstituted PLACEHOLDER_ tokens" \
      || ok "block fully rendered"
    # The block states an egress class to the agent. If it disagrees with the resolved profile,
    # the agent is being told the wrong thing about where its code goes — the one drift here
    # with a real consequence.
    if [ -n "$RESOLVED" ]; then
      DEF="$(printf '%s' "$RESOLVED" | jq -r '.default // empty')"
      EG="$(printf '%s' "$RESOLVED" | jq -r --arg n "$DEF" '.profiles[]|select(.name==$n)|.egress' 2> /dev/null)"
      if [ -n "$EG" ]; then
        # Collapse whitespace first: the assertion is about the block's claim, not about where
        # a markdown line happens to wrap.
        if tr '\n' ' ' < "$A" | tr -s ' ' | grep -q "egress \*\*${EG}\*\*"; then
          ok "block egress agrees with the resolved profile ($EG)"
        else
          bad "block egress disagrees with the resolved profile ($EG) — re-run setup"
        fi
      fi
    fi
  elif [ "$nb" -eq 0 ]; then
    bad "no delegate block in AGENTS.md — run setup-delegate-agent"
  else
    bad "malformed managed block ($nb begin / $ne end markers) — fix by hand"
  fi
else
  bad "no AGENTS.md at repo root"
fi

echo
echo "## 5. broker subagent"
echo "---------------------"
BROKER="${REPO}/.claude/agents/delegate-to-agent.md"
if [ -f "$BROKER" ]; then
  ok "broker subagent installed"
  head -1 "$BROKER" | grep -q '^---$' && ok "broker has frontmatter" || bad "broker is missing frontmatter"
else
  warn "broker subagent not installed — dispatch transcripts will land in the main context"
fi

echo
echo "## 6. consent gate fires"
echo "------------------------"
if [ -x "${BIN}/consent-gate.sh" ]; then
  probe() {
    printf '%s' "$2" | bash "${BIN}/consent-gate.sh" --tool claude 2> /dev/null \
      | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print("allow"); raise SystemExit
print(d.get("hookSpecificOutput",{}).get("permissionDecision","allow"))' 2> /dev/null || echo allow
  }
  d1="$(probe x '{"tool_input":{"command":".agents/bin/delegate-run --prompt hi"}}')"
  [ "$d1" = "deny" ] && ok "unapproved dispatch is denied" || bad "unapproved dispatch was NOT denied (got '$d1')"
  d2="$(probe x '{"tool_input":{"command":".agents/bin/delegate-agent -p hi"}}')"
  [ "$d2" = "deny" ] && ok "direct backend invocation is denied" || bad "direct backend invocation was NOT denied (got '$d2')"
  d3="$(probe x '{"tool_input":{"command":".agents/bin/delegate-run --prompt hi --approved t1"}}')"
  [ "$d3" = "allow" ] && ok "approved dispatch is allowed" || bad "approved dispatch was blocked (got '$d3')"
  d4="$(probe x '{"tool_input":{"command":"ls -la"}}')"
  [ "$d4" = "allow" ] && ok "unrelated commands pass through" || bad "gate blocked an unrelated command"
else
  bad "consent-gate.sh not executable — the backstop is not armed"
fi

echo
echo "## 7. hook wiring"
echo "-----------------"
WIRED=0
for rel in .claude/settings.json .gemini/settings.json .github/hooks/delegate.json; do
  f="${REPO}/${rel}"
  [ -f "$f" ] || continue
  if is_json "$f"; then
    if grep -q 'consent-gate.sh' "$f"; then
      ok "$rel wires the consent gate"
      WIRED=$((WIRED + 1))
    fi
  else
    bad "$rel is not valid JSON"
  fi
done
[ "$WIRED" -gt 0 ] && ok "consent gate wired into $WIRED tool(s)" \
  || warn "consent gate is not wired into any tool — delegate-run still enforces consent, but a raw backend call is not blocked"

echo
echo "## 8. credential hygiene"
echo "------------------------"
if [ -n "$RESOLVED" ]; then
  LEAKY="$(printf '%s' "$RESOLVED" | jq -r '.profiles[] | select(.settings_world_readable==true) | .settings_file' 2> /dev/null)"
  if [ -n "$LEAKY" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && warn "$f is group/world readable and holds a token — chmod 600 \"$f\""
    done <<< "$LEAKY"
  else
    ok "no world-readable credential file among the resolved profiles"
  fi
fi
if git -C "$REPO" ls-files --error-unmatch .delegate-backends.json > /dev/null 2>&1; then
  if grep -qE '"(profiles|tokenEnv)"' "${REPO}/.delegate-backends.json" 2> /dev/null; then
    bad "committed .delegate-backends.json declares profiles — a committed manifest must only narrow"
  else
    ok "committed .delegate-backends.json narrows only"
  fi
fi
for pat in ".agents/delegate/" ".delegate-agent/"; do
  grep -qxF "$pat" "${REPO}/.gitignore" 2> /dev/null && ok "gitignored: $pat" \
    || warn "not gitignored: $pat — briefs and results may be committed"
done

echo
echo "Summary: $P passed, $W warnings, $F failed"
[ "$F" -gt 0 ] && exit 1
exit 0
