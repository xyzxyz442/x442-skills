# AGENTS.md

Shared rules for `acme-api`. Two skills have already spliced their managed blocks into this
file, in the order the documented chain installs them, with the repo's own prose both above and
below them. This is the shape in which every AGENTS.md splice defect in this suite was reachable
and none of them was visible.

## House rules

- Prefer the repo's own scripts over ad-hoc shell.
- Never delete with `rm`; use `trash`.

<!-- graph-hooks:begin (managed by setup-graph-hooks — do not edit between markers) -->

## Knowledge Graph (code navigation)

Query the graph before you grep.

<!-- graph-hooks:end -->

<!-- handoff:begin (managed by setup-handoff — do not edit between markers) -->

## Handoff board

Claim before you work, release when you stop.

<!-- handoff:end -->

## Build

```bash
make build
```
