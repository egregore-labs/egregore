# Windows notification TLS diagnostics

Curl exit code 35 means the TLS handshake failed. It does not uniquely identify
a certificate-revocation problem. The notification command preserves curl's
error output and adds a diagnostic hint for this exit code.

Run `curl --version` to identify the TLS backend. For a Schannel build, inspect
the preceding error for a revocation-specific failure. Check system time,
proxy configuration, and access to the certificate's revocation service.

The script adds no retry or TLS bypass options, including `--ssl-no-revoke`.
Curl still honors your own curl configuration. A failed approved dispatch requires a
new plan and approval under the existing notification protocol. Do not put a
global TLS bypass in `~/.curlrc` as a default workaround.

## Verify locally

Requires Node.js, Bash, and jq:

```bash
node --test tests/test-notify-tls.mjs
```

On Windows, run from Git Bash with
`BASH_BIN='C:/Program Files/Git/bin/bash.exe'` set for the command.
The test injects curl exits 0, 35, 6, and 60 into the connected `test` command.
It verifies preserved stdout, diagnostics and exit codes, one curl invocation,
and no added retry or TLS bypass flags. It makes no network request and
does not establish that a live Schannel revocation outage is repaired.
