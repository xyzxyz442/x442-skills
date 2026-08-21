#!/usr/bin/env bash
# verify-delegate-agent.sh — read-only health check for an installed delegation setup.
#
#   verify-delegate-agent.sh [/path/to/repo]
#
# READ-ONLY: never writes, never dispatches, never contacts an agent endpoint. It exercises the
# consent gate with synthetic stdin (which only prints a decision) and resolves the cascade (which
# is itself read-only), so running it cannot change what it measures.
#
# Exits non-zero if any [FAIL]. Warnings never fail: an optional tool that is absent, or a
# capability an adapter genuinely lacks, is information rather than breakage.

set -uo pipefail
REPO="${1:-$PWD}"
REPO="$(cd "$REPO" 2> /dev/null && git rev-parse --show-toplevel 2> /dev/null)" || {
  echo "verify-delegate-agent: '${1:-$PWD}' is not inside a git repository." >&2
  exit 1
}
SKILL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${REPO}/.agents/bin"
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

# Compare the installed payload stamp against the version this skill ships. A behind-but-working
# install is a WARNING, never a FAIL — it still functions, it just predates a payload change, and
# reserving the non-zero exit for real breakage keeps the harness contract meaningful. Silent when
# the skill's own payload.version is unreadable, which is what happens if the verifier is copied
# somewhere detached from its skill directory: unknown is not the same as behind.
check_payload_version() { # installed-version skill-name   (caller reads the stamp; shapes differ)
  local installed="$1" skill="$2" shipped
  shipped="$(awk 'NR==1{print $2}' "$(dirname "$0")/payload.version" 2> /dev/null)"
  [ -n "$shipped" ] || return 0
  if [ -z "$installed" ]; then
    warn "payload version unknown (pre-versioning install) — re-run $skill"
  elif [ "$installed" -lt "$shipped" ] 2> /dev/null; then
    warn "payload v$installed installed, skill ships v$shipped — re-run $skill"
  elif [ "$installed" -gt "$shipped" ] 2> /dev/null; then
    warn "payload v$installed installed is newer than the skill's v$shipped — this $skill copy is stale"
  else
    ok "payload v$installed matches the version $skill ships"
  fi
}

is_json() { python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1" 2> /dev/null; }

echo "verify-delegate-agent: $REPO"
echo
echo "## 1. payload"
echo "-------------"
for f in delegate-agent delegate-run consent-gate.sh; do
  if [ -f "${BIN}/${f}" ]; then
    [ -x "${BIN}/${f}" ] && ok "$f installed and executable" || bad "$f is not executable"
    # Parse with the system bash, not whatever is first on PATH: macOS ships 3.2 and that is what
    # `env bash` resolves to, so a bash-4-only construct must fail here, loudly.
    /bin/bash -n "${BIN}/${f}" 2> /dev/null && ok "$f parses under system bash" \
      || bad "$f has a syntax error under system bash (bash 3.2)"
  else
    bad "$f is missing from .agents/bin/"
  fi
done
ADAPTER_N=0
for a in "${BIN}"/adapters/*.sh; do
  [ -f "$a" ] || continue
  ADAPTER_N=$((ADAPTER_N + 1))
  /bin/bash -n "$a" 2> /dev/null || bad "adapter $(basename "$a") has a syntax error"
done
[ "$ADAPTER_N" -gt 0 ] && ok "$ADAPTER_N adapter(s) installed" || bad "no adapters installed"
if [ -f "${BIN}/resolve-backends.py" ]; then
  cmp -s "${SKILL}/scripts/manifest/resolve.py" "${BIN}/resolve-backends.py" \
    && ok "resolver matches the skill's copy" \
    || warn "resolve-backends.py differs from the skill's resolve.py — re-run setup to resync"
else
  bad "resolve-backends.py is missing from .agents/bin/"
fi
check_payload_version "$(awk 'NR==1{print $2}' "${BIN}/.version" 2> /dev/null)" setup-delegate-agent

echo
echo "## 2. dependencies"
echo "------------------"
command -v python3 > /dev/null 2>&1 && ok "python3 present" || bad "python3 missing"
command -v jq > /dev/null 2>&1 && ok "jq present" || bad "jq missing (brew install jq)"
if command -v trivy > /dev/null 2>&1; then
  ok "trivy present (credential scanning active)"
else
  bad "trivy missing — scanning is fail-closed, so every dispatch will refuse (brew install trivy)"
fi
if command -v timeout > /dev/null 2>&1 || command -v gtimeout > /dev/null 2>&1; then
  ok "GNU timeout present"
else
  warn "no GNU timeout — the pure-bash watchdog will be used instead (this is supported)"
fi

echo
echo "## 3. cascade"
echo "-------------"
RESOLVED=""
if [ -f "${SKILL}/scripts/manifest/resolve.py" ]; then
  RESOLVED="$(cd "$REPO" && python3 "${SKILL}/scripts/manifest/resolve.py" --scope "$REPO" 2> /dev/null)"
  if [ -n "$RESOLVED" ]; then
    N="$(printf '%s' "$RESOLVED" | jq '.agents | length' 2> /dev/null || echo 0)"
    [ "$N" -gt 0 ] && ok "cascade resolves $N agent(s): $(printf '%s' "$RESOLVED" | jq -r '[.agents[].name]|join(", ")')" \
      || bad "cascade resolves no agent in this scope"
    [ "$(printf '%s' "$RESOLVED" | jq -r '.primary // empty')" != "" ] \
      && ok "primary assistant declared" \
      || warn "no primary declared — party falls back to third-party for everything"
    while IFS= read -r e; do [ -n "$e" ] && bad "cascade: $e"; done \
      <<< "$(printf '%s' "$RESOLVED" | jq -r '.errors[]?' 2> /dev/null)"
    while IFS= read -r w; do [ -n "$w" ] && warn "cascade: $w"; done \
      <<< "$(printf '%s' "$RESOLVED" | jq -r '.warnings[]?' 2> /dev/null)"
    NV="$(printf '%s' "$RESOLVED" | jq '.never_delegate | length' 2> /dev/null || echo 0)"
    [ "$NV" -gt 0 ] && ok "never-delegate floor active ($NV pattern(s))" \
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
    if [ -n "$RESOLVED" ]; then
      # The block tells the assistant which agents exist. If it disagrees with the cascade, the
      # assistant is being told about a route that may not resolve — the drift that actually bites.
      MISSING=""
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        grep -q "\`$n\`" "$A" || MISSING="$MISSING $n"
      done <<< "$(printf '%s' "$RESOLVED" | jq -r '.agents[].name')"
      [ -z "$MISSING" ] && ok "block lists every resolved agent" \
        || bad "block is missing resolved agent(s):$MISSING — re-run setup"
      THIRD="$(printf '%s' "$RESOLVED" | jq -r '[.agents[]|select(.party=="third-party")]|length')"
      if [ "$THIRD" -gt 0 ]; then
        grep -q 'third-party' "$A" && ok "block warns about third-party agents" \
          || bad "a third-party agent is permitted but the block does not say so"
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
echo "## 5. consent gate fires"
echo "------------------------"
if [ -x "${BIN}/consent-gate.sh" ]; then
  probe() {
    printf '%s' "$1" | bash "${BIN}/consent-gate.sh" --tool claude 2> /dev/null \
      | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print("allow"); raise SystemExit
print(d.get("hookSpecificOutput",{}).get("permissionDecision","allow"))' 2> /dev/null || echo allow
  }
  [ "$(probe '{"tool_name":"Bash","tool_input":{"command":".agents/bin/delegate-run --prompt hi"}}')" = "deny" ] \
    && ok "unapproved dispatch is denied" || bad "unapproved dispatch was NOT denied"
  [ "$(probe '{"tool_name":"Bash","tool_input":{"command":".agents/bin/delegate-agent --agent x"}}')" = "deny" ] \
    && ok "direct wrapper invocation is denied" || bad "direct wrapper invocation was NOT denied"
  [ "$(probe '{"tool_name":"Bash","tool_input":{"command":".agents/bin/delegate-run --task .env --approved t1"}}')" = "deny" ] \
    && ok "dispatch naming a credential path is denied" || bad "dispatch naming a credential path was NOT denied"
  [ "$(probe '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}')" = "ask" ] \
    && ok "main-session credential read asks" || bad "main-session credential read did not ask"
  [ "$(probe '{"tool_name":"Bash","tool_input":{"command":".agents/bin/delegate-run --prompt hi --approved t1"}}')" = "allow" ] \
    && ok "approved dispatch is allowed" || bad "approved dispatch was blocked"
  [ "$(probe '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}')" = "allow" ] \
    && ok "unrelated commands pass through" || bad "gate blocked an unrelated command"
else
  bad "consent-gate.sh not executable — the backstop is not armed"
fi

echo
echo "## 6. wiring and hygiene"
echo "------------------------"
WIRED=0
for rel in .claude/settings.json .gemini/settings.json .github/hooks/delegate.json; do
  f="${REPO}/${rel}"
  [ -f "$f" ] || continue
  if is_json "$f"; then
    grep -q 'consent-gate.sh' "$f" && {
      ok "$rel wires the consent gate"
      WIRED=$((WIRED + 1))
    }
  else
    bad "$rel is not valid JSON"
  fi
done
[ "$WIRED" -gt 0 ] && ok "consent gate wired into $WIRED tool(s)" \
  || warn "gate not wired into any tool — delegate-run still enforces consent, but a raw call is not blocked"

if [ -n "$RESOLVED" ]; then
  LEAKY="$(printf '%s' "$RESOLVED" | jq -r '.agents[] | select(.settings_world_readable==true) | .settings_path' 2> /dev/null)"
  if [ -n "$LEAKY" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && warn "$f is group/world readable and holds a token — chmod 600 \"$f\""
    done <<< "$LEAKY"
  else
    ok "no world-readable credential file among the resolved agents"
  fi
fi
if git -C "$REPO" ls-files --error-unmatch .agents/delegate.json > /dev/null 2>&1; then
  python3 -c "import json,sys; d=json.load(open('${REPO}/.agents/delegate.json')); sys.exit(0 if 'agents' not in d else 1)" 2> /dev/null \
    && ok "committed .agents/delegate.json narrows only" \
    || bad "committed .agents/delegate.json defines agents — a committed manifest must only narrow"
fi
for pat in ".agents/delegate/" ".delegate-agent/"; do
  grep -qxF "$pat" "${REPO}/.gitignore" 2> /dev/null && ok "gitignored: $pat" \
    || warn "not gitignored: $pat — briefs and results may be committed"
done

echo
echo "Summary: $P passed, $W warnings, $F failed"
[ "$F" -gt 0 ] && exit 1
exit 0
