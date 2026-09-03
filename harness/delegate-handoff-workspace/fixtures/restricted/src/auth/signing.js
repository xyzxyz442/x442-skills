// Request signing. The key MATERIAL never appears here — only the names the secret manager
// resolves, which is the whole point of the rotation handoff on this board.
const crypto = require('crypto');

const CURRENT = 'SIGNING_KEY_CURRENT';
const PREVIOUS = 'SIGNING_KEY_PREVIOUS';

function keyFor(name) {
  const value = process.env[name];
  if (!value) throw new Error(`missing secret: ${name}`);
  return value;
}

function sign(payload) {
  return crypto
    .createHmac('sha256', keyFor(CURRENT))
    .update(payload)
    .digest('hex');
}

// The overlap window. Accepting the previous key is what makes a rotation non-breaking, and
// closing this window is what makes it finished — see key-rotation-handoff.
function verify(payload, signature) {
  for (const name of [CURRENT, PREVIOUS]) {
    const want = crypto
      .createHmac('sha256', keyFor(name))
      .update(payload)
      .digest('hex');
    if (want === signature) return true;
  }
  return false;
}

module.exports = { sign, verify, CURRENT, PREVIOUS };
