# not-configured fixture

A workspace with a member repo but **no** `.handoff-repos.json` in its cascade. Cross-repo handoff
coordination is simply not opted into, which is not a failure: `verify-cross-repo-handoff.sh` reports
"not configured" and exits 0 (never a FAIL / exit 1). Regression guard for the unconfigured exit code.
