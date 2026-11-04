#!/usr/bin/env bash
# Release and lease cases for the handoff CLI: claim's expired-lease takeover, release's holder
# gate (ADR 0027), reopening an archived doc, blocked_on clearing, and formatter-wrapped rosters.
# Not run on its own — handoff.selftest.sh sources it, so it uses that suite's frozen payload
# ($SRC), its helpers (mkboard, hb, chk, chk_contains, now) and its pass/fail counters.
# Run: bash handoff.selftest.sh
[ -n "${SRC:-}" ] && declare -F mkboard > /dev/null || {
  echo "release.selftest.sh is sourced by handoff.selftest.sh — run that instead." >&2
  exit 2
}

printf '\nclaim takes over an expired lease without a reap in between\n'
# `claim` reads `expired` and is documented to take the lease over, but the lock directory of an
# expired lease is still on disk, so the atomic `mkdir` failed and the takeover branch was
# unreachable until something ran `reap --force`. Within one session nothing does.
EX="$(mkboard)"
EXB="$EX/.agents/handoff"
hb "$EX" new ex-case --title "Expired takeover" > /dev/null
HANDOFF_SESSION_ID=sess-a hb "$EX" claim ex-case "A working" > /dev/null
grep -v '^expires=' "$EXB/.locks/ex-case-handoff/owner" > "$EXB/.locks/ex-case-handoff/owner.t"
printf 'expires=1\n' >> "$EXB/.locks/ex-case-handoff/owner.t"
mv "$EXB/.locks/ex-case-handoff/owner.t" "$EXB/.locks/ex-case-handoff/owner"
OUT="$(HANDOFF_SESSION_ID=sess-b hb "$EX" claim ex-case "B taking over")"
chk_contains "an expired lease is taken over by claim" "$OUT" "Took over an EXPIRED lease"
chk "the lease now records the new session" "sess-b" "$(sed -n 's/^session=//p' "$EXB/.locks/ex-case-handoff/owner")"
chk "the new lease is live" "yes" \
  "$([ "$(sed -n 's/^expires=//p' "$EXB/.locks/ex-case-handoff/owner")" -gt "$(now)" ] && echo yes || echo no)"
chk "no takeover mutex is left behind" "no" "$([ -e "$EXB/.locks/.takeover-ex-case-handoff" ] && echo yes || echo no)"
chk_contains "a live lease still refuses a claim" "$(HANDOFF_SESSION_ID=sess-c hb "$EX" claim ex-case "C")" "CLAIMED by"
chk "and leaves the holder in place" "sess-b" "$(sed -n 's/^session=//p' "$EXB/.locks/ex-case-handoff/owner")"

printf '\nrelease honours the lease holder (ADR 0027)\n'
RL="$(mkboard)"
RLB="$RL/.agents/handoff"
hb "$RL" new rl-case --title "Release gate" > /dev/null
HANDOFF_SESSION_ID=sess-a hb "$RL" claim rl-case "A working" > /dev/null
OUT="$(HANDOFF_SESSION_ID=sess-b hb "$RL" release rl-case --status open)"
chk_contains "a non-holder cannot release a live lease" "$OUT" "only its holder can release it"
chk "the holder's lock is untouched" "sess-a" "$(sed -n 's/^session=//p' "$RLB/.locks/rl-case-handoff/owner" 2> /dev/null)"
OUT="$(HANDOFF_SESSION_ID=sess-b hb "$RL" release rl-case --status done --verified-by "B checked file.sh:1")"
chk_contains "nor close it done" "$OUT" "only its holder can release it"
chk "and the doc stays live" "yes" "$([ -f "$RLB/rl-case-handoff.md" ] && echo yes || echo no)"
OUT="$(HANDOFF_SESSION_ID=sess-a hb "$RL" release rl-case --status open)"
chk_contains "the holder releases normally" "$OUT" "Released rl-case-handoff → open"
chk "and the lock is gone" "no" "$([ -d "$RLB/.locks/rl-case-handoff" ] && echo yes || echo no)"
# The same cases `claim` takes over: an expired lease, or none at all.
HANDOFF_SESSION_ID=sess-a hb "$RL" claim rl-case "A again" > /dev/null
grep -v '^expires=' "$RLB/.locks/rl-case-handoff/owner" > "$RLB/.locks/rl-case-handoff/owner.t"
printf 'expires=1\n' >> "$RLB/.locks/rl-case-handoff/owner.t"
mv "$RLB/.locks/rl-case-handoff/owner.t" "$RLB/.locks/rl-case-handoff/owner"
OUT="$(HANDOFF_SESSION_ID=sess-b hb "$RL" release rl-case --status open)"
chk_contains "an expired lease can be released by anyone" "$OUT" "Released rl-case-handoff → open"
OUT="$(HANDOFF_SESSION_ID=sess-b hb "$RL" release rl-case --status done --verified-by "B checked file.sh:1")"
chk_contains "an unleased doc can be closed by anyone" "$OUT" "moved to archive/"
OUT="$(HANDOFF_SESSION_ID=sess-c hb "$RL" release rl-case --status done --verified-by "C checked file.sh:2")"
chk_contains "a done doc cannot be closed again" "$OUT" "already done"
chk "and its verified_by is unchanged" "B checked file.sh:1" "$(sed -n 's/^verified_by: "\(.*\)"$/\1/p' "$RLB/archive/rl-case-handoff.md")"
# Advisory mode: a lease claimed with no session id proves nobody, so it cannot refuse anybody either.
hb "$RL" new rl-adv --title "Advisory release" > /dev/null
(cd "$RL" && env -u HANDOFF_SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID ./.agents/handoff/handoff claim rl-adv "advisory" > /dev/null 2>&1)
OUT="$(cd "$RL" && env -u HANDOFF_SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID ./.agents/handoff/handoff release rl-adv --status open 2>&1)"
chk_contains "an advisory holder can still release their own lease" "$OUT" "Released rl-adv-handoff → open"
# A session-less caller cannot release a lease that DOES record a session — and is told why.
HANDOFF_SESSION_ID=sess-a hb "$RL" claim rl-adv "A" > /dev/null
OUT="$(cd "$RL" && env -u HANDOFF_SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID ./.agents/handoff/handoff release rl-adv --status open 2>&1)"
chk_contains "a session-less caller is refused a session-held lease" "$OUT" "only its holder can release it"
chk_contains "and is told how to prove ownership" "$OUT" "HANDOFF_SESSION_ID"
HANDOFF_SESSION_ID=sess-a hb "$RL" release rl-adv --status open > /dev/null

printf '\nrelease --status open on an archived doc reopens it\n'
OUT="$(HANDOFF_SESSION_ID=sess-c hb "$RL" release rl-case --status open "reopening")"
chk_contains "reopening an archived doc says so" "$OUT" "reopened"
chk "the doc is back in the live directory" "yes" "$([ -f "$RLB/rl-case-handoff.md" ] && echo yes || echo no)"
chk "and gone from archive/" "no" "$([ -f "$RLB/archive/rl-case-handoff.md" ] && echo yes || echo no)"
chk "its status is open" "open" "$(sed -n 's/^status: //p' "$RLB/rl-case-handoff.md" | head -1)"
chk_contains "list shows it again" "$(hb "$RL" list)" "rl-case-handoff"
chk_contains "the reopen is in the Activity log" "$(cat "$RLB/rl-case-handoff.md")" "reopened from archive"
# The orphan the bug left behind: archived, but no longer done.
hb "$RL" new rl-orphan --title "Orphan" > /dev/null
hb "$RL" release rl-orphan --status done --verified-by "checked file.sh:3" > /dev/null
sed 's/^status: done$/status: open/' "$RLB/archive/rl-orphan-handoff.md" > "$RLB/archive/rl-orphan.t"
mv "$RLB/archive/rl-orphan.t" "$RLB/archive/rl-orphan-handoff.md"
hb "$RL" release rl-orphan --status open > /dev/null
chk "an archived doc that is not done is moved back too" "yes" "$([ -f "$RLB/rl-orphan-handoff.md" ] && echo yes || echo no)"

printf '\nrelease clears blocked_on once the doc is no longer blocked\n'
BO="$(mkboard)"
BOB="$BO/.agents/handoff"
hb "$BO" new bo-case --title "Blocked case" > /dev/null
hb "$BO" new bo-dep --title "Dependency" > /dev/null
hb "$BO" release bo-case --status blocked --blocked-on bo-dep > /dev/null
chk "blocked_on is recorded" "bo-dep-handoff" "$(sed -n 's/^blocked_on: //p' "$BOB/bo-case-handoff.md")"
hb "$BO" release bo-case --status open > /dev/null
chk "an open release clears blocked_on" "" "$(sed -n 's/^blocked_on:[[:space:]]*//p' "$BOB/bo-case-handoff.md")"
chk "and drops the key rather than leaving it empty" "0" "$(grep -c '^blocked_on:' "$BOB/bo-case-handoff.md" | tr -d ' ')"
hb "$BO" release bo-case --status blocked --blocked-on bo-dep > /dev/null
hb "$BO" release bo-case --status done --verified-by "checked file.sh:4" > /dev/null
chk "a done release clears it too" "0" "$(grep -c '^blocked_on:' "$BOB/archive/bo-case-handoff.md" | tr -d ' ')"
OUT="$(hb "$BO" release bo-dep --status blocked --blocked-on "")"
chk "an empty --blocked-on does not crash the CLI" "no" "$(printf '%s' "$OUT" | grep -q 'parameter null' && echo yes || echo no)"
chk_contains "it is refused with a reason" "$OUT" "--blocked-on needs a value"
chk_contains "an empty --status is refused with a reason" "$(hb "$BO" release bo-dep --status "")" "--status needs a value"

printf '\na multi-line children list (as Prettier writes it) still reads as the roster\n'
ML="$(mkboard)"
MLB="$ML/.agents/handoff"
hb "$ML" new ml-one --title "One" > /dev/null
hb "$ML" new ml-two --title "Two" > /dev/null
hb "$ML" new ml-three --title "Three" > /dev/null
hb "$ML" new ml-bundle --orchestrator --children ml-one,ml-two,ml-three --title "ML bundle" > /dev/null
MLDOC="$MLB/ml-bundle-handoff.md"
awk '/^children:/ { print "children:"; print "  ["; print "    ml-one-handoff,"; print "    ml-two-handoff,"; print "    ml-three-handoff,"; print "  ]"; next } { print }' "$MLDOC" > "$MLDOC.t" && mv "$MLDOC.t" "$MLDOC"
chk_contains "list counts every child of a wrapped roster" "$(hb "$ML" list | grep '^ml-bundle-handoff ')" "0/3"
chk_contains "children lists the last child of a wrapped roster" "$(hb "$ML" children ml-bundle)" "ml-three-handoff"
chk_contains "a wrapped bundle with open children still refuses done" "$(hb "$ML" release ml-bundle --status done)" "outstanding children"
hb "$ML" new ml-four --title "Four" > /dev/null
hb "$ML" children add ml-bundle ml-four > /dev/null
chk "rewriting a wrapped roster leaves no stray lines" "0" "$(sed -n '2,/^---$/p' "$MLDOC" | grep -c '^[[:space:]]' | tr -d ' ')"
chk_contains "and the rewritten roster has all four" "$(sed -n 's/^children: //p' "$MLDOC")" "ml-four-handoff"
chk_contains "list counts the new child" "$(hb "$ML" list | grep '^ml-bundle-handoff ')" "0/4"
# Block style is the other shape a YAML formatter may emit.
awk '/^children:/ { print "children:"; print "  - ml-one-handoff"; print "  - ml-two-handoff"; next } { print }' "$MLDOC" > "$MLDOC.t" && mv "$MLDOC.t" "$MLDOC"
chk_contains "a block-style roster is read too" "$(hb "$ML" list | grep '^ml-bundle-handoff ')" "0/2"
