# CLAUDE.md

Guidance for Claude Code when working in this service.

## Service-specific notes

- This is a Kafka consumer service. The consumer group id is `orders-ingest-v2` — do not
  change it without coordinating with the platform team.
- Secrets come from Azure Key Vault via `@nestjs/config`; never hardcode connection strings.
- Run `yarn test:cov` before pushing; this repo enforces 100% branch coverage.
