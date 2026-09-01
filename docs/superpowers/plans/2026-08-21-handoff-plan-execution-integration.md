# Handoff Plan-Execution Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a handoff an optional `plan:` field that links it to a task-structured
implementation plan, so a fresh execution session can route the handoff to the tool's
plan-execution engine (per-task implementer + per-task review + fix loop) instead of
steering each task by hand — while the handoff board stays the durable coordination
envelope (claim → execute → verify → release).

**Architecture:** One optional frontmatter field (`plan:`) on the coordination doc
template, settable via a new `handoff new --plan PATH` flag, validated to be a
repo-relative path. `handoff export` inlines the plan path into the offline brief so an
executor without the board still follows the plan. `run-handoff` gains an "Execution
modes" section with a routing table (plan-driven / delegate / manual); `delegate-handoff`
gains a note that a plan is the spec-compliance reference for reviewing the return. The
board, lease, and `--verified-by` evidence model are unchanged — the plan is the payload,
the handoff is the envelope.

**Tech Stack:** Bash 3.2-compatible (macOS ships it), the existing `render_tmpl` /
`require_value` / `meta` / `doc_section` helpers in the `handoff` CLI, `awk` for
frontmatter, the repo's eval harness (`harness/lib/grade_common.py`), and the
`handoff.selftest.sh` PASS/FAIL pattern.

**Spec:** [docs/superpowers/specs/2026-08-21-handoff-plan-execution-integration-design.md](../specs/2026-08-21-handoff-plan-execution-integration-design.md)

**Concept authority (steering):** [docs/adr/0001-handoff-plan-execution-integration.md](../../adr/0001-handoff-plan-execution-integration.md) —
the ADR records the concept-level decisions (envelope/payload split, optional `plan:`
link, routing table, tool-agnostic wording). Its four steering questions were resolved
2026-08-23 (status `accepted`): tool-agnosticism is required, the CLI does no _hard_
existence check (soft warning at `new`, hard check in the brief's preflight), the plan
is an SDD plan from the superpowers suite, and the ADR steers while the spec + this plan
control implementation and sub-agent delegation. If steering changes a concept decision,
update this plan and the spec to match before executing.

## Prerequisites — rechecked 2026-08-23

Both prerequisite efforts are **merged into `main`** (rechecked at `536cff0`):

1. **`2026-08-21-handoff-config-scopes.md`** — landed: `config.sh` is in the payload, the
   CLI reads board config through the resolver (`5e4a3db`), and the installer no longer
   rewrites unchanged tool configs (`9a196c4`).
2. **`2026-08-21-handoff-offline-delegation.md`** — landed: the export/import CLI work is
   merged, and its harness is **complete** — `harness/delegate-handoff-workspace/` now has
   `grade.py` and `evals/`. Task 5 below no longer finishes that grader.

The payload has since moved to **`setup-handoff 6`** (brief template + provider
frontmatter, `40e15a4`/`197f4c6`), so Task 6 bumps **6 → 7**.

Still in flight (uncommitted on `main` as of the recheck — commit or stash before
starting, so the working tree is clean): a truncated-sentence fix in
`skills/personal/run-delegate-agent/SKILL.md` (archived handoff
`run-delegate-agent-truncated-sentence-handoff.md`), a board-path fix in
`scripts/payload/hooks.sh`, and catalog/README prose updates. None of them touch the
files this plan edits, but a clean tree keeps the per-task commits honest.

Work from `main` on a new feature branch (e.g. `feature/handoff-plan-execution`). The
`handoff` CLI line numbers cited in Tasks 2–3 are as of `536cff0` and will shift with any
further merges — re-locate by symbol (`cmd_new`, `cmd_export`, `cmd_list`, `render_tmpl`),
not by line.

## Global Constraints

Every task's requirements implicitly include these.

- **`plan:` is a repo-relative path.** No leading `/`, no `..` segment, no `:`. The CLI
  validates and refuses otherwise. It is a _link_, not embedded content — the plan file
  lives in the repo (typically `docs/superpowers/plans/`), so the handoff doc stays small
  and the plan stays the single source of task structure.
- **No hard existence check (ADR decision 2).** The CLI never refuses a missing plan
  file — a handoff is often filed before its plan is written. It prints a stderr warning
  when the file is absent at `new` time. The hard check lives in the brief's preflight:
  when a plan is linked, the executor verifies the file exists in _their_ checkout before
  proceeding (a missing plan there is a stop condition).
- **The field is optional.** A handoff with no `plan:` executes exactly as it does today
  (manual or delegate). No existing doc, fixture, or self-test breaks when the field is
  absent. `render_tmpl` fills an unset `PLACEHOLDER_PLAN` with an empty string.
- **Skill content is tool-agnostic.** This repo is installed into repos that use Claude
  Code, Gemini CLI, Copilot, or Antigravity. `run-handoff` and `delegate-handoff` must say
  "the tool's plan-execution engine" and "a task-structured plan", never a specific
  vendor's engine name. The plan _file_ (this document) may name them; the committed
  skill content may not. `scripts/verify-standalone.sh` enforces this on commit.
- **Bash 3.2.** No `sed -i`, no GNU-only flags, no `readlink -f`, no associative arrays,
  no `${var^^}`. Frontmatter edits go through `awk` / the existing `set_field` / `meta`.
- **No `:` in any frontmatter value.** `plan:` is a path, so the colon rule is satisfied
  by the path validation above; do not add a second colon-folding path for it.
- **Payload mirrors must not drift.** The `handoff` CLI and the doc/brief templates have
  copies in `harness/**/fixtures/**`. Any change to the payload CLI or a template must be
  re-synced to every fixture copy (Task 6).
- **House rules:** no emoji in skill content; `trash`, never `rm -rf`; Conventional
  Commits with scope from the fixed enum in `commitlint.config.mjs`
  (`setup|config|deps|feature|bug|docs|style|refactor|test|build|ci|release|other`).
  `handoff` and `skills` are **not** valid scopes — use `feature` for CLI work, `docs`
  for skill/catalog prose, `test` for harness work.

---

## File Structure

**Created:**

| Path                                                                             | Responsibility                   |
| -------------------------------------------------------------------------------- | -------------------------------- |
| `docs/superpowers/specs/2026-08-21-handoff-plan-execution-integration-design.md` | The design this plan argues from |

**Modified:**

| Path                                                                   | Change                                                                                     |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `skills/engineering/setup-handoff/scripts/payload/handoff`             | `--plan` flag on `new`, path validation, `plan` column in `list`, plan inlined in `export` |
| `skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh` | Cases for `--plan`, validation, missing-file warning, export+preflight, list column        |
| `skills/engineering/setup-handoff/assets/handoff-doc-template.md`      | `plan:` frontmatter field (optional)                                                       |
| `skills/engineering/setup-handoff/assets/handoff-brief-template.md`    | "Plan" subsection + plan preflight check in the offline brief                              |
| `skills/engineering/setup-handoff/scripts/payload.version`             | `setup-handoff 6` → `setup-handoff 7`                                                      |
| `skills/engineering/run-handoff/SKILL.md`                              | "Execution modes" section + routing table + anti-patterns                                  |
| `skills/engineering/delegate-handoff/SKILL.md`                         | Note: a `plan:` is the spec-compliance reference for the return review                     |
| `skills/README.md`, `AGENTS.md`                                        | Catalog one-liner update for `run-handoff`                                                 |
| `harness/run-handoff-workspace/evals/` + `grade.py`                    | Cases for `--plan`, validation, export, list column                                        |
| `harness/**/fixtures/**` (CLI + template mirrors)                      | Re-sync the payload and template changes                                                   |

---

## Task 1: The design spec

The spec is the binding authority the rest of this plan argues from. Write it before any
CLI or skill edit so the reviewer has something to check compliance against.

**Files:**

- Create: `docs/superpowers/specs/2026-08-21-handoff-plan-execution-integration-design.md`

**Interfaces:**

- Consumes: the current `handoff` CLI surface (`new`, `export`, `list`, `render_tmpl`,
  `meta`), the doc/brief templates, and the `run-handoff` / `delegate-handoff` skill bodies.
- Produces: a spec that names the `plan:` field semantics, the `--plan` validation rules,
  the export/list behavior, the execution-modes routing table, and the tool-agnostic
  wording requirement.

- [ ] **Step 1: Write the spec**

Create the spec with these sections (prose, no code):

1. **Problem.** A fresh execution session today steers every task by hand. A
   task-structured plan plus a plan-execution engine (fresh implementer per task, per-task
   spec+quality review, bounded fix loop, final whole-branch review) removes that
   per-task steering, but the handoff board has no way to say "this handoff has a plan."
   The board is the envelope; the plan is the payload; there is no link between them.
2. **The `plan:` field.** Optional frontmatter on a coordination doc. A repo-relative path
   to a task-structured plan (`Task N` headings, Global Constraints, exact steps). Its
   presence is the declaration that the handoff is plan-shaped. Absent = today's behavior.
3. **The `--plan` flag and validation.** `handoff new --plan PATH`. Refuse a leading `/`,
   a `..` segment, or a `:`. Store verbatim otherwise. No hard existence check — a
   missing file at `new` time prints a stderr warning ("may be filed later") but does
   not refuse; the hard check is the brief's preflight, which verifies the plan exists
   in the executor's checkout.
4. **Export and list.** `export` inlines the plan path into the brief so an executor
   without the board follows the plan task-by-task, and adds a plan-existence line to the
   brief's preflight block (alongside the root-commit check) so the executor verifies the
   plan exists in _their_ checkout before proceeding — a missing plan there is a stop
   condition. `list` shows a `Plan` column (path or `—`) so a session can route at a
   glance.
5. **Execution modes.** The routing table: `plan:` present → plan-execution engine;
   mechanical + single checkable definition-of-done + fits the context window → delegate;
   otherwise → manual. The handoff lease wraps whichever runs: claim before, release
   `done --verified-by` after the final review plus the session's own verify.
6. **Tool-agnostic wording.** The committed skill content names no vendor's engine. The
   plan file may; the skill may not.
7. **Non-goals.** No plan _content_ validation (the CLI does not parse the plan's tasks).
   No change to the lease, `--verified-by`, or orchestrator/standalone types. No new
   skill — the behavior lives in `run-handoff` and `delegate-handoff`.

- [ ] **Step 2: Self-review the spec against this plan's Global Constraints**

Check: does the spec keep `plan:` optional and repo-relative? Does it keep the skill
content tool-agnostic? Does it avoid a new skill? Fix inline.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-08-21-handoff-plan-execution-integration-design.md
git commit -m "docs: design the handoff plan-execution integration"
```

---

## Task 2: The `--plan` flag on `handoff new`

Add the flag, the validation, the template field, and the self-test cases. This is the
smallest change that makes a handoff declarably plan-shaped.

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/payload/handoff` (`cmd_new` flag parse
  near the other `new` flags; the coordination `render_tmpl` call **and its fallback
  heredoc branch** (the `else` that echoes the frontmatter by hand — it must gain the
  `plan:` line too, or template-less installs drift); a new `valid_plan` helper near
  `require_value`)
- Modify: `skills/engineering/setup-handoff/assets/handoff-doc-template.md` (add `plan:`)
- Test: `skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh`

**Interfaces:**

- Consumes: `require_value`, `render_tmpl`, the coordination template's `PLACEHOLDER_*`
  tokens.
- Produces: `valid_plan <path>` (exit 0 ok, non-zero with a message otherwise); a `plan:`
  frontmatter field on new coordination docs; `--plan` accepted by `handoff new`.

- [ ] **Step 1: Write the failing self-test**

Append to `handoff.selftest.sh` (follow the file's existing `chk` / `expect_fail`
helpers; use `trash` for any temp cleanup, not `rm -rf`):

```bash
# --- plan: field ---------------------------------------------------------
T_PLAN="$(mktemp -d)"
trap 'trash "$T_PLAN" 2>/dev/null || true' RETURN
plan_doc="$T_PLAN/plan-handoff.md"

# a valid repo-relative plan path is stored verbatim
(cd "$T_PLAN" && git init -q . && bash "$CLI" new plan --plan docs/plans/x.md > /dev/null 2>&1) \
  && grep -q '^plan: docs/plans/x.md$' "$T_PLAN/plan-handoff.md" \
  && pass "new --plan stores a repo-relative path" \
  || fail "new --plan stores a repo-relative path"

# an absolute path is refused
(cd "$T_PLAN" && bash "$CLI" new plan-abs --plan /etc/passwd > /dev/null 2>&1) \
  && fail "new --plan refuses an absolute path" \
  || pass "new --plan refuses an absolute path"

# a path with a parent-dir segment is refused
(cd "$T_PLAN" && bash "$CLI" new plan-dotdot --plan ../workspace/outside.md > /dev/null 2>&1) \
  && fail "new --plan refuses a .. segment" \
  || pass "new --plan refuses a .. segment"

# a path with a colon is refused (frontmatter rule)
(cd "$T_PLAN" && bash "$CLI" new plan-colon --plan 'docs:plans/x.md' > /dev/null 2>&1) \
  && fail "new --plan refuses a colon" \
  || pass "new --plan refuses a colon"

# no --plan leaves the field empty (optional)
(cd "$T_PLAN" && bash "$CLI" new noplan > /dev/null 2>&1) \
  && grep -q '^plan: $' "$T_PLAN/noplan-handoff.md" \
  && pass "new without --plan leaves plan: empty" \
  || fail "new without --plan leaves plan: empty"

# a missing plan file warns on stderr but is still stored (no hard check)
(cd "$T_PLAN" && bash "$CLI" new plan-missing --plan docs/plans/missing.md > /dev/null 2> "$T_PLAN/err.txt") \
  && grep -q 'plan file not found' "$T_PLAN/err.txt" \
  && grep -q '^plan: docs/plans/missing.md$' "$T_PLAN/plan-missing-handoff.md" \
  && pass "new --plan warns on a missing file but stores it" \
  || fail "new --plan warns on a missing file but stores it"
```

- [ ] **Step 2: Run the self-test to verify it fails**

Run: `bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh`
Expected: the six `plan:` cases FAIL (flag not yet parsed; field not yet in the template).

- [ ] **Step 3: Add the `plan:` field to the coordination template**

In `handoff-doc-template.md`, after the `note:` line in the frontmatter:

```yaml
note: PLACEHOLDER_NOTE
plan: PLACEHOLDER_PLAN
---
```

`PLACEHOLDER_PLAN` renders empty when `--plan` is not given, so the field is present but
blank — optional by absence of a value, not absence of the key.

- [ ] **Step 4: Add the `valid_plan` helper and the `--plan` flag**

Near `require_value` in the `handoff` CLI:

```bash
valid_plan() { # valid_plan <path> — repo-relative, no colon, no parent-dir segment
  local p=$1
  case "$p" in
    /*) die "plan path must be repo-relative (no leading /): $p" ;;
    *:*) die "plan path must not contain a colon: $p" ;;
  esac
  case "/$p/" in
    *../*) die "plan path must not contain a .. segment: $p" ;;
  esac
}
```

In `cmd_new`'s flag loop, alongside the other `new` flags:

```bash
      --plan)
        require_value --plan "$#" "${2:-}"
        plan=$2; shift 2 ;;
```

Initialize `plan=` next to the other `new` flag defaults, validate before rendering,
and warn (do not refuse) when the file is missing:

```bash
[ -n "$plan" ] && valid_plan "$plan"
[ -n "$plan" ] && [ ! -f "$plan" ] \
  && echo "warning: plan file not found: $plan (may be filed later)" >&2
```

Then add the token to the coordination `render_tmpl` call (the one that renders
`handoff-doc-template.md`, not the orchestrator/standalone ones):

```bash
render_tmpl "$tmpl" "PLACEHOLDER_ID=$id" "PLACEHOLDER_TITLE=$title" \
  "PLACEHOLDER_AUDIENCE=$audience" "PLACEHOLDER_SEVERITY=$severity" \
  "PLACEHOLDER_CREATED=$d" "PLACEHOLDER_UPDATED=$d" \
  "PLACEHOLDER_NOTE=$note" "PLACEHOLDER_PLAN=${plan:-}" > "$target"
```

And in the fallback heredoc branch of the same `else`, after the `note:` echo:

```bash
[ -n "$plan" ] && echo "plan: $plan"
```

(Only echo the line when set, so a template-less install without `--plan` stays
byte-identical to today's output.)

- [ ] **Step 5: Run the self-test to verify it passes**

Run: `bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh`
Expected: all `plan:` cases PASS, no regressions in the existing cases.

- [ ] **Step 6: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/payload/handoff \
  skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh \
  skills/engineering/setup-handoff/assets/handoff-doc-template.md
git commit -m "feat: add an optional plan field to handoff new"
```

---

## Task 3: Wire the plan into `export` and `list`

An offline executor must get the plan path in the brief; a session must see it in `list`
to route at a glance.

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/payload/handoff` (`cmd_export`
  `render_tmpl` call; `cmd_list` row rendering)
- Modify: `skills/engineering/setup-handoff/assets/handoff-brief-template.md` (a "Plan"
  section)
- Test: `skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh`

**Interfaces:**

- Consumes: `meta <doc> plan`, `doc_section`, the brief template's `PLACEHOLDER_*` tokens.
- Produces: a "Plan" subsection and a plan-existence preflight line in the exported
  brief; a `Plan` column in `handoff list`.

- [ ] **Step 1: Write the failing self-test**

Append to `handoff.selftest.sh`:

```bash
# export inlines the plan path into the brief
(cd "$T_PLAN" && bash "$CLI" export plan --to dev > /dev/null 2>&1) \
  && grep -q 'docs/plans/x.md' "$T_PLAN/.agents/handoff/briefs/plan.brief.md" \
  && pass "export inlines the plan path" \
  || fail "export inlines the plan path"

# export adds a plan-existence preflight check to the brief
(cd "$T_PLAN" && bash "$CLI" export plan --to dev > /dev/null 2>&1) \
  && grep -q '\[ -f "docs/plans/x.md" \]' "$T_PLAN/.agents/handoff/briefs/plan.brief.md" \
  && pass "export adds the plan preflight check" \
  || fail "export adds the plan preflight check"

# list shows a Plan column
(cd "$T_PLAN" && bash "$CLI" list 2> /dev/null | grep -q 'docs/plans/x.md') \
  && pass "list shows the plan path" \
  || fail "list shows the plan path"
```

- [ ] **Step 2: Run the self-test to verify it fails**

Run: `bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh`
Expected: the three new cases FAIL.

- [ ] **Step 3: Add the "Plan" subsection and the preflight check to the brief template**

The brief template is now numbered (0. Preflight, 1. Your assignment, 2. Executor
contract, …). Two additions:

In "0. Preflight", inside the existing `sh` code block, after the root-commit check —
the plan-existence check, rendered only when a plan is linked:

```sh
[ "$(git rev-list --max-parents=0 HEAD | tail -1)" = "PLACEHOLDER_ROOT_COMMIT" ] \
  && echo "OK — correct repo" || echo "WRONG REPO — do not proceed"
PLACEHOLDER_PLAN_PREFLIGHT
```

In "1. Your assignment", after "### Decisions already made", so the plan sits with the
other assignment content:

```markdown
### Plan

PLACEHOLDER_PLAN_SECTION
```

- [ ] **Step 4: Inline the plan in `cmd_export`**

In `cmd_export`, compute both the section and the preflight line, and pass them to the
`render_tmpl` call (the one that fills `PLACEHOLDER_CONTEXT` / `PLACEHOLDER_WHERE` / …):

```bash
local plan_section plan_preflight
plan="$(meta "$f" plan)"
if [ -n "$plan" ]; then
  plan_section="Follow this plan task-by-task: \`${plan}\`. It is the task structure and the spec-compliance reference for your Result."
  plan_preflight="[ -f \"$plan\" ] && echo \"OK — plan present\" || echo \"MISSING PLAN — do not proceed\""
else
  plan_section="No plan is linked. Work from the Context and Where sections above."
  plan_preflight=""
fi
```

Add `"PLACEHOLDER_PLAN_SECTION=$plan_section"` and
`"PLACEHOLDER_PLAN_PREFLIGHT=$plan_preflight"` to that `render_tmpl` call, next to
`"PLACEHOLDER_DECISIONS=…"`. When no plan is linked, the preflight token renders empty
and the brief is byte-identical to today's output.

- [ ] **Step 5: Add the `Plan` column to `cmd_list`**

In `cmd_list`'s coordination-row rendering, add a column that prints `$(meta "$doc" plan)`
or `—` when empty, and add `Plan` to the header row. Keep the column last so the existing
columns' order is unchanged.

- [ ] **Step 6: Run the self-test to verify it passes**

Run: `bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh`
Expected: the three new cases PASS, no regressions.

- [ ] **Step 7: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/payload/handoff \
  skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh \
  skills/engineering/setup-handoff/assets/handoff-brief-template.md
git commit -m "feat: surface the handoff plan in export and list"
```

---

## Task 4: The skill content — execution modes and routing

The judgment layer. `run-handoff` gains the routing table and the "the lease wraps the
engine" rule; `delegate-handoff` gains the plan-as-review-reference note. All wording is
tool-agnostic.

**Files:**

- Modify: `skills/engineering/run-handoff/SKILL.md` (new "Execution modes" section, two
  anti-patterns)
- Modify: `skills/engineering/delegate-handoff/SKILL.md` (one note in "Reviewing the
  return")
- Modify: `skills/README.md`, `AGENTS.md` (catalog one-liner for `run-handoff`)

**Interfaces:**

- Consumes: the `plan:` field from Task 2, the `list` Plan column from Task 3.
- Produces: a documented routing decision (plan-driven / delegate / manual) and the rule
  that the handoff lease wraps whichever engine runs.

- [ ] **Step 1: Add the "Execution modes" section to `run-handoff`**

Insert after section 3 ("File a new handoff…"), before section 4 ("Work under the
lease"). Wording must name no vendor's engine:

```markdown
## Execution modes — how a claimed handoff gets done

Claiming a handoff does not say how the work is done. Route by shape, then let the
lease wrap whichever runs: claim before, release `done --verified-by` after the final
review plus your own verify.

| Mode            | Signal                                                                | How                                                                                                                                                                                                                |
| --------------- | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Plan-driven** | The doc has a `plan:` field                                           | Run the tool's plan-execution engine over that plan — a fresh implementer per task, a spec+quality review after each, a bounded fix loop, a final whole-branch review. You steer the plan up front, not each task. |
| **Delegate**    | Mechanical, one checkable definition of done, fits the context window | `run-delegate-agent`: assess, ask, brief, dispatch, verify.                                                                                                                                                        |
| **Manual**      | Needs this session's judgment, context, or architecture               | Execute in-session, steering as you go.                                                                                                                                                                            |

A `plan:` is the declaration that a handoff is plan-shaped. The engine is overkill for
one or two tasks — route those to delegate or manual. If the execution session's tool has
no plan-execution engine, the plan still works as a manual task-by-task guide; you lose
the automated per-task review, not the structure.
```

- [ ] **Step 2: Add two anti-patterns to `run-handoff`**

Append to the existing "Anti-patterns" list:

```markdown
- Running the plan-execution engine on a one- or two-task handoff → the per-task review
  overhead does not pay off; route it to delegate or manual.
- Releasing `done` on the engine's final review alone → the review is the engine's
  evidence, not yours. Run your own verify and pass it as `--verified-by`.
```

- [ ] **Step 3: Add the plan note to `delegate-handoff`**

In "4. Reviewing the return", after the "Read the PR diff first. Read the Result
second." paragraph, add:

```markdown
If the handoff carried a `plan:`, the plan is the spec-compliance reference for the
return: check the diff against the plan's tasks the way a task reviewer would, not just
against the Result's narrative.
```

- [ ] **Step 4: Update the catalog one-liners**

In `skills/README.md` and `AGENTS.md`, extend the `run-handoff` purpose to mention that a
claimed handoff routes to a plan-execution engine, a delegate dispatch, or manual
execution by shape.

- [ ] **Step 5: Verify the standalone rule holds**

Run: `scripts/verify-standalone.sh --staged`
Expected: exit 0 — no vendor engine name leaked into the skill content.

- [ ] **Step 6: Commit**

```bash
git add skills/engineering/run-handoff/SKILL.md skills/engineering/delegate-handoff/SKILL.md \
  skills/README.md AGENTS.md
git commit -m "docs: add execution-mode routing to run-handoff"
```

---

## Task 5: The harness cases

Cover the new behavior in the `run-handoff` workspace. (The `delegate-handoff` grader
the offline-delegation plan once left open is now complete — `grade.py` and `evals/`
exist — so this task only adds the plan-field cases.)

**Files:**

- Modify: `harness/run-handoff-workspace/evals/` (cases), `harness/run-handoff-workspace/grade.py`
  (assertions)

**Interfaces:**

- Consumes: the `run-handoff-workspace` fixture board, `harness/lib/grade_common.py`.
- Produces: graded cases for `--plan`, validation refusals, export inlines plan, list
  column.

- [ ] **Step 1: Add `run-handoff` eval cases**

Add cases that: (a) `new --plan docs/plans/x.md` produces a doc with `plan:
docs/plans/x.md`; (b) `new --plan /abs`, `--plan ../workspace/x`, and `--plan 'a:b'` each refuse;
(c) `new --plan` with a missing file warns on stderr but still stores the path;
(d) `export` of a plan-bearing doc inlines the path into the brief and adds the
plan-existence preflight line; (e) `list` shows the plan path in the Plan column.
Follow the workspace's existing case shape.

- [ ] **Step 2: Extend `run-handoff` `grade.py`**

Add assertions matching the four cases, using `grade_common.py` helpers. Run the grader
against the fixture board.

- [ ] **Step 3: Run the grader**

Run: `python3 harness/run-handoff-workspace/grade.py`
Expected: all cases, including the new plan-field ones, pass.

- [ ] **Step 4: Commit**

```bash
git add harness/run-handoff-workspace
git commit -m "test: cover the handoff plan field"
```

---

## Task 6: Bump the payload version and re-sync the mirrors

The CLI and both templates changed, so the installed-payload version stamp moves and every
fixture copy of the payload must match the source of truth.

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/payload.version`
- Modify: every `harness/**/fixtures/**/.agents/handoff/handoff` and
  `harness/**/fixtures/**/.agents/handoff/templates/handoff-{doc,brief}-template.md`

**Interfaces:**

- Consumes: the final Task 2–3 payload and templates.
- Produces: `setup-handoff 7`; fixture mirrors byte-identical to the source of truth.

- [ ] **Step 1: Bump the version**

Set `skills/engineering/setup-handoff/scripts/payload.version` to `setup-handoff 7`.

- [ ] **Step 2: Re-sync the fixture mirrors**

Copy the updated `handoff` CLI and the two templates into every fixture that carries a
mirror. As of the recheck, the mirrors live under:

- `harness/delegate-handoff-workspace/fixtures/{exportable,returned-clean,bundle,returned-hostile}/.agents/handoff/`
- `harness/setup-handoff-workspace/fixtures/{legacy-config,claude-wired,advisory-wired}/.agents/handoff/`
- `harness/run-handoff-workspace/fixtures/board-wired/.agents/handoff/`
- `harness/repair-handoff-workspace/fixtures/{healthy,orphaned-lease}/.agents/handoff/`

(Re-run `find harness -path "*fixtures*" -name handoff` at execution time — the set may
have grown.) Do not hand-edit the mirrors — copy from
`skills/engineering/setup-handoff/scripts/payload/` and `assets/`.

- [ ] **Step 3: Run the full verification**

Run, in order:

```bash
bash skills/engineering/setup-handoff/scripts/payload/handoff.selftest.sh
bash skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh <fixture-repo>
scripts/verify-standalone.sh
python3 harness/run-handoff-workspace/grade.py
python3 harness/delegate-handoff-workspace/grade.py
```

Expected: self-test all PASS; verifier 0 failed; standalone exit 0; both graders green.

- [ ] **Step 4: Commit**

```bash
git add skills/engineering/setup-handoff/scripts/payload.version harness/
git commit -m "build: bump the handoff payload to 7 and re-sync the fixture mirrors"
```

---

## Adopted flow (reference for steering)

The workflow this plan enables, end to end:

- **Session 1 — design & decompose (you steer).** `grill-me` / `grill-with-docs` → write
  the **spec** (the binding authority) → file the **orchestrator + child handoffs** →
  **route each child** (plan-driven / delegate / manual) → for each plan-driven child,
  write the **plan** (`Task N` structure, Global Constraints, exact steps) and set it as
  the child's `plan:` field.
- **Session 2+ — execute (fresh, one per child).** `handoff claim <id>` → read the doc →
  route by shape → plan-driven children run the tool's plan-execution engine (you steer
  the plan up front, not each task; you step in only at the engine's stop conditions) →
  your own final verify → `handoff release <id> --status done --verified-by "…"`.

The two behavioral shifts this introduces: **per-plan steering, not per-task steering**,
and **retrospective rulings** (the engine's controller records execution rulings; you
review them at the end and rework what was wrong). A handoff you cannot let go of routes
to manual — that is the escape hatch the routing table exists for.
