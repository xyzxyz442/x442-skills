# acme-relay

A webhook relay: receives events, dispatches them per route with configurable rate
limits, and signs every delivery. `relay doctor` validates the local config against the
schema and prints each mismatch.

## Releasing

Cut the release first (bump, changelog, tag), then announce it: the changelog section for
the tag range is the source of truth for what changed.
