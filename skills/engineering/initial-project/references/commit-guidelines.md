# Commit conventions

Best practice for writing commits. These rules mirror the machine-enforced
[`commitlint.config.mjs`](../../setup-project-tooling/assets/commitlint.config.mjs) (based on
[Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/) via
[`@commitlint/config-conventional`](https://github.com/conventional-changelog/commitlint/tree/master/@commitlint/config-conventional)).
`commitlint.config.mjs` is the single source of truth — if this prose and the config ever diverge,
the config wins. `setup-project-tooling` installs the enforcement (husky `commit-msg` hook + CI);
these conventions apply to every commit regardless of whether that tooling is wired yet.

## Format

```text
type(scope): subject
```

- **type** — required; one of the allowed types below.
- **scope** — required by the config's `scope-enum`; one of the allowed scopes below.
- **subject** — lowercase, imperative mood ("add", not "added"/"adds"), no trailing period.

Keep the subject short (~50 chars). Add a body (blank line, then wrapped prose) when the change
needs the *why*; add a `BREAKING CHANGE:` footer for incompatible changes.

## Allowed types

| Type | Use for |
| --- | --- |
| `feat` | A new feature |
| `fix` | A bug fix |
| `docs` | Documentation-only changes |
| `style` | Formatting/whitespace — no change in code meaning |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `perf` | Performance improvement |
| `test` | Adding or correcting tests |
| `build` | Build system or external dependency changes |
| `ci` | CI configuration and scripts |
| `chore` | Other changes that don't touch src or tests |
| `revert` | Reverts a previous commit |

## Allowed scopes

`setup`, `config`, `deps`, `feature`, `bug`, `docs`, `style`, `refactor`, `test`, `build`, `ci`,
`release`, `other`.

## Examples

```text
feat(feature): add graph-hooks routing block to AGENTS.md
fix(bug): resolve primary-owner transfer on existing settings.local.json
docs(docs): document cross-platform prerequisites for both skills
chore(deps): bump @commitlint/cli to ^21
```

Avoid: `Fixed bug.` (no type/scope, capitalized, past tense, trailing period),
`feat: stuff` (missing scope, vague subject).
