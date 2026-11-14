# Security Policy

## Supported versions

Security fixes are released for the latest minor version of CcinnMysql.

| Version | Supported |
|---|---|
| 1.0.x | ✅ |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report vulnerabilities privately through GitHub's [private vulnerability reporting](https://github.com/whiteCcinn/ccinnmysql/security/advisories/new). Include:

- a description of the issue and its impact,
- steps to reproduce (server and version, connection options such as the TLS mode, sample data if relevant),
- any suggested fix.

You can expect an acknowledgement within a few days. Once a fix is available, we will publish a release and an advisory crediting the reporter (unless you prefer to remain anonymous).

## Scope and design notes

- Passwords, SSH secrets and client-certificate passphrases are stored in the macOS Keychain; saved profiles on disk never contain them.
- TLS is negotiated in place after the server greeting. *Preferred* (the default) encrypts when the server offers TLS but does not verify the certificate; it never retries in plaintext after a failed TLS handshake, and TLS 1.0/1.1 must be enabled per connection; use *Verify CA* or *Verify identity* (with your CA file) for servers you need to authenticate. Each connection has its own TLS session, so a session negotiated under a weaker mode is never resumed by a verifying one.
- `caching_sha2_password` / `sha256_password` full authentication sends the password only inside TLS, or encrypted with the server's RSA key. Retrieving that key over a plaintext connection is opt-in, because the key itself is not authenticated; pinning the key file avoids that.
- `mysql_clear_password` (LDAP / PAM) is only answered when explicitly enabled for a connection. `LOAD DATA LOCAL INFILE` is never offered to the server, and a server request for a local file is refused.
- SSH tunnels use the system `/usr/bin/ssh` with `StrictHostKeyChecking=accept-new` (changed host keys are rejected). Secrets reach `ssh` through a short-lived 0600 file, never the command line or environment.
- History and the MCP audit log redact credentials (`IDENTIFIED BY`, `PASSWORD(…)`, `SOURCE_PASSWORD`, …) and are written with mode 0600.
- The MCP server exposes only connections the user enabled, defaults to read-only, checks statements with the app's own lexer and additionally runs read-only calls inside `START TRANSACTION READ ONLY`. Ways to make a read-only MCP call change data are considered vulnerabilities.
- Statements built by the app (metadata, `KILL`, row edits) quote identifiers and literals; issues that allow injecting SQL through object names or cell values are considered vulnerabilities.
