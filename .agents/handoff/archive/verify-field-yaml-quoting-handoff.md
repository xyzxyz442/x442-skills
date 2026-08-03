---
id: verify-field-yaml-quoting-handoff
title: verify — frontmatter commands need quoting, not colon folding
type: coordination
status: done
audience: 
repos: []
severity: low
created: 2026-08-03
updated: 2026-08-03
note: found while closing frontmatter-colon-fields-handoff; a real verify — command always contains colons
verified_at: 2026-08-03
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

Last of the colon-in-frontmatter class ([[title-colon-frontmatter-handoff]] fixed titles,
[[frontmatter-colon-fields-handoff]] fixed `note`/`audience`/`severity`/`blocked_on`). The
optional `verify:` field is different in kind and was deliberately left alone: **folding its
colons would corrupt the command**, so it is the one field that has to be quoted rather than
folded — and quoting is what the earlier fixes rejected, because `meta()` reads frontmatter
with plain sed and would hand every reader a value with literal quotes still on it.

The CLI never writes `verify:` — a human or agent adds it by hand — so nothing in the tool
emits the bad line today. But the field is documented, and any realistic command contains a
colon, so docs that use it as documented are unparseable. Live example found on the shared
board (`../ais/src/.agents/handoff`), archived:

```text
esbm/archive/graph-hooks-sqlite-probe-handoff.md
verify: sqlite3 'file:.code-review-graph/graph.db?mode=ro' 'select count(*) from embeddings;'
```

Strict parse of that doc's frontmatter fails: "mapping values are not allowed in this context".

Fix (this session): **both** halves — quoting is now viable in code, and the docs tell authors
to use it. The scope check the Decisions section asked for came out "code too", because
documentation alone would have been wrong advice: quoting a command made it unrunnable.

Reproduced before fixing, on a scratch board with the opt-in enabled:

```text
verify: "sh -c 'echo ran: yes > VERIFY_RAN'"     # valid YAML, parses clean
handoff release vq --status done --run-verify
  -> line 960: sh -c 'echo ran: yes > VERIFY_RAN': command not found
```

The quotes reached `eval` intact, so "valid YAML" and "runnable command" were mutually
exclusive. After the fix the same doc parses **and** closes with `[verify: exit 0]`.

## Where

- `skills/engineering/setup-handoff/scripts/payload/handoff` — `meta()` now strips one
  surrounding quote pair (`sed -e 's/^"\(.*\)"$/\1/;t' -e "s/^'\(.*\)'\$/\1/"`). The `t`
  branch makes the two strips exclusive, so `"'x'"` loses one pair, not both. Unquoted values
  pass through untouched, so every doc written before this keeps working.
- `skills/engineering/setup-handoff/scripts/payload/hooks.sh` — the second, independent copy of
  `meta()`; a quoted value has to read identically in the hooks or `list`/INDEX and the gate
  disagree with the CLI.
- Installed copies synced: `.agents/handoff/` and the three harness fixture boards (both files).
- `skills/engineering/setup-handoff/scripts/payload/README.md` — the `verify` row in Fields plus
  a "Quote the command" block under "`verify:` is safe by default";
  `skills/engineering/run-handoff/SKILL.md` — same rule in its verify section.
- `harness/setup-handoff-workspace/grade.py` — the existing safe-by-default test now injects a
  QUOTED, colon-bearing command, and two expectations were added for the opt-in run path, which
  had **no coverage at all** before.

## Verify

A doc carrying a colon-bearing verify command parses strictly, and `release --status done`
still finds and prints the command unchanged:

```text
# add:  verify: sqlite3 'file:x?mode=ro' 'select 1;'   to a scratch doc, then
ruby -ryaml -rdate -e 'YAML.safe_load(File.read(ARGV[0]).split(/^---$/)[1], permitted_classes: [Date])' <doc>
.agents/handoff/handoff release <id> --status done --verified-by "..."   # must echo the command intact
```

Plus `python3 grade.py fixtures/claude-wired script-behavior` staying green — its last
expectation sweeps every doc the suite writes for a bare colon in a value.

## Decisions

- **Quote, do not fold.** Unlike every other field, the value is a command; folding `:` to `—`
  breaks it. This is the one case where the em-dash convention does not apply.
- Quoting only works if `meta()` strips the quotes on read — done in both copies together, so
  no reader (list, INDEX, hooks, `cmd_release`'s `eval`) sees a value with quotes baked in.
- ~~Scope check: maybe documentation rather than code~~ — resolved: **both were required**.
  Telling authors to quote without the reader change would have handed them a doc that parses
  and a `--run-verify` that fails, which is worse than the status quo.
- The strip is deliberately naive (one surrounding pair, no YAML escape handling). It is a sed
  reader, not a parser; anything needing real YAML semantics should not be in frontmatter.
- Existing unquoted `verify:` lines are left alone rather than migrated — they still execute,
  and rewriting a command inside a doc is riskier than the parse failure it fixes. The live
  example that prompted this handoff is in the shared board's `archive/`, i.e. history.

## Found while fixing

- `repos: []` — the doc template's default — makes `doc_is_local()` return false, so
  `--run-verify` is unreachable for every doc `handoff new` creates. Split out to
  [[verify-run-repos-empty-list-handoff]]; the new opt-in expectation carries a workaround
  comment pointing at it.

## Suggested skills

- x442-run-handoff (board discipline), x442-setup-handoff (payload/installer layout).

## Activity

- 2026-08-03 — open — released by Gunn Bhatrakarn (7e8142fa).
- 2026-08-03 — done — verified against live code by Gunn Bhatrakarn (7e8142fa): reproduced pre-fix (quoted verify hit 'command not found' at handoff:960 via eval) then verified post-fix: same doc parses strictly (ruby YAML) AND closes with [verify: exit 0], unquoted commands still run; harness script-behavior 54/54 with 2 new opt-in-run expectations, proven non-vacuous by running the suite against a board carrying the pre-fix meta() (6 expectations fail there); layout-migration 10/10, 5 other setup-handoff evals 19/19, run-handoff 12/12, verify-setup-handoff.sh 18/0/0; hooks.sh sessionstart smoke-tested live on this board; all 8 installed copies byte-identical to the payload.
