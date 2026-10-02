# VS Code runs the Claude-format hooks — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a repo wires Claude, VS Code chat runs the committed Claude-format hooks, and the `.github/hooks/` files stay for Copilot CLI and the cloud agent. Fix the two hook bugs that block this.

**Architecture:** setup-graph-hooks moves Claude's graph hooks into the committed `.claude/settings.json`. Both setup skills write Claude-format commands that fall back to the git root. Both skills ship one helper, `vscode-hooks.py`, that sets `chat.useClaudeHooks` and switches off only that skill's own Copilot file, and only when the Claude-format file covers it. Both verifiers call the same helper in `--check` mode.

**Tech Stack:** bash, python3 (stdlib only), JSON. Each script carries its own `--selftest`. Harness graders live under `harness/<skill>-workspace/grade.py`.

**Spec:** [docs/adr/0024-vs-code-runs-the-claude-format-hooks-when-a-repo-wires-claude.md](../../adr/0024-vs-code-runs-the-claude-format-hooks-when-a-repo-wires-claude.md)

## Global Constraints

- Never `rm`. Shipped scripts never delete user files; they print a note instead.
- Do not add an emoji or a `:` in any frontmatter value. Use imperative voice. Cite upstream docs for vendor behavior.
- Name no real company, team or repo. Use `acme-*` placeholders (`scripts/verify-standalone.sh`).
- A setup-graph-hooks payload edit (`scripts/graph-hooks/**`) moves `scripts/payload.version` in the **same commit** (`scripts/verify-payload-version.sh --staged`).
- The setup-handoff payload (`scripts/payload/**`) does not change. Its verifier already flags stale wiring through `merge-hooks.py --check`, so `payload.version` stays at 69.
- Conventional Commits, checked by `commitlint.config.mjs`. Do not use `--no-verify`.
- Never let prettier rewrite the secret-guard leak fixtures (`format-check-is-red-on-main`).

## Review Focus

1. A `.vscode/settings.json` with comments or trailing commas is never rewritten. The installer prints the two settings and the verifier warns (Task 4, `test_jsonc_refused`).
2. A `chat.*` key the user set, or another file's entry in `chat.hookFilesLocations`, survives every apply, including the other skill's (Task 4, `test_preserves_foreign_keys`).
3. When Copilot is the primary, its file stays on in VS Code. A repo that drops Claude, or whose primary moves to Copilot, gets its earlier `false` removed (Task 4, `test_uncovered_removes_our_false`).
4. A matcher-less VS Code payload sends terminal input to the read gate and read input to the shell gate. Neither may deny or advise (Task 1, extract selftest).
5. A Claude-format handoff command run from a subdirectory with `CLAUDE_PROJECT_DIR` unset still resolves the repo root (Task 2, merge-hooks selftest).

---

### Task 1: Graph hook core — Claude deny spelling and VS Code payloads

**Files:**

- Modify: `skills/engineering/setup-graph-hooks/scripts/graph-hooks/core/emit.py` (header line 17, `translate` line 51, selftest around line 106)
- Modify: `skills/engineering/setup-graph-hooks/scripts/graph-hooks/core/extract.py` (`extract` readtarget, `_selftest`)
- Modify: `skills/engineering/setup-graph-hooks/scripts/payload.version` (`setup-graph-hooks 4` → `setup-graph-hooks 5`)
- Modify: `harness/setup-graph-hooks-workspace/grade.py` (lines 208, 222, 249: `"block"` → `"deny"`)
- Modify: fixture copies of `.graph-hooks/core/{emit,extract}.py` under `harness/setup-graph-hooks-workspace/fixtures/*` and `harness/repair-graph-hooks-workspace/fixtures/*`. Copy only where the fixture already held a byte-identical copy of the old file; a fixture that is deliberately broken keeps its breakage.
- Modify: `skills/engineering/setup-graph-hooks/SKILL.md` (the per-tool contract table, if it says `block`)

**Interfaces:**

- Produces: `translate(deny, "claude", "pretool")["hookSpecificOutput"]["permissionDecision"] == "deny"`. `extract(payload, "readtarget")` also reads `filePath`.

- [ ] **Step 1: Flip the selftest to the documented value.** In `emit.py` `_selftest`, change the Claude assertion to `"permissionDecision": "deny"`, and make the comment say `"deny"`, which is what Claude Code accepts (`allow|deny|ask|defer`, https://code.claude.com/docs/en/hooks). `"block"` was the old top-level spelling. Change the Copilot comment `"deny" not "block"` to say Claude and Copilot now use the same value and differ only in nesting. Add `assert "block" not in json.dumps(translate(deny, "claude", "pretool"))`.
- [ ] **Step 2: Run it and watch it fail.** `python3 skills/engineering/setup-graph-hooks/scripts/graph-hooks/core/emit.py --selftest`. Expected: AssertionError on the Claude deny.
- [ ] **Step 3: Fix it.** Line 51: `hso["permissionDecision"] = "deny"`. Header line 17: `permissionDecision="deny"`.
- [ ] **Step 4: Add VS Code payloads to the extract selftest.** VS Code sends PascalCase events with snake_case fields (`tool_name`, `tool_input`) and ignores matchers. Add:

```python
    # VS Code runs Claude-format hooks with matchers IGNORED (ADR 0024): every PreToolUse kind
    # sees every tool. A terminal call reaching the read gate, or a file read reaching the shell
    # gate, must extract nothing -- an empty field is "no match", and the call passes.
    vsc_term = {"tool_name": "run_in_terminal", "tool_input": {"command": "grep -rn foo src/"}}
    vsc_read = {"tool_name": "read_file", "tool_input": {"filePath": "src/a.ts"}}
    assert extract(vsc_term, "readtarget") == "", "terminal call must not look like a read"
    assert extract(vsc_read, "command") == "", "file read must not look like a shell command"
    assert extract(vsc_read, "readtarget") == "src/a.ts", "VS Code spells it filePath"
```

- [ ] **Step 5: Run it and watch it fail** on the `filePath` assertion: `python3 skills/engineering/setup-graph-hooks/scripts/graph-hooks/core/extract.py --selftest`.
- [ ] **Step 6: Fix it.** In `extract` readtarget, use `str(ti.get("file_path") or ti.get("filePath") or "")`.
- [ ] **Step 7: Run both selftests (they must pass), then update the grader and the fixtures.** Change `grade.py` lines 208/222/249 to `"deny"`. List the fixture copies with `cmp -s` against the old blob (`git show HEAD:skills/.../core/emit.py`), and copy the new file only over the identical ones. Bump `payload.version` to `setup-graph-hooks 5`.
- [ ] **Step 8: Grade the setup-graph-hooks and repair-graph-hooks workspaces** using the harness runner documented in `docs/harness-structure.md`. Expected: the same pass/fail set as on `main`, with the grep-gate cases now asserting `deny`.
- [ ] **Step 9: Commit** `fix(setup-graph-hooks): spell the claude grep-gate deny as deny`. Stage the payload, `payload.version`, the grader and the fixtures in this one commit.

### Task 2: setup-handoff — Claude commands fall back to the git root

**Files:**

- Modify: `skills/engineering/setup-handoff/scripts/merge-hooks.py` (`command`, lines 93-105, and its selftest)
- Modify: `skills/engineering/setup-handoff/scripts/verify-setup-handoff.sh:154` (board-path derivation)
- Modify: `harness/delegate-handoff-workspace/fixtures/*/.claude/settings.json`, only if a grader run reports wiring drift on them
- Modify: `skills/engineering/setup-handoff/SKILL.md` (wherever the Claude command form is shown)

**Interfaces:**

- Produces: `command(hdpath, "claude", kind)` ==
  `R="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"; bash "$R/<hdpath>/scripts/hooks.sh" --kind <kind> --tool claude --project-dir "$R"`.
  `is_managed` still matches it, because it contains `/scripts/hooks.sh` and `--kind `.

- [ ] **Step 1: Write the failing selftest.** In merge-hooks.py's selftest, add an assertion that `"${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel" in command(".agents/handoff", "claude", "pretool-edit")`, and an execution test. In a temp git repo, create `.agents/handoff/scripts/hooks.sh` that echoes `"$@"`. Run the command with `subprocess.run(["bash", "-c", cmd], cwd=<repo>/sub, env=<env without CLAUDE_PROJECT_DIR>)`, and assert stdout contains `--project-dir <realpath repo>`. Also assert `is_managed(<new command>)` and `is_managed(<old $CLAUDE_PROJECT_DIR form>)`; the old form must still count as ours so a re-run replaces it.
- [ ] **Step 2: Run** `python3 skills/engineering/setup-handoff/scripts/merge-hooks.py --selftest` and watch it fail.
- [ ] **Step 3: Implement.** Add a module constant `ROOT = 'R="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"; '`, with a comment that VS Code and Copilot CLI read this file but do not set `CLAUDE_PROJECT_DIR` (ADR 0024). It is the same resolver graph hooks use. The Claude branch returns `f'{ROOT}bash "$R/{hdpath}/scripts/hooks.sh" --kind {kind} --tool claude --project-dir "$R"'`.
- [ ] **Step 4: Run the selftest (it must pass) and fix the verifier derivation.** In `verify-setup-handoff.sh`, after `D="${DERIVED##*CLAUDE_PROJECT_DIR/}"` add `D="${D#\$R/}"` (literal `$R/`). The grep `[^" ]*/(scripts/)?hooks\.sh` now yields `$R/.agents/handoff/scripts/hooks.sh`.
- [ ] **Step 5: Run the setup-handoff selftests and its harness workspace**, plus delegate-handoff, which carries the old form in its fixtures. Expected: no new failures. If the delegate fixtures report `tool.wired` drift, refresh them with `scripts/sync-fixture-boards.sh` if it covers them; otherwise regenerate each fixture's `.claude/settings.json` through `merge-hooks.py` with `HANDOFF_TOOL=claude HANDOFF_PRIMARY=1`.
- [ ] **Step 6: Commit** `fix(setup-handoff): resolve claude hook commands without CLAUDE_PROJECT_DIR`.

### Task 3: setup-graph-hooks — Claude's graph hooks go to the committed settings.json

**Files:**

- Modify: `skills/engineering/setup-graph-hooks/scripts/setup-graph-hooks.sh` (the `claude)` case, lines 189-201)
- Modify: `skills/engineering/setup-graph-hooks/scripts/verify-graph-hooks.sh` (CSET resolution, lines 246-256)
- Modify: `harness/setup-graph-hooks-workspace/grade.py:54` (`CLAUDE_CONFIG`) and any eval that expects `settings.local.json`
- Modify: `skills/engineering/setup-graph-hooks/SKILL.md`, `skills/engineering/repair-graph-hooks/SKILL.md` (file locations)

**Interfaces:**

- Consumes: `merge.py --file F` with stdin `{"hooks": {}}`, which removes only our groups (`replace_managed(entries, [])`) and drops events left empty.
- Produces: the verifier finding IDs `tool.wired` (claude, `.claude/settings.json`) and `claude.legacy_local` (warn: our groups are still in `settings.local.json` or `settings.example.json`).

- [ ] **Step 1: Write the failing grader expectation.** Set `CLAUDE_CONFIG = ".claude/settings.json"`, and add an expectation, after an install on a fixture that already has `settings.local.json` graph groups, that `settings.local.json` holds no `.graph-hooks/hook.sh` command.
- [ ] **Step 2: Grade it and watch it fail** on the install fixtures (`all-wired`, `both-wired`).
- [ ] **Step 3: Implement the installer.** Replace the `claude)` case body with:

```bash
mkdir -p .claude
# Committed, not per-machine (ADR 0024): VS Code runs the Claude-format file for every
# teammate, so a gitignored copy would leave anyone who never ran this installer without
# graph hooks. Our groups come OUT of the local and example files, because VS Code reads
# settings.local.json too and does not de-dupe across files the way Claude Code does.
render claude | merge .claude/settings.json
for legacy in .claude/settings.local.json .claude/settings.example.json; do
  [ -f "$legacy" ] && printf '{"hooks": {}}' | merge "$legacy"
done
echo "  + .claude/settings.json (claude hooks; graph groups removed from local/example)"
```

Keep `.claude/settings.local.json` in the `.gitignore` loop, since it is still a per-machine file. Do not delete `settings.example.json`. If it is left holding only `{"hooks": {}}`, print `  ~ .claude/settings.example.json no longer used by graph hooks — remove it if nothing else needs it`.

- [ ] **Step 4: Implement the verifier.** `CSET=.claude/settings.json` when it carries `--tool claude` with `.graph-hooks/hook.sh`. Otherwise fall back to local, then example, and `warn claude.legacy_local "claude graph hooks in $CSET — re-run setup-graph-hooks to commit them (ADR 0024)"`. Also warn `claude.legacy_local` when settings.json is wired **and** local still carries a `.graph-hooks/hook.sh` command, because VS Code would run it twice. The endturn owner scan (around line 340) must read settings.json first.
- [ ] **Step 5: Grade setup-graph-hooks and repair-graph-hooks.** Expected: Step 1 now passes. The repair fixtures (`healthy`, `missing-core`, `broken-json`) still carry local-only wiring and must now report `claude.legacy_local` as a warning, never a failure. Update any repair eval that asserted zero warnings on `healthy` so that it expects this warning, or migrate that fixture, whichever keeps the eval's intent.
- [ ] **Step 6: Update both SKILL.md files** to name the new location, the migration, and ADR 0024.
- [ ] **Step 7: Commit** `feat(setup-graph-hooks): commit claude graph hooks to settings.json`.

### Task 4: The VS Code switch — `vscode-hooks.py` in both skills

**Files:**

- Create: `skills/engineering/setup-graph-hooks/scripts/config/vscode-hooks.py`
- Create: `skills/engineering/setup-handoff/scripts/vscode-hooks.py` (byte-identical copy; each skill installs on its own)
- Modify: `setup-graph-hooks.sh` (after the Layer 2 loop), `verify-graph-hooks.sh` (section 2)
- Modify: `setup-handoff.sh` (after the per-tool wiring loop), `verify-setup-handoff.sh` (after `check_tool` calls)

**Interfaces:**

- Produces the CLI `vscode-hooks.py --repo DIR --copilot-file REL --claude yes|no --covered yes|no (--apply|--check)`.
  - `--apply`: when `--claude yes`, set `chat.useClaudeHooks: true`. When `--claude yes --covered yes`, set `chat.hookFilesLocations[REL] = false`. Otherwise remove `REL` from `chat.hookFilesLocations` **only if its value is `false`**, and drop the map if that leaves it empty. Never touch any other key. Write only on a data change, with 2-space JSON and a final newline. Create the file only when there is something to set. Exit 0. Exit 3 with no write when the file is not strict JSON, after printing the settings to add by hand.
  - `--check`: print one line `ok|warn|fail <finding-id> <message>`, always exit 0. Findings: `vscode.copilot_off_uncovered` (fail: `REL` is false but not `claude yes` and `covered yes`); `vscode.claude_hooks_off` (warn: claude yes, the Copilot file exists, and `useClaudeHooks` is not true); `vscode.double_run` (warn: claude yes, covered yes, useClaudeHooks true, `REL` not false); `vscode.unreadable` (warn: not strict JSON); otherwise `ok vscode.hook_source ...`.
- [ ] **Step 1: Write the selftest first**, inside the new script, as functions over a temp dir:

```python
def test_covered_switches_our_file_off(tmp):
    apply(tmp, ".github/hooks/graph.json", claude=True, covered=True)
    s = load(tmp)
    assert s["chat.useClaudeHooks"] is True
    assert s["chat.hookFilesLocations"] == {".github/hooks/graph.json": False}

def test_preserves_foreign_keys(tmp):
    write(tmp, {"editor.tabSize": 2, "chat.hookFilesLocations": {"custom/hooks": True, ".github/hooks/handoff.json": False}})
    apply(tmp, ".github/hooks/graph.json", claude=True, covered=True)
    s = load(tmp)
    assert s["editor.tabSize"] == 2
    assert s["chat.hookFilesLocations"] == {"custom/hooks": True, ".github/hooks/handoff.json": False, ".github/hooks/graph.json": False}

def test_uncovered_removes_our_false(tmp):
    write(tmp, {"chat.hookFilesLocations": {".github/hooks/graph.json": False}})
    apply(tmp, ".github/hooks/graph.json", claude=True, covered=False)
    assert "chat.hookFilesLocations" not in load(tmp)

def test_user_true_is_left_alone(tmp):
    write(tmp, {"chat.hookFilesLocations": {".github/hooks/graph.json": True}})
    apply(tmp, ".github/hooks/graph.json", claude=False, covered=False)
    assert load(tmp)["chat.hookFilesLocations"] == {".github/hooks/graph.json": True}

def test_jsonc_refused(tmp):
    raw = '{\n  // mine\n  "editor.tabSize": 2,\n}\n'
    write_raw(tmp, raw)
    assert apply(tmp, ".github/hooks/graph.json", claude=True, covered=True) == 3
    assert read_raw(tmp) == raw

def test_idempotent_no_rewrite(tmp):
    apply(tmp, ".github/hooks/graph.json", claude=True, covered=True)
    m = mtime(tmp); apply(tmp, ".github/hooks/graph.json", claude=True, covered=True)
    assert mtime(tmp) == m

def test_no_claude_no_file(tmp):
    apply(tmp, ".github/hooks/graph.json", claude=False, covered=False)
    assert not exists(tmp)

def test_check_flags_the_teammate_regression(tmp):
    write(tmp, {"chat.useClaudeHooks": True, "chat.hookFilesLocations": {".github/hooks/graph.json": False}})
    assert check(tmp, ".github/hooks/graph.json", claude=False, covered=False).startswith("fail vscode.copilot_off_uncovered")
```

- [ ] **Step 2: Run** `python3 skills/engineering/setup-graph-hooks/scripts/config/vscode-hooks.py --selftest` and watch it fail (functions not defined).
- [ ] **Step 3: Implement** `load`, `apply`, `check` and `main` to the interface above. The header comment cites ADR 0024 and the VS Code hooks doc, and says the script ships identically in both skills and that each skill passes only its own file. Copy the file to setup-handoff, and add a selftest line in each that compares it with the sibling copy when the sibling exists, so the two cannot drift.
- [ ] **Step 4: Wire setup-graph-hooks.** After the Layer 2 loop:

```bash
# ---- VS Code hook source (ADR 0024) ----------------------------------------------------
has() {
  case " $TOOLS_LIST " in *" $1 "*) return 0 ;; esac
  return 1
}
VC_CLAUDE=no
has claude && VC_CLAUDE=yes
VC_COVERED=no
[ "$VC_CLAUDE" = yes ] && has copilot && [ "$PRIMARY" != copilot ] && VC_COVERED=yes
python3 "$HERE/config/vscode-hooks.py" --repo . --copilot-file .github/hooks/graph.json \
  --claude "$VC_CLAUDE" --covered "$VC_COVERED" --apply \
  || echo "  ! .vscode/settings.json is not plain JSON — add the settings above by hand"
```

`TOOLS_LIST` is space-delimited and `PRIMARY` holds the chosen primary (`setup-graph-hooks.sh:26,61`).

- [ ] **Step 5: Wire setup-handoff.** After the per-tool loop: skip entirely under `LOCAL_WIRING=1`, and print instead: `VS Code: set "chat.useClaudeHooks": true in your user settings to run these hooks in VS Code chat`. Otherwise `--claude yes` when claude is among the wired tools, and `--covered yes` when copilot is wired and the primary is not copilot. The tools are `TOOLS` (comma list, split into `TOOL_ARR`) and the primary is `PRIMARY` (`setup-handoff.sh:1133-1141`); test claude/copilot membership with `case ",$TOOLS," in *,claude,*)`.
- [ ] **Step 6: Wire both verifiers** with `--check`, deriving `--claude` and `--covered` from what each verifier already computed. Graph: `WIRED` and the endturn owner. Handoff: `WIRED` and `HARD`, with claude counted only when wired in `.claude/settings.json`. Map the `ok|warn|fail` prefix onto the verifier's own `ok`, `warn` and `bad` functions.
- [ ] **Step 7: Add one harness case per skill.** Install with claude and copilot and a claude primary, then assert `.vscode/settings.json` has `useClaudeHooks` true and the skill's own Copilot file false. Seed a fixture with `.github/hooks/graph.json: false` and no Claude wiring, then assert the verifier reports `vscode.copilot_off_uncovered` as a failure.
- [ ] **Step 8: Run all selftests and both harness workspaces.** Commit `feat(setup-graph-hooks,setup-handoff): point vs code chat at the claude-format hooks`. If commitlint rejects two scopes, split this into one commit per skill.

### Task 5: Docs — where each surface gets its hooks

**Files:**

- Modify: `skills/engineering/setup-graph-hooks/SKILL.md`, `skills/engineering/setup-handoff/SKILL.md` (a "VS Code and Copilot surfaces" subsection: the per-surface table from ADR 0024, the accepted Copilot CLI double run, code review reading `AGENTS.md` only, and the user-level opt-out `"~/.claude/settings.json": false`)
- Modify: `skills/README.md`, only if it describes where hooks are written
- Modify: `docs/usage/` handoff guide, only if it shows the old Claude command form

- [ ] **Step 1: Write the subsections.** Link the ADR and cite the VS Code and GitHub docs. Use imperative voice and no emoji.
- [ ] **Step 2: Run** `pnpm run format:check` (or the repo's documented equivalent), `bash scripts/verify-standalone.sh` and `markdownlint` if wired. Expected: no new failures beyond the 3 already known.
- [ ] **Step 3: Commit** `docs(setup-graph-hooks,setup-handoff): document vs code and copilot hook surfaces`, together with the ADR and this plan if they are not yet committed.

### Task 6: Whole-branch verification

- [ ] Run every touched `--selftest`, the four harness workspaces (setup-graph-hooks, repair-graph-hooks, setup-handoff, delegate-handoff), `bash scripts/verify-payload-version.sh --against main`, `bash scripts/sync-fixture-boards.sh --check` and `bash scripts/verify-standalone.sh`. Report the counts against `main`.
- [ ] Do a fresh-eyes review of the whole branch diff (one reviewer).
- [ ] Hand back to the user for the merge, the version bump and the release, and offer to dogfood: re-running both installers on this repo would commit `.vscode/settings.json` changes here.
