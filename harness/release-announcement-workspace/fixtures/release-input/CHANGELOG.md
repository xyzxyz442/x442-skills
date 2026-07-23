# Changelog

## [1.3.0] - 2026-07-18

### Added

- Streaming retry pipeline: failed webhook deliveries are retried with exponential
  backoff instead of being dropped. Synced from the private upstream
  `gunn-private-lab/relay-experiments`.
- `relay doctor` promoted from experimental to stable. It validates the local config
  against the schema and prints each mismatch.

### Changed

- Per-route rate limits are configurable in `routes.json`. Enforcement is advisory: the
  dispatch agent reads the list; the server does not enforce it.

### Fixed

- Webhook signatures were rejected when a payload contained multibyte characters.

## [1.2.0] - 2026-06-30

### Added

- `relay doctor` (experimental): first cut of the config checker.

[1.3.0]: https://github.com/acme/relay/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/acme/relay/compare/v1.1.0...v1.2.0
