#!/usr/bin/env bash
# verify-secret-guard.sh — read-only health check for an installed secret guard.
#
#   verify-secret-guard.sh [--json]
#
# READ-ONLY: never writes to the installed layer, never edits settings, never contacts anything.
# It exercises the guard with synthetic stdin (which only prints a decision) and scans fixtures
# it creates in a temp directory, so running it cannot change what it measures.
#
# It asserts the guard DECIDES CORRECTLY, not that files exist. Checking for a file proves an
# install happened; firing the hook with a tool's own stdin shape proves it works, and those are
# different claims. The harness owns the other half — asserting a planted value never appears in
# output — because that belongs on synthetic data in a sandbox. This runs in a live environment,
# so it never prints a fixture's value, even on failure.
#
# Exits non-zero if any [FAIL]. Warnings never fail: an absent repo layer, a payload one version
# behind, unmanaged duplicate deny rules — information rather than breakage.
#
# --json emits every finding as a machine-readable object instead of prose. Much of what this
# checks is ADVISORY by design and none of it changes the exit code, so a grader reading only the
# exit status is blind to exactly the checks most likely to rot. This is the channel that makes
# them gradeable. Every finding carries a STABLE ID naming the CHECK, with `level` carrying the
# outcome, so a grader asserts "payload.version.behind came back warn" rather than matching prose
# that any rewording breaks.

set -uo pipefail
JSON=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    -h | --help)
      sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

SKILL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${SECRET_GUARD_HOME:-$HOME/.claude}"
P=0
F=0
W=0
FINDINGS="$(mktemp)"
TMP="$(mktemp -d)"
SECTION=""
cleanup() {
  rm -f "$FINDINGS"
  find "$TMP" -type f -delete 2> /dev/null
  rmdir "$TMP" 2> /dev/null
}
trap cleanup EXIT

section() {
  SECTION="$1"
  if [ "$JSON" -eq 0 ]; then
    echo
    echo "$1"
    printf '%s\n' "$(printf '%*s' "${#1}" '' | tr ' ' '-')"
  fi
}
emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$SECTION" "$(printf '%s' "$3" | tr '\t\n' '  ')" >> "$FINDINGS"; }
ok() {
  emit pass "$1" "$2"
  P=$((P + 1))
  [ "$JSON" -eq 1 ] || printf '  [PASS] %s\n' "$2"
}
bad() {
  emit fail "$1" "$2"
  F=$((F + 1))
  [ "$JSON" -eq 1 ] || printf '  [FAIL] %s\n' "$2"
}
warn() {
  emit warn "$1" "$2"
  W=$((W + 1))
  [ "$JSON" -eq 1 ] || printf '  [warn] %s\n' "$2"
}

# --------------------------------------------------------------------------- 1. the payload

section "## 1. engine present"
for rel in scripts/secret_redact.py scripts/secret-file-guard.py bin/redact-view bin/secret-scan; do
  if [ -f "${HOME_DIR}/${rel}" ]; then
    ok "engine.${rel##*/}" "${rel} installed"
  else
    bad "engine.${rel##*/}" "${rel} missing — run setup-secret-guard.sh"
  fi
done
for rel in bin/redact-view bin/secret-scan scripts/secret-file-guard.py; do
  if [ -f "${HOME_DIR}/${rel}" ] && [ ! -x "${HOME_DIR}/${rel}" ]; then
    bad "engine.executable" "${rel} is not executable — the guard cannot run it"
  fi
done

INSTALLED="$(awk 'NR==1{print $2}' "${HOME_DIR}/scripts/.secret-guard.version" 2> /dev/null || true)"
SHIPPED="$(awk 'NR==1{print $2}' "${SKILL}/scripts/payload.version" 2> /dev/null || true)"
if [ -z "$SHIPPED" ]; then
  warn "payload.version.unreadable" "cannot read the version this skill ships"
elif [ -z "$INSTALLED" ]; then
  warn "payload.version.unknown" "payload version unknown (pre-versioning install) — re-run setup-secret-guard.sh"
elif [ "$INSTALLED" -lt "$SHIPPED" ] 2> /dev/null; then
  warn "payload.version.behind" "payload v${INSTALLED} installed, skill ships v${SHIPPED} — re-run setup-secret-guard.sh"
elif [ "$INSTALLED" -gt "$SHIPPED" ] 2> /dev/null; then
  warn "payload.version.ahead" "payload v${INSTALLED} installed is newer than the skill's v${SHIPPED} — this skill copy is stale"
else
  ok "payload.version" "payload v${INSTALLED} matches the version the skill ships"
fi

# Content drift is a different question from version drift: the stamp can match while a file
# has been edited underneath it.
DRIFT=0
for pair in "scripts/secret_redact.py:secret_redact.py" "scripts/secret-file-guard.py:secret-file-guard.py" "bin/redact-view:redact-view" "bin/secret-scan:secret-scan"; do
  inst="${HOME_DIR}/${pair%%:*}"
  src="${SKILL}/scripts/payload/${pair##*:}"
  if [ -f "$inst" ] && [ -f "$src" ] && ! cmp -s "$inst" "$src"; then
    DRIFT=$((DRIFT + 1))
  fi
done
if [ "$DRIFT" -gt 0 ]; then
  warn "payload.content.drift" "${DRIFT} installed file(s) differ from the shipped payload — re-run with --adopt to take the skill's copy"
else
  ok "payload.content" "installed files match the shipped payload byte for byte"
fi

if grep -rqnI --exclude-dir=__pycache__ '/Users/\|/home/[a-z]' "${SKILL}/scripts/payload" 2> /dev/null; then
  bad "payload.depersonalised" "the shipped payload contains an absolute user path — it is bound to one machine"
else
  ok "payload.depersonalised" "no absolute user paths in the shipped payload"
fi

# ------------------------------------------------------------------------ 2. the engine works

section "## 2. engine decides correctly"
SCAN="${HOME_DIR}/bin/secret-scan"
VIEW="${HOME_DIR}/bin/redact-view"
if [ -x "$SCAN" ] && [ -x "$VIEW" ]; then
  printf 'SERVICE=billing\nDB_PASSWORD=not-a-real-password-000\n' > "${TMP}/sample-config"
  printf '{ "name": "acme", "port": 8080 }\n' > "${TMP}/clean.json"

  if "$SCAN" --quiet "${TMP}/sample-config" > /dev/null 2>&1; then
    ok "engine.detects" "a credential-bearing config is detected"
  else
    bad "engine.detects" "a credential-bearing config was reported clean"
  fi
  if "$SCAN" --quiet "${TMP}/clean.json" > /dev/null 2>&1; then
    bad "engine.no_false_positive" "an ordinary config was reported as holding a credential"
  else
    ok "engine.no_false_positive" "an ordinary config passes clean"
  fi
  # The value must never survive into the viewer's output.
  if "$VIEW" "${TMP}/sample-config" 2> /dev/null | grep -q 'not-a-real-password-000'; then
    bad "engine.masks" "the viewer printed a value it should have redacted"
  else
    ok "engine.masks" "the viewer redacts the value"
  fi
  if "$VIEW" "${TMP}/clean.json" 2> /dev/null | cmp -s - "${TMP}/clean.json"; then
    ok "engine.passthrough" "a clean file passes through byte-identical"
  else
    bad "engine.passthrough" "the viewer rewrote a file with nothing to redact"
  fi
  # Findings name the rule, never the value.
  if "$SCAN" "${TMP}/sample-config" 2> /dev/null | grep -q 'not-a-real-password-000'; then
    bad "engine.findings_quiet" "a finding echoed the value it matched"
  else
    ok "engine.findings_quiet" "findings name the rule, not the value"
  fi
else
  bad "engine.runnable" "secret-scan or redact-view is missing or not executable"
fi

# ------------------------------------------------------------------------- 3. the hook fires

section "## 3. read-path guard fires"
GUARD="${HOME_DIR}/scripts/secret-file-guard.py"
if [ -f "$GUARD" ]; then
  probe() { # probe <json-payload> -> allow|ask|deny
    printf '%s' "$1" | python3 "$GUARD" 2> /dev/null | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("allow"); raise SystemExit
try:
    d = json.loads(raw)
except Exception:
    print("badjson"); raise SystemExit
o = d.get("hookSpecificOutput", {})
print(o.get("permissionDecision", "allow"))' 2> /dev/null || echo allow
  }
  rewritten() { # true when the guard substituted a redact-view command
    printf '%s' "$1" | python3 "$GUARD" 2> /dev/null | grep -q 'redact-view'
  }

  # Assembled indirectly so this script never carries a literal credential path on a line
  # that another tool might scan.
  DOTENV=".$(printf 'env')"
  payload_for() { # payload_for <command-string> -> a PreToolUse envelope
    # Built with a real JSON encoder, not printf. A probe command containing a quote used to
    # produce malformed JSON, the guard bailed out of parsing it and returned allow, and the
    # probe passed without exercising anything -- a test that cannot fail is worse than none.
    python3 -c 'import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))' "$1"
  }

  PL="$(payload_for "cat ${DOTENV}")"
  if rewritten "$PL"; then
    ok "guard.rewrites_read" "a plain credential read is routed through the viewer"
  else
    bad "guard.rewrites_read" "a plain credential read was NOT routed through the viewer"
  fi

  # The rewrite is only as good as the command it produces. Asserting that the output
  # mentions redact-view proves the guard INTENDED something; running what it emitted proves
  # the intention was right. A resolver that picks a path which does not exist would turn a
  # plain read into a broken command -- worse than allowing or denying it.
  printf 'SERVICE=billing\nDB_PASSWORD=not-a-real-password-000\n' > "${TMP}/probe${DOTENV}"
  PL="$(payload_for "cat ${TMP}/probe${DOTENV}")"
  REWRITE="$(printf '%s' "$PL" | python3 "$GUARD" 2> /dev/null | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print(""); raise SystemExit
try:
    d = json.loads(raw)
except Exception:
    print(""); raise SystemExit
u = d.get("hookSpecificOutput", {}).get("updatedInput") or d.get("updatedInput") or {}
print(u.get("command", ""))' 2> /dev/null || true)"
  if [ -n "$REWRITE" ]; then
    RESULT="$(eval "$REWRITE" 2> /dev/null || true)"
    if printf '%s' "$RESULT" | grep -q 'not-a-real-password-000'; then
      bad "guard.rewrite_runs" "the command the guard substituted printed the value it was meant to redact"
    elif printf '%s' "$RESULT" | grep -q 'redacted'; then
      ok "guard.rewrite_runs" "the substituted command actually runs and redacts"
    else
      bad "guard.rewrite_runs" "the substituted command did not produce a redacted view — the viewer it names may not resolve"
    fi
  else
    bad "guard.rewrite_runs" "the guard produced no rewritten command for a plain credential read"
  fi

  PL="$(payload_for "base64 ${DOTENV}")"
  D="$(probe "$PL")"
  if [ "$D" = "deny" ]; then
    ok "guard.denies_extraction" "an extraction verb on a credential file is denied"
  else
    bad "guard.denies_extraction" "an extraction verb on a credential file was not denied (decided ${D})"
  fi

  PL="$(payload_for "ls -la")"
  D="$(probe "$PL")"
  if [ "$D" = "allow" ]; then
    ok "guard.passthrough" "an unrelated command passes through"
  else
    bad "guard.passthrough" "the guard blocked an unrelated command — it is wedging the session"
  fi

  # A filter aimed at the credential file is the reason this rule exists, and it stays denied.
  PL="$(payload_for "grep TOKEN ${DOTENV}")"
  D="$(probe "$PL")"
  if [ "$D" = "deny" ]; then
    ok "guard.filter_denied" "a filter aimed at a credential file is denied"
  else
    bad "guard.filter_denied" "a filter aimed at a credential file was not denied (decided ${D})"
  fi

  # ...but only when it is aimed at the file. A filter downstream of some other command is
  # reading that command's output, not the file, and refusing it taught people to rewrite
  # honest commands until the guard stopped objecting.
  PL="$(payload_for "somecmd --note \"fixed the staging${DOTENV} case\" | grep -v Wrote")"
  D="$(probe "$PL")"
  if [ "$D" = "allow" ]; then
    ok "guard.no_false_deny_downstream" "a filter downstream of an unrelated command is allowed"
  else
    bad "guard.no_false_deny_downstream" "credential-shaped text in an argument was refused (decided ${D}) — the filter never touched the file"
  fi

  # The worse half of the same confusion: rewriting a read that is quoted DATA changes what
  # the caller's command does, rather than merely refusing it.
  PL="$(payload_for "printf '%s' '{\"command\":\"cat ${DOTENV}\"}' | parse.py")"
  RW="$(printf '%s' "$PL" | python3 "$GUARD" 2> /dev/null | grep -c 'updatedInput' || true)"
  if [ "$RW" = "0" ]; then
    ok "guard.no_rewrite_of_quoted_data" "a read quoted inside an argument is left alone"
  else
    bad "guard.no_rewrite_of_quoted_data" "the guard rewrote a read that was quoted data — it altered the caller's argument"
  fi

  PL="$(payload_for "kubectl --kubeconfig=/tmp/kc get pods")"
  D="$(probe "$PL")"
  if [ "$D" = "allow" ]; then
    ok "guard.consumer_allowed" "a process that merely consumes a credential is allowed"
  else
    bad "guard.consumer_allowed" "a process consuming a credential was blocked — it never needed the value"
  fi
else
  bad "guard.present" "secret-file-guard.py missing — the read path is unguarded"
fi

# ------------------------------------------------------------------------------ 4. wiring

section "## 4. wiring"
SETTINGS="${HOME_DIR}/settings.json"
if [ -f "$SETTINGS" ]; then
  if python3 -c "import json,sys; json.load(open('$SETTINGS'))" 2> /dev/null; then
    ok "wiring.json_valid" "settings.json is valid JSON"
    HOOKED="$(python3 -c "
import json
d = json.load(open('$SETTINGS'))
print(sum(1 for g in d.get('hooks', {}).get('PreToolUse', [])
          for h in g.get('hooks', [])
          if 'secret-file-guard' in str(h.get('command', ''))))" 2> /dev/null || echo 0)"
    if [ "$HOOKED" = "1" ]; then
      ok "wiring.hook" "the guard is wired as a PreToolUse hook exactly once"
    elif [ "$HOOKED" = "0" ]; then
      bad "wiring.hook" "the guard is not wired into settings.json — nothing intercepts a read"
    else
      warn "wiring.hook.duplicated" "the guard is wired ${HOOKED} times — it will run more than once per call"
    fi
    DENY="$(python3 -c "
import json
d = json.load(open('$SETTINGS'))
print(len(d.get('permissions', {}).get('deny', [])))" 2> /dev/null || echo 0)"
    if [ "$DENY" -gt 0 ]; then
      ok "wiring.deny" "${DENY} deny rules present for the tools a hook cannot filter"
    else
      bad "wiring.deny" "no deny rules — Read and Edit are unguarded"
    fi
    DUPES="$(python3 -c "
import json
d = json.load(open('$SETTINGS'))
r = d.get('permissions', {}).get('deny', [])
print(len(r) - len(set(r)))" 2> /dev/null || echo 0)"
    if [ "$DUPES" -gt 0 ]; then
      warn "wiring.deny.duplicates" "${DUPES} EXACT duplicate deny rule(s) — harmless. Note a '//' twin of a '**/' rule is NOT a duplicate: one anchors at the working directory, the other at the filesystem root, and both are needed."
    fi
  else
    bad "wiring.json_valid" "settings.json is not valid JSON — the hook cannot load"
  fi
else
  bad "wiring.settings" "no settings.json at ${HOME_DIR} — run setup-secret-guard.sh"
fi

# ------------------------------------------------------------------------- 5. selftestable

section "## 5. helpers self-test"
for h in splice-agents-block merge-settings; do
  if [ -f "${SKILL}/scripts/${h}.py" ]; then
    if python3 "${SKILL}/scripts/${h}.py" --selftest > /dev/null 2>&1; then
      ok "selftest.${h}" "${h}.py selftest passes"
    else
      bad "selftest.${h}" "${h}.py selftest FAILS — its own assertions do not hold"
    fi
  else
    bad "selftest.${h}" "${h}.py missing"
  fi
done

# ---------------------------------------------------------------------------------- output

if [ "$JSON" -eq 1 ]; then
  python3 - "$FINDINGS" << 'PY'
import json, sys
out = []
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 4:
            out.append({"level": parts[0], "id": parts[1], "section": parts[2], "message": parts[3]})
print(json.dumps({"findings": out,
                  "passed": sum(1 for f in out if f["level"] == "pass"),
                  "warnings": sum(1 for f in out if f["level"] == "warn"),
                  "failed": sum(1 for f in out if f["level"] == "fail")}, indent=2))
PY
else
  echo
  echo "Summary: ${P} passed, ${W} warnings, ${F} failed"
fi

[ "$F" -eq 0 ] || exit 1
exit 0
