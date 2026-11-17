# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Precise SQL error markers.**
  - Syntax errors are underlined on the token where MySQL or MariaDB stopped, found from the server's `near '…' at line N`: also in multi-line statements, when the same text occurs several times, and when the server shortened its echo (MySQL and MariaDB cut it at 80 bytes) or replaced emoji with `?`.
  - Errors without a position are located by what they name: unknown or ambiguous columns (after `WHERE`, `ON`, `ORDER BY`, … when the message gives the clause), tables, databases, functions, procedures, key columns and system variables, in MySQL's and MariaDB's wording.
  - The message appears after the line and in a bar under the editor with its line and column, with previous/next navigation. The result shows the error code with the editor position, the server's message and **Show in Editor**.
  - `EXPLAIN`, `EXPLAIN ANALYZE` and the automatic `LIMIT` map back to the text you wrote; a marker never quotes the `LIMIT` the app added.
- **Checks while typing.** Unclosed strings, back-quoted names, comments (`/*` and `/*!`) and parentheses are flagged without contacting the server, following the session's `NO_BACKSLASH_ESCAPES`.
- **Format SQL** (⌥⌘L, toolbar button and Edit menu) formats the selection, or the whole script when nothing is selected, as one undoable edit:
  - main clauses on their own lines and one item per line in multi-item SELECT / GROUP BY / ORDER BY / SET / VALUES / `ON DUPLICATE KEY UPDATE` lists;
  - `AND` / `OR` conditions on their own lines in WHERE, HAVING and ON (not inside parentheses, CASE or BETWEEN);
  - joins, `FOR UPDATE`, indented subqueries and CTEs, split multi-branch CASE expressions;
  - `CREATE TABLE` columns and partitions one per line, table options after the `)` as `SHOW CREATE TABLE` writes them.

  Only whitespace and letter case change, and only where no supported server could read the text differently:
  - the case of the keywords every supported server reserves (checked against MySQL 5.5 to 9.6, Percona 8.0 and MariaDB 10.6 to 12.0), and of keywords in positions where they cannot be names. A word after a `.` (`shop.order`) is always a name. Names, functions, strings, quoted identifiers, comments and optimizer hints keep their exact text;
  - text that touches stays touching, except around punctuation, operators and comments. So `COUNT (*)` and `COUNT(*)` (MySQL parses them differently), `X'41'`, `_utf8mb4'a'`, `\N` and `0x1F` keep their meaning;
  - strings and double-quoted names are read as the session reads them (`NO_BACKSLASH_ESCAPES`, `ANSI_QUOTES`; the tab reads the session's `sql_mode` and character set when it opens and again after any `SET`, `CALL` or executable comment, and until then text that depends on them is left as it is), and `DELIMITER` scripts keep their command lines;
  - numbers are read exactly as MySQL and MariaDB read them (`1.5x` is 1.5 named `x`, `1e2end` is 1e2 followed by END), and text with a number or hexadecimal literal the server cannot read (`1.end`, `x'4'`), or with a backslash outside strings (`\N`, NULL on MariaDB but an error on MySQL 8), is not formatted;
  - account names such as `'root'@'%'` stay together, and only ASCII words count as keywords (`ſelect` is a name, as for the server);
  - CASE expressions are laid out only when every `end` in the statement closes one; with a column, alias or CTE named `end`, and in stored programs and other compound statements (`END CASE`, `END IF`), CASE keywords stay as written;
  - CRLF line breaks stay CRLF.

  The result is re-lexed and split into statements again and compared with the original before it replaces anything. A selection that starts or ends inside a word or a string is widened to whole tokens. Formatting runs in the background, stops when you type, and never interrupts an input method. When it changes nothing (you typed meanwhile, an input method was composing, or the result could not be proven to mean the same), the bar under the editor says why. **Settings ▸ General** sets the keyword case (UPPER, lower or unchanged) and the indent (2 or 4 spaces).

### Fixed

- AI (MCP) read-only mode refused the built-in functions `REPLACE()`, `INSERT()` and `TRUNCATE()` (for example `REPLACE(note, 'o', '0')`) as if they were the statements of the same name; they are allowed as functions now, while the statements stay refused.
- Syntax errors were never underlined: the editor looked for `at line N` at the end of a message that ended with ` (error 1064)`.
- Run, Run All and EXPLAIN split a script as the session reads it: with `NO_BACKSLASH_ESCAPES` or `ANSI_QUOTES` in the session's `sql_mode`, a backslash in a string or a double-quoted name could make the app split a script at the wrong `;`. Checks while typing and highlighting follow `ANSI_QUOTES` too, and the session's mode is read when the tab opens instead of after its first statement.
- Error markers no longer stay at a stale position after editing: they move with edits made before the failing statement and disappear when that statement is edited or the text is replaced, including edits made while it was still running.
- Starting a connection while another one was still connecting (a double-click, a second **Connect**) let the first finish later. It could leave a connection and its SSH tunnel open in the background, or replace the new attempt's status with its own progress or error. Starting a connection now cancels the one in progress, and whatever a cancelled attempt reports later is ignored.
- SSH tunnels no longer use or become a shared connection (`ControlMaster`) from `~/.ssh/config`. With `ControlMaster auto`, closing that window used to cut the other windows and terminal sessions sharing it. With a shared connection already running, the tunnel's port was opened by that connection instead: it stayed open (still forwarding to the database) after the tunnel closed, every connect added another one, and the connection's own SSH authentication was never used. Your own terminal sessions keep their shared connections.

### Security

- AI (MCP) read-only mode let through `SELECT … INTO @variable` and locking reads (`FOR SHARE`, `LOCK IN SHARE MODE`) when the keyword was written directly after a number, as in `SELECT 1.5into @v`: the app read `1.5into` as one number, while MySQL and MariaDB read 1.5 followed by INTO. File writes (`INTO OUTFILE`, `INTO DUMPFILE`) were always refused. Connections that confirm writes did not ask before `SELECT 1.5into outfile …` either. Numbers now end where the servers end them (highlighting included), and read-only mode also refuses text that servers or sessions could read differently: a backslash that moves the end of a string under `NO_BACKSLASH_ESCAPES`, a `;` left after `DELIMITER`, a malformed number. Locking reads could hold shared row locks until the AI session rolled back.
- On MariaDB, `\N` (NULL) glued to a keyword could hide `INTO @variable` and locking reads from AI (MCP) read-only mode in 1.2.0 (`SELECT \Ninto @v`, `… IS NOT \Nlock in share mode`, also through **explain_query** with `analyze`): MariaDB ends `\N` after the N, while the app read `Nlock` as one name. Read-only mode now refuses any backslash outside strings and quoted names, and Format SQL leaves such text unchanged.
- On servers that switch new connections to a multibyte character set such as GBK or Shift-JIS (`init_connect='SET NAMES gbk'`, which skips accounts with SUPER, so it hits exactly the plain accounts recommended for AI), AI (MCP) read-only mode could be bypassed in 1.2.0: in GBK the byte 0x5C after `中` is part of a character, so `SELECT '中\\' , ' INTO @v -- '` (two strings to the app) ran `INTO @v`, and similar text took row locks. 1.3.0 switches every connection to `utf8mb4` after the server's own setup, re-checks the character set before every read-only AI statement and refuses otherwise; Format SQL refuses sessions in other character sets.
- On accounts that can reach server files, server state or other sessions' data — `FILE`, `SUPER`, `PROCESS`, any `*_ADMIN`, global `ALL PRIVILEGES`, or `SELECT` on `*.*`, `mysql.*`, `performance_schema.*` or `sys.*` (also through a database pattern that matches one, such as `%`, `my%` or `m_sql`), also through roles (local `root` has all of them) — AI (MCP) read-only mode in 1.2.0 could run existing stored functions with side effects (write or read server files, sleep, hold named locks) and read password hashes (`mysql.user`) and other sessions' statements with their values (`performance_schema` statement history, the process list, also through views over it). Read-only AI tools now refuse such accounts unless **Settings → MCP** allows it for that connection, checked in the call's own session before every statement (roles included; a failed check refuses; on MariaDB, roles held through other roles can't be inspected and refuse with a message that says so). Even then `run_query` refuses the whole `mysql`, `performance_schema` and `sys` schemas (names in any case) and the `information_schema` views that show other sessions' statements (deny by default), and `get_processlist`, `get_innodb_status` and `get_top_statements` replace every literal in other sessions' statements with `?` (1.2.0 redacted only credentials). Routines and views that run with a privileged definer's rights cannot be checked from the outside (a view that `root` defined over the process list shows every session's statements to accounts without `PROCESS`): they are reported (in **Settings → MCP** and with read-only results), not refused.
- On MariaDB, AI (MCP) read-only mode in 1.2.0 allowed `SHOW GRANTS` and `SHOW CREATE USER`, which print the account's own password hash (`IDENTIFIED BY PASSWORD '*…'`), also for plain accounts. Read-only mode now refuses both on every server (MySQL 8 masks the hash unless the account can read `mysql.user`).
- AI (MCP) read-only mode in 1.2.0 allowed `EXPLAIN FOR CONNECTION <id>` and, on MariaDB, `SHOW EXPLAIN` / `SHOW ANALYZE … FOR <id>`, which print another session's plan with its values (`attached_condition: … 'card-4111-…'`). Read-only mode now refuses them.
- **get_replication_status** returned the replication applier's last SQL error as the server wrote it, which can quote a replicated statement and duplicate values (also in 1.2.0); everything between its quotes is now `?`, and `run_query` refuses `SHOW REPLICA STATUS` / `SHOW SLAVE STATUS`.
- Names reach the server as checked. The read-only deny lists compared Swift-lower-cased names, while MySQL and MariaDB read `information_schema.processlıst` (ı), `PROCESSLİST` (İ) and `proceſſlist` (ſ) as PROCESSLIST, and MariaDB also `ınformation_schema`, `performance_ſchema` and the Kelvin sign K. Read-only mode now refuses names and `database` arguments with any of the 19 letters whose case mapping contains an ASCII letter (ß İ ı ŉ ſ ǰ ẖ ẗ ẘ ẙ ẚ K ﬀ–ﬆ) and compares other names by an ASCII skeleton (case, compatibility forms and accents folded). A `database` argument with NUL (`information_\0schema`) reached the server without it, because the handshake dropped NUL: MCP arguments with control characters are refused, and connections refuse a user or database name with NUL instead of dropping it.
- AI (MCP) read-only mode let a plain account call loadable and component functions, which need no privilege (`audit_api_message_emit_udf`, `mysql_query_attribute_string`, `mysqlx_generate_document_id`, `sys_get` / `sys_set` / `sys_bineval` from lib_mysqludf_sys), and stored functions, which ran `INTO OUTFILE`, `LOAD_FILE`, `SLEEP` and `GET_LOCK` inside READ ONLY (also in 1.2.0). With the dynamic privilege `INNODB_REDO_LOG_ARCHIVE`, which has no `_ADMIN` suffix and so counted as plain, `SELECT innodb_redo_log_archive_start(…)` started a server-side file write. Read-only calls now use only the reviewed built-in functions of the server's flavor (verified on MySQL 8.4 and MariaDB 10.11); other functions need the connection's allowance in **Settings → MCP**, and every privilege outside a reviewed list counts as privileged.
- Read-only AI calls also remove the `sql_mode`s the app does not model (MariaDB's `ORACLE`, `MSSQL`, …, `PIPES_AS_CONCAT`, `IGNORE_SPACE`) for the call and refuse if one stays, check the exact text that is sent (after the automatic `LIMIT`, which itself keeps every token of the query), and **execute_statement** splits with the session's own `sql_mode`.

## [1.2.0] - 2026-11-17

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
