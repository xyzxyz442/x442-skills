<!-- cross-repo-handoff:begin (managed by register-cross-repo-handoff — do not edit between markers) -->

## Cross-repo handoff coordination

This repo coordinates handoffs with its peers on a **shared board** at `{{BOARD}}` (layout:
`{{LAYOUT}}` — the board has no sections, so every peer files into the same list). Claim before you
work; release when you stop — the same protocol as a single-repo board, but the board is shared.

Peers in the `{{GROUP}}` group:

{{PEER_TABLE}}

**Peers you can hand off to: {{PEERS}}.** File a handoff for another repo with its acts-next name.

The board is flat, so no `HANDOFF_GROUP` is needed — every command sees the whole board:

```text
{{BOARD}}/handoff list
{{BOARD}}/handoff new <id> --title "..." --audience <peer> --severity low|medium|high
{{BOARD}}/handoff claim <id> "what you're doing"
```

Every peer sees every handoff, so `audience` is what says whose move it is: claim only the ones
addressed to this repo. Do not edit a doc you do not hold the lease for. Handoff docs are committed
to git history — never paste secrets, keys, or PII.

Scope comes from the `.agents/handoff.json` cascade (user → workspace → subdirectory, nearest wins).
After editing it, re-run `sync-cross-repo-handoff.sh` so this block and the board wiring agree.

<!-- cross-repo-handoff:end -->
