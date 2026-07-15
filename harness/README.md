# harness/

Skill evaluation harness for x442-skills. The design doc is
[../docs/harness-structure.md](../docs/harness-structure.md) — it owns the contracts
(file formats, `lib/` API surface, exit codes, fixture guidance). This file says what is
here and how to run it, and does not restate them.

A skill is prose that changes an assistant's behavior, so "does it work" is an
**evaluation**, not a unit test: run the skill against a realistic fixture project, then
grade the artifacts it produces — ideally A/B, the same case with the skill on vs off. This
directory holds the fixtures, eval cases, graders, and aggregated results that make that
repeatable.

## Layout

```text
harness/
├── README.md                       # this file
├── lib/                            # shared, skill-agnostic helpers
│   ├── grade_common.py             # reusable assertions + run_verify_script() + isolation helper
│   ├── aggregate.py                # grading.json -> benchmark.json + benchmark.md
│   └── reorg.py                    # normalize raw run outputs into eval-<id>/<config>/run-N/
├── initial-project-workspace/      # one workspace per skill under test
├── setup-project-tooling-workspace/
├── setup-graph-hooks-workspace/
├── register-cross-repo-graph-workspace/
└── repair-graph-hooks-workspace/
```

Each `<skill>-workspace/` holds `evals/evals.json`, `fixtures/`, `grade.py`, and
`iterations/` (results). Workspace directories use the skill's **unprefixed** folder name;
the `x442-` prefix lives only in the skill's frontmatter `name` and in `evals.json`'s
`skill_name`.

## Two layers: `verify-*.sh` vs `grade.py`

Each shipped skill bundles a read-only verifier in its own `scripts/` that ends with a
`Summary: N passed, W warnings, F failed` line and exits non-zero on any FAIL. That line plus
the exit code **is** the contract; the harness parses nothing else.

The harness **reuses** those verifiers rather than duplicating them: a workspace `grade.py`
runs the skill's own verifier, turns its summary into one `grading.json` expectation, and
then adds only the assertions a verifier structurally cannot make — it sees the end state of
one repo, with no memory of what the repo looked like before and no notion of a case that was
supposed to fail:

- **idempotency** — a re-run leaves an empty diff
- **precondition refusal / non-fabrication** — the skill correctly stopped, and invented nothing
- **behavioral** — fire the artifact the skill produced and assert on what it decides at runtime

The verifier stays the single source of truth for "wired correctly."

## Running an eval (agent-driven)

Only step 1 needs an agent. **Steps 2-4 make no LLM calls** — they post-process local files,
so they are always safe to rerun by hand or in CI.

1. Copy the fixture to a scratch workspace and `git init` it; run the eval prompt, with the
   skill loaded (`with_skill`) or not (`without_skill`). Capture produced files into
   `run-N/outputs/` and metrics into `run-N/timing.json`.
2. `python3 <skill>-workspace/grade.py <produced-dir> <eval-id> --out <run-N>/grading.json`
   — the graders self-isolate (`grade_common.isolated_git_target`): if you point one at a
   fixture nested inside this repo, it copies it to its own temp git root first, so the bundled
   `verify-*.sh` and the git-clean check grade the fixture, not x442-skills. You can grade a
   post-state fixture in place without staging it out yourself.
3. `python3 lib/aggregate.py <iteration-dir>` → `benchmark.json` + `benchmark.md`
4. Write `analyst_notes.md` — what the deltas mean and what to change in the skill.

Self-test the shared library at any time:

```bash
for m in grade_common aggregate reorg; do python3 harness/lib/$m.py --selftest; done
```

## Guardrail

Do not launch automated multi-run LLM loops without first computing the expected call count
and getting explicit confirmation. Default to at most 3 runs per configuration.

## Status

- **`lib/`** — implemented and self-tested. `grade_common.py` (assertions, verifier wrapper,
  shared `grade.py` CLI), `aggregate.py` (→ `benchmark.json`/`.md` with with/without/delta),
  `reorg.py` (raw runs → canonical tree).
- **`initial-project-workspace/`** — fixtures `nest-new` (fresh), `nest-existing`
  (preserve-existing; the grader asserts the `orders-ingest-v2` consumer-group note survives),
  `ts-library` (already wired → idempotency). Grader wraps `verify-initial-project.sh`.
- **`setup-project-tooling-workspace/`** — fixtures `scaffolded` (a fully wired Node/TS post-state
  → 1.00 + idempotent) and `fresh` (a bare Node project — a pre-state input that fails until an
  agent scaffolds the tooling). The skill ships no scaffolder, so `scaffolded` is hand-assembled
  from its `assets/`; the verifier is Node-rooted for every language. Grader wraps
  `verify-project-tooling.sh`.
- **`setup-graph-hooks-workspace/`** — fixtures `no-agents-md` (precondition: the skill must
  stop and defer to `initial-project`), `fresh-wired`, `all-wired`, `copilot-primary-wired`,
  `both-wired` (single-refresh-owner invariant across two tools), and `graph-built` — a
  **behavioral** fixture carrying a real, hand-built `graph.db` + `graphify-out/graph.json`,
  so the grader can fire the wired dispatcher and prove it actually steers grep and reads
  toward the graph rather than merely being installed. Grader wraps `verify-graph-hooks.sh`.
- **`register-cross-repo-graph-workspace/`** — fixtures `not-configured` (a wired repo with no
  `.graph-repos.json`: the verifier must `[skip]` and exit 0, not FAIL) and `single-sibling` (a
  consumer + a sibling carrying a prebuilt `graph.db`). A synced repo cannot ship as a static
  fixture — its post-state embeds absolute registry/block/merged-graph paths — so the fixtures
  ship only portable inputs and the grader manufactures the machine-specific state **hermetically**:
  an isolated copy under a throwaway `$HOME` with a seeded registry, then it runs the skill's own
  LLM-free `sync-cross-repo-graph.sh` (building each repo's graphify graph in the sandbox) and
  verifies. The real `~/.code-review-graph` is never touched. The grader is explicit about its tool
  dependencies: it **fails fast** with a legible precondition when `code-review-graph` is absent,
  and records the graphify merged-graph facet as a `skipped()` expectation (visible in
  `summary.skipped`) when `graphify` is absent, rather than silently covering less. Grader wraps
  `verify-cross-repo-graph.sh`.
- **`repair-graph-hooks-workspace/`** — `repair-graph-hooks` ships no verifier of its own; its
  success condition is that `setup-graph-hooks`' `verify-graph-hooks.sh` goes green again, so the
  grader wraps that. Fixtures: `healthy` (repair is a no-op → directly gradeable), `broken-json`
  and `missing-core` (repair TARGETS — drifted inputs that fail the verifier by design until an
  agent runs the skill, then re-graded to 0 failed).
- **All five engineering skills now have a workspace.** Every grader wraps its target with
  `isolated_git_target` (a fixture nested in this repo is relocated to its own git root, so the
  bundled `verify-*.sh` grades the fixture, not x442-skills) and may emit `skipped()` expectations —
  counted in `summary.skipped` and excluded from `pass_rate` — so a run that covers less (an
  optional graph tool absent) is never silently green.
- **No iterations committed yet** — every workspace above has fixtures, evals, and a grader,
  and each grader has been exercised against its fixtures (post-state fixtures score 1.00; the
  unwired pre-states and the drifted repair targets score 0.00, so the graders discriminate). What
  has **not** run is step 1: the A/B skill executions that produce `iterations/iteration-N/`.

## Fixtures are inputs, not source

Fixtures are sample projects the harness feeds to a skill. They are held to a different
standard than repo source, and two rules keep them honest.

**Never "fix" a fixture.** They are _deliberately_ imperfect — a fixture's whole job can be to
start out unwired, or to carry a stale config — so an autofix destroys the case it exists to
test. Prettier does normalize fixture `.json`/`.md` via the repo's pre-commit hook, which is
safe today because graders assert on content (`@AGENTS.md` is present, a routing block exists),
never on byte-exact formatting. If you ever add a fixture whose exact bytes are the thing under
test, exclude it from [.lintstagedrc.json](../.lintstagedrc.json) rather than letting the hook
rewrite it.

**Regenerate the wired ones; never hand-edit them.** A wired fixture is the installer's output,
so it goes stale the moment the skill changes — and a stale fixture fails the idempotency evals
for a reason that has nothing to do with the skill being wrong. Rebuild with the tools/primary
combination the eval id names:

```bash
INSTALLER=skills/engineering/setup-graph-hooks/scripts/setup-graph-hooks.sh
bash "$INSTALLER" harness/setup-graph-hooks-workspace/fixtures/all-wired --tools claude --primary claude
```

Because they are the installer's output rather than hand-maintained files, a wired fixture
cannot silently drift from the skill it tests — regenerating simply reveals the drift. One
thing the installer clobbers on the way through and you must restore: `graph-built/.gitignore`,
whose negations are what keep the prebuilt graph committable.
