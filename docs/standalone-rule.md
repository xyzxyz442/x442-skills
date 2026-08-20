# The standalone rule

This repo is the **source** of agent skills, not a participant in anyone's fleet. Nothing
committed here may name, path to, or execute code in another project.

The rule is stated in [AGENTS.md](../AGENTS.md) under House rules. This document explains why
it exists, what the automated check does, and how to get past it honestly.

## Why

Every skill in `skills/` is designed to be installed _into_ other repos —
`register-cross-repo-handoff` wires a repo to a shared board, `register-cross-repo-graph`
registers sibling graphs, `setup-handoff` writes hooks. Running one of those skills **from**
this repo, against this repo, writes its output **into** this repo. That output is
project-specific by construction: a board path in a neighbouring workspace, a group name, a
list of peer service repos.

That is how foreign references have leaked in before, and they are not harmless:

- **They break on any other machine.** A hook that execs `../acme-workspace/.../hooks.sh`
  fails for every person who clones this repo, because that path exists on exactly one disk.
- **They leak private information.** Internal team, service, and product names end up in a
  public repository and in its git history.
- **They couple the source to one consumer.** A skill that works everywhere is worth more than
  a skill wired to one workspace, and wiring proves nothing the harness does not already prove.

Dogfooding a skill is still encouraged — just do it in a scratch checkout or a harness
fixture, and commit the _skill_ improvement, not the _install output_.

## What the check enforces

[`scripts/verify-standalone.sh`](../scripts/verify-standalone.sh) is read-only and runs three
passes over git-tracked text files.

| Check      | Fails on                                                                                  | Rationale                                                               |
| ---------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `wiring`   | any `../` inside `.claude/`, `.gemini/`, `.vscode/`, `.husky/`, `.github/hooks/`          | tool config is executed; it must never reach outside the repo           |
| `escaping` | a `..`-relative path whose first segment names nothing anywhere in this repo              | an intra-repo relative path always resolves to a name the repo contains |
| `names`    | any identifier in [`scripts/standalone-denylist.txt`](../scripts/standalone-denylist.txt) | pins names that have actually leaked before so they cannot return       |

The `escaping` check needs no list to maintain: `../lib/grade_common.py` passes because `lib`
exists in the tree, and a path naming a repo this tree does not contain fails because it does
not. Build output (`../coverage`) and elided paths (`../.../handoff`) are exempt.

## Running it

```text
scripts/verify-standalone.sh                 # every tracked file
scripts/verify-standalone.sh --staged        # only staged files (what pre-commit runs)
scripts/verify-standalone.sh docs/foo.md     # specific paths
```

It runs automatically in two places:

- **`pre-commit`**, via [`scripts/husky.sh`](../scripts/husky.sh), on staged files only.
- **CI**, via [`.github/workflows/standalone.yml`](../.github/workflows/standalone.yml), on the
  full tree for every push and pull request.

## Writing examples that pass

Use neutral placeholders. The repo already uses these; stay consistent with them.

| Instead of                 | Write                                 |
| -------------------------- | ------------------------------------- |
| a real repo name           | `acme-api`, `acme-lib`, `svc-billing` |
| a real workspace path      | `../workspace/src`, `../acme-lib`     |
| a real group or team name  | `acme`, `platform`, `<group>`         |
| a real service description | "billing usage ingest"                |

## The escape hatch

Two spellings, both matched inside a comment:

| Marker                    | Exempts             |
| ------------------------- | ------------------- |
| `standalone-ok`           | the line it sits on |
| `standalone-ok-next-line` | the line below it   |

Use `standalone-ok` in code and config, where lines are stable. **In markdown, use
`standalone-ok-next-line`** — prettier runs on every commit and reflows prose, which moves a
trailing inline comment onto a different line than the text it was meant to cover. A comment on
its own line stays put.

```text
<!-- standalone-ok-next-line: quoting the upstream name is the point of this citation -->
The bug is fixed upstream in someones-project 2.1.
```

Use it only for prose that must name something real to be accurate — a citation of an upstream
vendor doc, a changelog entry about an external dependency. **Never use it to restore wiring.**
A hook or setting that reaches outside the repo is the failure this rule exists to prevent, and
silencing the check does not make the path resolve on anyone else's machine.

## When a real name genuinely has to be recorded

It does not belong in this repo. Put it where the work is:

- Work that spans other repos belongs on **their** board, not on this repo's
  `.agents/handoff/`. File it in the repo that owns the work.
- A field record of an install belongs in the workspace that was installed into, or gets
  genericized before it lands here — see
  [cross-repo-handoff-usage-record.md](cross-repo-handoff-usage-record.md), which is written
  entirely in placeholders for exactly this reason.
