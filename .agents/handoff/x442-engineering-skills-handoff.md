---
id: x442-engineering-skills-handoff
title: Handoff — x442-skills engineering suite
type: standalone
status: open
created: 2026-07-20
updated: 2026-08-14
note:
---

# Handoff — x442-skills engineering suite

A porting guide and capability overview for adopting the `x442-skills` **engineering** skills into
an internal team skills collection. Eight skills, three groups:

- **Onboarding (setup):** `initial-project` → (`setup-project-tooling`) → `setup-graph-hooks`
- **Operate / extend the graph layer:** `repair-graph-hooks`, `register-cross-repo-graph`
- **Coordinate work (handoff):** `setup-handoff` → `run-handoff`, `register-cross-repo-handoff`

| Skill                         | Status         | Ships                | One-line purpose                                                                                                                                           |
| ----------------------------- | -------------- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `initial-project`             | `stable`       | scripts + references | Set up a project's AI-assistant config around a shared `AGENTS.md`, wiring each tool to load it.                                                           |
| `setup-project-tooling`       | `experimental` | scripts + assets     | Detect language, recommend a category, then scaffold a common base + per-language tooling (commitlint, lint-staged, VS Code, release-it).                  |
| `setup-graph-hooks`           | `stable`       | scripts + assets     | Wire a self-updating code knowledge graph so agents query the graph instead of grepping.                                                                   |
| `repair-graph-hooks`          | `experimental` | markdown only        | Re-check → validate → repair a broken/stale/drifted graph layer. Reuses `setup-graph-hooks`' scripts.                                                      |
| `register-cross-repo-graph`   | `experimental` | scripts + assets     | Declare sibling repos in a per-project `.graph-repos.json` cascade, then sync: register them, merge a graphify graph, rewrite the `AGENTS.md` scope block. |
| `setup-handoff`               | `experimental` | scripts + assets     | Install the lease-based handoff board (`.agents/handoff/`) with per-tool enforcement hooks, topology choice, and legacy migration.                         |
| `run-handoff`                 | `experimental` | markdown only        | The claim → work → release discipline over the installed board; `done` requires live-code evidence.                                                        |
| `register-cross-repo-handoff` | `experimental` | scripts + assets     | Declare groups of peer repos in a `.handoff-repos.json` cascade, then sync a standalone shared board owned by no repo, each member in its own section.     |

Source repo: `x442-skills` — `skills/engineering/`. The catalog is [`skills/README.md`](skills/README.md);
each skill's `SKILL.md` is the authoritative detail. This handoff is the executive summary over them.

---

## 0. What changed since the last sync

Read this first if your collection already carries an earlier port.

1. **v0.10.0 (2026-08-14).** Port from the tag. Full range:
   [v0.9.0...v0.10.0](https://github.com/xyzxyz442/x442-skills/compare/v0.9.0...v0.10.0). Two
   themes, both in `setup-graph-hooks`: **the embedding backend is now discovered rather than
   assumed, and `code-review-graph install` is no longer safe to run bare.**
   **Any OpenAI-compatible embedding server is detected, not just Ollama** (`e942e6a`).
   `setup-embeddings.sh` knew one backend; it now probes each candidate endpoint for its flavor and
   lists every embedding-capable model across all of them. The probe **order** is the part worth
   copying carefully: `/api/tags` looks Ollama-specific but **LM Studio serves it too** (it ships an
   Ollama-compatibility surface), so asking `/api/tags` first misclassifies LM Studio as Ollama —
   and when that Ollama install has no models pulled, you get a backend reported with an empty model
   list and no obvious cause. `/api/v0/models` is served **only** by LM Studio, so it must be asked
   first. `apply_ollama()` is replaced by an `apply_endpoint()` / `apply_named()` dispatch, and
   `unsync_mcp_env()` now clears stale env from **both** MCP config shapes. **Re-port
   `setup-embeddings.sh` and `graph-hooks/core/embed-provider.sh`.**
   **A new `embed-health.sh` owns the definition of "this repo's embedding config is wrong"**
   (`d7fc319`). Embeddings are configured in three places and are only correct when all three agree:
   the **write** path (`.code-review-graph/embed.env`, read by the refresh hooks), the **index** (the
   provider identity recorded on the rows), and the **read** path (the MCP server's own env block in
   `.mcp.json` / `.vscode/mcp.json`). Every way they can disagree fails silently — a write/index
   split re-embeds every node on every refresh forever, an unreachable endpoint makes each embed a
   no-op, and a read-path mismatch leaves a graph full of vectors `semantic_search` never looks at,
   because CRG's OpenAI provider raises without `CRG_OPENAI_*` and the tool swallows that into a
   keyword-mode answer. The check now has **one** definition: `verify-graph-hooks.sh` renders it as
   `[warn]` lines and `session-context.sh` as a session-start notice, both asking the script rather
   than reimplementing the comparison, because two copies of "what counts as drifted" drift. Codes
   are `drift | unreachable | readpath | cwd`; it never imports torch, never calls the embedder, and
   always exits 0 — an unhealthy embedding config is a warning, never a failure. **Port the new
   `graph-hooks/core/embed-health.sh`, and re-port `session-context.sh` and
   `verify-graph-hooks.sh`.**
   **`code-review-graph install` must be scoped to the tools you wired** (`ef1bfb1`, `9ac6ff1`).
   Step 7 offered the bare command, which defaults to `--platform all`. In this repo that configures
   **14 platforms** — Codex, Cursor, Windsurf, Continue, OpenCode, Kiro, Qoder, CodeBuddy and the
   rest — creates rule files for tools the repo never chose (`.cursorrules`, `.windsurfrules`,
   `QODER.md`, `CODEBUDDY.md`, `.kiro/steering/`), injects its own instruction block into
   `CLAUDE.md` / `AGENTS.md` / `GEMINI.md`, generates four `.claude/skills/` skills, and merges **its
   own hooks** into `.claude/settings.json` alongside a git `pre-commit` hook. Two of those are
   outright conflicts with this suite: the injected instructions compete with the `AGENTS.md` block
   step 5 manages, and the hooks are a **second refresh owner** — the duplicate-rebuild problem the
   single-owner rule exists to prevent. `--platform` takes one value and is **not repeatable**, so
   the skill now runs it once per chosen tool with `--no-hooks --no-instructions --no-skills`, and
   ships the tool → platform mapping (`claude-code` / `gemini-cli` / `copilot` / `antigravity`). The
   same bare command was also `repair-graph-hooks`' "MCP not registered" remedy — a repair skill
   prescribing the drift it exists to fix — and is scoped there too. **Re-port
   `setup-graph-hooks/SKILL.md` step 7, `setup-graph-hooks.sh`, `verify-graph-hooks.sh`, and
   `repair-graph-hooks/SKILL.md`.**
   One CRG quirk to expect while verifying that port: `--dry-run` prints its "Graph instructions will
   be injected into:" preview **before** it honours `--no-instructions`, so the list still appears in
   a dry run. A real run prints `Skipped instruction injection (--no-instructions)` and writes none
   of them.
   **Also dropped: `graphify hook install`** from the build guide. The `post-commit` hook this suite
   installs already backgrounds `graphify update .`, so graphify's own hook is a second refresh owner
   for exactly the same reason — it was documented in one place while `setup-graph-hooks/SKILL.md`
   forbade it in another.
2. **v0.9.0 (2026-08-04).** Port from the tag. Full range:
   [v0.8.0...v0.9.0](https://github.com/xyzxyz442/x442-skills/compare/v0.8.0...v0.9.0). One theme,
   in `setup-graph-hooks`: **the graph routing block was wrong, and the embeddings index had no
   owner.**
   **Routing is now by intent, not by failure** (`09a544d`). The block every repo carries said
   _"CRG first, graphify on miss, grep last"_. That chain cannot fire: `semantic_search_nodes_tool`
   is pure top-_k_ with **no minimum-score threshold**, so it never returns zero and the "on miss"
   branch was unreachable — while low-quality hits were consumed as if they were answers. The table
   is now keyed by **intent** (targeted lookup / structure / exploration / exact text), graphify is
   an exploration lane reached up front rather than a CRG fallback, and a meaning-based search that
   does not answer routes to `grep`, not graphify. **Re-port
   `setup-graph-hooks/assets/agents-knowledge-graph.md` and
   `scripts/graph-hooks/core/session-context.sh`.**
   **Step 5 now refreshes the block instead of only appending it.** Previously the injector skipped
   any repo that already had `graph-hooks:begin`, so a routing fix could never reach an existing
   install — the verifier could only warn. It now swaps the span between the markers and leaves
   everything around it alone. **This is the change that makes every future block revision
   portable**; without it your collection would need a manual edit per repo. Re-porting `SKILL.md`
   step 5 is the highest-value part of this release.
   **Say which `search_mode` answered.** There is no similarity floor and there will not be one:
   the score CRG returns is a boosted RRF rank, not a cosine similarity, so there is nothing
   well-defined to threshold. Instead the block now tells agents to read the `search_mode` field
   CRG already returns (`semantic` | `fts` | `keyword`). Tier is what a repo _can_ do; `search_mode`
   is what a query _did_. Degrading below the live tier means the vectors did not answer — the one
   case where grep is the right next step.
   **One embedder owns the embeddings index** (`09a544d`). CRG re-embeds a node whose provider
   identity changes, so a completed switch converges — but rows autocommit, so an **interrupted**
   switch splits the table between two embedders. Mixed vector families are incomparable,
   `EmbeddingStore.count()` ignores provider, and `_cosine_similarity` returns `0.0` on a width
   mismatch instead of raising, so a split index degrades every later search **silently**, behind a
   healthy-looking embedding count. `setup-embeddings.sh` now clears foreign vectors before a
   switch and **refuses to embed if it cannot** (an exclusive write lock — the end-of-turn refresh
   embeds in the background — blocks the read too, and treating that as "nothing to clear" was the
   subtle version of the same bug). `verify-graph-hooks.sh` previously reported only the _most
   common_ provider, which hid the split outright; it now groups every provider, **FAILs** on more
   than one, and warns when the recorded identity has drifted from `embed.env`. **Re-port
   `setup-embeddings.sh` and `verify-graph-hooks.sh`.**
   Note CRG's own `refresh_embeddings()` is **not** the migration tool — it refuses when the
   recorded identity differs from the requested one, which is exactly what a switch is. It guards
   same-identity refreshes; migrating is the skill's job.
   **Not changed, deliberately:** `grep-steer.sh`. Its ladder is FTS5/`LIKE` over node names plus
   usage edges — it has never run semantic search, and it reads `graphify-out/graph.json` inline as
   a parallel source rather than shelling out on a miss. If you carry a port of it, leave it alone.
   **`OLLAMA_KEEP_ALIVE` is documented, not wired**: it is read by `ollama serve`, and Ollama's
   OpenAI-compatible `/v1/embeddings` ignores a per-request `keep_alive` (native `/api/embed`
   honours it; CRG sends it on neither), so writing it into `embed.env` would be a no-op that looks
   like a fix.
3. **v0.8.0 (2026-08-04).** Tagged and pushed — port from the tag. Full range:
   [v0.7.0...v0.8.0](https://github.com/xyzxyz442/x442-skills/compare/v0.7.0...v0.8.0). Three themes:
   handoff frontmatter that survives a strict YAML parser, multi-group dogfooding, and a release-it
   changelog fix.
   **Handoff frontmatter is now valid YAML in every field** (`bdc6e41`, `c947dfa`, `3dff07e`). Three
   related defects, all in `setup-handoff/scripts/payload/`. First: `note`, `audience`, `severity`
   and the `blocked_on` `external: …` escape hatch were written unquoted, so a colon in any of them
   turned the line into a nested mapping and broke the doc for every parser — markdown preview
   included. All are now folded to an em dash, exactly like titles. **What you type does not change**
   (`--blocked-on "external: vendor ticket"` still works); only the stored value becomes
   `external — vendor ticket`, and the em-dash spelling is accepted on input too. Second: `verify:`
   is the one field that _cannot_ be folded — folding corrupts a shell command — so it has to be
   quoted, but `meta()` handed the quotes to `eval` and a correctly quoted command died with
   "command not found". `meta()` now strips one surrounding quote pair, in the CLI **and** in
   `hooks.sh` (both copies, or the gate and the tool disagree). **Quote your `verify:` commands.**
   Third: `doc_is_local()` read the doc template's own `repos: []` as "belongs to another repo", so
   `--run-verify` was unreachable for every doc the CLI creates; it also failed **open** twice — a
   block-list `repos:` naming other repos read as local, and `REPO_NAME=api` matched a doc scoped to
   `[api-gateway]`. Both of those now narrow the gate. **Re-port
   `setup-handoff/scripts/payload/{handoff,hooks.sh,README.md}` and `run-handoff/SKILL.md`.** No
   migration is needed for docs you already have: unquoted values keep being read, only newly
   written ones are folded.
   The v0.7.0 cross-repo work is now
   **dogfooded at multi-group scale**: this repo is one of four repos on a live shared board that
   hosts **three sub-indexed sections** (one group of 3 repos / 6 docs, one of 1 repo / 26 docs,
   and a third with **no wired repos** / 43 docs), and `verify-cross-repo-handoff.sh` reports
   **13 passed / 0 warnings / 0 failed** across the cascade, the board, and every member. Three
   things that only showed up under real use: a group **needs no member repos** (docs are authored
   board-side and routed by `audience` to repos that are not on the board — the shape to use for work
   in repos you have not onboarded); **regrouping is a manifest edit, not a migration** (moving one
   repo into its own group re-scaffolds the section, re-points its hooks, and silently re-renders
   every peer table, because peers are group-mates — existing docs do **not** follow the repo); and
   the fleet verifier checks that a peer block is present and correctly scoped but **not its
   contents**, so let the sync own that block rather than hand-editing it.
   **`setup-project-tooling` — release-it wrote an extension-less `CHANGELOG`.**
   `assets/release-it.json` has carried `"infile": "CHANGELOG"` since the skill landed. The
   conventional-changelog plugin writes markdown to exactly what that names, extension and all, so
   **every repo scaffolded from the asset got a file named `CHANGELOG`** — plain text on GitHub, and
   invisible to every markdown-keyed tool downstream. Nothing else in the skill agreed with it (the
   sibling `.prettierignore` protects `CHANGELOG.md`; `SKILL.md` says `CHANGELOG.md`), and dogfooding
   could not catch it because this repo's own `.release-it.json` had diverged to `CHANGELOG.md` — the
   broken value was only ever exercised by _users_ of the skill. Fixed, and the verifier now reads the
   plugin's `infile` and **warns** when it has no `.md` extension — warn, not fail, since the path is
   the repo's to choose. **Re-port `setup-project-tooling/assets/release-it.json` +
   `scripts/verify-project-tooling.sh`**, then check any repo you already scaffolded for a stray
   extension-less `CHANGELOG` (rename it and point `.release-it.json` at `CHANGELOG.md`).
   **New reference doc — a worked multi-repo, multi-group board install.**
   `docs/cross-repo-handoff-usage-record.md` records a real four-repo install end to end: the
   `.handoff-repos.json` actually used, the hook command the sync generates (`HANDOFF_REPO` /
   `HANDOFF_HDPATH` / `HANDOFF_GROUP`, and why identity lives on the command rather than in the shared
   board config), the full `subfolder` vs `prefix` path table (doc / archive / sub-index / leases /
   roll-up — this is also the answer to "can two groups reuse an id?"), what group isolation actually
   means in the order it bites, and the gotchas the install cost us (`GROUPS` is a bash builtin, hence
   `HANDOFF_GROUPS`; the hook merge needs the `--kind` discriminator; generated `INDEX.md` files must
   be excluded from prettier). It is the handoff layer's counterpart to
   `docs/graph-tools-during-development.md` — **ship it alongside the handoff skills** the same way
   §6 recommends for the graph doc. Copy list in §4.1, summary in §6.
   **The `--blocked-on` gap is now closed** (`781f450`). `release --status blocked` validated the
   blocker's existence by building its path at the **board root**, which on a `subfolder`-layout board
   holds no docs — so every blocker id was rejected and `blocked` was unreachable on any grouped
   board. It now resolves through the section-aware `doc_file`/`arch_file`. Earlier ports told the
   team to record blockers in the doc body as a workaround; that advice can be retired. **Re-port
   `setup-handoff/scripts/payload/handoff`.** (Filed and closed on the shared board as
   `handoff-blocked-on-ignores-section-handoff`.)
   **Graph status probes no longer report live vectors as keyword mode** (`01b0064`). The session
   cheatsheet's `search tier:` line is what tells an agent whether a shallow `semantic_search_nodes`
   result is a quality signal or an availability one, so a probe that mislabels a working vector tier
   as `keyword` pushes agents back to grep for no reason. **Re-port the `setup-graph-hooks` probe.**

4. **suite v0.7.0 (2026-07-27).** Four themes; full range:
   [v0.6.0...v0.7.0](https://github.com/xyzxyz442/x442-skills/compare/v0.6.0...v0.7.0). Re-verified
   on this repo's live board immediately before the release was cut: `setup-handoff` 116/116 grader
   assertions across 11 evals, `run-handoff` 12/12, the new `register-cross-repo-handoff` grader
   32/32 across 2 evals, and the live-board verifier 18 passed / 0 failed.
   **New skill — `register-cross-repo-handoff` (`experimental`).** Declare groups of peer repos in a
   per-workspace `.handoff-repos.json` cascade (user → workspace → subdirectory, the same shape as
   `AGENTS.md` and `.graph-repos.json`), then sync: it scaffolds a **standalone shared board owned by
   no repo** and wires every member to its own sub-indexed section. There is deliberately **no seed**
   — the board is not copied out of whichever project happened to go first, which is the failure the
   cross-repo identity fix in v0.5.0 only half-solved. Chains after `setup-handoff`. This is a **new
   port**: copy `skills/engineering/register-cross-repo-handoff/` whole (SKILL.md + `scripts/`).
   **Boards can now carry sub-indexed sections.** The payload understands board **sections** via
   `HANDOFF_GROUPS` + `HANDOFF_GROUP_LAYOUT` (`subfolder` | `prefix`) in the committed board config,
   with each consumer's own section threaded per-repo as `$HANDOFF_GROUP` in its hook command. An
   invocation only ever acts inside its own section; `INDEX.md` becomes a roll-up across all of them.
   **A flat single-repo board is byte-identical** — with neither key set, every section helper
   collapses to today's paths, so nothing changes for an existing install until you opt in.
   `setup-handoff.sh --board-only <path>` scaffolds a shared board with no per-tool wiring and no
   `AGENTS.md` edit. Two hook-merge fixes ride along: `merge-hooks.py` now recognizes our hooks on
   **any** board name (not just `.agents/handoff`), and the hook discriminator requires `--kind`, so
   merging no longer strips a foreign tool's hook group. Re-port `setup-handoff/scripts/` (incl.
   `merge-hooks.py`, `setup-handoff.sh`, `verify-setup-handoff.sh`) + `scripts/payload/`.
   **Handoff CLI — an unresolvable id is a hard error, not a half-success.** `claim`/`release` on an
   id with no doc behind it used to print `no such handoff`, then carry on: `claim` created a real
   lock directory for the phantom, both sprayed `sed: : No such file or directory`, and the command
   **still exited 0**, so no caller or hook could detect it. Cause: the resolver ended in `die`, but
   every caller runs it inside `$( )` where `exit` leaves only the subshell, and the script runs
   `set -uo pipefail` without `-e`. It now reports failure by exit status, callers hard-fail, and the
   lock key is derived only after the doc resolves. Because the automatic `-handoff` suffix makes a
   "short" id fold to a phantom (`foo` → `foo-handoff` while the real doc is `foo-backend-handoff`),
   the error also names the near misses on the board. Reported from a downstream board; if you ported
   the payload before, **re-port `scripts/payload/handoff`** — installs on the old build are affected.
   **`setup-project-tooling` — git hygiene and a safer bootstrap.** The skill now owns a
   `.gitattributes` baseline alongside `.gitignore` (with guidance on sizing a renormalize before you
   run one), and `initialize.sh` no longer hard-fails the VS Code folder-open task in a base-only repo
   that merely contains `.py` files — Python bootstrap is gated on the Python module actually being
   wired, not on a stray file match. Out of the handoff scope but in the same release; re-port
   `setup-project-tooling/assets/` + `SKILL.md`.

5. **suite v0.6.0 (2026-07-23).** Four themes; full range:
   [v0.5.0...v0.6.0](https://github.com/xyzxyz442/x442-skills/compare/v0.5.0...v0.6.0). Re-verified
   on this repo's live board immediately before the release was cut: `setup-handoff` 97/97 grader
   assertions across 10 evals, `run-handoff` 12/12, the new `release-announcement` grader 12/12 on
   its compliant fixture (with both deliberately non-compliant fixtures correctly rejected), and
   the live-board verifier 18 passed / 0 failed.
   **Board layout + a third handoff type (`orchestrator`).** The board payload is restructured —
   `hooks.sh` lives in `scripts/`, the doc templates in `templates/` — and the installer migrates
   an existing flat board in place; old hook groups are recognized as ours and rewritten (a new
   `layout-migration` eval guards the exact path). The new **`orchestrator`** type indexes a
   bundle: `handoff new <id> --orchestrator --children a,b,c`. It holds no work of its own and is
   never claimed; `list` derives live progress (`2/3 done`) from each child's own status, and
   `release --status done` refuses while any child is outstanding. Ids are now **enforced
   lowercase kebab-case** (any input folds to it), and a `:` in a `--title` (or in the H1 that
   `import` derives a title from) folds to `—`, so the unquoted YAML `title:` can never break
   frontmatter parsing again. Re-port `setup-handoff/scripts/` + `scripts/payload/` + `assets/`
   (now incl. `handoff-orchestrator-template.md`) and `run-handoff/SKILL.md`.
   **Graph hooks — search tiers are explicit and vector-first.** The routing block now defines
   three `semantic_search` tiers — **custom → local → keyword** — tells agents to prefer the
   richest available and to _state which tier backed an answer_; the live tier is announced at
   session start and every grep pre-answer is marked `[search tier: …]`. Keyword mode remains the
   supported floor (the §4.4 caveat stands unchanged). Re-port `setup-graph-hooks/scripts/` (the
   `graph-hooks/core/` payload incl. `embed-provider.sh`, `grep-steer.sh`, `session-context.sh`)
   - `assets/agents-knowledge-graph.md`.
     **`setup-project-tooling` — husky wiring is one committed dispatcher, not an echo chain.** The
     old fan-out of `package.json` scripts echoing shell fragments into `.husky/` is replaced by a
     single committed `scripts/husky.sh` sub-command dispatcher, installed by an **`install:dev`**
     script — deliberately **never `prepare`**, which is an npm lifecycle script that fires on plain
     installs and inside CI/DevOps pipelines where hook installation has no business running.
     Re-running the skill migrates old `prepare` wiring and deletes the entry; the verifier accepts
     either shape. Python repos now run their toolchain through a `scripts/py-tool.sh` resolver (uv
     or pipx when present, `.venv` fallback with pinned versions). Re-port
     `setup-project-tooling/SKILL.md` + `assets/` (new `husky.sh` and `py-tool.sh`, updated
     `initialize.sh` and `prettierignore`).
     **New `productivity` category — `release-announcement` (`experimental`).** The first skill
     outside the engineering suite: it turns an already-cut release (tag + changelog) into a
     channel-shaped announcement grouped by user-visible theme, with hard rules on attribution
     (never name a non-public upstream), explicit status changes, no overstated guarantees, and no
     invented numbers. Its harness workspace is the harness's first **text-output** grader (the
     skill ships no scripts, so there is no `verify-*.sh` to wrap — the produced `ANNOUNCEMENT.md`
     is graded against the skill's own Rules; see §7). Out of this doc's engineering scope — catalog
     entry in [`skills/README.md`](skills/README.md).

6. **suite v0.4.0–v0.5.0 — two new skills: `setup-handoff` + `run-handoff` (handoff coordination).** The suite
   gains a lease-based **handoff board** for multi-agent / cross-session / cross-repo work: _claim
   before you edit, release when you stop, `done` only when verified against live code._
   `setup-handoff` installs the tool-generic `.agents/handoff/` payload, wires per-tool enforcement
   hooks (you pick one **primary** tool for the hard `deny` gate; others get advisory board-injection),
   and can **detect + migrate a legacy `.claude/handoff/`** install to the generic path (current
   repo-level, a parent-level shared dir, or a specific `--handoff-dir`). `run-handoff` is the
   every-session discipline. Both are `experimental`. This is a **new port** (not a re-copy) — see §2,
   §4.1, §4.3. Ported and hardened from a battle-tested reference; the port fixes two of its defects
   (the lease now records `session=` so the ownership gate actually denies, and the installer really
   registers the enforcement hooks). **Doc-authoring is also hardened:** because a handoff doc is
   **committed to the repo and its git history** (unlike a throwaway temp-dir handoff), the template,
   the `handoff` script output (`new` + `release --status done`), the `AGENTS.md` routing block, the
   payload README, and `run-handoff` §3 now carry a **redaction rule** (never paste keys/secrets/
   passwords/PII — if a credential is truly needed, prompt the user and record only its _name_ via a
   safe channel: env var / secret-manager ref / out-of-band), a **`## Suggested skills`** section, and
   a **link-don't-duplicate** note. Guidance, not a hard gate — redaction can't be mechanically
   verified. If you already ported these two skills, **re-port `setup-handoff/assets/` +
   `scripts/payload/` and `run-handoff/SKILL.md`**; leases, enforcement, and mechanics are unchanged.
   **Now typed:** every handoff carries a `type:` — `coordination` (default, the lease-gated work
   item) or `standalone` (a self-contained reference/knowledge doc: porting guide, eval report,
   compaction brief). A **standalone** doc is **gate-exempt** — freely editable with no lease, `claim`
   refuses it, it is listed apart, and it retires via `release --status done` **without**
   `--verified-by`. Absent `type:` ⇒ `coordination`, so existing boards are unaffected. New surface:
   `handoff new --standalone` and `handoff import <file>` (bring an existing file onto the board).
   This very doc is a migrated standalone handoff; its sibling
   [`handoff-types-eval-report`](./archive/doc-types-eval-report-handoff.md) records the eval run (60/60 graders,
   verifier 18/18). To adopt: **re-port `setup-handoff/assets/` (now incl.
   `handoff-standalone-template.md`) + `scripts/payload/` + `scripts/setup-handoff.sh`, and
   `run-handoff/SKILL.md`.**
   **Cross-repo shared board fixed:** a board genuinely shared by N repos no longer bakes one repo's
   identity into its committed `config` (the last installer used to clobber every sibling). Identity
   is now **per-consumer** via `$HANDOFF_REPO` (baked into each repo's own hook command); the shared
   `config` carries no `REPO_NAME`; the `AGENTS.md` block + session-start hint are **path-substituted**
   to the real board location (no more hardcoded `.agents/handoff`); the inert consumer `.gitignore`
   `.locks/` line is skipped for cross-repo (verifier is topology-aware); and `handoff new` on a
   shared board **requires `--audience`**. Single-repo is byte-identical. A new **`cross-repo`**
   harness eval (two siblings + a shared parent board) guards the exact regression; sibling
   [`handoff-cross-repo-eval-report`](./archive/cross-repo-eval-report-handoff.md) records the run (73/73
   graders, verifier 0-failed on both topologies). Re-port `setup-handoff/scripts/` (incl.
   `merge-hooks.py`, `verify-setup-handoff.sh`) + `scripts/payload/` + `assets/agents-handoff.md`.
   **File naming — `<id>-handoff.md`:** every board doc is now named `<id>-handoff.md` and the **id is
   the filename stem** (`handoff new rbac-gap` → `rbac-gap-handoff.md`, id `rbac-gap-handoff`; the tool
   auto-appends `-handoff` idempotently, and `claim`/`release` take the short or full id). A file is a
   handoff doc **iff** it matches `*-handoff.md` — this whitelist replaces the INDEX/README/template
   blacklist and structurally kills the template-leak bug class. Existing board docs (and the harness
   legacy fixture) were migrated to the suffix; `blocked_on` references are canonicalized too. All 11
   evals stay green (setup-handoff 61/61 incl. cross-repo 13/13, run-handoff 12/12). Re-port
   `scripts/payload/{handoff,hooks.sh}` and rename any existing board docs to `*-handoff.md`.
7. **suite v0.3.1 (`setup-graph-hooks` embeddings offer now fires reliably).** Step 8's
   semantic-search offer was framed so heavily as "optional, never assumed" that an assistant
   would skip the `AskUserQuestion` prompt entirely and degrade to an unmentioned "optional
   step" — observed with GitHub Copilot as the resource owner. Fixed: surfacing the choice is now
   **required** (only _enabling_ embeddings stays optional), with an explicit non-interactive
   fallback (print `setup-embeddings.sh --list` state + the `--provider` commands, keyword mode
   until the user runs one) and a short-circuit when a provider is already configured. **Mechanics
   are unchanged** — `setup-embeddings.sh`, the `local`/`ollama`/`off` providers, and `embed.env`
   are byte-identical — so this is a **wording-only re-port**: re-copy `setup-graph-hooks/SKILL.md`
   §8. See §2 (`setup-graph-hooks`) and §4.4 embeddings caveat, both otherwise unchanged.

8. **`register-cross-repo-graph` was redesigned and is now a replacement, not an increment.** It went
   from markdown-only (ad-hoc `code-review-graph register` calls) to a **declared, committed
   `.graph-repos.json` manifest cascade** (user → repo → subdir, nearest wins, like `AGENTS.md`)
   applied by `sync-cross-repo-graph.sh`, with a real verifier and a shared Python resolver. It also
   now gets a **per-project** graphify merged graph instead of writing graphify's global one. **Delete
   the old version rather than merging into it.** See §2 and §4.1.
9. **A `.gitignore` bug that silently truncates the port.** An unanchored `MANIFEST` rule (from the
   stock Python template) matches the new `scripts/manifest/` **directory** on any case-insensitive
   filesystem, so `git add -A` ships the skill without its resolver. Fixed here in both our
   `.gitignore` and the template `setup-project-tooling` **ships to every scaffolded project**
   (`assets/gitignore` → `/MANIFEST`). **Check your own collection's `.gitignore` before porting** —
   the full check is in §4.1.
10. **Semantic search / embeddings are an opt-in tier**, and keyword mode is the supported default —
    unchanged from the last handoff, but still the most common source of "the graph looks broken" false
    alarms. See the embeddings caveat in §4.4.
11. **The eval harness now covers all seven skills** (was five at the last sync). `harness/` ships a
    self-tested shared library plus a workspace for every skill — the five graph/onboarding skills
    plus the new `setup-handoff` and `run-handoff` — each with fixtures, `evals/evals.json`, and a
    `grade.py` that wraps the skill's own `verify-*.sh` (or, for `run-handoff`, drives the installed
    board). Graders are read-only and LLM-free. The `verify-*.sh` checkers remain the correctness
    source of truth; the harness adds repeatable, gradeable evals on top. See §7.
12. **`verify-cross-repo-graph.sh` now exits 0 on a repo that never opted into cross-repo** (it reports
    a `[skip]`, not a `[FAIL]`). "Not configured" and "broken" are no longer conflated — see §4.3.
13. **Everything else is unchanged.** `initial-project` and `setup-graph-hooks` remain `stable`;
    `setup-project-tooling` and `repair-graph-hooks` are unchanged in behavior.

---

## 1. How the suite chains

Repo onboarding is a short pipeline, then two skills operate/extend the graph layer afterward.

```text
initial-project ──> (setup-project-tooling) ──> setup-graph-hooks
       │                                              │
       │                           ┌──────────────────┴──────────────────┐
       │                           ▼                                      ▼
       │                    repair-graph-hooks               register-cross-repo-graph
       │                    (recover the layer)              (extend: read a sibling repo)
       │
       └────> setup-handoff ──> run-handoff
              (install the board)  │  (operate it every session)
                                   ▼
                          register-cross-repo-handoff
                          (extend: one board, many repos)
```

- **`initial-project` runs first** — it creates the canonical `AGENTS.md` every later skill depends
  on. `setup-graph-hooks` hard-stops if `AGENTS.md` is missing.
- **`setup-project-tooling` is the optional middle step.** Run it **before** `setup-graph-hooks`:
  it installs husky, which moves git's hook path to `.husky/`, and `setup-graph-hooks` is husky-aware
  — it then lands the graph `post-commit` refresh in `.husky/post-commit` instead of `.git/hooks/`.
- **`repair-graph-hooks` and `register-cross-repo-graph` chain after `setup-graph-hooks`.** Both
  assume that skill's wiring already exists. `repair` is markdown-only and invokes `setup-graph-hooks`'
  scripts directly; `register` now ships its **own** scripts + assets (it did not at the last handoff).
- **`setup-handoff` and `run-handoff` are an independent branch off `initial-project`** — they need
  `AGENTS.md` but not the graph layer. `setup-handoff` installs the lease-based handoff board and its
  enforcement hooks; `run-handoff` is the every-session discipline over that board (it ships no
  scripts of its own — it drives the installed `handoff` script). Adopt them with or without the graph
  skills.
- **`register-cross-repo-handoff` chains after `setup-handoff`** and is the handoff-side mirror of
  `register-cross-repo-graph`: it takes repos that already have their own board and points a group of
  them at one **shared** board instead. Optional — a single-repo board never needs it.

---

## 2. Capability overview

### `initial-project` — `stable`

- **Trigger:** initializing or setting up a project's AI-assistant configuration ("init this
  project", "set up Claude/Copilot here").
- **Workflow:** ensure `AGENTS.md` carries a `## Coding guidelines` section (Karpathy text) and a
  `## Commit conventions` section (Conventional Commits, mirroring `commitlint.config.mjs`) → detect
  tools by marker → ask which to wire (multi-select) → wire each chosen tool idempotently → offer to
  hand off to `setup-project-tooling` and then `setup-graph-hooks`.
- **Commit conventions (seeded, always-on):** seeds a `## Commit conventions` section from
  [`references/commit-guidelines.md`](skills/engineering/initial-project/references/commit-guidelines.md)
  — `type(scope): subject`, lowercase imperative, no trailing period, with the allowed type/scope
  enums. Names `commitlint.config.mjs` as the enforced source of truth; this is the _guidance_ for
  writing commits, while `setup-project-tooling` installs the husky `commit-msg` _enforcement_
  (local-only — see its section; no CI workflow).
- **Supported tools and how each loads `AGENTS.md`:**

  | Tool           | Detect marker(s)                              | Entry file                        | Loads `AGENTS.md` via                                                                            |
  | -------------- | --------------------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------ |
  | Claude Code    | `.claude/`, `CLAUDE.md`                       | `CLAUDE.md`                       | `@AGENTS.md` import                                                                              |
  | Antigravity    | `ANTIGRAVITY.md`, `.antigravity/`             | `ANTIGRAVITY.md` (overrides only) | native read (v1.20.3+) — no import line                                                          |
  | Gemini CLI     | `GEMINI.md`, `.gemini/`                       | `GEMINI.md`                       | `@AGENTS.md` import                                                                              |
  | GitHub Copilot | `.github/copilot-instructions.md`, `.github/` | `.github/copilot-instructions.md` | prose link to `../AGENTS.md` + `.vscode/settings.json` → `chat.agentFilesLocations: {".": true}` |

- **End-state:** `AGENTS.md` (with the two sections); one entry file per chosen tool;
  `.vscode/settings.json` for Copilot. Idempotent — re-running is a no-op for already-wired tools.
- **Ships:** `scripts/verify-initial-project.sh`, `references/karpathy-guidelines.md`,
  `references/commit-guidelines.md`.

### `setup-project-tooling` — `experimental`

- **Trigger:** setting up project dev tooling — "set up commitlint", "add lint-staged", "wire
  prettier/husky", editor settings, or release automation. Chains after `initial-project`.
- **Model — detect → recommend → common base + per-language layers:**
  1. **Detect** the package manager (from the lockfile; defaults to npm) and language (from
     `tsconfig.json`/`*.ts`, `pyproject.toml`/`*.py`, `*.sql`, `*.csproj`, `Chart.yaml`, …).
  2. **Recommend a category** (frontend / backend / library / other) for the user to **confirm** —
     category is _lightweight_, setting only the release-it default and framework expectation; the
     **language** drives the lint/format fragments.
  3. Apply a **common base** every repo gets, then layer the detected **language module** on top.
- **Fully supported languages:** **Python** (black formatter) and a **Python-stream** Flink-SQL flavor
  (sqlfluff, dialect `flink`), and **Node/TypeScript strict** (prettier + eslint; NestJS/Next.js are
  framework touches, not separate modules). Any other language (C#, Helm, Go, Rust, …) gets the
  **common base only** — the user fills in the language config from there.
- **Common base (every repo):** a `package.json` `prepare` hook chain that regenerates the gitignored
  `.husky/commit-msg` + `.husky/pre-commit` on install; `commitlint.config.mjs`; a base
  `.lintstagedrc.json` (`*.{json,yml,yaml,md}` → prettier), `.prettierrc`/`.prettierignore` (with
  `prettier-plugin-sh` for shell); a base `.editorconfig`; `.vscode/` settings/extensions/tasks; a
  base `.gitignore`; and optional `release-it`.
- **Workspace bootstrap — `initialize.sh` (new):** a committed, idempotent script copied to the repo
  root and wired to a `.vscode/tasks.json` **Bootstrap Workspace** task that runs on folder-open. It
  is package-manager aware (`<pm> install`, provisioning yarn/pnpm via corepack), repairs husky hooks
  by re-running `prepare`, and for Python bootstraps a `.venv` (uv-first, pip fallback) with black
  (and sqlfluff when `*.sql` is present).
- **Commit enforcement is local-only:** the husky `commit-msg` hook runs commitlint against
  `commitlint.config.mjs`. **No CI workflow** — the previous `commitlint.yml` GitHub Action was
  removed; enforcement is the local hook (or the committed-hook fallback).
- **Node-rooted:** husky, commitlint, lint-staged, and release-it live in `package.json` even for a
  Python/SQL repo (a minimal `package.json` is created if absent). Python tools (black, sqlfluff)
  install into `.venv` via **uv (preferred) or pip**, not npm.
- **Ships:** `scripts/verify-project-tooling.sh` and a layered `assets/` tree — `initialize.sh`,
  `commit-msg`, `commitlint.config.mjs`, `gitignore`, `prettierrc`, `prettierignore`, `release-it.json`,
  `sqlfluff`, `tasks.json`, and per-language fragments under `editorconfig/`, `lintstaged/`, and
  `vscode/` (`base` + `nodejs` + `python` + `python-stream`).

### `setup-graph-hooks` — `stable`

- **Trigger:** immediately after `initial-project`, or whenever the user mentions a code knowledge
  graph, graph hooks, code-review-graph, graphify, smart-grep, or blast-radius/impact analysis.
- **Architecture — three layers:**
  1. **Universal (always):** `.graph-hooks/` shared behavior cores + dispatcher, a git `post-commit`
     refresh (husky-aware), `.gitignore` entries, `.code-review-graphignore` / `.graphifyignore`, and
     the `<!-- graph-hooks -->` routing block appended to `AGENTS.md`.
  2. **Shared behavior cores:** `grep-steer.sh`, `read-nudge.sh`, `session-context.sh`,
     `graph-refresh.sh` (the incremental `update`), `embed-provider.sh` (the embeddings gate) and
     `embed-health.sh` (the one definition of embedding-config drift)
     under `.graph-hooks/core/`, dispatched by `.graph-hooks/hook.sh`. The per-tool stdin/stdout
     protocol lives once in `core/extract.py` + `core/emit.py`.
  3. **Per-tool hook config:** rendered by `config/render.py` and merged into each tool's native
     settings file (replacing only the hooks subtree). Only the **primary** tool gets the end-of-turn
     refresh, so N wired tools never trigger N graph builds.
- **Per-tool support:**

  | Tool           | Config file                  | Pre-tool event | Session        | End-of-turn  | Status            |
  | -------------- | ---------------------------- | -------------- | -------------- | ------------ | ----------------- |
  | Claude Code    | `.claude/settings*.json`     | `PreToolUse`   | `SessionStart` | `Stop`       | active            |
  | Gemini CLI     | `.gemini/settings.json`      | `BeforeTool`   | `SessionStart` | `AfterAgent` | active            |
  | GitHub Copilot | `.github/hooks/graph.json`   | `preToolUse`   | `sessionStart` | `agentStop`  | active            |
  | Antigravity    | `.agents/hooks.json.example` | `PreToolUse`   | —              | —            | **inert (gated)** |

  **Antigravity is gated:** the hook contract is unverified, so the installer writes an inert
  `.agents/hooks.json.example` and never activates it. Antigravity still gets the universal layer
  (git refresh + AGENTS.md routing). To activate later, verify the contract against a live install and
  rename the example to `.agents/hooks.json`.

- **Semantic search / embeddings — an OPT-IN tier (important):** the default build is
  `code-review-graph build` with **no `embed`**. With an empty embeddings table,
  `semantic_search_nodes_tool` falls back to **keyword search over symbol names** — a supported,
  healthy state, _not_ a degraded one. Nothing in `setup-graph-hooks` installs PyTorch.
  - Opting in is a separate script, `scripts/setup-embeddings.sh` (never called by the installer):
    `--list` prints the machine's state (Ollama up/down + embedding-capable models,
    `sentence-transformers` present, current provider); `--provider local|ollama|off` applies a
    choice non-interactively. Run `--list`, then ask — the bare command is an interactive TTY menu.
  - **`local`** — CRG's own default provider, so the MCP server reads the vectors as-is with no
    further wiring. Costs ~2 GB of PyTorch plus a one-time ~90 MB model fetch; no daemon.
  - **`ollama`** — skips the PyTorch install but needs a resident daemon, and the vectors are only
    readable if the MCP server gets `CRG_OPENAI_*` in its environment **and** every call pins
    `provider="openai", model=<name>`. The script wires the first into `.mcp.json` (localhost) and
    prints the second.
  - **`off`** — keyword mode; the correct default when the user has no preference.
  - The choice is written to **`.code-review-graph/embed.env`** — repo-local, not shell-local, so a
    commit from a GUI git client (which inherits no shell rc) still refreshes vectors.
  - **The refresh knows.** `core/embed-provider.sh` resolves the provider (`embed.env` → cloud env
    var → the provider already recorded in the `embeddings` table) and prints nothing when there is
    none, so `graph-refresh.sh` and `post-commit` skip `embed` entirely. It probes with `sqlite3`, so
    it never imports torch. **Asymmetry:** a repo embedded with `local` refreshes with no config at
    all; Ollama/cloud providers _require_ `embed.env` or CRG raises `ValueError`.
  - The verifier reports the tier: keyword mode is a `[PASS]`; a partial embed, or vectors nothing
    can refresh, is a `[warn]`.
- **End-state:** `.graph-hooks/` payload; `.husky/post-commit` or `.git/hooks/post-commit`;
  `.gitignore`; the two ignore files; per-tool config files; the `AGENTS.md` routing block. Idempotent
  and non-destructive. (`.code-review-graph/embed.env` only if embeddings were opted into.)
- **Ships:** `scripts/` (installer, `setup-embeddings.sh`, verifier, `post-commit`, `graphignore`,
  `config/`, and the `graph-hooks/` payload incl. `core/embed-provider.sh` and
  `core/embed-health.sh`) +
  `assets/agents-knowledge-graph.md` (the routing block, which now tells agents that
  `semantic_search_nodes_tool` works with or without vectors — "do not reach for grep because a
  result looked shallow").

### `repair-graph-hooks` — `experimental` (markdown-only)

- **Trigger:** the graph tools "aren't working" (empty/stale results, MCP errors, a hook that never
  fires), `verify-graph-hooks.sh` reported a `[FAIL]`/`[warn]`, a tool was dropped/added, or a
  new-machine/Windows checkout broke a hook. **Not** for first-time setup — if `.graph-hooks/` is
  absent, run `setup-graph-hooks`. **Not** for keyword-quality `semantic_search` hits on a repo that
  never opted into embeddings — that is the designed fallback, not a fault.
- **What it adds over the read-only verifier:** it is the recovery counterpart. The verifier only
  _reports_ health and re-running the installer fixes only a subset; this skill adds **tool-integrity
  smoke-tests** (does the CRG/graphify binary actually _run_, not just resolve on `PATH`) and
  **graph-state probes** (staleness vs `HEAD`, DB integrity / zero-node, embeddings state,
  Ollama-daemon reachability, ignore-file drift, exec-bit/CRLF breakage, `.gitignore` leak, stale
  refresh locks, settings.local vs settings.example divergence) that neither script performs.
- **Embeddings — three states, only two are defects** (compare `count(embeddings)` against
  `count(nodes WHERE kind!='File')`):
  - **zero** → keyword mode. Report it; **do not offer a fix**. Point at `setup-embeddings.sh` only
    if the user actually wants semantic search.
  - **partial** (`0 < embeddings < nodes`) → an `embed` was interrupted. Flag and offer a re-embed.
  - **unrefreshable** → vectors exist but `embed-provider.sh` resolves nothing (usually `embed.env`
    was deleted while the graph carries `openai:`/`google:` vectors), so the hooks skip `embed` and
    the vectors drift. Fix: restore `embed.env` or re-embed with `local`.

  It also flags an **Ollama-backed provider whose daemon is down** — embeddings will never refresh
  and nothing else surfaces it.

- **Procedure:** (0) tool-integrity smoke first → (1) reuse `verify-graph-hooks.sh` → (2) graph-state
  probes → (3) safe auto file/wiring repair (reconstruct the historical `--tools` set, back up +
  JSON-validate each config, re-run the installer, re-sync ignore files, clear stale locks) → (4)
  **offer** (never auto-run) the heavy rebuild → (5) re-verify → (6) report.
- **Rebuild/embed nuance:** the offered fixes are `code-review-graph update` (stale) or `build`
  (corrupt/zero-node) — **no `embed` by default**. Offer an embed only on an already-opted-in repo,
  and pass the provider the graph was embedded with, because the bare command defaults to `local`
  and errors on an Ollama/cloud repo:
  `code-review-graph embed --provider "$(bash .graph-hooks/core/embed-provider.sh)"`.
  A full `build` does **not** clear the embeddings table (rows are keyed by `qualified_name`) but
  leaves newly-parsed/renamed nodes unembedded — i.e. the _partial_ state — so on an opted-in repo
  follow a rebuild with the embed.
- **Reuse, not duplication:** the wiring detector is `setup-graph-hooks`' `verify-graph-hooks.sh` and
  the file/wiring repair is that skill's own idempotent installer — this skill orchestrates them and
  adds the two new layers on top. **No-op on a healthy repo.** Clears only empty lock dirs (`rmdir`,
  never `rm -rf`); never deletes source or force-pushes.

### `register-cross-repo-graph` — `experimental` (scripts + assets)

> **Redesigned since the last handoff.** It was a markdown-only skill that ran ad-hoc `register`
> commands. Scope is now **declared in a committed manifest** and applied by a script. If your team
> already ported the old version, this is a replacement, not an increment.

- **Trigger:** a session in repo A needs a symbol/type/call site that lives in repo B
  (frontend↔backend, shared library, monorepo sibling), and you want the graph to answer instead of
  grepping across the folder boundary — plus a durable in-context pointer so every future session
  knows the sibling graph is queryable.
- **Scope is declared, not imperative.** A `.graph-repos.json` manifest **cascades exactly like
  `AGENTS.md`/`CLAUDE.md`** — lowest precedence first, nearest wins:

  | Layer   | File                                    | Committed | Use for                                     |
  | ------- | --------------------------------------- | --------- | ------------------------------------------- |
  | user    | `~/.code-review-graph/graph-repos.json` | no        | personal siblings, visible to every project |
  | project | `<repo-root>/.graph-repos.json`         | **yes**   | the team-shared sibling list — the default  |
  | subdir  | `<subdir>/.graph-repos.json`            | **yes**   | a monorepo package with its own scope       |

  Each entry is `{alias, path, tools, notes}`; `{alias, remove: true}` is a **tombstone** — the only
  way a nearer layer can un-inherit an entry from a lower one. A relative `path` resolves against
  **the manifest that declared it**, which is what lets a committed `"../acme-api"` mean the same
  checkout on every teammate's machine.

- **One command applies it:** `sync-cross-repo-graph.sh` registers each in-scope repo with CRG
  (additively), rebuilds a **per-project** graphify graph at `graphify-out/merged-graph.json`, and
  rewrites the `<!-- cross-repo -->` block in `AGENTS.md` **from what it confirmed afterwards, never
  from what it intended** — so the block can never advertise a repo that will not answer. Idempotent:
  a second run leaves `git status` clean.
- **The critical design fact — two registries, one scope.** CRG's registry
  (`~/.code-review-graph/registry.json`) is **machine-global and hardcoded**; it cannot be scoped per
  repo. So sync only ever _adds_ to it and never unregisters what it did not create, and
  `cross_repo_search_tool` **will** return hits from your other projects' repos. **Scope is enforced
  in context, not in the registry:** the in-scope alias table in the `AGENTS.md` block is the
  enforcement surface. That is a soft boundary — right for read-only lookup, _not_ a security control.
  (graphify sidesteps this entirely: its merged graph is per-project.)
- **Ships a shared Python resolver** (`scripts/manifest/resolve.py`) that _both_ the installer and the
  verifier call, so the two can never disagree about what the cascade means.
- **Removal:** tombstone the alias and re-sync (it leaves the block, which is what actually narrows
  the agent). `--prune` additionally unregisters — but **only** aliases this repo registered, tracked
  in `.code-review-graph/cross-repo-state.json`; it never touches another project's entries.

### `setup-handoff` — `experimental` (scripts + assets)

> **New port since the last handoff.** No earlier version to merge — copy it wholesale. Hardened from
> a battle-tested reference; the port fixes two of its defects (the lease now records `session=` so
> the ownership gate actually denies; the installer really registers the hooks).

- **Trigger:** the user wants multi-agent / cross-session / cross-repo **work coordination** — a
  handoff board, "claim before you work / release when you stop" leases, tracking who acts next, or
  verifying "done" against live code. Chains after `initial-project`.
- **What it installs:** a tool-generic payload under `.agents/handoff/` — the `handoff` lease script,
  `hooks.sh` (enforcement), a committed `config` (topology + repo name), a doc template, `.locks/`
  (gitignored), and a `<!-- handoff -->` routing block appended to `AGENTS.md`.
- **Ownership is an atomic `mkdir` lock**, never a frontmatter edit. The lease records
  `session=<raw id>`; the enforcement gate matches that against the tool's hook payload — that
  equality is the whole basis of enforcement. Durable state lives only in frontmatter, ownership only
  in `.locks/`; they cannot desync.
- **Per-tool enforcement, one primary.** The user picks **one primary** tool that gets the hard
  `pretool-edit` **deny** gate + `stop` nag; every other wired tool gets `sessionstart` board-injection
  - `posttool-edit` index-regen (advisory). Claude Code's contract is wired precisely; Gemini/Copilot
    use their documented event names best-effort (the `AGENTS.md` block is their behavioral guarantee).
    Payloads are parsed with **python3** (not `jq`).
- **Fail-safe, not fail-open.** If the deny gate cannot parse a payload, it denies handoff-doc edits
  (never ordinary files) with an actionable reason; the installer's **preflight refuses a
  hard-enforcement primary unless `python3` is present**, so breakage is caught at install time.
- **Self-maintaining leases:** `sessionstart` auto-reaps expired leases; `posttool-edit` auto-touches
  the holder's lease so active work never expires mid-flight (`touch`/`reap` remain manual).
- **Evidence-gated `done`:** `release --status done` requires `--verified-by "<how>"`; an optional
  `verify:` frontmatter command is **never auto-run** (a cross-repo doc is untrusted) — it runs only
  with `--run-verify` + the install opt-in `HANDOFF_ALLOW_VERIFY_CMD=1`, and only for a local doc.
  `blocked` requires `--blocked-on`, and closing a blocker surfaces its dependents as unblocked.
- **Topology + location:** single-repo (default, in-repo, no `audience` routing) or cross-repo
  (a shared parent board with `audience` routing). Repo-level location is configurable via
  `--handoff-dir`. `detect-handoff.sh` scans repo-level and parent-level paths, classifies each
  install (generic / legacy-toolpath / shared; current / legacy), and drives an **upgrade + migrate**
  choice — to the current repo, a parent-level shared dir, or a specific location. Migration preserves
  docs, `archive/`, and history (`git mv` in-repo; copy + `git rm` when leaving the repo).
- **Docs are committed — authoring is guided, not gated.** A handoff doc lands in the repo and its
  git history, so the template and the `handoff` output (`new`, `release --status done`) carry a
  **redaction** reminder (never paste keys/secrets/passwords/PII; if the next agent needs a credential,
  prompt the user and record only its _name_ via a safe channel), a **`## Suggested skills`** section,
  and a **link-don't-duplicate** note. It is prose guidance — there is no mechanical redaction gate.
- **Two handoff types.** Each doc has a `type:` — `coordination` (default; lease-gated work item) or
  `standalone` (self-contained reference doc, e.g. this handoff). A **standalone** doc is
  **gate-exempt** (`pretool-edit` allows editing with no lease), `claim` refuses it, it lists apart,
  and `release --status done` retires it without `--verified-by`. Absent `type:` ⇒ `coordination`, so
  legacy boards are unaffected. Create with `handoff new --standalone`; import a file with
  `handoff import <file>`.
- **Ships:** `scripts/setup-handoff.sh` (installer), `scripts/detect-handoff.sh` (read-only detector),
  `scripts/merge-hooks.py` (per-tool JSON merge), `scripts/verify-setup-handoff.sh` (verifier),
  `scripts/payload/` (`handoff`, `hooks.sh`, `README.md`), `assets/handoff-doc-template.md` +
  `assets/handoff-standalone-template.md`, `assets/agents-handoff.md` (the `AGENTS.md` routing block).

### `run-handoff` — `experimental` (markdown-only)

- **Trigger:** working in a repo that has a `.agents/handoff/` board — before editing shared /
  cross-repo work, when picking up or filing a handoff, or when stopping mid-task. Chains after
  `setup-handoff`; ships **no scripts** (it drives the installed `handoff` script).
- **Workflow:** read the board (`handoff list`) → `claim <id>` before editing (the hook blocks edits
  you don't hold) → do the work, keeping the doc current → `release` with an honest status: `open`
  (more to do), `blocked --blocked-on <id|external>`, or `done --verified-by "<how>"`. `done` means
  verified against the **live code**, not "the doc says resolved." Never hand-edit `INDEX.md` (it is
  generated). Release before you stop — the stop hook nags on a still-held lease.
- **Authoring rules (docs are committed):** redact secrets/keys/passwords/PII — if a credential is
  needed, prompt the user and record only its _name_ via a safe channel; fill the **Suggested skills**
  section; and **link, don't duplicate** (reference PRDs/ADRs/commits by path, don't paste them).
- **Pick a type when filing.** Default `coordination` (the claim/release flow above); use
  `handoff new --standalone` (or `handoff import <file>`) for a self-contained reference doc — it
  needs no claim and is listed apart.
- **Depends on `setup-handoff`.** Do not port it alone; it is the discipline layer over that skill's
  board.

### `register-cross-repo-handoff` — `experimental` (scripts + assets)

- **Trigger:** several repos need to coordinate on **one** board — a feature spanning an API and a
  web app, or a squad that wants a single place to see who acts next. Chains after `setup-handoff`.
- **Declare, then sync.** Group membership lives in a `.handoff-repos.json` **cascade** — user →
  workspace → subdirectory, the same layering as `AGENTS.md` and `register-cross-repo-graph`'s
  `.graph-repos.json`, so a workspace default can be narrowed per subtree. The sync step then
  scaffolds the shared board and wires every member repo to it.
- **The board is owned by no repo and seeded from none.** It is scaffolded standalone
  (`setup-handoff.sh --board-only`), not copied out of whichever member ran first — that "first repo
  wins" seeding is exactly what made shared boards fragile before. Each member gets its **own
  sub-indexed section** (`subfolder` or `prefix` layout, board-global), and its identity is threaded
  per-consumer through its own hook command, never baked into the shared config.
- **Scope of an invocation.** A repo's `handoff` calls act only inside that repo's section; the
  top-level `INDEX.md` is a roll-up across all sections. Locks live per-section, so a repo only reaps
  and nags on its own leases.
- **Depends on `setup-handoff`.** It configures and extends that skill's board; do not port it alone.

---

## 3. Prerequisites matrix

`R` = required, `O` = optional (feature dormant if absent), `—` = not used. "Required by" scopes the
dependency to the skills that actually use it.

| Dependency                                                                                    | macOS | Linux | Windows (WSL) | Required by / notes                                                                                                                                                                                                                                                                                    |
| --------------------------------------------------------------------------------------------- | :---: | :---: | :-----------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `bash`                                                                                        |   R   |   R   |       R       | All skills' scripts (`post-commit` is POSIX `sh`). macOS system bash 3.2 is fine.                                                                                                                                                                                                                      |
| `git`                                                                                         |   R   |   R   |       R       | All. `setup-graph-hooks`/`repair` require a git working tree.                                                                                                                                                                                                                                          |
| `python3`                                                                                     |   R   |   R   |       R       | initial-project, setup-graph-hooks, repair, register, **setup-handoff** — JSON + sqlite engine (not `jq`). setup-handoff's enforcement gate parses hook payloads with it (preflight refuses a hard-enforcement primary without it). WSL: ensure a `python3` alias.                                     |
| `sqlite3` (Python stdlib)                                                                     |   R   |   R   |       R       | Graph read path (FTS5 preferred; falls back to `LIKE`).                                                                                                                                                                                                                                                |
| `grep`                                                                                        |   R   |   R   |       R       | All — only POSIX-portable flags (`-q -E -F -c -x`), BSD/GNU neutral.                                                                                                                                                                                                                                   |
| `node` + a package manager                                                                    |  R\*  |  R\*  |      R\*      | **`setup-project-tooling` only** (husky/commitlint/lint-staged/release-it live in `package.json`). The other four never execute Node.                                                                                                                                                                  |
| `prettier`, `eslint`                                                                          |   O   |   O   |       O       | `setup-project-tooling`, Node/TS module (installed via npm; `prettier-plugin-sh` formats shell).                                                                                                                                                                                                       |
| `black` / `sqlfluff` (+ `uv` or `pip`)                                                        |   O   |   O   |       O       | `setup-project-tooling`, Python / Python-stream modules — installed into `.venv` via **uv (preferred) or pip**, not npm.                                                                                                                                                                               |
| `code-review-graph` (MCP)                                                                     |   O   |   O   |       O       | Graph skills. `pipx install code-review-graph`. **`register` needs it actually installed**, not just dormant.                                                                                                                                                                                          |
| `graphify` (CLI)                                                                              |   O   |   O   |       O       | Graph skills. `pipx install graphifyy` (double `y`; command is `graphify`).                                                                                                                                                                                                                            |
| **Embeddings** — `sentence-transformers`/PyTorch **or** an OpenAI-compatible embedding server |   O   |   O   |       O       | **Opt-in tier only** (`setup-embeddings.sh`). Keyword mode is the default and needs neither. `local` = ~2 GB PyTorch + ~90 MB model; a server (Ollama, LM Studio, or any OpenAI-compatible endpoint — auto-detected) = resident daemon + `CRG_OPENAI_*` in the MCP env. Nothing else installs PyTorch. |
| `jq`                                                                                          |   —   |   —   |       —       | Never used — all JSON handled by `python3`.                                                                                                                                                                                                                                                            |
| `trash`                                                                                       |   O   |   O   |       O       | Undo advice only — macOS/Homebrew `trash`; Linux `trash-cli`/`gio trash`. Never invoked.                                                                                                                                                                                                               |

**Platform summary:** macOS and Linux are first-class (the scripts shim `md5sum || md5`, a `mkdir`
lock instead of `flock`, `timeout || gtimeout ||` uncapped, and a `uname`-branched resource guard).
**Windows is supported via WSL only** — there is no PowerShell/cmd path. `repair-graph-hooks` shares
`setup-graph-hooks`' runtime exactly; `register-cross-repo-graph` additionally writes machine-local
`~/` state and assumes both repos are checkouts on the **same machine**.

---

## 4. Porting into an internal team skills collection

### 4.1 What to copy

Copy each skill directory wholesale, preserving substructure:

- `skills/engineering/initial-project/` — `SKILL.md`, `scripts/verify-initial-project.sh`,
  `references/karpathy-guidelines.md`, `references/commit-guidelines.md`.
- `skills/engineering/setup-project-tooling/` — `SKILL.md`, `scripts/verify-project-tooling.sh`,
  and all of `assets/` (the layered `editorconfig/`, `lintstaged/`, `vscode/` fragments plus
  `initialize.sh`, `commitlint.config.mjs`, `gitignore`, `prettierrc`/`prettierignore`, etc.).
- `skills/engineering/setup-graph-hooks/` — `SKILL.md`, all of `scripts/` (installer, verifier,
  `post-commit`, `graphignore`, `config/`, and the `graph-hooks/` payload), and
  `assets/agents-knowledge-graph.md`.
- `skills/engineering/repair-graph-hooks/` — `SKILL.md` only.
- `skills/engineering/register-cross-repo-graph/` — `SKILL.md`, all of `scripts/` (**including the
  `scripts/manifest/` Python package** — `resolve.py` + `render.py`; both `sync-*` and `verify-*`
  import it and hard-fail without it), and `assets/` (`agents-cross-repo.md`,
  `graph-repos.example.json`).
- `skills/engineering/setup-handoff/` — `SKILL.md`, all of `scripts/` (`setup-handoff.sh`,
  `detect-handoff.sh`, `merge-hooks.py`, `verify-setup-handoff.sh`, and the `scripts/payload/`
  directory — `handoff`, `hooks.sh`, `README.md`), and `assets/` (`handoff-doc-template.md`,
  `agents-handoff.md`).
- `skills/engineering/run-handoff/` — `SKILL.md` only (it drives `setup-handoff`'s installed script).
- `skills/engineering/register-cross-repo-handoff/` — `SKILL.md`, all of `scripts/` (**including the
  `scripts/manifest/` Python package**, same shape and same `.gitignore` gotcha as
  `register-cross-repo-graph` below), and `assets/`.
- `docs/graph-tools-during-development.md` — the runtime companion for the graph layer (see §6).
- `docs/cross-repo-handoff-usage-record.md` — the worked install record for the handoff layer, and the
  reference for the `subfolder`/`prefix` path rules (see §6). Ship it with the handoff skills.

Also carry the repo-root **`.gitattributes`** (LF guard for `*.sh`/`*.py`/`post-commit`) — it prevents
CRLF from breaking shebangs on Windows/WSL checkouts.

> **Porting gotcha — a prettier/markdown pass will mangle the handoff payload if it is not ignored.**
> The doc template uses `PLACEHOLDER_*` tokens (not `{{...}}`) and the `AGENTS.md` block avoids `<...>`
> and `|` in its code samples precisely so a formatter cannot rewrite them — but the **harness fixtures
> must still be byte-exact** (the idempotency eval re-runs the installer). Carry the `.prettierignore`
> entries for `harness/setup-handoff-workspace/fixtures/**` and `harness/run-handoff-workspace/fixtures/**`
> (mirroring the existing byte-critical-fixture ignores), or your pre-commit prettier will churn them.

> **Dependency note:** `run-handoff` ships no scripts and **depends on `setup-handoff` being present**
> — it operates the board that skill installs. Do not port `run-handoff` alone. `setup-handoff` itself
> is self-contained (needs only `bash`, `git`, and `python3` for a hard-enforcement primary).

> **Porting gotcha — a stock Python `.gitignore` will silently drop `scripts/manifest/`.** The
> standard template carries an unanchored `MANIFEST` rule (meant for setuptools' root `MANIFEST`
> file). On a case-insensitive filesystem (macOS default, `core.ignorecase=true`) it also matches the
> **`manifest/` directory** — so `git add -A` stages the skill _without_ its resolver and ships a
> skill that dies on first run. Anchor the rule to `/MANIFEST`. We hit this exact bug here; both our
> `.gitignore` and the one `setup-project-tooling` **ships** (`assets/gitignore`) are now fixed.
> **Check your internal collection's `.gitignore` before porting**, then confirm with:
> `git check-ignore -v skills/.../scripts/manifest/resolve.py` (should print nothing).

> **Dependency note:** `repair-graph-hooks` ships no scripts of its own and **depends on
> `setup-graph-hooks` being present** — it invokes that skill's `verify-graph-hooks.sh` and
> `setup-graph-hooks.sh` directly. `register-cross-repo-graph` ships its own scripts but still assumes
> the `<!-- graph-hooks -->` wiring exists. Do not port either without `setup-graph-hooks`.

> **Commit-conventions note:** `initial-project`'s `commit-guidelines.md` names `commitlint.config.mjs`
> as the enforced ruleset, but that file ships with **`setup-project-tooling`**
> (`assets/commitlint.config.mjs`), not `initial-project`. Porting `initial-project` alone still gives
> the writing guidance; the machine enforcement (a husky `commit-msg` hook running commitlint against
> `commitlint.config.mjs`) only lands when `setup-project-tooling` is also adopted. Enforcement is
> **local-only** — the skill no longer ships a CI workflow (the old `commitlint.yml` action was removed).

### 4.2 The `x442-` naming convention

The **folder stays unprefixed**; the `x442-` prefix lives only in the frontmatter `name`:

- `initial-project/` → `name: x442-initial-project`
- `setup-project-tooling/` → `name: x442-setup-project-tooling`
- `setup-graph-hooks/` → `name: x442-setup-graph-hooks`
- `repair-graph-hooks/` → `name: x442-repair-graph-hooks`
- `register-cross-repo-graph/` → `name: x442-register-cross-repo-graph`
- `setup-handoff/` → `name: x442-setup-handoff`
- `run-handoff/` → `name: x442-run-handoff`

The prefix keeps the installed slash-command unambiguous across environments. **To use your own
prefix**, change it consistently in: (1) each `SKILL.md` frontmatter `name:`; (2) the skill index rows
(`AGENTS.md` "Skill Index", `skills/README.md`, `skills/engineering/README.md`). Cross-references
between skills are by relative **folder** path, not prefixed name, so they are unaffected. The scripts
do not hardcode the prefix — they are invoked by path, so no script edits are needed for a rename.

### 4.3 Install / verify commands

```bash
# initial-project — verify a wired repo (read-only; defaults to current repo)
bash skills/engineering/initial-project/scripts/verify-initial-project.sh [repo-root]

# setup-project-tooling — verify the scaffolded tooling
bash skills/engineering/setup-project-tooling/scripts/verify-project-tooling.sh [repo-root]

# setup-graph-hooks — install (idempotent, non-destructive)
bash skills/engineering/setup-graph-hooks/scripts/setup-graph-hooks.sh <repo-root> \
  --tools claude,gemini,copilot --primary claude

# setup-graph-hooks — verify hooks are installed and fire (healthy = 0 failed)
bash skills/engineering/setup-graph-hooks/scripts/verify-graph-hooks.sh [repo-root]

# build the graph, once, only if a tool is installed (NOTE: no `embed` — keyword mode is the default)
# Register CRG's MCP server ONCE PER WIRED TOOL. A bare `code-review-graph install` is
# --platform all: it configures every platform it can detect or create a file for, injects
# competing instruction blocks, and merges its own hooks — a second refresh owner.
for p in claude-code gemini-cli copilot; do
  code-review-graph install --platform "$p" --no-hooks --no-instructions --no-skills
done
code-review-graph build                                # CRG: MCP tools + graph search
graphify update .                                      # graphify: builds the initial graph (optional)
# Do NOT run `graphify hook install` — setup-graph-hooks' post-commit already refreshes graphify,
# so its own hook would be a second, redundant refresh owner (the duplicate-rebuild problem).

# OPT-IN semantic search (separate, never run by the installer). Read state, then choose.
bash skills/engineering/setup-graph-hooks/scripts/setup-embeddings.sh --list
bash skills/engineering/setup-graph-hooks/scripts/setup-embeddings.sh --provider local
bash skills/engineering/setup-graph-hooks/scripts/setup-embeddings.sh --provider ollama --model qwen3-embedding
bash skills/engineering/setup-graph-hooks/scripts/setup-embeddings.sh --provider lmstudio --model text-embedding-qwen3-embedding-4b
bash skills/engineering/setup-graph-hooks/scripts/setup-embeddings.sh --provider off   # keyword mode

# register-cross-repo-graph — declare scope, preview, apply, verify ($SCOPE = repo root or a package)
cp skills/engineering/register-cross-repo-graph/assets/graph-repos.example.json .graph-repos.json
$EDITOR .graph-repos.json                                    # author the entries
SYNC=skills/engineering/register-cross-repo-graph/scripts/sync-cross-repo-graph.sh
bash "$SYNC" "$SCOPE" --dry-run          # effective set + which layer each alias won from
bash "$SYNC" "$SCOPE" --build missing    # ONLY after asking: writes into someone else's checkout
bash "$SYNC" "$SCOPE"                    # register + merge + rewrite the AGENTS.md block
bash "$SYNC" "$SCOPE" --merge-only       # refresh the stale merged graph (AST-only, no LLM cost)
bash skills/engineering/register-cross-repo-graph/scripts/verify-cross-repo-graph.sh "$SCOPE"

# setup-handoff — detect any existing board first (read-only), then install
bash skills/engineering/setup-handoff/scripts/detect-handoff.sh <repo-root>
bash skills/engineering/setup-handoff/scripts/setup-handoff.sh <repo-root> \
  --tools claude,gemini,copilot --primary claude          # hard enforcement on the primary
# repo-level location / topology / legacy migration (pick as needed):
#   --handoff-dir .claude/handoff        # place the board elsewhere in-repo
#   --topology cross-repo                # shared parent board with audience routing
#   --migrate <found-dir>                # upgrade + move a legacy install (preserves docs/history)
#   --allow-verify-cmd                   # opt in to running a doc's verify: command (off by default)

# setup-handoff — verify (healthy = 0 failed)
bash skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh [repo-root]

# run-handoff has no installer — it is the discipline over the installed board:
#   .agents/handoff/handoff list
#   .agents/handoff/handoff claim <id> "..."   # then edit; the hook blocks non-holders
#   .agents/handoff/handoff release <id> --status done --verified-by "<how>"
```

**`setup-graph-hooks.sh` flags:** `--tools` accepts any subset of
`claude,gemini,copilot,antigravity`; `--primary` is the one tool that owns the per-turn graph refresh
(or `none` = refresh only on git commit).

**`sync-cross-repo-graph.sh` flags** (note its `--tools` is a _different_ flag from the one above —
it names graph tools, not AI tools):

| Flag                                   | Default          | Meaning                                                                                                                                                                            |
| -------------------------------------- | ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--tools crg,graphify`                 | both             | which graph-tool paths to hydrate                                                                                                                                                  |
| `--build never\|missing\|force`        | `never`          | **`never` only _prints_ the build command.** Building writes into someone else's checkout, so the skill offers it and never forces it — pass `missing` only after the user agrees. |
| `--prune`                              | off              | also unregister aliases **this repo** registered that have left scope; never touches another project's entries                                                                     |
| `--merge-only`                         | off              | rebuild the graphify merged graph and nothing else                                                                                                                                 |
| `--no-agents` / `--agents-file <path>` | write to nearest | skip the `AGENTS.md` block, or target a specific file — the escape hatch for a monorepo package whose `AGENTS.md` is not where sync would look                                     |
| `--dry-run`                            | off              | print what would change, write nothing, always exit 0                                                                                                                              |

It is idempotent and byte-compares before writing, so a second run leaves `git status` clean.

- **Never run `setup-embeddings.sh` bare from an agent** — with no flags it opens an interactive TTY
  menu. Use `--list` to read state, ask the user, then apply with `--provider`.

- **`repair-graph-hooks` has no verifier of its own** — it re-runs `setup-graph-hooks`'
  `verify-graph-hooks.sh` and, on a healthy repo, is a clean no-op.
- **`register-cross-repo-graph` now has a real verifier** — `verify-cross-repo-graph.sh` (it had none
  at the last handoff; the old manual `code-review-graph repos` + smoke-query recipe is superseded).
  Healthy = **0 failed**. It asserts the cascade parses, every in-scope repo is on disk and queryable,
  CRG's registry agrees, the merged graph is fresh, and — the useful one — it **fails on block drift**,
  i.e. someone edited a manifest and never re-synced. On a repo that never opted into cross-repo it
  reports a `[skip]` and **exits 0** ("no `.graph-repos.json` in the cascade — not configured"): "not
  set up" is a clean skip, distinct from a failure, so the verifier is safe to run as a health probe
  on any repo.

### 4.4 Caveats to brief the team on

- **Three of five are `experimental`** — `setup-project-tooling`, `repair-graph-hooks`,
  `register-cross-repo-graph`. Review their output before relying on it.
- **`repair-graph-hooks` runs real repairs** (re-invokes the installer, re-syncs ignore files, clears
  stale locks) and its graph-state detection is new — review what it reports before approving a heavy
  rebuild. It never deletes source or force-pushes.
- **`register-cross-repo-graph`: the registry is a union; the `AGENTS.md` block is the fence.**
  `cross_repo_search_tool` returns hits from _every_ repo any project registered on this machine, so
  scope is enforced by the in-scope alias table in context — a **soft boundary**, fine for read-only
  lookup, not a security control. Brief the team on this explicitly; it is the most surprising part of
  the design.
- **A committed `.graph-repos.json` is a scope grant.** A PR that adds an entry adds a repo path to
  every teammate's agent scope. Read-only and local-path-only, but review it like any other config.
- **Cross-repo state is still same-machine.** The manifest is committed and portable; the _registry_
  and the sibling checkouts are not. Each teammate/machine runs sync themselves, and freshness is
  their own (registering neither builds nor refreshes). The merged graphify graph is refreshed by
  **nothing** — it goes stale on the next commit; `--merge-only` rebuilds it.
- **Antigravity graph hooks are gated** — inert `.example` written, contract unverified. Do not
  activate without confirming against a live install.
- **Windows = WSL only.** Keep the repo on the Linux filesystem (exec-bit + speed); rely on
  `.gitattributes` for LF. A lost exec bit degrades the verifier to _warnings_, not failures.
- **Graph tools are optional and dormant** until installed and built — the hooks silently no-op, so the
  setup is safe on any repo before a graph exists.
- **Embeddings are opt-in; keyword mode is the supported default.** A `semantic_search` result that
  looks shallow on a repo that never opted in is _not_ a bug — brief the team so nobody "fixes" it or
  falls back to grep. Enabling costs either ~2 GB of PyTorch (`local`) or a resident Ollama daemon;
  with Ollama the MCP server also needs `CRG_OPENAI_*` and every call must pin
  `provider="openai", model=<name>`. The choice lives in repo-local `.code-review-graph/embed.env`.
- **Idempotent + non-destructive** across the suite — safe to re-run; nothing is deleted (use `trash`,
  never `rm -rf`, for manual cleanup).

### 4.5 Definition of done (a wired target repo)

A repo is fully onboarded when all of these hold — run the verifiers from §4.3 to confirm, they are
read-only and LLM-free:

- [ ] `AGENTS.md` exists at the repo root with a `## Coding guidelines` section (Karpathy) and a
      `## Commit conventions` section, and **each in-use tool's entry file loads it** — no shared
      guidance duplicated into a tool file. → `verify-initial-project.sh` = `0 failed`.
- [ ] If `setup-project-tooling` was applied: commitlint + a husky `commit-msg` hook, lint-staged, and
      the VS Code workspace are in place. → `verify-project-tooling.sh` = `0 failed`.
- [ ] The `## Knowledge Graph` routing block, the shared `.graph-hooks/` layer, per-tool dispatch, and
      a **single** git `post-commit` refresh owner are installed; `.code-review-graph/` and
      `graphify-out/` are gitignored. → `verify-graph-hooks.sh` = `0 failed`, showing the dispatcher
      firing per tool and exactly one refresh owner (and, if a graph tool is installed, the graph
      built).
- [ ] If cross-repo was configured: `.graph-repos.json` parses, every in-scope sibling is on disk and
      queryable, CRG's registry agrees, and the `AGENTS.md` scope block has not drifted. →
      `verify-cross-repo-graph.sh` = `0 failed` (or a clean `[skip]` + exit 0 on a repo that never
      opted in).
- [ ] If handoff coordination was installed: the `.agents/handoff/` payload, a committed `config`, the
      `<!-- handoff -->` `AGENTS.md` block, and each wired tool's hook config are present; a
      hard-enforcement primary has a `pretool-edit` deny gate; `.locks/` is gitignored; and the
      read-only hook paths fire (deny `INDEX.md`, allow ordinary files). → `verify-setup-handoff.sh` =
      `0 failed`.

---

## 5. Cross-platform notes (detail)

- **CRLF line endings** are the main Windows/WSL breakage risk: a `.sh`/`.py` file checked out with
  CRLF makes `#!/usr/bin/env bash` fail with `bash\r: no such file`. The repo-root `.gitattributes`
  (`*.sh text eol=lf`, `*.py text eol=lf`, `post-commit text eol=lf`) resolves this — ship it.
- **Exec-bit loss** on `/mnt/c`-style mounts: the installer `chmod +x`es the hook files, but a
  Windows-mounted filesystem may not persist the bit. The verifier reports this as a _warning_ and the
  hooks still fire when invoked via `bash <path>`. Keeping the repo on the WSL Linux filesystem avoids
  it (and `repair-graph-hooks` detects and re-fixes it).
- **`disown` under dash `/bin/sh`:** `post-commit` is POSIX `sh`; on Debian/Ubuntu `/bin/sh` is dash,
  which lacks `disown`. It is guarded (`disown 2>/dev/null || true`) and the `nohup ... &` still
  detaches, so this is a no-op, not a breakage.
- **No macOS-only binaries are executed** — `trash`/`pbcopy` never run; `flock` is avoided in favor of
  a portable `mkdir` lock; `timeout` absence on stock macOS falls back to uncapped.
- **`register-cross-repo-graph`'s `~/` registry is a same-machine assumption** — a foreign repo on
  another machine or in CI is not reachable; keep both checkouts local and current.

---

## 6. Reference docs

- **[`docs/graph-tools-during-development.md`](docs/graph-tools-during-development.md)** — the runtime
  companion for the graph layer: the two tools (CRG vs graphify), what each hook fires and when, the
  routing rule agents follow, worked **token-cost scenarios** (grep+read vs graph, ~85–95% savings on
  a mid-size repo), escape hatches (`--graph-tried`), the **opt-in embeddings tier**, and build/verify
  commands. **Recommend shipping it alongside the graph skills** — it is the best single explainer for
  a developer new to the layer.
- **[`docs/cross-repo-handoff-usage-record.md`](docs/cross-repo-handoff-usage-record.md)** — the same
  thing for the handoff layer, written from a real four-repo install: the manifest used, the hook
  command the sync generates and why identity rides on it rather than in the shared board `config`,
  the `subfolder` vs `prefix` path table (doc / archive / sub-index / leases / roll-up), what group
  isolation means step by step, the fleet verifier output, and the gotchas the install cost us.
  **Recommend shipping it alongside `setup-handoff` / `run-handoff` / `register-cross-repo-handoff`** —
  it answers the two questions every adopting team asks first ("can two groups reuse an id?" and "who
  sees what?") without reading three `SKILL.md`s.
- **[`docs/harness-structure.md`](docs/harness-structure.md)** — the **contract** for the skill
  eval/test harness (fixtures, graders, A/B on-vs-off). It is now **implemented** under `harness/`
  (a workspace per skill, including the first text-output grader; see §7), not a proposal. Read it for the file formats, the `lib/` API,
  and the porting checklist.
- **[`skills/README.md`](skills/README.md)** (catalog) and each **`SKILL.md`** — the authoritative
  per-skill detail (full procedures, verification harness, status meanings). This handoff is the
  executive summary; point the team to these for the exact steps.

---

## 7. Eval harness (`harness/`)

Built since the last handoff. A skill is prose that changes an assistant's behavior, so "does it
work" is an **evaluation**, not a unit test: run the skill against a realistic fixture, then grade the
artifacts it produces. `harness/` makes that repeatable, and layers on top of — never replaces — the
per-skill `verify-*.sh` checkers. It is **read-only and LLM-free** (fixtures + graders make no API
calls); only the optional A/B skill _executions_ need an agent.

- **Two layers.** Each skill's `verify-*.sh` prints a `Summary: N passed, W warnings, F failed` line
  and exits non-zero on any FAIL — that line **is** the contract. A workspace `grade.py` runs the
  verifier, turns its summary into one `grading.json` expectation, and adds only the assertions a
  verifier structurally cannot make: idempotency (empty re-run diff), precondition refusal /
  non-fabrication, and **behavioral** checks (fire the produced artifact and assert what it decides).
- **Shared library** (`harness/lib/`, self-tested via `--selftest`): `grade_common.py` (assertions,
  the `run_verify_script()` wrapper, and `isolated_git_target()`), `aggregate.py`
  (`grading.json` → `benchmark.json`/`.md`), `reorg.py` (raw runs → canonical tree).
- **Fixture isolation (important for porting).** `verify-*.sh`, the git-clean check, and the graph
  hooks all resolve the **git toplevel**, so a fixture nested inside the skills repo would be graded
  against that outer repo. `grade_common.isolated_git_target()` copies a non-root target to its own
  temp git root first, so a post-state fixture grades correctly **in place**. Fixtures are committed
  as portable inputs; anything machine-specific is built at grade time.
- **Workspaces (one per skill, incl. the productivity skill):**

  | Workspace                               | Wraps                                                  | Representative cases                                                                                                                                                                                                                                                                                                                          |
  | --------------------------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
  | `initial-project-workspace`             | `verify-initial-project.sh`                            | fresh / preserve-existing / idempotent                                                                                                                                                                                                                                                                                                        |
  | `setup-project-tooling-workspace`       | `verify-project-tooling.sh`                            | `scaffolded` (fully wired Node/TS → 1.00 + idempotent) and `fresh` (bare project — a pre-state input)                                                                                                                                                                                                                                         |
  | `setup-graph-hooks-workspace`           | `verify-graph-hooks.sh`                                | precondition (no `AGENTS.md`), wired variants, single-refresh-owner across tools, and a **behavioral** fixture with a real `graph.db` proving the hooks steer grep/read                                                                                                                                                                       |
  | `register-cross-repo-graph-workspace`   | `verify-cross-repo-graph.sh`                           | `not-configured` (verifier skips, exit 0) and `single-sibling` (register + `AGENTS.md` block + merged graph + end-to-end grep-steer into the sibling)                                                                                                                                                                                         |
  | `repair-graph-hooks-workspace`          | `verify-graph-hooks.sh`                                | `healthy` (no-op) plus repair TARGETS `broken-json` and `missing-core` — drifted inputs that fail the verifier until repaired                                                                                                                                                                                                                 |
  | `setup-handoff-workspace`               | `verify-setup-handoff.sh`                              | precondition (no `AGENTS.md`), fresh/wired/advisory variants, `detect` (existing-install scan), `custom-location`, `legacy-install` (upgrade + migrate), and a **behavioral** `script-behavior` case that drives the lease script + hooks (session gate, fail-safe deny, auto-reap/touch, evidence-gated `done`, `blocked_on`, verify-safety) |
  | `run-handoff-workspace`                 | `verify-setup-handoff.sh` (env sanity)                 | `discipline-done` and `discipline-blocked` — drives the installed board per the discipline and asserts the produced artifacts (archived doc + `verified_at`, released lease, regenerated `INDEX.md`, blocked/`blocked_on` state)                                                                                                              |
  | `register-cross-repo-handoff-workspace` | `verify-setup-handoff.sh` (per member repo)            | `not-configured` (no `.handoff-repos.json` — sync refuses, nothing scaffolded) and `fleet` (a multi-repo group: standalone board scaffolded from no seed, per-member sections, per-consumer identity in each hook command)                                                                                                                    |
  | `release-announcement-workspace`        | the skill's own Rules (text-output — no `verify-*.sh`) | `release-input` (pre-state), `announcement-good` (compliant reference → 1.00), `violations` (deliberately rule-breaking reference the grader must reject, naming each broken rule)                                                                                                                                                            |

  Every grader isolates a nested fixture to its own git root before grading, and may emit `skipped()`
  expectations (counted in `summary.skipped`, excluded from `pass_rate`) so an optional-tool-absent
  run reports reduced coverage instead of a misleading full-green.

- **Cross-repo is graded hermetically.** A synced repo cannot ship as a static fixture — its
  post-state embeds absolute registry/block/merged-graph paths — so the grader manufactures that state
  in a sandbox: an isolated copy under a **throwaway `$HOME`** with a **seeded registry** (so `sync`
  takes the already-registered path and never shells out to the real CRG binary), each repo's graphify
  graph **built in the sandbox** (AST-only, no LLM), then `sync` → `verify`. The real
  `~/.code-review-graph` is never touched.
- **Repair is graded against setup's verifier.** `repair-graph-hooks` ships no verifier of its own; a
  healthy repo is a no-op (directly gradeable to 1.00), and the drifted fixtures fail by design until
  an agent runs the skill, then re-grade to 0 failed.
- **Pre-state labels + first benchmarks.** Each eval carries a `kind`
  (`pre-state`/`post-state`/`precondition`); graders hint when a pre-state fixture is graded raw so
  its expected 0.00 doesn't read as breakage. A first **deterministic** A/B iteration is committed for
  `setup-graph-hooks` and `setup-project-tooling` (`with_skill` = the skill's own tooling applied,
  `without_skill` = untouched fixture, `+1.00` delta). Executor `deterministic (no LLM)`, so the delta
  is structural — it proves the grade → aggregate → benchmark pipeline; a true agent A/B (LLM runs) is
  the deferred follow-up. Only the summaries + per-run `grading.json`/`timing.json` commit; the
  produced `outputs/` trees are gitignored.
- **Guardrail.** Do not launch automated multi-run LLM loops without computing the expected call count
  and getting explicit confirmation; default to at most 3 runs per configuration. The graders
  themselves make no LLM calls.
- **Porting note.** `harness/` is optional to adopt — it depends on the skills' `verify-*.sh` (already
  ported with the skills) plus `bash`/`git`/`python3` (and `code-review-graph`/`graphify` for the
  cross-repo behavioral case). If you carry it, keep the byte-critical fixture guard: the
  `repair-graph-hooks` `broken-json` fixture is intentionally invalid JSON and is listed in
  `.prettierignore` so the pre-commit formatter neither rewrites nor chokes on it.
