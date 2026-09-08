#!/usr/bin/env python3
"""PreToolUse guard: let Claude USE credential files without their VALUES
entering the transcript.

Policy, in order of preference:

  rewrite -> a plain read (`cat .env`) is rewritten to `redact-view .env`, which
             prints the same file with values redacted and structure intact. Claude
             gets the shape; the transcript never sees the secret.
  ask     -> helm/Harness values files: often secret-bearing, often ordinary work.
  deny    -> commands that would *extract* or *exfiltrate* a value (base64, scp,
             openssl, source, curl). Redaction cannot help there; the whole point
             of those commands is the raw value.
  allow   -> everything else, including metadata (`ls`, `stat`, `[ -f ]`) and any
             process that merely CONSUMES a secret without printing it
             (`npm run deploy`, `kubectl --kubeconfig=...`).

Permission deny rules cover the Read/Edit tools but NOT Bash, so this hook is the
load-bearing half of the policy.
"""

import json
import os
import re
import sys


# The library sits beside this file in the payload, and one directory over once installed
# (bin/ next to scripts/). Resolve rather than hardcode, so the same file works in the skill,
# in a project-level install, and in the home layer of the cascade.
def _lib_dir():
    here = os.path.dirname(os.path.abspath(os.path.realpath(__file__)))
    for cand in (
        here,
        os.path.join(here, os.pardir, "scripts"),
        os.environ.get("SECRET_GUARD_HOME", ""),
    ):
        if cand and os.path.isfile(os.path.join(cand, "secret_redact.py")):
            return os.path.abspath(cand)
    return here


sys.path.insert(0, _lib_dir())
try:
    from secret_redact import contains_secrets, looks_configish
except Exception:  # library missing -> fall back to filename matching only
    contains_secrets = None
    looks_configish = None


def _redact_view():
    here = os.path.dirname(os.path.abspath(os.path.realpath(__file__)))
    for cand in (
        here,
        os.path.join(here, os.pardir, "bin"),
        os.environ.get("SECRET_GUARD_HOME", ""),
    ):
        if not cand:
            continue
        p = os.path.abspath(os.path.join(cand, "redact-view"))
        if os.path.isfile(p):
            return p
    return os.path.abspath(os.path.join(here, os.pardir, "bin", "redact-view"))


REDACT_VIEW = _redact_view()

# --------------------------------------------------------------- path patterns

# Files whose values must never be transcribed verbatim.
SECRET_PATTERNS = [
    r"\.env\b",
    r"\.npmrc\b",
    r"\.pypirc\b",
    r"\.netrc\b",
    r"\.pem\b",
    r"\.p12\b",
    r"\.pfx\b",
    r"\.key\b",
    r"id_rsa",
    r"id_ed25519",
    r"id_ecdsa",
    r"id_dsa",
    r"\.ssh/",
    r"kubeconfig",
    r"\.kube/",
    r"\.aws/",
    r"\.config/gcloud",
    r"\.docker/config\.json",
    r"/etc/hosts",
    r"(^|[\s'\"/=])hosts([\s'\"]|$)",
    r"\.credentials\.json",
    r"\bsecrets?\.(ya?ml|json|env)\b",
]

# Frequently secret-bearing, but also frequently ordinary work. Prompt, don't block.
ASK_PATTERNS = [
    r"values[^/\s]*\.ya?ml",
    r"/harness/",
    r"\.harness\b",
]

# --------------------------------------------------------------------- verbs

# Plain readers: safe to transparently redirect through redact-view.
# NB: no `view` -- \bview\b matches inside `redact-view` and the guard would
# rewrite its own viewer call.
REDACTABLE_VERBS = r"cat|bat|tac|nl|less|more|head|tail"

# Verbs whose entire purpose is to obtain or move the raw value. Redaction is
# meaningless here, so these stay hard-denied.
EXTRACT_VERBS = (
    r"\b(base64|openssl|xxd|od|hexdump|strings|dd|scp|rsync|curl|wget"
    r"|pbcopy|tee|nc|ncat|socat|printenv|gpg|age|keybase)\b"
)
# `source .env` / `. ./.env` load values into the environment for later echoing.
SOURCE_RE = re.compile(r"(^|[;&|]\s*)(source\s+\S|\.\s+\S)")

# Filters that would otherwise slice raw values out of a secret file. These are
# allowed, but only downstream of redact-view (see rewrite step).
FILTER_VERBS = r"\b(grep|egrep|fgrep|rg|ag|ack|awk|sed|cut|paste|sort|uniq|tr|jq|yq)\b"

SECRET_RE = re.compile("|".join(SECRET_PATTERNS), re.IGNORECASE)
ASK_RE = re.compile("|".join(ASK_PATTERNS), re.IGNORECASE)
EXTRACT_RE = re.compile(EXTRACT_VERBS, re.IGNORECASE)
FILTER_RE = re.compile(FILTER_VERBS, re.IGNORECASE)

HEREDOC_START = re.compile(r"<<-?\s*[\"\']?([A-Za-z_][A-Za-z0-9_]*)[\"\']?")

# A bare path token that looks like a secret file.
PATH_TOKEN = r"""(?:"[^"]+"|'[^']+'|[^\s|;&><]+)"""
READ_CALL = re.compile(
    rf"(?<![-/\w.])({REDACTABLE_VERBS})\b"
    rf"((?:\s+-{{1,2}}[A-Za-z0-9-]+(?:[= ]\S+)?)*)\s+({PATH_TOKEN})"
)
# An already-redacted call, so we don't re-flag our own rewrite.
REDACTED_CALL = re.compile(
    rf"""["']?(?:{re.escape(REDACT_VIEW)}|redact-view)["']?\s+(?:--all\s+)?{PATH_TOKEN}"""
)


def strip_heredocs(cmd: str) -> str:
    """Drop heredoc bodies: they are data being written, not files being read."""
    out, terminator = [], None
    for line in cmd.split("\n"):
        if terminator is not None:
            if line.strip() == terminator:
                terminator = None
            continue
        m = HEREDOC_START.search(line)
        out.append(line)
        if m:
            terminator = m.group(1)
    return "\n".join(out)


# ------------------------------------------------------------------ shell shape


# Launchers that move the rest of the line into another filesystem namespace. A read
# downstream of one of these does not open a host file, so rewriting it to the host's
# redact-view produces a path the guest cannot resolve. `ssh` is matched only as a bare
# word so `ssh-keygen` and `~/.ssh/config` do not read as remote execution.
REMOTE_EXEC_RE = re.compile(
    r"""(?:\b(?:docker|podman|nerdctl)\s+(?:exec|run)\b)"""
    r"""|(?:\bkubectl\s+exec\b)"""
    r"""|(?<!\S)ssh(?=\s)"""
    r"""|(?:\bdistrobox\s+enter\b)|(?:\btoolbox\s+run\b)"""
    r"""|(?:\bvagrant\s+ssh\b)|(?:\bheroku\s+run\b)"""
)


def quoted_mask(line: str, q=None):
    """True at each character that sits inside a shell quote, plus the quote left open.

    `q` carries the quote a previous line opened and did not close. A shell quote is
    not a line-local construct: `docker run sh -c '` opens one that stays open over
    every following line. Resetting the state per line made those lines look like
    bare commands, so a read inside an embedded script was rewritten to a host path
    that does not exist in the container -- `sh: 2: .../redact-view: not found`.

    The guard's two worst false positives both came from treating quoted text as
    shell syntax: a credential-shaped name inside a sentence, and a `cat <file>`
    inside a JSON fixture. One produced a refusal for a command that read nothing;
    the other silently REWROTE the fixture, altering data the caller was passing
    through. Knowing which characters are quoted separates a command from an
    argument that merely looks like one.
    """
    mask = [False] * len(line)
    i = 0
    while i < len(line):
        c = line[i]
        if q is None:
            if c in "\"'":
                q, mask[i] = c, True
            elif c == "\\":
                i += 1
        else:
            mask[i] = True
            if c == "\\" and q == '"':
                if i + 1 < len(line):
                    mask[i + 1] = True
                i += 1
            elif c == q:
                q = None
        i += 1
    return mask, q


def stages(cmd: str):
    """Split a command into pipeline/list stages, ignoring separators inside quotes.

    `foo ".env" | grep bar` is two stages: nothing in the second one reads the file,
    so the filter is operating on the first command's OUTPUT, not slicing a
    credential. Only a stage holding both a filter and a credential path is a slice.
    """
    mask, _ = quoted_mask(cmd)
    parts, cur, i = [], [], 0
    while i < len(cmd):
        if not mask[i] and cmd[i] in "|;&\n":
            parts.append("".join(cur))
            cur = []
            while i < len(cmd) and not mask[i] and cmd[i] in "|;&\n":
                i += 1
            continue
        cur.append(cmd[i])
        i += 1
    parts.append("".join(cur))
    return [x for x in parts if x.strip()]


def scrub(cmd: str) -> str:
    """Remove already-safe constructs before deciding anything."""
    return REDACTED_CALL.sub(" ", strip_heredocs(cmd))


# Config formats that can carry credentials. A read of one of these is routed
# through redact-view even when the path cannot be resolved here (shell variables,
# command substitution) -- the viewer re-decides at runtime with the real path,
# and returns clean files byte-identical, so the detour is invisible.
CONFIGISH_EXT = re.compile(
    r"\.(json|ya?ml|ini|cfg|conf|toml|properties|env|npmrc|netrc|pypirc)"
    r"(\.[A-Za-z0-9_-]+)?$|(^|/)\.env(\.|$)|kubeconfig",
    re.IGNORECASE,
)


def configish_token(token: str) -> bool:
    t = token.strip().strip("\"'")
    # A shell-variable path still exposes its extension; that is enough to route.
    return bool(CONFIGISH_EXT.search(t))


def _resolve(token: str, cwd: str) -> str:
    """Strip shell quoting and resolve relative to the session cwd."""
    t = token.strip()
    if len(t) >= 2 and t[0] == t[-1] and t[0] in "\"'":
        t = t[1:-1]
    t = os.path.expanduser(t)
    if not os.path.isabs(t) and cwd:
        t = os.path.join(cwd, t)
    return t


def leaks(token: str, cwd: str) -> bool:
    """Would reading this token's file raw put a credential in the transcript?

    Filename patterns catch the well-known names. The content probe catches the
    rest -- an ordinary `appsettings.json` whose `database.password` is set.
    """
    if SECRET_RE.search(token):
        return True
    path = _resolve(token, cwd)
    resolved = False
    try:
        resolved = os.path.isfile(path)
    except Exception:
        resolved = False

    if resolved and contains_secrets is not None:
        try:
            if contains_secrets(path):
                return True
        except Exception:
            pass
        # Resolvable and demonstrably clean -> read it raw, no detour.
        return False

    # Unresolvable (shell variable, substitution): fall back to the extension and
    # let redact-view arbitrate at runtime. Clean files pass through unchanged.
    return configish_token(token)


def emit(decision: str, reason: str, updated=None):
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }
    }
    if updated is not None:
        out["hookSpecificOutput"]["updatedInput"] = updated
    json.dump(out, sys.stdout)
    sys.exit(0)


def rewrite_reads(cmd: str, cwd: str = ""):
    """Redirect plain reads of credential-bearing files through redact-view.

    Returns (new_command, [paths_rewritten], [paths_embedded]).

    `paths_embedded` are credential reads sitting inside a quoted script that a
    previous line opened -- an embedded shell (`docker run sh -c '...'`, `ssh host
    '...'`). They are deliberately NOT rewritten: the viewer is a host path with no
    meaning in that namespace. They are reported instead, because silently passing
    one through would print the raw value that this guard exists to withhold.
    """
    touched = []
    embedded = []
    line_mask = []
    carried = False
    remote_at = None

    def repl(m):
        verb, flags, path = m.group(1), m.group(2) or "", m.group(3)
        # A read whose VERB is inside quotes is data being passed along -- a fixture, a
        # message, a command being described -- not a command being run. Rewriting there
        # corrupts the caller's argument, which is worse than any decision this hook makes:
        # it changes what the command does. The operand may still be quoted (`cat ".env"`
        # is an ordinary read); it is the verb's position that settles it.
        masked = m.start(1) < len(line_mask) and line_mask[m.start(1)]
        # `carried` -> inside a quote a previous line opened (a multi-line -c script).
        # `remote_at` -> a launcher earlier on this line already crossed the boundary.
        nested = carried or (remote_at is not None and m.start(1) > remote_at)
        if masked or nested:
            if nested and SECRET_RE.search(path):
                embedded.append(path)
            return m.group(0)
        if not leaks(path, cwd):
            return m.group(0)
        touched.append(path)
        # head/tail keep their line limits by piping after redaction.
        if verb in ("head", "tail") and flags.strip():
            return f'"{REDACT_VIEW}" {path} | {verb}{flags}'
        return f'"{REDACT_VIEW}" {path}'

    # Apply only outside heredoc bodies: text inside one is a document being
    # written, not a command being run. Rewriting there would corrupt the file.
    out, terminator, pending = [], None, None
    for line in cmd.split("\n"):
        if terminator is not None:
            out.append(line)
            if line.strip() == terminator:
                terminator = None
            continue
        carried = pending is not None
        line_mask, pending = quoted_mask(line, pending)
        remote_at = None
        for rm in REMOTE_EXEC_RE.finditer(line):
            if rm.start() >= len(line_mask) or not line_mask[rm.start()]:
                remote_at = rm.start()
                break
        m = HEREDOC_START.search(line)
        if m:
            # The command part precedes the heredoc marker; body starts next line.
            terminator = m.group(1)
            out.append(READ_CALL.sub(repl, line))
            continue
        out.append(READ_CALL.sub(repl, line))
    return "\n".join(out), touched, embedded


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # never let a malformed payload wedge the session

    tool = payload.get("tool_name", "")
    ti = payload.get("tool_input") or {}

    # ---- Grep: only content mode leaks; -l / -c are safe ---------------------
    if tool == "Grep":
        if (ti.get("output_mode") or "files_with_matches") != "content":
            sys.exit(0)
        target = " ".join(str(ti.get(k, "")) for k in ("path", "glob"))
        if SECRET_RE.search(target):
            emit(
                "deny",
                "Grep in content mode would print raw secret lines. Read the file "
                f'through the redacting viewer instead: `"{REDACT_VIEW}" <file> | grep ...`',
            )
        sys.exit(0)

    if tool != "Bash":
        sys.exit(0)

    original = ti.get("command", "")
    if not original:
        sys.exit(0)

    cwd = payload.get("cwd") or os.getcwd()
    probe = scrub(original)

    # Content probe: a plain read of an innocuously-named file that nonetheless
    # holds credentials must still be redirected through the viewer.
    if not SECRET_RE.search(probe):
        rewritten, touched, _ = rewrite_reads(original, cwd)
        if touched:
            new_input = dict(ti)
            new_input["command"] = rewritten
            emit(
                "allow",
                f"Redirected through redact-view ({', '.join(touched)}): this file "
                f"holds credential-shaped values. Structure preserved, values redacted.",
                updated=new_input,
            )

    if not SECRET_RE.search(probe):
        # No secret path left once safe constructs are removed.
        if ASK_RE.search(probe) and (
            FILTER_RE.search(probe) or READ_CALL.search(probe)
        ):
            hit = ASK_RE.search(probe)
            emit(
                "ask",
                f"This reads a helm/Harness values file ({hit.group(0).strip()!r}), which "
                f"often carries secrets. Approve to see it raw, or cancel and use "
                f'`"{REDACT_VIEW}" <file>` for a redacted view.',
            )
        sys.exit(0)

    # ---- extraction / exfiltration: redaction cannot help --------------------
    if EXTRACT_RE.search(probe) or SOURCE_RE.search(probe):
        verb = (EXTRACT_RE.search(probe) or SOURCE_RE.search(probe)).group(0).strip()
        emit(
            "deny",
            f"Blocked: `{verb}` on a credential file would put the raw value in the "
            f"transcript. If a process needs the secret, let it read the file itself "
            f"(it inherits the environment) — you do not need to see the value. For "
            f'structure only: `"{REDACT_VIEW}" <file>`.',
        )

    # ---- plain read: rewrite through the redacting viewer --------------------
    rewritten, touched, embedded = rewrite_reads(original, cwd)

    # A credential read inside an embedded shell: redaction cannot cross the
    # namespace boundary, so there is no rewrite that both works and withholds the
    # value. Ask rather than deny -- the operator may have a reason, and a guard
    # that refuses outright is a guard that gets switched off.
    if embedded:
        emit(
            "ask",
            f"`{', '.join(sorted(set(embedded)))}` is read inside an embedded shell "
            f"(docker/ssh/-c script). redact-view is a host path with no meaning in "
            f"that namespace, so the value would reach the transcript unredacted. "
            f"Prefer running the read on the host, or redacting inside the guest.",
        )

    if touched:
        leftover = scrub(rewritten)
        if not SECRET_RE.search(leftover) or not FILTER_RE.search(leftover):
            new_input = dict(ti)
            new_input["command"] = rewritten
            emit(
                "allow",
                f"Redirected through redact-view ({', '.join(touched)}): values are "
                f"redacted to a length + sha256 fingerprint, structure preserved.",
                updated=new_input,
            )

    # ---- filters aimed straight at a secret file ----------------------------
    # Same stage, not merely the same command line. `something ".env" | grep x` puts the
    # filter on the first command's output; it never opens the file, and refusing it taught
    # people to rewrite honest commands until the guard stopped objecting -- which is how a
    # guard trains the habit it exists to prevent.
    for stage in stages(probe):
        if FILTER_RE.search(stage) and SECRET_RE.search(stage):
            emit(
                "deny",
                "Blocked: this would slice raw values out of a credential file. Pipe from "
                f'the redacting viewer instead: `"{REDACT_VIEW}" <file> | grep ...` — key '
                f"names and structure survive, values do not.",
            )

    # A secret path is present but nothing prints it (e.g. `kubectl --kubeconfig=x`).
    sys.exit(0)


if __name__ == "__main__":
    main()
