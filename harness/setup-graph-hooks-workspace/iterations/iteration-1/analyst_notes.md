# Analyst notes — setup-graph-hooks, iteration-1

## What this measures

The `fresh-wired` eval: a repo that already has `AGENTS.md` but no graph-hooks wiring. The grader
(`grade.py fresh-wired`) asserts the verifier passes, the `<!-- graph-hooks -->` routing block is in
`AGENTS.md`, and `.graph-hooks/hook.sh` exists.

- **with_skill** — the fixture with the skill's own tooling applied:
  `setup-graph-hooks.sh --tools claude --primary claude` plus the `AGENTS.md` routing block (SKILL
  step 5). → pass_rate **1.00**.
- **without_skill** — the raw `fresh-wired` fixture, untouched. → pass_rate **0.00**.
- **delta: +1.00.**

## Read this delta as _structural_, not an efficacy measurement

This is a **deterministic** A/B (executor `deterministic (no LLM)`): the `with_skill` arm is produced
by running the skill's bundled installer, and the `without_skill` arm is the untouched pre-state. So
the delta is the _ceiling_ — "the skill's tooling produces the wired state; doing nothing does not."
It proves the grade → aggregate → benchmark pipeline end-to-end and establishes the committed record,
but it does **not** measure whether the skill helps a _model_ reason better.

A true agent A/B — spawn a subagent to perform the `fresh-wired` prompt with the skill in context vs.
without it, and compare — is the follow-up that measures real efficacy. It needs LLM runs (and the
batch-cap confirmation), so it is intentionally deferred; this deterministic iteration is the template
it will reuse (same `eval-<id>/{with_skill,without_skill}/run-N/grading.json` layout).

## Reproduce

`with_skill` was produced in a scratch git repo (installer resolves the git toplevel, so it must run
in an isolated checkout, not in-place), then graded. `without_skill` grades the fixture directly.
Only `grading.json` + `timing.json` per run and `benchmark.{json,md}` are committed; the produced
project trees (`outputs/`) are gitignored. Regenerate the benchmark from the committed grading.json
with `python3 harness/lib/aggregate.py harness/setup-graph-hooks-workspace/iterations/iteration-1`.
