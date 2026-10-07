---
status: accepted
date: 2026-10-07
---

# A cluster-API read is routed by command, not path

Through payload v12, the secret guard decided everything from file paths. A command that pulls
credentials from a cluster API names no file, so no rule matched it. The guard neither rewrote,
asked about, nor denied it. This record explains three things: why those commands are now matched
by their own shape, why the redactor goes straight after the producer rather than at the end of
the pipeline, and why the viewer now fails closed on output it cannot parse.

## Context

An agent preparing an Argo CD sync ran:

```text
argocd app get APP -o json | jq -r '.spec.source // .spec.sources | tostring' | head -c 900
```

The Application kept its credentials as inline `spec.source.helm.values`. Its client secret and
webhook secret reached the transcript raw. `secret-file-guard.py` rewrites `cat`/`head` of
credential-bearing paths, asks about reads behind `kubectl exec`/`ssh`, and denies `base64` and
similar on credential files. Nothing in that command is a path.

The engine was mostly ready. `redact-view -` already redacted the JSON form. It was not ready for
the other shapes that cluster reads print:

- **Unnamed YAML.** Stdin was read as YAML only with a manifest's `apiVersion:`/`kind:` signature
  at column 0. `helm get values` and `argocd app get -o yaml` have none, so they were read as
  dotenv and printed raw.
- **A Secret inside a List.** `kubectl get secrets -o yaml` returns `kind: List`, which indents
  each `kind: Secret` inside an item. The column-0 anchor missed it, and a `data` key such as
  `DATABASE_URL` is not credential-named.
- **Diffs.** `argocd app diff` masks a Secret's `data` as `+++++++`, but nothing else. A changed
  Deployment env `value:` or inline Helm value appears without the sibling `name:` that would mark
  it secret, behind a `<`/`>`/`+`/`-` marker that no YAML grammar reads.
  [CVE-2026-45737](https://osv.dev/vulnerability/CVE-2026-45737) shows that even Secret data
  leaked, through the `last-applied-configuration` annotation's JSON.

## Decision

### Routing

- **Producers are data.** A list in `secret-file-guard.py` has one line per command: `argocd app
get`, `argocd app manifests`, `argocd app diff`, `helm get values|manifest|all|hooks`,
  `helm template`, `kubectl get` and `kubectl config view`. `kubectl get` counts only with
  `-o yaml|json` or `--raw`, because its table output carries no values. `kubectl config view
--raw` prints the kubeconfig's tokens and keys.
- **Insert the redactor straight after the producer:** `PRODUCER | redact-view --yaml - | jq …`.
  A downstream `jq` or `head` then works on redacted text with its structure intact, so a
  field-selecting read still works. Clean output passes byte-identical.
- **The guard names the format.** It passes `--yaml` for every producer except
  `argocd app diff`, which gets `--diff`. The unnamed-stdin sniff stays narrow, because
  `text_contains_secrets` shares it on the write path. Loosening it there would change what a
  handoff release refuses.
- **Every later decision keeps the routing.** An `ask` emitted after routing carries the routed
  command as `updatedInput`, so approving never runs the producer unrouted. The helm/Harness
  values-file ask stays whole-command: `ls values.yaml | xargs grep` reads the file in a step that
  never names it. Only a values path inside a step the guard actually routed is discounted.

### Matching reads the words the shell passes

Each heuristic that classifies a command by its spelling had a spelling the shell reads
differently. Matching therefore reads the command the way the shell does:

- Quote delimiters, escapes and line continuations are removed and mapped back to the original
  offsets. `kube"ctl"`, `-o ya'ml'`, `kube\ctl` and a continued `g\` + newline + `et` are the
  words `kubectl`, `yaml` and `get`. bash's ANSI-C quoting is decoded the way bash decodes it, so
  `$'\x79aml'` is `yaml`. Binary names match in any case, because macOS resolves `Kubectl` to
  `kubectl`.
- A quoted span with no whitespace is a bare word (`'kubectl'`). A quoted span containing
  whitespace is data: a message, a fixture or a note. Shell comments are not code.
- `$( )` inside double quotes is code. So is a quoted script handed to a runner (`sh -c`, `eval`,
  a remote launcher), and so is a heredoc fed to a shell or an expanding heredoc's `$( )`. A
  producer in one of those cannot be routed, so the guard asks.
- The insertion point is trimmed on the raw text. Trimming on a quote-blanked copy walks back
  inside a closing quote and turns the pipe into an argument.

### Verdicts where no rewrite helps

- **Deny** a template output on a Secret (`-o jsonpath=`, `go-template`, `--template`, in any case
  and any spelling), which prints one bare scalar. Also deny an extraction verb downstream of a
  producer (`| base64 -d`, `| openssl`, `| curl`).
- **Ask** about output redirected anywhere but `/dev/null` (a file, stderr, `>&1`, `/dev/fd/1`).
  That covers a redirect anywhere in the step (`> out kubectl get …`) and an earlier `exec >`.
  Also ask about a producer inside a quoted or heredoc script, and about
  `argocd app get --show-params`, which prints a table.

### The viewer on stdin

- `--yaml` reads non-JSON stdin as YAML. The stdin header goes to stderr, so the output stays valid
  JSON or YAML for a filter downstream.
- A `data`/`stringData` key whose own mapping declares `kind: Secret` is strict at any depth.
- A document encoded as one JSON string (`jq tostring` without `-r`) is decoded, redacted and
  encoded back.
- A JSON document among flat log lines (`WARN[…]` merged in by `2>&1`) is redacted where it
  starts, but only when it begins at column 0 and every other line is flat. An indented `{` line,
  such as a YAML annotation, is part of the document, and splitting there would reshape it.
- **Embedded JSON fails closed.** Every JSON document on stdin is parsed, wherever it sits: behind
  indentation, inside YAML, or behind a diff marker. Each credential `redact_json` would hide is
  replaced in place in the output. Lines and structure are untouched. Values shorter than six
  characters are skipped, so ordinary substrings are not replaced across the output. This is the
  one fix that does not depend on classifying the input correctly.
- **Diffs fail closed.** With `--diff`, or on stdin carrying a hunk header or a `=====` banner,
  every value on every content line is fingerprinted. That includes JSON lines, comments, unmarked
  side-by-side lines and lines that do not parse. The values of `name`, `kind` and `apiVersion`
  stay readable while they do not look like credentials. Old and new fingerprints still differ, so
  the diff still shows what changed, just not to what.
- **A diff header is decided by structure.** Inside a unified hunk, the `@@ -a,b +c,d @@` counts
  say how many lines follow, and every one is content, whatever it looks like. Between hunks, only
  exact headers pass:
  - Argo CD's `===== group/Kind namespace/name ======` banner;
  - normal-diff hunk lines and their `---` separator;
  - `diff --git` and `diff -…` command lines;
  - a real `index <sha>..<sha>` line;
  - a `---`/`+++` pair directly before a hunk header, at the start of the text or after one of
    the lines above.

  Detection is a separate, deliberately loose pattern. Mistaking text for a diff only
  over-redacts, while a missed diff hides every value behind its markers.

- Stdin is capped at 256 MiB, not the 2 MiB file-probe limit, and above the cap the viewer refuses
  rather than truncating. A truncated JSON document stops parsing and falls through to a line
  grammar that cannot see its values.

## How the decision was tested

The first cut was routed by spelling and redacted by key name. Nine rounds of commit security
review each found a bypass, and each was reproduced before it was fixed, so every one is now a
regression case. Two lessons shaped the final design:

- **Appearance is not structure.** Each heuristic that judged a line or a word by how it looks had
  a counterexample:
  - a quoted output format, and a binary joined from quoted pieces;
  - a comment naming a producer;
  - a removed `-- x` line that reads `--- x`;
  - a pair of content lines shaped like a file header.

  The fixes moved from patterns to structure: the shell's own words, a hunk's line counts, and
  parsing every JSON document instead of guessing which ones matter.

- **One pattern, one job.** A banner regex served both header passthrough and diff detection.
  Tightening it for the first job silently narrowed the second, which then failed open.

## Scope and relation to ADR 0009

ADR 0009 keeps the read backstop out of quoted regions, because quoted text there is data. This
record makes one deliberate exception, and only for cluster-API producers. Command substitution
inside double quotes and a quoted script handed to a runner are code to the shell, so they are
treated as code. The read-verb rule itself is unchanged, and the matching gap for plain reads
(`bash -c 'cat FILE'`) is tracked separately.

The spec asked whether other CLIs should be included. The producers are the three tools in use:
argocd, helm and kubectl. Credential-echoing commands of `gh` and the cloud CLIs were assessed and
left out rather than widened speculatively. `kubectl describe secret` prints byte counts, not
values, and `helm status --show-resources` prints a resource table, so both stay unrouted.

## Sources

The producer list and the format rules encode vendor CLI behaviour. Recheck them against the
upstream references when a tool changes:

- kubectl get, its output formats (`-o yaml|json|jsonpath|go-template|custom-columns`,
  `--template`) and `--raw`: <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_get/>.
- Template output formats and JSONPath: <https://kubernetes.io/docs/reference/kubectl/jsonpath/>.
- helm get values, manifest, all and hooks: <https://helm.sh/docs/helm/helm_get/>.
- helm template: <https://helm.sh/docs/helm/helm_template/>.
- argocd app get, including `--show-params` and `-o json|yaml`:
  <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_get/>.
- argocd app manifests:
  <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_manifests/>.
- argocd app diff: <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_diff/>.
- The diff's Secret masking gap: [CVE-2026-45737](https://osv.dev/vulnerability/CVE-2026-45737).

## Considered options

- **Put the redactor last and refuse every filter after a producer.** Rejected. The redactor
  would then see `jq`'s output, so the filter would run on raw values, which is the slicing that
  the file rule denies. Refusing every `| jq` after a producer blocks the field-selecting reads the
  operator actually needs, and a guard that blocks honest work gets switched off.
- **Rely on agent discipline or a memory note.** Rejected. That is how the leak happened. A
  transcript cannot be unwritten, so prevention is the only lever.
- **Widen the unnamed-stdin YAML sniff.** Rejected for the reason above: the sniff is shared with
  the write-path scanner. A producer always knows its own format, so the caller states it.
- **Rewrite inside quoted scripts.** Rejected. Behind `ssh` the host's viewer does not exist. That
  is the same boundary that makes embedded-shell reads ask rather than rewrite.
- **Redact a diff by key name, as for YAML.** Rejected. A hunk shows a changed value without the
  context that marks it secret, so a diff is fingerprinted fail-closed instead.

## Consequences

- A producer pipeline's exit status is now the viewer's, unless the shell runs with `pipefail`.
- A binary reached through a variable, alias or wrapper script (`k=kubectl; $k get secret …`) is
  not matched. This is the cooperative-guard limit SKILL.md already states: the guard routes
  honest commands and does not sandbox a determined one.
- A diff routed through the viewer shows which keys changed, not their new values.
- `test-secret-file-guard.py` runs the substituted commands against stub producers. Asserting that
  a rewrite happened proves intent. Running it proves that the value is gone and that `jq` still
  parses the output, and it caught a trap that the intent check passed.
