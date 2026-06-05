# Skill harness / evals / tests — recommended structure

A recommendation for where skill tests, evaluations, and harness code should live in this repo.
It is modeled on the mature harness in `cronus-skills-bak`, adapted to this repo's conventions
(kebab-case skill names, no `cronus-` prefix, and skill directories that hold only `SKILL.md`
plus `references/`).

This is a design document, not yet-built infrastructure. Nothing under `harness/` exists today.

## Purpose

Skills are prose that change an assistant's behavior, so "does it work" is not a unit test — it is an
**evaluation**: run the skill against a realistic project, then grade the artifacts it produces. A
harness makes that repeatable: fixed inputs (fixtures), fixed questions (eval cases), and a grader that
scores the output the same way every time. It also supports **A/B** comparison — the same case run with
the skill on vs off — to prove the skill actually helps.

This is the concrete form of the lint/validation tooling that [README.md](../README.md) and
[AGENTS.md](../AGENTS.md) list as a TODO.

## Placement

Put all eval infrastructure in a top-level `harness/`, a sibling of `skills/`:

- Skill directories stay limited to `SKILL.md` + `references/`, per the AGENTS.md authoring
  conventions. Tests do not belong inside a skill folder — they would ship with the skill.
- One harness root keeps fixtures, graders, and results out of the publishable skill content.

## Layout

```text
harness/
├── README.md                       # how the harness works + how to run/grade an eval
├── lib/                            # shared, skill-agnostic helpers (DRY)
│   ├── grade_common.py             # reusable assertions: file_exists, contains, no_fabrication, json_roundtrip
│   ├── aggregate.py                # per-run grading.json -> benchmark.json + benchmark.md (mean/stddev/delta)
│   └── reorg.py                    # normalize raw run outputs -> eval-<id>/<config>/run-N/ layout
└── <skill>-workspace/              # one workspace per skill under test, e.g. initial-project-workspace/
    ├── evals/
    │   └── evals.json              # eval cases: { id, prompt, fixture, expected_output }
    ├── fixtures/                   # input projects, one directory per scenario
    │   ├── fresh-empty/
    │   ├── claude-only/
    │   └── all-wired/              # idempotency fixture (this repo's own wired state)
    ├── grade.py                    # skill-specific graders; imports ../lib/grade_common.py
    └── iterations/                 # results, one directory per benchmark run
        └── iteration-1/
            ├── benchmark.json      # aggregated, machine-readable
            ├── benchmark.md        # human-readable summary table
            ├── analyst_notes.md    # findings + recommendations
            └── eval-<id>/
                └── {with_skill,without_skill}/
                    └── run-N/
                        ├── grading.json
                        ├── timing.json
                        └── outputs/   # AGENTS.md, CLAUDE.md, plan.md, transcript.md, diff.md
```

## What this keeps from cronus, and what it changes

Kept, because it works:

- The `<skill>-workspace/` unit — each skill gets its own evals, fixtures, grader, and results.
- The `evals.json` case shape and per-scenario `fixtures/` directories.
- The `with_skill` / `without_skill` A/B split, with N runs per configuration for variance.
- The result chain: `grading.json` (per run) -> `benchmark.json` (aggregated) -> `analyst_notes.md`.
- Python graders.

Changed, on purpose:

- **`harness/lib/`** holds the shared grader helpers and the aggregator/reorg scripts. cronus copied
  `grade.py` and `reorg.py` into every workspace; here a skill's `grade.py` imports from `lib/` and
  only defines its own assertions.
- **`iterations/`** wraps the result directories instead of leaving `iteration-1/` loose at the
  workspace root, keeping the workspace root to four entries.
- **Repo-native naming** — `initial-project-workspace`, no `cronus-` prefix; eval ids are kebab-case.

## File formats

### `evals/evals.json`

Defines the cases. Each case pairs a prompt with a fixture and a prose description of the expected
output (the grader turns that prose into concrete assertions).

```json
{
  "skill_name": "initial-project",
  "evals": [
    {
      "id": "fresh-empty",
      "prompt": "Set up AI assistant config for this project so Claude Code and Copilot share one source of truth.",
      "fixture": "fixtures/fresh-empty",
      "expected_output": "AGENTS.md (CREATE) with a ## Coding guidelines section. CLAUDE.md (CREATE) with @AGENTS.md import. No fabricated tools wired."
    }
  ]
}
```

### `grading.json` (one per run, written by `grade.py`)

```json
{
  "expectations": [
    { "text": "AGENTS.md exists and is non-empty", "passed": true, "evidence": "AGENTS.md size: 2266 bytes" },
    { "text": "CLAUDE.md imports AGENTS.md (`@AGENTS.md`)", "passed": true, "evidence": "@AGENTS.md present: True" }
  ],
  "summary": { "pass_rate": 1.0, "passed": 8, "failed": 0, "total": 8 },
  "timing": { "total_tokens": 39500, "total_duration_seconds": 82.5 }
}
```

Each assertion is a `{ text, passed, evidence }` triple — the evidence string explains why it passed
or failed, so a reviewer never has to re-derive the verdict.

### `iterations/iteration-N/benchmark.json` (written by `lib/aggregate.py`)

```json
{
  "metadata": {
    "skill_name": "initial-project",
    "skill_path": "skills/engineering/initial-project",
    "executor_model": "<model-name>",
    "timestamp": "2026-06-05T00:00:00Z",
    "evals_run": ["fresh-empty", "claude-only", "all-wired"],
    "runs_per_configuration": 3
  },
  "runs": [
    { "eval_id": "all-wired", "configuration": "with_skill", "run_number": 1, "result": { "pass_rate": 1.0 } }
  ],
  "run_summary": {
    "with_skill":    { "pass_rate": { "mean": 0.96, "stddev": 0.07, "min": 0.875, "max": 1.0 } },
    "without_skill": { "pass_rate": { "mean": 0.63, "stddev": 0.12, "min": 0.5,   "max": 0.75 } },
    "delta":         { "pass_rate": "+0.33" }
  }
}
```

## Naming conventions

- Workspace directory: `<skill-name>-workspace` (e.g. `initial-project-workspace`).
- Eval id: kebab-case, descriptive (`fresh-empty`, `claude-only`, `all-wired`).
- Result path: `iterations/iteration-<N>/eval-<id>/<config>/run-<M>/`, where `<config>` is
  `with_skill` or `without_skill`.
- Output artifacts use their real filenames (`AGENTS.md`, `CLAUDE.md`, `plan.md`, `transcript.md`,
  `diff.md`) so a result directory reads like the project the skill produced.

## Git hygiene

Result runs are bulky and regenerable; the summaries are the durable record. Commit:

- `evals/evals.json`, everything under `fixtures/`, `grade.py`, and `harness/lib/`.
- Per iteration: `benchmark.json`, `benchmark.md`, `analyst_notes.md`.

Ignore the raw per-run artifacts. Add to `.gitignore`:

```gitignore
harness/**/iterations/**/outputs/
harness/**/iterations/**/run-*/transcript.md
```

## Running an eval

There is no in-repo runner yet; execution is agent-driven. The flow per case and configuration:

1. Copy the fixture to a scratch workspace; for `with_skill`, the agent has the skill loaded, for
   `without_skill` it does not.
2. Run the prompt; capture the produced files into `run-N/outputs/` and metrics into
   `run-N/timing.json`.
3. `python grade.py` — score each run's outputs into `run-N/grading.json`.
4. `python lib/aggregate.py` — roll the runs into `benchmark.json` and `benchmark.md`.
5. Write `analyst_notes.md` — what the deltas mean and what to change in the skill.

Honor the repo guardrail on batch LLM calls: do not launch automated multi-run loops without
computing the expected call count first and getting explicit confirmation. Default to a small number
of runs per configuration.

## Worked example: the `initial-project` skill

`initial-project-workspace/` would define three fixtures, matched to the skill's real branches:

- **`fresh-empty/`** — bare project, no `AGENTS.md` and no tool files. Asserts: `AGENTS.md` is created
  with a `## Coding guidelines` section; `CLAUDE.md` is created with an `@AGENTS.md` import.
- **`claude-only/`** — has a `CLAUDE.md` with existing notes but no `AGENTS.md`. Asserts: `AGENTS.md`
  is created; the existing `CLAUDE.md` notes are preserved and an `@AGENTS.md` import is added.
- **`all-wired/`** — every tool already wired (this repo's own state). This is the **idempotency**
  case. Asserts: re-running produces no changes to `AGENTS.md`, `CLAUDE.md`, `ANTIGRAVITY.md`,
  `GEMINI.md`, `.github/copilot-instructions.md`, or `.vscode/settings.json` — an empty diff is the
  pass condition.
