---
id: PLACEHOLDER_ID
title: PLACEHOLDER_TITLE
type: orchestrator
status: open
children: [PLACEHOLDER_CHILDREN]
created: PLACEHOLDER_CREATED
updated: PLACEHOLDER_UPDATED
note: PLACEHOLDER_NOTE
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

<!-- What ties these handoffs together? The shared goal, the shared subsystem, or the
     shared release they must all land in. One paragraph — the children carry the detail. -->

## Sequencing

<!-- Order and dependencies BETWEEN children: what must land first, what can run in
     parallel, what is optional. Use `blocked_on` on the children themselves for hard
     blockers; this section is for the reasoning a dependency edge cannot express. -->

## Suggested skills

<!-- Skills the next agent should invoke to pick up this bundle. -->

## Notes

<!-- Open questions, caveats, and anything that would change the shape of the bundle. -->
