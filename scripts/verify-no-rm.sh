#!/usr/bin/env bash
# verify-no-rm.sh — enforce the narrow rm exception for shipped tooling (read-only).
#
# The owner's rule is `trash`, never `rm`. Shipped tooling has one exception (ADR 0028): it may
# `rm -f` a single named file it created itself — a mktemp scratch file, its own lease or cache
# file — and then `rmdir` the empty directory. This gate checks the SHAPE of every delete:
#
#   shell   `rm` must be `rm -f` and every argument must start with a quoted variable
#           ("$t", "${tmp}/scan.txt", "$DIR"/first-*). Refused: any other flag (-r, -R, -rf),
#           a literal or unquoted path, `find ... -delete`, and `rm` run through xargs/exec.
#   python  `shutil.rmtree` and `os.removedirs` are refused; deleting one path is allowed.
#
# The gate cannot prove that the variable names a file the script created. A reviewer checks
# that. `git rm` is an index operation and is out of scope.
#
# Scope: every script under scripts/ and skills/*/*/scripts/ — installed payloads, the
# setup/verify scripts that run from a skill directory, and the selftests.
#
# Usage: scripts/verify-no-rm.sh [--staged] [PATH...]
#   --staged     check only files staged for commit (what the pre-commit hook runs)
#   PATH...      check only these paths (scope still applies)
#   (no args)    check every git-tracked file in scope
#
# Exit 0 clean, 1 on any violation.

set -euo pipefail

SCOPE='^(scripts/|skills/[^/]+/[^/]+/scripts/)'

case "${1:-}" in
  --staged) files="$(git diff --cached --name-only --diff-filter=ACMR)" ;;
  "") files="$(git ls-files)" ;;
  *) files="$(printf '%s\n' "$@")" ;;
esac

files="$(printf '%s\n' "$files" | grep -E "$SCOPE" || true)"
[ -n "$files" ] || {
  echo "verify-no-rm: nothing in scope"
  exit 0
}

printf '%s\n' "$files" | python3 -I -c '
import re, sys

# A command position: line start, after a separator plus whitespace, after a shell keyword, or
# as the first word of a trap string. Requiring whitespace after `|` keeps "add|rm" usage text
# out; prose quoting a command inside echo text is not at a command position.
CMD = re.compile(
    r"""(?:^|[;&|({]\s|\b(?:then|do|else|xargs|command|exec)\s|trap\s+[\x27"])\s*(?:/bin/)?rm\s"""
)
FIND_DELETE = re.compile(r"(?:^|[;&|({]\s|\b(?:then|do|else)\s)\s*find\s.*\s-delete\b")
PY_TREE = re.compile(r"\b(?:rmtree|removedirs)\s*\(")
STOP = set(";&|)}\x27<>#")


def words_after_rm(line, start):
    """Raw words of the rm command, quotes kept, up to the first unquoted separator."""
    words, cur, quote, i = [], "", None, start
    while i < len(line):
        c = line[i]
        if quote:
            cur += c
            if c == quote:
                quote = None
        elif c in "\"":
            quote = c
            cur += c
        elif c.isspace():
            if cur:
                words.append(cur)
                cur = ""
        elif c in STOP:
            break
        else:
            cur += c
        i += 1
    if cur:
        words.append(cur)
    # a trailing fd number of a redirect (`2> /dev/null`) is not an argument
    if words and words[-1].isdigit() and i < len(line) and line[i] in "<>":
        words.pop()
    return words


def kind(path, first):
    if path.endswith(".py") or "python" in first:
        return "py"
    if path.endswith(".sh") or re.match(r"#!.*\b(ba)?sh\b", first):
        return "sh"
    return None


bad = 0
for path in sys.stdin.read().split():
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeDecodeError):
        continue
    k = kind(path, lines[0] if lines else "")
    for n, line in enumerate(lines, 1):
        body = line.strip()
        if not body or body.startswith("#"):
            continue
        why = None
        if k == "py":
            if PY_TREE.search(line):
                why = "recursive delete (rmtree/removedirs); delete one path, or leave a temp tree for the OS"
        elif k == "sh":
            if FIND_DELETE.search(line):
                why = "find -delete is a recursive delete; leave a temp tree for the OS"
            for m in CMD.finditer(line):
                w = words_after_rm(line, m.end())
                flags = [x for x in w if x.startswith("-")]
                args = [x for x in w if not x.startswith("-")]
                if flags != ["-f"]:
                    why = "rm takes exactly -f (got %s)" % (" ".join(flags) or "no flag")
                elif not args:
                    why = "rm -f with no argument"
                elif any(not x.startswith("\"$") for x in args):
                    why = "rm -f argument is not a quoted variable: %s" % " ".join(
                        x for x in args if not x.startswith("\"$"))
        if why:
            print("  %s:%d  %s" % (path, n, why), file=sys.stderr)
            bad += 1

if bad:
    print("verify-no-rm: %d violation(s). Rule: AGENTS.md house rules, ADR 0028." % bad, file=sys.stderr)
    sys.exit(1)
print("verify-no-rm: clean")
'
