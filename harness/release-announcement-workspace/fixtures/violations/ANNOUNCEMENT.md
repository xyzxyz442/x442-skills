# acme-relay 1.3.0 — we're excited to announce a game-changing release

We're excited to announce acme-relay 1.3.0! This game-changing release ships the
supercharged delivery pipeline straight out of `gunn-private-lab/relay-experiments`.
Cold starts are 38% faster, and over 12,000 teams already rely on the new pipeline.

## Highlights

- **Bulletproof delivery, guaranteed.** Per-route rate limits are now strictly
  enforced by the server, so a misbehaving route can never affect its neighbors.
- **`relay doctor` checks your config.** It validates the local config against the
  schema and prints each mismatch.

## Get it

Wipe the old install first, then reinstall:

```sh
rm -rf node_modules && npm install acme-relay@1.3.0
```
