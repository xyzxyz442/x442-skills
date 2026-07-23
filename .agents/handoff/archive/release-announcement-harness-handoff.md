---
id: release-announcement-harness-handoff
title: Add an eval harness workspace for the release-announcement skill
type: coordination
status: done
audience:
repos: []
severity: low
created: 2026-07-21
updated: 2026-07-23
note:
verified_at: 2026-07-23
---

## Context

`skills/productivity/release-announcement/` shipped as `experimental` with **no eval
workspace**. Every other skill in this repo has one, and its catalog row currently records
`None — markdown only`, so this is a known, deliberate gap rather than an oversight — filed
here to close later.

It does not fit either existing grader pattern:

- The `setup-*` skills wrap a read-only `verify-*.sh`. This skill **ships no scripts**, so
  there is nothing to wrap — `evals.json`'s `verify_script` field has no value here (decide
  whether to omit it or set it null; confirm `harness/lib/grade_common.py` handles the absence).
- `run-handoff` is also script-free but drives an installed CLI and asserts on the artifacts
  it produces. This skill produces **prose**, so grading must assert on the generated
  announcement text against the skill's own rules.

That makes it the first _text-output_ grader in the harness. Keep it honest: a grader that
only ever passes proves nothing.

## Where

Create `harness/release-announcement-workspace/` mirroring the existing layout
(`evals/evals.json`, `fixtures/`, `grade.py`).

- **Skill under test** — `skills/productivity/release-announcement/SKILL.md`. Its `## Rules`
  and `## Verification` sections are the grading contract; grade against those, not against
  a new checklist invented in the workspace.
- **Closest structural model** — `harness/run-handoff-workspace/`: `grade.py:52` (`grade()`),
  `grade.py:105` (`gc.run_grader` entrypoint), and `evals/evals.json` for the schema
  (`skill_name`, `skill_path`, `verify_script`, `evals[]` with `id`/`kind`/`prompt`/
  `fixture`/`expected_output`).
- **Shared assertions** — `harness/lib/grade_common.py`: `expectation():29`, `skipped():34`,
  `contains():55`, `not_contains():65`, `no_fabrication():80`, `isolated_git_target():240`,
  `run_grader():301`. `not_contains()` is the workhorse here.
- **Catalog row to update when done** — `skills/README.md`, the `### productivity/` table,
  `Harness` column (currently `None — markdown only`). Also refresh
  `skills/productivity/README.md` if the status line changes.
- **Harness contract** — `docs/harness-structure.md` owns file formats and the `lib/` API.

### Suggested fixtures

Fixtures are _inputs_, not source — see "Fixtures are inputs, not source" in
`harness/README.md`. Two, so the grader can both pass and fail:

1. `fixtures/release-input/` — a synthetic project carrying a `CHANGELOG.md` section, a tag
   range, a status promotion (`experimental` → `stable`), a capability whose enforcement is
   **soft** (so the "never overstate a guarantee" rule is exercised), and provenance from a
   non-public upstream (so the attribution rule is exercised). A `pre-state` input.
2. `fixtures/violations/` — a _produced_ announcement that deliberately breaks the rules:
   marketing language, the non-public upstream named, an invented benchmark number, and a
   destructive command in the upgrade block. The grader must score this **below 1.00**.

### What to assert

Drawn straight from the skill's `## Verification` list:

- Structure present: title, lede, highlights, and a "Get it" block with an upgrade command
  and a compare/changelog link.
- `not_contains` marketing phrases — "excited to announce", "game-changing", "supercharged".
- `not_contains` the non-public upstream's name (the sharpest, most mechanically testable
  rule in the skill).
- `not_contains` a destructive command (`rm -rf`) in the upgrade block.
- `contains` the status word when the input changelog carries a promotion.
- `no_fabrication` for numbers not present in the input.

## Verify

The next agent confirms this against live code, not against this doc:

1. `python3 harness/release-announcement-workspace/grade.py <produced-dir> <eval-id>`
   returns `pass_rate` `1.00` on the good post-state fixture.
2. The same grader scores the `violations` fixture **below 1.00**, and the failing
   expectations name the specific rule broken. A grader that greens both is not done.
3. `python3 harness/lib/grade_common.py --selftest` still exits 0 (the new workspace should
   not require changes to shared lib behavior; if it does, self-test the change).
4. `skills/README.md`'s `Harness` column no longer says `None — markdown only`, and prettier
   passes on every file touched.

## Decisions

Settled — do not relitigate:

- The skill lives in `productivity/`, not `engineering/`: the catalog defines productivity as
  "daily non-code workflow tools" and engineering as code work. Writing an announcement is
  the former.
- Status stays `experimental` until this harness exists and passes.
- The skill ships **no scripts by design**. Do not add a `verify-*.sh` just to fit the
  existing grader shape — grade the produced prose instead.
- **Emoji are expected in a generated announcement.** The house style for release
  announcements is emoji section markers plus bold-claim bullets; `AGENTS.md`'s "no emojis"
  rule governs _skill content_, not the output a skill generates. A grader must not fail an
  announcement for containing emoji.
- Known follow-up (small, independent of the harness): `SKILL.md`'s emoji rule currently
  reads "Default to none", which understates the house style above. Reword it to lead with
  mirroring the project's changelog convention.

## Resolution (2026-07-23)

Built as `harness/release-announcement-workspace/` (`evals/evals.json`, three fixtures,
`grade.py`). Deviations from the sketch above, each forced by the spec itself:

- **`verify_script` is omitted**, not null — `docs/harness-structure.md` already sanctions
  omission for script-free skills, and nothing in `harness/lib/` reads the key (graders
  hardcode their verifier path; this grader wraps none).
- **Three fixtures, not two.** Verify step 1 requires a good post-state fixture that grades
  1.00 deterministically, which the two-fixture sketch could not deliver without an LLM run.
  `announcement-good/` (post-state control, 1.00) joins `release-input/` (pre-state input)
  and `violations/` (negative control, grades 0.42 with 7 failing expectations naming the
  broken rules).
- **The invented-numbers rule uses digit-run tracing**, not `gc.no_fabrication()` (which
  asserts file absence, not content): every digit run in the announcement must appear in the
  input files' text.
- The known follow-up (SKILL.md's emoji rule leading with "Default to none") is fixed in the
  same change.

## Suggested skills

- `x442-run-handoff` — claim this handoff before starting, release with an honest status.
- Read `docs/harness-structure.md` and `harness/README.md` first; they own the contract this
  workspace must satisfy.

## Activity

- 2026-07-21 — open — released by Gunn Bhatrakarn (6c0310c6).
- 2026-07-23 — done — verified against live code by Gunn Bhatrakarn (dfa4d021): grade.py: announcement-good fixture pass_rate 1.00 exit 0; violations fixture 0.42 exit 1 with 7 failing expectations naming the broken rules; release-input raw 0.00 with pre-state hint; grade_common --selftest OK; skills/README.md Harness column updated; prettier clean on all touched files.
