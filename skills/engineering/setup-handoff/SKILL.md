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
   `templates/` (the doc scaffolds), `.locks/` (gitignored), a committed `config` (topology + repo
   name), and the `<!-- handoff -->` routing block appended to `AGENTS.md`. Because every tool's
   entry file `@AGENTS.md`-imports (set up by `initial-project`), the routing block reaches all
   tools with no per-tool edit. Machinery sits in `scripts/` + `templates/` so the board root holds
   only the `handoff` entry point and the docs themselves; a flat board from before this layout is
   migrated on the next install (`git mv`, hook commands rewritten), and keeps working until then.
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

**Per-repo identity (shared board).** The shared `config` is repo-neutral — it carries no
`REPO_NAME`, so no sibling's install clobbers another's identity. Each consuming repo's identity is
baked into its **own** hook command as `HANDOFF_REPO=<repo>` (plus `HANDOFF_HDPATH` so the
session-start hint shows the correct relative path). `hooks.sh`/`handoff` prefer `$HANDOFF_REPO` over
the config, and the `AGENTS.md` routing block is path-substituted to the real board location. On a
shared board `handoff new` requires an explicit `--audience`. Single-repo installs are unchanged.

## Notes

- **Fail-safe, not fail-open.** If the deny gate cannot parse a payload (python3 missing/broken),
  it **denies handoff-doc edits** with an actionable reason and never blocks ordinary files — the
  opposite of the reference's silent no-op. Combined with the install-time preflight, a broken
  enforcement surfaces instead of vanishing.
- **Self-maintaining leases.** `sessionstart` auto-reaps expired leases; `posttool-edit`
  auto-touches the current session's leases so active work never expires mid-flight. `touch`/`reap`
  remain manual escape hatches.
- **`done` is evidence-gated.** `release --status done` requires `--verified-by "<how>"` and
  refuses to trust-close. An optional `verify:` command is **never auto-run** (a cross-repo doc is
  untrusted); it runs only with `--run-verify` + the install opt-in, and only for a local doc.
- **Two invariants, ported intact.** Ownership lives only in gitignored `.locks/`; durable state
  only in frontmatter — they cannot desync. `INDEX.md` is generated and never hand-edited.
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
  outstanding.
- **Bundled files:** `scripts/setup-handoff.sh` (installer), `scripts/detect-handoff.sh`
  (read-only existing-install detector), `scripts/merge-hooks.py` (per-tool JSON merge),
  `scripts/verify-setup-handoff.sh` (verifier), `scripts/payload/` (the
  `.agents/handoff/` payload: `handoff` → board root, `hooks.sh` → board `scripts/`, `README.md`),
  `assets/handoff-doc-template.md`
  - `assets/handoff-standalone-template.md` (scaffolds for `handoff new` / `new --standalone`), and
    `assets/agents-handoff.md` (the AGENTS.md routing block).
