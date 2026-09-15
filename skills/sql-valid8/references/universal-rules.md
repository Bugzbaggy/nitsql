## Universal Rules Quick Reference

Rules that apply across ALL four dialects. Dialect-specific syntax noted where it varies.

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

**`query-limit-results`** -- All dialects. Always limit result sets for user-facing queries.
| Dialect | Syntax |
|---------|--------|
| MSSQL | `TOP(n)` or `OFFSET x ROWS FETCH NEXT n ROWS ONLY` |
| PostgreSQL | `LIMIT n OFFSET x` or `FETCH FIRST n ROWS ONLY` |
| Oracle | `FETCH FIRST n ROWS ONLY` (12c+) or `ROWNUM <= n` (legacy) |
| MySQL | `LIMIT n OFFSET x` or `LIMIT x, n` |

**`query-avoid-implicit-conversion`** -- All dialects. Match parameter data types to column data types exactly. Implicit conversions prevent index usage and cause full table scans.

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

**`index-key-order`** -- All dialects. Order index key columns by: (1) equality predicates first, (2) then range predicates, (3) most selective columns first within each group.

**`index-unused-indexes`** -- All dialects. Identify and drop indexes with zero or near-zero reads. They slow down writes with no benefit.
| Dialect | How to Find Unused Indexes |
|---------|--------------------------|
| MSSQL | `sys.dm_db_index_usage_stats` -- `user_seeks + user_scans + user_lookups = 0` |
| PostgreSQL | `pg_stat_user_indexes` -- `idx_scan = 0` |
| Oracle | `V$OBJECT_USAGE` after `ALTER INDEX ... MONITORING USAGE` or `DBA_INDEX_USAGE` (19c+) |
| MySQL | `performance_schema.table_io_waits_summary_by_index_usage` -- `COUNT_STAR = 0` |

**`index-missing-indexes`** -- All dialects. Use built-in advisors to find missing indexes.
| Dialect | Missing Index Source |
|---------|--------------------|
| MSSQL | `sys.dm_db_missing_index_details`, `sys.dm_db_missing_index_group_stats` |
| PostgreSQL | `pg_stat_user_tables` -- high `seq_scan` count with low `idx_scan` |
| Oracle | `DBA_ADVISOR_RECOMMENDATIONS` from SQL Tuning Advisor |
| MySQL | `EXPLAIN` output showing `type: ALL` or `type: index` on large tables |

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

**`index-statistics-maintenance`** -- All dialects. Keep statistics current for accurate query plan cost estimation.
| Dialect | Statistics Management |
|---------|---------------------|
| MSSQL | `AUTO_UPDATE_STATISTICS ON`, `UPDATE STATISTICS` for manual refresh |
| PostgreSQL | `autovacuum` handles `ANALYZE` automatically. Manual: `ANALYZE table_name` |
| Oracle | `DBMS_STATS.GATHER_TABLE_STATS` with appropriate `METHOD_OPT` |
| MySQL | `ANALYZE TABLE` or `innodb_stats_auto_recalc = ON` |

### 3. Security & Compliance (HIGH) -- `security-`

**`security-parameterize-queries`** -- All dialects. Use parameterized queries for ALL dynamic SQL. Never concatenate user input into SQL strings.
| Dialect | Secure Dynamic SQL |
|---------|-------------------|
| MSSQL | `sp_executesql @sql, N'@id INT', @id = @id` -- never `EXEC(@sql)` with concatenation |
| PostgreSQL | `EXECUTE format('SELECT ... WHERE id = $1') USING var_id` or `EXECUTE ... USING` |
| Oracle | `EXECUTE IMMEDIATE sql USING bind_var` -- never `EXECUTE IMMEDIATE 'SELECT...' \|\| input` |
| MySQL | Prepared statements: `PREPARE stmt FROM ?; EXECUTE stmt USING @var` |

**`security-least-privilege`** -- All dialects. Grant minimum necessary permissions. Never give application accounts admin/owner roles.
| Dialect | Anti-Pattern | Correct Pattern |
|---------|-------------|-----------------|
| MSSQL | `ALTER ROLE db_owner ADD MEMBER app_user` | `GRANT SELECT, INSERT, UPDATE ON SCHEMA::app TO app_role` |
| PostgreSQL | `GRANT ALL ON ALL TABLES TO app_user` | `GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA app TO app_role` |
| Oracle | `GRANT DBA TO app_user` | `GRANT SELECT, INSERT, UPDATE ON schema.table TO app_role` |
| MySQL | `GRANT ALL PRIVILEGES ON *.* TO 'app'@'%'` | `GRANT SELECT, INSERT, UPDATE ON db.* TO 'app'@'app-host'` |

**`security-avoid-admin-accounts`** -- All dialects. Never use superuser/admin accounts for application access.
| Dialect | Forbidden | Use Instead |
|---------|-----------|-------------|
| MSSQL | `sa`, `dbo` | Dedicated application login with custom role |
| PostgreSQL | `postgres` superuser | Dedicated role with `NOINHERIT`, `NOSUPERUSER` |
| Oracle | `SYS`, `SYSTEM` | Dedicated schema user with explicit grants |
| MySQL | `root` | Dedicated user with specific host restrictions |

**`security-encrypt-connections`** -- All dialects. Enforce encrypted connections in production.
| Dialect | How |
|---------|-----|
| MSSQL | `Encrypt=True;TrustServerCertificate=False` in connection string, TLS 1.2+ |
| PostgreSQL | `sslmode=verify-full` in connection string, server `ssl = on` in `postgresql.conf` |
| Oracle | Native Network Encryption or TLS in `sqlnet.ora`: `SQLNET.ENCRYPTION_SERVER = REQUIRED` |
| MySQL | `--require-secure-transport`, `ssl-mode=VERIFY_IDENTITY` in client |

**`security-row-level-security`** -- Implement RLS for multi-tenant data isolation.
| Dialect | Mechanism |
|---------|-----------|
| MSSQL | Security policy with predicate function using `SESSION_CONTEXT(N'tenant_id')` |
| PostgreSQL | `CREATE POLICY ... USING (tenant_id = current_setting('app.tenant_id'))` with `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` |
| Oracle | Virtual Private Database (VPD) via `DBMS_RLS.ADD_POLICY` |
| MySQL | No native RLS. Implement via views with `WHERE tenant_id = @current_tenant` or application-layer filtering |

**`security-data-encryption-at-rest`** -- All dialects. Enable transparent encryption for data at rest.
| Dialect | Feature |
|---------|---------|
| MSSQL | Transparent Data Encryption (TDE), Always Encrypted |
| PostgreSQL | `pgcrypto` extension, filesystem-level encryption, or cloud provider encryption |
| Oracle | TDE (tablespace or column-level), Oracle Wallet/Key Vault |
| MySQL | InnoDB tablespace encryption: `ALTER TABLE ... ENCRYPTION='Y'` |

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

### 4. Connection Management (HIGH) -- `connection-`

**`connection-pooling`** -- All dialects. Always use connection pooling. Never open/close connections per query.
| Dialect | Pooling Mechanism |
|---------|------------------|
| MSSQL | ADO.NET: `Pooling=True;Min Pool Size=5;Max Pool Size=100`, SQLAlchemy: `pool_size=10`, Node: `tedious` ConnectionPool |
| PostgreSQL | `pgbouncer` (external), psycopg2: connection pool class, SQLAlchemy: `pool_size=10`, Node: `pg.Pool` |
| Oracle | Oracle Connection Pool: `oracledb.create_pool(min=5, max=20)`, UCP for Java |
| MySQL | `mysql-connector-python`: `pooling={'pool_size': 10}`, Node: `mysql2.createPool()` |

**`connection-retry-logic`** -- All dialects. Implement exponential backoff for transient errors.
| Dialect | Transient Error Codes |
|---------|----------------------|
| MSSQL | 4060, 40197, 40501, 40613, 49918, 49919, 49920, 1205 (deadlock) |
| PostgreSQL | Class 08 (connection exceptions), 40001 (serialization failure), 40P01 (deadlock) |
| Oracle | ORA-03113 (end-of-file), ORA-03114 (not connected), ORA-12541 (no listener), ORA-00060 (deadlock) |
| MySQL | 1205 (lock wait timeout), 1213 (deadlock), 2003 (can't connect), 2006 (server gone away) |

**`connection-close-dispose`** -- All dialects. Always release connections back to the pool using `using`, `try-finally`, context managers, or equivalent resource management.

**`connection-async`** -- All dialects. Use async/await for database calls in web applications to avoid thread blocking.
| Dialect | Async Driver |
|---------|-------------|
| MSSQL | `aioodbc`, async `tedious` (Node) |
| PostgreSQL | `asyncpg`, `psycopg` (async mode), `pg` with async (Node) |
| Oracle | `oracledb` thin mode (async), `cx_Oracle` with `asyncio` |
| MySQL | `aiomysql`, `mysql2` promise API (Node) |

**`connection-timeouts`** -- All dialects. Set appropriate connection and command timeouts. Never use infinite timeouts in production.
| Dialect | Connection Timeout | Command Timeout |
|---------|-------------------|-----------------|
| MSSQL | `Connect Timeout=30` in connection string | `CommandTimeout = 30` (seconds) on SqlCommand |
| PostgreSQL | `connect_timeout=10` in connection string | `statement_timeout = '30s'` per session or in postgresql.conf |
| Oracle | `CONNECT_TIMEOUT=10` in sqlnet.ora or `(CONNECT_TIMEOUT=10)` in TNS | `ALTER SESSION SET NLS_TIMEOUT = 30` or `call_timeout` in oracledb driver |
| MySQL | `connect_timeout=10` in my.cnf | `max_execution_time=30000` (ms) hint or `wait_timeout` for idle connections |

**`connection-read-replicas`** -- All dialects. Route read-only queries to replicas to reduce primary load.
| Dialect | Configuration |
|---------|--------------|
| MSSQL | `ApplicationIntent=ReadOnly` in connection string for AG routing |
| PostgreSQL | Separate connection string to replica, or `target_session_attrs=prefer-standby` |
| Oracle | `(LOAD_BALANCE=ON)` in TNS with Active Data Guard |
| MySQL | MySQL Router, ProxySQL, or application-level read/write splitting |

### 5. Procedural Code Patterns (MEDIUM-HIGH) -- `proc-`

**`proc-error-handling`** -- All dialects. All procedural code must have structured error handling.
| Dialect | Pattern |
|---------|---------|
| MSSQL | `BEGIN TRY...END TRY BEGIN CATCH...END CATCH` with `THROW` or `RAISERROR` |
| PostgreSQL | `BEGIN...EXCEPTION WHEN ... THEN...END` inside PL/pgSQL functions |
| Oracle | `BEGIN...EXCEPTION WHEN ... THEN...END` inside PL/SQL blocks |
| MySQL | `DECLARE ... HANDLER FOR SQLEXCEPTION BEGIN...END` |

**`proc-transaction-handling`** -- All dialects. Wrap multi-statement operations in explicit transactions. Always pair COMMIT with error-path ROLLBACK.
| Dialect | Transaction Pattern |
|---------|-------------------|
| MSSQL | `BEGIN TRANSACTION; ...TRY/CATCH... COMMIT/ROLLBACK; SET XACT_ABORT ON` |
| PostgreSQL | `BEGIN; ...EXCEPTION path ROLLBACK... COMMIT;` or savepoints |
| Oracle | Implicit transaction start. `COMMIT;` or `ROLLBACK;` explicitly. Use `SAVEPOINT` for partial rollback |
| MySQL | `START TRANSACTION; ... COMMIT;` or `ROLLBACK;` -- ensure `autocommit=0` for multi-statement |

**`proc-set-based-over-row-by-row`** -- All dialects. Always prefer set-based operations over loops/cursors. If a cursor is unavoidable, use the most efficient cursor type available:
| Dialect | If Cursor Required |
|---------|-------------------|
| MSSQL | `FAST_FORWARD` (read-only, forward-only) cursor |
| PostgreSQL | `DECLARE ... CURSOR FOR ...` with `FETCH` in batches |
| Oracle | `BULK COLLECT ... LIMIT 1000` with `FORALL` for DML |
| MySQL | `DECLARE ... CURSOR FOR ...` with `FETCH` |

**`proc-avoid-dynamic-sql-when-possible`** -- All dialects. Use static SQL whenever possible. Dynamic SQL introduces injection risk, prevents compile-time validation, and complicates plan caching.

**`proc-schema-qualify`** -- All dialects. Always qualify object references with schema/owner name.
| Dialect | Example |
|---------|---------|
| MSSQL | `dbo.orders`, `sales.customers` |
| PostgreSQL | `public.orders`, `app.customers` |
| Oracle | `hr.employees`, `app.orders` |
| MySQL | `mydb.orders` (database-qualified) |

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
| **SA0009** | VARCHAR/CHAR with unnecessarily small size | All | LOW |
| **SA0010** | Deprecated join syntax | MSSQL | MEDIUM |
| **SA0011** | Special characters in object names | All | LOW |
| **SA0012** | Reserved words as identifiers | All | MEDIUM |
| **SA0014** | Implicit type conversion in predicate | All | HIGH |
| **SA0015** | Non-deterministic function in WHERE clause | All | MEDIUM |
| **SA0016** | Problematic naming prefix (`sp_` in MSSQL) | MSSQL | MEDIUM |

### 7. Database Configuration (MEDIUM) -- `config-`

**`config-query-analysis-tools`** -- Each dialect has its own query analysis infrastructure. Enable and configure it.
| Dialect | Tool | Configuration |
|---------|------|--------------|
| MSSQL | Query Store | `ALTER DATABASE db SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, MAX_STORAGE_SIZE_MB = 1024, INTERVAL_LENGTH_MINUTES = 30, DATA_FLUSH_INTERVAL_SECONDS = 900)` |
| PostgreSQL | pg_stat_statements | `shared_preload_libraries = 'pg_stat_statements'` in `postgresql.conf`, then `CREATE EXTENSION pg_stat_statements` |
| Oracle | AWR + ASH | Enabled by default with Diagnostics Pack. `EXEC DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT;` for manual snapshots |
| MySQL | Performance Schema | `performance_schema = ON` in `my.cnf`. Enable `events_statements_summary_by_digest` |

**`config-memory`** -- Configure memory allocation per dialect.
| Dialect | Key Setting |
|---------|------------|
| MSSQL | `max server memory (MB)` -- set to total RAM minus OS needs (leave 4-8 GB for OS) |
| PostgreSQL | `shared_buffers` (25% of RAM), `effective_cache_size` (50-75% of RAM), `work_mem` (per-sort, start at 4-64 MB) |
| Oracle | `SGA_TARGET` (automatic), `PGA_AGGREGATE_TARGET` |
| MySQL | `innodb_buffer_pool_size` (70-80% of RAM), `innodb_log_file_size` |

**`config-parallelism`** -- Control parallel query execution.
| Dialect | Key Setting |
|---------|------------|
| MSSQL | `MAXDOP` -- set based on NUMA node CPU count. Cost Threshold for Parallelism: raise from default 5 to 25-50 |
| PostgreSQL | `max_parallel_workers_per_gather` (2-4), `parallel_tuple_cost`, `min_parallel_table_scan_size` |
| Oracle | `PARALLEL_DEGREE_POLICY = AUTO`, or hint `/*+ PARALLEL(t, 4) */` |
| MySQL | `innodb_parallel_read_threads` (MySQL 8.0.14+), limited parallel query support |

**`config-auto-maintenance`** -- Enable automatic maintenance tasks.
| Dialect | Tasks |
|---------|-------|
| MSSQL | `AUTO_UPDATE_STATISTICS ON`, `AUTO_CREATE_STATISTICS ON`, index rebuild/reorganize maintenance jobs |
| PostgreSQL | `autovacuum` for VACUUM and ANALYZE. Tune `autovacuum_vacuum_scale_factor` for large tables |
| Oracle | Auto Maintenance Windows: `DBMS_AUTO_TASK_ADMIN` controls optimizer stats, SQL tuning, segment advisor |
| MySQL | `innodb_stats_auto_recalc = ON`, `OPTIMIZE TABLE` for fragmented tables |

**`config-logging-and-recovery`** -- Configure transaction logging and recovery.
| Dialect | Key Settings |
|---------|-------------|
| MSSQL | Recovery model (FULL for production), Accelerated Database Recovery (ADR) for instant rollback |
| PostgreSQL | `wal_level = replica`, `checkpoint_timeout`, `max_wal_size` |
| Oracle | Archive log mode for production, RMAN backup configuration |
| MySQL | `innodb_flush_log_at_trx_commit = 1` (durability), `sync_binlog = 1`, binary log for replication |

### 8. Data Types & Naming (MEDIUM) -- `type-`, `naming-`

**`type-use-appropriate-types`** -- Use the correct data type for each dialect. Avoid overly large types.
| Purpose | MSSQL | PostgreSQL | Oracle | MySQL |
|---------|-------|------------|--------|-------|
| Auto-increment PK | `INT IDENTITY` or `BIGINT IDENTITY` | `GENERATED ALWAYS AS IDENTITY` or `SERIAL` | `GENERATED ALWAYS AS IDENTITY` (12c+) or sequence + trigger | `INT AUTO_INCREMENT` |
| UUID | `UNIQUEIDENTIFIER` | `UUID` with `gen_random_uuid()` | `RAW(16)` or `SYS_GUID()` | `BINARY(16)` or `CHAR(36)` |
| Timestamp | `DATETIME2(7)` | `TIMESTAMPTZ` | `TIMESTAMP WITH TIME ZONE` | `DATETIME(6)` or `TIMESTAMP(6)` |
| Boolean | `BIT` | `BOOLEAN` | `NUMBER(1)` with CHECK constraint | `BOOLEAN` (alias for `TINYINT(1)`) |
| Large text | `NVARCHAR(MAX)` | `TEXT` | `CLOB` | `LONGTEXT` |
| JSON | `NVARCHAR(MAX)` with JSON functions | `JSONB` (preferred) or `JSON` | `JSON` (21c+) or `CLOB` with JSON functions | `JSON` |
| Money/Currency | `DECIMAL(19,4)` (not `MONEY`) | `NUMERIC(19,4)` | `NUMBER(19,4)` | `DECIMAL(19,4)` |

**`type-avoid-deprecated`** -- Do not use deprecated or legacy data types.
| Dialect | Deprecated | Use Instead |
|---------|-----------|-------------|
| MSSQL | `TEXT`, `NTEXT`, `IMAGE`, `MONEY` | `VARCHAR(MAX)`, `NVARCHAR(MAX)`, `VARBINARY(MAX)`, `DECIMAL(19,4)` |
| PostgreSQL | `SERIAL` (soft-deprecated) | `GENERATED ALWAYS AS IDENTITY` |
| Oracle | `LONG`, `LONG RAW` | `CLOB`, `BLOB` |
| MySQL | `FLOAT`/`DOUBLE` for money | `DECIMAL` for exact numeric |

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
- Avoid reserved words as identifiers in all dialects
- Avoid special characters (spaces, hyphens, dots) in object names
- Use meaningful, descriptive names (not `t1`, `col1`, `temp`)

### 9. Data Modeling (MEDIUM) -- `model-`

**`model-enforce-constraints`** -- All dialects. Always define PRIMARY KEY, FOREIGN KEY, UNIQUE, CHECK, and NOT NULL constraints. Constraints are the last line of defense for data integrity.

**`model-temporal-tables`** -- Use system-versioned temporal tables for audit trails when available.
| Dialect | Support |
|---------|---------|
| MSSQL | `SYSTEM_VERSIONING = ON` with history table |
| PostgreSQL | `temporal_tables` extension or manual trigger-based approach |
| Oracle | Flashback Data Archive (Total Recall) |
| MySQL | Not natively supported. Use triggers or application-level audit tables |

**`model-partitioning`** -- Partition large tables (>10M rows or >10 GB) for manageability and query performance.
| Dialect | Partitioning |
|---------|-------------|
| MSSQL | Partition function + scheme, requires Enterprise or Developer edition (Standard in 2022 for some features) |
| PostgreSQL | Declarative partitioning: `PARTITION BY RANGE/LIST/HASH` (PostgreSQL 10+) |
| Oracle | Range, list, hash, composite partitioning. Enterprise Edition feature |
| MySQL | `PARTITION BY RANGE/LIST/HASH/KEY` -- natively supported in InnoDB |

**`model-json-storage`** -- Store semi-structured data as JSON when appropriate.
| Dialect | JSON Capabilities |
|---------|------------------|
| MSSQL | `ISJSON()`, `JSON_VALUE()`, `JSON_QUERY()`, `OPENJSON()`, `FOR JSON` |
| PostgreSQL | `JSONB` type with GIN indexes, `@>` containment, `->>/->` operators, `jsonb_path_query` |
| Oracle | `JSON` type (21c+), `JSON_VALUE()`, `JSON_TABLE()`, `IS JSON` check constraint, search index |
| MySQL | `JSON` type, `JSON_EXTRACT()`, `->>/->` operators, generated columns for indexing JSON paths |

### 10. Monitoring & Diagnostics (LOW-MEDIUM) -- `monitor-`

**`monitor-execution-plans`** -- Know how to read execution plans in each dialect.
| Dialect | How to Get Plan |
|---------|----------------|
| MSSQL | `SET STATISTICS IO ON; SET STATISTICS TIME ON;` or `Include Actual Execution Plan` in SSMS |
| PostgreSQL | `EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)` -- always use ANALYZE for actual row counts |
| Oracle | `EXPLAIN PLAN FOR ...` then `SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY)` or `V$SQL_PLAN` |
| MySQL | `EXPLAIN ANALYZE` (8.0.18+) or `EXPLAIN FORMAT=JSON` for cost details |

**`monitor-wait-statistics`** -- Identify performance bottlenecks through wait analysis.
| Dialect | Wait Monitoring |
|---------|----------------|
| MSSQL | `sys.dm_os_wait_stats`, `sys.dm_exec_session_wait_stats`. Key waits: `PAGEIOLATCH`, `LCK_M`, `CXPACKET`, `SOS_SCHEDULER_YIELD` |
| PostgreSQL | `pg_stat_activity` (wait_event, wait_event_type). Key waits: `LWLock`, `Lock`, `BufferIO` |
| Oracle | `V$SESSION_WAIT`, `V$ACTIVE_SESSION_HISTORY` (ASH). Key waits: `db file sequential read`, `log file sync`, `enq: TX` |
| MySQL | `performance_schema.events_waits_summary_global_by_event_name`. Key waits: `innodb_row_lock`, `table_lock` |

**`monitor-slow-queries`** -- Find and fix slow queries.
| Dialect | Slow Query Detection |
|---------|---------------------|
| MSSQL | Query Store Top Resource Consumers, `sys.dm_exec_query_stats` ordered by total_worker_time |
| PostgreSQL | `pg_stat_statements` ordered by `mean_exec_time` or `total_exec_time` |
| Oracle | AWR Top SQL, `V$SQL` ordered by `ELAPSED_TIME`, ADDM recommendations |
| MySQL | Slow query log (`slow_query_log = ON`, `long_query_time = 1`), `performance_schema.events_statements_summary_by_digest` |

**`monitor-deadlocks`** -- Detect and resolve deadlocks.
| Dialect | Deadlock Detection |
|---------|-------------------|
| MSSQL | `system_health` Extended Events session captures deadlock graphs automatically. Query `sys.fn_xe_file_target_read_file` |
| PostgreSQL | `log_lock_waits = on` in postgresql.conf, `deadlock_timeout` setting |
| Oracle | `ALERT.LOG` records ORA-00060 deadlocks, trace files contain deadlock graphs |
| MySQL | `SHOW ENGINE INNODB STATUS` -- LATEST DETECTED DEADLOCK section, `innodb_print_all_deadlocks = ON` |

**`monitor-index-health`** -- Monitor index fragmentation and bloat.
| Dialect | Index Health Check |
|---------|-------------------|
| MSSQL | `sys.dm_db_index_physical_stats` -- reorganize at 10-30% fragmentation, rebuild above 30% |
| PostgreSQL | `pgstattuple` extension for bloat estimation, `REINDEX CONCURRENTLY` for rebuilds |
| Oracle | `ANALYZE INDEX ... VALIDATE STRUCTURE`, `INDEX_STATS` view, `ALTER INDEX ... REBUILD ONLINE` |
| MySQL | `OPTIMIZE TABLE` or `ALTER TABLE ... ENGINE=InnoDB` to rebuild |

