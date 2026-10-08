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

import bisect
import json
import os
import re
import sys
from typing import NamedTuple


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
    from secret_redact import MAX_BYTES, contains_secrets, looks_configish
    from secret_redact import _logical_name as logical_name
except Exception:  # library missing -> fall back to filename matching only
    MAX_BYTES = 2 * 1024 * 1024
    contains_secrets = None
    looks_configish = None

    def logical_name(name):
        return name


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
    r"\.envrc\b",
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
# A flag's VALUE stops at a shell separator, exactly as a path token does. `\S+` here
# did not: in `head -20 /etc/passwd; cat .env` the value ran on through `/etc/passwd;`,
# so this match's "path" became `cat` -- the real credential read was swallowed by the
# earlier match, never re-examined by the next `sub()` scan, and never rewritten. Nothing
# was denied either, because `cat` is not a secret-looking path, so the command simply ran
# and printed the file. See secret-guard-compound-cat-bypass-handoff.
FLAG_VALUE = PATH_TOKEN
READ_CALL = re.compile(
    rf"(?<![-/\w.])({REDACTABLE_VERBS})\b"
    rf"((?:\s+-{{1,2}}[A-Za-z0-9-]+(?:[= ]{FLAG_VALUE})?)*)\s+({PATH_TOKEN})"
)
# An already-redacted call, so we don't re-flag our own rewrite.
REDACTED_CALL = re.compile(
    rf"""["']?(?:{re.escape(REDACT_VIEW)}|redact-view)["']?\s+(?:--(?:all|yaml|diff)\s+)*{PATH_TOKEN}"""
)


def strip_heredocs(cmd: str) -> str:
    """Drop heredoc bodies: they are data being written, not files being read."""
    return "\n".join(line for line, _, kind, _ in _heredoc_lines(cmd) if kind == "cmd")


# ------------------------------------------------------------------ shell shape


# Launchers that move the rest of the line into another filesystem namespace. A read
# downstream of one of these does not open a host file, so rewriting it to the host's
# redact-view produces a path the guest cannot resolve. `ssh` is matched only as a bare
# word so `ssh-keygen` and `~/.ssh/config` do not read as remote execution.
#
# Every entry here WIDENS a pass-through, so each one is a security trade rather than a
# convenience: downstream reads stop being redacted, and only credential-named ones ask.
# The bar for adding one is that it unambiguously crosses a namespace boundary. Note the
# bare-`ssh` branch already covers the cloud wrappers that end in a bare `ssh` word --
# `gcloud compute ssh`, `az vm ssh`, `fly ssh console` -- so those need no entry of their
# own; adding them would only widen the match without changing a decision.
#
# `compose` is called out separately because the subcommand sits between the binary and
# `exec`: `docker compose exec` does not match `docker\s+exec`, so it was being rewritten
# to a host path -- the same `redact-view: not found` breakage this pattern exists to stop.
REMOTE_EXEC_RE = re.compile(
    r"""(?:\b(?:docker|podman|nerdctl)\s+(?:exec|run)\b)"""
    r"""|(?:\b(?:docker|podman|nerdctl)\s+compose\s+(?:exec|run)\b)"""
    r"""|(?:\bkube(?:ctl|color)\s+exec\b)"""
    r"""|(?<!\S)ssh(?=\s)"""
    r"""|(?:\bdistrobox\s+enter\b)|(?:\btoolbox\s+run\b)"""
    r"""|(?:\bvagrant\s+ssh\b)|(?:\bheroku\s+run\b)"""
    r"""|(?:\blimactl\s+shell\b)|(?:\bmultipass\s+(?:exec|shell)\b)"""
    r"""|(?:\b(?:incus|lxc)\s+exec\b)"""
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
    r"\.(jsonl?|ndjson|ya?ml|ini|cfg|conf|toml|properties|env|npmrc|netrc|pypirc)"
    r"(\.[A-Za-z0-9_-]+)?$|(^|/)\.env(\.|$)|kubeconfig",
    re.IGNORECASE,
)


def configish_token(token: str) -> bool:
    t = token.strip().strip("\"'")
    # A shell-variable path still exposes its extension; that is enough to route. A backup
    # copy buries it under suffixes (`app.yaml.pre-rotation.20260913`), so judge the name the
    # file had before it was backed up -- the same stripping the engine applies to real paths.
    return bool(
        CONFIGISH_EXT.search(t)
        or CONFIGISH_EXT.search(logical_name(os.path.basename(t)))
    )


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
    # A path the shell has yet to expand -- a variable, a substitution -- cannot be opened here,
    # and its name may say nothing (`config.uat`). The viewer re-decides at runtime with the
    # real path and prints a clean file byte-identical, so routing it costs nothing. A token
    # starting with `-` or `+` is an option (`head -$N`, `less +$LINE`), never a path.
    bare = token.strip("\"'")
    if ("$" in token or "`" in token) and not bare.startswith(("-", "+")):
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


# ------------------------------------------------------- cluster-API producers

# Commands that pull credentials from a cluster API instead of a file. They name no path, so
# nothing above sees them: `argocd app get APP -o json` printed an Application's inline Helm
# values, client secrets included, and the guard neither rewrote, asked, nor denied. Each is
# routed through the viewer by inserting it straight after the producer, so a downstream `jq`
# or `head` still works -- on redacted text with its structure intact. Clean output passes
# byte-identical, so the detour costs nothing where there is nothing to hide.
#
# One line per producer; adding one is a one-line change. A pattern never crosses a shell
# separator, so it cannot pair a binary in one stage with a subcommand in the next.
_BIN = r"(?<![\w.-])(?:[\w./-]*/)?{}(?![\w-])[^|;&\n]*?\s"
# `kubecolor` wraps kubectl with the same arguments; on this machine kubectl is aliased to it.
KUBECTL = "(?:kubectl|kubecolor)"
PRODUCERS = [
    ("argocd app get", re.compile(_BIN.format("argocd") + r"app\s+get(?![\w-])", re.I)),
    (
        "argocd app manifests",
        re.compile(_BIN.format("argocd") + r"app\s+manifests(?![\w-])", re.I),
    ),
    # Argo CD masks a Secret's data in a diff, but not always all of it: CVE-2026-45737
    # leaked values through the last-applied annotation. The viewer's in-place redaction of
    # embedded JSON reads through the diff's `<`/`>` markers.
    (
        "argocd app diff",
        re.compile(_BIN.format("argocd") + r"app\s+diff(?![\w-])", re.I),
    ),
    (
        "helm get",
        re.compile(
            _BIN.format("helm") + r"get\s+(?:values|manifest|all|hooks)(?![\w-])", re.I
        ),
    ),
    ("helm template", re.compile(_BIN.format("helm") + r"template(?![\w-])", re.I)),
    ("kubectl get", re.compile(_BIN.format(KUBECTL) + r"get(?![\w-])", re.I)),
    # `--raw` and `--flatten` print the kubeconfig's tokens and keys; the default view redacts
    # them itself, so _classify routes it only with one of those flags.
    (
        "kubectl config view",
        re.compile(_BIN.format(KUBECTL) + r"config\s+view(?![\w-])", re.I),
    ),
]

# `kubectl get` prints a table unless asked for a document; only the document formats carry
# values. A template format prints one bare scalar, which no viewer can redact by structure.
# kubectl's flag parser joins boolean shorthands with `-o` (`-Ao yaml` is `-A -o yaml`). Only the
# boolean ones may precede it: `-n` takes a value, so `-nfoo` is a namespace, never an `-o`.
KUBE_OUTPUT_RE = re.compile(
    r"""(?:\s-[ARwh]*o(?:=|\s*)|\s--output(?:=|\s+))["']?([\w-]+)"""
)
KUBE_TEMPLATE_RE = re.compile(r"\s--template(?:=|\s)")
KUBE_SECRET_RE = re.compile(r"[\s,]secrets?(?![\w-])", re.IGNORECASE)
DOC_FORMATS = ("yaml", "json")

# Downstream of a producer, these exist to obtain or move a raw value. `tee` is not here: after
# the viewer it writes the redacted text, which is exactly what a saved copy should hold.
PIPE_EXTRACT_RE = re.compile(
    r"\b(base64|openssl|xxd|od|hexdump|strings|scp|rsync|curl|wget"
    r"|pbcopy|nc|ncat|socat|gpg|age|keybase)\b"
)
# What runs a quoted string as a script. A producer inside one executes, so it is not data.
# The allowlist is the honest runners (ADR 0026). Interpreter one-liners (`python3 -c
# "os.system(...)"`) are the documented cooperative limit, not an omission.
SCRIPT_RUNNER_RE = re.compile(
    r"(?<![\w./-])(?:[\w./-]*/)?(?:ba|z|da|k|fi)?sh(?![\w-])"
    r"|(?<![\w-])(?:eval|watch|xargs|parallel|su|runuser|script|flock)(?![\w-])"
    r"|(?<![\w-])sudo\s+-[A-Za-z]*[is](?![\w-])"
)
# A heredoc is a script when it is fed to a runner above or to an interpreter.
HEREDOC_RUNNER_RE = re.compile(
    SCRIPT_RUNNER_RE.pattern
    + r"|(?<![\w./-])(?:[\w./-]*/)?(?:python3?|perl|node|ruby|make)(?![\w-])"
)
# A redirection of stdout. `2>` and `2>&1` leave stdout alone. Anything else moves it: to a
# file a later read can print raw, to stderr, or back to stdout by another name (`>&1`,
# `/dev/fd/1`). Only `/dev/null` is provably silent.
STDOUT_REDIR_RE = re.compile(r"(?<![<>&\d])(?:1|&)?>>?\|?\s*(&?\S*)")
SILENT_TARGETS = ("/dev/null",)
# `exec >file` redirects every later command in the shell, the producer included.
EXEC_REDIR_RE = re.compile(r"(?<![\w-])exec\s+(?:\d*|&)>")


# One escape inside bash's ANSI-C quoting, `$'...'`. bash decodes these before the command sees
# them, so `-o $'\x79aml'` is `-o yaml`.
ANSI_ESC_RE = re.compile(
    r"\\(x[0-9A-Fa-f]{1,2}|u[0-9A-Fa-f]{1,4}|U[0-9A-Fa-f]{1,8}|[0-7]{1,3}|c.|.)", re.S
)
ANSI_SIMPLE = {
    "n": "\n",
    "t": "\t",
    "r": "\r",
    "a": "\a",
    "b": "\b",
    "e": "\x1b",
    "E": "\x1b",
    "f": "\f",
    "v": "\v",
    "\\": "\\",
    "'": "'",
    '"': '"',
    "?": "?",
}


def _ansi_char(seq: str):
    """The character an ANSI-C escape decodes to, or None when bash keeps it as written."""
    kind = seq[0]
    try:
        if kind in "xuU":
            return chr(int(seq[1:], 16))
        if kind.isdigit():
            return chr(int(seq, 8) & 0xFF)
    except (ValueError, OverflowError):
        return None
    if kind == "c" and len(seq) == 2:
        return chr(ord(seq[1]) & 0x1F)
    return ANSI_SIMPLE.get(kind)


def _exec_mask(cmd: str):
    """Per character: True where the shell executes it as code.

    quoted_mask() calls every quoted character data, which is right for a read's verb --
    `echo "cat .env"` runs nothing. For a producer it is wrong in one place: `$( )` inside
    double quotes is code, and `echo "$(argocd app get APP -o json)"` prints the output.

    Returns (code, drop, subst): `drop` marks characters the shell consumes, and `subst` maps
    the first character of an ANSI-C escape to the character bash decodes it to.
    """
    code = [True] * len(cmd)
    subst = {}
    # Characters the shell consumes rather than passes on: quote delimiters, escaping
    # backslashes, and the newline of a line continuation. Removing them yields the words
    # the command actually receives -- `ya'ml'` is `yaml`, `kube\ctl` is `kubectl`.
    drop = [False] * len(cmd)

    def escape(at, live):
        drop[at] = at + 1 < len(cmd) and (live is None or cmd[at + 1] in live)
        if at + 1 < len(cmd) and cmd[at + 1] == "\n":
            drop[at + 1] = True

    stack = ["top"]
    i = 0
    while i < len(cmd):
        c, top = cmd[i], stack[-1]
        if top == "ansi":
            code[i] = False
            if c == "'":
                stack.pop()
                drop[i] = True
            elif c == "\\":
                esc = ANSI_ESC_RE.match(cmd, i)
                decoded = _ansi_char(esc.group(1)) if esc else None
                if decoded is not None:
                    subst[i] = decoded
                    for k in range(i + 1, esc.end()):
                        code[k], drop[k] = False, True
                    i = esc.end()
                    continue
        elif top == "sq":
            code[i] = False
            if c == "'":
                stack.pop()
                drop[i] = True
        elif top == "dq":
            code[i] = False
            if c == "\\":
                escape(i, '$`"\\\n')
                i += 1
            elif c == '"':
                stack.pop()
                drop[i] = True
            elif c == "$" and cmd[i + 1 : i + 2] == "(":
                stack.append("sub")
                i += 1
            elif c == "`":
                stack.append("bt")
        elif c == "$" and cmd[i + 1 : i + 2] in ("'", '"'):
            # `$'...'` is ANSI-C quoting and `$"..."` a locale string; the `$` is consumed.
            drop[i] = True
            if cmd[i + 1] == "'":
                stack.append("ansi")
                code[i + 1], drop[i + 1] = False, True
                i += 2
                continue
        elif c == "\\":
            escape(i, None)
            i += 1
        elif c == "#" and (i == 0 or cmd[i - 1] in " \t\n;|&("):
            # A comment runs to the end of the line and executes nothing. A producer named
            # there was matched, "routed" into the comment, and excused the real step.
            while i < len(cmd) and cmd[i] != "\n":
                code[i] = False
                i += 1
            continue
        elif c == "'":
            stack.append("sq")
            code[i] = False
            drop[i] = True
        elif c == '"':
            stack.append("dq")
            code[i] = False
            drop[i] = True
        elif c == "(":
            stack.append("paren")
        elif c == ")" and top in ("sub", "paren"):
            stack.pop()
        elif c == "`" and top == "bt":
            stack.pop()
        elif c == "`":
            stack.append("bt")
        i += 1
    return code, drop, subst


def _heredoc_lines(cmd: str):
    """Yield (line, offset, kind, marker) for each line of `cmd`.

    kind is "cmd" for a line the shell runs, "body" for a heredoc body line, and "end" for the
    line that closes one. marker is the heredoc-start match on a "cmd" line, else None. The one
    place heredocs are recognised; every consumer below decides what to do with a body.
    """
    pos, terminator = 0, None
    for line in cmd.split("\n"):
        if terminator is not None:
            if line.strip() == terminator:
                terminator = None
                yield line, pos, "end", None
            else:
                yield line, pos, "body", None
        else:
            marker = HEREDOC_START.search(line)
            if marker:
                terminator = marker.group(1)
            yield line, pos, "cmd", marker
        pos += len(line) + 1


class HeredocBody(NamedTuple):
    """A heredoc body by character offset, and how the shell treats it."""

    start: int
    end: int
    fed_to_shell: bool  # `bash <<EOF`: the body is a script
    expands: bool  # unquoted delimiter: `$( )` and backticks inside it run


def _heredoc_bodies(cmd: str):
    """Every heredoc body in `cmd`, with whether it runs or expands.

    `expands` is an unquoted delimiter: the shell runs `$( )` and backticks inside the body,
    so `cat <<EOF` around `$(kubectl get secret X -o yaml)` prints the Secret.
    """
    bodies, opened = [], None
    for line, pos, kind, marker in _heredoc_lines(cmd):
        if kind == "cmd" and marker:
            head = line[: marker.start()]
            fed = bool(HEREDOC_RUNNER_RE.search(head) or REMOTE_EXEC_RE.search(head))
            expands = not re.search(r"[\"']", marker.group(0))
            opened = (pos + len(line) + 1, fed, expands)
        elif kind == "end" and opened:
            bodies.append(HeredocBody(opened[0], pos, *opened[1:]))
            opened = None
    if opened:
        bodies.append(HeredocBody(opened[0], len(cmd), *opened[1:]))
    return bodies


def _scan_end(cmd: str, code, start: int, ends_at: str) -> int:
    """Where the span holding `start` ends: an unquoted `;`, newline, backtick, unmatched `)`,
    a lone `&`, or a pipe beginning with `ends_at` (`|` ends a stage, `||` a pipeline).
    """
    depth, j = 0, start
    while j < len(cmd):
        c = cmd[j]
        if code[j]:
            if c in ";\n`":
                break
            if c == "|":
                if cmd.startswith(ends_at, j):
                    break
            elif c == "&":
                if cmd[j - 1 : j] not in ("<", ">", "|") and cmd[j + 1 : j + 2] != ">":
                    break
            elif c == "(":
                depth += 1
            elif c == ")":
                if depth == 0:
                    break
                depth -= 1
        j += 1
    return j


TEMPLATE_FORMATS = ("jsonpath", "go-template", "template", "custom-columns")
# A kubeconfig template is allowed only when every expression reads a safe root. Credentials
# live under `users`, and a wildcard, an index on the root, recursive descent or a template file
# reaches them without naming them, so the check is an allowlist, not a list of bad words.
SAFE_CONFIG_ROOT_RE = re.compile(
    r"^\$?\.(?:current-context|contexts|clusters|preferences|apiVersion|kind)(?![\w-])"
)


def _template_groups_safe(groups) -> bool:
    """Does every expression in one template's groups read a safe root?"""
    in_range = 0
    for raw in groups:
        g = raw.strip()
        if g == "end":
            in_range = max(0, in_range - 1)
        elif g.startswith("range "):
            if not SAFE_CONFIG_ROOT_RE.match(g[6:].strip()):
                return False
            in_range += 1
        elif not re.search(r"[.@$*\[]", g):
            continue  # a literal: `{"\n"}`, `{"\t"}`
        elif not (
            SAFE_CONFIG_ROOT_RE.match(g) or (in_range and re.match(r"^\.[\w-]", g))
        ):
            return False
    return True


def _config_template_safe(stage: str) -> bool:
    """Does every template expression anywhere in a `kubectl config view` step read a safe root?

    kubectl honours the last `-o`, and a step can carry several templates. Checking only the
    first, or stopping at custom-columns, let `-o go-template={{.current-context}} -o
    jsonpath={[*]}` pass on the safe one while kubectl printed every user. So every jsonpath
    group, every go-template group and every custom-columns path must be safe.
    """
    if re.search(r"-file\b|users|\.\.", stage):
        return False
    jsonpath = re.findall(r"(?<!\{)\{(?!\{)([^{}]*)\}", stage)
    go = re.findall(r"\{\{-?(.*?)-?\}\}", stage)
    columns = [
        c.split(":", 1)[-1]
        for spec in re.findall(r"custom-columns=(\S+)", stage)
        for c in spec.split(",")
    ]
    if not (jsonpath or go or columns):
        return False
    return (
        _template_groups_safe(jsonpath)
        and _template_groups_safe(go)
        and all(SAFE_CONFIG_ROOT_RE.match(p) for p in columns)
    )


def _kube_format(stage: str) -> str:
    """The output format kubectl will use: the last `-o`, lowercased, or "" for none."""
    found = KUBE_OUTPUT_RE.findall(stage)
    return found[-1].lower() if found else ""


def _template_output(stage: str) -> bool:
    """Does this kubectl step print through a template -- one bare value per field?"""
    return bool(KUBE_TEMPLATE_RE.search(stage)) or _kube_format(stage).startswith(
        TEMPLATE_FORMATS
    )


# kyaml is a whole document like yaml, but flow-style, and the viewer reads block YAML only: it
# passes kyaml through with every value raw. Ask until the viewer learns it.
KYAML_WHY = (
    "`-o kyaml` prints the whole object in flow-style YAML, which redact-view cannot read, so "
    "its values would reach the transcript raw; `-o yaml` is routed through the viewer instead"
)


def _classify(label: str, stage: str):
    """(action, why) for one producer stage: rewrite, ask, deny, or None to leave it."""
    if label == "kubectl config view":
        # kubectl redacts only password, token and cert data on its own; OIDC auth-provider
        # secrets and exec-plugin env values print raw even without --raw. So the view is always
        # routed, and a template that can reach `users` (or the whole document) is denied: it
        # prints a bare value. `{.current-context}` and the like are everyday and left alone.
        # A document format beats --template: kubectl ignores the template under `-o yaml` or
        # `-o json`, in either order, and prints the whole kubeconfig.
        fmt = _kube_format(stage)
        if fmt == "kyaml":
            return "ask", KYAML_WHY
        if fmt in DOC_FORMATS:
            return "rewrite", None
        if _template_output(stage):
            if not _config_template_safe(stage):
                return "deny", (
                    "a template output that reaches the kubeconfig's users prints one raw "
                    "token or key, which no viewer can redact by structure"
                )
            return None, None
        return "rewrite", None
    if label == "kubectl get":
        fmt = _kube_format(stage)
        if fmt == "kyaml":
            return "ask", KYAML_WHY
        if fmt in DOC_FORMATS or re.search(r"\s--raw(?:=|\s|$)", stage):
            return "rewrite", None
        if KUBE_SECRET_RE.search(stage) and _template_output(stage):
            return "deny", (
                "a template output format on a Secret prints one raw value, which no viewer "
                "can redact by structure"
            )
        return None, None
    if label == "argocd app get" and "--show-params" in stage:
        return "ask", (
            "`--show-params` prints Helm parameters as a table the viewer cannot read "
            "structurally; `-o json | jq '.spec.source.helm.parameters'` is routed instead"
        )
    return "rewrite", None


class ShellView:
    """Two readings of one command: one that keeps offsets, one that reads as the shell does.

    view: same length as the command, line continuations blanked; used to find where a stage
          ends and where to insert, so offsets carry straight back to the command.
    code: where the shell executes rather than quotes (see _exec_mask). Heredoc bodies are
          excluded; `bodies` says how each one is run.
    word: quoted spans holding no whitespace. `'kubectl'` is still the binary; a quoted span
          with a space in it is a message, a fixture or a script, never a bare word.
    deq, idx: the command with quote delimiters, escapes and continuations REMOVED, and the
          original offset of each remaining character. Matching and classification read this,
          because the shell joins `kube"ctl"` and `-o ya'ml'` into single words; blanking the
          quotes instead read different words and let both run unrouted.
    """

    def __init__(self, cmd: str):
        self.cmd = cmd
        self.view = cmd.replace("\\\n", "  ")
        self.code, drop, subst = _exec_mask(cmd)
        self.word = [False] * len(cmd)
        i = 0
        while i < len(cmd):
            if self.code[i]:
                i += 1
                continue
            j = i
            while j < len(cmd) and not self.code[j]:
                j += 1
            if cmd[i] in "'\"" and not any(ch.isspace() for ch in cmd[i:j]):
                self.word[i:j] = [True] * (j - i)
            i = j
        self.idx = [k for k in range(len(cmd)) if not drop[k]]
        self.deq = "".join(subst.get(k, cmd[k]) for k in self.idx)
        self.bodies = _heredoc_bodies(cmd)
        for body in self.bodies:
            for k in range(body.start, min(body.end, len(cmd))):
                self.code[k] = self.word[k] = False

    def executes(self, pos: int) -> bool:
        """Is the character at `pos` part of a command the shell runs, not quoted data?"""
        return self.code[pos] or self.word[pos]

    def body_at(self, pos: int):
        return next((b for b in self.bodies if b.start <= pos < b.end), None)

    def runner_before(self, pos: int) -> bool:
        """Is a script runner (`sh -c`, `eval`, a remote launcher) executed earlier in the step
        holding `pos`? A runner in an earlier step (`bash x.sh; git commit -m "…"`) runs
        nothing here, and counting it made an honest commit message ask."""
        first = self.stage_start(pos)
        return any(
            self.code[m.start()] and first <= m.start() < pos
            for rx in (SCRIPT_RUNNER_RE, REMOTE_EXEC_RE)
            for m in rx.finditer(self.view)
        )

    def stage_end(self, start: int) -> int:
        return _scan_end(self.view, self.code, start, ends_at="|")

    def pipeline_end(self, start: int) -> int:
        return _scan_end(self.view, self.code, start, ends_at="||")

    def stage_start(self, end: int) -> int:
        """Where the stage ending at `end` begins: just after the previous unquoted separator."""
        j = end - 1
        while j >= 0 and not (self.code[j] and self.view[j] in "|;&\n(`"):
            j -= 1
        return j + 1

    def executed(self, a: int, b: int) -> str:
        """Offsets [a, b) with quoted characters blanked; for finding redirections."""
        return "".join(
            ch if self.code[a + k] else " " for k, ch in enumerate(self.view[a:b])
        )

    def words(self, a: int, b: int, executed_only: bool = False) -> str:
        """The words the shell passes for original offsets [a, b)."""
        lo, hi = bisect.bisect_left(self.idx, a), bisect.bisect_left(self.idx, b)
        if not executed_only:
            return self.deq[lo:hi]
        return "".join(
            self.deq[d] if self.executes(self.idx[d]) else " " for d in range(lo, hi)
        )


class Routing(NamedTuple):
    """What route_producers() decided for one command."""

    command: str  # the command to run, with the viewer inserted after each producer
    labels: tuple  # the producers routed, in the order they were matched
    verdict: tuple  # (decision, reason) when no rewrite can work, else None
    routed_stages: frozenset  # the exact original text of every routed step


def _verdict(cmd: str, decision: str, reason: str) -> Routing:
    return Routing(cmd, (), (decision, reason), frozenset())


def route_producers(cmd: str) -> Routing:
    """Route cluster-API reads through the viewer.

    A non-None verdict is final: a deny for an extraction shape, an ask where no rewrite can
    both work and withhold the value (a quoted script, an expanding heredoc, output sent
    anywhere but stdout).
    """
    shell = ShellView(cmd)
    unroutable = (
        "runs inside a quoted script or a heredoc the shell expands, where its output cannot "
        "be routed through redact-view, so any credential it prints reaches the transcript "
        f'raw. Run it on the host and pipe it through `"{REDACT_VIEW}" --yaml -`.'
    )
    inserts = []  # (offset to insert at, producer label)
    for label, pattern in PRODUCERS:
        for match in pattern.finditer(shell.deq):
            start = shell.idx[match.start()]
            if not shell.executes(start):
                body = shell.body_at(start)
                if body:
                    nested = body.fed_to_shell or (
                        body.expands and re.search(r"\$\(|`", cmd[body.start : start])
                    )
                else:
                    nested = shell.runner_before(start)
                if nested:
                    return _verdict(cmd, "ask", f"`{label}` {unroutable}")
                continue  # quoted data: a message, a fixture, a note being written
            end = shell.stage_end(start)
            action, why = _classify(label, " " + shell.words(start, end))
            if action is None:
                continue
            if action != "rewrite":
                return _verdict(
                    cmd,
                    action,
                    f"`{label}`: {why}. For the structure, pipe a document format through "
                    f'`"{REDACT_VIEW}" --yaml -` -- key names survive, values do not.',
                )
            downstream = shell.words(end, shell.pipeline_end(end), executed_only=True)
            extract = PIPE_EXTRACT_RE.search(downstream)
            if extract:
                return _verdict(
                    cmd,
                    "deny",
                    f"Blocked: `{extract.group(0)}` downstream of `{label}` exists to obtain or "
                    f"move a raw credential value. If a process needs the secret, let it read "
                    f"the cluster itself -- you do not need to see the value.",
                )
            # The whole step, not just from the producer on: `> out kubectl get …` redirects too.
            targets = STDOUT_REDIR_RE.findall(
                shell.executed(shell.stage_start(start), end)
            )
            if EXEC_REDIR_RE.search(shell.executed(0, start)):
                targets.append("exec")
            if targets and all(t in SILENT_TARGETS for t in targets):
                continue  # discarded; nothing reaches the transcript
            if targets:
                return _verdict(
                    cmd,
                    "ask",
                    f"`{label}` output is redirected ({', '.join(targets)}), where the viewer "
                    f"cannot reach it: a file a later read prints raw, or stderr. Approve to "
                    f"write it raw, or drop the redirection so it is routed through redact-view.",
                )
            # Trim on the raw text: the view blanks quote characters, and trimming there walks
            # back inside a closing quote -- `-o 'json | redact-view'` -- and routes nothing.
            at = end
            while at > start and cmd[at - 1] in " \t":
                at -= 1
            if any(a == at for a, _ in inserts):
                continue  # two patterns matched one stage
            inserts.append((at, label))
    routed = frozenset(cmd[shell.stage_start(at) : at].strip() for at, _ in inserts)
    for at, label in sorted(inserts, reverse=True):
        hint = "--diff" if label == "argocd app diff" else "--yaml"
        cmd = f'{cmd[:at]} | "{REDACT_VIEW}" {hint} -{cmd[at:]}'
    return Routing(cmd, tuple(label for _, label in inserts), None, routed)


# The routed command, once route_producers() has rewritten one. Every later decision carries
# it: an `ask` without it shows -- and on approval runs -- the command as originally typed,
# with the producer unrouted.
ROUTED = None


def emit(decision: str, reason: str, updated=None):
    if updated is None and decision != "deny":
        updated = ROUTED
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


def emit_embedded(embedded):
    emit(
        "ask",
        f"`{', '.join(sorted(set(embedded)))}` is read inside an embedded shell or a quoted "
        f"script (docker/ssh, `sh -c`, `su -c`, a heredoc fed to a shell). redact-view cannot "
        f"be inserted there, so the value would reach the transcript unredacted. Prefer "
        f"running the read on the host, or redacting inside the guest.",
    )


# Reader options that take a value, per verb. A variable right after one is that value, not a
# path: `head -n $N` reads stdin, and routing `$N` broke the command. The same letters are plain
# flags elsewhere -- `cat -n FILE` numbers lines -- so a verb with no entry takes no values.
VALUE_FLAGS = {
    "head": frozenset(("-n", "-c", "--lines", "--bytes")),
    "tail": frozenset(("-n", "-c", "--lines", "--bytes")),
    "bat": frozenset(("-r", "--line-range", "-l", "--language")),
    "nl": frozenset(("-w", "-s", "-b", "-v", "-i")),
    "tac": frozenset(("-s", "--separator")),
}


def _is_flag_value(verb: str, flags: str, token: str) -> bool:
    """Is `token` the value of the last flag, rather than a path to read?"""
    words = flags.split()
    return (
        bool(words)
        and words[-1] in VALUE_FLAGS.get(verb, ())
        and ("$" in token or "`" in token)
        and not SECRET_RE.search(token)
    )


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
    runners = []

    def runner_runs(line, verb_at):
        """Does a runner earlier in the same step run the quoted script holding `verb_at`?"""
        first = 0
        for k in range(verb_at - 1, -1, -1):
            if line[k] in "|;&(" and not line_mask[k]:
                first = k + 1
                break
        return any(first <= r < verb_at for r in runners)

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
        nested = (
            carried
            or (remote_at is not None and m.start(1) > remote_at)
            or (masked and runner_runs(m.string, m.start(1)))
        )
        if masked or nested:
            if nested and SECRET_RE.search(path):
                embedded.append(path)
            return m.group(0)
        if _is_flag_value(verb, flags, path) or not leaks(path, cwd):
            return m.group(0)
        touched.append(path)
        # head/tail keep their line limits by piping after redaction.
        if verb in ("head", "tail") and flags.strip():
            return f'"{REDACT_VIEW}" {path} | {verb}{flags}'
        return f'"{REDACT_VIEW}" {path}'

    # Apply only outside heredoc bodies: text inside one is a document being
    # written, not a command being run. Rewriting there would corrupt the file.
    out, pending, fed = [], None, False
    for line, _, kind, marker in _heredoc_lines(cmd):
        if kind != "cmd":
            # A body fed to a runner is a script, so a credential read in it runs. Report it;
            # rewriting inside a document someone else executes is not this guard's to do.
            if kind == "body" and fed:
                embedded.extend(
                    rm.group(3)
                    for rm in READ_CALL.finditer(line)
                    if SECRET_RE.search(rm.group(3))
                )
            out.append(line)
            continue
        if marker:
            head = line[: marker.start()]
            fed = bool(HEREDOC_RUNNER_RE.search(head) or REMOTE_EXEC_RE.search(head))
        carried = pending is not None
        line_mask, pending = quoted_mask(line, pending)
        remote_at = None
        for rm in REMOTE_EXEC_RE.finditer(line):
            if rm.start() >= len(line_mask) or not line_mask[rm.start()]:
                remote_at = rm.start()
                break
        runners = [
            rm.start()
            for rm in SCRIPT_RUNNER_RE.finditer(line)
            if rm.start() < len(line_mask) and not line_mask[rm.start()]
        ]
        out.append(READ_CALL.sub(repl, line))
    return "\n".join(out), touched, embedded


# A verb at the head of a stage, used by the backstop below.
STAGE_VERB = re.compile(rf"(?<![-/\w.])({REDACTABLE_VERBS})\b")


def missed_reads(cmd: str, cwd: str, limit: int = 40):
    """Credential reads the rewriter did not catch.

    The rewriter is one regex over a whole shell line, and the defect this exists for was
    that regex quietly consuming the very read it should have rewritten. Such a miss is
    invisible: nothing is denied, the command is simply allowed, and the value is printed.
    Prevention is the only lever this guard has, so ask the question a second time in a
    different shape -- per stage, token by token -- and prefer a prompt over a silent pass.

    Deliberately narrow. Stages already routed through the viewer, and stages that cross a
    namespace boundary (handled by the embedded-shell path), are skipped.
    """
    found, probes = [], 0
    # Heredoc bodies are documents being written, not reads being run -- the rewriter skips
    # them, and asking here would prompt on every note that mentions `cat .env`.
    for stage in stages(strip_heredocs(cmd)):
        if REDACTED_CALL.search(stage) or REMOTE_EXEC_RE.search(stage):
            continue
        mask, _ = quoted_mask(stage)
        vm = STAGE_VERB.search(stage)
        if not vm or (vm.start() < len(mask) and mask[vm.start()]):
            continue  # no plain reader here, or it is quoted data rather than a command
        prev = ""
        for tok in stage[vm.end() :].split():
            variable = "$" in tok or "`" in tok
            # Only a VARIABLE after one of this verb's value-taking flags is that flag's value:
            # `-n` is a plain flag for cat, and skipping what followed it hid `cat -n .env`.
            value, prev = _is_flag_value(vm.group(1), prev, tok), tok
            if tok.startswith("-") or (tok.startswith("+") and variable) or value:
                continue
            if probes >= limit:
                continue
            probes += 1
            if leaks(tok, cwd):
                found.append(tok)
    return found


def backstop(cmd: str, cwd: str):
    """Last line of defence: never exit quiet on a read that still looks credential-bearing."""
    missed = missed_reads(cmd, cwd)
    if missed:
        emit(
            "ask",
            f"`{', '.join(sorted(set(missed)))}` looks credential-bearing and this guard "
            f"could not rewrite the read automatically, so the raw value would reach the "
            f'transcript. Cancel and run `"{REDACT_VIEW}" <file>` for a redacted view, '
            f"or approve if you know this file holds no secret.",
        )


def read_file_guard(file_path: str, cwd: str):
    """Ask before the Read tool opens a file whose content holds a credential."""
    if not file_path or contains_secrets is None:
        return  # engine absent: the filename deny rules are the floor
    path = _resolve(file_path, cwd)
    try:
        # Oversized files are left to the Read tool's own limits. contains_secrets treats
        # them as positive, which would prompt on every large lockfile and teach dismissal.
        if not os.path.isfile(path) or os.path.getsize(path) > MAX_BYTES:
            return
        hit = contains_secrets(path)
    except Exception:
        return  # read path fails open
    if hit:
        emit(
            "ask",
            f"`{file_path}` holds credential-shaped values, and the Read tool cannot redact "
            f"what it returns. Approve to see it raw, or cancel and run "
            f"`cat {file_path}` (routed through redact-view) for a redacted view.",
        )


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

    # ---- Read: the tool returns the file raw, and no hook can filter its output --------
    # Deny rules cover credential-NAMED files. A Helm values file or an appsettings.json is
    # named like ordinary config, so only its content says whether it holds a credential.
    # Ask rather than deny: the Edit tool requires a prior Read, and refusing outright would
    # make every secret-bearing values.yaml uneditable -- a guard that gets switched off.
    if tool == "Read":
        read_file_guard(ti.get("file_path") or "", payload.get("cwd") or os.getcwd())
        sys.exit(0)

    if tool != "Bash":
        sys.exit(0)

    original = ti.get("command", "")
    if not original:
        sys.exit(0)

    cwd = payload.get("cwd") or os.getcwd()

    # A cluster-API read names no file, so it is routed before anything path-driven runs.
    # Every decision below then judges the command that will actually run, and each exit
    # that would otherwise leave it untouched carries the routing instead.
    global ROUTED
    routing = route_producers(original)
    if routing.verdict:
        emit(*routing.verdict)
    original = routing.command
    if routing.labels:
        ROUTED = dict(ti, command=original)

    def finish():
        if routing.labels:
            emit(
                "allow",
                f"Routed {', '.join(routing.labels)} output through redact-view: cluster "
                f"credentials are redacted to a length + sha256 fingerprint, structure "
                f"preserved for any filter downstream.",
                updated=ROUTED,
            )
        sys.exit(0)

    probe = scrub(original)

    # Content probe: a plain read of an innocuously-named file that nonetheless
    # holds credentials must still be redirected through the viewer.
    if not SECRET_RE.search(probe):
        rewritten, touched, embedded = rewrite_reads(original, cwd)
        if embedded:
            emit_embedded(embedded)
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
        # Whole-command, as before routing existed: `ls values.yaml | xargs grep` reads the
        # file in a stage that never names it. Only a values path inside a routed producer's
        # own stage is discounted -- `helm template -f values.yaml | yq` filters the
        # producer's redacted output, never the file.
        hit = next(
            (
                ASK_RE.search(st)
                for st in stages(probe)
                # Exactly a step the guard routed -- not any step that mentions a producer,
                # which a quoted word or a comment can do.
                if ASK_RE.search(st) and st.strip() not in routing.routed_stages
            ),
            None,
        )
        if hit and (FILTER_RE.search(probe) or READ_CALL.search(probe)):
            emit(
                "ask",
                f"This reads a helm/Harness values file ({hit.group(0).strip()!r}), which "
                f"often carries secrets. Approve to see it raw, or cancel and use "
                f'`"{REDACT_VIEW}" <file>` for a redacted view.',
            )
        backstop(original, cwd)
        finish()

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
        emit_embedded(embedded)

    if touched:
        # Judge the leftover per stage, exactly as the deny below does. A whole-command
        # test ("a secret path and a filter are both still in there") discarded the rewrite
        # for `ls .env; ps aux | grep node; cat .env`, and the per-stage deny then found no
        # stage holding both -- so no decision was emitted and the ORIGINAL command ran.
        leftover = scrub(rewritten)
        if not any(
            FILTER_RE.search(s) and SECRET_RE.search(s) for s in stages(leftover)
        ):
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
    # Check the command that will actually run: no rewrite was emitted, so that is the
    # original. Checking `rewritten` skipped the very reads the discarded rewrite had routed.
    backstop(original, cwd)
    finish()


if __name__ == "__main__":
    main()
