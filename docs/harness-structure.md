# Skill harness / evals / tests — structure

Where skill tests, evaluations, and harness code live in this repo, and how they relate to the
read-only `verify-*.sh` checkers each skill already ships.

## Status

This document is the **contract**; [harness/](../harness/README.md) is the implementation.

- Steps 1-4, 6, and 7 of the [porting checklist](#porting-checklist) are **done**: `harness/lib/`
  (three self-tested modules), the `.gitignore` entries, `initial-project-workspace/`,
  `setup-graph-hooks-workspace/`, `register-cross-repo-graph-workspace/`,
  `repair-graph-hooks-workspace/`, and `harness/README.md`. Every grader has been exercised
  against its fixtures — wired/healthy fixtures score 1.00, the unwired pre-state and the drifted
  repair targets score 0.00 — but no iteration has been run, because that is the one step needing
  an agent.
- Still open: `setup-project-tooling-workspace/` (step 5). The skill already ships a conforming
  verifier, so its grader can wrap one directly.
- All four shipped verifiers
  ([verify-initial-project.sh](../skills/engineering/initial-project/scripts/verify-initial-project.sh),
  [verify-project-tooling.sh](../skills/engineering/setup-project-tooling/scripts/verify-project-tooling.sh),
  [verify-graph-hooks.sh](../skills/engineering/setup-graph-hooks/scripts/verify-graph-hooks.sh),
  [verify-cross-repo-graph.sh](../skills/engineering/register-cross-repo-graph/scripts/verify-cross-repo-graph.sh))
  honor the output contract the harness depends on.

Every contract in this document was read off a working implementation, not reconstructed from
memory. Where the implementation does something non-obvious, that choice is called out.

## Purpose

Skills are prose that change an assistant's behavior, so "does it work" is not a unit test — it is
an **evaluation**: run the skill against a realistic project, then grade the artifacts it produces.
A harness makes that repeatable: fixed inputs (fixtures), fixed questions (eval cases), and a grader
that scores the output the same way every time. It also supports **A/B** comparison — the same case
run with the skill on vs off — to prove the skill actually helps rather than merely not hurting.

## Placement

Put all eval infrastructure in a top-level `harness/`, a sibling of `skills/`:

- Skill folders ship to users via `npx skills add`, the Claude plugin marketplace, and the dev-loop
  link scripts. Bulky eval material — fixtures (whole sample projects), per-run outputs, benchmark
  results — must not ride along, so it lives under `harness/`, not inside a skill folder.
- A skill's own `scripts/verify-*.sh` **stays in the skill**. It is a deterministic post-condition
  checker that ships _with_ the skill so a user can confirm a run after the fact. The harness
  consumes it; it does not replace it.

## The two-layer model

This is the load-bearing idea of the whole harness, and the reason the two halves never drift.

Every shipped skill that wires a repo bundles a read-only verifier in its `scripts/`. Verifiers
inspect files only — they never write, call an LLM, or hit the network — and each ends with a line
shaped like:

```text
Summary: 23 passed, 1 warnings, 0 failed
```

exiting non-zero on any FAIL. Warnings never fail a run. That line plus the exit code **is** the
contract; the harness parses nothing else.

The harness adds a second layer on top and **reuses the first** rather than duplicating it:

| Layer         | Lives in                     | Role                                                                                                          | LLM?                 |
| ------------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------- | -------------------- |
| `verify-*.sh` | the skill's `scripts/`       | deterministic post-condition check; the single source of truth for "wired correctly"; ships with the skill    | never                |
| `grade.py`    | `harness/<skill>-workspace/` | eval grader: runs the verifier, parses its summary, adds eval-specific assertions, scores with/without deltas | never (grading only) |

So each `grade.py` runs the skill's own `verify-*.sh` against the produced workspace, turns its
summary plus exit code into a single `grading.json` expectation, and then layers on **only the
assertions a verifier cannot make**:

- **Idempotency** — a re-run leaves an empty diff (`git status --porcelain` is empty).
- **Precondition refusal / non-fabrication** — the skill correctly stopped, and invented no files.
- **Behavioral** — fire the artifact the skill produced (e.g. a wired hook) and assert on what it
  actually decides at runtime.

A verifier cannot check these because it only ever sees the end state of one repo, with no memory
of what the repo looked like before and no notion of a case that was supposed to fail.

> One caveat worth inheriting knowingly: `verify-graph-hooks.sh` is read-only _except_ that
> exercising the end-of-turn refresh may kick off a background graph update (idempotent and locked).
> Everything else on this page assumes verifiers are side-effect free.

## Layout

```text
harness/
├── README.md                       # how the harness works + how to run/grade an eval
├── lib/                            # shared, skill-agnostic helpers (DRY)
│   ├── grade_common.py             # reusable assertions + run_verify_script() wrapper
│   ├── aggregate.py                # per-run grading.json -> benchmark.json + benchmark.md
│   └── reorg.py                    # normalize raw run outputs -> eval-<id>/<config>/run-N/
└── <skill>-workspace/              # one workspace per skill under test
    ├── evals/
    │   └── evals.json              # eval cases: { id, prompt, fixture, expected_output }
    ├── fixtures/                   # input projects, one directory per scenario
    ├── grade.py                    # skill-specific grader; imports ../lib/grade_common.py
    └── iterations/                 # results, one directory per benchmark run
        └── iteration-1/
            ├── benchmark.json      # aggregated, machine-readable
            ├── benchmark.md        # human-readable summary tables
            ├── analyst_notes.md    # findings + recommendations
            └── eval-<id>/
                └── {with_skill,without_skill}/
                    └── run-N/
                        ├── grading.json
                        ├── timing.json
                        └── outputs/   # AGENTS.md, CLAUDE.md, plan.md, transcript.md, diff.md
```

The workspace directory uses the skill's **unprefixed** folder name plus `-workspace`
(`initial-project` → `initial-project-workspace`). The `x442-` prefix lives only in the skill's
frontmatter `name` and in the dev-loop symlinks — never in repo paths.

Keeping `iterations/` as a wrapper (rather than leaving `iteration-1/` loose at the workspace root)
holds the workspace root to exactly four entries.

## `lib/` API surface

Three modules, shared by every workspace. All are read-only, make zero LLM calls, and are therefore
always safe to run by hand or in CI. Each carries a `--selftest`.

### `grade_common.py`

A library, not a runner. Every assertion returns the canonical triple
`{"text": str, "passed": bool, "evidence": str}` — the evidence string explains the verdict so a
reviewer never has to re-derive it.

| Function                                             | Passes when                                                        |
| ---------------------------------------------------- | ------------------------------------------------------------------ |
| `expectation(text, passed, evidence)`                | (constructor for the triple; coerces types)                        |
| `file_exists(root, rel)`                             | `root/rel` is a file with size > 0                                 |
| `contains(root, rel, needle, *, label=None)`         | `root/rel` contains the literal substring `needle`                 |
| `no_fabrication(root, rel)`                          | `root/rel` does **not** exist — asserts the skill invented nothing |
| `json_roundtrip(root, rel)`                          | `root/rel` parses as JSON                                          |
| `run_verify_script(script, target)`                  | see below                                                          |
| `write_grading(out_path, expectations, timing=None)` | (writes `grading.json`, returns the dict)                          |

`run_verify_script(script, target)` shells out to `bash <script> <target>`, then scans stdout with:

```python
re.compile(r"Summary:\s*(\d+)\s+passed,\s*(\d+)\s+warnings,\s*(\d+)\s+failed")
```

It passes iff `returncode == 0 and failed == 0`. Two behaviors are easy to get wrong when
reimplementing:

- If the script is missing, it returns a **failed** expectation rather than raising.
- If no `Summary:` line matches, `failed` stays `None`, so `failed == 0` is `False` and the
  expectation fails — a verifier that forgets to print its summary is treated as a failure, not
  silently passed. The evidence string becomes `(no Summary line) (exit N)`.

On success the evidence carries the summary verbatim, e.g.
`"Summary: 8 passed, 1 warnings, 0 failed (exit 0)"`.

`write_grading()` computes `pass_rate = passed / total` (`0.0` when `total == 0`), creates parent
directories, and writes JSON with `indent=2` plus a trailing newline.

### `aggregate.py`

```text
python3 aggregate.py <iteration-dir> [--executor-model NAME] [--timestamp ISO8601]
```

Walks `<iteration-dir>/eval-<id>/{with_skill,without_skill}/run-N/grading.json`, pulls `skill_name`
and `skill_path` from the workspace's `evals/evals.json` (located as `iteration_dir.parent.parent`),
and writes `benchmark.json` + `benchmark.md` into the same iteration directory.

Details that matter:

- **`executor_model` and `timestamp` are passed in, never generated** — flags first, then the
  `EVAL_EXECUTOR_MODEL` / `EVAL_TIMESTAMP` env vars, else `null`. This keeps reruns byte-identical,
  so re-aggregating a finished iteration produces no spurious diff. Do not "helpfully" call
  `datetime.now()` here.
- Statistics use **population** stddev (`statistics.pstdev`), not sample stddev, and round to 4
  places. With a single run, stddev is hardcoded to `0.0` rather than computed.
- Delta is formatted `f"{with_mean - without_mean:+.2f}"` → `"+0.33"`. It is `null` when either
  configuration is absent, which is the normal case for a single-config iteration.
- `runs_per_configuration` is the **max** run count across all (eval, config) pairs, not an average.
- Missing stats render as an em dash (`—`) in `benchmark.md`.

### `reorg.py`

```text
python3 reorg.py <raw-dir> <iteration-dir>
```

Normalizes an ad-hoc pile of run directories into the canonical tree. Each run directory is keyed by
a `meta.json` holding `{eval_id, configuration, run_number}`; if absent, the directory name is
parsed against `^eval-(?P<eval_id>.+?)__(with_skill|without_skill)__run-(\d+)$`. Unparseable
directories are skipped with a printed `skip ...` line rather than aborting the batch.

`grading.json` and `timing.json` land at the run root; **everything else** is copied under
`outputs/`.

### Exit-code conventions

| Situation                              | Exit |
| -------------------------------------- | ---- |
| `--selftest` passes                    | 0    |
| No arguments (prints docstring)        | 2    |
| Input directory does not exist         | 1    |
| Normal success                         | 0    |
| `grade.py` with any failed expectation | 1    |

`grade.py` exits `0` iff `summary.failed == 0`.

## File formats

### `evals/evals.json`

Defines the cases. Each case pairs a prompt with a fixture and a prose description of the expected
output; the grader turns that prose into concrete assertions.

```json
{
  "skill_name": "x442-initial-project",
  "skill_path": "skills/engineering/initial-project",
  "verify_script": "skills/engineering/initial-project/scripts/verify-initial-project.sh",
  "evals": [
    {
      "id": "nest-new",
      "prompt": "Set up this project's AI assistant config around a shared AGENTS.md so Claude Code and Copilot use one source of truth.",
      "fixture": "fixtures/nest-new",
      "expected_output": "Freshly-scaffolded NestJS app with no AI config. AGENTS.md (CREATE) with a `## Coding guidelines` section citing karpathy-guidelines. CLAUDE.md (CREATE) with exactly one `@AGENTS.md` import. No guidelines duplicated into tool files."
    }
  ]
}
```

`skill_name` carries the `x442-` prefix (it matches the skill's frontmatter `name`); eval `id`s stay
kebab-case and unprefixed. `verify_script` is repo-relative and omitted for skills that ship no
verifier.

### `grading.json` (one per run, written by `grade.py`)

```json
{
  "expectations": [
    { "text": "AGENTS.md exists and is non-empty", "passed": true, "evidence": "AGENTS.md size: 2266 bytes" },
    { "text": "verify-initial-project.sh passes", "passed": true, "evidence": "Summary: 8 passed, 1 warnings, 0 failed (exit 0)" }
  ],
  "summary": { "pass_rate": 1.0, "passed": 8, "failed": 0, "total": 8 },
  "timing": { "total_tokens": 39500, "total_duration_seconds": 82.5 }
}
```

### `timing.json` (one per run, captured at run time — **not** by the grader)

Graders never measure anything; they leave `timing` empty and the runner supplies this file. All
fields are nullable, which is the honest answer for a deterministic, LLM-free run.

```json
{
  "total_tokens": null,
  "total_duration_seconds": null,
  "note": "Deterministic script execution; no LLM calls were made for this run."
}
```

### `iterations/iteration-N/benchmark.json` (written by `lib/aggregate.py`)

```json
{
  "metadata": {
    "skill_name": "x442-initial-project",
    "skill_path": "skills/engineering/initial-project",
    "executor_model": "<model-name>",
    "timestamp": "2026-07-10T00:00:00Z",
    "evals_run": ["nest-new", "nest-existing", "ts-library"],
    "runs_per_configuration": 3
  },
  "runs": [{ "eval_id": "ts-library", "configuration": "with_skill", "run_number": 1, "result": { "pass_rate": 1.0 } }],
  "run_summary": {
    "with_skill": { "pass_rate": { "mean": 0.96, "stddev": 0.07, "min": 0.875, "max": 1.0 } },
    "without_skill": { "pass_rate": { "mean": 0.63, "stddev": 0.12, "min": 0.5, "max": 0.75 } },
    "delta": { "pass_rate": "+0.33" }
  }
}
```

When a configuration has no runs, its `pass_rate` is `null` and so is the delta — the keys are
always present.

### `iterations/iteration-N/benchmark.md` (written by `lib/aggregate.py`)

A header (skill, executor model, timestamp, evals, runs per configuration) followed by two tables:
**Pass rate (across all runs)** with `with_skill` / `without_skill` / `**delta**` rows, and
**Per-eval pass rate (mean)** with one row per eval id.

### `iterations/iteration-N/analyst_notes.md` (hand-written)

Prose: what the deltas mean, which assertions moved, and what to change in the skill. This is the
durable artifact — benchmarks age, findings don't.

## Naming conventions

- Workspace directory: `<skill-name>-workspace`, using the **unprefixed** folder name
  (e.g. `initial-project-workspace`, `setup-graph-hooks-workspace`).
- `evals.json` `skill_name`: the `x442-`-prefixed frontmatter name (e.g. `x442-initial-project`).
- Eval id: kebab-case, descriptive (`nest-new`, `all-wired`, `no-agents-md`), unprefixed.
- Result path: `iterations/iteration-<N>/eval-<id>/<config>/run-<M>/`, where `<config>` is
  `with_skill` or `without_skill`.
- Output artifacts use their real filenames (`AGENTS.md`, `CLAUDE.md`, `plan.md`, `transcript.md`,
  `diff.md`) so a result directory reads like the project the skill produced.

## File formatting

Defer to [.editorconfig](../.editorconfig): UTF-8, LF, final newline. Python graders use 4-space
indent; JSON uses 2-space; markdown keeps trailing whitespace (line-break semantics). No emojis in
harness content.

## Git hygiene

Result runs are bulky and regenerable; the summaries are the durable record. Commit:

- `evals/evals.json`, everything under `fixtures/`, `grade.py`, and `harness/lib/`.
- Per iteration: `benchmark.json`, `benchmark.md`, `analyst_notes.md`.

Ignore the raw per-run artifacts — but ignoring them is only half the job. This repo's
[.gitignore](../.gitignore) is generated from a toptal template whose Python/virtualenv rules
(`lib/`, `[Ll]ib`) match `harness/lib/`, and whose AI rules (`.code-review-graph/`,
`graphify-out/`) match the prebuilt graph that makes the behavioral fixture behavioral. A third
pattern, `**/.claude/settings.local.json`, lives in the user's **global** `core.excludesFile`.
Left alone, all three silently drop harness _source_ — the graders and the fixture payload — from
every commit. So the ignore block must both exclude the outputs and re-include those:

```gitignore
harness/**/iterations/**/outputs/
harness/**/iterations/**/run-*/transcript.md

!harness/lib/
!harness/**/fixtures/**/.code-review-graph/
!harness/**/fixtures/**/graphify-out/
!harness/**/fixtures/**/.claude/settings.local.json
```

Repo rules beat the global excludesFile, so the last negation belongs here rather than in the
user's global config. Verify with `git check-ignore -v <path>` rather than assuming — the rule
that catches a path is often not the one you expect.

**Add these entries before the first eval run, not after.** The reference implementation wrote this
rule down and then committed `outputs/` trees anyway, because the runs happened before the ignore
landed and `.gitignore` does not retroactively untrack files.

## Running an eval

There is no in-repo runner; execution is agent-driven. Per case and configuration:

1. Copy the fixture to a scratch workspace and `git init` it. For `with_skill` the agent has the
   skill loaded; for `without_skill` it does not.
2. Run the prompt; capture the produced files into `run-N/outputs/` and metrics into
   `run-N/timing.json`.
3. `python3 grade.py <produced-project-dir> <eval-id> --out <run-N>/grading.json` — runs the skill's
   `verify-*.sh` and adds the eval-specific assertions.
4. `python3 ../lib/aggregate.py <iteration-dir>` — roll the runs into `benchmark.json` and
   `benchmark.md`.
5. Write `analyst_notes.md` — what the deltas mean and what to change in the skill.

Only steps 1–2 need an agent. **Steps 3–5 make no LLM calls** — they only post-process local files —
so they are always safe to rerun, and re-running step 4 on an unchanged iteration produces no diff.

Honor the batch-LLM guardrail: do not launch automated multi-run loops without computing the
expected call count first and getting explicit confirmation. Cap at 3 runs per configuration unless
told otherwise.

## Fixture guidance

Fixtures are whole sample projects, one directory per scenario, committed **without**
`node_modules`/`dist` — these skills read and write config files, so no install is needed.

For a repo-wiring skill, the project's language is rarely what selects a branch; the **starting
state of the AI config** is. So vary that, and let the project type merely be realistic. Aim for at
least four cases:

| Case              | What it proves                                 | Graded with                      |
| ----------------- | ---------------------------------------------- | -------------------------------- |
| fresh             | the skill creates the right files from nothing | `file_exists` + `contains`       |
| preserve-existing | pre-existing user content survives the edit    | `contains` on a distinctive line |
| idempotency       | re-running changes nothing                     | empty `git status --porcelain`   |
| precondition      | the skill refuses and invents nothing          | `no_fabrication`                 |

The preserve-existing case works best when the fixture contains one distinctive, greppable string
(the reference repo uses a consumer-group id) that the grader asserts on directly.

A **behavioral** fixture is worth adding for any skill whose output is executable. Wiring fixtures
prove hooks are installed; only a fixture with a real, pre-built graph proves the installed hooks
actually steer a search. Fire the produced artifact with realistic payloads and assert on its
decisions.

## Porting checklist

Each step is independently verifiable; do them in order.

1. `mkdir -p harness/lib`, port the three modules, and confirm each with
   `python3 harness/lib/<module>.py --selftest`. All three must print `... selftest OK`.
2. Add the two `.gitignore` entries above — before any eval runs.
3. Build **`initial-project-workspace/`** first. It has the simplest verifier and the clearest
   branches: fresh / preserve-existing / idempotent. Its `grade.py` locates the repo root by walking
   up for the directory containing `skills/`, then wraps
   `skills/engineering/initial-project/scripts/verify-initial-project.sh`.
4. Then **`setup-graph-hooks-workspace/`** — the richest branch set, and the only one that needs a
   behavioral fixture (a repo with a built graph) plus a precondition fixture (a repo with no
   `AGENTS.md`, where the skill must stop and defer to `initial-project`).
5. Then **`setup-project-tooling-workspace/`** — **still open**. It already ships
   `verify-project-tooling.sh` and the reference repo never gave it a workspace, so this is the
   remaining gap to close.
6. Write `harness/README.md` last, pointing back at this document rather than restating it.

7. **Done — `register-cross-repo-graph-workspace/`.** It ships `verify-cross-repo-graph.sh`, so its
   grader wraps a verifier like the others — but it is the only workspace needing a **two-repo**
   fixture (a consumer plus a sibling with a prebuilt graph) and a redirected `HOME`, because the
   skill hydrates machine-global registry state. A synced repo cannot ship as a static fixture (its
   post-state embeds absolute registry/block/merged-graph paths), so the fixtures ship only portable
   inputs and the grader manufactures the machine-specific state **hermetically**: an isolated copy
   under a throwaway `$HOME` with a **seeded registry** (so `sync` takes the already-registered path
   and never shells out to the real CRG binary), each repo's graphify graph **built in the sandbox**
   (AST-only, no LLM), then `sync` → `verify`. Shipped cases: `not-configured` (no manifest → the
   verifier `[skip]`s and exits 0, guarding the unconfigured-exit fix) and `single-sibling`
   (register + AGENTS.md block + merged graph + end-to-end grep-steer into the sibling). Further
   cases worth adding: cascade-override (user layer shadowed by project), tombstone-removal, and
   dead-path (a manifest entry whose repo is gone — must FAIL).

8. **Done — `repair-graph-hooks-workspace/`.** `repair-graph-hooks` ships no verifier of its own; its
   success condition is that `setup-graph-hooks`' `verify-graph-hooks.sh` goes green again, so the
   grader wraps that plus one targeted assertion per case. Fixtures: `healthy` (repair is a no-op →
   directly gradeable to 1.00) and the repair TARGETS `broken-json` (corrupt Claude config) and
   `missing-core` (a deleted core script) — drifted inputs that fail the verifier by design until an
   agent runs the skill, then re-graded to 0 failed.

## Known gaps in the reference implementation

Recorded so they are not inherited by accident:

- Its harness README's status section omits workspaces that exist on disk — each has evals and a
  grader but no committed iteration, so the README reads as if they were never built.
- `setup-project-tooling` ships a verifier with no workspace wrapping it.
- Two `setup-graph-hooks` eval cases (`copilot-primary-wired`, `both-wired`) are defined in
  `evals.json` but were never run in a committed iteration, so the benchmark's 100% covers four of
  six cases.
- Per-run `outputs/` trees are committed despite the `.gitignore` rule meant to exclude them.
- Graders for content-generation skills wrap no verifier and assert on raw content patterns; that
  works, but it puts the pass condition in two places when the skill also ships a checker.
