# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Multiple windows made easy.** File ▸ **New Window with This Connection** (⇧⌘N) and the toolbar's **New Window** button open the current connection in another window, with the password already in use, so unsaved connections and passwords not in the Keychain work too. Saved connections have **Open in New Window**, and the connection screen has a **New Window** button. Every window keeps its own connection; closing one disconnects only that window. A window that macOS restores after a relaunch shows the connection screen and never connects by itself.

## [1.1.0] - 2026-11-16

### Added

- **Check for Updates…** in the app menu. When a newer release exists, CcinnMysql shows its version and release notes. **Download & Open** downloads the disk image, verifies its size and SHA-256 against the release's `SHA256SUMS.txt`, saves it to Downloads without overwriting anything, and opens it. **Release Page**, **Skip This Version** and **Later** are also available.
- A quiet automatic check at most once a day (retried after an hour when offline), on by default, switchable in **Settings → General → Updates**.
- Project links: the Help menu now has **CcinnMysql on GitHub**, **Release Notes** and **Report an Issue…**; the About window shows the GitHub link; Settings → General shows the version and project links.

## [1.0.0] - 2026-11-15

### Added

- Native macOS client for MySQL 5.5 → 9.x, MariaDB 10/11 and Percona Server, with a pure-Swift MySQL protocol client.
- TLS via `SSLRequest` and an in-place upgrade of the same socket; modes disabled, preferred, required, verify CA and verify identity; custom CA and PKCS#12 client certificates.
- Authentication: `mysql_native_password`, `caching_sha2_password` (fast and full, over TLS or RSA-OAEP), `sha256_password`, MariaDB `client_ed25519`, opt-in `mysql_clear_password`.
- Schema browser with tables grouped by storage engine, views, sequences, procedures, functions, triggers and events.
- Table insights: columns, indexes with cardinality, foreign keys in both directions, partitions, size estimates, DDL, data preview, and findings (missing primary key, redundant/duplicate indexes, AUTO_INCREMENT headroom, non-transactional engines).
- Server views: overview, processlist with pinned kills, InnoDB transactions / lock waits / latest deadlock, top statements from `performance_schema`, replication and topology (replicas, Group Replication, Galera, ProxySQL), variables, status with per-second rates, users and grants.
- SQL workbench with completion, `DELIMITER` support, automatic LIMIT, error positions, history, export, charts, visual EXPLAIN (`FORMAT=JSON`, `EXPLAIN ANALYZE`, MariaDB `ANALYZE FORMAT=JSON`) and safe inline row editing.
- SSH tunnels through the system OpenSSH client; Keychain secrets.
- Built-in MCP server (`CcinnMysql mcp`) with per-connection AI access, app-enforced and server-enforced read-only mode, limits, cancellation, a fresh session per call, connections tagged `program_name = 'CcinnMysql MCP'` and an audit log; the README and SECURITY.md describe what read-only covers and recommend a dedicated SELECT-only MySQL user.
