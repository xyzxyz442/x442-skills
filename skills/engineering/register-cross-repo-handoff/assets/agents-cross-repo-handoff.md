<!-- cross-repo-handoff:begin (managed by register-cross-repo-handoff — do not edit between markers) -->

## Cross-repo handoff coordination

This repo coordinates handoffs with its peers on a **shared board** at `{{BOARD}}`, in the
`{{GROUP}}` section (layout: `{{LAYOUT}}`). Claim before you work; release when you stop — the same
protocol as a single-repo board, but the board is shared and sub-indexed by group.

Peers in the `{{GROUP}}` group:

{{PEER_TABLE}}

**Peers you can hand off to: {{PEERS}}.** File a handoff for another repo with its acts-next name.

`HANDOFF_GROUP` is what scopes a command to this repo's section. The tool hooks set it for you, but
a command you type by hand inherits nothing — so pass it explicitly:

```text
HANDOFF_GROUP={{GROUP}} {{BOARD}}/handoff list      # only the {{GROUP}} section
HANDOFF_GROUP={{GROUP}} {{BOARD}}/handoff new <id> --title "..." --audience <peer> --severity low|medium|high
HANDOFF_GROUP={{GROUP}} {{BOARD}}/handoff claim <id> "what you're doing"
```

Omit it on this sectioned board and `list` warns that nothing it shows is scoped to you, while
`claim` cannot resolve an id in your section — it will tell you which section holds it.

Your session board and the edit gate **are** scoped for you, because the hooks carry
`HANDOFF_GROUP={{GROUP}}`: you only see and lease this group's handoffs, and other groups on the
board are isolated. Do not edit a doc you do not hold the lease for. Handoff docs are committed to
git history — never paste secrets, keys, or PII.

Scope comes from the `.agents/handoff.json` cascade (user → workspace → subdirectory, nearest wins).
After editing it, re-run `sync-cross-repo-handoff.sh` so this block, the board wiring, and the
sub-indexes agree.

<!-- cross-repo-handoff:end -->
