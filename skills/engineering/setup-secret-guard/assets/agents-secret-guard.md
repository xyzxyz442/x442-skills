<!-- secret-guard:begin (managed by setup-secret-guard — do not edit between markers) -->

## Secrets and credentials (redacted, not forbidden)

Credential **values** must never reach the transcript. The files themselves stay usable — reads
are routed through a redacting viewer instead of being blocked, so you get the file's shape while
the value is replaced by a stable fingerprint.

A tool result enters the transcript before any hook can react to it, and the transcript persists
to disk. Nothing can redact a secret after the fact. Prevention is the only lever, which is why
the rules below are absolute rather than advisory.

### What happens automatically

`cat`, `head`, `tail`, `less` on a credential-bearing file is rewritten to run through
`redact-view`. You get keys, structure, and value types; each secret value becomes:

```text
password: <redacted len=25 sha256:585c2252>
```

The digest derives from the real value, so the same secret shows the same tag in two files. That
answers "do staging and prod share this token?" without disclosing either.

This is content-driven, not just filename-driven: an ordinary-looking `appsettings.json` holding
a `database.password` — or a connection string with an embedded `Password=` — is redacted too.
Files with nothing secret in them pass through **byte-identical**, so the detour is invisible.

### What is still blocked

Commands whose whole purpose is to obtain the raw value: `base64`, `openssl`, `xxd`, `strings`,
`source`/`.`, `scp`, `rsync`, `curl`, `pbcopy`, `tee`. Redaction cannot help there. A content-mode
`grep` at a secret file is blocked too — pipe from the viewer instead:

```bash
redact-view .env | grep TOKEN
```

Raw key material (`*.pem`, `id_rsa`, `*.p12`) has no structure worth showing, so it is withheld
wholesale — you get type, byte count, and a digest.

### The rules

- **Never route around the guard.** No copying a secret to an unwatched path, no base64, no
  reading it through a language interpreter, no renaming to dodge a pattern.
- **A process that consumes a secret needs no read from you.** `npm run deploy` and
  `kubectl --kubeconfig=...` already work — the child process reads the file itself. You never
  need to see the value.
- **If a task genuinely needs a plaintext secret, stop and say so.** That is the user's call, not
  yours.
- **Record a credential's NAME, never its value** — an environment variable or a secret-manager
  reference. This applies to every file you write, every commit message, and every handoff doc.
- `redact-view --all FILE` redacts every scalar, for when the key names themselves are sensitive.

### Enforcement is not uniform, and you should know which side you are on

Claude Code enforces this with a `PreToolUse` hook that can rewrite a command before it runs.
Other tools get deny/ask rules where their hook model allows it. **This block is documentation,
not enforcement** — where a tool cannot intercept, these rules hold only because you follow them.

`secret-scan FILE` answers whether content holds a credential (exit 0 = found, 1 = clean) and
names the rule that matched, never the value. Use it before writing or sending content you did
not author.

<!-- secret-guard:end -->
