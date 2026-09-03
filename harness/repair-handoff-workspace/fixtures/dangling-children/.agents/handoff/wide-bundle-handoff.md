---
id: wide-bundle-handoff
title: Wide bundle — a roster written before its docs
type: orchestrator
status: open
children: [ghost-one-handoff, ghost-two-handoff, ghost-three-handoff, sample-repair-handoff]
created: 2026-08-01
updated: 2026-08-01
note: Three of its four children were never filed.
schema: 1
---

<!-- ORCHESTRATOR handoff: an index over a BUNDLE of related handoffs. It holds no work of its
     own — the children do — so it needs no lease and is gate-exempt. -->

## Bundle

A bundle whose roster names documents that were never filed. Declaring a roster ahead of authoring
its children is legitimate planning; the defect is that nothing ever reports the gap, so the bundle
can never close and nobody is told why.

## Current state

Three children are named and unfiled. `verify-setup-handoff.sh` reports them as
`bundle.children.dangling`; `handoff children add --stub` is the cheap fix.

## Children

<!-- prettier-ignore-start -->
<!-- handoff:children:begin -->
<!-- handoff:children:end -->
<!-- prettier-ignore-end -->

## Sequencing
