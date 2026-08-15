#!/usr/bin/env python3
# resolve.py — resolve the delegate-backends cascade into ONE effective set of backend profiles.
#
#   resolve.py --scope <dir> --root <git-root> [--user-manifest <path>]
#
# Layers, applied lowest -> highest precedence:
#
#   1. user    ~/.agents/delegate-backends.json   (personal, this machine, NOT committed)
#   2. repo    <root>/.delegate-backends.json     (committed, team-shared)
#   3. subdir  <dir>/.delegate-backends.json for each dir from <root> down to <scope>, deepest last
#
# The asymmetry is the point, and it is why this resolver does not look like its siblings
# (.graph-repos.json, .handoff-repos.json). Those cascade whole entries and use {"remove": true}
# tombstones because every layer is equally entitled to declare one. Here it is not:
#
#   * ONLY the user layer may define `profiles`. A profile names a host that your source code
#     gets shipped to. A committed manifest that could introduce one would let a pull request
#     silently add an exfiltration target to every clone of the repo. A repo layer declaring
#     `profiles` is a hard error, not a merge.
#   * Repo layers NARROW, via `allow` — intersected across layers, so a nearer layer can only
#     ever remove reach, never add it. That makes tombstones unnecessary: `allow` already is the
#     un-inherit mechanism, and it fails safe (an empty intersection means no delegation at all).
#   * `neverDelegate` is a UNION across every layer, including the user layer. Sensitivity is a
#     property of the codebase, so a nearer layer must not be able to drop a protection a lower
#     one asserted. No approval overrides it either — the dispatcher refuses these paths outright.
#
# Emits one JSON object on stdout. Read-only and network-free: this never writes anything and
# never dials an endpoint, so the installer and the verifier can both call it and can never
# disagree about the effective set. Reachability is probed by the shell callers, not here.
import argparse
import ipaddress
import json
import os
import re
import stat
import sys
from urllib.parse import urlparse

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
CLASS_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
MANIFEST = ".delegate-backends.json"
# DELEGATE_USER_MANIFEST exists so a test fixture or an eval grader can resolve against a manifest
# it controls. Without it every such run would read the operator's real backend config — which is
# both unrepeatable and a way for a fixture to accidentally reference a live endpoint.
USER_MANIFEST = os.environ.get("DELEGATE_USER_MANIFEST") or os.path.join(
    os.path.expanduser("~"), ".agents", "delegate-backends.json")

DEFAULT_CONTEXT = 131072
DEFAULT_ROUNDS = 3
DEFAULT_ALLOW_TOOLS = "Read,Grep,Glob"
# Paths that are never delegable regardless of configuration. A repo may add to this; nothing
# can subtract from it. Kept deliberately short — a floor, not a policy.
BUILTIN_NEVER = [".env", ".env.*", "secrets/**", "*.pem", "*.key", "id_rsa*", ".ssh/**"]


def layer_files(scope: str, root: str) -> list[tuple[str, str, bool]]:
    """(layer-name, manifest-path, committed?) lowest precedence first."""
    out: list[tuple[str, str, bool]] = [("user", USER_MANIFEST, False)]
    out.append(("repo", os.path.join(root, MANIFEST), True))
    rel = os.path.relpath(scope, root)
    if rel not in (".", ""):
        cur = root
        for part in rel.split(os.sep):
            if part in ("", os.pardir):
                continue
            cur = os.path.join(cur, part)
            out.append((os.path.relpath(cur, root), os.path.join(cur, MANIFEST), True))
    return out


def classify_egress(base_url: str) -> str:
    """local iff the endpoint cannot leave this machine's trust boundary.

    Everything unrecognised is classified `remote`. Guessing `local` on an unparseable host is
    the one error with a real blast radius here: it would re-arm the sensitivity clause and route
    credentials off-box. Unknown therefore fails toward the stricter answer.
    """
    try:
        host = (urlparse(base_url).hostname or "").strip("[]")
    except Exception:  # noqa: BLE001
        return "remote"
    if not host:
        return "remote"
    if host in ("localhost", "localhost.localdomain") or host.endswith(".local"):
        return "local"
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return "remote"
    return "local" if (ip.is_loopback or ip.is_private or ip.is_link_local) else "remote"


def read_settings_file(raw: str, warnings: list[str]) -> dict:
    """Adopt an existing Claude Code --settings file as a profile source.

    Reads base URL and model out of it so a working setup does not have to be re-declared. The
    auth token is deliberately NOT returned: this object is printed to stdout, and stdout ends up
    in logs, transcripts, and the verifier's output. Only its presence and the file's mode travel,
    which is what the credential-hygiene warning needs.
    """
    out = {"settings_file": None, "base_url": None, "model": None,
           "has_token": False, "mode": None, "world_readable": None}
    p = os.path.expandvars(os.path.expanduser(raw))
    out["settings_file"] = p
    if not os.path.isfile(p):
        warnings.append(f"settingsFile {p} does not exist")
        return out
    try:
        st = os.stat(p)
        out["mode"] = oct(stat.S_IMODE(st.st_mode))
        out["world_readable"] = bool(stat.S_IMODE(st.st_mode) & 0o077)
    except OSError:
        pass
    try:
        with open(p) as f:
            data = json.load(f)
    except Exception as e:  # noqa: BLE001
        warnings.append(f"settingsFile {p}: invalid JSON ({e})")
        return out
    if not isinstance(data, dict):
        warnings.append(f"settingsFile {p}: expected a JSON object")
        return out
    env = data.get("env") if isinstance(data.get("env"), dict) else {}
    out["base_url"] = env.get("ANTHROPIC_BASE_URL")
    out["model"] = data.get("model") or env.get("ANTHROPIC_MODEL")
    out["has_token"] = bool(env.get("ANTHROPIC_AUTH_TOKEN") or env.get("ANTHROPIC_API_KEY"))
    return out


def _str_list(value, where: str, field: str, errors: list[str], pattern=None) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or any(not isinstance(v, str) or not v for v in value):
        errors.append(f"{where}: {field} must be an array of non-empty strings")
        return []
    if pattern is not None:
        bad = [v for v in value if not pattern.match(v)]
        if bad:
            errors.append(f"{where}: {field} entries must match {pattern.pattern} (got {bad!r})")
            return [v for v in value if pattern.match(v)]
    return value


def load_profiles(path: str, data: dict, errors: list[str], warnings: list[str]) -> dict[str, dict]:
    raw = data.get("profiles")
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        errors.append(f'{path}: "profiles" must be an object keyed by profile name')
        return {}

    out: dict[str, dict] = {}
    for name, p in raw.items():
        where = f"{path}[profiles.{name}]"
        if not NAME_RE.match(name):
            errors.append(f"{where}: profile name must match {NAME_RE.pattern}")
            continue
        if not isinstance(p, dict):
            errors.append(f"{where}: not an object")
            continue

        settings = read_settings_file(p["settingsFile"], warnings) if isinstance(
            p.get("settingsFile"), str) and p.get("settingsFile") else None

        base_url = p.get("baseUrl") or (settings or {}).get("base_url")
        if not isinstance(base_url, str) or not base_url:
            errors.append(f'{where}: needs a "baseUrl", or a "settingsFile" that supplies one')
            continue
        model = p.get("model") or (settings or {}).get("model")
        if not isinstance(model, str) or not model:
            errors.append(f'{where}: needs a "model", or a "settingsFile" that supplies one')
            continue

        egress = p.get("egress")
        derived = classify_egress(base_url)
        if egress is None:
            egress = derived
        elif egress not in ("local", "remote"):
            errors.append(f'{where}: egress must be "local" or "remote" (got {egress!r})')
            continue
        elif egress == "local" and derived == "remote":
            # Declaring a public host "local" is how the sensitivity clause gets re-armed against
            # an endpoint that is anything but. Refuse rather than trust the label.
            errors.append(
                f"{where}: declared egress=local but {base_url} is not a loopback/private address "
                f"— refusing to treat it as on-machine"
            )
            continue

        ctx = p.get("context", DEFAULT_CONTEXT)
        if not isinstance(ctx, int) or isinstance(ctx, bool) or ctx <= 0:
            errors.append(f"{where}: context must be a positive integer")
            continue
        rounds = p.get("maxQuestionRounds", DEFAULT_ROUNDS)
        if not isinstance(rounds, int) or isinstance(rounds, bool) or rounds < 0:
            errors.append(f"{where}: maxQuestionRounds must be a non-negative integer")
            continue
        allow_tools = p.get("allowTools", DEFAULT_ALLOW_TOOLS)
        if not isinstance(allow_tools, str) or not allow_tools:
            errors.append(f"{where}: allowTools must be a non-empty string")
            continue

        # A token is never stored here and never read by our scripts. Either the profile points at
        # a settingsFile and the CLI reads the credential itself, or `tokenEnv` names an environment
        # variable the caller has already exported. Both keep the secret out of this repo, out of
        # this resolver's stdout, and out of any transcript that quotes it.
        token_env = p.get("tokenEnv")
        if token_env is not None and (not isinstance(token_env, str) or not token_env):
            errors.append(f"{where}: tokenEnv must be the NAME of an environment variable")
            continue
        if isinstance(token_env, str) and token_env.startswith(("sk-", "sk_")):
            errors.append(
                f"{where}: tokenEnv looks like a token value, not a variable name. Put the secret "
                f"in the environment and name the variable here."
            )
            continue

        auto = _str_list(p.get("autoApprove"), where, "autoApprove", errors, CLASS_RE)
        always = _str_list(p.get("alwaysAsk"), where, "alwaysAsk", errors, CLASS_RE)
        overlap = sorted(set(auto) & set(always))
        if overlap:
            # alwaysAsk wins below; say so rather than letting the caller guess.
            warnings.append(
                f"{where}: {overlap!r} in both autoApprove and alwaysAsk — alwaysAsk wins")

        out[name] = {
            "name": name,
            "base_url": base_url,
            "model": model,
            "context": ctx,
            "egress": egress,
            "egress_declared": p.get("egress") is not None,
            "auto_approve": [c for c in auto if c not in always],
            "always_ask": always,
            "max_question_rounds": rounds,
            "allow_tools": allow_tools,
            "token_env": token_env if isinstance(token_env, str) else None,
            "settings_file": (settings or {}).get("settings_file"),
            "has_token": (settings or {}).get("has_token", False),
            "settings_mode": (settings or {}).get("mode"),
            "settings_world_readable": (settings or {}).get("world_readable"),
            "notes": p.get("notes", "") if isinstance(p.get("notes"), str) else "",
            "layer": "user",
            "manifest": path,
        }
    return out


def main() -> int:  # noqa: C901
    ap = argparse.ArgumentParser()
    ap.add_argument("--scope", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--user-manifest", default=USER_MANIFEST)
    args = ap.parse_args()

    scope = os.path.realpath(args.scope)
    root = os.path.realpath(args.root)

    errors: list[str] = []
    warnings: list[str] = []
    layers: list[dict] = []
    narrowed: list[dict] = []

    profiles: dict[str, dict] = {}
    never: list[str] = list(BUILTIN_NEVER)
    allow: set[str] | None = None
    default: str | None = None
    default_layer: str | None = None

    for name, file, committed in layer_files(scope, root):
        if name == "user":
            file = args.user_manifest
        present = os.path.isfile(file)
        layers.append({"layer": name, "file": file, "committed": committed, "present": present})
        if not present:
            continue
        try:
            with open(file) as f:
                data = json.load(f)
        except Exception as e:  # noqa: BLE001
            errors.append(f"{file}: invalid JSON ({e})")
            continue
        if not isinstance(data, dict):
            errors.append(f"{file}: expected a JSON object")
            continue
        if data.get("version", 1) != 1:
            warnings.append(f"{file}: unknown version {data.get('version')!r} — parsing as version 1")

        if committed and data.get("profiles") is not None:
            errors.append(
                f'{file}: a committed manifest may not define "profiles". A profile names a host '
                f"your code is shipped to; declaring one here would add an egress target to every "
                f'clone. Define it in {args.user_manifest} and narrow with "allow" instead.'
            )
        if not committed:
            profiles.update(load_profiles(file, data, errors, warnings))

        never.extend(_str_list(data.get("neverDelegate"), file, "neverDelegate", errors))

        if data.get("allow") is not None:
            entries = _str_list(data.get("allow"), file, "allow", errors, NAME_RE)
            layer_allow = set(entries)
            allow = layer_allow if allow is None else (allow & layer_allow)
            narrowed.append({"layer": name, "manifest": file, "allow": sorted(layer_allow)})

        if isinstance(data.get("default"), str):
            default, default_layer = data["default"], name

    # Narrowing is applied after every layer is read, so `allow` is the intersection of all of
    # them. An entry naming a profile the user layer never defined is a typo with a security
    # smell — it silently widens nothing, but it means the author believed it did.
    if allow is not None:
        for a in sorted(allow):
            if a not in profiles:
                warnings.append(
                    f"allow lists {a!r}, which no user-layer profile defines — it grants nothing")
        dropped = sorted(set(profiles) - allow)
        for d in dropped:
            profiles.pop(d)
        if dropped:
            narrowed.append({"layer": "effective", "dropped": dropped})
        if not profiles:
            errors.append(
                "the allow lists intersect to nothing — no profile is permitted in this scope")

    if default is not None and default not in profiles:
        errors.append(
            f"default profile {default!r} (set by the {default_layer} layer) is not among the "
            f"permitted profiles {sorted(profiles)!r}")
        default = None
    if default is None:
        default = sorted(profiles)[0] if len(profiles) == 1 else None
        default_layer = "implicit" if default else None

    for p in profiles.values():
        if p["settings_world_readable"]:
            warnings.append(
                f"{p['settings_file']} is mode {p['settings_mode']} and holds an auth token — "
                f"group/world readable. Consider: chmod 600 {p['settings_file']}"
            )

    # Deduplicate while preserving order: the union is a floor, and a repeated pattern in the
    # output would read as if it were weighted.
    seen: set[str] = set()
    never_out = [n for n in never if not (n in seen or seen.add(n))]

    json.dump({
        "scope": scope,
        "scope_rel": os.path.relpath(scope, root) if scope != root else ".",
        "root": root,
        "layers": layers,
        "profiles": sorted(profiles.values(), key=lambda p: p["name"]),
        "default": default,
        "default_layer": default_layer,
        "never_delegate": never_out,
        "narrowed": narrowed,
        "warnings": warnings,
        "errors": errors,
    }, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
