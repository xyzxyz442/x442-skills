function switchTenant(req, res, next) {
  const cached = req.session.tenantId; // BUG: read before the handler below updates it
  applySwitch(req, res);
  req.tenantId = cached;
  next();
}

function applySwitch(req, res) {
  req.session.tenantId = req.body.tenantId;
}

module.exports = { switchTenant };
