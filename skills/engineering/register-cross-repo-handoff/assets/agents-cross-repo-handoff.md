<!-- cross-repo-handoff:begin (managed by register-cross-repo-handoff — do not edit between markers) -->

## Cross-repo handoff coordination

This repo coordinates handoffs with its peers on a **shared board** at `{{BOARD}}`, in the
`{{GROUP}}` section (layout: `{{LAYOUT}}`). Claim before you work; release when you stop — the same
protocol as a single-repo board, but the board is shared and sub-indexed by group.

Peers in the `{{GROUP}}` group:

{{PEER_TABLE}}

**Peers you can hand off to: {{PEERS}}.** File a handoff for another repo with its acts-next name:

```text
{{BOARD}}/handoff new <id> --title "..." --audience <peer> --severity low|medium|high
{{BOARD}}/handoff list      # shows only the {{GROUP}} section
{{BOARD}}/handoff claim <id> "what you're doing"
```

Your session board and the edit gate are scoped to the `{{GROUP}}` section, so you only see and
lease this group's handoffs; other groups on the board are isolated. Do not edit a doc you do not
hold the lease for. Handoff docs are committed to git history — never paste secrets, keys, or PII.

Scope comes from the `.handoff-repos.json` cascade (user → workspace → subdirectory, nearest wins).
After editing it, re-run `sync-cross-repo-handoff.sh` so this block, the board wiring, and the
sub-indexes agree.

<!-- cross-repo-handoff:end -->
