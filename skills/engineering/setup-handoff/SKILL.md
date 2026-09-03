---
name: x442-setup-handoff
description: >-
  Use immediately after initial-project, or whenever the user wants multi-agent / cross-session /
  cross-repo work coordination — a handoff board, "claim before you work / release when you stop"
  leases, tracking who acts next, or verifying "done" against live code. Installs a tool-generic
  lease-based handoff protocol into .agents/handoff/, wires each tool's enforcement hooks (the
  user picks a primary), injects an AGENTS.md routing block, and can migrate a legacy
  .claude/handoff/ install. Idempotent and safe on any repo. Chains before run-handoff.
---

# setup-handoff

Installs a **lease-based handoff coordination protocol** so multiple agents, sessions, or repos
can work the same codebase without clobbering each other. The rule the protocol enforces is
**"claim before you work, release when you stop."** Runs as a repo-onboarding step after
`initial-project` has created the canonical `AGENTS.md`; the every-session discipline it enables
is documented by [`run-handoff`](../run-handoff/SKILL.md).

Everything is idempotent. The tool-generic payload installs on any repo; only the enforcement
hooks are per-tool, and the user chooses which one tool gets **hard** enforcement.

## Architecture: three layers

1. **Universal payload (tool-agnostic, always installed)** under `.agents/handoff/`: the
   `handoff` lease script, `scripts/hooks.sh`, the generated `INDEX.md`, per-topic docs,
   `templates/` (the doc scaffolds), `.locks/` (gitignored on a board with no remote, committed on
   one that has it — see **A shared board is a git repo**), a committed `handoff.json` (topology,
   policy, and the tooling-owned `_generated` block), and the `<!-- handoff -->` routing block
   appended to `AGENTS.md`. Because every tool's
   entry file `@AGENTS.md`-imports (set up by `initial-project`), the routing block reaches all
   tools with no per-tool edit. Machinery sits in `scripts/` + `templates/` so the board root holds
   only the `handoff` entry point and the docs themselves; a flat board from before this layout is
   migrated on the next install (`git mv`, hook commands rewritten), and keeps working until then.
   The `handoff` entry point is a **dispatcher**, not the CLI: the CLI is ~180 KB and changes on
   every fix, so a copy of it on every board made each fix an N-file regeneration. The dispatcher
   resolves `$HANDOFF_BIN` → a **user-level install** (`${XDG_DATA_HOME:-$HOME/.local/share}/handoff/handoff`,
   written by this installer — the one thing it writes outside the repo) → the board's vendored
   `scripts/handoff-cli`, which is what keeps a cold clone working with nothing but bash. Pass
   `--no-vendor-cli` to skip the vendored copy on a board that is never cloned cold. Which board
   and which CLI answered is always reportable with `./handoff --which`, and repointing a repo at
   another board needs no committed edit — export `HANDOFF_BOARD_PATH`.
2. **One enforcement core (`hooks.sh`).** A single dispatcher runs every hook kind
   (`sessionstart` / `pretool-edit` / `posttool-edit` / `stop`). It parses each tool's payload
   with **python3** (this repo standardises on python3, not `jq`) and emits that tool's native
   deny/context shape. Ownership is settled by an **atomic `mkdir` lock**; the gate matches the
   payload's `session_id` against the `session=` the lease records — that equality is the whole
   basis of enforcement.
3. **Per-tool hook config.** For each chosen tool, `merge-hooks.py` writes that tool's native hook
   config, **merging** (it strips only handoff-managed groups, never other keys). Only the
   **primary** tool gets the `pretool-edit` **deny** gate + `stop` nag (hard enforcement);
   the rest get `sessionstart` board-injection + `posttool-edit` index-regen (advisory).

### Per-tool support

| Tool           | Config file                  | Pre-tool (deny) | Session        | Post-tool      | End-of-turn   |
| -------------- | ---------------------------- | --------------- | -------------- | -------------- | ------------- |
| Claude Code    | `.claude/settings.json`      | `PreToolUse`    | `SessionStart` | `PostToolUse`  | `Stop`        |
| Gemini CLI     | `.gemini/settings.json`      | `BeforeTool`*   | `SessionStart` | `AfterTool`*   | `AfterAgent`* |
| GitHub Copilot | `.github/hooks/handoff.json` | `preToolUse`*   | `sessionStart` | `postToolUse`* | `agentStop`*  |

Claude Code's contract is wired precisely and verified. Gemini/Copilot event names (`*`) follow
their documented hook references but are wired best-effort; for those, the AGENTS.md routing block
is the behavioral guarantee. Sources: [Claude Code hooks](https://code.claude.com/docs/en/hooks.md),
[Gemini CLI hooks](https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/reference.md),
[Copilot hooks](https://docs.github.com/en/copilot/reference/hooks-reference).

## Preconditions

1. **`AGENTS.md` exists at the repo root.** This skill chains after `initial-project`. If it is
   missing, stop and tell the user to run `initial-project` first — do not create it here.
2. The repo is a git working tree.

If either fails, report it and stop. Do not partially apply.

## Prerequisites & platform support

- **Hard runtime:** `bash`, `git`, and — for a hard-enforcement **primary** — `python3` (stdlib
  only). The installer's preflight **refuses to designate a primary unless python3 is present**,
  so a broken deny gate is caught at install time, not silently at runtime. An advisory-only
  install (`--primary none`) needs no python3.
- **Platform:** macOS and Linux are first-class — the scripts are portable (temp-file `sed`
  instead of GNU `sed -i`, `date -r || date -d`, `awk` for frontmatter edits, `mkdir`-based
  locks). Windows via WSL: keep the repo on the Linux filesystem (a `/mnt/c` mount can drop the
  hook exec bit) and check the `.sh` files out with LF (the repo `.gitattributes` enforces this).
- No `node`, no `jq`.

## Procedure

`$SKILL_DIR` is this skill's folder; `$REPO` is the target repo root.

### 1. Resolve the repo root

```bash
REPO="$(git rev-parse --show-toplevel)"
```

### 2. Detect tools, and ask which to wire

Mirror `initial-project`. Detect by marker — Claude (`.claude/`, `CLAUDE.md`), Gemini (`.gemini/`,
`GEMINI.md`), Copilot (`.github/copilot-instructions.md`). Present them with `AskUserQuestion`
(`multiSelect: true`), pre-selecting the detected ones. The universal payload installs regardless.

### 3. Pick the primary (hard-enforcement) tool — REQUIRED

Ask (`AskUserQuestion`, single-select) which **one** tool owns **hard enforcement** (the
`pretool-edit` deny gate). Pre-select the most-used / first-detected tool. Include a
_"None — advisory only"_ option. Only the primary can deny an edit by a non-lease-holder; the
others still inject the board and regenerate the index. **If a primary is chosen, python3 must be
present** (the installer enforces this); if it is not, either install python3 or fall back to
`--primary none`.

### 4. Pick the topology

Ask (`AskUserQuestion`, single-select), default **single-repo**:

- **single-repo** (repo-level) — the board lives **in-repo**; no `audience` routing. Best for
  multi-agent / multi-session work in one repo. Defaults to `.agents/handoff/`; pass
  `--handoff-dir <relative-path>` to place it elsewhere in the repo (e.g. `.claude/handoff`,
  `.handoff`). The path must stay inside the repo — a shared parent dir is what cross-repo is for.
- **cross-repo** — the board is a **shared** folder referenced by sibling repos; `audience` routes
  which repo acts next. Choose this only for a multi-repo setup, and pass `--topology cross-repo`
  (optionally `--handoff-dir <shared path>`); re-run the installer in each sibling repo.

### 5. Detect an existing install and offer to upgrade + migrate

Always run the detector first — it scans repo-level (`.agents/handoff`, `.claude/handoff`,
`.gemini/handoff`, `.github/handoff`, `.handoff`) and parent-level (`../.agents/handoff`,
`../handoff`) locations and classifies each install:

```bash
bash "$SKILL_DIR/scripts/detect-handoff.sh" "$REPO"
# FOUND <path> | scope=repo|parent | kind=generic|legacy-toolpath|shared | version=current|legacy | docs=<n>
# ... + a Suggestion + `Detected: N install(s)`
```

- **`Detected: 0`** → fresh install; skip to the apply step.
- **A generic, current `.agents/handoff/`** already present → no migration needed (re-run is a
  no-op).
- **A legacy or tool-path install** (e.g. `.claude/handoff`, or `version=legacy`) → **ask the user
  (`AskUserQuestion`)** whether to upgrade + migrate it, and to **where**:
  - **current repo-level** — `--migrate <found>` (moves to `.agents/handoff/`, the default).
  - **parent-level shared** — `--topology cross-repo --migrate <found>` (for a board siblings share).
  - **specific location** — `--handoff-dir <path> --migrate <found>`.

Migration `git mv`s the docs and `archive/` (history preserved), drops the machine-local
`.locks/`, installs the fixed scripts, and re-points every wired config. It is the "enhancing"
path and is a no-op when the install is already generic and current.

### 6. Apply

```text
bash "$SKILL_DIR/scripts/setup-handoff.sh" "$REPO" \
  --tools <comma-list> --primary <tool|none> \
  [--topology single-repo|cross-repo] [--handoff-dir <path>] \
  [--migrate <legacy-dir>] [--allow-verify-cmd]
```

`--allow-verify-cmd` records the opt-in that lets `release --status done --run-verify` execute a
doc's `verify:` command (off by default — see the safety note). Re-running with a different
`--primary` moves hard enforcement idempotently (strips the old deny/stop hooks).

### 7. Verify it fires

```bash
bash "$SKILL_DIR/scripts/verify-setup-handoff.sh" "$REPO"
```

Healthy result is **0 failed**. The verifier confirms the payload, the config/gitignore/AGENTS.md
block, each wired tool's JSON, that a hard-enforcement primary has a `pretool-edit` deny gate, the
python3 preflight, and fires the read-only hook paths (sessionstart; pretool denies `INDEX.md`
and allows ordinary files). If anything `[FAIL]`s, surface it and stop.

### 8. Report

Summarize: tools wired, primary (hard) vs advisory, topology, whether a legacy install was
migrated, and the verifier summary line. Point the user at `run-handoff` for the day-to-day
discipline.

## Cross-repo read-only access (optional)

In cross-repo topology the shared board lives outside each repo. The installer wires Claude's
`additionalDirectories` so the current repo can read/execute the shared `handoff` script; run the
installer in each sibling so every one is wired. `audience` (which repo acts next) is what keeps a
backend and a frontend agent apart — the lock only settles the genuine both-repos race.

For a whole fleet — several repos, or several **groups** of repos sub-indexed on one shared board —
drive this installer from a manifest with
[`register-cross-repo-handoff`](../register-cross-repo-handoff/SKILL.md) instead of running it by
hand per repo; a worked install is recorded in
[docs/cross-repo-handoff-usage-record.md](../../../docs/cross-repo-handoff-usage-record.md).

**Per-repo identity (shared board).** The shared board config is repo-neutral — it carries no
repo name, so no sibling's install clobbers another's identity. Each consuming repo records its own
identity in its own `.agents/handoff.json` (`repo`, `group`, `board`), written by `merge-hooks.py`
at install time. It is deliberately **not** baked into the hook command: a command string goes
stale on a rename and nothing on the board can see that it has. `hooks.sh`/`handoff` prefer
`$HANDOFF_REPO` over that config when it is set, and the `AGENTS.md` routing block is
path-substituted to the real board location. On a
shared board `handoff new` requires an explicit `--audience`. Single-repo installs are unchanged.

## Two version numbers — payload and schema

A board carries **`payload`** (the CLI, templates, hooks) and **`schema`** (the document format).
Payload drift stays a verifier warning saying re-run the installer; **`schema` is the only thing
that triggers a migration.** One number would mean a routine CLI bugfix prompting a whole-board
rewrite for every member of every group (ADR 0003).

The compatibility rule is asymmetric on purpose: an older CLI **reads** a newer document with one
warning, and **refuses to write** it, naming both versions. Refusing to write is what makes reading
safe — warn-and-proceed says nothing about writing, so an older CLI could read a newer doc, release
it, and silently drop every field it did not understand. The two ship together; the read half alone
is worse than neither.

`./handoff migrate [--dry-run] [--yes]` moves documents forward. It moves **structure only** —
never an inferred environment, sensitivity, or a current state seeded from an activity log — and it
is gated on version control, no live lease in the section, a clean worktree, and a push that rolls
back rather than half-applying. Interactive callers are asked, hooks print one line and do nothing,
`--yes` is for CI.

## `verify-setup-handoff.sh --json`

The verifier speaks two ways. Without a flag it prints prose for a human; with `--json` it emits
every finding as an object, each carrying a **stable id**:

```json
{
  "tool": "verify-setup-handoff",
  "schema": 1,
  "summary": { "pass": 24, "warn": 2, "fail": 0 },
  "findings": [
    {
      "id": "bundle.children.dangling",
      "level": "warn",
      "section": "7. Document schema",
      "message": "…"
    }
  ]
}
```

This is not a convenience. Roughly half of what the verifier checks is **advisory by design** —
staleness, document size, weak closure evidence, a missing current state, a board with no remote, a
bundle whose roster names documents that were never filed. None of it changes the exit code, so a
grader or a repair skill reading only the exit status is blind to exactly the checks most likely to
rot. Both consume the findings instead.

The **id is the contract**: it names the check, `level` carries the outcome, and prose is reworded
freely. Assert on `board.git.remote` coming back `warn`, never on the sentence. Where two outcomes
of one check need different remediation they get their own ids (`payload.version.behind` vs
`payload.version.ahead`). `schema` is bumped only when the document SHAPE changes — new ids appear
over time by design, and a consumer that broke on each one would be abandoned within a release.

Section 7 also carries the sensitivity/secret-scan trio from ADR 0005: `board.sensitivity.restricted`
(always a `pass`, reporting the count — holding restricted work is the field doing its job, not a
defect), `doc.sensitivity.invalid` (`warn` — a typo'd value reads as `normal` to every gate,
silently), and `doc.secret.detected` (the section's one `fail` — a credential pattern already in
git history, which needs redacting AND rotating, not just editing). A match on a doc whose activity
log records a `--force-secret` override for that same rule reports as `doc.secret.overridden`
(`warn`) instead: the decision is signed and auditable, so it stays visible without leaving a board
that can never come back clean.

## Configuration

**Everything about handoff is configured in one filename: `handoff.json`.** Which layer a file is
depends on _where_ it sits, not on what it is called — the same shape `AGENTS.md` already uses.
Nearest wins:

```text
env  >  <repo>/.agents/handoff.json  >  <board>/handoff.json  >  built-in default
```

Environment carries **overrides** for a single run; committed files carry normal operation. The two
never collide by accident, because env names keep the `HANDOFF_` prefix (`HANDOFF_TTL_HOURS`) while
file keys are camelCase (`ttlHours`). Two overrides resolve the board and the CLI themselves and so
sit above every config layer: `HANDOFF_BOARD_PATH` (which board) and `HANDOFF_BIN` (which CLI). A
board named by either and not found is a hard error, never a silent fallback to a different board.

**`<board>/handoff.json`** is board-global — `topology`, `groups`, `groupLayout`, `ttlHours`,
`allowVerifyCmd`, `environments`, plus `repoName` on a single-repo board only, and the tooling-owned
`_generated` block (the projected repo registry and the payload version stamp).
**`<repo>/.agents/handoff.json`** is per-consumer and written only for cross-repo installs — `repo`,
`group`, `board`. A shared board is read by every member repo, so no member's identity may live in
the board file; the last installer would clobber the rest. The full key table ships in the board's
own [`README.md`](scripts/payload/README.md) — JSON has no comments, so that table is the
documentation.

This used to be **five files with five names** — a board `config.json`, a generated `repos.json`, a
`.version` stamp, a repo `handoff.config.json`, and a KEY=value `config` — and nobody could answer
"where is handoff configured" without listing all of them. Every one of those is still **read**, at
lower precedence than the file that replaced it in the same directory, so an install that has never
been re-run keeps working. Re-running the installer folds each into `handoff.json` and renames the
old file to `*.superseded`: renamed, never deleted, because nothing here removes a file somebody may
have hand-edited.

Three behaviours worth knowing before you re-run the installer:

- **`ttlHours` survives a re-install.** Lease policy is a committed team decision; an install must
  not quietly revert it. The installer owns wiring facts (`topology`, `groups`, `groupLayout`,
  `repoName`) and rewrites those every time; it leaves policy alone.
- **`allowVerifyCmd` does not survive.** It follows `--allow-verify-cmd` on each run, because it
  permits `release --run-verify` to execute a command from a doc — a security opt-in nobody
  re-affirmed is not one to inherit.
- **The `AGENTS.md` routing block is rewritten, not just injected.** The block declares itself
  `managed by setup-handoff — do not edit between markers`, so every run splices the current
  `assets/agents-handoff.md` over the span between the markers. Hand edits inside the markers are
  discarded, which is what the marker promises; edit the asset instead. Before payload v9 the
  installer only injected the block when it was absent, so an installed block drifted from the
  asset forever and re-running fixed nothing. Duplicated or unbalanced markers are refused rather
  than clobbered — fix those by hand.

The config is **parsed, never sourced.** A shared board's config file is written by every member's
installer and read by every member's hooks, so sourcing it would let one repo execute shell in its
siblings' sessions. Reading it needs `python3`; a board still on the pre-JSON shell `config` keeps
working and migrates on its next install.

## Notes

- **Fail-safe, not fail-open.** If the deny gate cannot parse a payload (python3 missing/broken),
  it **denies handoff-doc edits** with an actionable reason and never blocks ordinary files — the
  opposite of the reference's silent no-op. Combined with the install-time preflight, a broken
  enforcement surfaces instead of vanishing.
- **A shared board is a git repo (ADR 0002).** `--board-only` git-initialises the board it
  scaffolds — non-optionally, because the board of record holds documents that exist nowhere else,
  and one that was never a repository has no history, no blame, and no recovery. `--remote <url>`
  gives it a remote; without one it says plainly that it is versioned but still reaches one
  machine. A board with a remote commits its `.locks/` and `claim` becomes a compare-and-swap over
  `git push` — real mutual exclusion across machines, no server. A board without one keeps
  ignoring `.locks/` and touches the network on no path at all. A nested (in-repo) board is left
  alone: its history belongs to the repo containing it.
- **Self-maintaining leases.** `sessionstart` auto-reaps expired leases; `posttool-edit`
  auto-touches the current session's leases so active work never expires mid-flight. `touch`/`reap`
  remain manual escape hatches.
- **`done` is evidence-gated.** `release --status done` requires `--verified-by "<how>"` and
  refuses to trust-close. An optional `verify:` command is **never auto-run** (a cross-repo doc is
  untrusted); it runs only with `--run-verify` + the install opt-in, and only for a local doc.
- **Two invariants, ported intact.** Ownership lives only in `.locks/`; durable state only in
  frontmatter — they cannot desync. `INDEX.md` is generated and never hand-edited.
  If the repo formats markdown (prettier, dprint, a markdown linter), exclude
  `.agents/handoff/INDEX.md` from it — the generated tables are unaligned, a formatter rewrites them,
  and the next `claim`/`release` regenerates them unaligned again, so the file churns on every
  command. Treat it as generator-owned output, not source.
- **Naming: `<id>-handoff.md`, id always lowercase kebab-case.** Every board doc file ends
  `-handoff.md` and the id is the filename stem; `handoff new`/`import` auto-append the suffix
  (idempotent) and `claim`/`release` accept the short or full id. `norm_id` is the single
  canonicalizer: it lowercases, folds every non-alphanumeric run to one `-`, trims, then appends the
  suffix — so `new "RBAC Gap"`, `new RBAC_Gap`, and `new rbac-gap` all land `rbac-gap-handoff.md`,
  and an id with nothing alphanumeric is rejected. Enforced because ids are literal-compared as
  `.locks/` directory names, as `blocked_on` references, and by the hooks' case-sensitive glob;
  unfolded casing would mean two leases on one doc. Pre-existing docs are **not** renamed —
  resolution falls back to the old spelling when only that file exists. A file is a handoff doc
  **iff** it matches `*-handoff.md` — a whitelist that replaces the old blacklist and structurally
  prevents templates/README/INDEX from leaking into the board listing.
- **Docs are committed — redaction is authored in.** Unlike a throwaway temp-dir handoff, these
  docs land in git history. The template and `handoff new`/`release` output carry a redact-secrets
  reminder (keys, passwords, PII → request via a safe channel, never paste), a `Suggested skills`
  section, and a link-don't-duplicate note. It is guidance, not a hard gate — redaction can't be
  mechanically verified.
- **Sensitivity is a handling flag, not an access control (ADR 0005).**
  `handoff new --sensitivity normal|restricted` marks a `coordination`/`orchestrator` doc that
  must never leave the board; absent reads as `normal`, and `migrate` never backfills it. `restricted` refuses `export`
  outright — a bundle refuses the whole export if the parent or any child carries it — prints a
  handling banner on `claim`, marks the session-start row, and is refused by a delegated agent's
  dispatcher. Board membership is the access boundary; the flag only changes what the tooling does
  with the document.
- **A secret scanner sits on the CLI write path, not in a pre-commit hook (ADR 0005)** — a
  pre-commit hook has nothing to attach to on a board with no repository, which is the board most
  likely to need it. `new`, `release`, `import --result`, and `export` all scan before writing
  (`export` scans the RENDERED brief, closing the gap where the outbound path used to be
  unchecked) and die naming the matched rule, never the value. `--force-secret "<reason>"`
  overrides it on all four commands; the reason is required and recorded on the doc's Activity
  log.
- **Three handoff types.** Each doc carries a `type:` — `coordination` (default; the lease-gated work
  item) or `standalone` (a self-contained reference/knowledge doc: porting guide, eval report,
  compaction brief). A **standalone** doc is **gate-exempt** — the `pretool-edit` hook allows editing
  it with no lease, `claim` refuses it, and it is listed apart from open work; retire it via `release
--status done` (no `--verified-by`). Absent `type:` means `coordination`, so legacy docs and
  existing boards are unaffected. Create with `handoff new --standalone`; bring an existing file onto
  the board with `handoff import <file>`. An **orchestrator** (`handoff new --orchestrator
--children a,b,c`) is the third type: an index over a bundle of related handoffs, also gate-exempt
  and never claimed. Its progress is **derived** from the children's own frontmatter at read time
  and never stored — a written count is stale the moment a child closes — a child naming no doc
  reads as `MISSING` rather than done, and `release --status done` refuses while any child is
  outstanding. The bundle doc carries that derivation as a **generated `## Children` table** (one
  row per child: status, acts-next, severity, blocked-on, lease) so a fresh session can continue a
  bundle from the doc alone; it is rebuilt between `handoff:children` markers on every `index` run,
  and an existing bundle doc gains the section on the next run. `handoff children add|rm <parent>
<child>` changes the roster — the canonicalizing path, so a child cannot be recorded under a
  spelling that names no file.
- **Bundled files:** `scripts/setup-handoff.sh` (installer), `scripts/detect-handoff.sh`
  (read-only existing-install detector), `scripts/merge-hooks.py` (per-tool JSON merge,
  plus `--check` to compare a wired config against what the installer would write now),
  `scripts/splice-agents-block.py` (AGENTS.md block render + splice, shared by the installer and
  the verifier's drift check),
  `scripts/verify-setup-handoff.sh` (verifier), `scripts/payload/` (the
  `.agents/handoff/` payload: `handoff` → board root, `hooks.sh` → board `scripts/`, `README.md`),
  `assets/handoff-doc-template.md`
  - `assets/handoff-standalone-template.md` (scaffolds for `handoff new` / `new --standalone`), and
    `assets/agents-handoff.md` (the AGENTS.md routing block).
