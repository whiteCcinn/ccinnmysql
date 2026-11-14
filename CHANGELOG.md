# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
- Built-in MCP server (`CcinnMysql mcp`) with per-connection AI access, app-enforced and server-enforced read-only mode, limits, cancellation and an audit log.
