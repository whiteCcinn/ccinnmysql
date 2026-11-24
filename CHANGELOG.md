# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **The Data tab pages through the whole table and sorts on the server.** 1.6 showed the first 200 rows and sorted only those: sorting `id` descending showed the largest id among the first 200. Now:
  - a click on a column header asks the server: ascending, then descending, then the table's own order;
  - first, previous and next page of 200 rows, with the position (`Rows 201–400 of ≈ 2.8M`, the exact count on the last page) and row numbers that continue across pages;
  - pages are read by key where the server compares the sort exactly as it orders it (`WHERE (sort, key) > (last row)`), so page 5,000 costs what page 1 does; nullable, floating-point, binary, ENUM/SET, TEXT and TIMESTAMP sorts, and tables without a key, read by offset, with the other columns breaking ties;
  - the page on screen stays while the next one loads; Reload, cell edits and Open in Editor act on it. An edit confirmed after another page arrived is refused rather than applied to the row now in its place.

## [1.6.1] - 2026-11-24

### Fixed

- **Completion keeps up with typing.** The suggestion list narrows with every key, Backspace included, without waiting: 1.6.0 waited 70 ms after each key and started over on the next one, so while typing a table name the list stayed closed, or kept showing the list for the earlier letters.
- **Return and Tab insert the name you typed.** With `crm` listed and `_p` typed quickly, 1.6.0 could insert the first table of the older list (`crm_contact` instead of `crm_pipeline`).
- **Names inside back-quotes and in the middle of a word.** Typing inside `` `us` `` or editing `us|ers` listed every table unfiltered and inserted the choice beside the existing text (`` `ususers` ``). The suggestions now match the letters before the cursor, the whole name is replaced, and a back-quoted name stays back-quoted. A back-quote typed after `FROM ` opens the table list.
- **More places suggest tables:** after `STRAIGHT_JOIN`, `LOCK TABLES`, `FLUSH TABLES`, `CREATE INDEX … ON`, `DROP INDEX … ON`, `CREATE TRIGGER … ON`, `GRANT … ON`, `REVOKE … ON` and a statement-leading `EXPLAIN`; CTE names defined by the statement's `WITH`; names that start with digits (`2024_report`). `RENAME TABLE … TO` no longer suggests functions, and `FROM` inside `EXTRACT(… FROM …)` or `TRIM(… FROM …)` no longer suggests tables.
- **Better order:** exact and prefix matches first, shorter names first among equals, numbers in natural order (`t2` before `t10`); scattered letters (`us` in `status_log`) no longer match.
- **A new query tab knows its database right away.** A tab opened before the database list loaded had no current database until a statement ran, so completion offered no tables; it now uses the connection's default database, as its session does.
- **Schema stays current.** Tables and columns cached for completion reload in the background after five minutes, so tables created by migrations or other clients appear without a refresh. DDL run in the editor reloads every database it names and the columns of the tables it changes. A database whose table list cannot be read is asked again after a minute instead of on every key. Missing tables and columns no longer hold the list back: it shows what is known at once and fills in when they arrive.
- **`CREATE DATABASE` and `DROP DATABASE`** run in the editor now update the database list in the sidebar and in completion.
- **Faster on large schemas and long scripts:** with 20,000 tables, opening the list takes about 5 ms instead of 33 ms, and each key typed afterwards under 1 ms. Completion reads only the statement at the cursor, however long the script.

## [1.6.0] - 2026-11-19

### Added

- **Knowledge from 1.5 carries over on first launch:** table and column notes (with their value meanings), glossary terms, the relationships you or an AI added, your verdicts and linked folders, merged as a 1.5 backup's knowledge is merged. The Knowledge tab says once what came over and what did not; Refresh rebuilds the structure. It runs once and leaves the 1.5 files in place.

### Changed

- **The knowledge base now follows the design shared by CcinnStarRocks and CcinnPsql**, so knowledge files, backups and the MCP tools have one shape across the ccinn apps:
  - knowledge is kept per database and keyed by the server's endpoint (through the SSH bastion when tunnelled), so every connection that reaches a server shares it, and it can be linked to any number of local projects;
  - relationships carry their evidence and a confidence (0–100) computed from it: declared foreign keys are facts (100); joins in view, procedure, function, trigger and event definitions, in the editor's query history, in the code of the folders you link (`scan`, with file and line), in code an AI cited, and in names are inferred; your Confirm or Reject always wins;
  - structure fingerprints mark notes and relationships stale when their table changes; notes, a glossary in any language, subject areas and Mermaid ER diagrams;
  - the Knowledge tab (toolbar **Knowledge**, or right-click a database → **Knowledge Base**) refreshes, reviews relationships, shows notes, glossary, diagrams and linked projects.
- **MCP knowledge tools are renamed** to the shared set: `list_knowledge`, `knowledge_overview`, `search_knowledge`, `explain_table`, `find_join_path`, `er_diagram`, `refresh_knowledge`, and for writes `link_project`, `add_notes`, `add_relationships`, `define_terms`, `define_subject_area`, `remove_knowledge` (replacing `knowledge_status`, `knowledge_build`, `knowledge_search`, `knowledge_context`, `knowledge_join_path`, `knowledge_erd`, `knowledge_annotate`). Prompts `build_knowledge` and `answer_with_knowledge`. They pass the same privilege check as every tool and show only what the connection's account can see, down to the columns it may read; a refresh through an account that sees part of a database leaves the rest as it was. Writes need the connection's **AI may write knowledge** setting (Settings → MCP, on by default) and `mcp --no-knowledge-writes` turns them off for the whole server.
- **Export and import** became **File ▸ Export / Import Settings and Knowledge…** (also Settings → General → Backup): settings and optionally query history are included too, the import previews every change with per-connection choices and highlights changes that weaken security, project folders can be remapped, and a snapshot saved first lets *Restore Pre-Import Snapshot* undo exactly what the import wrote. Backups made by 1.5 still import.
- The MCP audit log records the AI client's name and, for knowledge writes, what changed.
- Editing a connection's AI access or favourite now counts as a change of the connection, so the newer side wins an import conflict.

### Removed

- The Knowledge tab's **Export Markdown…** and **Reset…**; **Copy Mermaid** remains, and an unreadable knowledge file is left untouched rather than replaced.
- Settings → Backup (replaced by the Backup window).

### Fixed

- Two windows on the same connection overwrote each other's query history: each kept its own copy and wrote it back. Windows now update the file under a shared lock and reread it when another one changed it.

## [1.5.1] - 2026-11-19

### Fixed

- **Knowledge tab, Relationships:** From and To show `table(column)` labels in full at the default window size; 1.5.0 cut them off on every row. A label that still doesn't fit loses its middle, so the column names stay readable, and shows in full on hover.
- **Counts in the singular:** "1 view", "1 relationship", "1 file", "≈ 1 row" in the Knowledge tab, the exported Markdown and the backup screen. 1.5.0 wrote "1 views".
- **CI:** the checks that the SQL formatter stays linear now measure how its time grows when the input is 8 times larger, instead of a fixed time limit. A busy CI runner no longer fails them; a quadratic slowdown still does.

## [1.5.0] - 2026-11-19

### Added

- **Knowledge base** per database: maps how the tables relate and keeps what AI assistants learn about them.
  - **Built from facts** (metadata only, no rows):
    - declared foreign keys;
    - naming conventions (`user_id` → `users.id`, camelCase, shared prefixes, plurals, self references, keys named like the column; type-checked, polymorphic pairs skipped);
    - `JOIN … ON`, `USING` and comma-join equalities in view, routine, trigger and event definitions;
    - the same in the source files of the code folders you link, with file and line.

    Every relationship lists its sources, confidence and evidence. Rebuilds keep notes, report added, removed and changed tables, and flag outdated notes.
  - **Judgements with provenance:** table purposes, column notes with value meanings, glossary terms with a read-only SQL recipe, relationships with evidence, and verdicts. Each records its author (AI or user) and time. An AI cannot change what the user wrote; rejected relationships are never used.
  - **Knowledge tab** (toolbar, or a database's context menu):
    - linked folders, and build with progress and cancel;
    - relationships with Confirm / Reject and evidence, and tables with notes and code locations;
    - notes review and a neighbourhood diagram;
    - Copy Mermaid ER Diagram and Export Markdown (no host, user or local paths).
  - **MCP tools:** `knowledge_status`, `knowledge_build`, `knowledge_search` (also CJK), `knowledge_context`, `knowledge_join_path` (ready-to-use `JOIN … ON`), `knowledge_erd` (Mermaid) and `knowledge_annotate`. All but `knowledge_build` work offline. The server instructions tell AIs to consult the knowledge base before exploring table by table.
  - **Storage:** local, owner-only files, one per connection and database. Writes from the app and several MCP processes are serialized per file, and unreadable or newer-format files are never overwritten.
- **Move to another Mac** (File ▸ Export / Import Connections & Knowledge…, Settings → Backup).
  - **Export:** one owner-only backup file with the saved connections and, optionally, their knowledge bases and their secrets. Secrets are encrypted with a passphrase (PBKDF2-HMAC-SHA256 with 600,000 iterations, AES-256-GCM).
  - **Import:** a merge. Connections are matched by id and replaced only on request. Passwords are restored only with the right passphrase, and a wrong one changes nothing. Knowledge bases are merged per note, newer first and the user's notes over an AI's. Paths under the old home folder follow the new one.
  - **Locate…** repoints a linked folder that moved, keeping its name and evidence.

## [1.4.0] - 2026-11-19

### Added

- **Excel export.** *Export as › Excel…* writes an `.xlsx` workbook (no Office needed, no external library):
  - numbers are number cells only when Excel keeps them exactly: integers show every digit (format `0`, never `1.2E+12`), decimals their scale (`24.10`); integers and decimals beyond 15 significant digits, such as 64-bit IDs, and ZEROFILL values with leading zeros stay exact text;
  - dates, ENUM, JSON and everything else are exact text; NULL is an empty cell; text over Excel's 32,767-character cell limit is cut, and the toast says how many values were;
  - the header row is bold and frozen, and columns are sized to their content;
  - results larger than a sheet (1,048,575 rows or 16,384 columns) are refused before anything is written, with a hint to use CSV.
- **Multi-row SQL INSERT.** *Copy as* and *Export as › SQL INSERT, Multi-row* write `INSERT INTO t (…) VALUES` with one row per line. A new statement starts every 1,000 rows, or before a row that would take it past about 1 MB, so each statement stays under `max_allowed_packet`. The grid's context menu has *Copy Rows as Multi-row INSERT*.
- The result menu has *Copy as* (CSV, TSV, SQL INSERT one per row, multi-row) and *Export as* (all of those and Excel) for the whole result.

### Changed

- INSERTs for a result whose columns name no table (computed columns) take the table of a plain single-table `SELECT … FROM db.t [alias]`; INSERTs never target the query's alias. Exported files are named after the source table.

### Fixed

- `nan` and `inf` values of floating-point columns were written into INSERTs unquoted; they are now quoted.

## [1.3.1] - 2026-11-19

### Fixed

- **SQL completion showed suggestions for text you had already typed past.** After the first suggestions appeared, the popup kept showing an earlier list while it moved and resized for the new one: `select * from` listed `SELECT`, `SET` and `SET SESSION`, and a table name typed out kept the list of the first letters, so Return could insert a different name. The popup now shows exactly the suggestions for the text at the cursor.
- **Table names are suggested right after `FROM`.** A space after `FROM`, `JOIN`, `INTO`, `UPDATE`, `TABLE` or `TRUNCATE` opens the list of tables and views in the current database; a space after `CALL` opens the procedures, and after `USE` the databases. Return and Tab never open it.
- `ORDER BY … DESC` no longer suggests tables: only a statement that starts with `DESC` / `DESCRIBE` names a table.

## [1.3.0] - 2026-11-18

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
