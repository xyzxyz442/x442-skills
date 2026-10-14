# Graph hooks — setting up "query, don't grep"

An assistant that greps a repo, then reads every file the grep matched, spends most of its context
on text it did not need. The graph suite replaces that with a structural index. Two tools build it:
**code-review-graph** (MCP tools for symbol search, callers and blast radius) and **graphify** (a
CLI for exploration and paths between concepts). A layer of hooks keeps the index fresh and steers
the assistant to it before it reaches for `grep`.

This page covers getting there: what to install, what to run, and what to check. What happens
while you work (the cheatsheet, the grep gate, the refresh, the search tiers) is covered in
[How the graph tools work during development](../graph-tools-during-development.md). This page
does not repeat it.

| Skill                                                                                      | Use it to                                                            |
| ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------- |
| [`setup-graph-hooks`](../../skills/engineering/setup-graph-hooks/SKILL.md)                 | wire a repo the first time, or upgrade it                            |
| [`repair-graph-hooks`](../../skills/engineering/repair-graph-hooks/SKILL.md)               | fix a graph that is stale, empty, duplicated or failing its verifier |
| [`register-cross-repo-graph`](../../skills/engineering/register-cross-repo-graph/SKILL.md) | give one repo read-only access to a sibling repo's graph             |

---

## Per developer — install the tools

```bash
pipx install code-review-graph
pipx install graphifyy # PyPI name has two y's; the command is `graphify`
```

That is the only per-developer step. The hooks, the `AGENTS.md` routing block and the MCP
registration are committed in the repo. The graph itself (`.code-review-graph/`, `graphify-out/`)
is gitignored, because it is rebuilt from source. Each clone builds its own.

Do **not** run a bare `code-review-graph install`. It defaults to every platform it can find,
writes its own instruction blocks into your context files, and merges its own refresh hook, which
then competes with the repo's. If a repo needs the MCP server registered again, use the flags the
skill uses:

```bash
code-review-graph install --platform claude-code --no-hooks --no-instructions --no-skills
python3 .graph-hooks/portable-mcp.py # strip this machine's absolute path before committing
```

Do not add `graphify hook install` either. Git's `post-commit` hook already refreshes graphify,
and a second hook would refresh it twice.

---

## Per repo — wire it once

Prerequisites: an `AGENTS.md` at the repo root (run `initial-project` first) and a git working
tree. Run `setup-project-tooling` before this if the repo will use husky. The graph's `post-commit`
hook goes into `.husky/` when husky is present and into `.git/hooks/` otherwise.

Run **`/x442-setup-graph-hooks`**. It asks three things:

1. **Which assistants to wire.** Claude Code, Gemini CLI, Copilot, Antigravity. Pick everything
   the team uses. Claude Code, Gemini CLI, and Copilot each get their own hook config pointing at
   the same shared scripts in `.graph-hooks/`. Antigravity is gated: the installer writes only an
   inert `.agents/hooks.json.example` and never activates it. Antigravity still gets the git
   refresh and the `AGENTS.md` routing block.
2. **Which one is the primary refresh owner.** Exactly one assistant refreshes the graph at end of
   turn. More than one would rebuild the same graph concurrently. Pick the one most people use, or
   "None" to rely on the git hook alone.
3. **Which search tier to use.** Keyword, local, or custom embeddings. See
   [Semantic search](#semantic-search--decide-once-per-repo).

It then splices a routing block into `AGENTS.md` between `<!-- graph-hooks:begin` and its end
marker. Only that span is managed: edit anything outside it freely. It also runs the verifier and
offers to build the graph.

When Claude is wired, it also sets `chat.useClaudeHooks` in `.vscode/settings.json`, so Copilot
chat in VS Code runs the same Claude-format hooks.

```bash
code-review-graph build # first build; minutes on a large repo, seconds afterwards
graphify update .       # AST only, no API cost
```

---

## Semantic search — decide once per repo

Without embeddings, `semantic_search_nodes_tool` matches symbol names (the **keyword** tier). That
works, and it is the floor. With embeddings it matches by meaning. The skill always asks which tier
you want:

| Tier      | Cost                                                                                             | Notes                                                                                                                                                                                |
| --------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `keyword` | nothing (embeddings off)                                                                         | fine for small repos and well-named code                                                                                                                                             |
| `local`   | about 2 GB of PyTorch plus a 90 MB model, once per machine                                       | the built-in model; no daemon to keep running                                                                                                                                        |
| `custom`  | an OpenAI-compatible endpoint: a local model server such as Ollama or LM Studio, or a hosted API | every call must pin `provider` and `model`, or it silently drops to keyword. A hosted endpoint costs per token and your code leaves the machine, so agree first on where code may go |

Change your mind any time with `setup-embeddings.sh --provider …` from the skill directory. The
choice is stored per clone in the gitignored `.code-review-graph/embed.env`.
[Semantic search is optional](../graph-tools-during-development.md#semantic-search-is-optional)
covers the tiers and how to tell which one answered a query.

---

## Check it

```bash
bash "$SKILL_DIR/scripts/verify-graph-hooks.sh" .
```

`SKILL_DIR` is wherever your install put `x442-setup-graph-hooks`. Easier still, ask the assistant
to "run the graph-hooks verifier". A healthy repo ends with `0 failed`. A `[warn]` on a fresh clone
usually means a tool or a graph is not built yet.

Then confirm the behaviour, not just the wiring:

- A new session opens with a `GRAPH QUERY CHEATSHEET` (exactly one).
- Ask "who calls FUNCTION?" for a function you know. The answer should come from
  `query_graph_tool`, not from `grep`.
- Make a commit. The graph's `last updated` time moves.

---

## When it breaks

Run **`/x442-repair-graph-hooks`**. It smoke-tests both tools first (installed, broken, outdated,
registered), then runs the verifier and checks the graph against `HEAD`: stale, corrupt, empty,
half-embedded, stale locks, CRLF in a hook script. It backs up the tool configs before touching
them. It re-runs the installer with the same tools you chose originally. It only _offers_ heavy
rebuilds, never runs them unasked. On a healthy repo it changes nothing.

| Symptom                                                               | Likely cause                                                                                                                                                                                                                                           |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| two cheatsheets at session start                                      | personal copies of older graph hooks in `~/.claude/`. The verifier warns `user_hooks.predecessor`; trash the scripts it names. See [check 3 of the existing-developer audit](onboarding-existing-developer.md#3-personal-hooks-that-predate-the-repos) |
| graph never updates after commits                                     | husky arrived after graph setup, so the hook sits in `.git/hooks/`, which git no longer reads                                                                                                                                                          |
| `semantic_search_nodes_tool` says `keyword` although embeddings exist | custom-provider vectors need `provider` and `model` pinned on every call                                                                                                                                                                               |
| graph tools missing in a session                                      | the project MCP server was never approved. Run `/mcp`                                                                                                                                                                                                  |
| everything empty on a WSL clone                                       | the repo is under `/mnt/c`. Move it into the Linux filesystem; see [Platforms](platforms.md)                                                                                                                                                           |

---

## Sibling repos

When one repo needs symbols from another, run `/x442-register-cross-repo-graph` from the consumer
repo. You list the siblings in a committed `.graph-repos.json`, preview with `--dry-run`, then
sync. The siblings' graphs become queryable read-only, and `AGENTS.md` records which repos are in
scope, so the assistant knows where it may look.
[Cross-repo lookups](../graph-tools-during-development.md#cross-repo-lookups) has the full flow and
a worked cost example.
