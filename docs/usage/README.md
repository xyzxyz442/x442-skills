# Usage guides

Each skill's `SKILL.md` tells an assistant **when** to invoke it and **how** to run it. These pages
are the layer above that: what a suite is **for**, what a real run looks like end to end, and which
situations it is the right answer to.

They are written for someone meeting these skills for the first time. If you are looking for the
exact flags a command takes, the `SKILL.md` files are the reference; these pages are the map.

## Start here — onboarding

Read these in order the first time.

| Guide                                                                  | Read it when                                                                                                                        |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| [Onboarding — a new developer](onboarding-new-developer.md)            | You have GitHub, VS Code and your language toolchain, and nothing AI-related set up yet.                                            |
| [Onboarding — an existing developer](onboarding-existing-developer.md) | You already use an assistant, but your hooks, global context, permissions or VS Code settings grew by hand. A fifteen-minute audit. |
| [Onboarding — a project](onboarding-project.md)                        | A repo needs wiring: newly created, legacy with its own tooling, or half-migrated by someone who stopped partway.                   |
| [Platforms](platforms.md)                                              | You are on Linux or Windows (WSL), or a hook works on one machine and not another.                                                  |
| [Best practices](best-practices.md)                                    | You want the standard global context, a permission baseline, and the delegation and working habits behind them.                     |
| [Daily prompts](daily-prompts.md)                                      | The setup is done and you want the prompts that get the most out of it.                                                             |

## Suites

| Guide                                                           | Read it when                                                                                                                                                  |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Graph hooks](graph-hooks.md)                                   | An assistant should query a code graph instead of grepping — installing the tools, wiring a repo, choosing a search tier, repairing it.                       |
| [Handoff](handoff.md)                                           | Two agents, two sessions or two repos need to work the same code without clobbering each other — or work has to survive a session.                            |
| [Team and personal boards](handoff-team-and-personal-boards.md) | You work on a team that shares one handoff board and keep a board of your own — where each lives, which work goes on which, and how a draft reaches the team. |
| [Secret guard](secret-guard.md)                                 | A credential file or a cluster read has to stay usable by an agent without its values landing in a transcript.                                                |
| [Delegate](delegate.md)                                         | Mechanical, bulky work should run on a cheaper agent, without deciding for the user where their code goes.                                                    |

## Diagrams

The guides link standalone HTML diagrams under [`diagrams/`](diagrams/). Open the file directly —
the SVG, the styles and the viewer are all inline, so nothing needs a build step or a server.

They pull one webfont from Google Fonts. With no network the page still renders and is fully
readable; it falls back to a system monospace face. Treat them as **generated artifacts**: they are
produced by `archify deliver`, which reports a sha256 over the exact committed bytes, so regenerate
them rather than editing them by hand.

The handoff and delegate diagrams' sources live in [`diagrams/src/`](diagrams/src/), one JSON spec per diagram,
named `NAME.TYPE.json`. To change one, edit the spec, then validate and deliver it from the archify
skill directory:

```text
node bin/archify.mjs validate TYPE SPEC.json --quality showcase --json
node bin/archify.mjs deliver TYPE SPEC.json docs/usage/diagrams/NAME.html --quality showcase --json
```

`deliver` refuses anything short of a full showcase pass and leaves the previous HTML in place. The
secret-guard diagram predates this and has no committed source yet.

## Where the other sources of truth live

These pages deliberately do not restate any of the following. When they disagree, the sources win.

- **[`CONTEXT.md`](../../CONTEXT.md)** — the glossary. A word these guides bold as a _term_ (not a
  bold lead-in sentence) is defined there, with the near-synonyms to avoid. If a word here seems to be doing precise work, it
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
