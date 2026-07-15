# Analyst notes — setup-project-tooling, iteration-1

## What this measures

The `fresh` eval: a bare Node project with no commit/lint tooling. The grader (`grade.py fresh`)
asserts `verify-project-tooling.sh` passes (its Node-rooted floor: `commitlint.config.mjs` + a
`package.json` with the six devDeps and a husky `prepare` chain + a lint-staged config +
`.editorconfig`) and that `commitlint.config.mjs` exists.

- **with_skill** — `fresh` with the skill's output applied: the config assets copied in
  (`commitlint.config.mjs`, `.editorconfig`, `.lintstagedrc.json`, `.prettierrc`, `.vscode/`,
  executable `initialize.sh`) and the tooling merged into `fresh`'s own `package.json` (its identity
  and `build` script kept; the six devDeps and the husky `prepare` chain added). → pass_rate **1.00**.
- **without_skill** — the raw `fresh` fixture, untouched. → pass_rate **0.00**.
- **delta: +1.00.**

## Read this delta as _structural_, not an efficacy measurement

`setup-project-tooling` ships no scaffolder script, so the `with_skill` arm was produced
deterministically by applying the skill's own `assets/` (the same output the `scaffolded` fixture
carries). Like the other iteration-1 benchmarks, this is the **ceiling** delta — "the skill's assets
produce the wired tooling; an untouched repo has none" — proving the pipeline, not measuring whether
the skill helps a _model_. A true agent A/B is the deferred follow-up (needs LLM runs + the batch-cap
confirmation); this deterministic run is its template.

## Reproduce

`with_skill` was assembled in a scratch dir and graded; `without_skill` grades the fixture directly.
Only `grading.json` + `timing.json` per run and `benchmark.{json,md}` are committed; the produced
trees (`outputs/`) are gitignored. Regenerate with
`python3 harness/lib/aggregate.py harness/setup-project-tooling-workspace/iterations/iteration-1`.
