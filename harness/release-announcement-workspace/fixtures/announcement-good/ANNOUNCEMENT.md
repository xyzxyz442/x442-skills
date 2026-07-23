# acme-relay 1.3.0 — retries, a stable doctor, per-route limits

This release makes webhook delivery survivable: failed deliveries now retry with
exponential backoff instead of being dropped, `relay doctor` is stable enough to rely
on, and rate limits can be tuned per route.

## Highlights

- **Failed deliveries retry automatically.** A streaming retry pipeline with
  exponential backoff replaces drop-on-failure. The work arrives via an upstream sync.
- **`relay doctor` is now stable.** Promoted from experimental to stable: it validates
  your local config against the schema and prints each mismatch.
- **Per-route rate limits.** Configure limits per route in `routes.json`. Enforcement
  is advisory — the dispatch agent reads the list; the server itself does not enforce
  it.

## Notable fixes

- Webhook signatures are no longer rejected when a payload contains multibyte
  characters.

## Action required

None. There are no breaking changes in this release.

## Get it

```sh
npm install acme-relay@1.3.0
```

Full changelog: [CHANGELOG.md](CHANGELOG.md) · Compare:
[v1.2.0...v1.3.0](https://github.com/acme/relay/compare/v1.2.0...v1.3.0)
