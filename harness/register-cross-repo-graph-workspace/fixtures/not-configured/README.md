# demo-service

A small TypeScript service used as a harness fixture. AI-assistant config and graph hooks are
already wired, and a small hand-built `.code-review-graph/graph.db` + `graphify-out/graph.json`
describe `src/billing.ts`'s `calculateInvoiceTotal` and `src/index.ts`'s `greet`. Used to prove
the wired hooks actually steer real code-search operations (grep, direct reads, session start)
toward the graph instead of grep.
