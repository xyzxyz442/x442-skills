---
id: template-render-sed-injection-handoff
title: A pipe in --title/--note produced a zero-byte handoff doc
type: coordination
status: done
audience:
repos: []
severity: high
created: 2026-07-21
updated: 2026-07-21
note: Templates were rendered with sed s-expressions interpolating user text; the redirect had already truncated the file.
verified_at: 2026-07-21
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

`handoff new` rendered its templates by interpolating user text into `sed` substitutions:

```text
sed -e "s|PLACEHOLDER_NOTE|$note|g" ... "$tmpl" > "$DIR/$id.md"
```

`--title` and `--note` are arbitrary user text. A `|` in either closes the `s|||` expression early;
`sed` then treats the remainder as a filename, prints `No such file or directory`, and exits
non-zero. The output redirect has **already truncated the destination**, so the result is a
**zero-byte handoff doc** — and `handoff new` still printed its success message. `claim` then
succeeded on the empty file, because an absent `status` is not `done`.

Found by filing a handoff whose `--note` contained the word "pipeline" written as `tr|while read`.
`&` is the same class of trap: `sed` expands it in a replacement to the whole match.

Silent data loss on the primary creation path, so: high.

## Where

- [payload/handoff](../../skills/engineering/setup-handoff/scripts/payload/handoff) — all three
  branches of `cmd_new` (coordination, standalone, orchestrator) shared the pattern.

## Verify

```text
handoff new x --title "Fix A & B" --note "a|b"   -> non-empty doc, both values verbatim
handoff new y --standalone --title "Ref | doc"   -> same
handoff new z --orchestrator --children x --title "Bundle | x"  -> same
```

Covered by `script-behavior` in `harness/setup-handoff-workspace`.

## Decisions

- **Render with bash `${var//pat/rep}`, not `sed`.** It substitutes literally, cannot be broken by
  any character in the value, and needs no external process — which also keeps the CLI free of the
  python3 dependency that only the enforcement gate requires.
- **Do not merely change the `sed` delimiter.** Any delimiter can appear in user text; that trades a
  common break for a rarer one.

## Outcome

Fixed 2026-07-21. All three branches use `render_tmpl`. Three new expectations cover `|` and `&`
across all three template types.

## Suggested skills

- `x442-setup-handoff` — re-run the installer to propagate the payload.

## Activity

- 2026-07-21 — done — verified against live code by Gunn Bhatrakarn (c0ebf4f2): new --title 'Fix A & B' --note 'a|b' yields a 1591-byte doc with both values verbatim; standalone 'Ref | doc' and orchestrator 'Bundle | x' likewise; 3 new script-behavior expectations.
