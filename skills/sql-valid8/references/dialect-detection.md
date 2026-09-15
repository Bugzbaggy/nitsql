# Dialect Detection Reference

Detailed syntax markers, connection strings, and driver imports for identifying SQL dialects.

## Dialect Detection

Before applying any rules, detect the target RDBMS dialect. Use these signals in priority order:

### 1. Explicit User Declaration
If the user states the dialect, use it. No further detection needed.

### 2. File Extensions and Naming Conventions

| Signal | Dialect |
|--------|---------|
| `.sql` files with `tsql` or `mssql` in path/name | MSSQL |
| `.sql` files with `pg`, `postgres`, or `pgsql` in path/name | PostgreSQL |
| `.sql` files with `ora` or `plsql` in path/name | Oracle |
| `.sql` files with `mysql` or `mariadb` in path/name | MySQL |
| `.pgsql` extension | PostgreSQL |
| `.plsql`, `.pks`, `.pkb` extensions | Oracle |

### 3. Syntax Markers

**MSSQL (T-SQL):**
- `SET NOCOUNT ON`, `SET XACT_ABORT ON`
- `@@IDENTITY`, `@@ROWCOUNT`, `@@ERROR`, `@@TRANCOUNT`
- `sp_executesql`, `sp_help`, `sp_who`
- `BEGIN TRY...END TRY`, `BEGIN CATCH...END CATCH`
- `NVARCHAR`, `DATETIME2`, `UNIQUEIDENTIFIER`
- `TOP` without parentheses in older code, `TOP(n)` in modern code
- `WITH (NOLOCK)`, `WITH (ROWLOCK)`
- Square bracket quoting: `[schema].[table].[column]`
- `CROSS APPLY`, `OUTER APPLY`
- `MERGE...WHEN MATCHED...WHEN NOT MATCHED`
- `OUTPUT INSERTED.*`, `OUTPUT DELETED.*`

**PostgreSQL (PL/pgSQL):**
- `DO $$...$$`, dollar-quoting `$function$...$function$`
- `::` type cast operator (e.g., `value::integer`)
- `RETURNING` clause on INSERT/UPDATE/DELETE
- `SERIAL`, `BIGSERIAL`, `GENERATED ALWAYS AS IDENTITY`
- `RAISE NOTICE`, `RAISE EXCEPTION`
- `CREATE OR REPLACE FUNCTION...RETURNS...LANGUAGE plpgsql`
- `ILIKE` (case-insensitive LIKE)
- `JSONB`, `ARRAY[]`, `HSTORE`
- `ON CONFLICT DO UPDATE` (upsert)
- `EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)`
- `LISTEN`, `NOTIFY`
- `\d`, `\dt`, `\di` (psql meta-commands in scripts)

**Oracle (PL/SQL):**
- `DECLARE...BEGIN...EXCEPTION...END;` block structure
- Trailing `/` to execute PL/SQL blocks
- `DBMS_OUTPUT.PUT_LINE`, `DBMS_LOB`, `UTL_FILE`
- `SYSDATE`, `SYSTIMESTAMP`, `DUAL`
- `:param` bind variable syntax
- `NVL()`, `NVL2()`, `DECODE()`
- `ROWNUM`, `ROWID`
- `CREATE OR REPLACE PACKAGE`, `CREATE OR REPLACE PACKAGE BODY`
- `BULK COLLECT`, `FORALL`
- `CONNECT BY`, `START WITH` (hierarchical queries)
- `EXECUTE IMMEDIATE`
- `PRAGMA AUTONOMOUS_TRANSACTION`

**MySQL:**
- `DELIMITER //` or `DELIMITER $$`
- `ENGINE=InnoDB`, `ENGINE=MyISAM`
- Backtick quoting: `` `database`.`table`.`column` ``
- `AUTO_INCREMENT`
- `LIMIT offset, count` (two-argument LIMIT)
- `ON DUPLICATE KEY UPDATE`
- `DECLARE...HANDLER FOR SQLEXCEPTION`
- `GROUP_CONCAT()`
- `SHOW CREATE TABLE`, `SHOW PROCESSLIST`, `SHOW ENGINE INNODB STATUS`
- `@@global.`, `@@session.` system variables
- `IFNULL()`, `IF()` function
- `STRAIGHT_JOIN`, `SQL_NO_CACHE`

### 4. Connection Strings

| Pattern | Dialect |
|---------|---------|
| `Server=...;Database=...;` or `Data Source=...;Initial Catalog=...;` | MSSQL |
| `mssql+pyodbc://`, `jdbc:sqlserver://` | MSSQL |
| `postgresql://`, `postgres://`, `jdbc:postgresql://` | PostgreSQL |
| `host=... dbname=... user=...` (libpq format) | PostgreSQL |
| `oracle://`, `oracle+cx_oracle://`, `jdbc:oracle:thin:@` | Oracle |
| `(DESCRIPTION=(ADDRESS=...)(CONNECT_DATA=...))` (TNS) | Oracle |
| `mysql://`, `mysql+pymysql://`, `jdbc:mysql://` | MySQL |

### 5. Framework and Driver Imports

| Import / Package | Dialect |
|-----------------|---------|
| `pyodbc`, `pymssql`, `Microsoft.Data.SqlClient`, `tedious`, `mssql` (Node) | MSSQL |
| `psycopg2`, `psycopg`, `asyncpg`, `Npgsql`, `pg` (Node), `node-postgres` | PostgreSQL |
| `cx_Oracle`, `oracledb`, `Oracle.ManagedDataAccess`, `oracle` (Node) | Oracle |
| `mysql-connector-python`, `pymysql`, `MySqlConnector` (.NET), `mysql2` (Node) | MySQL |

### 6. Ambiguous or Unknown Dialect
If dialect cannot be determined, **ask the user**. Do not guess. State: "I detected SQL code but cannot determine the target RDBMS. Which dialect should I use: MSSQL, PostgreSQL, Oracle, or MySQL?"

