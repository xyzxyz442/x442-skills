---
status: accepted
date: 2026-09-04
---

# Config keys name their subject from their own layer — `repo` and `repoName` both stay

A future reader will find the board config saying `repoName` and a member repo's config
saying `repo`, conclude the handoff cascade has two spellings for one fact, and try to
converge them. We decided to keep both. They sit in different files describing different
subjects, they are never written to the same board, and the resolver already folds them
into one value.

## Context

`handoff-env-term-naming-handoff` opened on the premise that identity had three spellings —
env `HANDOFF_REPO`, board config `repoName`, repo config `repo` — and that converging the
config keys needed a schema bump and a migration. Each round of execution narrowed that
premise, and the last of it does not survive contact with the code:

- `config.sh` already reconciles the spellings on read. A repo config's `repo` maps to
  `repoName`; either spelling resolves. Nothing is broken today.
- **The two keys never co-occur.** `write_board_config` writes `repoName` only when topology
  is not `cross-repo`; `setup-handoff.sh:734-736` leaves `HANDOFF_REPO` empty off a
  cross-repo install, so `merge-hooks.py` writes no repo config for a single-repo board at
  all. A single-repo board names its repo in the board config and has no repo config; a
  cross-repo board must not name any repo in the board config and gets one repo config per
  member. There is no board on which the same repo is named under both spellings.
- `schema` never enters this. It is the board's **document** schema; a config key is not a
  document, and no on-disk board format changes either way.

So what remained was not a migration. It was a naming decision nobody had written down,
which is how it got re-litigated three times.

## Decision

**A config key names its subject from the point of view of the file it sits in.**

- `<board>/handoff.json` describes the board, so `repoName` reads as "the repo this board
  belongs to".
- `<repo>/.agents/handoff.json` describes one repo, so `repo` reads as "who I am on this
  board".
- `HANDOFF_REPO` overrides whichever one is in play. It needs no rename — the prefix is
  right and the term after it is the tool's own.

This is already the convention elsewhere in the same cascade: the board records `groups`,
the sections it hosts; a member repo records `group`, the one section it is in. Same fact at
two levels of detail, named per layer, and nobody has ever called that drift.

## Considered options

- **Converge the write path on `repoName`.** Rejected — a file whose entire scope is one
  repo, naming its own key `repoName`, reads as though it names some _other_ repo. It also
  buys a deprecation window and a permanent read alias for no user-visible gain.
- **Converge the write path on `repo`.** Rejected — the board config would then carry a key
  that on a cross-repo board must always be absent, which is worse than the split it fixes.
- **Say nothing and let it be re-litigated.** Rejected on evidence: that is what produced
  three passes at this handoff, two of which planned work against a premise that had already
  stopped being true.

## Consequences

- `payload/README.md` states the convention beside the config tables, so the next reader
  meets the rule before the two keys.
- This is **not** a precedent for tolerating aliases. `board` and `boardPath` are two names
  for one key at one layer, which is real drift; `board` is canonical and `boardPath` is a
  read-only legacy alias on its way out. The test is whether the two names sit in the same
  file describing the same subject — if they do, converge them.
- `HANDOFF_REPO` is settled and the row can close. Nothing in the payload's env surface is
  now proposed for rename.
