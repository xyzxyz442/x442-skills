# orders-consumer-service

An existing NestJS Kafka-consumer service (representative Kafka-consumer shape). It already has a
`CLAUDE.md` with service-specific notes but **no** `AGENTS.md`.

This is an eval fixture for the `initial-project` skill — see
[../../../../docs/harness-structure.md](../../../../docs/harness-structure.md). Running the
skill against a copy should create `AGENTS.md`, preserve the existing `CLAUDE.md` notes, and
add an `@AGENTS.md` import to `CLAUDE.md`.
