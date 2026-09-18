---
status: accepted
date: 2026-09-18
---

# A bundle projects as native sub-issues, and the adapter owns the identifier gap

ADR 0011 lets a board mirror open work into an issue tracker, projecting a bundle as one issue
carrying a Markdown checklist of its children. Where the tracker supports a native parent/child
relationship, we decided the mirror **also** links the bundle's issue to its children's issues, so
teammates get real structure and a progress bar without opening the board. The adapter contract
stays addressed by issue **number**, and each adapter resolves whatever identifier its own API
needs. This extends ADR 0011 and is bound by ADR 0013.

## Context

- A bundle is an **orchestrator** whose `children:` roster is the board's only parent/child
  relationship. The mirror already renders it as a checklist, which is inert text: it carries no
  progress, and closing a child's issue updates nothing.
- The upstream API identifies the two ends of the relationship in **different identifier spaces**.
  The parent is addressed by `issue_number` in the path; the child is named by `sub_issue_id` in
  the body, documented as "The id of the sub-issue to add" — the internal database id, not the
  number. Verified against a live public issue: number `1` carries database id `502407912`.
- **Both are integers**, so confusing them is not a type error. It is a silent misaddress that
  either resolves to an unrelated issue or returns a bare `422`.
- The board never learns a database id. Every identifier it holds is a number: the adapter contract
  returns `number` from `list`, `create` parses the number out of the issue URL, and `external_ref`
  stores a number. Nothing on the board could carry an id without a schema change.
- The CLI the GitHub adapter is built on already reads the relationship natively — `subIssues`,
  `subIssuesSummary`, and `parent` are ordinary JSON fields, selecting
  `subIssues(first:100){nodes{id,number,title,url,state,...}}`. So the **read** side needs no raw
  API call, and its page size exactly matches the documented per-parent cap. Only the **write** side
  does. Note that this CLI's `id` field is the GraphQL node id (a base64 string), which the REST
  endpoint will not accept; the database id comes from the REST issue resource.
- A child may have **at most one parent**. The API exposes a singular `parent` resource and a
  `replace_parent` flag, "when true, instructs the operation to replace the sub-issues current
  parent issue". So linking is not additive: attaching a child necessarily detaches it from
  whatever parent it already had.
- Upstream limits are 100 sub-issues per parent and eight levels of nesting, and a child must belong
  to the same repository owner as its parent. A mirror targets one configured repository, so the
  owner constraint holds by construction.

## Decision

- **Visibility only, one way.** The board writes the tracker; the tracker never writes the board.
  Building a bundle out of sub-issues authored on the tracker is a separate `import` feature and is
  out of scope.
- **One relationship.** An orchestrator's `children:` roster is the sole source of the links. The
  board's other edge type, `depends_on` (ADR 0004), is **not** projected, even though the upstream
  API exposes blocked-by and blocking relationships that would fit it. One board concept maps to one
  tracker concept or the mapping stops being readable.
- **The contract stays number-based, and the adapter closes the gap.** Child identity rides on the
  existing `update` request as issue numbers; each adapter reconciles links internally, resolving
  numbers to whatever its own API names. No new adapter verb, no capability probe. An adapter that
  cannot link keeps the checklist and nothing else changes. The alternative — teaching the contract
  a second identifier — would push a tracker's implementation detail onto every adapter and into the
  document schema, to be resolved by exactly one of them.
- **Links reconcile in a pass of their own, after the create/update/close loop.** They cannot ride
  on the body-diffed update, for two reasons found in the code: every request is built before any
  action runs, so a parent cannot name a child issue that does not exist yet — and on a first run
  none of them do — while an unchanged parent is short-circuited to `same` and emits no request at
  all. So the pass runs once every marker's number is known, and compares desired links against
  actual ones rather than against the body.
- **Support is read from the `list` reply, per issue.** An issue row carrying `children` can be
  linked; one without it cannot. Reporting them is part of supporting them, so there is still no
  probe. A parent created in the same run has no row to read, so its links are sent once regardless:
  against an adapter with no link support that costs one ignored call per bundle, on the run that
  creates it, and nothing after.
- **Ownership is told to the adapter, not re-derived by it.** The link request names every issue the
  mirror made in `owned`, exactly as it already names the label prefixes it manages in `managed`. An
  adapter that had to work ownership out for itself would need a fetch per linked child, and two
  adapters would drift on the definition.
- **An issue the board delegated is the mirror's to link, too.** A child handed out with
  `export --to-issue` is skipped by the mirror and never carries a marker, so its number is read
  from its own doc's `external_ref` — the second lookup key. That record is read board-wide rather
  than per-roster: a child dropped from a bundle must still be recognised as the board's own, or its
  link could never be taken down.
- **The mirror never re-parents.** `replace_parent` is never sent. Because linking is destructive of
  an existing parent, sending it would let the mirror silently steal a child a person had deliberately
  parented elsewhere. A refusal there is reported and the run continues, consistent with ADR 0011's
  rule that only the mirror's own artifacts are reconciled.
- **Managed links only.** A link is removed only when both issues are the mirror's own, identified by
  its hidden marker or by `external_ref`. A hand-attached sub-issue survives, the same rule that
  already governs managed label prefixes.
- **The checklist stays.** It is the portable floor for trackers with no native relationship, and the
  only place ADR 0013's public count of unshared children can live. On a public repository an
  unshared child is never linked, because a link names the child.
- **A closed child is left linked** while the orchestrator is mirrored, resolved from the archive the
  same way child progress already is. When the orchestrator itself closes, its links are left as they
  are.
- **Overflow warns, it never fails.** Past the per-parent cap or the nesting depth, the extra children
  stay in the checklist and the run says so and exits zero. A visibility feature that fails a run has
  made things worse than the checklist it replaced.
- **Tracker drift is reported, never reconciled.** A child closed on the tracker while open on the
  board does not become `done` — status changes only on the board, with evidence (ADR 0011). The
  mirror does not reopen the issue. It records the divergence in a generated per-section
  `TRACKER-DRIFT.md`, rewritten only when drift appears or clears so a CI run stays quiet, and
  `handoff list` and the session board surface it on the affected handoff.
- **No schema bump.** No document gains a field. Existing bundles acquire links on their next mirror
  run. The payload version is bumped and the fixture boards resynced.

## Considered options

- **Carry database ids in the contract or on the document.** Rejected — it leaks one tracker's
  identifier space into every adapter and into the schema, for a value only that adapter can use and
  which the board can always re-derive from a number.
- **A capability probe, so the CLI asks whether an adapter supports links.** Rejected — a new verb
  and a new failure mode to answer a question the adapter can answer by doing nothing.
- **Replace the checklist with links.** Rejected — it strands every tracker without a native
  relationship, and deletes the one place the public unshared-child count can be stated.
- **Send `replace_parent` so the board's roster always wins.** Rejected — the board is the source of
  truth for its own bundles, not for relationships a person built by hand in the tracker. Stealing
  them silently is the worst available failure.
- **Project `depends_on` as blocked-by relationships.** Rejected for now — plausible and separately
  useful, but it doubles the mapping surface in the same change and the two edges answer different
  questions. Worth its own decision later.
- **Fail the run on overflow.** Rejected — the cap is far above any bundle these boards produce, and
  the behaviour would only ever fire as a surprise.

## Consequences

- The GitHub adapter gains one API call per child linked or unlinked to resolve a number to a
  database id, plus one read per mirrored parent. A bundle already in sync costs the read and no
  writes.
- `update` becomes **partial**: absent `title`, `body` and `labels` mean "do not touch". Without
  that, a link-only update would pass an empty title and blank the issue.
- The GitHub adapter is no longer expressible in issue subcommands alone; the write path needs raw
  API calls. Its contract header must say so.
- The no-network adapter used by the harness has to model parent/child links, including a
  hand-attached one it must leave alone.
- Neither upstream limit binds any bundle this board has produced, so the overflow path is reachable
  only from the harness. That is the point of testing it there.
- `TRACKER-DRIFT.md` is generated, like `INDEX.md`: never hand-edited, and needing no lease.

## Sources

- <https://docs.github.com/en/rest/issues/sub-issues?apiVersion=2022-11-28> — endpoints,
  `sub_issue_id`, `replace_parent`, response codes.
- <https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/adding-sub-issues>
  — "up to 100 sub-issues per parent issue", "up to eight levels of nested sub-issues".
