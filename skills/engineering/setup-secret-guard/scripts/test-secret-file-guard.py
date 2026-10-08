#!/usr/bin/env python3
"""Regression tests for the PreToolUse guard's read-rewrite half.

Run: python3 test-secret-file-guard.py   (exit 0 = pass)

The guard is load-bearing and SILENT when it fails: a read it does not rewrite is
not denied, it is simply allowed, and the value reaches the transcript. So the
assertion here is deliberately coarse -- "this command cannot run as written" --
rather than checking for a specific decision. Any of rewrite / ask / deny is a
pass; a bare allow-with-no-change on a credential read is the bug.

Every fixture is synthetic. Nothing here touches a real credential file.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile

GUARD = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "payload", "secret-file-guard.py"
)


def decide(cmd, cwd):
    p = subprocess.run(
        [sys.executable, GUARD],
        text=True,
        capture_output=True,
        input=json.dumps(
            {"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": cwd}
        ),
    )
    if p.returncode != 0:
        raise AssertionError(f"guard crashed: {p.stderr}")
    if not p.stdout.strip():
        return "allow", None
    out = json.loads(p.stdout)["hookSpecificOutput"]
    return out["permissionDecision"], out.get("updatedInput", {}).get("command")


def protected(cmd, cwd):
    """True when the credential read cannot reach the transcript as written."""
    decision, updated = decide(cmd, cwd)
    if decision in ("deny", "ask"):
        return True
    return bool(updated and "redact-view" in updated)


# Prefixes that put a REDACTABLE verb with a flag earlier in the same command.
# This is the shape that regressed: the flag-value sub-pattern was `\S+`, which is
# not bounded by shell separators, so `head -20 /etc/passwd` swallowed `; cat .env`
# and the credential read became that match's "path" -- never rewritten, never
# reported. See secret-guard-compound-cat-bypass-handoff.
PREFIXES = [
    ("head-flag-in-pipe", "ps aux | grep node | head -20"),
    ("head-n-in-pipe", "ps aux | grep node | head -n 20"),
    ("head-flag-and-file", "head -20 /etc/passwd"),
    ("tail-n-and-file", "tail -n 5 /etc/passwd"),
    ("head-c-and-file", "head -c 100 /etc/passwd"),
    ("nl-flag-and-file", "nl -ba /etc/passwd"),
    ("no-redactable-verb", "git log --oneline -5"),
    ("quoted-echo", 'echo "=== section ==="'),
]
SEPARATORS = [("and", " && "), ("semi", "; "), ("or", " || "), ("newline", "\n")]
READS = [
    ("cat-relative", "cat .env"),
    ("cat-absolute", "cat {d}/.env"),
    ("head-absolute", "head {d}/.env"),
    ("cat-quoted", 'cat ".env"'),
]


# ------------------------------------------------------- cluster-API producers
#
# A command that pulls credentials from a cluster API names no file, so a guard routed by
# path never saw it: `argocd app get APP -o json` printed an Application's inline Helm
# values, client secrets included. These are synthetic stand-ins for those producers. The
# stubs print fake values only; nothing here contacts a cluster.

FAKE = (
    "FAKEclientSecret0123456789abcdef",
    "FAKEwebhookSecret0123456789xyzw",
    "FAKEdbPass98765",
)

APP_JSON = json.dumps(
    {
        "metadata": {"name": "uat-acme-api"},
        "spec": {
            "source": {
                "repoURL": "https://git.example/acme.git",
                "path": "charts/api",
                "targetRevision": "main",
                "helm": {
                    "valueFiles": ["values-uat.yaml"],
                    "values": "app:\n  auth0:\n    clientId: abc123\n"
                    f"    clientSecret: {FAKE[0]}\n    webhookSecret: {FAKE[1]}\n",
                    "parameters": [{"name": "app.db.password", "value": FAKE[2]}],
                },
            }
        },
    }
)
APP_YAML = (
    "metadata:\n  name: uat-acme-api\nspec:\n  source:\n    helm:\n      values: |\n"
    f"        app:\n          auth0:\n            clientSecret: {FAKE[0]}\n"
    f"            webhookSecret: {FAKE[1]}\n"
    f"      parameters:\n      - name: app.db.password\n        value: {FAKE[2]}\n"
)
HELM_VALUES = (
    f"USER-SUPPLIED VALUES:\napp:\n  auth0:\n    clientSecret: {FAKE[0]}\n"
    f"    webhookSecret: {FAKE[1]}\n"
)
# Plural `get secrets` returns a List: `kind: Secret` sits indented inside each item, where a
# column-0 anchor cannot see it, and a key like DATABASE_URL is not credential-named.
SECRET_LIST = (
    "apiVersion: v1\nitems:\n- apiVersion: v1\n  data:\n"
    "    DATABASE_URL: RkFLRWRiVXJsUGFzcw==\n  kind: Secret\n  metadata:\n    name: acme\n"
    "kind: List\n"
)

STUB = r"""#!/usr/bin/env python3
import sys
args = " ".join(sys.argv[1:])
out = {OUT}
sys.stdout.write(out(args))
"""

PRODUCER_COMMANDS = [
    ("argocd-json", "argocd app get uat-acme-api -o json"),
    ("argocd-yaml", "argocd app get uat-acme-api -o yaml"),
    ("argocd-default", "argocd app get uat-acme-api"),
    ("argocd-global-flag", "argocd --grpc-web app get uat-acme-api -o json"),
    ("argocd-manifests", "argocd app manifests uat-acme-api"),
    ("argocd-diff", "argocd app diff uat-acme-api --server-side-diff"),
    ("helm-values", "helm get values acme-api -n acme"),
    ("helm-all", "helm get all acme-api"),
    ("kubectl-secret-yaml", "kubectl get secret acme -o yaml"),
    ("kubectl-secrets-json", "kubectl get secrets -n acme -o json"),
    ("kubectl-output-eq", "kubectl -n acme get secret acme --output=yaml"),
    ("kubectl-deploy-yaml", "kubectl get deploy acme -oyaml"),
    ("kubectl-kubeconfig", "kubectl --kubeconfig=/tmp/kc get secret acme -o yaml"),
]
SHAPES = [
    ("bare", "{p}"),
    ("jq", "{p} | jq '.'"),
    ("head-c", "{p} | head -c 900"),
    ("stderr-merged", "{p} 2>&1 | head -50"),
    ("subst", 'x=$({p}); echo "$x"'),
    ("subst-quoted", 'echo "$({p})"'),
]


def _rewritten(cmd, cwd):
    decision, updated = decide(cmd, cwd)
    return (
        decision == "allow" and bool(updated and "redact-view" in updated),
        decision,
        updated,
    )


def cluster_cases(d):
    failures, checked = [], 0

    for pname, prod in PRODUCER_COMMANDS:
        for sname, shape in SHAPES:
            cmd = shape.format(p=prod)
            checked += 1
            if not protected(cmd, d):
                failures.append(f"cluster/{pname}/{sname}: {cmd!r} ran unguarded")

    # The exact shape that leaked, inside a loop with a variable app name.
    loop = (
        'for a in uat-acme-api prd-acme-api; do argocd app get "$a" -o json '
        "| jq -r '.spec.source // .spec.sources | tostring' | head -c 900; echo; done"
    )
    checked += 1
    ok, decision, _ = _rewritten(loop, d)
    if not ok:
        failures.append(
            f"cluster/loop: the leaking command was not rewritten ({decision})"
        )

    # A producer handed to another shell as a quoted script runs there, not as data.
    for cmd in (
        "bash -c 'argocd app get uat-acme-api -o json'",
        "ssh bastion 'kubectl get secret acme -o yaml'",
        "bash <<'EOF'\nhelm get values acme-api\nEOF",
    ):
        checked += 1
        if not protected(cmd, d):
            failures.append(f"cluster/nested: {cmd!r} ran unguarded")

    # Shapes the shell reads as a producer while a raw-text match does not. Each one printed a
    # Secret unrouted in the first cut of this rule (found in a commit security review).
    for cmd in (
        "kubectl get secret acme \\\n  -o yaml",
        "argocd \\\n  app get acme -o json",
        "kubectl get secret acme -o 'yaml'",
        "'kubectl' get secret acme -o yaml",
        '"argocd" app get acme -o json',
        "kubectl get --raw /api/v1/namespaces/acme/secrets/acme",
        "kubectl get secret acme -o yaml > s.txt; cat s.txt",
        "kubectl get secret acme -o yaml >&1",
        "kubectl get secret acme -o yaml > /dev/fd/1",
        "cat <<EOF\n$(kubectl get secret acme -o yaml)\nEOF",
    ):
        checked += 1
        if not protected(cmd, d):
            failures.append(f"cluster/differential: {cmd!r} ran unguarded")

    # A later rule must not discard the routing. A values-file mention plus a filter in another
    # stage used to ask with no updated command, so approving ran the producer unrouted.
    for cmd in (
        "helm template acme ./chart -f values-uat.yaml | yq '.kind'",
        "helm get values acme -o yaml | grep -i secret",
    ):
        checked += 1
        decision, updated = decide(cmd, d)
        if not (updated and "redact-view" in updated):
            failures.append(
                f"cluster/routing-kept: {cmd!r} was {decision} without routing"
            )

    # ...but a values file still asks when something outside a producer can print it. Judging
    # the ask per stage dropped `ls values.yaml | xargs grep`, which v12 asked about.
    for cmd in (
        "ls values-uat.yaml | xargs grep password",
        "find charts -name 'values*.yaml' | xargs grep -h token",
    ):
        checked += 1
        if not protected(cmd, d):
            failures.append(f"cluster/values-ask-kept: {cmd!r} ran unguarded")

    # The discount covers only the exact step the guard routed. A producer word in a quote or
    # a comment elsewhere is not a routed step, and it used to excuse a raw values read.
    for cmd in (
        'kubectl get pods -o yaml; grep password values-uat.yaml "kubectl get"',
        "kubectl get pods -o yaml; grep token values-uat.yaml # helm template",
    ):
        checked += 1
        decision, _ = decide(cmd, d)
        if decision not in ("ask", "deny"):
            failures.append(f"cluster/discount-exact: {cmd!r} was {decision}")

    # Quotes and escapes are removed, not blanked: the shell joins `ya'ml'` into `yaml` and
    # `kube"ctl"` into `kubectl`, and a match on a blanked view read different words.
    for cmd in (
        "kubectl get secret acme -o ya'ml'",
        'kube"ctl" get secret acme -o yaml',
        "kube\\ctl get secret acme -o yaml",
        "kubectl g\\\net secret acme -o yaml",
    ):
        checked += 1
        ok_, decision, _ = _rewritten(cmd, d)
        if not ok_:
            failures.append(f"cluster/dequote: {cmd!r} was {decision}, not routed")

    # A redirect anywhere in the step, or an earlier `exec >`, sends the producer's output to a
    # file the viewer never sees -- the insertion after it routes nothing.
    for cmd in (
        "> out.txt kubectl get secret acme -o yaml; cat out.txt",
        "exec > out.txt; kubectl get secret acme -o yaml",
    ):
        checked += 1
        decision, _ = decide(cmd, d)
        if decision not in ("ask", "deny"):
            failures.append(f"cluster/redirect-before: {cmd!r} was {decision}")

    # Words the shell passes: bash decodes $'...' (escapes included), and macOS resolves a
    # binary name case-insensitively, so `Kubectl` is kubectl.
    for cmd in (
        "kubectl get secret acme -o $'yaml'",
        "kubectl get secret acme -o $'\\x79aml'",
        "Kubectl get secret acme -o yaml",
        "ARGOCD app get acme -o json",
        "kubectl config view --raw",
    ):
        checked += 1
        ok_, decision, _ = _rewritten(cmd, d)
        if not ok_:
            failures.append(f"cluster/shell-words: {cmd!r} was {decision}, not routed")
    checked += 1
    decision, _ = decide("kubectl get secret acme -o $'jsonpath={.data.password}'", d)
    if decision != "deny":
        failures.append(
            f"cluster/shell-words: ANSI-C jsonpath was {decision}, expected deny"
        )

    # Slice: quoted scripts (ADR 0026). A runner on the allowlist runs its quoted argument, so a
    # producer or a credential read inside it is asked about -- not rewritten, since nested
    # quoting is where the next differential would come from.
    for cmd in (
        "su -c 'kubectl get secret acme -o yaml'",
        "runuser -l svc -c 'kubectl get secret acme -o yaml'",
        "script -q -c 'kubectl get secret acme -o yaml' /dev/null",
        "flock /tmp/l -c 'helm get values acme'",
        "sudo -s 'kubectl get secret acme -o yaml'",
        "python3 <<'PY'\nimport os\nos.system('kubectl get secret acme -o yaml')\nPY",
        "make -f - <<'MK'\nall:\n\tkubectl get secret acme -o yaml\nMK",
        "bash -c 'cat .env'",
        "eval 'cat .env'",
        'sh -c "head .env"',
        "su -c 'cat .env'",
        "bash <<'EOF'\ncat .env\nEOF",
    ):
        checked += 1
        decision, _ = decide(cmd, d)
        if decision != "ask":
            failures.append(
                f"quoted-script/runner: {cmd!r} was {decision}, expected ask"
            )
    # ...honest quoting stays untouched, including after a runner in an EARLIER step.
    for cmd in (
        'echo "kubectl get secret acme -o yaml"',
        'git commit -m "route kubectl get secret -o yaml through the viewer"',
        'bash scripts/x.sh; git commit -m "route kubectl get secret -o yaml"',
        'echo "cat .env" >> notes.txt',
        "cat > notes.md <<'EOF'\nRun cat .env to see the keys.\nEOF",
    ):
        checked += 1
        decision, updated = decide(cmd, d)
        if decision in ("ask", "deny") or (updated and "redact-view" in updated):
            failures.append(
                f"quoted-script/honest: {cmd!r} was interfered with ({decision})"
            )
    # The documented cooperative limit (ADR 0026): an interpreter one-liner is not detected.
    # Pinned so the limit is a decision, not an accident -- change it deliberately or not at all.
    checked += 1
    decision, _ = decide(
        "python3 -c \"import os; os.system('kubectl get secret acme -o yaml')\"", d
    )
    if decision != "allow":
        failures.append(
            f"quoted-script/limit: interpreter one-liner was {decision}; update ADR 0026"
        )

    # Slice: template parity. Plain `kubectl config view` redacts only password, token and cert
    # data -- OIDC auth-provider secrets and exec-plugin env values print raw (verified against a
    # synthetic kubeconfig) -- so config view is always routed. A template output that can reach
    # credentials (`users`, recursive `..`, the whole document) prints a bare value the viewer
    # cannot redact, so it is denied with or without --raw. Templates over contexts, clusters and
    # current-context are everyday queries and stay untouched.
    for cmd in (
        "kubectl config view --raw -o jsonpath='{.users[0].user.token}'",
        "kubectl config view --raw -o go-template='{{(index .users 0).user.token}}'",
        "kubectl config view --flatten --minify -o jsonpath='{.users[0].user.client-key-data}'",
        "kubectl config view -o jsonpath='{.users[0].user.auth-provider.config.client-secret}'",
        "kubectl config view -o jsonpath='{..client-secret}'",
        "kubectl config view -o go-template='{{json .}}'",
        # The template is checked against an allowlist of safe roots, not a list of bad words:
        # a file template, a wildcard or an indexed root can reach users without naming them.
        "kubectl config view -o jsonpath-file=/tmp/t.txt",
        "kubectl config view -o go-template-file=/tmp/t.tmpl",
        "kubectl config view -o jsonpath='{.*}'",
        "kubectl config view -o jsonpath='{[*]}'",
        "kubectl config view -o go-template='{{index . \"us\"}}'",
        # kubectl honours the LAST -o; every template in the step is checked, so the order of
        # a safe and an unsafe one cannot matter, and custom-columns does not end the check.
        "kubectl config view -o go-template='{{.current-context}}' -o jsonpath='{[*]}'",
        "kubectl config view -o jsonpath='{[*]}' -o go-template='{{.current-context}}'",
        "kubectl config view -o custom-columns=A:.contexts -o jsonpath='{[*]}'",
    ):
        checked += 1
        decision, _ = decide(cmd, d)
        if decision != "deny":
            failures.append(f"template-parity: {cmd!r} was {decision}, expected deny")
    for cmd in (
        "kubectl config view -o jsonpath='{.current-context}'",
        "kubectl config view -o jsonpath='{.contexts[*].name}'",
        "kubectl config view -o jsonpath='{range .contexts[*]}{.name}{\"\\n\"}{end}'",
        "kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'",
        "kubectl config view -o go-template='{{.current-context}}'",
    ):
        checked += 1
        decision, updated = decide(cmd, d)
        if decision != "allow" or (updated and "redact-view" in updated):
            failures.append(
                f"template-parity/honest: {cmd!r} was interfered with ({decision})"
            )
    for cmd in (
        "kubectl config view",
        "kubectl config view --minify",
        "kubectl config view --raw",
    ):
        checked += 1
        ok_, decision, _ = _rewritten(cmd, d)
        if not ok_:
            failures.append(
                f"template-parity/routed: {cmd!r} was {decision}, not routed"
            )

    # Slice: output precedence. kubectl ignores --template when -o names a document format, in
    # either order, and prints the whole kubeconfig (measured on kubectl 1.37.1 against a
    # synthetic kubeconfig: 19 lines for `-o yaml --template=...`, 0 for the bare template). The
    # guard took the --template flag at its word and left the full document unrouted.
    for cmd in (
        "kubectl config view -o yaml --template='{{.current-context}}'",
        "kubectl config view --template='{{.current-context}}' -o yaml",
        "kubectl config view -o json --template='{{.current-context}}'",
        "kubectl config view --output=yaml --template '{{.current-context}}'",
        'kubectl config view -o "yaml" --template={{.current-context}}',
        "kubecolor config view -ojson --template='{{.current-context}}'",
    ):
        checked += 1
        ok_, decision, _ = _rewritten(cmd, d)
        if not ok_:
            failures.append(f"output-precedence: {cmd!r} was {decision}, not routed")
    for cmd in (
        "kubectl config view --template='{{.current-context}}'",
        "kubectl config view -o go-template --template='{{.current-context}}'",
        "kubectl config view -o jsonpath --template='{.current-context}'",
    ):
        checked += 1
        decision, updated = decide(cmd, d)
        if decision != "allow" or (updated and "redact-view" in updated):
            failures.append(
                f"output-precedence/honest: {cmd!r} was interfered with ({decision})"
            )

    # Slice: kyaml. kubectl's flow-style YAML is a whole document, but the viewer reads block
    # YAML line by line and passes kyaml through with the Secret's data raw. Until the viewer
    # learns it, the step asks and names `-o yaml`, which it does redact.
    for cmd in (
        "kubectl get secret acme -o kyaml",
        "kubectl get secret acme -okyaml",
        "kubecolor get secret acme --output=kyaml",
        "kubectl get pods -o kyaml",
        "kubectl get secret acme -o yaml -o kyaml",
        "kubectl config view -o kyaml",
        "kubectl config view -o kyaml --template='{{.current-context}}'",
    ):
        checked += 1
        decision, _ = decide(cmd, d)
        if decision != "ask":
            failures.append(f"kyaml: {cmd!r} was {decision}, expected ask")
    # Slice: combined short flags. kubectl's flag parser joins boolean shorthands with `-o`
    # (`-Ao yaml` is `-A -o yaml`; confirmed on 1.37.1, where `-Ro bogusfmt` is refused as an
    # output format). The guard wanted whitespace right before `-o` and missed the format.
    for cmd in (
        "kubectl get secrets -Ao yaml",
        "kubectl get secrets -Aoyaml",
        "kubectl get secret acme -wo json",
        "kubectl get secrets -ARo=yaml",
        # `-n` takes a value, so `-nfoo` is a namespace and never an `-o`.
        "kubectl get secret acme -o yaml -nfoo",
    ):
        checked += 1
        ok_, decision, _ = _rewritten(cmd, d)
        if not ok_:
            failures.append(f"short-flags: {cmd!r} was {decision}, not routed")
    checked += 1
    decision, _ = decide("kubectl get secrets -Ao kyaml", d)
    if decision != "ask":
        failures.append(f"short-flags/kyaml: was {decision}, expected ask")
    checked += 1
    decision, updated = decide("kubectl get pods -Ao wide", d)
    if decision != "allow" or (updated and "redact-view" in updated):
        failures.append(
            f"short-flags/honest: -Ao wide was interfered with ({decision})"
        )

    checked += 1
    ok_, decision, _ = _rewritten("kubectl get secret acme -o kyaml -o yaml", d)
    if not ok_:
        failures.append(f"kyaml/last-o-wins: was {decision}, not routed")

    # Slice: unresolved reads. A path held in a variable cannot be opened here, and its
    # extension may say nothing (`config.uat`). The viewer prints a clean file byte-identical,
    # so every read whose path is not a literal goes through it.
    for cmd in (
        "for f in /srv/app/config.uat; do cat $f; done",
        'cat "$CFG"',
        "head -5 ${DIR}/x",
        "cat $(ls /srv/app/*)",
    ):
        checked += 1
        ok_, decision, _ = _rewritten(cmd, d)
        if not ok_:
            failures.append(f"unresolved-read: {cmd!r} was {decision}, not routed")
    # A variable in a FLAG VALUE is not a path: `head -n $N` reads stdin. Routing it rewrote
    # honest commands into broken ones (`"redact-view" $N | head -n`).
    # ...but a flag only takes a value for the verb that defines it: `-n`, `-s`, `-b` and `-v`
    # are plain flags for cat, so the variable after them is the path, and it is routed.
    for cmd in (
        'cat -n "$HOME/.env"',
        "cat -s $DIR/.env",
        'cat -v "$F"',
        'tac -s "$SEP" "$F"',
    ):
        checked += 1
        ok_, decision, _ = _rewritten(cmd, d)
        if not ok_:
            failures.append(
                f"unresolved-read/plain-flag: {cmd!r} was {decision}, not routed"
            )
    for cmd in (
        "ps aux | head -n $N",
        'tail -n "$LINES" app.log',
        "head -c $BYTES big.bin",
        "git log | head -$N",
        "less +$LINE file.txt",
    ):
        checked += 1
        decision, updated = decide(cmd, d)
        if decision in ("ask", "deny") or (updated and "redact-view" in updated):
            failures.append(
                f"unresolved-read/flag-value: {cmd!r} was interfered with ({decision})"
            )
    with open(os.path.join(d, "plain.txt"), "w") as fh:
        fh.write("just a line of text\n")
    checked += 1
    decision, updated = decide(f"cat {d}/plain.txt", d)
    if decision != "allow" or updated:
        failures.append(
            "unresolved-read/literal: a literal clean path was interfered with"
        )
    checked += 1
    _, _, upd = _rewritten('F=plain.txt; cat "$F"', d)
    shown = subprocess.run(
        ["bash", "-c", upd or "false"], cwd=d, text=True, capture_output=True
    )
    if shown.stdout != "just a line of text\n":
        failures.append(
            "unresolved-read/clean: a clean file read through a variable changed"
        )

    # Slice: kubecolor. On this machine kubectl is an alias for kubecolor, so an agent may well
    # write it directly. Every kubectl rule applies to it.
    checked += 1
    ok_, decision, _ = _rewritten("kubecolor get secret acme -o yaml", d)
    if not ok_:
        failures.append(
            f"kubecolor: kubecolor get secret -o yaml was {decision}, not routed"
        )
    checked += 1
    decision, _ = decide("kubecolor get secret acme -o jsonpath='{.data.password}'", d)
    if decision != "deny":
        failures.append(
            f"kubecolor: a kubecolor template output on a Secret was {decision}"
        )
    checked += 1
    decision, _ = decide("kubecolor exec pod -- cat /var/run/.env", d)
    if decision != "ask":
        failures.append(
            f"kubecolor: a credential read behind kubecolor exec was {decision}"
        )
    checked += 1
    decision, updated = decide("kubecolor get pods -n acme", d)
    if decision != "allow" or updated:
        failures.append("kubecolor: a table-format kubecolor get was interfered with")

    # The backstop skips a value after a value-taking flag only when it is a variable. `-n` is a
    # plain flag for cat, so `cat -n .env` must still be probed if the rewrite ever misses it.
    checked += 1
    spec = importlib.util.spec_from_file_location("guard_mod", GUARD)
    guard_mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard_mod)
    if ".env" not in guard_mod.missed_reads("cat -n .env", d):
        failures.append("backstop: `cat -n .env` was skipped as a flag value")

    # Shapes whose whole purpose is one raw value: the viewer cannot redact a bare scalar.
    for cmd in (
        "kubectl get secret acme -o jsonpath='{.data.password}'",
        "kubectl get secret acme -o go-template='{{.data.password}}'",
        "kubectl get secret acme -o 'jsonpath={.data.password}'",
        "kubectl get SECRET acme -o jsonpath='{.data.password}'",
        "kubectl get secret acme -o \"json\"path='{.data.password}'",
        'kubectl get secret acme -o json | "base64" -d',
        "kubectl get secret acme --template='{{.data.password}}'",
        "kubectl get secret acme -o json | jq -r .data.password | base64 -d",
        "helm get values acme-api -o json | openssl enc -base64",
    ):
        checked += 1
        decision, _ = decide(cmd, d)
        if decision != "deny":
            failures.append(f"cluster/extract: {cmd!r} was {decision}, expected deny")

    # Commands that print nothing secret, or keep the output off the transcript.
    for cmd in (
        "kubectl get pods -n acme",
        "kubectl get pods -o jsonpath='{.items[*].metadata.name}'",
        "kubectl get secrets -n acme",
        "kubectl describe secret acme",
        "kubectl --kubeconfig=/tmp/kc get pods",
        "kubectl get secret acme -o yaml > /dev/null 2>&1",
        "argocd app list",
        "helm list -A",
        'git commit -m "route argocd app get -o json through the viewer"',
        "cat > notes.md <<'EOF'\nRun argocd app get APP -o json to see it.\nEOF",
    ):
        checked += 1
        decision, updated = decide(cmd, d)
        if decision in ("deny", "ask") or (updated and "redact-view" in updated):
            failures.append(f"cluster/false-positive: {cmd!r} was interfered with")

    # Recovering JSON from log noise must not reshape YAML: an indented JSON line (a
    # last-applied annotation) is part of the document, not a document behind noise.
    sec = (
        "apiVersion: v1\ndata:\n  DB_URL: RkFLRWRiVXJsUGFzcw==\nkind: Secret\nmetadata:\n"
        "  annotations:\n    last-applied: |\n"
        '      {"apiVersion":"v1","data":{"DB_URL":"RkFLRWRiVXJsUGFzcw=="},"kind":"Secret"}\n'
        "  name: acme\ntype: Opaque\n"
    )
    view = subprocess.run(
        [os.path.join(os.path.dirname(GUARD), "redact-view"), "--yaml", "-"],
        input=sec,
        text=True,
        capture_output=True,
    ).stdout
    checked += 1
    if (
        len(view.splitlines()) != len(sec.splitlines())
        or "RkFLRWRiVXJsUGFzcw==\n" in view
    ):
        failures.append(
            "engine/yaml-not-reshaped: noise recovery reshaped or leaked a YAML Secret"
        )

    # A JSON document the noise recovery declines -- indented lines around it, or nested inside
    # YAML -- is still parsed for its credentials, and every one is redacted in the output in
    # place. Declining used to fall through to a line grammar that cannot see inside a JSON
    # string, and the Helm values printed raw.
    pretty = json.dumps(json.loads(APP_JSON), indent=2)
    for name, text in (
        (
            "indented-noise-before",
            "level=warning msg=retry\n  caused by: timeout\n" + pretty + "\n",
        ),
        ("indented-noise-after", pretty + "\n  at grpc.go:42\n"),
        (
            "yaml-annotation-json",
            "apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  annotations:\n"
            "    last-applied: |\n      " + APP_JSON + "\n  name: acme\n",
        ),
    ):
        out = subprocess.run(
            [os.path.join(os.path.dirname(GUARD), "redact-view"), "--yaml", "-"],
            input=text,
            text=True,
            capture_output=True,
        ).stdout
        checked += 1
        if any(v in out for v in FAKE):
            failures.append(f"engine/fail-closed/{name}: printed a fake value")
        elif len(out.splitlines()) != len(text.splitlines()):
            failures.append(f"engine/fail-closed/{name}: reshaped the document")

    # Two shapes a line grammar cannot read: a whole document encoded as one JSON string
    # (`jq tostring` without -r), and a diff whose lines carry `<`/`>` markers. Argo CD masks a
    # Secret's data in `app diff`, but CVE-2026-45737 leaked it through the last-applied
    # annotation's JSON, which is exactly the line the diff marker hides from a line grammar.
    for name, text in (
        ("json-string", json.dumps(json.dumps(json.loads(APP_JSON)["spec"])) + "\n"),
        (
            "diff-annotation",
            "===== /Secret acme/db ======\n12c12\n"
            '<         {"apiVersion":"v1","kind":"Secret","data":{"pw":"RkFLRW9sZA=="}}\n'
            "---\n"
            f'>         {{"apiVersion":"v1","kind":"Secret","data":{{"pw":"{FAKE[0]}"}}}}\n',
        ),
    ):
        out = subprocess.run(
            [os.path.join(os.path.dirname(GUARD), "redact-view"), "--yaml", "-"],
            input=text,
            text=True,
            capture_output=True,
        ).stdout
        checked += 1
        if any(v in out for v in FAKE) or "RkFLRW9sZA==" in out:
            failures.append(f"engine/encoded/{name}: printed a fake value")

    # A diff shows only the changed lines, so a Deployment env `value:` arrives without the
    # sibling `name:` that marks it secret, behind a marker no YAML grammar reads. Argo CD masks
    # only a Secret's data. Every value on a diff line is redacted; keys and names stay.
    for name, text, keep in (
        (
            "normal-diff",
            "===== apps/Deployment acme/api ======\n40c40\n"
            f"<           value: {FAKE[2]}old\n---\n>           value: {FAKE[2]}\n"
            "===== argoproj.io/Application argocd/acme ======\n12a13\n"
            f">     clientSecret: {FAKE[0]}\n",
            "clientSecret:",
        ),
        (
            "unified-diff",
            "--- live\n+++ desired\n@@ -38,3 +38,4 @@\n         - name: DB_PASSWORD\n"
            f"-          value: {FAKE[2]}old\n+          value: {FAKE[2]}\n"
            f"+  webhookSecret: |\n+    {FAKE[1]}\n",
            "name: DB_PASSWORD",
        ),
        (
            # JSON and comment lines inside a diff fail closed too: a Deployment's last-applied
            # annotation holds env values no key name marks as secret, a wrapped JSON line does
            # not parse, and a comment can hold anything.
            "json-and-comment-lines",
            "===== apps/Deployment acme/api ======\n7c7\n"
            '<         {"kind":"Deployment","env":[{"name":"DSN","value":"FAKEdbPass98765old"}]}\n'
            "---\n"
            f'>         {{"kind":"Deployment","env":[{{"name":"DSN","value":"{FAKE[2]}"}}]}}\n'
            "9a10\n"
            f'>         {{"truncated": "{FAKE[1]}\n'
            f">   # rotated from {FAKE[0]}\n",
            '"kind"',
        ),
        (
            # Kept keys stay readable only while their value looks harmless; `key` is not kept.
            "kept-key-secret-value",
            "===== /ConfigMap acme/cfg ======\n3c3\n"
            f"<   name: postgres://svc:{FAKE[0]}@db/acme\n---\n"
            f">   key: {FAKE[1]}\n",
            "name:",
        ),
    ):
        out = subprocess.run(
            [os.path.join(os.path.dirname(GUARD), "redact-view"), "--yaml", "-"],
            input=text,
            text=True,
            capture_output=True,
        ).stdout
        checked += 1
        if any(v in out for v in FAKE):
            failures.append(f"engine/diff/{name}: printed a fake value")
        elif keep not in out or len(out.splitlines()) != len(text.splitlines()):
            failures.append(f"engine/diff/{name}: lost the diff's shape or its keys")

    # A diff with no hunk header (side-by-side, or a tool that omits it) is a diff when the
    # producer says so: the guard passes --diff, and every line is redacted, marker or not.
    side = (
        "===== apps/Deployment acme/api ======\n"
        f"          value: {FAKE[2]}old            |           value: {FAKE[2]}\n"
        f"clientSecret: {FAKE[0]}\n"
    )
    out = subprocess.run(
        [os.path.join(os.path.dirname(GUARD), "redact-view"), "--diff", "-"],
        input=side,
        text=True,
        capture_output=True,
    ).stdout
    checked += 1
    if any(v in out for v in FAKE):
        failures.append("engine/diff/hunkless-side-by-side: printed a fake value")
    # Header patterns are exact. A removed `-- x` or added `++ x` line reads as `--- x` /
    # `+++ x`, and an unmarked side-by-side line can start with `diff`, `index` or `===`;
    # each passed raw as a "header". Git's function context after `@@ ... @@` is content too.
    for name, text in (
        (
            "dash-plus-content",
            "--- a/x.sql\n+++ b/x.sql\n@@ -1,2 +1,2 @@ secret: " + FAKE[2] + "\n"
            f"--- {FAKE[0]}\n+++ {FAKE[1]}\n",
        ),
        (
            # A hunk that ends in a removed `-- x` and an added `++ y` line, right before the
            # next hunk, looks exactly like a file-header pair. Only the hunk's own line counts
            # can tell them apart.
            "pair-at-hunk-end",
            "--- a/m.sql\n+++ b/m.sql\n@@ -1,2 +1,2 @@\n select 1;\n"
            f"--- {FAKE[0]}\n+++ {FAKE[1]}\n@@ -9,1 +9,1 @@\n-x\n+y\n",
        ),
        (
            # Only the exact "no newline" marker passes inside a hunk, not any `\` line.
            "backslash-line",
            "--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n\\ " + FAKE[0] + "\n-a\n+b\n",
        ),
        (
            # A file-header pair after a hunk needs a `diff`/`index` line or a banner before it.
            "pair-after-hunk",
            "--- a/x\n+++ b/x\n@@ -1,1 +1,1 @@\n-a\n+b\n"
            f"--- {FAKE[0]}\n+++ {FAKE[1]}\n@@ -5 +5 @@\n-c\n+d\n",
        ),
        (
            # Argo CD's banner has a fixed shape: group/Kind, then namespace/name.
            "loose-banner",
            f"===== {FAKE[0]} x =====\n5c5\n< a\n---\n> b\n",
        ),
        (
            # With no hunk header anywhere, only Argo CD's banner is a header.
            "hunkless-git-words",
            f"===== /ConfigMap a/b ======\ndiff --git {FAKE[0]}\nindex abcd..ef01 {FAKE[1]}\n",
        ),
        (
            "header-words",
            f"===== /ConfigMap a/b ======\nindex {FAKE[0]}\n=== {FAKE[1]}\ndiff {FAKE[2]}\n",
        ),
    ):
        out = subprocess.run(
            [os.path.join(os.path.dirname(GUARD), "redact-view"), "--diff", "-"],
            input=text,
            text=True,
            capture_output=True,
        ).stdout
        checked += 1
        if any(v in out for v in FAKE):
            failures.append(f"engine/diff/headers/{name}: printed a fake value")
        elif FAKE[0] not in text.split("\n")[0] and not out.startswith(
            text.split("\n")[0]
        ):
            failures.append(f"engine/diff/headers/{name}: a real header was redacted")

    # Detection stays loose even though header passthrough is strict: a banner that is not in
    # Argo CD's exact shape must still put stdin into diff mode, or the markers hide every
    # value from the YAML grammar. Tightening the one regex for both jobs failed open.
    out = subprocess.run(
        [os.path.join(os.path.dirname(GUARD), "redact-view"), "-"],
        input=f"===== /Secret default/My_Secret ======\n>   data_value: {FAKE[0]}\n",
        text=True,
        capture_output=True,
    ).stdout
    checked += 1
    if FAKE[0] in out:
        failures.append("engine/diff/loose-detection: a hunkless diff was not detected")

    checked += 1
    _, _, upd = _rewritten("argocd app diff uat-acme-api", d)
    if not (upd and "--diff -" in upd):
        failures.append(
            "cluster/argocd-diff-flag: argocd app diff not routed with --diff"
        )

    # End to end: put stub producers on PATH, run what the guard substituted, and check the
    # output both lacks every fake value and stays usable by the filter downstream.
    bindir = os.path.join(d, "stubbin")
    os.makedirs(bindir, exist_ok=True)
    stubs = {
        "argocd": f"lambda a: {APP_YAML!r} if '-o yaml' in a else {APP_JSON!r}",
        "helm": f"lambda a: {HELM_VALUES!r}",
        "kubectl": f"lambda a: {SECRET_LIST!r}",
    }
    # argocd prints `WARN[...]` lines on stderr; merged with 2>&1 they sit before the JSON.
    # Real clusters print far more than a fixture: several MiB of clean YAML must still flow.
    stubs["argocd"] = (
        "lambda a: (sys.stderr.write('WARN[0000] grpc retry\\n') if 'warn-app' in a else 0) "
        f"and '' or ({APP_YAML!r} if '-o yaml' in a else {APP_JSON!r})"
    )
    stubs["kubectl"] = (
        "lambda a: 'apiVersion: v1\\nkind: List\\nitems:\\n' + ''.join("
        "f'- metadata:\\n    name: pod-{i}\\n' for i in range(150000)) "
        f"if ' -A' in a else {SECRET_LIST!r}"
    )
    for name, out in stubs.items():
        p = os.path.join(bindir, name)
        with open(p, "w") as fh:
            fh.write(STUB.replace("{OUT}", out))
        os.chmod(p, 0o755)
    env = dict(os.environ, PATH=bindir + os.pathsep + os.environ.get("PATH", ""))

    for name, cmd, must in (
        ("leak-shape", loop, "repoURL"),
        (
            "field-select",
            "argocd app get uat-acme-api -o json | jq -c "
            "'.spec.source | {repoURL, path, targetRevision, valueFiles: .helm.valueFiles}'",
            '"targetRevision":"main"',
        ),
        ("argocd-yaml", "argocd app get uat-acme-api -o yaml", "clientSecret"),
        ("helm-values", "helm get values acme-api", "clientSecret"),
        ("secret-list", "kubectl get secrets -o yaml", "DATABASE_URL"),
        (
            "stderr-prefix",
            "argocd app get warn-app -o json 2>&1 | head -c 4000",
            "repoURL",
        ),
        ("big-output", "kubectl get pods -A -o yaml | head -5", "pod-0"),
        # The insertion point is trimmed on the raw text. Trimmed on a quote-blanked view, it
        # walked inside the closing quote of `-o 'json'` and the pipe became part of the value.
        (
            "quoted-args",
            "'argocd' app get uat-acme-api -o 'json' | jq -c .spec.source.helm.parameters",
            "app.db.password",
        ),
        (
            "continuation",
            "argocd \\\n  app get uat-acme-api -o json | jq -c .spec.source.helm.parameters",
            "app.db.password",
        ),
    ):
        checked += 1
        ok, decision, updated = _rewritten(cmd, d)
        if not ok:
            failures.append(f"e2e/{name}: not rewritten ({decision})")
            continue
        run = subprocess.run(
            ["bash", "-c", updated], cwd=d, env=env, text=True, capture_output=True
        )
        shown = run.stdout + run.stderr
        leaked = [v for v in FAKE if v in shown] + (
            ["DATABASE_URL value"] if "RkFLRWRiVXJsUGFzcw" in shown else []
        )
        if leaked:
            failures.append(f"e2e/{name}: printed {len(leaked)} fake value(s)")
        elif must not in run.stdout:
            failures.append(f"e2e/{name}: output lost {must!r} -- rc={run.returncode}")
    return checked, failures


def main():
    failures = []
    checked = 0
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, ".env"), "w") as fh:
            fh.write(
                "NODE_ENV=development\n"
                "AUTH0_CLIENT_SECRET=FAKEfake0123456789abcdefFAKEfake\n"
            )

        # Baseline: a bare read must be protected, or nothing below means anything.
        for name, read in READS:
            cmd = read.format(d=d)
            checked += 1
            if not protected(f"cd {d} && {cmd}", d):
                failures.append(f"baseline/{name}: {cmd!r} ran raw")

        for pname, prefix in PREFIXES:
            for sname, sep in SEPARATORS:
                for rname, read in READS:
                    cmd = f"cd {d}{sep}{prefix}{sep}{read.format(d=d)}"
                    checked += 1
                    if not protected(cmd, d):
                        failures.append(
                            f"compound/{pname}/{sname}/{rname}: credential read "
                            f"reached the transcript unredacted"
                        )

        # A second mention of the credential path plus a filter ANYWHERE in the command.
        # The rewrite was judged on the whole command -- "a secret path and a filter are
        # both still present" -- so it was discarded, while the deny below it is per stage
        # and found no stage holding both. No decision, and the original command ran.
        for name, mention in (
            ("ls", "ls -la .env"),
            ("test-f", "test -f .env"),
            ("bracket-f", "[ -f .env ]"),
            ("ls-two", "ls .env .env.example"),
        ):
            cmd = f"{mention}; ps aux | grep node | head; cat .env"
            checked += 1
            decision, updated = decide(cmd, d)
            if not (updated and "redact-view" in updated):
                failures.append(
                    f"second-mention/{name}: {cmd!r} was not rewritten ({decision})"
                )

        # A filter aimed straight at the file is still a slice, and still denied.
        for cmd in (
            "grep TOKEN .env",
            "awk -F= '{print $2}' .env",
            "cat .env; grep KEY .env",
        ):
            checked += 1
            decision, _ = decide(cmd, d)
            if decision != "deny":
                failures.append(f"slice: {cmd!r} was {decision}, expected deny")

        # A session transcript stores a printed file as one JSON string per line. The
        # detector used to miss a credential there, so `cat` of it was not rewritten.
        with open(os.path.join(d, "session.jsonl"), "w") as fh:
            fh.write(
                json.dumps({"type": "user", "message": "show the env"})
                + "\n"
                + json.dumps(
                    {
                        "type": "tool_result",
                        "content": "NODE_ENV=development\n"
                        "AUTH0_CLIENT_SECRET=FAKEfake0123456789abcdefFAKEfake\n",
                    }
                )
                + "\n"
            )
        with open(os.path.join(d, "clean.jsonl"), "w") as fh:
            fh.write(
                json.dumps({"type": "user", "message": "list the files"})
                + "\n"
                + json.dumps({"type": "tool_result", "content": "a.txt\nb.txt\n"})
                + "\n"
            )
        checked += 1
        if not protected(f"cd {d} && cat session.jsonl", d):
            failures.append("jsonl: a transcript holding a credential ran raw")

        # A command that reads nothing secret must still pass through untouched,
        # or the guard is just noise people switch off.
        for cmd in (
            f"cd {d} && head -20 /etc/passwd",
            "ps aux | grep node | head -n 20",
            f"ls -la {d}",
            # A heredoc BODY is a document being written, not a read being run.
            "cat > notes.md <<'EOF'\nRun `cat .env` to see the keys.\nEOF",
            'something ".env" | grep x',
            'echo "cat .env" >> notes.txt',
            "cat clean.jsonl",
        ):
            checked += 1
            decision, updated = decide(cmd, d)
            if decision in ("deny", "ask") or (updated and "redact-view" in updated):
                failures.append(f"false-positive: {cmd!r} was interfered with")

        c, f = cluster_cases(d)
        checked += c
        failures += f

    print(f"{checked} cases checked, {len(failures)} failed")
    for f in failures:
        print(f"  FAIL  {f}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
