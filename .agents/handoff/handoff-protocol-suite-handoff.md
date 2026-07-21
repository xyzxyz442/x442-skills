---
id: handoff-protocol-suite-handoff
title: Handoff protocol: outstanding work bundle
type: orchestrator
status: open
children: [blocked-on-validation-handoff, index-orchestrator-section-handoff, children-last-child-drop-handoff, retire-paths-skip-unblock-handoff, template-render-sed-injection-handoff, release-announcement-harness-handoff, x442-engineering-skills-handoff]
created: 2026-07-21
updated: 2026-07-21
note: Tracks the open handoffs against the handoff protocol itself. Progress is derived from the children.
---

<!-- NEVER COMMIT SECRETS. This doc is committed to the repo and its git history.
     Remove or redact any keys, API tokens, secrets, confidential data, passwords, or
     personally identifiable information (PII) before saving. If the next agent genuinely
     needs a credential, do NOT paste it — leave a named placeholder, prompt the user, and
     suggest a safe channel (an environment variable, a secret-manager reference, or
     out-of-band). Record the variable/reference NAME here, never the value. -->

<!-- ORCHESTRATOR handoff: an index over a BUNDLE of related handoffs. It holds no work of
     its own — the children do — so it needs no lease and is gate-exempt. Do NOT write child
     status here: `handoff list` derives progress from each child's own frontmatter every time
     it runs, and a hand-written count is exactly the rot this doc type exists to prevent.
     `release --status done` refuses while any child is still outstanding. -->

## Bundle

The open work against the handoff protocol itself — the `setup-handoff` / `run-handoff` skills and
the board they install. Grouped because they share one payload
(`skills/engineering/setup-handoff/scripts/payload/`) and one pair of eval harnesses, so they land
and regress together.

Progress is derived from each child's own frontmatter every time `handoff list` runs. Do not record
child status in this doc; `release --status done` refuses while any child is outstanding.

- `blocked-on-validation-handoff` — bug, **landed**. `--blocked-on` accepted dangling, self, and
  standalone blockers, all of which deadlocked silently. Now validated at release, and all three
  closing paths announce their dependents.
- `index-orchestrator-section-handoff` — bug, **landed**. `cmd_index` skipped standalone docs but
  not orchestrators, so a bundle appeared in INDEX.md's **Open** table as an unclaimed task. `list`
  was right and the generated index was wrong — the index is what AGENTS.md points at.
- `children-last-child-drop-handoff` — bug, **landed**. `children_of` piped to `while read` and lost
  the final child, so a bundle could be closed complete with an invisible open child.
- `retire-paths-skip-unblock-handoff` — bug, **landed**. The standalone and bundle-complete closing
  paths never announced their dependents.
- `template-render-sed-injection-handoff` — bug, **landed**. A `|` in `--title`/`--note` broke the
  `sed` render and produced a zero-byte doc while reporting success.
- `release-announcement-harness-handoff` — the `release-announcement` skill has no eval workspace,
  unlike every other skill in the repo.
- `x442-engineering-skills-handoff` — the running changelog for the engineering suite. Standalone,
  so it is a reference child rather than a work item; it closes when the suite stabilizes.

## Sequencing

All five bugs are landed and independent of each other: `blocked-on-validation` and
`retire-paths-skip-unblock` touched `cmd_release`, `index-orchestrator-section` touched `cmd_index`,
`children-last-child-drop` touched `children_of`, and `template-render-sed-injection` touched
`cmd_new`. None overlapped the remaining children.

`release-announcement-harness` is independent of everything else here and can run at any time; it
adds a harness workspace rather than changing the payload.

`x442-engineering-skills` is a log, not a task. It should be appended to as the other children land,
and closed last.

Four of the five landed bugs share one root cause: a new path was added and an existing rule was
not applied to it. `cmd_release`'s standalone and bundle branches skipped `surface_unblocked`;
`cmd_index` skipped the orchestrator exemption `cmd_list` already had. When adding a doc type or a
closing path, check **every** site that switches on `type:` and every site that closes a doc.

The fifth, `template-render-sed-injection`, is a different lesson: never interpolate user text into
a `sed` expression. It stayed hidden because the failure mode was a truncated file plus a success
message — it only surfaced when a `--note` happened to contain a `|`.

No child is `blocked_on` another — the ordering above is preference, not a hard dependency. If that
changes, record it on the child with `release --status blocked --blocked-on <id>` rather than here,
so the board can surface it.

## Suggested skills

- `x442-run-handoff` — claim a child before working it. The orchestrator itself is never claimed.
- `x442-setup-handoff` — for any change to the payload, re-run the installer to propagate to the
  live board and the harness fixtures.

## Notes

Known outstanding beyond this bundle: the `wmboacs` shared cross-repo board has neither the
`scripts/` + `templates/` layout nor slugified ids. Re-running `setup-handoff` in each sibling repo
migrates it. Not filed as a child because it is an operational task in another repo, not work on
this payload.
