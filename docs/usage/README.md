# Usage guides

Each skill's `SKILL.md` tells an assistant **when** to invoke it and **how** to run it. These pages
are the layer above that: what a suite is **for**, what a real run looks like end to end, and which
situations it is the right answer to.

They are written for someone meeting these skills for the first time. If you are looking for the
exact flags a command takes, the `SKILL.md` files are the reference; these pages are the map.

| Guide                           | Read it when                                                                                                                       |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| [Handoff](handoff.md)           | Two agents, two sessions or two repos need to work the same code without clobbering each other — or work has to survive a session. |
| [Secret guard](secret-guard.md) | A credential file has to stay usable by an agent without its values landing in a transcript.                                       |

## Diagrams

Both guides link a standalone HTML diagram under [`diagrams/`](diagrams/). Open the file directly —
the SVG, the styles and the viewer are all inline, so nothing needs a build step or a server.

They pull one webfont from Google Fonts. With no network the page still renders and is fully
readable; it falls back to a system monospace face. Treat them as **generated artifacts**: they are
produced by `archify deliver`, which reports a sha256 over the exact committed bytes, so regenerate
them rather than editing them by hand.

## Where the other sources of truth live

These pages deliberately do not restate any of the following. When they disagree, the sources win.

- **[`CONTEXT.md`](../../CONTEXT.md)** — the glossary. Every term these guides use in bold is
  defined there, with the near-synonyms to avoid. If a word here seems to be doing precise work, it
  is, and that is where the definition lives.
- **[`docs/adr/`](../adr/)** — why each piece is shaped the way it is. The guides link an ADR
  wherever a design looks arbitrary, because it usually is not.
- **The skill files** under [`skills/`](../../skills/) — the authoritative flag lists and
  procedures.
- **[`harness/*/fixtures/`](../../harness/)** — worked examples. These are real installed boards and
  guard states, committed so the graders can run against them, and they are the closest thing to a
  sandbox you can read without installing anything.

## A note on the examples

Every example here uses neutral placeholders — `acme-api`, `acme-lib`, `svc-a`,
`../workspace/src`. That is not house style; it is enforced. This repo is the _source_ of these
skills, not a participant in anyone's fleet, so nothing committed here may name a real repo, team,
service or product. See [the standalone rule](../standalone-rule.md), which runs at pre-commit and
in CI.
