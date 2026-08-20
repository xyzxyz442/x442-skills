---
id: verify-run-repos-empty-list-handoff
title: repos — [] blocks --run-verify for every doc new creates
type: coordination
status: done
audience:
repos: []
severity: low
created: 2026-08-03
updated: 2026-08-04
note: found while testing the verify quoting fix
verified_at: 2026-08-04
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

`--run-verify` is unreachable for any doc the CLI creates. `doc_is_local()` is documented as
"a doc belongs to this repo when `repos:` is unset or names REPO_NAME", but the doc template
writes `repos: []`, and the empty flow list is not the same as unset: `meta()` returns the
two-character string `[]`, which is non-empty and does not contain REPO_NAME, so the function
returns 1 and `cmd_release` refuses to run the command.

Found while adding harness coverage for [[verify-field-yaml-quoting-handoff]] — the new
expectation had to hand-write `repos: [<repo>]` into the fixture doc to reach the run path at
all, which is what exposed this.

Reproduced on a scratch board (fixture copy, `HANDOFF_ALLOW_VERIFY_CMD=1` in `config`):

```text
handoff new vq                       # template writes `repos: []`
# add a verify: command, claim, then:
handoff release vq --status done --verified-by z --run-verify
  -> "NOTE: this handoff carries a verify: command but it was NOT run"
# identical doc with `repos: [claude-wired]` instead:
  -> "Running verify: ..."           # executes
```

Nothing else reads `repos:`, so the blast radius is exactly this one gate.

Fix (this session): `doc_is_local()` now reads the _effective_ list rather than the raw line.
Probing the whole boundary first turned up **two more defects in the same function**, both in
the opposite direction — the gate failing OPEN — and both contradicting this doc's own
"`repos: [other-repo]` must keep returning false" invariant:

| `repos:` shape               | before          | after   |
| ---------------------------- | --------------- | ------- |
| `[]` (template default)      | foreign ❌      | local   |
| empty list with a space      | foreign ❌      | local   |
| absent                       | local           | local   |
| `[claude-wired]`             | local           | local   |
| `[other, claude-wired]`      | local           | local   |
| `[other-repo]`               | foreign         | foreign |
| block list naming this repo  | local (by luck) | local   |
| block list, other repos only | **local** ❌    | foreign |
| `[claude-wired-extra]`       | **local** ❌    | foreign |

The block-list hole: `meta()` only ever reads the key's own line, so `repos:` followed by
`  - other-repo` returned the empty string — indistinguishable from "unset", i.e. local, i.e.
auto-executable. The substring hole: `case "$repos" in *"$REPO_NAME"*` matched `api` inside
`api-gateway`.

## Where

- `skills/engineering/setup-handoff/scripts/payload/handoff` — new `repos_of()` (awk; reads the
  inline flow list AND block-list items, stops at the closing `---`), and `doc_is_local()`
  rewritten on top of it: empty ⇒ local, and a whole-name `case` match instead of substring.
- Same file, `cmd_release`'s `done` branch — the `run_verify` condition, the only caller.
- `harness/setup-handoff-workspace/grade.py` — the opt-in expectation's `repos:` workaround is
  gone (the doc is now exactly what `new` writes, with an added assertion that it really does
  carry `repos: []`), plus two expectations that a doc scoped to other repos is refused, in
  both flow and block spelling.
- `skills/engineering/setup-handoff/scripts/payload/README.md` — the `repos` field row and the
  "safe by default" section now state the real semantics.

## Verify

A doc created plainly by `handoff new`, with a `verify:` command and the install opt-in, runs
that command on `release --status done --run-verify` — no hand-edited `repos:` line:

```text
cd harness/setup-handoff-workspace && python3 grade.py fixtures/claude-wired script-behavior
```

Expect 57/57. The relevant rows: "test setup: the doc carries the template's default empty repos
list" (guards against the workaround creeping back), "a QUOTED verify: command runs verbatim
under the opt-in", and "verify: is REFUSED for a doc scoped to another repo" in both the flow-
and block-list spellings.

## Decisions

- Treat `[]` as unset, not as a foreign repo list — that is what the function's own comment
  already claims it does. Check the parsed list is empty rather than string-comparing.
- Do not widen the gate any further: it is a security boundary (a cross-repo doc is untrusted),
  so `repos: [other-repo]` must keep returning false. **Both extra fixes narrow it**, never
  widen: a block list naming other repos, and a name that is only a substring of this repo's,
  now both read as foreign.
- Read `repos:` with awk rather than teaching `meta()` about block lists. `meta()` is a
  single-line sed reader used by every other field and by hooks.sh; making it multi-line to
  serve one field would put that risk on all of them.
- The whole-name match is a real behavior change for anyone whose REPO_NAME is a substring of a
  listed repo: `--run-verify` now prints instead of executing. That is the safe direction, and
  the previous behavior was a false positive on a security gate.

## Suggested skills

- x442-run-handoff (board discipline), x442-setup-handoff (payload/installer layout).

## Activity

- 2026-08-03 — open — released by Gunn Bhatrakarn (7e8142fa).
- 2026-08-04 — done — verified against live code by Gunn Bhatrakarn (7e8142fa): reproduced pre-fix (doc from plain 'handoff new' with repos: [] refused --run-verify) then verified post-fix across an 8-case boundary probe: []/[ ]/absent/[this]/[other,this]/block-list-with-this all local, [other-repo]/block-list-other/[this-extra] all foreign; harness script-behavior 57/57 with the repos workaround REMOVED and 3 new expectations, proven non-vacuous by reverting only doc_is_local on a scratch board (exactly those 3 fail); layout-migration 10/10, 5 other setup-handoff evals 19/19, run-handoff 12/12, verify-setup-handoff.sh 18/0/0; live board list + sessionstart hook smoke-tested; all 12 payload copies in sync.
