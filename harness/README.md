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
│   ├── grade_common.py             # reusable assertions + run_verify_script() wrapper
│   ├── aggregate.py                # grading.json -> benchmark.json + benchmark.md
│   └── reorg.py                    # normalize raw run outputs into eval-<id>/<config>/run-N/
├── initial-project-workspace/      # one workspace per skill under test
└── setup-graph-hooks-workspace/
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
- **`setup-graph-hooks-workspace/`** — fixtures `no-agents-md` (precondition: the skill must
  stop and defer to `initial-project`), `fresh-wired`, `all-wired`, `copilot-primary-wired`,
  `both-wired` (single-refresh-owner invariant across two tools), and `graph-built` — a
  **behavioral** fixture carrying a real, hand-built `graph.db` + `graphify-out/graph.json`,
  so the grader can fire the wired dispatcher and prove it actually steers grep and reads
  toward the graph rather than merely being installed. Grader wraps `verify-graph-hooks.sh`.
- **No iterations committed yet** — every workspace above has fixtures, evals, and a grader,
  and each grader has been exercised against its fixtures (wired fixtures score 1.00; the
  unwired pre-state scores 0.00, so the graders discriminate). What has **not** run is step 1:
  the A/B skill executions that produce `iterations/iteration-N/`.
- **Not yet wired:** `setup-project-tooling` and `register-cross-repo-graph` each ship a
  read-only `verify-*.sh` that `run_verify_script()` can wrap directly, so they are the
  cheapest workspaces to add next. `repair-graph-hooks` ships no verifier of its own (it
  reuses `verify-graph-hooks.sh`), so it needs a grader built on direct assertions — defer it
  until the others are green.

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
skills/engineering/setup-graph-hooks/scripts/setup-graph-hooks.sh < fixture > --tools claude --primary claude
```

Two things the installer will clobber on the way through, both of which must be restored:
`graph-built/.gitignore` (its negations are what keep the prebuilt graph committable) and any
fixture whose source files you excluded from the rebuild.

The wired fixtures are generated by running this repo's own
`skills/engineering/setup-graph-hooks/scripts/setup-graph-hooks.sh` against the source files,
not hand-maintained, so a fixture cannot drift from the skill it tests. Regenerate one by
re-running the installer with the tools/primary combination its eval id names.
