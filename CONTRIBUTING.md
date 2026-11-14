# Contributing to CcinnMysql

Thanks for taking the time to contribute! This document explains how to set up a development environment and what we expect from changes.

## Development setup

- macOS 14 or later, Xcode 16 or later (Swift 6).
- Docker, if you want to run the integration tests against real MySQL / MariaDB / Percona servers.

```bash
git clone https://github.com/whiteCcinn/ccinnmysql.git
cd ccinnmysql
swift build
swift test --skip IntegrationTests
scripts/build-app.sh --open
```

### Integration tests

```bash
scripts/it-up.sh m57 m84 mariadb1011 mariadb114   # see scripts/it-up.sh for every target (all-basic, r84, galera, proxysql, …)
scripts/it-wait.sh m57 m84 mariadb1011 mariadb114
swift build && CCINNMYSQL_IT=1 swift test --skip-build --filter IntegrationTests
scripts/it-down.sh
```

Containers are named `ccinnmysql-it-*`, bound to `127.0.0.1:13300–13399` and limited to 384 MB each; tests skip servers that are not running and accept `CCINNMYSQL_IT_TARGETS=m84,mariadb114` to narrow the matrix. `scripts/seed-demo.sql` creates the `shop` schema used by the tests and screenshots: tables in three engines, a partitioned table, foreign keys, a redundant index, a table without a primary key, an AUTO_INCREMENT close to its limit, a view, a procedure, a function, a trigger and an event. Images are pulled from `public.ecr.aws/docker/library` (override with `CCINNMYSQL_IT_REGISTRY`).

### Running the app against a server directly

```bash
CCINNMYSQL_PASSWORD=secret dist/CcinnMysql.app/Contents/MacOS/CcinnMysql \
  --connect 127.0.0.1:13384 --user root --database shop --object shop.orders --section insights
```

Passwords never go on the command line; use `CCINNMYSQL_PASSWORD`. Other launch arguments: `--tls disabled|preferred|required|verifyCA|verifyIdentity`, `--sql "…" --auto-run [--view grid|chart|plan]`, `--server overview|processlist|innodb|statements|replication|variables|status|users`, `--profile <saved name>`, `--appearance light|dark`, and `--snapshot <file.png> --snapshot-delay <seconds> --quit-after-snapshot` (renders the window off-screen without stealing focus or needing screen-recording permission).

## Project layout

| Module | Responsibility |
|---|---|
| `MySQLWire` | MySQL protocol: framing, handshake, SSLRequest, authentication plugins (native, caching_sha2, sha256, ed25519, RSA-OAEP), text result sets — no I/O |
| `MySQLKit` | Transport with in-place TLS, connections, pool, sessions with pinned `KILL QUERY`, SSH tunnels, flavor/version detection, metadata and operations |
| `CcinnMysqlKit` | UI-independent app logic: profiles, SQL lexer/splitter/auto-limit, read-only guard, redaction, completion, charts, export, history, EXPLAIN parsers, table insights, row editing, MCP |
| `CcinnMysql` | SwiftUI/AppKit application and the `mcp` subcommand |

Dependencies only point downwards; lower modules must not import higher ones.

## Guidelines

- **Test first.** Add or update tests with every behaviour change. Protocol logic is covered with the in-memory fake server in `Tests/MySQLKitTests/FakeMySQLServer.swift` (it scripts TLS requests and authentication rounds); server behaviour with the integration suite.
- **Read server output by column name.** `SHOW` output and `information_schema` / `performance_schema` tables differ between MySQL, MariaDB and versions; use `Record.text("Name", "AlternativeName")`, never column positions.
- **Fall back only on server errors.** Optional metadata may degrade when the server rejects a statement, but timeouts, network errors and cancellation must propagate.
- **Never crash on input.** No force unwraps/casts, unchecked indexing or trapping integer conversions on data that comes from a server, a file or the user. Bound recursion and sizes. Throw a descriptive error instead.
- **Concurrency.** Code must compile in Swift 6 strict-concurrency mode. Keep shared mutable state inside actors or behind small, well-scoped locks; do not block the main actor with I/O, sorting, parsing or chart preparation. Async results that can be superseded carry a generation token.
- **Secrets** must never appear in logs, errors, history, audit files or screenshots.
- Keep pull requests focused, and update `CHANGELOG.md` under *Unreleased*.

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/): `feat(scope): …`, `fix(scope): …`, `docs: …`, `test: …`, `refactor: …`, `chore: …`.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make sure `swift build` and `swift test --skip IntegrationTests` pass (and the integration suite, if you touched MySQLWire or MySQLKit).
3. Describe what changed and how you tested it (including server versions, if relevant).

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE). Please follow our [Code of Conduct](CODE_OF_CONDUCT.md).
