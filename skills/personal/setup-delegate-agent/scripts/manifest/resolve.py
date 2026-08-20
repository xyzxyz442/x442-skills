#!/usr/bin/env python3
# resolve.py — resolve the .agents/delegate.json cascade into ONE effective delegation roster.
#
#   resolve.py --scope <dir> [--home <dir>]
#
# Layers are every ancestor directory of <scope>, root -> leaf, each contributing its
# .agents/delegate.json if present. $HOME is always included, so ~/.agents/delegate.json is the
# machine-wide layer without being a special case. Nearest layer wins.
#
# There is no git-root special case, and that is the point: a workspace directory holding a
# hundred independent repos is not itself a repo, so anchoring on a git root would make its
# policy unreachable from inside any of them.
#
# WHO MAY DEFINE AN AGENT
#
# A layer may declare `agents` only if it is NOT inside a git work tree. A file inside a repo is
# committable, and a committed manifest that could introduce an agent would add an egress target
# to every clone of that repo via pull request. So definition lives in uncommittable layers
# (your home dir, a workspace dir) and repos may only NARROW.
#
# NARROWING IS MONOTONIC
#
# Every knob a nearer layer can set moves in exactly one direction — stricter:
#
#   allow            intersect      fewer agents reachable
#   neverDelegate    union          more protected paths
#   allowTools       intersect      fewer tools
#   allowModels      intersect      fewer models
#   autoApprove      intersect      more prompting
#   alwaysAsk        union          more prompting
#   maxQuestionRounds/maxTurns/timeout   min      smaller budgets
#   strictMcp        OR             can force strict, never un-strict
#   requireParty     strictest      local > same-party > third-party
#
# So no layering order and no planted file can ever WIDEN what the machine permits. That is what
# makes walking up from the filesystem safe: an unexpected ancestor manifest can only subtract.
#
# Read-only and network-free. Both the installer and the verifier call it, so they can never
# disagree about the effective roster. Reachability is probed by callers, not here.
import argparse
import ipaddress
import json
import os
import re
import stat
import subprocess
import sys
from urllib.parse import urlparse

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
CLASS_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
MANIFEST = os.path.join(".agents", "delegate.json")

# What each adapter's CLI can actually enforce. Declared rather than assumed, because a capability
# that silently does nothing is worse than one that is absent — the consent gate would be
# approving a scope nobody enforces.
ADAPTERS = {
    # schema:  how a forced output shape is expressed (needed for the ask-back protocol)
    # tools:   how faithfully a per-tool allowlist can be applied
    "claude": {"schema": "inline", "tools": "fine", "resume": True, "vendor": "anthropic"},
    "codex": {"schema": "file", "tools": "coarse", "resume": True, "vendor": "openai"},
    "copilot": {"schema": "none", "tools": "fine", "resume": True, "vendor": "github"},
    "gemini": {"schema": "none", "tools": "policy", "resume": True, "vendor": "google"},
}
PARTY_RANK = {"local": 0, "same-party": 1, "third-party": 2}
DEFAULT_ROUNDS = 3
DEFAULT_ALLOW_TOOLS = "Read,Grep,Glob"
# A floor, not a policy. A repo may add to this; nothing may subtract from it.
BUILTIN_NEVER = [".env", ".env.*", "secrets/**", "*.pem", "*.key", "id_rsa*", ".ssh/**"]


def ancestors(scope: str, home: str) -> list[str]:
    """Every directory from the filesystem root down to scope, with $HOME guaranteed present."""
    out, cur = [], os.path.realpath(scope)
    while True:
        out.append(cur)
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    out.reverse()
    h = os.path.realpath(home)
    if h not in out:
        out.insert(0, h)
    return out


def in_git_worktree(d: str) -> bool:
    try:
        r = subprocess.run(["git", "-C", d, "rev-parse", "--is-inside-work-tree"],
                           capture_output=True, text=True, timeout=5)
        return r.returncode == 0 and r.stdout.strip() == "true"
    except Exception:  # noqa: BLE001
        return False


def classify_party(base_url: str | None, adapter: str, vendor: str | None,
                   primary_vendor: str | None, local_provider: str | None) -> str:
    """local | same-party | third-party.

    `local` means the work never leaves the machine. `same-party` means it goes to a vendor who
    already sees this code because they run your primary assistant — delegating there adds no new
    observer. `third-party` means it adds one. Unknown always resolves to third-party: guessing
    downward is the only error here with real blast radius.
    """
    if local_provider:
        return "local"
    if base_url:
        try:
            host = (urlparse(base_url).hostname or "").strip("[]")
        except Exception:  # noqa: BLE001
            return "third-party"
        if host in ("localhost", "localhost.localdomain") or host.endswith(".local"):
            return "local"
        try:
            ip = ipaddress.ip_address(host)
            if ip.is_loopback or ip.is_private or ip.is_link_local:
                return "local"
        except ValueError:
            pass
    v = vendor or ADAPTERS.get(adapter, {}).get("vendor")
    # A custom base URL means the traffic goes wherever that host is, regardless of which CLI
    # speaks to it — an Anthropic-speaking gateway on someone else's domain is not Anthropic.
    if base_url and v == ADAPTERS.get(adapter, {}).get("vendor") and not vendor:
        return "third-party"
    if primary_vendor and v and v == primary_vendor:
        return "same-party"
    return "third-party"


def read_settings(path: str, warnings: list[str]) -> dict:
    """Read a CLI's own settings file for base URL / model / context. Never returns the token."""
    out = {"path": path, "base_url": None, "model": None, "context": None,
           "has_token": False, "mode": None, "world_readable": None}
    if not os.path.isfile(path):
        warnings.append(f"{path} does not exist")
        return out
    try:
        st = os.stat(path)
        out["mode"] = oct(stat.S_IMODE(st.st_mode))
        out["world_readable"] = bool(stat.S_IMODE(st.st_mode) & 0o077)
    except OSError:
        pass
    try:
        data = json.load(open(path))
    except Exception as e:  # noqa: BLE001
        warnings.append(f"{path}: invalid JSON ({e})")
        return out
    if not isinstance(data, dict):
        return out
    env = data.get("env") if isinstance(data.get("env"), dict) else {}
    out["base_url"] = env.get("ANTHROPIC_BASE_URL") or env.get("OPENAI_BASE_URL")
    out["model"] = data.get("model") or env.get("ANTHROPIC_MODEL")
    out["has_token"] = bool(env.get("ANTHROPIC_AUTH_TOKEN") or env.get("ANTHROPIC_API_KEY")
                            or env.get("OPENAI_API_KEY"))
    raw = env.get("CLAUDE_CODE_MAX_CONTEXT_TOKENS")
    if raw is not None:
        try:
            out["context"] = int(str(raw))
        except ValueError:
            warnings.append(f"{path}: CLAUDE_CODE_MAX_CONTEXT_TOKENS is not an integer")
    return out


def _slist(v, where, field, errors, pattern=None):
    if v is None:
        return None
    if not isinstance(v, list) or any(not isinstance(x, str) or not x for x in v):
        errors.append(f"{where}: {field} must be an array of non-empty strings")
        return None
    if pattern:
        bad = [x for x in v if not pattern.match(x)]
        if bad:
            errors.append(f"{where}: {field} entries must match {pattern.pattern} (got {bad!r})")
            return [x for x in v if pattern.match(x)]
    return v


def _toolset(s):
    return {t.strip() for t in s.split(",") if t.strip()}


def load_agents(path, data, may_define, errors, warnings):
    """Parse this layer's `agents` block. Refuses definition from a committable layer."""
    raw = data.get("agents")
    if raw is None:
        return {}
    if not may_define:
        errors.append(
            f'{path}: this layer is inside a git work tree and may not define "agents". A '
            f"committed manifest that could add an agent would add an egress target to every "
            f'clone. Define it in an uncommittable layer (~/.agents/delegate.json or a workspace '
            f'directory) and narrow here with "allow" instead.'
        )
        return {}
    if not isinstance(raw, dict):
        errors.append(f'{path}: "agents" must be an object keyed by agent name')
        return {}

    out = {}
    for name, a in raw.items():
        where = f"{path}[agents.{name}]"
        if not NAME_RE.match(name):
            errors.append(f"{where}: name must match {NAME_RE.pattern}")
            continue
        if not isinstance(a, dict):
            errors.append(f"{where}: not an object")
            continue
        adapter = a.get("adapter")
        if adapter not in ADAPTERS:
            errors.append(f"{where}: adapter must be one of {sorted(ADAPTERS)} (got {adapter!r})")
            continue

        cfg_dir = a.get("configDir")
        settings = None
        if isinstance(cfg_dir, str) and cfg_dir:
            cfg_dir = os.path.expandvars(os.path.expanduser(cfg_dir))
            settings = read_settings(os.path.join(cfg_dir, "settings.json"), warnings)

        model = a.get("model") or (settings or {}).get("model")
        if not isinstance(model, str) or not model:
            errors.append(f'{where}: needs a "model" (or a configDir whose settings supply one)')
            continue

        base_url = a.get("baseUrl") or (settings or {}).get("base_url")
        local_provider = a.get("localProvider")
        if local_provider and adapter != "codex":
            errors.append(f"{where}: localProvider is only meaningful for the codex adapter")
            continue

        ctx = a.get("context") or (settings or {}).get("context")
        if ctx is not None and (not isinstance(ctx, int) or isinstance(ctx, bool) or ctx <= 0):
            errors.append(f"{where}: context must be a positive integer")
            continue

        out[name] = {
            "name": name, "adapter": adapter, "model": model,
            "command": a.get("command") or adapter,
            "base_url": base_url, "config_dir": cfg_dir if isinstance(cfg_dir, str) else None,
            "local_provider": local_provider, "vendor": a.get("vendor"),
            "context": ctx, "notes": a.get("notes", "") if isinstance(a.get("notes"), str) else "",
            "settings_world_readable": (settings or {}).get("world_readable"),
            "settings_path": (settings or {}).get("path"),
            "settings_mode": (settings or {}).get("mode"),
            "has_token": (settings or {}).get("has_token", False),
            "layer": path, "capabilities": dict(ADAPTERS[adapter]),
            # Base limits; policy layers may only tighten these.
            "allow_tools": a.get("allowTools", DEFAULT_ALLOW_TOOLS),
            "allow_models": _slist(a.get("allowModels"), where, "allowModels", errors),
            "auto_approve": _slist(a.get("autoApprove"), where, "autoApprove", errors, CLASS_RE) or [],
            "always_ask": _slist(a.get("alwaysAsk"), where, "alwaysAsk", errors, CLASS_RE) or [],
            "max_question_rounds": a.get("maxQuestionRounds", DEFAULT_ROUNDS),
            "max_turns": a.get("maxTurns", 25),
            "timeout": a.get("timeout", 1800),
            "strict_mcp": a.get("strictMcp", True) is not False,
            "require_party": None,
        }
    return out


def tighten(agent, pol, where, errors):
    """Apply one policy block. Every knob moves toward stricter or not at all."""
    if not isinstance(pol, dict):
        errors.append(f"{where}: policy entry must be an object")
        return
    if "allowTools" in pol:
        if not isinstance(pol["allowTools"], str):
            errors.append(f"{where}: allowTools must be a string")
        else:
            agent["allow_tools"] = ",".join(
                sorted(_toolset(agent["allow_tools"]) & _toolset(pol["allowTools"])))
    if "allowModels" in pol:
        v = _slist(pol["allowModels"], where, "allowModels", errors)
        if v is not None:
            agent["allow_models"] = sorted(set(v) if agent["allow_models"] is None
                                           else set(agent["allow_models"]) & set(v))
    if "autoApprove" in pol:
        v = _slist(pol["autoApprove"], where, "autoApprove", errors, CLASS_RE)
        if v is not None:
            agent["auto_approve"] = sorted(set(agent["auto_approve"]) & set(v))
    if "alwaysAsk" in pol:
        v = _slist(pol["alwaysAsk"], where, "alwaysAsk", errors, CLASS_RE)
        if v is not None:
            agent["always_ask"] = sorted(set(agent["always_ask"]) | set(v))
    for key, field in (("maxQuestionRounds", "max_question_rounds"),
                       ("maxTurns", "max_turns"), ("timeout", "timeout")):
        if key in pol:
            v = pol[key]
            if not isinstance(v, int) or isinstance(v, bool) or v < 0:
                errors.append(f"{where}: {key} must be a non-negative integer")
            else:
                agent[field] = min(agent[field], v)
    if pol.get("strictMcp") is True:
        agent["strict_mcp"] = True
    if "requireParty" in pol:
        v = pol["requireParty"]
        if v not in PARTY_RANK:
            errors.append(f"{where}: requireParty must be one of {sorted(PARTY_RANK)}")
        else:
            cur = agent["require_party"]
            agent["require_party"] = v if cur is None or PARTY_RANK[v] < PARTY_RANK[cur] else cur


def main() -> int:  # noqa: C901
    ap = argparse.ArgumentParser()
    ap.add_argument("--scope", required=True)
    ap.add_argument("--home", default=os.environ.get("DELEGATE_HOME") or os.path.expanduser("~"))
    args = ap.parse_args()

    scope = os.path.realpath(args.scope)
    errors, warnings, layers, narrowed = [], [], [], []
    agents, never, policies = {}, list(BUILTIN_NEVER), []
    allow, default, default_layer = None, None, None
    primary, primary_layer = None, None

    for d in ancestors(scope, args.home):
        f = os.path.join(d, MANIFEST)
        present = os.path.isfile(f)
        committable = in_git_worktree(d) if present else False
        if present:
            layers.append({"dir": d, "file": f, "committable": committable})
        if not present:
            continue
        try:
            data = json.load(open(f))
        except Exception as e:  # noqa: BLE001
            errors.append(f"{f}: invalid JSON ({e})")
            continue
        if not isinstance(data, dict):
            errors.append(f"{f}: expected a JSON object")
            continue
        if data.get("version", 1) != 1:
            warnings.append(f"{f}: unknown version {data.get('version')!r} — parsing as version 1")

        agents.update(load_agents(f, data, not committable, errors, warnings))

        v = _slist(data.get("neverDelegate"), f, "neverDelegate", errors)
        if v:
            never.extend(v)
        if data.get("allow") is not None:
            v = _slist(data.get("allow"), f, "allow", errors, NAME_RE)
            if v is not None:
                s = set(v)
                allow = s if allow is None else (allow & s)
                narrowed.append({"file": f, "allow": sorted(s)})
        if isinstance(data.get("default"), str):
            default, default_layer = data["default"], f
        if isinstance(data.get("primary"), str):
            primary, primary_layer = data["primary"], f
        if isinstance(data.get("policy"), dict):
            policies.append((f, data["policy"]))

    # Party depends on the primary assistant, so it is computed after every layer has been read.
    primary_vendor = ADAPTERS.get(primary, {}).get("vendor") if primary else None
    if primary and primary not in ADAPTERS:
        warnings.append(f"primary {primary!r} is not a known adapter — party falls back to third-party")
    for a in agents.values():
        a["party"] = classify_party(a["base_url"], a["adapter"], a["vendor"],
                                    primary_vendor, a["local_provider"])

    # Narrowing after every layer, so `allow` is the intersection of all of them.
    if allow is not None:
        for name in sorted(allow):
            if name not in agents:
                warnings.append(f"allow lists {name!r}, which no layer defines — it grants nothing")
        dropped = sorted(set(agents) - allow)
        for name in dropped:
            agents.pop(name)
        if dropped:
            narrowed.append({"effect": "dropped", "agents": dropped})
        if not agents:
            errors.append("the allow lists intersect to nothing — no agent is permitted here")

    for f, pol in policies:
        for key, block in pol.items():
            targets = agents.values() if key == "*" else [agents[key]] if key in agents else []
            for a in targets:
                tighten(a, block, f"{f}[policy.{key}]", errors)

    for a in list(agents.values()):
        rp = a["require_party"]
        if rp and PARTY_RANK[a["party"]] > PARTY_RANK[rp]:
            narrowed.append({"effect": "party", "agent": a["name"],
                             "required": rp, "actual": a["party"]})
            agents.pop(a["name"])
            continue
        if a["allow_models"] is not None and a["model"] not in a["allow_models"]:
            narrowed.append({"effect": "model", "agent": a["name"],
                             "model": a["model"], "allowed": a["allow_models"]})
            agents.pop(a["name"])
            continue
        # A capability that cannot be enforced must be visible, not assumed.
        if a["capabilities"]["schema"] == "none":
            warnings.append(
                f"{a['name']}: the {a['adapter']} adapter cannot force an output schema, so "
                f"ask-back is best-effort — a blocked sub-agent may return prose instead of a question")
        if a["capabilities"]["tools"] == "coarse" and _toolset(a["allow_tools"]):
            warnings.append(
                f"{a['name']}: the {a['adapter']} adapter has sandbox levels, not a per-tool "
                f"allowlist — {a['allow_tools']!r} is approximated, not enforced tool-by-tool")
        if a["settings_world_readable"]:
            warnings.append(f"{a['settings_path']} is mode {a['settings_mode']} and holds a token "
                            f"— group/world readable. Consider: chmod 600 {a['settings_path']}")

    # Default selection. A repo that narrows away the machine-wide default is the NORMAL case,
    # not a misconfiguration, so fall back rather than erroring — and say which layer caused it.
    default_reason = None
    if default is not None and default not in agents:
        if len(agents) == 1:
            only = next(iter(agents))
            default_reason = (f"{default!r} (set by {default_layer}) is not permitted here; "
                              f"fell back to the only permitted agent {only!r}")
            default = only
            default_layer = "fallback"
        else:
            errors.append(
                f"default {default!r} (set by {default_layer}) is not permitted here, and "
                f"{len(agents)} agents remain — declare a default in this scope")
            default = None
    if default is None and len(agents) == 1:
        default, default_layer = next(iter(agents)), "implicit"

    seen = set()
    json.dump({
        "scope": scope,
        "layers": layers,
        "primary": primary, "primary_layer": primary_layer, "primary_vendor": primary_vendor,
        "agents": sorted(agents.values(), key=lambda a: a["name"]),
        "default": default, "default_layer": default_layer, "default_reason": default_reason,
        "never_delegate": [n for n in never if not (n in seen or seen.add(n))],
        "narrowed": narrowed, "warnings": warnings, "errors": errors,
    }, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
