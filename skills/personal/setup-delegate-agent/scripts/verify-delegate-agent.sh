#!/usr/bin/env bash
# verify-delegate-agent.sh — read-only health check for an installed delegation setup.
#
#   verify-delegate-agent.sh [/path/to/repo] [--json]
#
# READ-ONLY: never writes, never dispatches, never contacts an agent endpoint. It exercises the
# consent gate with synthetic stdin (which only prints a decision) and resolves the cascade (which
# is itself read-only), so running it cannot change what it measures.
#
# Exits non-zero if any [FAIL]. Warnings never fail: an optional tool that is absent, or a
# capability an adapter genuinely lacks, is information rather than breakage.
#
# --json emits every finding as a machine-readable object instead of prose. A third of what this
# checks is ADVISORY by design — a resolver copy that has drifted, no primary declared, a missing
# GNU timeout, a world-readable credential file, briefs that are not gitignored — and none of it
# changes the exit code, so a grader reading only the exit status is blind to exactly the checks
# most likely to rot. This is the channel that makes them gradeable.
#
# Every finding carries a STABLE ID. The id names the CHECK and `level` carries the outcome, so a
# grader asserts "perms.world_readable came back warn" rather than matching prose that any future
# rewording breaks. Where two outcomes of one check need different remediation they get different
# ids (payload.version.behind vs payload.version.ahead) — same rule, applied where it earns itself.

set -uo pipefail
JSON=0
ARGS=""
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    *) ARGS="$a" ;;
  esac
done
REPO="${ARGS:-$PWD}"
REPO="$(cd "$REPO" 2> /dev/null && git rev-parse --show-toplevel 2> /dev/null)" || {
  echo "verify-delegate-agent: '${ARGS:-$PWD}' is not inside a git repository." >&2
  exit 1
}
SKILL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${REPO}/.agents/bin"
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
  shipped="$(awk 'NR==1{print $2}' "$SKILL/scripts/payload.version" 2> /dev/null)"
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

echo "verify-delegate-agent: $REPO"
section "## 1. payload"
for f in delegate-agent delegate-run consent-gate.sh; do
  if [ -f "${BIN}/${f}" ]; then
    [ -x "${BIN}/${f}" ] && ok payload.executable "$f installed and executable" || bad payload.executable "$f is not executable"
    # Parse with the system bash, not whatever is first on PATH: macOS ships 3.2 and that is what
    # `env bash` resolves to, so a bash-4-only construct must fail here, loudly.
    /bin/bash -n "${BIN}/${f}" 2> /dev/null && ok payload.parses "$f parses under system bash" \
      || bad payload.parses "$f has a syntax error under system bash (bash 3.2)"
  else
    bad payload.present "$f is missing from .agents/bin/"
  fi
done
ADAPTER_N=0
for a in "${BIN}"/adapters/*.sh; do
  [ -f "$a" ] || continue
  ADAPTER_N=$((ADAPTER_N + 1))
  /bin/bash -n "$a" 2> /dev/null || bad adapter.parses "adapter $(basename "$a") has a syntax error"
done
[ "$ADAPTER_N" -gt 0 ] && ok adapter.present "$ADAPTER_N adapter(s) installed" || bad adapter.present "no adapters installed"
if [ -f "${BIN}/resolve-backends.py" ]; then
  cmp -s "${SKILL}/scripts/manifest/resolve.py" "${BIN}/resolve-backends.py" \
    && ok resolver.in_sync "resolver matches the skill's copy" \
    || warn resolver.in_sync "resolve-backends.py differs from the skill's resolve.py — re-run setup to resync"
else
  bad resolver.present "resolve-backends.py is missing from .agents/bin/"
fi
check_payload_version "$(awk 'NR==1{print $2}' "${BIN}/.version" 2> /dev/null)" setup-delegate-agent

section "## 2. dependencies"
command -v python3 > /dev/null 2>&1 && ok dep.python3 "python3 present" || bad dep.python3 "python3 missing"
command -v jq > /dev/null 2>&1 && ok dep.jq "jq present" || bad dep.jq "jq missing (brew install jq)"
if command -v trivy > /dev/null 2>&1; then
  ok dep.trivy "trivy present (credential scanning active)"
else
  bad dep.trivy "trivy missing — scanning is fail-closed, so every dispatch will refuse (brew install trivy)"
fi
if command -v timeout > /dev/null 2>&1 || command -v gtimeout > /dev/null 2>&1; then
  ok dep.timeout "GNU timeout present"
else
  warn dep.timeout "no GNU timeout — the pure-bash watchdog will be used instead (this is supported)"
fi

section "## 3. cascade"
RESOLVED=""
if [ -f "${SKILL}/scripts/manifest/resolve.py" ]; then
  RESOLVED="$(cd "$REPO" && python3 "${SKILL}/scripts/manifest/resolve.py" --scope "$REPO" 2> /dev/null)"
  if [ -n "$RESOLVED" ]; then
    N="$(printf '%s' "$RESOLVED" | jq '.agents | length' 2> /dev/null || echo 0)"
    [ "$N" -gt 0 ] && ok cascade.agents "cascade resolves $N agent(s): $(printf '%s' "$RESOLVED" | jq -r '[.agents[].name]|join(", ")')" \
      || bad cascade.agents "cascade resolves no agent in this scope"
    [ "$(printf '%s' "$RESOLVED" | jq -r '.primary // empty')" != "" ] \
      && ok cascade.primary "primary assistant declared" \
      || warn cascade.primary "no primary declared — party falls back to third-party for everything"
    while IFS= read -r e; do [ -n "$e" ] && bad cascade.error "cascade: $e"; done \
      <<< "$(printf '%s' "$RESOLVED" | jq -r '.errors[]?' 2> /dev/null)"
    while IFS= read -r w; do [ -n "$w" ] && warn cascade.warning "cascade: $w"; done \
      <<< "$(printf '%s' "$RESOLVED" | jq -r '.warnings[]?' 2> /dev/null)"
    NV="$(printf '%s' "$RESOLVED" | jq '.never_delegate | length' 2> /dev/null || echo 0)"
    [ "$NV" -gt 0 ] && ok cascade.never_delegate "never-delegate floor active ($NV pattern(s))" \
      || bad cascade.never_delegate "never-delegate list is empty — the built-in floor did not load"
  else
    bad cascade.resolves "resolver produced no output"
  fi
else
  bad cascade.resolves "resolver missing from the skill"
fi

section "## 4. AGENTS.md routing block"
A="${REPO}/AGENTS.md"
if [ -f "$A" ]; then
  # grep -c already prints 0 on no-match (and exits 1), so `|| echo 0` appended a SECOND 0: nb
  # became the two-line string "0\n0", every [ -eq ] against it errored to stderr and evaluated
  # false, and a repo with no block at all fell through to the malformed branch — reported as
  # "malformed managed block (0" and told to fix it by hand instead of to run setup-delegate-agent.
  # Same fix, same reason, as verify-cross-repo-graph.sh:222.
  nb=$(grep -c '<!-- delegate:begin' "$A" 2> /dev/null) || nb=0
  ne=$(grep -c '<!-- delegate:end -->' "$A" 2> /dev/null) || ne=0
  if [ "$nb" -eq 1 ] && [ "$ne" -eq 1 ]; then
    ok block.present "managed block present exactly once"
    grep -q 'PLACEHOLDER_' "$A" && bad block.rendered "block still contains unsubstituted PLACEHOLDER_ tokens" \
      || ok block.rendered "block fully rendered"
    if [ -n "$RESOLVED" ]; then
      # The block tells the assistant which agents exist. If it disagrees with the cascade, the
      # assistant is being told about a route that may not resolve — the drift that actually bites.
      MISSING=""
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        grep -q "\`$n\`" "$A" || MISSING="$MISSING $n"
      done <<< "$(printf '%s' "$RESOLVED" | jq -r '.agents[].name')"
      [ -z "$MISSING" ] && ok block.lists_agents "block lists every resolved agent" \
        || bad block.lists_agents "block is missing resolved agent(s):$MISSING — re-run setup"
      THIRD="$(printf '%s' "$RESOLVED" | jq -r '[.agents[]|select(.party=="third-party")]|length')"
      if [ "$THIRD" -gt 0 ]; then
        grep -q 'third-party' "$A" && ok block.third_party_warned "block warns about third-party agents" \
          || bad block.third_party_warned "a third-party agent is permitted but the block does not say so"
      fi
    fi
  elif [ "$nb" -eq 0 ]; then
    bad block.present "no delegate block in AGENTS.md — run setup-delegate-agent"
  else
    bad block.malformed "malformed managed block ($nb begin / $ne end markers) — fix by hand"
  fi
else
  bad block.agents_md "no AGENTS.md at repo root"
fi

section "## 5. consent gate fires"
if [ -x "${BIN}/consent-gate.sh" ]; then
  probe() {
    printf '%s' "$1" | bash "${BIN}/consent-gate.sh" --tool claude 2> /dev/null \
      | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print("allow"); raise SystemExit
print(d.get("hookSpecificOutput",{}).get("permissionDecision","allow"))' 2> /dev/null || echo allow
  }
  [ "$(probe '{"tool_name":"Bash","tool_input":{"command":".agents/bin/delegate-run --prompt hi"}}')" = "deny" ] \
    && ok gate.unapproved_denied "unapproved dispatch is denied" || bad gate.unapproved_denied "unapproved dispatch was NOT denied"
  [ "$(probe '{"tool_name":"Bash","tool_input":{"command":".agents/bin/delegate-agent --agent x"}}')" = "deny" ] \
    && ok gate.direct_wrapper_denied "direct wrapper invocation is denied" || bad gate.direct_wrapper_denied "direct wrapper invocation was NOT denied"
  [ "$(probe '{"tool_name":"Bash","tool_input":{"command":".agents/bin/delegate-run --task .env --approved t1"}}')" = "deny" ] \
    && ok gate.credential_path_denied "dispatch naming a credential path is denied" || bad gate.credential_path_denied "dispatch naming a credential path was NOT denied"
  [ "$(probe '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}')" = "ask" ] \
    && ok gate.credential_read_asks "main-session credential read asks" || bad gate.credential_read_asks "main-session credential read did not ask"
  [ "$(probe '{"tool_name":"Bash","tool_input":{"command":".agents/bin/delegate-run --prompt hi --approved t1"}}')" = "allow" ] \
    && ok gate.approved_allowed "approved dispatch is allowed" || bad gate.approved_allowed "approved dispatch was blocked"
  [ "$(probe '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}')" = "allow" ] \
    && ok gate.passthrough "unrelated commands pass through" || bad gate.passthrough "gate blocked an unrelated command"
else
  bad gate.armed "consent-gate.sh not executable — the backstop is not armed"
fi

section "## 6. wiring and hygiene"
WIRED=0
for rel in .claude/settings.json .gemini/settings.json .github/hooks/delegate.json; do
  f="${REPO}/${rel}"
  [ -f "$f" ] || continue
  if is_json "$f"; then
    grep -q 'consent-gate.sh' "$f" && {
      ok wiring.tool "$rel wires the consent gate"
      WIRED=$((WIRED + 1))
    }
  else
    bad wiring.json_valid "$rel is not valid JSON"
  fi
done
[ "$WIRED" -gt 0 ] && ok wiring.any "consent gate wired into $WIRED tool(s)" \
  || warn wiring.any "gate not wired into any tool — delegate-run still enforces consent, but a raw call is not blocked"

if [ -n "$RESOLVED" ]; then
  LEAKY="$(printf '%s' "$RESOLVED" | jq -r '.agents[] | select(.settings_world_readable==true) | .settings_path' 2> /dev/null)"
  if [ -n "$LEAKY" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && warn perms.world_readable "$f is group/world readable and holds a token — chmod 600 \"$f\""
    done <<< "$LEAKY"
  else
    ok perms.world_readable "no world-readable credential file among the resolved agents"
  fi
fi
if git -C "$REPO" ls-files --error-unmatch .agents/delegate.json > /dev/null 2>&1; then
  python3 -c "import json,sys; d=json.load(open('${REPO}/.agents/delegate.json')); sys.exit(0 if 'agents' not in d else 1)" 2> /dev/null \
    && ok manifest.narrows_only "committed .agents/delegate.json narrows only" \
    || bad manifest.narrows_only "committed .agents/delegate.json defines agents — a committed manifest must only narrow"
fi
for pat in ".agents/delegate/" ".delegate-agent/"; do
  grep -qxF "$pat" "${REPO}/.gitignore" 2> /dev/null && ok gitignore.delegate_paths "gitignored: $pat" \
    || warn gitignore.delegate_paths "not gitignored: $pat — briefs and results may be committed"
done

echo
echo "Summary: $P passed, $W warnings, $F failed"

if [ "$JSON" = 1 ]; then
  exec 1>&3
  python3 - "$FINDINGS" "$REPO" "$P" "$W" "$F" << 'PY'
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
    "tool": "verify-delegate-agent",
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
[ "$F" -gt 0 ] && exit 1
exit 0
