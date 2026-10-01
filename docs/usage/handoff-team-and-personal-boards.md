# Team board and personal board — a guide for team members

You work with two handoff boards:

- **The team board** — one per team, shared by everyone. Claims, assignments, reviews and issue
  notifications all happen here. If another person needs to see it, it belongs here.
- **Your own board** — optional, private to you. Drafts, notes, half-formed plans, anything not
  ready for the team. Nobody else reads it, so nothing on it coordinates anything.

The rule that makes this work: **claim on the team board, always.** A lease on a board nobody else
reads stops nobody from starting the same work.

This guide uses a fictional company, `acme`, whose projects live in one folder per developer. Swap
in your own names.

## 1. What it looks like on disk

```text
~/work/acme/                             your workspace root
├── .agents/
│   └── handoff-dev-a/                   YOUR board      → github.com/dev-a/handoff-board  (private)
└── src/                                 the one folder holding every project clone
    ├── .agents/
    │   └── handoff/                     TEAM board      → github.com/acme/team-board      (private)
    ├── acme-api/                        .agents/handoff.json → board ../.agents/handoff, group api
    ├── acme-web/                        .agents/handoff.json → board ../.agents/handoff, group web
    └── acme-lib/                        .agents/handoff.json → board ../.agents/handoff, group libs
```

Why these two places:

- **Setup finds a board by looking in the project and up to two folders above it**
  ([ADR 0010](../adr/0010-a-repo-finds-its-board-locally.md)). From `src/acme-api`, it finds
  `src/.agents/handoff` one level up — the team board, and only the team board.
- **Your own board must not sit where setup looks.** `.agents/handoff-dev-a` is a name setup never
  searches for, so it is never proposed in place of the team board
  ([ADR 0022](../adr/0022-the-team-board-is-the-one-setup-finds-and-a-developers-own-board-is-reached-by-name.md)).
  Had it been called `~/work/acme/.agents/handoff`, every setup run in every project would find two
  boards and stop to ask which one.
- **Already had a board in `src/.agents/handoff`?** Rename it out of the way first — for example to
  `src/.agents/handoff-old` or `~/work/acme/.agents/handoff-dev-a` — then clone the team board into
  `src/.agents/handoff`.

## 2. One-time setup

### 2.1 Join the team board

```bash
git clone https://github.com/acme/team-board.git ~/work/acme/src/.agents/handoff
```

Then, in each project you work on, run the `setup-handoff` skill (or ask your assistant to "set up
handoff here"). It reports one candidate — the team board — and wires the project to it with the
project's group. If your team declares groups centrally, the
[`register-cross-repo-handoff`](../../skills/engineering/register-cross-repo-handoff/SKILL.md) sync
wires every project at once.

### 2.2 Tell the board who you are

In each project, `.agents/handoff.local.json` (never committed) carries your identity:

```json
{
  "handle": "dev-a",
  "hostAccount": "dev-a",
  "boards": {
    "github.com/dev-a/handoff-board": "/home/dev-a/work/acme/.agents/handoff-dev-a"
  }
}
```

- **`handle` must be exactly your GitHub login.** The board assigns issues by handle; a handle that
  is not a login fails to assign and says nothing. The verifier warns when `handle` and
  `hostAccount` differ ([ADR 0023](../adr/0023-who-does-the-work-is-told-through-the-tracker-and-the-board-names-only-the-reviewer.md)).
- **`hostAccount`** is the GitHub account this board writes issues as. `mirror` refuses to run
  under any other account.
- **`boards`** records where your own board lives, so `list` can show the status of a wait on it.
  It does **not** change which board the project uses.

**Never record your own board with `--local-board`.** That flag makes it the project's board, and
every claim you make in that project lands where nobody else looks. Setup warns before it does
that.

### 2.3 Optional — your own board

Create a **private** repository for it (setup refuses a public one), then:

```bash
bash "$SKILL_DIR/scripts/setup-handoff.sh" --board-only ~/work/acme/.agents/handoff-dev-a \
  --groups api,web,libs --layout subfolder --remote https://github.com/dev-a/handoff-board.git
```

Use the same group names as the team board, so a draft moves across without renaming.

### 2.4 Two GitHub accounts on one machine

If your work account and your personal account are both signed in to `gh`, git uses whichever is
**active** — and a private board under the other one answers "Repository not found". Pin each
board clone to its account in that clone's own config, instead of switching accounts machine-wide:

```bash
cd ~/work/acme/src/.agents/handoff
git config --local --add credential.https://github.com.helper ''
git config --local --add credential.https://github.com.helper \
  '!f() { GH_TOKEN="$(gh auth token --user ACCOUNT)" gh auth git-credential "$@"; }; f'
```

Replace `ACCOUNT` with the login that owns that board. The token is read at the moment git needs
it and never written to disk.

## 3. Daily workflow

```text
   YOUR board                                TEAM board                          project issues
   ──────────                                ──────────                          ──────────────
   draft, notes  ── handoff move ──────────►  open handoff  ── mirror ──────────►  issue
   (nobody sees)    (you name the target)     claim → work →                       (assignee gets
                                              release / review                      notified)
```

### Planning work for someone else

The senior developer files the work on the team board and names themselves as reviewer:

```bash
handoff new rate-limit --title "Rate-limit the public API" --audience acme-api --reviewer senior-a
```

Then, on the mirrored issue, add the developer who will do it as an **assignee**. GitHub notifies
them; the board never overrides an assignee you set by hand. The board names only the reviewer —
who does the work is told through the issue (ADR 0023).

### Picking up assigned work

```bash
handoff claim rate-limit "starting — token bucket per key"
# ... work ...
handoff checkpoint rate-limit "bucket in place, tests for burst still to write"
handoff release rate-limit --for-review "done; tests green" --reviewer senior-a
```

Claim **when you start**, not when you are assigned — the lease is about who is working right now
and it expires on its own. `--for-review` hands it back without closing it; the reviewer claims it and closes it with their
own evidence:

```bash
handoff claim rate-limit "reviewing"
handoff release rate-limit --status done --verified-by "pnpm test — 42 passed, 0 failed"
```

### Work that depends on another group's work

A bare id always means your own group. Name another group's handoff as `group/id`:

```bash
handoff new consume-dto --title "Use the new DTO" --audience acme-api --after libs/shared-dto
```

`claim` warns while `libs/shared-dto` is still open and says nothing once it has landed. It is a
warning, not a lock — you may start against a stub and say so in the doc
([ADR 0021](../adr/0021-a-dependency-across-groups-names-its-group.md)).

### Drafting on your own board, then sharing

```bash
cd ~/work/acme/.agents/handoff-dev-a
HANDOFF_GROUP=api ./handoff new cache-idea --title "Cache the pricing lookup" --audience acme-api

# when the team should see it — moving needs the lease, like any other change:
HANDOFF_GROUP=api ./handoff claim cache-idea "moving it to the team board"
HANDOFF_GROUP=api ./handoff move cache-idea --to ~/work/acme/src/.agents/handoff --group api \
  --to-remote github.com/acme
```

`move` transfers the handoff — your board keeps a pointer, never a copy. Moving to a board under a
different owner refuses unless you name that owner with `--to-remote`, so work never leaks across
by accident ([ADR 0018](../adr/0018-a-trust-boundary-is-its-remote-owner-and-a-child-board-narrows-it.md)).
A handoff marked `sensitivity: restricted` never crosses to a different owner at all.

## 4. What goes where

| Kind of work                                  | Board                       | Why                                           |
| --------------------------------------------- | --------------------------- | --------------------------------------------- |
| Anything someone else will pick up or review  | Team                        | Claims and assignments are only visible there |
| Work that depends on another group            | Team                        | `group/id` only resolves inside one board     |
| An idea you are still shaping                 | Yours                       | Nobody needs to see it yet                    |
| Notes for your own continuity across sessions | Yours                       | Keeps the team board free of noise            |
| A handoff to someone not on the board         | Team, then `handoff export` | The brief leaves; the record stays            |

## 5. When something is off

| Symptom                                         | Cause and fix                                                                                                     |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `claim` says it cannot reach the board's remote | Usually the wrong GitHub account answered — see 2.4. Also check `/opt/homebrew/bin` (or your `gh`) is on `PATH`.  |
| Setup stops and asks which of two boards to use | A second board sits where setup looks. Rename your own board to `.agents/handoff-<you>`.                          |
| Your claims never show up for teammates         | The project was pointed at your own board with `--local-board`. Remove `board` from `.agents/handoff.local.json`. |
| A teammate's assignment never notified you      | Your `handle` is not your exact GitHub login.                                                                     |
| `move` to the team board refuses                | Name the owner: `--to-remote github.com/acme`. A restricted handoff will still refuse — that is intended.         |

## Further reading

- [The handoff usage guide](handoff.md) — every situation the board answers.
- [`run-handoff`](../../skills/engineering/run-handoff/SKILL.md) — the claim, work, release discipline.
- [`setup-handoff`](../../skills/engineering/setup-handoff/SKILL.md) — installation and options.
