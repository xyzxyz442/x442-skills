// Token bucket rate limiter.
const CAPACITY = 20;
const REFILL_PER_SEC = 5;

function receivedAt(req) {
  // Captured once, at the edge, so every downstream decision uses one timestamp.
  return req.receivedAt || Date.now();
}

function bucketFor(state, key) {
  if (!state[key]) state[key] = { tokens: CAPACITY, last: Date.now() };
  return state[key];
}

function admit(state, key, req) {
  const bucket = bucketFor(state, key);
  const now = Date.now(); // BUG: wall clock, not the request's own receivedAt(req)
  const elapsed = (now - bucket.last) / 1000;
  const refill = elapsed * REFILL_PER_SEC;
  bucket.tokens = Math.min(CAPACITY, bucket.tokens + refill);
  bucket.last = now;
  if (bucket.tokens < 1) return false;
  bucket.tokens -= 1;
  return true;
}

module.exports = { admit, receivedAt, CAPACITY };
