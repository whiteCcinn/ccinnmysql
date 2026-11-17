import Foundation

/// Keyword and function vocabulary for MySQL / MariaDB SQL.
public enum SQLKeywords {
    /// Words highlighted as keywords.
    public static let all: Set<String> = Set("""
    ACCOUNT ACTION ADD AFTER AGAINST ALGORITHM ALL ALTER ANALYZE AND ANY AS ASC AUTO_INCREMENT AVG_ROW_LENGTH BEFORE BEGIN \
    BETWEEN BIGINT BINARY BINLOG BIT BLOB BOOL BOOLEAN BOTH BTREE BY CALL CASCADE CASE CAST CHANGE CHAR CHARACTER CHARSET \
    CHECK CHECKSUM COLLATE COLLATION COLUMN COLUMNS COMMENT COMMIT COMMITTED COMPACT COMPRESSED CONDITION CONSTRAINT \
    CONTINUE CONVERT CREATE CROSS CURRENT CURRENT_DATE CURRENT_TIME CURRENT_TIMESTAMP CURRENT_USER CURSOR DATA DATABASE \
    DATABASES DATE DATETIME DAY DEALLOCATE DEC DECIMAL DECLARE DEFAULT DEFINER DELAYED DELETE DELIMITER DESC DESCRIBE \
    DETERMINISTIC DISABLE DISTINCT DISTINCTROW DIV DO DOUBLE DROP DUAL DUMPFILE DUPLICATE DYNAMIC EACH ELSE ELSEIF ENABLE \
    ENCLOSED END ENGINE ENGINES ENUM ESCAPED EVENT EVENTS EVERY EXCEPT EXECUTE EXISTS EXIT EXPLAIN EXTENDED FALSE FETCH \
    FIELDS FIRST FIXED FLOAT FLUSH FOLLOWING FOR FORCE FOREIGN FORMAT FROM FULL FULLTEXT FUNCTION GENERATED GLOBAL GRANT \
    GRANTS GROUP HANDLER HASH HAVING HELP HIGH_PRIORITY HOUR IF IGNORE IN INDEX INDEXES INFILE INNER INOUT INSERT INT \
    INTEGER INTERSECT INTERVAL INTO INVISIBLE INVOKER IS ISOLATION ITERATE JOIN JSON KEY KEYS KILL LAST LATERAL LEADING \
    LEAVE LEFT LESS LEVEL LIKE LIMIT LINES LIST LOAD LOCAL LOCK LOCKED LOGS LONGBLOB LONGTEXT LOOP LOW_PRIORITY MASTER \
    MATCH MAXVALUE MEDIUMBLOB MEDIUMINT MEDIUMTEXT MERGE MINUTE MOD MODIFY MONTH NATURAL NEXT NO NOT NOWAIT NULL NUMERIC \
    OFFSET ON ONLY OPTIMIZE OPTION OR ORDER OUT OUTER OUTFILE OVER PARTITION PARTITIONS PASSWORD PERSIST PRECEDING \
    PREPARE PRIMARY PRIVILEGES PROCEDURE PROCESSLIST PURGE QUARTER QUERY QUICK RANGE READ REAL RECURSIVE REDUNDANT \
    REFERENCES REGEXP RELEASE RENAME REPAIR REPEAT REPEATABLE REPLACE REPLICA REPLICAS REPLICATION REQUIRE RESET RESIGNAL \
    RESTRICT RETURN RETURNS REVOKE RIGHT RLIKE ROLE ROLLBACK ROLLUP ROUTINE ROW ROWS ROW_FORMAT SAVEPOINT SCHEDULE SCHEMA \
    SCHEMAS SECOND SECURITY SELECT SEPARATOR SEQUENCE SERIALIZABLE SESSION SET SHARE SHOW SIGNAL SIGNED SKIP SLAVE \
    SMALLINT SOME SOURCE SPATIAL SQL SQL_CALC_FOUND_ROWS SQL_NO_CACHE SQLEXCEPTION SQLSTATE SQLWARNING START STARTING \
    STATUS STOP STORED STRAIGHT_JOIN TABLE TABLES TABLESPACE TEMPORARY TEMPTABLE TERMINATED TEXT THAN THEN TIME TIMESTAMP \
    TINYBLOB TINYINT TINYTEXT TO TRAILING TRANSACTION TRIGGER TRIGGERS TRUE TRUNCATE TYPE UNBOUNDED UNCOMMITTED UNDEFINED \
    UNION UNIQUE UNLOCK UNSIGNED UNTIL UPDATE USAGE USE USER USING VALUE VALUES VARBINARY VARCHAR VARIABLES VIEW VIRTUAL \
    VISIBLE WAIT WARNINGS WEEK WHEN WHERE WHILE WINDOW WITH WORK WRITE XA XOR YEAR ZEROFILL
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// MySQL 8.0 reserved words (must be back-quoted when used as identifiers).
    public static let reserved: Set<String> = Set("""
    ACCESSIBLE ADD ALL ALTER ANALYZE AND AS ASC ASENSITIVE BEFORE BETWEEN BIGINT BINARY BLOB BOTH BY CALL CASCADE CASE \
    CHANGE CHAR CHARACTER CHECK COLLATE COLUMN CONDITION CONSTRAINT CONTINUE CONVERT CREATE CROSS CUBE CUME_DIST \
    CURRENT_DATE CURRENT_TIME CURRENT_TIMESTAMP CURRENT_USER CURSOR DATABASE DATABASES DAY_HOUR DAY_MICROSECOND \
    DAY_MINUTE DAY_SECOND DEC DECIMAL DECLARE DEFAULT DELAYED DELETE DENSE_RANK DESC DESCRIBE DETERMINISTIC DISTINCT \
    DISTINCTROW DIV DOUBLE DROP DUAL EACH ELSE ELSEIF EMPTY ENCLOSED ESCAPED EXCEPT EXISTS EXIT EXPLAIN FALSE FETCH \
    FIRST_VALUE FLOAT FLOAT4 FLOAT8 FOR FORCE FOREIGN FROM FULLTEXT FUNCTION GENERATED GET GRANT GROUP GROUPING GROUPS \
    HAVING HIGH_PRIORITY HOUR_MICROSECOND HOUR_MINUTE HOUR_SECOND IF IGNORE IN INDEX INFILE INNER INOUT INSENSITIVE INSERT \
    INT INT1 INT2 INT3 INT4 INT8 INTEGER INTERSECT INTERVAL INTO IO_AFTER_GTIDS IO_BEFORE_GTIDS IS ITERATE JOIN JSON_TABLE \
    KEY KEYS KILL LAG LAST_VALUE LATERAL LEAD LEADING LEAVE LEFT LIKE LIMIT LINEAR LINES LOAD LOCALTIME LOCALTIMESTAMP \
    LOCK LONG LONGBLOB LONGTEXT LOOP LOW_PRIORITY MASTER_BIND MASTER_SSL_VERIFY_SERVER_CERT MATCH MAXVALUE MEDIUMBLOB \
    MEDIUMINT MEDIUMTEXT MIDDLEINT MINUTE_MICROSECOND MINUTE_SECOND MOD MODIFIES NATURAL NOT NO_WRITE_TO_BINLOG NTH_VALUE \
    NTILE NULL NUMERIC OF ON OPTIMIZE OPTIMIZER_COSTS OPTION OPTIONALLY OR ORDER OUT OUTER OUTFILE OVER PARTITION \
    PERCENT_RANK PRECISION PRIMARY PROCEDURE PURGE RANGE RANK READ READS READ_WRITE REAL RECURSIVE REFERENCES REGEXP \
    RELEASE RENAME REPEAT REPLACE REQUIRE RESIGNAL RESTRICT RETURN REVOKE RIGHT RLIKE ROW ROWS ROW_NUMBER SCHEMA SCHEMAS \
    SECOND_MICROSECOND SELECT SENSITIVE SEPARATOR SET SHOW SIGNAL SMALLINT SPATIAL SPECIFIC SQL SQLEXCEPTION SQLSTATE \
    SQLWARNING SQL_BIG_RESULT SQL_CALC_FOUND_ROWS SQL_SMALL_RESULT SSL STARTING STORED STRAIGHT_JOIN SYSTEM TABLE \
    TERMINATED THEN TINYBLOB TINYINT TINYTEXT TO TRAILING TRIGGER TRUE UNDO UNION UNIQUE UNLOCK UNSIGNED UPDATE USAGE \
    USE USING UTC_DATE UTC_TIME UTC_TIMESTAMP VALUES VARBINARY VARCHAR VARCHARACTER VARYING VIRTUAL WHEN WHERE WHILE \
    WINDOW WITH WRITE XOR YEAR_MONTH ZEROFILL
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Words reserved by every supported server, so never an unquoted name (except right after `.`): the only words whose
    /// letter case the formatter changes as such, and after which whitespace before `(` does not matter.
    ///
    /// Server-verified, not taken from documentation: each word of `all` and `reserved` was sent as `SELECT 1 AS <word>`
    /// to MySQL 5.5.62, 5.6.51, 5.7.44, 8.0.46, 8.4.13, 9.6.0, Percona 8.0.46 and MariaDB 10.6.28, 10.11.19, 11.4.13, 12.0.2;
    /// these are the words every one rejected with error 1064 (MySQL 8.4 also lists all of them as reserved in
    /// information_schema.KEYWORDS). `FormatterIntegrationTests` re-checks them on the servers it runs against. Left out
    /// because some server takes them as names: DATABASE, SCHEMA, OPTION (MariaDB), PARTITION (MySQL 5.5), the words only
    /// newer versions reserve (ROW, ROWS, OVER, WINDOW, LATERAL, FUNCTION, …) and MASTER_BIND (no longer reserved in 8.4).
    public static let reservedEverywhere: Set<String> = Set("""
    ADD ALL ALTER ANALYZE AND AS ASC ASENSITIVE BEFORE BETWEEN BIGINT BINARY BLOB BOTH BY CALL CASCADE CASE CHANGE CHAR \
    CHARACTER CHECK COLLATE COLUMN CONDITION CONSTRAINT CONTINUE CONVERT CREATE CROSS CURRENT_DATE CURRENT_TIME \
    CURRENT_TIMESTAMP CURRENT_USER CURSOR DATABASES DAY_HOUR DAY_MICROSECOND DAY_MINUTE DAY_SECOND DEC DECIMAL DECLARE \
    DEFAULT DELAYED DELETE DESC DESCRIBE DETERMINISTIC DISTINCT DISTINCTROW DIV DOUBLE DROP DUAL EACH ELSE ELSEIF ENCLOSED \
    ESCAPED EXISTS EXIT EXPLAIN FALSE FETCH FLOAT FLOAT4 FLOAT8 FOR FORCE FOREIGN FROM FULLTEXT GRANT GROUP HAVING \
    HIGH_PRIORITY HOUR_MICROSECOND HOUR_MINUTE HOUR_SECOND IF IGNORE IN INDEX INFILE INNER INOUT INSENSITIVE INSERT INT \
    INT1 INT2 INT3 INT4 INT8 INTEGER INTERVAL INTO IS ITERATE JOIN KEY KEYS KILL LEADING LEAVE LEFT LIKE LIMIT LINEAR LINES \
    LOAD LOCALTIME LOCALTIMESTAMP LOCK LONG LONGBLOB LONGTEXT LOOP LOW_PRIORITY MATCH MAXVALUE MEDIUMBLOB MEDIUMINT \
    MEDIUMTEXT MIDDLEINT MINUTE_MICROSECOND MINUTE_SECOND MOD MODIFIES NATURAL NOT NO_WRITE_TO_BINLOG NULL NUMERIC ON \
    OPTIMIZE OPTIONALLY OR ORDER OUT OUTER OUTFILE PRECISION PRIMARY PROCEDURE PURGE RANGE READ READS READ_WRITE REAL \
    REFERENCES REGEXP RELEASE RENAME REPEAT REPLACE REQUIRE RESIGNAL RESTRICT RETURN REVOKE RIGHT RLIKE SCHEMAS \
    SECOND_MICROSECOND SELECT SENSITIVE SEPARATOR SET SHOW SIGNAL SMALLINT SPATIAL SPECIFIC SQL SQLEXCEPTION SQLSTATE \
    SQLWARNING SQL_BIG_RESULT SQL_CALC_FOUND_ROWS SQL_SMALL_RESULT SSL STARTING STRAIGHT_JOIN TABLE TERMINATED THEN \
    TINYBLOB TINYINT TINYTEXT TO TRAILING TRIGGER TRUE UNDO UNION UNIQUE UNLOCK UNSIGNED UPDATE USAGE USE USING UTC_DATE \
    UTC_TIME UTC_TIMESTAMP VALUES VARBINARY VARCHAR VARCHARACTER VARYING WHEN WHERE WHILE WITH WRITE XOR YEAR_MONTH \
    ZEROFILL
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Keywords that start a statement.
    public static let statementStarters: [String] = [
        "SELECT", "WITH", "SHOW", "DESCRIBE", "EXPLAIN", "EXPLAIN ANALYZE", "EXPLAIN FORMAT=JSON", "USE", "INSERT INTO", "REPLACE INTO",
        "UPDATE", "DELETE FROM", "CREATE TABLE", "CREATE VIEW", "CREATE DATABASE", "CREATE INDEX", "CREATE PROCEDURE", "CREATE FUNCTION",
        "CREATE TRIGGER", "CREATE EVENT", "ALTER TABLE", "DROP TABLE", "DROP VIEW", "TRUNCATE TABLE", "RENAME TABLE", "ANALYZE TABLE",
        "OPTIMIZE TABLE", "CHECK TABLE", "CALL", "KILL QUERY", "SET", "SET SESSION", "START TRANSACTION", "COMMIT", "ROLLBACK",
        "LOCK TABLES", "UNLOCK TABLES", "FLUSH", "GRANT", "REVOKE", "TABLE", "VALUES",
    ]

    /// Targets offered after SHOW.
    public static let showTargets: [String] = [
        "DATABASES", "TABLES", "FULL TABLES", "TABLE STATUS", "COLUMNS FROM", "FULL COLUMNS FROM", "INDEX FROM", "CREATE TABLE",
        "CREATE VIEW", "CREATE PROCEDURE", "CREATE FUNCTION", "CREATE TRIGGER", "CREATE EVENT", "PROCESSLIST", "FULL PROCESSLIST",
        "VARIABLES", "GLOBAL VARIABLES", "SESSION VARIABLES", "STATUS", "GLOBAL STATUS", "ENGINE INNODB STATUS", "ENGINES",
        "GRANTS", "GRANTS FOR", "WARNINGS", "ERRORS", "TRIGGERS", "EVENTS", "PROCEDURE STATUS", "FUNCTION STATUS", "PLUGINS",
        "REPLICA STATUS", "SLAVE STATUS", "BINARY LOGS", "BINARY LOG STATUS", "MASTER STATUS", "REPLICAS", "CHARACTER SET",
        "COLLATION", "OPEN TABLES", "PRIVILEGES", "PROFILES",
    ]

    /// Keywords offered inside expressions and after table references.
    public static let clauseKeywords: [String] = [
        "FROM", "WHERE", "GROUP BY", "HAVING", "ORDER BY", "LIMIT", "AND", "OR", "NOT", "IN", "EXISTS", "BETWEEN", "LIKE", "REGEXP",
        "IS NULL", "IS NOT NULL", "CASE", "WHEN", "THEN", "ELSE", "END", "AS", "DISTINCT", "ASC", "DESC", "UNION", "UNION ALL",
        "OVER", "PARTITION BY", "WINDOW", "WITH ROLLUP", "INTERVAL", "COLLATE", "DIV", "MOD", "XOR", "TRUE", "FALSE", "NULL",
    ]
}

/// A built-in function offered by completion.
public struct SQLFunction: Sendable, Hashable {
    public enum Category: String, Sendable {
        case aggregate, window, date, string, math, conditional, json, information, encryption, spatial
    }

    public let name: String
    public let signature: String
    public let summary: String
    public let category: Category
}

public enum SQLFunctions {
    public static let all: [SQLFunction] = {
        func f(_ name: String, _ signature: String, _ summary: String, _ category: SQLFunction.Category) -> SQLFunction {
            SQLFunction(name: name, signature: signature, summary: summary, category: category)
        }
        return [
            // Aggregate
            f("COUNT", "COUNT(expr)", "Number of non-NULL values", .aggregate),
            f("SUM", "SUM(expr)", "Sum", .aggregate), f("AVG", "AVG(expr)", "Average", .aggregate),
            f("MIN", "MIN(expr)", "Minimum", .aggregate), f("MAX", "MAX(expr)", "Maximum", .aggregate),
            f("GROUP_CONCAT", "GROUP_CONCAT(expr ORDER BY … SEPARATOR ',')", "Concatenate group values", .aggregate),
            f("JSON_ARRAYAGG", "JSON_ARRAYAGG(expr)", "Aggregate into a JSON array", .aggregate),
            f("JSON_OBJECTAGG", "JSON_OBJECTAGG(key, value)", "Aggregate into a JSON object", .aggregate),
            f("STDDEV", "STDDEV(expr)", "Population standard deviation", .aggregate),
            f("STDDEV_SAMP", "STDDEV_SAMP(expr)", "Sample standard deviation", .aggregate),
            f("VARIANCE", "VARIANCE(expr)", "Population variance", .aggregate),
            f("BIT_AND", "BIT_AND(expr)", "Bitwise AND", .aggregate), f("BIT_OR", "BIT_OR(expr)", "Bitwise OR", .aggregate),
            // Window
            f("ROW_NUMBER", "ROW_NUMBER() OVER (…)", "Row number within the partition", .window),
            f("RANK", "RANK() OVER (…)", "Rank with gaps", .window), f("DENSE_RANK", "DENSE_RANK() OVER (…)", "Rank without gaps", .window),
            f("NTILE", "NTILE(n) OVER (…)", "Bucket number", .window), f("LAG", "LAG(expr, offset, default) OVER (…)", "Previous row value", .window),
            f("LEAD", "LEAD(expr, offset, default) OVER (…)", "Next row value", .window),
            f("FIRST_VALUE", "FIRST_VALUE(expr) OVER (…)", "First value in the frame", .window),
            f("LAST_VALUE", "LAST_VALUE(expr) OVER (…)", "Last value in the frame", .window),
            f("PERCENT_RANK", "PERCENT_RANK() OVER (…)", "Relative rank", .window), f("CUME_DIST", "CUME_DIST() OVER (…)", "Cumulative distribution", .window),
            // Date and time
            f("NOW", "NOW([fsp])", "Current date and time", .date), f("CURDATE", "CURDATE()", "Current date", .date),
            f("CURTIME", "CURTIME([fsp])", "Current time", .date), f("UTC_TIMESTAMP", "UTC_TIMESTAMP([fsp])", "Current UTC date and time", .date),
            f("DATE", "DATE(expr)", "Date part", .date), f("TIME", "TIME(expr)", "Time part", .date),
            f("DATE_FORMAT", "DATE_FORMAT(date, format)", "Format a date ('%Y-%m-%d')", .date),
            f("STR_TO_DATE", "STR_TO_DATE(str, format)", "Parse a date", .date),
            f("DATE_ADD", "DATE_ADD(date, INTERVAL n unit)", "Add an interval", .date), f("DATE_SUB", "DATE_SUB(date, INTERVAL n unit)", "Subtract an interval", .date),
            f("DATEDIFF", "DATEDIFF(a, b)", "Days between dates", .date),
            f("TIMESTAMPDIFF", "TIMESTAMPDIFF(unit, a, b)", "Difference in units", .date),
            f("TIMESTAMPADD", "TIMESTAMPADD(unit, n, ts)", "Add units", .date),
            f("UNIX_TIMESTAMP", "UNIX_TIMESTAMP([date])", "Seconds since the epoch", .date),
            f("FROM_UNIXTIME", "FROM_UNIXTIME(seconds[, format])", "Epoch seconds to datetime", .date),
            f("CONVERT_TZ", "CONVERT_TZ(dt, from_tz, to_tz)", "Convert between time zones", .date),
            f("YEAR", "YEAR(date)", "Year", .date), f("MONTH", "MONTH(date)", "Month", .date), f("DAY", "DAY(date)", "Day of month", .date),
            f("HOUR", "HOUR(time)", "Hour", .date), f("MINUTE", "MINUTE(time)", "Minute", .date), f("WEEK", "WEEK(date[, mode])", "Week number", .date),
            f("DAYOFWEEK", "DAYOFWEEK(date)", "1 = Sunday … 7 = Saturday", .date), f("LAST_DAY", "LAST_DAY(date)", "Last day of the month", .date),
            f("EXTRACT", "EXTRACT(unit FROM date)", "Extract a part", .date),
            // String
            f("CONCAT", "CONCAT(s1, s2, …)", "Concatenate", .string), f("CONCAT_WS", "CONCAT_WS(sep, s1, s2, …)", "Concatenate with separator", .string),
            f("SUBSTRING", "SUBSTRING(str, pos[, len])", "Substring", .string), f("SUBSTRING_INDEX", "SUBSTRING_INDEX(str, delim, count)", "Substring before a delimiter", .string),
            f("LENGTH", "LENGTH(str)", "Length in bytes", .string), f("CHAR_LENGTH", "CHAR_LENGTH(str)", "Length in characters", .string),
            f("LOWER", "LOWER(str)", "Lower case", .string), f("UPPER", "UPPER(str)", "Upper case", .string),
            f("TRIM", "TRIM([BOTH|LEADING|TRAILING x FROM] str)", "Trim", .string), f("REPLACE", "REPLACE(str, from, to)", "Replace occurrences", .string),
            f("LPAD", "LPAD(str, len, pad)", "Left pad", .string), f("RPAD", "RPAD(str, len, pad)", "Right pad", .string),
            f("LOCATE", "LOCATE(substr, str[, pos])", "Position of a substring", .string), f("INSTR", "INSTR(str, substr)", "Position of a substring", .string),
            f("LEFT", "LEFT(str, len)", "Leftmost characters", .string), f("RIGHT", "RIGHT(str, len)", "Rightmost characters", .string),
            f("REGEXP_LIKE", "REGEXP_LIKE(expr, pattern[, match_type])", "Regular expression match", .string),
            f("REGEXP_REPLACE", "REGEXP_REPLACE(expr, pattern, repl)", "Regular expression replace", .string),
            f("REGEXP_SUBSTR", "REGEXP_SUBSTR(expr, pattern)", "Regular expression substring", .string),
            f("FORMAT", "FORMAT(x, decimals[, locale])", "Format a number", .string), f("HEX", "HEX(x)", "Hexadecimal", .string),
            f("UNHEX", "UNHEX(str)", "From hexadecimal", .string), f("FIND_IN_SET", "FIND_IN_SET(str, list)", "Position in a comma list", .string),
            // Math
            f("ROUND", "ROUND(x[, d])", "Round", .math), f("TRUNCATE", "TRUNCATE(x, d)", "Truncate", .math), f("FLOOR", "FLOOR(x)", "Round down", .math),
            f("CEIL", "CEIL(x)", "Round up", .math), f("ABS", "ABS(x)", "Absolute value", .math), f("MOD", "MOD(n, m)", "Remainder", .math),
            f("POW", "POW(x, y)", "Power", .math), f("SQRT", "SQRT(x)", "Square root", .math), f("LOG", "LOG([b,] x)", "Logarithm", .math),
            f("RAND", "RAND([seed])", "Random value in [0, 1)", .math), f("GREATEST", "GREATEST(a, b, …)", "Largest argument", .math),
            f("LEAST", "LEAST(a, b, …)", "Smallest argument", .math),
            // Conditional
            f("IF", "IF(cond, then, else)", "Conditional value", .conditional), f("IFNULL", "IFNULL(expr, alt)", "Replace NULL", .conditional),
            f("NULLIF", "NULLIF(a, b)", "NULL when equal", .conditional), f("COALESCE", "COALESCE(a, b, …)", "First non-NULL", .conditional),
            f("CAST", "CAST(expr AS type)", "Convert type", .conditional), f("CONVERT", "CONVERT(expr USING charset)", "Convert character set", .conditional),
            // JSON
            f("JSON_EXTRACT", "JSON_EXTRACT(doc, path)", "Extract with a JSON path ('$.a')", .json),
            f("JSON_UNQUOTE", "JSON_UNQUOTE(json)", "Unquote a JSON string", .json),
            f("JSON_OBJECT", "JSON_OBJECT(k1, v1, …)", "Build an object", .json), f("JSON_ARRAY", "JSON_ARRAY(v1, …)", "Build an array", .json),
            f("JSON_CONTAINS", "JSON_CONTAINS(target, candidate[, path])", "Containment test", .json),
            f("JSON_LENGTH", "JSON_LENGTH(doc[, path])", "Number of elements", .json), f("JSON_KEYS", "JSON_KEYS(doc[, path])", "Object keys", .json),
            f("JSON_SET", "JSON_SET(doc, path, val, …)", "Insert or replace values", .json),
            f("JSON_TABLE", "JSON_TABLE(doc, path COLUMNS (…)) AS jt", "JSON as a table", .json),
            f("JSON_VALID", "JSON_VALID(val)", "Is valid JSON", .json),
            // Information
            f("DATABASE", "DATABASE()", "Current schema", .information), f("USER", "USER()", "Session user", .information),
            f("CURRENT_USER", "CURRENT_USER()", "Authenticated account", .information), f("VERSION", "VERSION()", "Server version", .information),
            f("CONNECTION_ID", "CONNECTION_ID()", "Thread id of this connection", .information),
            f("LAST_INSERT_ID", "LAST_INSERT_ID()", "Last AUTO_INCREMENT value", .information),
            f("ROW_COUNT", "ROW_COUNT()", "Rows changed by the previous statement", .information),
            f("FOUND_ROWS", "FOUND_ROWS()", "Rows of the previous SQL_CALC_FOUND_ROWS query", .information),
            f("UUID", "UUID()", "New UUID", .information), f("INET_ATON", "INET_ATON(ip)", "IPv4 to number", .information),
            f("INET_NTOA", "INET_NTOA(n)", "Number to IPv4", .information),
            // Encryption / hashing
            f("SHA2", "SHA2(str, bits)", "SHA-2 hash", .encryption), f("CRC32", "CRC32(str)", "CRC-32 checksum", .encryption),
            f("TO_BASE64", "TO_BASE64(str)", "Base64 encode", .encryption), f("FROM_BASE64", "FROM_BASE64(str)", "Base64 decode", .encryption),
            // Spatial
            f("ST_AsText", "ST_AsText(geom)", "Geometry as WKT", .spatial), f("ST_GeomFromText", "ST_GeomFromText(wkt[, srid])", "Geometry from WKT", .spatial),
            f("ST_Distance_Sphere", "ST_Distance_Sphere(p1, p2)", "Distance on a sphere in meters", .spatial),
        ]
    }()

    public static let names: Set<String> = Set(all.map { $0.name.uppercased() })
}
