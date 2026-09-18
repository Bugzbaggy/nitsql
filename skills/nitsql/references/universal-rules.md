## Universal Rules Quick Reference

Rules that apply across all five dialects (MSSQL, PostgreSQL, Oracle, MySQL, SQLite). Dialect-specific syntax noted where it varies. SQLite differs more than the other four in several structural ways (no stored procedures, limited `ALTER TABLE`, dynamic typing via type affinity) — where a rule genuinely does not apply to SQLite, its row says so explicitly (`N/A`) rather than being omitted.

### 1. Query Performance (CRITICAL) -- `query-`

**`query-avoid-select-star`** -- All dialects. Never use `SELECT *` in production code. Always list columns explicitly.
- Prevents breakage when columns are added/removed
- Reduces network transfer and memory usage
- Enables covering index optimization

**`query-parameterize`** -- All dialects. Always use parameterized queries. Never concatenate user input into SQL strings.
| Dialect | Parameter Syntax | Example |
|---------|-----------------|---------|
| MSSQL | `@param` with `sp_executesql` | `WHERE id = @id` |
| PostgreSQL | `$1`, `$2` (positional) or `%(name)s` (psycopg2) | `WHERE id = $1` |
| Oracle | `:param` (named bind) | `WHERE id = :id` |
| MySQL | `?` (positional) or `%s` (connector) | `WHERE id = ?` |
| SQLite | `?` / `?NNN` (positional) or `:name` / `@name` / `$name` (named) | `WHERE id = ?` or `WHERE id = :id` |

**`query-sargable`** -- All dialects. Never wrap indexed columns in functions inside WHERE clauses.
```
-- BAD (all dialects): optimizer cannot use index
WHERE YEAR(order_date) = 2025
WHERE UPPER(last_name) = 'SMITH'
WHERE amount + tax > 100

-- GOOD (all dialects): index-friendly
WHERE order_date >= '2025-01-01' AND order_date < '2026-01-01'
WHERE last_name = 'SMITH'  -- use case-insensitive collation or functional index
WHERE amount > 100 - tax
```

**`query-exists-vs-count`** -- All dialects. Use `EXISTS` instead of `COUNT(*) > 0` for existence checks. EXISTS short-circuits after finding the first row.
```
-- BAD
IF (SELECT COUNT(*) FROM orders WHERE customer_id = @id) > 0

-- GOOD
IF EXISTS (SELECT 1 FROM orders WHERE customer_id = @id)
```

**`query-avoid-cursors`** -- All dialects. Replace row-by-row cursor processing with set-based operations. Cursors are 10-100x slower than equivalent set-based SQL.

**`query-batch-operations`** -- All dialects. Batch large INSERT/UPDATE/DELETE operations to avoid lock escalation, excessive logging, and timeout.
| Dialect | Batch Technique |
|---------|----------------|
| MSSQL | `DELETE TOP(5000)` in a loop, or `OFFSET-FETCH` batching |
| PostgreSQL | `DELETE ... WHERE ctid IN (SELECT ctid ... LIMIT 5000)` |
| Oracle | `BULK COLLECT...FORALL` with `LIMIT` clause |
| MySQL | `DELETE ... LIMIT 5000` in a loop |
| SQLite | `DELETE FROM t WHERE rowid IN (SELECT rowid FROM t WHERE ... LIMIT 5000)` in a loop |

Note: standard SQLite builds do **not** support `DELETE ... LIMIT` directly — that syntax requires the `SQLITE_ENABLE_UPDATE_DELETE_LIMIT` compile-time option, which most distributed builds (including Python's bundled `sqlite3` and most system packages) do not enable. Use the `rowid IN (SELECT ... LIMIT n)` form, which works everywhere. There is also no `TRUNCATE TABLE` in SQLite; `DELETE FROM t` with no `WHERE` clause is automatically optimized into a fast "truncate" path that skips row-by-row logging, so a bare unconditional `DELETE` does not need the batching workaround.

**`query-limit-results`** -- All dialects. Always limit result sets for user-facing queries.
| Dialect | Syntax |
|---------|--------|
| MSSQL | `TOP(n)` or `OFFSET x ROWS FETCH NEXT n ROWS ONLY` |
| PostgreSQL | `LIMIT n OFFSET x` or `FETCH FIRST n ROWS ONLY` |
| Oracle | `FETCH FIRST n ROWS ONLY` (12c+) or `ROWNUM <= n` (legacy) |
| MySQL | `LIMIT n OFFSET x` or `LIMIT x, n` |
| SQLite | `LIMIT n OFFSET x` or `LIMIT x, n` |

**`query-avoid-implicit-conversion`** -- All dialects. Match parameter data types to column data types exactly. Implicit conversions prevent index usage and cause full table scans.
- SQLite caveat: columns are dynamically typed (type affinity, not a strict type), so SQLite will silently coerce values on comparison far more often than MSSQL/PostgreSQL/Oracle/MySQL and often still uses the index. The performance risk is smaller, but it is not zero — a `TEXT` value compared against an `INTEGER`-affinity column can still skip index usage if affinity conversion fails partway. Bind parameters with the type your application actually intends rather than relying on affinity to paper over the mismatch.

**`query-avoid-leading-wildcard`** -- All dialects. Avoid `LIKE '%value'` patterns. Use full-text search or reverse-index strategies instead.

**`query-union-all-vs-union`** -- All dialects. Use `UNION ALL` instead of `UNION` when duplicate elimination is not required. `UNION` forces a sort/distinct operation.
```sql
-- BAD: UNION removes duplicates even when source data is already distinct
SELECT order_id FROM active_orders
UNION
SELECT order_id FROM archived_orders;

-- GOOD: UNION ALL when you know there are no duplicates, or duplicates are acceptable
SELECT order_id FROM active_orders
UNION ALL
SELECT order_id FROM archived_orders;
```

**`query-avoid-nolock` (MSSQL)** -- Do not use `WITH (NOLOCK)` / `READ UNCOMMITTED` as a blanket performance fix. It reads uncommitted (dirty) data, phantom rows, and can return incorrect results. Only acceptable for known-safe reporting queries where approximate counts are fine.
```sql
-- BAD: dirty reads, phantom rows, incorrect results possible
SELECT * FROM dbo.Orders WITH (NOLOCK) WHERE Status = 'Pending';

-- GOOD: use READ COMMITTED SNAPSHOT isolation instead (database-level setting)
ALTER DATABASE [YourDB] SET READ_COMMITTED_SNAPSHOT ON;
-- Then normal queries use row-versioning without dirty read risk
SELECT OrderID, Status FROM dbo.Orders WHERE Status = 'Pending';
```

**`query-avoid-or-antipattern`** -- All dialects. Multiple `OR` conditions on different columns prevent index usage. Rewrite as `UNION ALL` or use separate indexed queries.
```sql
-- BAD: optimizer often can't use indexes efficiently with OR across columns
SELECT * FROM orders WHERE customer_id = 100 OR order_date = '2025-01-01';

-- GOOD: two indexed lookups combined
SELECT order_id, customer_id, order_date FROM orders WHERE customer_id = 100
UNION ALL
SELECT order_id, customer_id, order_date FROM orders WHERE order_date = '2025-01-01' AND customer_id != 100;
```

### 2. Indexing Strategy (CRITICAL) -- `index-`

**`index-cover-queries`** -- Create covering indexes to eliminate table/heap lookups for frequent queries.
| Dialect | Covering Index Support |
|---------|----------------------|
| MSSQL | `CREATE INDEX ... INCLUDE (col1, col2)` -- full support |
| PostgreSQL | `CREATE INDEX ... INCLUDE (col1, col2)` -- PostgreSQL 11+ |
| Oracle | No INCLUDE syntax. Use composite index with all needed columns as key columns |
| MySQL | No INCLUDE syntax. Use composite index with all needed columns as key columns |
| SQLite | No INCLUDE syntax. Use composite index with all needed columns as key columns; `EXPLAIN QUERY PLAN` reports `USING COVERING INDEX` when it succeeds |

**`index-key-order`** -- All dialects. Order index key columns by: (1) equality predicates first, (2) then range predicates, (3) most selective columns first within each group.

**`index-unused-indexes`** -- All dialects. Identify and drop indexes with zero or near-zero reads. They slow down writes with no benefit.
| Dialect | How to Find Unused Indexes |
|---------|--------------------------|
| MSSQL | `sys.dm_db_index_usage_stats` -- `user_seeks + user_scans + user_lookups = 0` |
| PostgreSQL | `pg_stat_user_indexes` -- `idx_scan = 0` |
| Oracle | `V$OBJECT_USAGE` after `ALTER INDEX ... MONITORING USAGE` or `DBA_INDEX_USAGE` (19c+) |
| MySQL | `performance_schema.table_io_waits_summary_by_index_usage` -- `COUNT_STAR = 0` |
| SQLite | N/A -- no index-usage counters exist. SQLite tracks no runtime DMVs at all; the closest proxy is manually reviewing `EXPLAIN QUERY PLAN` for every query an index was created for and confirming at least one still uses it |

**`index-missing-indexes`** -- All dialects. Use built-in advisors to find missing indexes.
| Dialect | Missing Index Source |
|---------|--------------------|
| MSSQL | `sys.dm_db_missing_index_details`, `sys.dm_db_missing_index_group_stats` |
| PostgreSQL | `pg_stat_user_tables` -- high `seq_scan` count with low `idx_scan` |
| Oracle | `DBA_ADVISOR_RECOMMENDATIONS` from SQL Tuning Advisor |
| MySQL | `EXPLAIN` output showing `type: ALL` or `type: index` on large tables |
| SQLite | No advisor. `EXPLAIN QUERY PLAN` showing `SCAN table_name` (instead of `SEARCH`) on a table above trivial size |

**`index-concurrent-creation` (PostgreSQL)** -- Always use `CREATE INDEX CONCURRENTLY` for production tables. Regular `CREATE INDEX` acquires a write lock for the entire duration, blocking INSERTs/UPDATEs/DELETEs.
```sql
-- BAD: blocks writes on the table for the entire build duration
CREATE INDEX ix_orders_date ON public.orders (order_date);

-- GOOD: allows concurrent writes (takes longer, but no downtime)
CREATE INDEX CONCURRENTLY ix_orders_date ON public.orders (order_date);
```
Note: `CONCURRENTLY` cannot be used inside a transaction block. If it fails partway, the index is left in an `INVALID` state — check `pg_index.indisvalid` and retry if needed.

**`index-partial-and-filtered`** -- Use partial/filtered indexes for queries on subsets of data.
| Dialect | Support |
|---------|---------|
| MSSQL | `CREATE INDEX ... WHERE status = 'active'` (filtered index) |
| PostgreSQL | `CREATE INDEX ... WHERE status = 'active'` (partial index) |
| Oracle | Function-based index returning NULL for excluded rows (simulates partial index) |
| MySQL | Not supported natively. Use generated columns with indexes as workaround |
| SQLite | `CREATE INDEX ... WHERE status = 'active'` (partial index, native support since 3.8.0) |

**`index-statistics-maintenance`** -- All dialects. Keep statistics current for accurate query plan cost estimation.
| Dialect | Statistics Management |
|---------|---------------------|
| MSSQL | `AUTO_UPDATE_STATISTICS ON`, `UPDATE STATISTICS` for manual refresh |
| PostgreSQL | `autovacuum` handles `ANALYZE` automatically. Manual: `ANALYZE table_name` |
| Oracle | `DBMS_STATS.GATHER_TABLE_STATS` with appropriate `METHOD_OPT` |
| MySQL | `ANALYZE TABLE` or `innodb_stats_auto_recalc = ON` |
| SQLite | `ANALYZE` populates `sqlite_stat1`/`sqlite_stat4`; not run automatically -- schedule it manually or run `PRAGMA optimize` (3.18+) before closing each connection |

### 3. Security & Compliance (HIGH) -- `security-`

**`security-parameterize-queries`** -- All dialects. Use parameterized queries for ALL dynamic SQL. Never concatenate user input into SQL strings.
| Dialect | Secure Dynamic SQL |
|---------|-------------------|
| MSSQL | `sp_executesql @sql, N'@id INT', @id = @id` -- never `EXEC(@sql)` with concatenation |
| PostgreSQL | `EXECUTE format('SELECT ... WHERE id = $1') USING var_id` or `EXECUTE ... USING` |
| Oracle | `EXECUTE IMMEDIATE sql USING bind_var` -- never `EXECUTE IMMEDIATE 'SELECT...' \|\| input` |
| MySQL | Prepared statements: `PREPARE stmt FROM ?; EXECUTE stmt USING @var` |
| SQLite | No server-side dynamic SQL construct (no stored procedures). Parameterize at the driver: `?`/`:name` placeholders bound via the client API -- never build SQL text via string concatenation before passing it to `execute()` |

**`security-least-privilege`** -- All dialects. Grant minimum necessary permissions. Never give application accounts admin/owner roles.
| Dialect | Anti-Pattern | Correct Pattern |
|---------|-------------|-----------------|
| MSSQL | `ALTER ROLE db_owner ADD MEMBER app_user` | `GRANT SELECT, INSERT, UPDATE ON SCHEMA::app TO app_role` |
| PostgreSQL | `GRANT ALL ON ALL TABLES TO app_user` | `GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA app TO app_role` |
| Oracle | `GRANT DBA TO app_user` | `GRANT SELECT, INSERT, UPDATE ON schema.table TO app_role` |
| MySQL | `GRANT ALL PRIVILEGES ON *.* TO 'app'@'%'` | `GRANT SELECT, INSERT, UPDATE ON db.* TO 'app'@'app-host'` |
| SQLite | N/A -- no `GRANT`/`REVOKE` or user/role system | OS file permissions on the `.db` file; open read-only app connections with `PRAGMA query_only=ON` or the driver's read-only open flag |

**`security-avoid-admin-accounts`** -- All dialects. Never use superuser/admin accounts for application access.
| Dialect | Forbidden | Use Instead |
|---------|-----------|-------------|
| MSSQL | `sa`, `dbo` | Dedicated application login with custom role |
| PostgreSQL | `postgres` superuser | Dedicated role with `NOINHERIT`, `NOSUPERUSER` |
| Oracle | `SYS`, `SYSTEM` | Dedicated schema user with explicit grants |
| MySQL | `root` | Dedicated user with specific host restrictions |
| SQLite | N/A -- no admin account concept exists | Never run the app as the OS user/process with unrestricted filesystem access to the `.db` file; scope file permissions to the app's own service account |

**`security-encrypt-connections`** -- All dialects. Enforce encrypted connections in production.
| Dialect | How |
|---------|-----|
| MSSQL | `Encrypt=True;TrustServerCertificate=False` in connection string, TLS 1.2+ |
| PostgreSQL | `sslmode=verify-full` in connection string, server `ssl = on` in `postgresql.conf` |
| Oracle | Native Network Encryption or TLS in `sqlnet.ora`: `SQLNET.ENCRYPTION_SERVER = REQUIRED` |
| MySQL | `--require-secure-transport`, `ssl-mode=VERIFY_IDENTITY` in client |
| SQLite | N/A -- SQLite is an embedded, in-process library with no network protocol to encrypt. If the `.db` file is accessed over a network filesystem, secure the transport at the OS/filesystem layer instead |

**`security-row-level-security`** -- Implement RLS for multi-tenant data isolation.
| Dialect | Mechanism |
|---------|-----------|
| MSSQL | Security policy with predicate function using `SESSION_CONTEXT(N'tenant_id')` |
| PostgreSQL | `CREATE POLICY ... USING (tenant_id = current_setting('app.tenant_id'))` with `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` |
| Oracle | Virtual Private Database (VPD) via `DBMS_RLS.ADD_POLICY` |
| MySQL | No native RLS. Implement via views with `WHERE tenant_id = @current_tenant` or application-layer filtering |
| SQLite | No native RLS. Implement via views with `WHERE tenant_id = ?` or application-layer filtering (same fallback as MySQL) |

**`security-data-encryption-at-rest`** -- All dialects. Enable transparent encryption for data at rest.
| Dialect | Feature |
|---------|---------|
| MSSQL | Transparent Data Encryption (TDE), Always Encrypted |
| PostgreSQL | `pgcrypto` extension, filesystem-level encryption, or cloud provider encryption |
| Oracle | TDE (tablespace or column-level), Oracle Wallet/Key Vault |
| MySQL | InnoDB tablespace encryption: `ALTER TABLE ... ENCRYPTION='Y'` |
| SQLite | No built-in encryption-at-rest. Requires a third-party extension: SQLCipher (open source, transparent AES-256) or the SQLite Encryption Extension/SEE (commercial); otherwise rely on filesystem/disk-level encryption |

**`security-pg-search-path`** -- PostgreSQL only. Set `search_path` explicitly in `SECURITY DEFINER` functions to prevent schema hijacking attacks.
```sql
-- BAD: attacker can create objects in public schema that shadow intended objects
CREATE FUNCTION get_data() RETURNS TABLE(id INT) SECURITY DEFINER AS $$
    SELECT id FROM users;
$$ LANGUAGE sql;

-- GOOD: explicit search_path prevents schema hijacking
CREATE FUNCTION get_data() RETURNS TABLE(id INT) SECURITY DEFINER
SET search_path = app, pg_temp AS $$
    SELECT id FROM users;
$$ LANGUAGE sql;
```

**`security-oracle-bind-variables`** -- Oracle only. Always use bind variables in application SQL. Non-bound literals cause hard parses for every unique statement, filling the shared pool/library cache and causing `ORA-04031` errors under load.
```sql
-- BAD: each unique customer_id value creates a new cursor in the library cache
EXECUTE IMMEDIATE 'SELECT name FROM customers WHERE id = ' || v_id;

-- GOOD: one cursor parsed once, reused for all executions
EXECUTE IMMEDIATE 'SELECT name FROM customers WHERE id = :1' USING v_id;
```

**`security-audit-logging`** -- All dialects. Enable audit logging for compliance.
| Dialect | Feature |
|---------|---------|
| MSSQL | SQL Server Audit, Extended Events |
| PostgreSQL | `pgaudit` extension |
| Oracle | Unified Auditing: `CREATE AUDIT POLICY` |
| MySQL | `audit_log` plugin (Enterprise) or `general_log` (development only) |
| SQLite | No built-in audit log. Implement with `AFTER INSERT/UPDATE/DELETE` triggers writing to an application-defined audit table, or log at the application/driver layer (e.g., a trace callback) |

### 4. Connection Management (HIGH) -- `connection-`

**`connection-pooling`** -- All dialects. Always use connection pooling. Never open/close connections per query.
| Dialect | Pooling Mechanism |
|---------|------------------|
| MSSQL | ADO.NET: `Pooling=True;Min Pool Size=5;Max Pool Size=100`, SQLAlchemy: `pool_size=10`, Node: `tedious` ConnectionPool |
| PostgreSQL | `pgbouncer` (external), psycopg2: connection pool class, SQLAlchemy: `pool_size=10`, Node: `pg.Pool` |
| Oracle | Oracle Connection Pool: `oracledb.create_pool(min=5, max=20)`, UCP for Java |
| MySQL | `mysql-connector-python`: `pooling={'pool_size': 10}`, Node: `mysql2.createPool()` |
| SQLite | Different model, not N/A: connections are cheap (in-process, no network handshake), so a large pool has little benefit. Prefer a single writer connection plus a small pool (1-4) of reader connections, and require `PRAGMA journal_mode=WAL` -- without WAL, concurrent connections mostly serialize anyway |

**`connection-retry-logic`** -- All dialects. Implement exponential backoff for transient errors.
| Dialect | Transient Error Codes |
|---------|----------------------|
| MSSQL | 4060, 40197, 40501, 40613, 49918, 49919, 49920, 1205 (deadlock) |
| PostgreSQL | Class 08 (connection exceptions), 40001 (serialization failure), 40P01 (deadlock) |
| Oracle | ORA-03113 (end-of-file), ORA-03114 (not connected), ORA-12541 (no listener), ORA-00060 (deadlock) |
| MySQL | 1205 (lock wait timeout), 1213 (deadlock), 2003 (can't connect), 2006 (server gone away) |
| SQLite | `SQLITE_BUSY` (5) -- another connection holds the write lock; `SQLITE_LOCKED` (6) -- lock conflict within the same connection. There is no deadlock code: retry with `busy_timeout` and/or application-level exponential backoff |

**`connection-close-dispose`** -- All dialects. Always release connections back to the pool using `using`, `try-finally`, context managers, or equivalent resource management.

**`connection-async`** -- All dialects. Use async/await for database calls in web applications to avoid thread blocking.
| Dialect | Async Driver |
|---------|-------------|
| MSSQL | `aioodbc`, async `tedious` (Node) |
| PostgreSQL | `asyncpg`, `psycopg` (async mode), `pg` with async (Node) |
| Oracle | `oracledb` thin mode (async), `cx_Oracle` with `asyncio` |
| MySQL | `aiomysql`, `mysql2` promise API (Node) |
| SQLite | N/A -- SQLite itself is a synchronous, in-process library with no async I/O mode. "Async" wrappers (e.g., Python's `aiosqlite`) run the synchronous calls on a background thread rather than performing true async I/O; `better-sqlite3` for Node.js is deliberately synchronous by design, not async at all |

**`connection-timeouts`** -- All dialects. Set appropriate connection and command timeouts. Never use infinite timeouts in production.
| Dialect | Connection Timeout | Command Timeout |
|---------|-------------------|-----------------|
| MSSQL | `Connect Timeout=30` in connection string | `CommandTimeout = 30` (seconds) on SqlCommand |
| PostgreSQL | `connect_timeout=10` in connection string | `statement_timeout = '30s'` per session or in postgresql.conf |
| Oracle | `CONNECT_TIMEOUT=10` in sqlnet.ora or `(CONNECT_TIMEOUT=10)` in TNS | `ALTER SESSION SET NLS_TIMEOUT = 30` or `call_timeout` in oracledb driver |
| MySQL | `connect_timeout=10` in my.cnf | `max_execution_time=30000` (ms) hint or `wait_timeout` for idle connections |
| SQLite | N/A -- no network connection to time out (in-process); closest equivalent is `PRAGMA busy_timeout=5000`, how long to retry before returning `SQLITE_BUSY` on a lock conflict | No separate command timeout mechanism -- a running statement must be cancelled from application code via the driver's interrupt API (e.g., `sqlite3_interrupt()`) |

**`connection-read-replicas`** -- All dialects. Route read-only queries to replicas to reduce primary load.
| Dialect | Configuration |
|---------|--------------|
| MSSQL | `ApplicationIntent=ReadOnly` in connection string for AG routing |
| PostgreSQL | Separate connection string to replica, or `target_session_attrs=prefer-standby` |
| Oracle | `(LOAD_BALANCE=ON)` in TNS with Active Data Guard |
| MySQL | MySQL Router, ProxySQL, or application-level read/write splitting |
| SQLite | No native replication. Third-party tools such as Litestream (continuous streaming backup, not a live read replica) or rqlite/dqlite (Raft-replicated wrappers) are needed to approximate this; plain SQLite has a single file with no replica topology |

### 5. Procedural Code Patterns (MEDIUM-HIGH) -- `proc-`

**`proc-error-handling`** -- All dialects. All procedural code must have structured error handling.
| Dialect | Pattern |
|---------|---------|
| MSSQL | `BEGIN TRY...END TRY BEGIN CATCH...END CATCH` with `THROW` or `RAISERROR` |
| PostgreSQL | `BEGIN...EXCEPTION WHEN ... THEN...END` inside PL/pgSQL functions |
| Oracle | `BEGIN...EXCEPTION WHEN ... THEN...END` inside PL/SQL blocks |
| MySQL | `DECLARE ... HANDLER FOR SQLEXCEPTION BEGIN...END` |
| SQLite | N/A -- no stored procedures, functions, or procedural blocks exist. All error handling happens in application code around each statement (catch the driver's exception class, e.g. `sqlite3.IntegrityError` / `sqlite3.OperationalError` in Python) |

**`proc-transaction-handling`** -- All dialects. Wrap multi-statement operations in explicit transactions. Always pair COMMIT with error-path ROLLBACK.
| Dialect | Transaction Pattern |
|---------|-------------------|
| MSSQL | `BEGIN TRANSACTION; ...TRY/CATCH... COMMIT/ROLLBACK; SET XACT_ABORT ON` |
| PostgreSQL | `BEGIN; ...EXCEPTION path ROLLBACK... COMMIT;` or savepoints |
| Oracle | Implicit transaction start. `COMMIT;` or `ROLLBACK;` explicitly. Use `SAVEPOINT` for partial rollback |
| MySQL | `START TRANSACTION; ... COMMIT;` or `ROLLBACK;` -- ensure `autocommit=0` for multi-statement |
| SQLite | `BEGIN [DEFERRED\|IMMEDIATE\|EXCLUSIVE]; ... COMMIT;` or `ROLLBACK;`. Plain `BEGIN` (DEFERRED) does not take the write lock until the first write statement, which means a transaction can start successfully and then fail with `SQLITE_BUSY` partway through -- use `BEGIN IMMEDIATE` when the transaction is going to write, so the lock (and any busy-timeout retry) happens up front |

**`proc-set-based-over-row-by-row`** -- All dialects. Always prefer set-based operations over loops/cursors. If a cursor is unavoidable, use the most efficient cursor type available:
| Dialect | If Cursor Required |
|---------|-------------------|
| MSSQL | `FAST_FORWARD` (read-only, forward-only) cursor |
| PostgreSQL | `DECLARE ... CURSOR FOR ...` with `FETCH` in batches |
| Oracle | `BULK COLLECT ... LIMIT 1000` with `FORALL` for DML |
| MySQL | `DECLARE ... CURSOR FOR ...` with `FETCH` |
| SQLite | N/A -- there is no server-side/declared cursor construct to choose a type for. Every client driver call already returns a forward-only, read-only result iterator (e.g., a Python DB-API `Cursor`); process it incrementally rather than materializing the full result set, and use `executemany()`/an explicit transaction for batched writes |

**`proc-avoid-dynamic-sql-when-possible`** -- All dialects. Use static SQL whenever possible. Dynamic SQL introduces injection risk, prevents compile-time validation, and complicates plan caching.

**`proc-schema-qualify`** -- All dialects. Always qualify object references with schema/owner name.
| Dialect | Example |
|---------|---------|
| MSSQL | `dbo.orders`, `sales.customers` |
| PostgreSQL | `public.orders`, `app.customers` |
| Oracle | `hr.employees`, `app.orders` |
| MySQL | `mydb.orders` (database-qualified) |
| SQLite | Not user/owner-based like the other four. The default database is always named `main`; additional database files can be attached and referenced as `schema.object` via `ATTACH DATABASE 'other.db' AS reporting`, e.g. `reporting.orders` |

### 6. Static Analysis (MEDIUM-HIGH) -- `SA****`

Static analysis rules applicable across dialects. Originally from SSDT Code Analysis for MSSQL, these principles apply universally:

| Rule ID | Description | Dialects | Severity |
|---------|-------------|----------|----------|
| **SA0001** | `SELECT *` in production queries | All | HIGH |
| **SA0004** | IN predicate on non-indexed columns | All | HIGH |
| **SA0005** | LIKE patterns with leading wildcard `'%value'` | All | HIGH |
| **SA0006** | Column reference not isolated in comparison (non-SARGable) | All | MEDIUM |
| **SA0007** | Nullable column used without NULL handling | All | MEDIUM |
| **SA0008** | Using non-scoped identity function | MSSQL | MEDIUM |
| **SA0009** | VARCHAR/CHAR with unnecessarily small size | All except SQLite† | LOW |
| **SA0010** | Deprecated join syntax | MSSQL | MEDIUM |
| **SA0011** | Special characters in object names | All | LOW |
| **SA0012** | Reserved words as identifiers | All | MEDIUM |
| **SA0014** | Implicit type conversion in predicate | All‡ | HIGH |
| **SA0015** | Non-deterministic function in WHERE clause | All | MEDIUM |
| **SA0016** | Problematic naming prefix (`sp_` in MSSQL) | MSSQL | MEDIUM |

† SQLite parses `VARCHAR(n)`/`CHAR(n)` but never enforces the length (type affinity only) -- an undersized declaration is misleading rather than a real sizing problem, so this rule doesn't carry the same weight there.
‡ On SQLite, "implicit type conversion" happens by design via type affinity rather than as a driver/engine quirk; see `query-avoid-implicit-conversion` above for how the risk differs.

### 7. Database Configuration (MEDIUM) -- `config-`

**`config-query-analysis-tools`** -- Each dialect has its own query analysis infrastructure. Enable and configure it.
| Dialect | Tool | Configuration |
|---------|------|--------------|
| MSSQL | Query Store | `ALTER DATABASE db SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, MAX_STORAGE_SIZE_MB = 1024, INTERVAL_LENGTH_MINUTES = 30, DATA_FLUSH_INTERVAL_SECONDS = 900)` |
| PostgreSQL | pg_stat_statements | `shared_preload_libraries = 'pg_stat_statements'` in `postgresql.conf`, then `CREATE EXTENSION pg_stat_statements` |
| Oracle | AWR + ASH | Enabled by default with Diagnostics Pack. `EXEC DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT;` for manual snapshots |
| MySQL | Performance Schema | `performance_schema = ON` in `my.cnf`. Enable `events_statements_summary_by_digest` |
| SQLite | None built-in | No query-store equivalent. Use `EXPLAIN QUERY PLAN` per query during development, and add application-level timing/logging (or a driver trace hook, e.g. Python's `sqlite3.Connection.set_trace_callback`) for production visibility |

**`config-memory`** -- Configure memory allocation per dialect.
| Dialect | Key Setting |
|---------|------------|
| MSSQL | `max server memory (MB)` -- set to total RAM minus OS needs (leave 4-8 GB for OS) |
| PostgreSQL | `shared_buffers` (25% of RAM), `effective_cache_size` (50-75% of RAM), `work_mem` (per-sort, start at 4-64 MB) |
| Oracle | `SGA_TARGET` (automatic), `PGA_AGGREGATE_TARGET` |
| MySQL | `innodb_buffer_pool_size` (70-80% of RAM), `innodb_log_file_size` |
| SQLite | `PRAGMA cache_size` (page cache; negative value = KiB) and `PRAGMA mmap_size` (memory-mapped I/O, bytes) per connection -- there is no separate server memory pool since SQLite runs in-process with the application |

**`config-parallelism`** -- Control parallel query execution.
| Dialect | Key Setting |
|---------|------------|
| MSSQL | `MAXDOP` -- set based on NUMA node CPU count. Cost Threshold for Parallelism: raise from default 5 to 25-50 |
| PostgreSQL | `max_parallel_workers_per_gather` (2-4), `parallel_tuple_cost`, `min_parallel_table_scan_size` |
| Oracle | `PARALLEL_DEGREE_POLICY = AUTO`, or hint `/*+ PARALLEL(t, 4) */` |
| MySQL | `innodb_parallel_read_threads` (MySQL 8.0.14+), limited parallel query support |
| SQLite | N/A -- a single query always executes on a single thread with no intra-query parallelism. Multiple connections can run concurrently (see `connection-pooling`), but that is concurrency across queries, not parallelism within one |

**`config-auto-maintenance`** -- Enable automatic maintenance tasks.
| Dialect | Tasks |
|---------|-------|
| MSSQL | `AUTO_UPDATE_STATISTICS ON`, `AUTO_CREATE_STATISTICS ON`, index rebuild/reorganize maintenance jobs |
| PostgreSQL | `autovacuum` for VACUUM and ANALYZE. Tune `autovacuum_vacuum_scale_factor` for large tables |
| Oracle | Auto Maintenance Windows: `DBMS_AUTO_TASK_ADMIN` controls optimizer stats, SQL tuning, segment advisor |
| MySQL | `innodb_stats_auto_recalc = ON`, `OPTIMIZE TABLE` for fragmented tables |
| SQLite | No background maintenance daemon. `PRAGMA auto_vacuum=INCREMENTAL` (set before first `CREATE TABLE`) reclaims free pages via periodic `PRAGMA incremental_vacuum(N)` calls; run `PRAGMA optimize` (3.18+) before closing each connection to refresh planner statistics cheaply |

**`config-logging-and-recovery`** -- Configure transaction logging and recovery.
| Dialect | Key Settings |
|---------|-------------|
| MSSQL | Recovery model (FULL for production), Accelerated Database Recovery (ADR) for instant rollback |
| PostgreSQL | `wal_level = replica`, `checkpoint_timeout`, `max_wal_size` |
| Oracle | Archive log mode for production, RMAN backup configuration |
| MySQL | `innodb_flush_log_at_trx_commit = 1` (durability), `sync_binlog = 1`, binary log for replication |
| SQLite | `PRAGMA journal_mode=WAL` (write-ahead log; enables concurrent readers during a write) and `PRAGMA synchronous` (`FULL` for maximum durability, `NORMAL` is safe and faster under WAL) -- there is no separate archive-log or binlog concept; the WAL file plus periodic checkpointing is the whole recovery mechanism |

### 8. Data Types & Naming (MEDIUM) -- `type-`, `naming-`

**`type-use-appropriate-types`** -- Use the correct data type for each dialect. Avoid overly large types.
| Purpose | MSSQL | PostgreSQL | Oracle | MySQL | SQLite |
|---------|-------|------------|--------|-------|--------|
| Auto-increment PK | `INT IDENTITY` or `BIGINT IDENTITY` | `GENERATED ALWAYS AS IDENTITY` or `SERIAL` | `GENERATED ALWAYS AS IDENTITY` (12c+) or sequence + trigger | `INT AUTO_INCREMENT` | `INTEGER PRIMARY KEY` (rowid alias -- do not add `AUTOINCREMENT` unless you specifically need non-reuse of deleted IDs) |
| UUID | `UNIQUEIDENTIFIER` | `UUID` with `gen_random_uuid()` | `RAW(16)` or `SYS_GUID()` | `BINARY(16)` or `CHAR(36)` | No native UUID type -- store as `TEXT` (36-char canonical form) or `BLOB` (16 bytes) |
| Timestamp | `DATETIME2(7)` | `TIMESTAMPTZ` | `TIMESTAMP WITH TIME ZONE` | `DATETIME(6)` or `TIMESTAMP(6)` | No native date/time type -- store as `TEXT` (ISO-8601, sorts correctly) or `INTEGER` (Unix epoch via `unixepoch()`) |
| Boolean | `BIT` | `BOOLEAN` | `NUMBER(1)` with CHECK constraint | `BOOLEAN` (alias for `TINYINT(1)`) | No native boolean type -- `INTEGER` storing 0/1 (the `BOOLEAN` keyword is accepted but maps to `NUMERIC` affinity, not a real boolean) |
| Large text | `NVARCHAR(MAX)` | `TEXT` | `CLOB` | `LONGTEXT` | `TEXT` (no separate small/large text type; length is never enforced) |
| JSON | `NVARCHAR(MAX)` with JSON functions | `JSONB` (preferred) or `JSON` | `JSON` (21c+) or `CLOB` with JSON functions | `JSON` | `TEXT` with `CHECK (json_valid(col))`, or `BLOB` storing JSONB (3.45+) for faster read-back |
| Money/Currency | `DECIMAL(19,4)` (not `MONEY`) | `NUMERIC(19,4)` | `NUMBER(19,4)` | `DECIMAL(19,4)` | No exact fixed-point type -- store integer minor units (e.g., cents) in `INTEGER`; avoid `REAL`, whose `NUMERIC` affinity does not guarantee exact decimal representation |

**`type-avoid-deprecated`** -- Do not use deprecated or legacy data types.
| Dialect | Deprecated | Use Instead |
|---------|-----------|-------------|
| MSSQL | `TEXT`, `NTEXT`, `IMAGE`, `MONEY` | `VARCHAR(MAX)`, `NVARCHAR(MAX)`, `VARBINARY(MAX)`, `DECIMAL(19,4)` |
| PostgreSQL | `SERIAL` (soft-deprecated) | `GENERATED ALWAYS AS IDENTITY` |
| Oracle | `LONG`, `LONG RAW` | `CLOB`, `BLOB` |
| MySQL | `FLOAT`/`DOUBLE` for money | `DECIMAL` for exact numeric |
| SQLite | N/A -- only five storage classes exist (`NULL`, `INTEGER`, `REAL`, `TEXT`, `BLOB`), nothing is deprecated | The trap runs the other way: `VARCHAR(n)`/`CHAR(n)`/`DECIMAL(p,s)` etc. are accepted as type names for compatibility but the length/precision is silently ignored (affinity only) -- prefer the five real storage class names so the DDL doesn't imply a constraint that isn't there |

**`type-mysql-utf8mb4`** -- MySQL only. Always use `utf8mb4` character set, never `utf8` (which is `utf8mb3` — only 3 bytes, cannot store emoji, CJK supplementary, or some Unicode symbols).
```sql
-- BAD: MySQL's 'utf8' is actually utf8mb3 (max 3 bytes per character)
CREATE TABLE users (name VARCHAR(100)) CHARACTER SET utf8;

-- GOOD: utf8mb4 is true UTF-8 (max 4 bytes per character)
CREATE TABLE users (name VARCHAR(100)) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Set database default
ALTER DATABASE mydb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
```

**`type-mysql-strict-mode`** -- MySQL only. Ensure `sql_mode` includes `STRICT_TRANS_TABLES` to prevent silent data truncation and invalid date insertion.
```sql
-- Check current mode
SELECT @@sql_mode;

-- Recommended (MySQL 8.0 default includes these):
SET GLOBAL sql_mode = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';
```

**`naming-consistent-conventions`** -- All dialects. Use consistent naming:
- Lowercase with underscores (`snake_case`) preferred for PostgreSQL and MySQL
- PascalCase or snake_case acceptable for MSSQL and Oracle
- `snake_case` is the prevailing convention for SQLite (it is typically embedded in Python/Node/C ecosystems that already use snake_case), though SQLite itself is permissive about identifier casing
- Avoid reserved words as identifiers in all dialects
- Avoid special characters (spaces, hyphens, dots) in object names
- Use meaningful, descriptive names (not `t1`, `col1`, `temp`)

### 9. Data Modeling (MEDIUM) -- `model-`

**`model-enforce-constraints`** -- All dialects. Always define PRIMARY KEY, FOREIGN KEY, UNIQUE, CHECK, and NOT NULL constraints. Constraints are the last line of defense for data integrity.
- SQLite caveats: foreign key enforcement is **OFF by default** and must be turned on every connection with `PRAGMA foreign_keys=ON` (it is not persisted like `journal_mode`) -- a schema with `REFERENCES` clauses but no such pragma enforces nothing. Also, constraints generally cannot be added to an existing table via `ALTER TABLE` (SQLite's `ALTER TABLE` only supports renaming/adding columns, and an added column can't carry a `NOT NULL` without a default); adding or changing a constraint on an existing table normally means the create-new/copy-data/drop-old/rename rebuild pattern.

**`model-temporal-tables`** -- Use system-versioned temporal tables for audit trails when available.
| Dialect | Support |
|---------|---------|
| MSSQL | `SYSTEM_VERSIONING = ON` with history table |
| PostgreSQL | `temporal_tables` extension or manual trigger-based approach |
| Oracle | Flashback Data Archive (Total Recall) |
| MySQL | Not natively supported. Use triggers or application-level audit tables |
| SQLite | Not natively supported. Use `AFTER UPDATE`/`AFTER DELETE` triggers to copy the prior row into a history table (same fallback as MySQL) |

**`model-partitioning`** -- Partition large tables (>10M rows or >10 GB) for manageability and query performance.
| Dialect | Partitioning |
|---------|-------------|
| MSSQL | Partition function + scheme, requires Enterprise or Developer edition (Standard in 2022 for some features) |
| PostgreSQL | Declarative partitioning: `PARTITION BY RANGE/LIST/HASH` (PostgreSQL 10+) |
| Oracle | Range, list, hash, composite partitioning. Enterprise Edition feature |
| MySQL | `PARTITION BY RANGE/LIST/HASH/KEY` -- natively supported in InnoDB |
| SQLite | No native table partitioning. At the sizes SQLite typically targets, this is rarely needed; if it genuinely is, the usual workaround is separate tables (e.g., one per time range) unioned through a view, or splitting across multiple attached database files |

**`model-json-storage`** -- Store semi-structured data as JSON when appropriate.
| Dialect | JSON Capabilities |
|---------|------------------|
| MSSQL | `ISJSON()`, `JSON_VALUE()`, `JSON_QUERY()`, `OPENJSON()`, `FOR JSON` |
| PostgreSQL | `JSONB` type with GIN indexes, `@>` containment, `->>/->` operators, `jsonb_path_query` |
| Oracle | `JSON` type (21c+), `JSON_VALUE()`, `JSON_TABLE()`, `IS JSON` check constraint, search index |
| MySQL | `JSON` type, `JSON_EXTRACT()`, `->>/->` operators, generated columns for indexing JSON paths |
| SQLite | No native JSON type -- store as `TEXT` with `CHECK (json_valid(col))`. `json_extract()`, `->`/`->>` operators (3.38+), `json_each()`/`json_tree()` for expansion, `json_group_array()`/`json_group_object()` for aggregation. A generated column expression (`col ->> '$.field'`) can be indexed since JSON functions are deterministic |

### 10. Monitoring & Diagnostics (LOW-MEDIUM) -- `monitor-`

**`monitor-execution-plans`** -- Know how to read execution plans in each dialect.
| Dialect | How to Get Plan |
|---------|----------------|
| MSSQL | `SET STATISTICS IO ON; SET STATISTICS TIME ON;` or `Include Actual Execution Plan` in SSMS |
| PostgreSQL | `EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)` -- always use ANALYZE for actual row counts |
| Oracle | `EXPLAIN PLAN FOR ...` then `SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY)` or `V$SQL_PLAN` |
| MySQL | `EXPLAIN ANALYZE` (8.0.18+) or `EXPLAIN FORMAT=JSON` for cost details |
| SQLite | `EXPLAIN QUERY PLAN <query>` -- human-readable plan (`SCAN`/`SEARCH`/`USING COVERING INDEX`); plain `EXPLAIN <query>` dumps raw VDBE bytecode for advanced debugging, not an execution-timing report like `EXPLAIN ANALYZE` elsewhere |

**`monitor-wait-statistics`** -- Identify performance bottlenecks through wait analysis.
| Dialect | Wait Monitoring |
|---------|----------------|
| MSSQL | `sys.dm_os_wait_stats`, `sys.dm_exec_session_wait_stats`. Key waits: `PAGEIOLATCH`, `LCK_M`, `CXPACKET`, `SOS_SCHEDULER_YIELD` |
| PostgreSQL | `pg_stat_activity` (wait_event, wait_event_type). Key waits: `LWLock`, `Lock`, `BufferIO` |
| Oracle | `V$SESSION_WAIT`, `V$ACTIVE_SESSION_HISTORY` (ASH). Key waits: `db file sequential read`, `log file sync`, `enq: TX` |
| MySQL | `performance_schema.events_waits_summary_global_by_event_name`. Key waits: `innodb_row_lock`, `table_lock` |
| SQLite | N/A -- no session/wait instrumentation exists. Contention is file-level, not row-level, and shows up as `SQLITE_BUSY`/`SQLITE_LOCKED` errors (or `busy_timeout` retries) rather than a queryable wait stat; track those at the application/driver layer |

**`monitor-slow-queries`** -- Find and fix slow queries.
| Dialect | Slow Query Detection |
|---------|---------------------|
| MSSQL | Query Store Top Resource Consumers, `sys.dm_exec_query_stats` ordered by total_worker_time |
| PostgreSQL | `pg_stat_statements` ordered by `mean_exec_time` or `total_exec_time` |
| Oracle | AWR Top SQL, `V$SQL` ordered by `ELAPSED_TIME`, ADDM recommendations |
| MySQL | Slow query log (`slow_query_log = ON`, `long_query_time = 1`), `performance_schema.events_statements_summary_by_digest` |
| SQLite | No built-in slow query log. Use a driver-level trace/profile hook (e.g., Python's `sqlite3.Connection.set_trace_callback`, or `sqlite3_trace_v2()` at the C API level) to time and log statements from application code |

**`monitor-deadlocks`** -- Detect and resolve deadlocks.
| Dialect | Deadlock Detection |
|---------|-------------------|
| MSSQL | `system_health` Extended Events session captures deadlock graphs automatically. Query `sys.fn_xe_file_target_read_file` |
| PostgreSQL | `log_lock_waits = on` in postgresql.conf, `deadlock_timeout` setting |
| Oracle | `ALERT.LOG` records ORA-00060 deadlocks, trace files contain deadlock graphs |
| MySQL | `SHOW ENGINE INNODB STATUS` -- LATEST DETECTED DEADLOCK section, `innodb_print_all_deadlocks = ON` |
| SQLite | N/A -- true multi-connection deadlocks can't occur under SQLite's single-writer model. Lock contention surfaces as `SQLITE_BUSY`/`SQLITE_LOCKED` errors (or busy-timeout retries) rather than a detected-and-broken deadlock cycle |

**`monitor-index-health`** -- Monitor index fragmentation and bloat.
| Dialect | Index Health Check |
|---------|-------------------|
| MSSQL | `sys.dm_db_index_physical_stats` -- reorganize at 10-30% fragmentation, rebuild above 30% |
| PostgreSQL | `pgstattuple` extension for bloat estimation, `REINDEX CONCURRENTLY` for rebuilds |
| Oracle | `ANALYZE INDEX ... VALIDATE STRUCTURE`, `INDEX_STATS` view, `ALTER INDEX ... REBUILD ONLINE` |
| MySQL | `OPTIMIZE TABLE` or `ALTER TABLE ... ENGINE=InnoDB` to rebuild |
| SQLite | No fragmentation/bloat metric -- indexes live in the same B-tree file as the tables. Run `VACUUM` to defragment and compact the whole database file, or `PRAGMA integrity_check`/`PRAGMA quick_check` to validate structure (not the same thing as a fragmentation report) |

