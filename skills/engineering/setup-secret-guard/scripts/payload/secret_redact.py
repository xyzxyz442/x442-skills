"""secret_redact — shared credential-redaction heuristics.

Used by callers that must agree exactly -- the viewer that redacts a file, the scanner
that answers yes/no, and the hook that decides allow/ask/deny. They are installed from
one payload precisely so they cannot drift apart.

Keeping the heuristics in one module stops the guard and the viewer from
drifting apart -- a drift where the guard says "safe" and the viewer would
would have redacted something is exactly how a secret reaches the transcript.
"""

from __future__ import annotations

import hashlib
import json
import os
import re

MAX_BYTES = 2 * 1024 * 1024  # refuse to slurp huge blobs

# ---------------------------------------------------------------- fingerprints


def fingerprint(value: str) -> str:
    """Non-reversible stable tag for a secret value."""
    if value is None:
        return "<redacted null>"
    s = str(value)
    if s == "":
        return "<redacted empty>"
    digest = hashlib.sha256(s.encode("utf-8", "replace")).hexdigest()[:8]
    return f"<redacted len={len(s)} sha256:{digest}>"


# ------------------------------------------------------------------ heuristics

# Key names that mean "this value is a credential", matched case-insensitively
# against the key alone.
SECRET_KEY_RE = re.compile(
    r"(pass(word|wd|phrase)?|secret|token|api[-_]?key|apikey|access[-_]?key"
    r"|private[-_]?key|privatekey|client[-_]?secret|auth|authorization|bearer"
    r"|credential|cred|session[-_]?key|encryption[-_]?key|signing[-_]?key"
    r"|salt|nonce|otp|pin|licen[cs]e[-_]?key|connection[-_]?string|dsn"
    r"|sas[-_]?token|account[-_]?key|webhook|dockerconfigjson|\.dockerconfigjson"
    r"|certificate|cert[-_]?data|ca[-_]?data|client[-_]?key[-_]?data"
    r"|client[-_]?certificate[-_]?data|id[-_]?token|refresh[-_]?token)",
    re.IGNORECASE,
)

# Keys that are almost always safe config, even though they brush the rules above.
SAFE_KEY_RE = re.compile(
    r"^(auth[-_]?(url|endpoint|type|method|provider|domain)"
    r"|token[-_]?(url|endpoint|type|expiry|ttl)"
    r"|secret[-_]?(name|ref|key[-_]?ref|manager)"
    r"|cert[-_]?(manager|issuer|path|file)"
    r"|.*[-_]?(enabled|required|count|replicas|port|timeout|version|name|path|file))$",
    re.IGNORECASE,
)

PEM_RE = re.compile(r"-----BEGIN [^-]+-----")
JWT_RE = re.compile(r"^ey[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+$")
AWS_AKID_RE = re.compile(r"^(AKIA|ASIA)[0-9A-Z]{16}$")
GH_TOKEN_RE = re.compile(r"^gh[pousr]_[A-Za-z0-9]{20,}$")
SLACK_RE = re.compile(r"^xox[abprs]-[A-Za-z0-9-]{10,}$")
PRIVKEY_RE = re.compile(r"^[A-Za-z0-9+/]{40,}={0,2}$")  # long bare base64
URL_CREDS_RE = re.compile(r"^([a-zA-Z][a-zA-Z0-9+.-]*://)([^/\s:@]+):([^/\s@]+)@(.*)$")

# Values that look like ordinary config and should survive untouched.
BENIGN_VALUE_RE = re.compile(
    r"^(true|false|null|none|yes|no|on|off|latest|stable|always|never"
    r"|ifnotpresent|[0-9]+(\.[0-9]+)*(m|mi|gi|g|k|ki|s|ms|h)?|v?[0-9]+\.[0-9.]*)$",
    re.IGNORECASE,
)


# A credential embedded INSIDE a larger value, where no key in the document looks secret --
# an ADO.NET or JDBC connection string, a DSN, a broker URI with options. Adoption found this
# gap: `{"ConnectionStrings": {"Default": "Server=db;User Id=svc;Password=..."}}` was reported
# clean, because the only key the walker sees is `Default`. Requiring no space around the `=`
# keeps it off prose, which is scanned by a different tool with its own rules.
EMBEDDED_CRED_RE = re.compile(
    r"(?:^|[;,&\s])(pass(?:word|wd)?|pwd|secret|token|api[-_]?key|accountkey"
    r"|sharedaccesskey)=[^;,&\s]{4,}",
    re.IGNORECASE,
)


def looks_secret_value(v) -> bool:
    """True when the value itself betrays that it is a credential."""
    if not isinstance(v, str):
        return False
    s = v.strip()
    if len(s) < 8 or BENIGN_VALUE_RE.match(s):
        return False
    if PEM_RE.search(s) or JWT_RE.match(s) or AWS_AKID_RE.match(s):
        return True
    if GH_TOKEN_RE.match(s) or SLACK_RE.match(s):
        return True
    if URL_CREDS_RE.match(s):
        return True
    if EMBEDDED_CRED_RE.search(s):
        return True
    # Long, high-entropy, no spaces, not a path or URL.
    if (
        len(s) >= 24
        and " " not in s
        and not s.startswith(("/", "./", "http://", "https://"))
    ):
        classes = sum(bool(re.search(p, s)) for p in (r"[a-z]", r"[A-Z]", r"[0-9]"))
        if classes >= 2 and PRIVKEY_RE.match(s.replace("-", "").replace("_", "")):
            return True
    return False


def secret_key(key) -> bool:
    """True when a key NAME alone marks its value as a credential."""
    k = str(key)
    return bool(SECRET_KEY_RE.search(k)) and not SAFE_KEY_RE.match(k)


def should_mask(key, value, mask_all: bool) -> bool:
    if mask_all:
        return not isinstance(value, (bool, int, float, type(None)))
    if key is not None and secret_key(key):
        return True
    return looks_secret_value(value)


# Incremented by mask_value()/render_blob(); reset at the start of each render().
MASK_COUNT = 0


def mask_value(v):
    """Mask a scalar, but keep URL credentials partially readable (host survives)."""
    global MASK_COUNT
    MASK_COUNT += 1
    if isinstance(v, str):
        m = URL_CREDS_RE.match(v.strip())
        if m:
            scheme, user, pw, rest = m.groups()
            return f"{scheme}{user}:{fingerprint(pw)}@{rest}"
    return fingerprint(v)


# -------------------------------------------------------------- format: whole-file

# Files where every value is secret by definition — no key-name heuristics needed.
ALWAYS_MASK_ALL = re.compile(
    r"(^|/)(\.env(\..*)?|\.npmrc|\.pypirc|\.netrc|kubeconfig[^/]*|\.kubeconfig"
    r"|credentials)$|\.(pem|key|p12|pfx|kubeconfig)$|id_(rsa|ed25519|ecdsa|dsa)",
    re.IGNORECASE,
)

OPAQUE_BLOB = re.compile(r"\.(p12|pfx)$|id_(rsa|ed25519|ecdsa|dsa)$", re.IGNORECASE)


def render_blob(path: str, raw: bytes) -> str:
    """Binary or raw key material: no structure worth showing."""
    global MASK_COUNT
    MASK_COUNT += 1
    digest = hashlib.sha256(raw).hexdigest()[:16]
    kind = (
        "PEM/text key material"
        if PEM_RE.search(raw[:200].decode("utf-8", "replace"))
        else "opaque key material"
    )
    return (
        f"# {path}\n"
        f"# {kind}, fully withheld\n"
        f"# {len(raw)} bytes, sha256:{digest}\n"
    )


# ------------------------------------------------------------------ format: JSON

# A Kubernetes Secret carries its values under these keys, and every one of them is a
# credential by definition -- the key names are arbitrary (`DB_URL`, `tls.crt`) and the values
# are base64, which no value heuristic recognises. Matched on the manifest's `kind`, not a name.
K8S_SECRET_DATA_KEYS = ("data", "stringdata")

# The name/value list Kubernetes and nearly every Helm chart use for environment variables:
# `- name: DB_PASSWORD` / `value: ...`. The credential-shaped word sits in the SIBLING's value,
# so a walker that only looks at a value's own key sees `value` and lets the secret through.
ENV_NAME_KEYS = ("name", "key")


def _env_pair_is_secret(names) -> bool:
    return any(isinstance(n, str) and secret_key(n) for n in names)


def redact_json(obj, mask_all: bool, key=None):
    if isinstance(obj, dict):
        k8s_secret = obj.get("kind") == "Secret"
        env_secret = "value" in obj and _env_pair_is_secret(
            obj.get(k) for k in obj if str(k).lower() in ENV_NAME_KEYS
        )
        return {
            k: redact_json(
                v,
                mask_all
                or (k8s_secret and str(k).lower() in K8S_SECRET_DATA_KEYS)
                or (env_secret and k == "value"),
                key=k,
            )
            for k, v in obj.items()
        }
    if isinstance(obj, list):
        return [redact_json(v, mask_all, key=key) for v in obj]
    if should_mask(key, obj, mask_all):
        return mask_value(obj)
    return obj


# ------------------------------------------------- format: dotenv / ini (line based)

DOTENV_LINE = re.compile(r"^(\s*(?:export\s+)?)([A-Za-z_][A-Za-z0-9_.]*)(\s*=\s*)(.*)$")
INI_LINE = re.compile(r"^(\s*)([A-Za-z0-9_.\-/:@]+)(\s*=\s*)(.*)$")

COMMENT_SPLIT = re.compile(r'^((?:[^#"\']|"[^"]*"|\'[^\']*\')*?)(\s+#.*)$')


def _split_comment(val: str):
    """(value, trailing-comment) -- a `#` inside quotes is part of the value."""
    cm = COMMENT_SPLIT.match(val)
    if cm:
        return cm.group(1).strip(), cm.group(2)
    return val.strip(), ""


def _unquote(s: str):
    """(quote-char, inner) for a quoted scalar, ("", s) otherwise."""
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        return s[0], s[1:-1]
    return "", s


def _mask_pem_line(line: str) -> str:
    global MASK_COUNT
    MASK_COUNT += 1
    return re.sub(r"(-----BEGIN [^-]+-----).*", r"\1 <redacted body>", line)


def redact_lines(text: str, pattern: re.Pattern, mask_all: bool) -> str:
    out = []
    in_block = False
    for line in text.splitlines():
        stripped = line.strip()

        # Multi-line PEM blocks inside env/ini: withhold the body entirely.
        if PEM_RE.search(line):
            in_block = True
            out.append(_mask_pem_line(line))
            continue
        if in_block:
            if "-----END" in line:
                in_block = False
            continue

        if not stripped or stripped.startswith("#"):
            out.append(line)
            continue

        m = pattern.match(line)
        if not m:
            out.append(line)
            continue

        pre, key, sep, val = m.groups()
        bare = val.strip()
        if bare in ("", "|", ">", "|-", ">-", "{}", "[]", "null", "~"):
            out.append(line)
            continue
        bare, comment = _split_comment(val)
        quote, bare = _unquote(bare)

        if should_mask(key, bare, mask_all):
            out.append(f"{pre}{key}{sep}{quote}{mask_value(bare)}{quote}{comment}")
        else:
            out.append(line)
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


# ------------------------------------------------------------------ format: YAML
#
# YAML is walked structurally, not line by line. A line-local reading was how Helm values
# leaked through a viewer that the scanner had already flagged: the value of `dbPassword: |`
# lives on the NEXT lines, the credential-shaped word of an env var lives in a SIBLING key,
# and a Kubernetes Secret's sensitivity is declared by a `kind:` line anywhere in the
# document. None of those are visible from the line holding the value. Stdlib only -- the
# engine runs on machines with no PyYAML -- so this tracks indentation, not a full parse.

YAML_LINE = re.compile(
    r"""^(\s*(?:-\s+)?)("[^"\n]*"|'[^'\n]*'|[A-Za-z0-9_.\-/]+)(\s*:(?=\s|$)\s*)(.*)$"""
)
YAML_ITEM_SCALAR = re.compile(r"^(\s*-\s+)(\S.*)$")
BLOCK_SCALAR_RE = re.compile(r"^[|>][0-9+-]{0,2}$")
DOC_SEP_RE = re.compile(r"^(---|\.\.\.)(\s|$)")
K8S_SECRET_KIND_RE = re.compile(r"""^kind:\s*["']?Secret["']?\s*(#.*)?$""")
EMPTY_YAML_VALUES = ("", "{}", "[]", "null", "~")

# A parent whose children are credentials whatever they are called: a chart's `secrets:`,
# `extraSecrets:`, `credentials:` map of `STRIPE_KEY: ...`. Anchored at the END so
# `secretName` and `secretsEnabled` are not parents. Pull secrets are registry references,
# not values, and `imagePullSecrets` is in nearly every chart -- excluded by name.
SECRET_PARENT_RE = re.compile(r"(secrets?|credentials?)$", re.IGNORECASE)
NOT_SECRET_PARENT_RE = re.compile(r"pull[-_]?secrets?$", re.IGNORECASE)
YAML_NAME_RE = re.compile(r"\.ya?ml(\.[A-Za-z0-9_-]+)?$", re.IGNORECASE)

# Scope strength, inherited from the nearest parent that sets one.
LOOSE, STRICT = 1, 2


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _yaml_structure(lines):
    """One structural pass: every key line, and the body range of every block scalar.

    Returns (records, bodies). A record carries the key's column and the id of the mapping
    it belongs to, so siblings of one list item (`- name:` / `value:`) can be related.
    """
    records, bodies = {}, {}
    group_at, next_gid = {}, 0
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        if DOC_SEP_RE.match(line):
            group_at = {}
            i += 1
            continue
        stripped = line.strip()
        m = YAML_LINE.match(line) if stripped and not stripped.startswith("#") else None
        if not m:
            i += 1
            continue
        pre, qkey, _, val = m.groups()
        col = len(pre)
        item = pre.strip().startswith("-")
        for c in [c for c in group_at if c > col or (item and c == col)]:
            del group_at[c]
        if col not in group_at:
            group_at[col] = next_gid
            next_gid += 1
        bare, _ = _split_comment(val)
        records[i] = {
            "col": col,
            "key": _unquote(qkey)[1],
            "bare": bare,
            "gid": group_at[col],
        }
        if BLOCK_SCALAR_RE.match(bare):
            # The body is every following line indented deeper than the key, up to the first
            # line that is not. Blank lines inside belong to it; trailing ones do not.
            j, body_indent = i + 1, None
            while j < n:
                if lines[j].strip():
                    ind = _indent(lines[j])
                    if body_indent is None:
                        if ind <= col:
                            break
                        body_indent = ind
                    elif ind < body_indent:
                        break
                j += 1
            end = j
            while end > i + 1 and not lines[end - 1].strip():
                end -= 1
            if body_indent is not None:
                bodies[i] = (i + 1, end, body_indent)
                i = end
                continue
        i += 1
    return records, bodies


def _k8s_secret_lines(lines):
    """Per line: does it sit in a document whose `kind` is Secret?"""
    flags = [False] * len(lines)

    def close(start, end):
        if any(K8S_SECRET_KIND_RE.match(lines[k]) for k in range(start, end)):
            for k in range(start, end):
                flags[k] = True

    start = 0
    for idx, line in enumerate(lines):
        if DOC_SEP_RE.match(line):
            close(start, idx)
            start = idx + 1
    close(start, len(lines))
    return flags


def _env_value_lines(records):
    """Line indices of `value:` keys whose sibling `name:` is credential-shaped."""
    secret_groups = {
        r["gid"]
        for r in records.values()
        if r["key"].lower() in ENV_NAME_KEYS
        and _env_pair_is_secret([_unquote(r["bare"])[1]])
    }
    return {
        idx
        for idx, r in records.items()
        if r["key"].lower() == "value" and r["gid"] in secret_groups
    }


def _loose_masks(key, value) -> bool:
    """Inside a `secrets:`-style parent: everything but plain switches and safe keys."""
    return not SAFE_KEY_RE.match(str(key)) and not BENIGN_VALUE_RE.match(value)


def _redact_nested_line(line: str, mask_all: bool) -> str:
    """A block-scalar body line that is not YAML: an embedded dotenv file, or a bare token."""
    m = DOTENV_LINE.match(line)
    if m:
        pre, key, sep, val = m.groups()
        bare, comment = _split_comment(val)
        quote, bare = _unquote(bare)
        if bare and should_mask(key, bare, mask_all):
            return f"{pre}{key}{sep}{quote}{mask_value(bare)}{quote}{comment}"
        return line
    if looks_secret_value(line.strip()):
        return " " * _indent(line) + mask_value(line.strip())
    return line


def redact_yaml(text: str, mask_all: bool, nested: bool = False) -> str:
    global MASK_COUNT
    lines = text.splitlines()
    records, bodies = _yaml_structure(lines)
    in_secret_doc = _k8s_secret_lines(lines)
    env_values = _env_value_lines(records)

    out = []
    stack = []  # (column, scope) of open parent mappings
    in_pem = False
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        if DOC_SEP_RE.match(line):
            stack = []
            out.append(line)
            i += 1
            continue
        if PEM_RE.search(line):
            in_pem = True
            out.append(_mask_pem_line(line))
            i += 1
            continue
        if in_pem:
            if "-----END" in line:
                in_pem = False
            i += 1
            continue
        if not stripped or stripped.startswith("#"):
            out.append(line)
            i += 1
            continue

        rec = records.get(i)
        if rec is None:
            item = YAML_ITEM_SCALAR.match(line)
            if item:
                col = len(item.group(1))
                while stack and stack[-1][0] >= col:
                    stack.pop()
                scope = stack[-1][1] if stack else 0
                bare, comment = _split_comment(item.group(2))
                quote, bare = _unquote(bare)
                if bare not in EMPTY_YAML_VALUES and (
                    mask_all
                    or scope == STRICT
                    or (scope == LOOSE and not BENIGN_VALUE_RE.match(bare))
                    or looks_secret_value(bare)
                ):
                    line = f"{item.group(1)}{quote}{mask_value(bare)}{quote}{comment}"
            elif nested:
                line = _redact_nested_line(line, mask_all)
            out.append(line)
            i += 1
            continue

        col, key = rec["col"], rec["key"]
        while stack and stack[-1][0] >= col:
            stack.pop()
        scope = stack[-1][1] if stack else 0

        if i in bodies:
            start, end, body_indent = bodies[i]
            body_lines = lines[start:end]
            out.append(line)
            if (
                mask_all
                or scope == STRICT
                or i in env_values
                or secret_key(key)
                or (scope == LOOSE and not SAFE_KEY_RE.match(key))
            ):
                body = "\n".join(bl[body_indent:] for bl in body_lines)
                out.append(" " * body_indent + mask_value(body))
            else:
                # An ordinary key can still hold a whole config file: a ConfigMap's
                # `application.yaml: |`. Redact inside it, and keep it byte-identical if
                # nothing in it needed redacting.
                before = MASK_COUNT
                dedented = "\n".join(
                    bl[body_indent:] if bl.strip() else "" for bl in body_lines
                )
                inner = redact_yaml(dedented, mask_all, nested=True)
                if MASK_COUNT == before:
                    out.extend(body_lines)
                else:
                    out.extend(
                        (" " * body_indent + il) if il else ""
                        for il in inner.split("\n")
                    )
            i = end
            continue

        m = YAML_LINE.match(line)
        pre, qkey, sep, val = m.groups()
        bare, comment = _split_comment(val)
        quote, bare = _unquote(bare)

        if bare == "":
            # A parent. Its scope is the stronger of what it inherits and what it declares.
            own = 0
            if in_secret_doc[i] and col == 0 and key.lower() in K8S_SECRET_DATA_KEYS:
                own = STRICT
            elif SECRET_PARENT_RE.search(key) and not NOT_SECRET_PARENT_RE.search(key):
                own = LOOSE
            stack.append((col, max(scope, own)))
            out.append(line)
            i += 1
            continue

        if bare in EMPTY_YAML_VALUES or BLOCK_SCALAR_RE.match(bare):
            out.append(line)
            i += 1
            continue

        if (
            should_mask(key, bare, mask_all)
            or scope == STRICT
            or (scope == LOOSE and _loose_masks(key, bare))
            or i in env_values
        ):
            out.append(f"{pre}{qkey}{sep}{quote}{mask_value(bare)}{quote}{comment}")
        else:
            out.append(line)
        i += 1
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


# ----------------------------------------------------------------------- driver


# A copy made by hand or by an editor keeps its credentials and loses its extension:
# `values.yaml.bak`, `app.env~`, `values.prd.yaml.pre-rotation.20260913`. Judged by the raw
# name, such a file falls through to the dotenv grammar, which cannot see a single
# `key: value` line -- and a YAML backup was printed raw exactly that way. Strip these,
# repeatedly, before any decision that reads the name.
BACKUP_SUFFIX_RE = re.compile(
    r"(~|\.(bak|backup|orig|old|save|sav|swp|swo|tmp|rej"
    r"|(pre|post)-[A-Za-z0-9_-]+|\d{6,14}(-\d{2,6})?|\d{4}-\d{2}-\d{2}))$",
    re.IGNORECASE,
)


def _logical_name(name: str) -> str:
    """The name a file had before it was backed up: `values.yaml.pre-x.20260913` -> `values.yaml`."""
    while True:
        stripped = BACKUP_SUFFIX_RE.sub("", name)
        if stripped == name or not stripped:
            return name
        name = stripped


def _is_yaml(name: str, text: str) -> bool:
    lower = name.lower()
    if YAML_NAME_RE.search(lower) or "kubeconfig" in lower:
        return True
    # Unnamed input (stdin, a piped `kubectl get -o yaml`) is YAML only when it carries a
    # manifest's signature -- both lines at column 0, which prose does not.
    if not name or name.startswith("<"):
        return bool(
            re.search(r"^apiVersion:\s*\S", text, re.M)
            and re.search(r"^kind:\s*\S", text, re.M)
        )
    return False


def _render_body(name: str, text: str, mask_all: bool) -> str:
    """The redacted text alone, without a header. Shared by the viewer and the scanner."""
    stripped = text.lstrip()
    if stripped.startswith(("{", "[")):
        try:
            return json.dumps(redact_json(json.loads(text), mask_all), indent=2) + "\n"
        except (ValueError, RecursionError):
            pass  # fall through to line-based

    base = _logical_name(os.path.basename(name)).lower()
    if _is_yaml(base if name and not name.startswith("<") else name, text):
        return redact_yaml(text, mask_all)
    if base in (".npmrc", ".pypirc", ".netrc") or base.endswith(
        (".ini", ".cfg", ".conf", ".toml")
    ):
        return redact_lines(text, INI_LINE, mask_all)
    # Default: dotenv shape.
    return redact_lines(text, DOTENV_LINE, mask_all)


def render(path: str, raw: bytes, mask_all: bool) -> str:
    global MASK_COUNT
    MASK_COUNT = 0
    name = _logical_name(os.path.basename(path))
    if OPAQUE_BLOB.search(name) or b"\x00" in raw[:4096]:
        return render_blob(path, raw)

    text = raw.decode("utf-8", "replace")
    if PEM_RE.search(text) and name.endswith((".pem", ".key", ".crt", ".cer")):
        return render_blob(path, raw)

    # Heuristic by default: ordinary config stays readable, credential-shaped
    # values do not. `--all` redacts every scalar.
    header = f"# {path}  [redacted view — values replaced by fingerprints, structure preserved]\n"
    return header + _render_body(path, text, mask_all)


# ------------------------------------------------------- content-based probe

CONFIGISH = (
    ".json",
    ".yaml",
    ".yml",
    ".ini",
    ".cfg",
    ".conf",
    ".toml",
    ".properties",
    ".env",
    ".npmrc",
    ".netrc",
    ".pypirc",
    ".xml",
)


# Filenames that are secret regardless of content.
def is_secret_name(path: str) -> bool:
    name = _logical_name(os.path.basename(path))
    return bool(
        ALWAYS_MASK_ALL.search(path)
        or ALWAYS_MASK_ALL.search(name)
        or OPAQUE_BLOB.search(name)
    )


def looks_configish(path: str) -> bool:
    name = _logical_name(os.path.basename(path)).lower()
    return (
        name.endswith(CONFIGISH)
        or bool(YAML_NAME_RE.search(name))
        or name.startswith(".env")
        or name in (".npmrc", ".netrc", ".pypirc")
        or "kubeconfig" in name
    )


def contains_secrets(path: str) -> bool:
    """True if reading this file raw would put a credential in the transcript.

    Filename alone is not enough: an ordinary-looking appsettings.json can hold a
    password. This opens the file and applies the same heuristics the
    viewer would, so the guard and the viewer never disagree.
    """
    if is_secret_name(path):
        return True
    if not looks_configish(path):
        return False
    try:
        if os.path.getsize(path) > MAX_BYTES:
            return True  # too big to vet -> assume the worst
        with open(path, "rb") as fh:
            raw = fh.read(MAX_BYTES)
    except OSError:
        return False
    if b"\x00" in raw[:4096]:
        return False
    return text_contains_secrets(raw.decode("utf-8", "replace"), path)


def text_contains_secrets(text: str, name_hint: str = "") -> bool:
    """The same heuristics, against text that may never have been a file.

    The write and outbound callers scan a rendered document, a brief, a command -- content
    with no path to stat. Splitting this out of contains_secrets is what lets them share one
    definition of "this is a credential" with the read path instead of growing a second.

    The answer is DERIVED from the viewer: render the text and ask whether anything was
    redacted. A separate detection walk used to live here, and it drifted -- it flagged a
    Helm `dbPassword: |` block that the viewer then printed raw. One code path cannot
    disagree with itself.

    `name_hint` only selects which line grammar to try (dotenv, YAML, INI); it is never
    required, and an unnamed blob is read as dotenv, the loosest of the three.
    """
    global MASK_COUNT
    if PEM_RE.search(text):
        return True
    before = MASK_COUNT
    try:
        _render_body(name_hint or "", text, False)
        return MASK_COUNT > before
    finally:
        MASK_COUNT = before


def render_or_verbatim(path: str, raw: bytes, mask_all: bool):
    """Render a view of `raw`, returning (text, masked).

    When nothing matched, the ORIGINAL bytes are returned untouched -- no header,
    no reformatting -- so routing a clean file through the viewer is invisible.
    """
    rendered = render(path, raw, mask_all)
    if MASK_COUNT == 0:
        return raw.decode("utf-8", "replace"), False
    return rendered, True
