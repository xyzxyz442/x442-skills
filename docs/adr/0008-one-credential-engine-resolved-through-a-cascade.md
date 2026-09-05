---
status: accepted
date: 2026-09-05
---

# One credential engine, resolved through a cascade

Credential detection converges on one engine that owns **structural detection and masking**, and
the payloads that need it resolve it through a `.claude/` cascade at run time rather than
vendoring a copy. It exposes detection and masking only — never a verdict — and each call site
owns its policy, including what failure means. The document scanner's prose-tuned rule table is
deliberately **not** absorbed into it.

## Context

Three credential detectors exist across this repository and the machine it installs onto. They
are not redundant copies of one idea; they are tuned for different corpora, and only two of them
overlap.

`consent-gate.sh` matches credential-shaped **paths** and nothing else, so it is blind to a
secret inside an innocuously named file. It has no content awareness at all.

The handoff CLI carries a genuinely good scanner (ADR 0005): thirteen named rules, every one
carrying a vendor prefix or a structural marker, behind a single `scan_secrets` chokepoint that
every write path calls. It never echoes what it matched, it names the rule instead of the value,
and its override is a flag that must carry a reason and is recorded on the document. Its rules
are deliberately shaped so that **prose about secrets passes clean** — which matters, because
what it scans is handoff documents, and a security handoff is mostly prose about credentials.

The third lives outside the repository entirely, as three unversioned files under one user's
`~/.claude`: key-name matching with a safe-key allowlist, PEM and JWT detection, structural
parsers for JSON, YAML and INI, and value fingerprinting that masks a secret while preserving
the document's shape. It is wired by hand, documented by hand, installed on exactly one machine,
and has no git history behind it.

Two capabilities are missing everywhere, and they are what this decision is actually about.

**Nothing in this repository guards the read path.** Every existing check runs when content is
written or dispatched. Nothing stops a credential entering a transcript in the first place, which
is the one exposure that cannot be undone afterwards — a tool result is on disk before any hook
can react to it.

**Nothing can mask.** Every shipped check refuses. Refusal is right for a document being
committed, but it is the wrong answer for a config file an agent legitimately needs to read the
shape of. "You may not see this file" and "here is this file with its values fingerprinted" are
different answers, and only the second lets ordinary work continue.

## Decision

- **One engine owns structural detection and masking.** It ships as the payload of
  `x442-setup-secret-guard` and is the single source of truth for both. Two CLIs over one
  library — `secret-scan` detects, `redact-view` masks by replacing a value with a stable
  non-reversible fingerprint while preserving key names and structure.
- **The engine exposes no verdicts.** Policy lives at each call site: the read-path hook maps
  detections to Claude Code's `allow`/`ask`/`deny`, `consent-gate.sh` maps them to
  deny-or-ask, the handoff write path maps them to write-or-refuse.
- **The document scanner keeps its own rule table.** `scan_secrets` is not retired onto the
  engine. Its rules are tuned for prose and the engine's key-name matching is tuned for
  structured data; pointing the latter at handoff documents would fire on every security
  handoff that mentions the word `password`. What the handoff CLI gains from the engine is
  masking, not detection.
- **`consent-gate.sh` does converge.** Path-only matching is a floor with no corpus argument
  behind it, and content awareness is exactly what it lacks.
- **Consumers resolve the engine through a cascade** — `$CLAUDE_PROJECT_DIR/.claude/…` first,
  `$HOME/.claude/…` second — the idiom the existing hooks already use. The home layer is
  load-bearing, because a leak is a property of the machine and the transcript rather than of
  the repository, and the guard must be on for a repo nobody installed into.
- **Absent and broken are different failures.** When the engine is **absent**, a consumer
  degrades to its own existing check, says so on stderr, and its verifier reports which detector
  is live. When the engine is **present and errors**, the write and outbound paths fail
  **closed** and the read path fails **open**. Fail-closed on absence would brick every board on
  every machine that has not installed the guard, which is the hard-dependency outcome rejected
  below.
- **The read path fails open on internal error**, because a wedged session is worse than a
  bounded exposure — but visibly, once per session, never silently.
- **Export policy is unchanged from ADR 0005**: the scanner runs on the rendered brief and
  **refuses** if it trips. Masking is a read-path capability. Silently shipping a brief with
  fingerprints in place of credentials would turn a refusal the sender must act on into a
  transformation they never see.
- **The repository layer may add, never lower the floor.** `.agents/secret-guard.json`, resolving
  through the same cascade as the other per-repo manifests, may add path patterns and add
  safe-key exceptions, which affect only the masking of an already-matched key. It may never
  remove a path from the deny or rewrite sets.
- **Claude Code is enforced; other tools degrade honestly.** Rewriting a read into a masked read
  is a Claude Code `PreToolUse` capability. Other tools get deny/ask where their hook model
  allows and a prose block where it does not, and the prose block is documented as not being
  enforcement.
- **The skill is canonical, and adoption backs up before it overwrites.** Two distinct checks:
  the installer hash-compares content and refuses on divergence without an explicit `--adopt`,
  and `verify-secret-guard.sh` compares the installed `.version` stamp against the one the skill
  ships. Content drift and version drift are different questions. The previous copy is always
  backed up first.

## Considered options

- **Retire `scan_secrets` onto the engine too.** Rejected, and this is the correction that came
  out of reviewing this record before implementing it. The two detectors are tuned for different
  corpora: the engine's key-name matching over prose about credentials is a false-positive
  machine, and a write-path scanner that cries wolf gets overridden by habit, which is worse than
  the narrower scanner it replaced. "One engine" is a claim about structural detection and
  masking, not about every place the word "secret" is checked.
- **Vendor the engine into each consuming payload.** Rejected. It is what every other payload
  here does and it is the disease in this one case: copies of a detection heuristic drift, and
  the drift is invisible because each copy keeps passing its own tests. The convention exists so
  a payload works on a cold clone, and the loud-degrade path preserves that without the drift.
- **Make the engine a hard dependency.** Rejected. It bricks every existing board and every wired
  repo on a machine that has not installed the guard, and an unwritable shared board is the worst
  available outcome. Refusing to coordinate is not a security win.
- **Let the engine speak one verdict vocabulary that consumers subset.** Rejected. It drags
  Claude Code's `ask` into a bash CLI with no user to ask, and makes the engine's contract change
  every time any consumer's policy changes. Detection is stable; policy is not.
- **A single global failure posture.** Rejected in both directions. Fail-closed everywhere wedges
  a session on a malformed payload, which is how a guard gets switched off. Fail-open everywhere
  is what put a credential-path check behind `command -v python3 || exit 0`.
- **Strict additive-only repository layers.** Rejected. Unusable false positives — a repository
  of public `*.key` files, a `webhook` field holding a public URL — drive someone to disable the
  guard entirely. Narrowing the axis on which a repo may weaken is the useful version of the
  instinct.
- **A `repair-secret-guard` sibling.** Rejected against this repository's own test: no database,
  no leases, no daemon, no external install — only files it wrote plus a marked block in a shared
  settings file. Upgrade is re-running the installer; drift detection belongs in the verifier.

## Consequences

- One payload here is deliberately not self-contained. A future reader will find a payload
  reaching outside itself and may "fix" it into a vendored copy, restoring the drift. That is the
  main reason this record exists.
- `setup-delegate-agent` gains a soft dependency on a component it does not own. Its verifier
  must report which detector is live, or the degrade is invisible one level further out.
- The engine becomes security-critical shared code. A false negative in it is a false negative
  everywhere at once — the cost of convergence, paid for by the fact that a single detector is
  the only kind that can actually be reviewed and tested.
- **A repo-layer `safe_keys` entry suppresses masking for a key name.** It is the weakest link in
  the cascade and the easiest to change: an ordinary pull request into a consuming repository can
  exempt a real credential's key from masking, and the change looks like configuration rather
  than a security decision. Additions to that list deserve review as security changes, and the
  verifier should report how many are in effect.
- **The `--adopt` gate cannot distinguish a first install from tampering.** De-personalisation
  guarantees the first run always diverges, so `--adopt` is always required once, on every
  machine — which is exactly when trust is being bootstrapped and the check has no discriminating
  power. It defends against later silent drift, not against a bad first install.
- A scanner on a write path means a false positive blocks a write, so it needs an explicit,
  recorded override rather than a silent bypass — the requirement ADR 0005 already established.
- The read path stays fail-open by design. A deliberate, bounded weakness: it protects the
  session at the cost of a gap when the engine itself breaks, which is why the degrade must
  announce itself rather than be inferred.
