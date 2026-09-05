"""secret_redact — shared credential-redaction heuristics.

Used by callers that must agree exactly -- the viewer that masks a file, the scanner
that answers yes/no, and the hook that decides allow/ask/deny. They are installed from
one payload precisely so they cannot drift apart.

Keeping the heuristics in one module stops the guard and the viewer from
drifting apart -- a drift where the guard says "safe" and the viewer would
have masked something is exactly how a secret reaches the transcript.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys

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
    if len(s) >= 24 and " " not in s and not s.startswith(("/", "./", "http://", "https://")):
        classes = sum(bool(re.search(p, s)) for p in (r"[a-z]", r"[A-Z]", r"[0-9]"))
        if classes >= 2 and PRIVKEY_RE.match(s.replace("-", "").replace("_", "")):
            return True
    return False


def should_mask(key, value, mask_all: bool) -> bool:
    if mask_all:
        return not isinstance(value, (bool, int, float, type(None)))
    if key is not None:
        k = str(key)
        if SECRET_KEY_RE.search(k) and not SAFE_KEY_RE.match(k):
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
    kind = "PEM/text key material" if PEM_RE.search(
        raw[:200].decode("utf-8", "replace")) else "opaque key material"
    return (f"# {path}\n"
            f"# {kind}, fully withheld\n"
            f"# {len(raw)} bytes, sha256:{digest}\n")


# ------------------------------------------------------------------ format: JSON

def redact_json(obj, mask_all: bool, key=None):
    if isinstance(obj, dict):
        return {k: redact_json(v, mask_all, key=k) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact_json(v, mask_all, key=key) for v in obj]
    if should_mask(key, obj, mask_all):
        return mask_value(obj)
    return obj


# ------------------------------------------ format: dotenv / ini / yaml (line based)

DOTENV_LINE = re.compile(r"^(\s*(?:export\s+)?)([A-Za-z_][A-Za-z0-9_.]*)(\s*=\s*)(.*)$")
YAML_LINE = re.compile(r"^(\s*-?\s*)([A-Za-z0-9_.\-/]+)(\s*:\s*)(.*)$")
INI_LINE = re.compile(r"^(\s*)([A-Za-z0-9_.\-/:@]+)(\s*=\s*)(.*)$")


def redact_lines(text: str, pattern: re.Pattern, mask_all: bool) -> str:
    out = []
    in_block = False
    for line in text.splitlines():
        stripped = line.strip()

        # Multi-line PEM blocks inside YAML/env: withhold the body entirely.
        if PEM_RE.search(line):
            global MASK_COUNT
            MASK_COUNT += 1
            in_block = True
            out.append(re.sub(r"(-----BEGIN [^-]+-----).*", r"\1 <redacted body>", line))
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
        # Preserve trailing comments and structural YAML markers.
        bare = val.strip()
        if bare in ("", "|", ">", "|-", ">-", "{}", "[]", "null", "~"):
            out.append(line)
            continue
        comment = ""
        cm = re.match(r'^((?:[^#"\']|"[^"]*"|\'[^\']*\')*?)(\s+#.*)$', val)
        if cm:
            bare, comment = cm.group(1).strip(), cm.group(2)

        quote = ""
        if len(bare) >= 2 and bare[0] == bare[-1] and bare[0] in "\"'":
            quote, bare = bare[0], bare[1:-1]

        if should_mask(key, bare, mask_all):
            out.append(f"{pre}{key}{sep}{quote}{mask_value(bare)}{quote}{comment}")
        else:
            out.append(line)
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


# ----------------------------------------------------------------------- driver

def render(path: str, raw: bytes, mask_all: bool) -> str:
    global MASK_COUNT
    MASK_COUNT = 0
    name = os.path.basename(path)
    if OPAQUE_BLOB.search(name) or b"\x00" in raw[:4096]:
        return render_blob(path, raw)

    text = raw.decode("utf-8", "replace")
    if PEM_RE.search(text) and name.endswith((".pem", ".key", ".crt", ".cer")):
        return render_blob(path, raw)

    # Heuristic masking by default: ordinary config stays readable, credential-
    # shaped values do not. `--all` forces every scalar to be masked.
    force_all = mask_all

    header = f"# {path}  [redacted view — values masked, structure preserved]\n"

    # JSON first: structure-aware beats line-based.
    stripped = text.lstrip()
    if stripped.startswith(("{", "[")):
        try:
            return header + json.dumps(
                redact_json(json.loads(text), force_all), indent=2) + "\n"
        except (ValueError, RecursionError):
            pass  # fall through to line-based

    lower = name.lower()
    if lower.endswith((".yaml", ".yml")) or "kubeconfig" in lower:
        return header + redact_lines(text, YAML_LINE, force_all)
    if lower in (".npmrc", ".pypirc", ".netrc") or lower.endswith((".ini", ".cfg", ".conf", ".toml")):
        return header + redact_lines(text, INI_LINE, force_all)
    # Default: dotenv shape.
    return header + redact_lines(text, DOTENV_LINE, force_all)



# ------------------------------------------------------- content-based probe

CONFIGISH = (".json", ".yaml", ".yml", ".ini", ".cfg", ".conf", ".toml",
             ".properties", ".env", ".npmrc", ".netrc", ".pypirc", ".xml")

# Filenames that are secret regardless of content.
def is_secret_name(path: str) -> bool:
    name = os.path.basename(path)
    return bool(ALWAYS_MASK_ALL.search(path) or ALWAYS_MASK_ALL.search(name)
                or OPAQUE_BLOB.search(name))


def looks_configish(path: str) -> bool:
    name = os.path.basename(path).lower()
    return name.endswith(CONFIGISH) or name.startswith(".env") or name in (
        ".npmrc", ".netrc", ".pypirc") or "kubeconfig" in name


def _walk_json_has_secret(obj, key=None) -> bool:
    if isinstance(obj, dict):
        return any(_walk_json_has_secret(v, k) for k, v in obj.items())
    if isinstance(obj, list):
        return any(_walk_json_has_secret(v, key) for v in obj)
    return should_mask(key, obj, False)


def contains_secrets(path: str) -> bool:
    """True if reading this file raw would put a credential in the transcript.

    Filename alone is not enough: an ordinary-looking appsettings.json can hold a
    password. This opens the file and applies the same masking heuristics the
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

    `name_hint` only selects which line grammar to try (dotenv, YAML, INI); it is never
    required, and an unnamed blob is read as dotenv, the loosest of the three.
    """
    if PEM_RE.search(text):
        return True

    stripped = text.lstrip()
    if stripped.startswith(("{", "[")):
        try:
            return _walk_json_has_secret(json.loads(text))
        except (ValueError, RecursionError):
            pass

    name = os.path.basename(name_hint).lower()
    if name.endswith((".yaml", ".yml")) or "kubeconfig" in name:
        pattern = YAML_LINE
    elif name in (".npmrc", ".pypirc", ".netrc") or name.endswith(
            (".ini", ".cfg", ".conf", ".toml")):
        pattern = INI_LINE
    else:
        pattern = DOTENV_LINE

    for line in text.splitlines():
        st = line.strip()
        if not st or st.startswith("#"):
            continue
        m = pattern.match(line)
        if not m:
            continue
        key, val = m.group(2), m.group(4).strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        if val and should_mask(key, val, False):
            return True
    return False


def render_or_verbatim(path: str, raw: bytes, mask_all: bool):
    """Render a view of `raw`, returning (text, masked).

    When nothing matched, the ORIGINAL bytes are returned untouched -- no header,
    no reformatting -- so routing a clean file through the viewer is invisible.
    """
    rendered = render(path, raw, mask_all)
    if MASK_COUNT == 0:
        return raw.decode("utf-8", "replace"), False
    return rendered, True
