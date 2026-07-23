---
id: frontmatter-colon-fields-handoff
title: note and blocked_on frontmatter values can still carry colons
type: coordination
status: open
audience:
repos: []
severity: low
created: 2026-07-23
updated: 2026-07-23
note:
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

## Context

Same defect class as [[title-colon-frontmatter-handoff]] (fixed): the `handoff` CLI writes
frontmatter values as unquoted YAML, so a `:` inside the value breaks external parsers.
Titles are now folded, but two fields still admit colons:

- `note:` — free text from `--note`, written verbatim into frontmatter by `new`/`import`
  (a note like "see: foo" produces invalid YAML).
- `blocked_on:` — the documented `external: vendor ticket` convention produces
  `blocked_on: external: vendor ticket`, invalid YAML by design. A harness expectation
  ("an external: blocker is still accepted unvalidated") pins this format, and the unblock
  logic parses it, so changing it is a design decision, not a mechanical fold.

## Where

- `skills/engineering/setup-handoff/scripts/payload/handoff` — `note:` writes in `cmd_new`
  (all three type branches) and `cmd_import`; `blocked_on` writes in `cmd_release`.
- `harness/setup-handoff-workspace/grade.py` — the `external:` expectations in
  `grade_script_behavior`.
- Docs pinning the `external: …` spelling: `skills/engineering/run-handoff/SKILL.md`,
  `skills/engineering/setup-handoff/scripts/payload/README.md`, AGENTS.md routing block.

## Verify

`.agents/handoff/handoff new t --note "a: b"` produces YAML that a strict parser accepts
(e.g. `python3 -c "import yaml,sys; yaml.safe_load(...)"` on the frontmatter block), and the
same for a doc released `--status blocked --blocked-on "external: x"`.

## Decisions

- Do not silently fold `blocked_on` — `external: …` is a validated, documented format with a
  harness guard and cross-doc references; pick a replacement spelling (e.g. `external — …` or
  quoting) deliberately and migrate the docs/readers together.

## Suggested skills

- x442-run-handoff, x442-setup-handoff.
