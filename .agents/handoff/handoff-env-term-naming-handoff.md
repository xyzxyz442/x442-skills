---
id: handoff-env-term-naming-handoff
title: Handoff env vars — align names to the tool's own terms
type: coordination
status: open
audience:
repos: []
severity: low
created: 2026-08-23
updated: 2026-08-23
note:
---

## Context

Audit first, because the premise needs narrowing: **every user-settable env var in the
handoff payload already carries the `HANDOFF_` prefix.** Sweeping
`grep -rnoE '\$\{?(HANDOFF|HD|HC|BOARD)[A-Z0-9_]*' skills harness` turns up
`HANDOFF_GROUP`, `HANDOFF_GROUPS`, `HANDOFF_GROUP_LAYOUT`, `HANDOFF_TTL_HOURS`,
`HANDOFF_REPO`, `HANDOFF_ALLOW_VERIFY_CMD`, `HANDOFF_HDPATH`, `HANDOFF_SESSION_ID`,
`HANDOFF_NO_MAIN`, `HANDOFF_TOOL`, `HANDOFF_PRIMARY` — no bare-named reads. `HC_*` are
internal assignments emitted by `config.sh`, never read from the environment.

The defect is one level down: **the prefix is right, the terms after it are not.** Names
carry the installer's internal abbreviations and disagree with the tool's own vocabulary,
which is the thing that makes the surface hard to learn and hard to document.

Confirmed violations:

| Name                                   | Problem                                                                                                                                                                                                                                                                             | Proposed                                                                              |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `HANDOFF_HDPATH`                       | `HD` is the installer's private abbreviation (`HDEST`/`HDPATH`). The tool's term for this is **board path** — `merge-hooks.py:137` literally assigns `cfg["boardPath"] = found["HANDOFF_HDPATH"]`. It is the most public name we have — baked into every wired tool's hook command. | `HANDOFF_BOARD_PATH`                                                                  |
| `HANDOFF_REPO`                         | Identity has three spellings — env `HANDOFF_REPO`, board config `repoName`, repo config `repo` (`config.sh:76-80` maps `repo` to `repoName`).                                                                                                                                       | keep `HANDOFF_REPO`, converge the **config keys** on `repoName`; document the mapping |
| `HANDOFF_NO_MAIN`                      | An implementation term — "main" is the dispatch block at `payload/handoff:2148-2150`. Set by nothing but the self-test, so it is not really public surface at all.                                                                                                                  | `HANDOFF_INTERNAL_NO_DISPATCH`, documented as internal, or leave and mark internal    |
| `HANDOFF_DIR` (`setup-handoff.sh:138`) | A **local shell variable**, not an env var, squatting on the public namespace and meaning "the board path" (the `--handoff-dir` flag).                                                                                                                                              | rename the local to `BOARD_ARG`; no deprecation needed, it was never public           |

Out of scope, deliberately: `CLAUDE_SESSION_ID` and `CLAUDE_CODE_SESSION_ID`
(`payload/handoff:266`) are **vendor-owned** and read as fallbacks. They must keep their
names. `USER` likewise.

Also incomplete: `payload/README.md:150-152` states the prefix convention and then lists only
five of the names. `HANDOFF_HDPATH`, `HANDOFF_SESSION_ID`, `HANDOFF_TOOL`, `HANDOFF_PRIMARY`
and `HANDOFF_NO_MAIN` are undocumented, which is how the terms drifted unnoticed.

## Where

- `skills/engineering/setup-handoff/scripts/payload/handoff:52-58` — the env-over-config
  layer where each `HANDOFF_*` is read.
- `skills/engineering/setup-handoff/scripts/payload/hooks.sh:139-152` — the same layer in the
  hooks, including `hd="${HANDOFF_HDPATH:-${HC_BOARD_PATH:-.agents/handoff}}"` at `:145`.
- `skills/engineering/setup-handoff/scripts/setup-handoff.sh:420`, `:435` — where
  `HANDOFF_HDPATH` is baked into each tool's hook command. Renaming here changes committed
  tool settings in every wired repo, so it must go through `merge-hooks.py`'s rewrite path,
  not a manual edit.
- `skills/engineering/setup-handoff/scripts/merge-hooks.py:123`, `:136-137`, `:163` — the
  parser that recovers `HANDOFF_*` out of an existing hook command. It must accept **both**
  spellings while the old one lives, or re-running the installer against an
  already-wired repo loses the value.
- `skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh:243` and
  `skills/engineering/repair-handoff/SKILL.md:194` — callers that pass `HANDOFF_HDPATH`.
- `skills/engineering/setup-handoff/scripts/payload/README.md:150-152` — the convention and
  its incomplete list.

## The work

1. **Read new, fall back to old, warn once.** For each renamed name:
   `NEW="${HANDOFF_BOARD_PATH:-${HANDOFF_HDPATH:-<default>}}"`, and when the old name is set
   while the new one is not, emit one deprecation line to **stderr** naming the replacement
   and the removal version.
2. **Respect the hooks' no-hard-fail rule.** `hooks.sh` must never fail a tool session
   (`hooks.sh:95-99` — pretool/posttool/stop "stay silent and fast", only sessionstart
   surfaces degradation to the user). So a deprecation warning from the hooks belongs on the
   **sessionstart** channel only. Never on pretool — a warning on every edit is how a session
   gets flooded and how the gate gets disabled.
3. **Warn once per process**, guarded by a flag variable, not once per call site.
4. **Teach `merge-hooks.py` both spellings** and have it rewrite the old name to the new one
   when it re-renders a hook command, so a re-run of the installer migrates wired repos
   without operator action.
5. **Complete `README.md`'s table** with every `HANDOFF_*` name, each marked public or
   internal. An undocumented name is how this happened.
6. **Record every rename in `handoff-deprecation-registry-handoff`** — that doc is the single
   source of truth for what is deprecated, from which version, and when it is removed. Do not
   invent a removal date here; the registry owns the policy.
7. Bump `scripts/payload.version`, and bump the board schema number **only if** a config key
   changes shape — an env alias alone does not change on-disk board format. See
   `handoff-cli-version-guard-handoff` for the two-number split.

## Decisions

- The prefix is **not** the problem and does not need a sweep. Do not rename anything that is
  already `HANDOFF_<tool-term>`.
- Vendor env vars (`CLAUDE_*`) are never renamed or aliased.
- No breaking change in this handoff. Old names keep working for at least one full
  deprecation window; the registry sets the window.
- `HANDOFF_DIR` in `setup-handoff.sh` is a local variable — rename it freely, it has no
  deprecation obligation. Do not add an alias for something that was never public.

## Verify

- `HANDOFF_HDPATH=foo bash -c '<hooks sessionstart invocation>'` prints exactly one
  deprecation line naming `HANDOFF_BOARD_PATH`, and the resolved board path is still `foo`.
- The same var on a **pretool** invocation prints nothing and the gate still enforces.
- Setting both names, new wins, no warning.
- Setting neither, no warning, default path resolves.
- `merge-hooks.py --check` against a hook command carrying the old name reports it as
  wired (not missing), and a re-run rewrites the command to the new name in place.
- `bash skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh .` passes; the
  harness workspaces for `setup-handoff` and `repair-handoff` stay green.
- Every name in the payload appears in `README.md`'s table:
  `grep -ohE 'HANDOFF_[A-Z_]+' skills/engineering/setup-handoff/scripts/payload/* | sort -u`
  diffed against the table.

## Suggested skills

- `x442-repair-handoff` — smoke-tests the CLI and the wired hook commands after the rename.
- `x442-run-handoff` — claim/release discipline while working this.

## Activity

- 2026-08-23 — open — released by Gunn Bhatrakarn (d874fc91).
