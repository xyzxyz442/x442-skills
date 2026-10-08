---
status: accepted
date: 2026-10-07
---

# The secret guard closes honest shapes and free fail-closed gaps

The secret guard is a cooperative guard. It routes the commands an honest agent or tool runs, and
it does not sandbox a determined one (ADR 0025, Consequences). Nothing said which findings that
leaves in scope. Between v0.19.1 and v0.19.2, nine rounds of background commit security review each
reported a bypass. Some were shapes an agent produces every day; others were deliberate
obfuscation. Without a rule, every finding reopened the release, and the fixes began to add the
prompts on honest commands that ADR 0009 warns get a guard switched off.

## Decision

**A finding is in scope when at least one of these holds:**

1. **It is an honest shape:** a command an agent, a person or a tool produces in ordinary work.
   Examples are `2>&1` noise, `su -c '…'`, `$( … )`, a `for` loop over files, an Argo CD banner,
   `jq tostring`, and an aliased binary (`kubecolor`).
2. **Its fix is free and fail-closed:** the fix makes the guard stricter, and it adds no prompt,
   denial or rewrite to any honest command. Decoding bash's `$'…'` quoting is free. Asking on every
   quoted string that mentions a producer is not, because commit messages, `echo` lines and
   handoff notes quote producers honestly.

**Out of scope, recorded as the cooperative limit:**

- a binary reached through a variable, an alias or a wrapper script (`k=kubectl; $k get …`);
- an interpreter one-liner (`python3 -c "os.system('kubectl …')"`, `perl -e 'system(…)'`);
- a script file written and then run;
- quoting or encoding games whose only fix would add prompts to honest commands.

A test pins the interpreter one-liner as not asked about, so the limit is a decision, not an
accident. Changing it means revisiting this record.

**Cadence.** Work a round of findings on one branch. Allow at most two review rounds after the
first fix, plus one explicit review pass in which every finding is read in full. A finding a
background review reports without detail is not guessed at. A finding that fails the test above
is filed, not fixed. Then release once. The one exception is a regression: a value the installed
payload redacts that the new code prints raw, reproduced. It may be fixed past the cap with the
user's go-ahead, and the fix must provably redact no less than the installed payload. Record each
exception below.

## Applied in v0.19.3

- **Quoted scripts:** the runner allowlist gains the honest runners `su -c`, `runuser -c`,
  `script -c`, `flock -c` and `sudo -s/-i`. A heredoc fed to `python3`, `perl`, `node`, `ruby` or
  `make` is a script too. A producer or a credential read inside such a script asks, and the runner
  must be in the same step. A fail-closed "ask on any quoted producer" rule was rejected under
  test 2. See the ADR 0009 amendment.
- **`kubectl config view`:** kubectl redacts only password, token and certificate data on its own.
  OIDC `auth-provider` secrets and exec-plugin `env` values print raw (verified against a synthetic
  kubeconfig), so the view is always routed. A template output passes only when every expression
  reads a safe root (`current-context`, `contexts`, `clusters`, `preferences`). Any other template
  is denied, including a template file or a wildcard.
- **Variable reads:** a read whose path the shell has yet to expand goes through the viewer, which
  prints a clean file byte-identical. A variable that is a flag's value (`head -n $N`) is not a
  path.
- **`kubecolor`** matches wherever `kubectl` does.

## Applied in v0.20.0

- **kyaml:** the viewer reads kubectl's flow-style YAML (`-o kyaml`), so `-o kyaml` is routed like
  `-o yaml` rather than asked about. A document is found from its `---` separator wherever it sits:
  behind stderr noise, a comment, a BOM or block YAML, or pasted into a note, where `secret-scan`
  sees it too. A document that does not parse fails closed when the input is piped or opens with
  it. Elsewhere in a named file or a note it may be prose, so it is left to the surrounding
  grammar; that is a limit, pinned by a test.
- **Cadence exception:** the round used both review rounds by its third commit. A further review
  reported a regression, reproduced as plain and single-quoted values in an unparseable document
  that the installed payload had masked. With the user's go-ahead it was fixed past the cap: the
  fail-closed path runs the old grammar first and masks the remaining quoted strings, so it
  redacts no less than before. A differential over 2,242 generated documents showed no regression.
  One more undescribed "redaction regression" finding could not be reproduced and was not
  guessed at. The user shipped with it open.

## Considered options

- **Fix every reported finding.** Rejected. Reviews of a heuristic guard do not converge, and
  chasing obfuscation trades away the property that keeps prompts meaningful.
- **Ask on any quoted producer and pass only known data contexts.** Rejected: a list of data
  contexts is as incomplete as a list of runners, and this one fails toward honest prompts.
- **Treat the guard as a sandbox.** Rejected. Only process isolation can stop a determined
  command, and that is not what this guard is.

## Consequences

- Review findings can now be triaged in one line each: honest shape, free fail-closed fix, or the
  limit.
- The limit is visible in two places: in this record, and in a test that fails if it changes
  silently.
- A finding that fails the test is closed by documenting it, not by code.
