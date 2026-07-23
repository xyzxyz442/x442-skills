---
name: x442-release-announcement
description: Use when announcing a release or writing release notes — "announce v1.2.0", "write the release notes", "draft a Slack post for this release". Turns a tagged version and its changelog into a user-facing announcement shaped for its channel (GitHub release, Slack, email), leading with user impact rather than the file diff. Can emit a second language.
argument-hint: '<version> [channel] [language]'
---

# Release announcement

Turn a released version into an announcement its audience can act on. The input is a
changelog or commit range; the output is prose that says what is now possible that was not
before. This skill is about the message, not the release mechanics — cut the release
(version bump, changelog, tag) first.

## When to use

- A version was tagged and the team needs to hear about it.
- A `CHANGELOG.md` section exists and someone asks for release notes, a GitHub release
  body, or a Slack post.
- The same release must go out on more than one channel or in more than one language.

Do **not** use this to decide the version number or to run the release. If the release is
not cut yet, cut it first, then come back with the resulting range.

## Procedure

1. **Gather the inputs.** You need version, previous version, the changelog or commit
   range, audience, channel, and language. Ask for anything missing or ambiguous — do not
   guess a channel or an audience, because both change the shape of the output.
2. **Read the actual changes.** Use the changelog section for the range, and read the
   commits or diff when a subject line is too thin to explain user impact. Every claim in
   the announcement must trace back to something you read.
3. **Find the precedent.** Look for how this project's last release was announced — a prior
   GitHub release body (`gh release view <prev-tag>`), an `announcements/` or `docs/` entry,
   or the previous run of this skill. Match its section shape, heading vocabulary, and emoji
   use. **Precedent from the same project outranks every default in this skill**, including
   the channel table below. Follow the defaults only when there is no precedent to match.
4. **Group by user-visible theme, never by commit type.** A reader does not care that four
   commits were `feat` and two were `fix`. They care that one capability now exists. Merge
   related commits into a single highlight; drop internal churn entirely.
5. **Draft** to the structure below.
6. **Apply the rules** below as a checklist pass over the draft.
7. **Shape for the channel**, then translate if a second language was requested.
8. **Deliver** the finished text ready to paste, with no commentary about how you wrote it.

## Structure

1. **Title** — `<project> <version> — <three to eight word headline change>`.
2. **Lede** — one paragraph: what this release makes possible that the previous one did not.
3. **Highlights** — three to five items. Each is a bold one-line claim followed by one to
   three lines of detail.
4. **Notable fixes** — only bugs a user could have hit. Omit the section if there are none.
5. **Action required / breaking changes** — or state plainly that there are none.
6. **Get it** — the upgrade command, a link to the full changelog, and the compare range.

## Rules

- **Lead with consequence, not mechanics.** Say what someone can now do and what it
  replaces. "Agents answer across a repo boundary instead of grepping between checkouts"
  beats "synced 207 files".
- **Never overstate a guarantee.** If the code enforces something softly — a convention, a
  list in a config file, a boundary maintained by an agent rather than by the tool — say so
  in the announcement. An announcement that implies a hard guarantee the code does not make
  is a defect, not a rough edge.
- **Watch attribution.** If the release syncs work from another repository, check whether
  that repository is visible to this audience. Never name a private, personal, or otherwise
  non-public upstream in team-facing content; describe it as an upstream sync, or describe
  the change on its own terms.
- **State status changes explicitly.** Anything promoted to stable, still experimental, or
  deprecated must be named, because that governs whether people should rely on it.
- **Do not invent.** No benchmark numbers, adoption claims, or dates that are not in the
  inputs. If a highlight needs a number you do not have, write the highlight without it.
- **No marketing language.** No "excited to announce", "game-changing", "supercharged".
  Imperative and matter-of-fact.
- **Keep commands copy-pasteable** and correct for the target project. Never demonstrate a
  destructive command; use `trash` rather than `rm`.
- **Match the project's emoji convention.** Mirror the project's changelog or previous
  announcement: if it uses section emoji, use the same set rather than inventing a
  different one; default to none only when there is no precedent to mirror. A repo's authoring-style rules — an `AGENTS.md` "no emoji" line, a lint
  config — govern content committed **to** the repo; they do not govern an announcement
  unless the previous announcement observed them. Do not reason your way out of an
  established precedent on the strength of a rule written for something else.

## Channel shaping

| Channel             | Shape                                                                                  |
| ------------------- | -------------------------------------------------------------------------------------- |
| GitHub release body | The full structure. Markdown headings, links to the compare range and `CHANGELOG.md`.  |
| Slack / Teams       | Six lines maximum: headline, two or three bullets, upgrade command, link. No headings. |
| Email               | The full structure plus a short "who should care and what to do" opener.               |
| Internal wiki / doc | The full structure plus any migration detail too long for a release body.              |

These are defaults for a project with no announcement history. A previous announcement's
shape wins over this table — including its length. A Slack post that runs past six lines
because that is how this project has always posted is correct, not a rule violation.

## More than one language

Translate the prose, but keep in the source language: project and skill names, file paths,
commands, flags, status words, and established technical terms. Match the register of the
project's existing translated docs if any exist. Emit the source language first, then the
translation under its own heading, and note which one is authoritative if they diverge.

## Verification

There is no script to run. Before delivering, confirm each of these by re-reading the draft
against the changelog:

- The draft matches the project's previous announcement in section shape and emoji use — or
  you confirmed there was no previous announcement to match.
- Every highlight traces to a real commit or changelog entry.
- No claim promises a stronger guarantee than the code provides.
- No non-public upstream is named.
- Status changes are stated.
- The upgrade command and links are correct for this project and version.
