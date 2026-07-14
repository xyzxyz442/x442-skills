# AGENTS.md

Single source of truth for AI assistants working in `@acme/toolkit-example`.

This is a published TypeScript library: the public surface is whatever `src/index.ts`
re-exports. Keep that barrel accurate — anything not exported there is private.

## Build and test

- `yarn build` — `tsc -b tsconfig.build.json`; emits `dist/` with `.d.ts` declarations.
- `yarn test:cov` — Jest with coverage. This library enforces full branch coverage.
- `yarn release` — `release-it`, conventional commits.

## Coding guidelines

Follow the Karpathy coding guidelines (`karpathy-guidelines`): make the smallest change that
solves the problem, prefer clarity over cleverness, surface assumptions, and define a
verifiable success criterion before writing code.

## Commit conventions

Follow the commit guidelines (`commit-guidelines`): Conventional Commits
`type(scope): subject`, lowercase imperative subject, no trailing period. The enforced
ruleset is `commitlint.config.mjs`.
