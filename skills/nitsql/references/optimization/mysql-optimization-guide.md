# MySQL / MariaDB Optimization Guide

A comprehensive reference for MySQL and MariaDB-specific performance tuning, covering query analysis, InnoDB internals, indexing, server configuration, and replication.

---

## 1. EXPLAIN Output Interpretation

### Basic Usage

```sql
-- Traditional EXPLAIN
EXPLAIN SELECT * FROM orders WHERE customer_id = 42;

-- Tree format (MySQL 8.0.16+)
EXPLAIN FORMAT=TREE SELECT * FROM orders WHERE customer_id = 42;

-- Actual execution with timing (MySQL 8.0.18+)
EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = 42;

-- JSON format with detailed cost info
EXPLAIN FORMAT=JSON SELECT * FROM orders WHERE customer_id = 42;
```

### The `type` Column (Access Method)

Listed from worst to best performance:

| Type | Description | Action |
|---|---|---|
| `ALL` | Full table scan, reads every row | Add an index or rewrite the query |
| `index` | Full index scan (reads entire index) | Better than ALL but still reads everything; check if a more selective index exists |
| `range` | Index range scan (e.g., `BETWEEN`, `>`, `<`, `IN`) | Generally good; ensure the range is narrow |
| `index_subquery` | Subquery uses index lookup | Acceptable |
| `unique_subquery` | Subquery uses unique index | Good |
| `index_merge` | Multiple indexes merged | Can be OK; sometimes a composite index is better |
| `ref_or_null` | Like `ref` but also searches for NULL | Good |
| `ref` | Non-unique index lookup | Good |
| `eq_ref` | Unique index lookup (one row per join) | Excellent (typical for PRIMARY KEY or UNIQUE joins) |
| `const` | Table has at most one matching row (optimized away) | Best possible |
| `system` | Table has exactly one row | Best possible |

### Other Important EXPLAIN Columns

| Column | What to Look For |
|---|---|
| `key` | Which index is actually used (NULL = no index) |
| `key_len` | Bytes of the index used -- helps identify if all columns in a composite index are utilized |
| `ref` | What is compared to the index (const, column name, func) |
| `rows` | Estimated rows to examine (lower is better) |
| `filtered` | Percentage of rows remaining after table condition filter (100% = no additional filtering needed) |
| `Extra` | Critical flags: `Using filesort`, `Using temporary`, `Using where`, `Using index` (covering index) |

### Dangerous `Extra` Values

- **Using filesort**: MySQL must do an extra sort pass. Consider adding an index that matches the ORDER BY.
- **Using temporary**: A temp table is created (common with GROUP BY and DISTINCT on non-indexed columns).
- **Using where**: Rows are filtered after being read from the storage engine. Not always bad but indicates the index is not fully selective.
- **Using join buffer (Block Nested Loop)**: No index on the join column. Add one.

---

## 2. InnoDB Buffer Pool Sizing and Monitoring

### Sizing the Buffer Pool

The InnoDB buffer pool is the most important memory structure -- it caches data pages and index pages.

```ini
# my.cnf / my.ini
[mysqld]
# Set to 70-80% of available RAM on a dedicated database server
innodb_buffer_pool_size = 12G

# Number of buffer pool instances (reduces contention; use 1 per GB, max 64)
innodb_buffer_pool_instances = 8

# Chunk size for resizing (must divide evenly into pool_size / instances)
innodb_buffer_pool_chunk_size = 128M
```

### Monitoring Buffer Pool Hit Ratio

```sql
-- Buffer pool hit ratio (should be > 99% for OLTP workloads)
SELECT
    (1 - (
        (SELECT variable_value FROM performance_schema.global_status WHERE variable_name = 'Innodb_buffer_pool_reads')
        /
        (SELECT variable_value FROM performance_schema.global_status WHERE variable_name = 'Innodb_buffer_pool_read_requests')
    )) * 100 AS buffer_pool_hit_ratio;

-- Detailed buffer pool stats
SHOW ENGINE INNODB STATUS\G
-- Look for the "BUFFER POOL AND MEMORY" section

-- Buffer pool pages breakdown
SELECT
    pool_id,
    pool_size AS total_pages,
    free_buffers AS free_pages,
    database_pages AS data_pages,
    old_database_pages AS old_pages,
    modified_db_pages AS dirty_pages,
    ROUND(100 * database_pages / pool_size, 1) AS pct_used
FROM information_schema.INNODB_BUFFER_POOL_STATS;
```

### Warming Up the Buffer Pool After Restart

```ini
[mysqld]
# Save buffer pool page list on shutdown, reload on startup
innodb_buffer_pool_dump_at_shutdown = ON
innodb_buffer_pool_load_at_startup = ON

# Percentage of pages to save (default: 25)
innodb_buffer_pool_dump_pct = 75
```

---

## 3. Query Cache Removal in MySQL 8.0+ and Alternatives

The query cache was removed entirely in MySQL 8.0 due to scalability issues (global mutex contention on every write).

### Alternatives

1. **Application-level caching** (Redis, Memcached):
   ```python
   # Pseudo-code
   result = cache.get(f"user:{user_id}")
   if result is None:
       result = db.query("SELECT * FROM users WHERE id = %s", user_id)
       cache.set(f"user:{user_id}", result, ttl=300)
   ```

2. **ProxySQL query caching**:
   ```sql
   -- ProxySQL admin interface
   INSERT INTO mysql_query_rules (rule_id, match_pattern, cache_ttl)
   VALUES (1, '^SELECT .* FROM products WHERE', 60000);
   LOAD MYSQL QUERY RULES TO RUNTIME;
   ```

3. **MySQL materialized views** (manually managed):
   ```sql
   -- Create a summary table
   CREATE TABLE daily_sales_summary (
       sale_date DATE PRIMARY KEY,
       total_revenue DECIMAL(15,2),
       order_count INT,
       updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
   );

   -- Refresh via scheduled event
   CREATE EVENT refresh_daily_sales
   ON SCHEDULE EVERY 1 HOUR
   DO
   REPLACE INTO daily_sales_summary (sale_date, total_revenue, order_count)
   SELECT DATE(created_at), SUM(total), COUNT(*)
   FROM orders
   WHERE created_at >= CURDATE() - INTERVAL 1 DAY
   GROUP BY DATE(created_at);
   ```

---

## 4. InnoDB Clustered Index Behavior and Primary Key Design

### How InnoDB Stores Data

InnoDB tables are **always** stored as a clustered index (the B+tree whose leaf nodes contain the full row data). The clustering key is:

1. The `PRIMARY KEY` (if defined)
2. The first `UNIQUE NOT NULL` index (if no PK)
3. A hidden 6-byte `ROW_ID` generated by InnoDB (if neither exists -- avoid this)

### Primary Key Design Best Practices

```sql
-- GOOD: Auto-increment integer PK (sequential inserts, compact)
CREATE TABLE orders (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    customer_id INT NOT NULL,
    total DECIMAL(12,2),
    created_at DATETIME NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB;

-- BAD: UUID as primary key (random inserts cause page splits and fragmentation)
CREATE TABLE orders_bad (
    id CHAR(36) NOT NULL,  -- or BINARY(16)
    ...
    PRIMARY KEY (id)
) ENGINE=InnoDB;
-- Random UUIDs cause massive page splitting and poor cache utilization

-- ACCEPTABLE: UUID v7 or ULID (time-ordered, sequential)
-- If you must use UUIDs, use an ordered variant stored as BINARY(16)
CREATE TABLE orders_uuid (
    id BINARY(16) NOT NULL,
    ...
    PRIMARY KEY (id)
) ENGINE=InnoDB;
-- Insert with: INSERT INTO orders_uuid (id, ...) VALUES (UUID_TO_BIN(UUID(), 1), ...);
```

### Why PK Size Matters

Every secondary index in InnoDB includes a copy of the primary key in its leaf nodes. A large PK (e.g., 36-byte CHAR UUID) multiplies storage across all secondary indexes.

```sql
-- Check the actual size of a primary key
SELECT
    TABLE_NAME,
    INDEX_NAME,
    STAT_VALUE * @@innodb_page_size AS size_bytes
FROM mysql.innodb_index_stats
WHERE stat_name = 'size'
  AND TABLE_NAME = 'orders'
  AND INDEX_NAME = 'PRIMARY';
```

---

## 5. Covering Indexes with InnoDB

A covering index contains all columns needed by a query, eliminating the need to look up the full row from the clustered index (the "bookmark lookup").

```sql
-- Query
SELECT customer_id, status, total FROM orders WHERE customer_id = 42 AND status = 'shipped';

-- Covering index for this query
CREATE INDEX idx_orders_covering ON orders (customer_id, status, total);

-- EXPLAIN will show "Using index" in Extra column, meaning index-only access
EXPLAIN SELECT customer_id, status, total FROM orders
WHERE customer_id = 42 AND status = 'shipped';
```

### InnoDB Covering Index Advantage

Since InnoDB secondary index leaf nodes already contain the primary key, the PK columns are implicitly part of every covering index:

```sql
-- This index covers queries that also need `id` (the PK) even though `id` is not in the index definition
CREATE INDEX idx_orders_cust_status ON orders (customer_id, status);

-- This query is covered because `id` is in the secondary index implicitly
EXPLAIN SELECT id, customer_id, status FROM orders WHERE customer_id = 42;
```

---

## 6. OPTIMIZE TABLE and InnoDB Online DDL

### OPTIMIZE TABLE

```sql
-- Rebuild the table and its indexes (reclaim space, reduce fragmentation)
OPTIMIZE TABLE orders;
-- For InnoDB, this runs ALTER TABLE ... FORCE internally

-- Check fragmentation before optimizing
SELECT
    TABLE_NAME,
    DATA_LENGTH,
    DATA_FREE,
    ROUND(100 * DATA_FREE / (DATA_LENGTH + DATA_FREE), 1) AS frag_pct
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'mydb' AND DATA_FREE > 0
ORDER BY DATA_FREE DESC;
```

### InnoDB Online DDL (MySQL 5.6+)

Many DDL operations can run without blocking concurrent DML:

```sql
-- Add index without blocking writes (ALGORITHM=INPLACE, LOCK=NONE is the default for index creation)
ALTER TABLE orders ADD INDEX idx_orders_date (created_at), ALGORITHM=INPLACE, LOCK=NONE;

-- Add a column (instant in MySQL 8.0.12+ for appending columns)
ALTER TABLE orders ADD COLUMN notes TEXT, ALGORITHM=INSTANT;

-- Change column default (instant)
ALTER TABLE orders ALTER COLUMN status SET DEFAULT 'pending', ALGORITHM=INSTANT;

-- Operations that still require a table copy:
-- - Changing column data type
-- - Changing character set
-- - Adding a FULLTEXT or SPATIAL index (first one on the table)
```

---

## 7. Slow Query Log Configuration

```ini
[mysqld]
# Enable slow query log
slow_query_log = ON
slow_query_log_file = /var/log/mysql/slow.log

# Threshold in seconds (capture queries slower than 500ms)
long_query_time = 0.5

# Also log queries not using indexes
log_queries_not_using_indexes = ON

# Throttle the above to avoid flooding the log
log_throttle_queries_not_using_indexes = 60

# Log extra info (MySQL 8.0.14+): rows_affected, bytes_sent, etc.
log_slow_extra = ON

# Include replication-applied queries
log_slow_replica_statements = ON
```

### Analyzing the Slow Query Log

```bash
# MySQL's built-in analyzer
mysqldumpslow -s t -t 10 /var/log/mysql/slow.log

# Percona pt-query-digest (more detailed)
pt-query-digest /var/log/mysql/slow.log --limit 20 --order-by Query_time:sum
```

---

## 8. Performance Schema for Query Analysis

```sql
-- Enable Performance Schema (usually ON by default in MySQL 8.0)
-- Check status:
SHOW VARIABLES LIKE 'performance_schema';

-- Top 10 queries by average latency
SELECT
    DIGEST_TEXT,
    COUNT_STAR AS exec_count,
    ROUND(AVG_TIMER_WAIT / 1e9, 2) AS avg_latency_ms,
    ROUND(SUM_TIMER_WAIT / 1e9, 0) AS total_latency_ms,
    SUM_ROWS_EXAMINED,
    SUM_ROWS_SENT,
    ROUND(SUM_ROWS_EXAMINED / NULLIF(SUM_ROWS_SENT, 0), 0) AS rows_examined_per_sent
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME = 'mydb'
  AND COUNT_STAR > 10
ORDER BY AVG_TIMER_WAIT DESC
LIMIT 10;

-- Queries creating temporary tables on disk
SELECT
    DIGEST_TEXT,
    COUNT_STAR,
    SUM_CREATED_TMP_DISK_TABLES,
    SUM_CREATED_TMP_TABLES,
    ROUND(AVG_TIMER_WAIT / 1e9, 2) AS avg_ms
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_CREATED_TMP_DISK_TABLES > 0
ORDER BY SUM_CREATED_TMP_DISK_TABLES DESC
LIMIT 10;

-- Queries doing full table scans
SELECT
    DIGEST_TEXT,
    COUNT_STAR,
    SUM_NO_INDEX_USED,
    SUM_NO_GOOD_INDEX_USED,
    ROUND(AVG_TIMER_WAIT / 1e9, 2) AS avg_ms
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_NO_INDEX_USED > 0
ORDER BY SUM_NO_INDEX_USED DESC
LIMIT 10;

-- Table I/O waits (which tables are hottest)
SELECT
    OBJECT_SCHEMA,
    OBJECT_NAME,
    COUNT_STAR AS total_io,
    COUNT_READ,
    COUNT_WRITE,
    ROUND(SUM_TIMER_WAIT / 1e12, 2) AS total_wait_sec
FROM performance_schema.table_io_waits_summary_by_table
WHERE OBJECT_SCHEMA = 'mydb'
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;
```

### Using the sys Schema (MySQL 5.7+)

```sql
-- Statements with full table scans
SELECT * FROM sys.statements_with_full_table_scans LIMIT 10;

-- Statements with temporary tables on disk
SELECT * FROM sys.statements_with_temp_tables LIMIT 10;

-- Unused indexes
SELECT * FROM sys.schema_unused_indexes WHERE object_schema = 'mydb';

-- Redundant indexes
SELECT * FROM sys.schema_redundant_indexes WHERE table_schema = 'mydb';

-- Table statistics (rows, latency)
SELECT * FROM sys.schema_table_statistics WHERE table_schema = 'mydb'
ORDER BY total_latency DESC;

-- Wait analysis
SELECT * FROM sys.user_summary_by_statement_latency;
```

---

## 9. MySQL Query Hints

### Index Hints

```sql
-- Suggest an index (optimizer may still ignore it)
SELECT * FROM orders USE INDEX (idx_orders_customer) WHERE customer_id = 42;

-- Force an index (optimizer must use it if applicable)
SELECT * FROM orders FORCE INDEX (idx_orders_customer) WHERE customer_id = 42;

-- Ignore an index (prevent optimizer from considering it)
SELECT * FROM orders IGNORE INDEX (idx_orders_date) WHERE created_at > '2024-01-01';

-- Scope-specific hints
SELECT * FROM orders USE INDEX FOR JOIN (idx_orders_customer)
                     USE INDEX FOR ORDER BY (idx_orders_date)
WHERE customer_id = 42 ORDER BY created_at;
```

### Optimizer Hints (MySQL 8.0+)

```sql
-- Force join order
SELECT /*+ JOIN_ORDER(o, c) */ o.*, c.name
FROM orders o JOIN customers c ON o.customer_id = c.id;

-- Force a specific join algorithm
SELECT /*+ HASH_JOIN(o, c) */ o.*, c.name
FROM orders o JOIN customers c ON o.customer_id = c.id;

SELECT /*+ NO_HASH_JOIN(o, c) */ o.*, c.name
FROM orders o JOIN customers c ON o.customer_id = c.id;

-- Control index usage via optimizer hints
SELECT /*+ INDEX(orders idx_orders_date) */ * FROM orders WHERE created_at > '2024-01-01';
SELECT /*+ NO_INDEX(orders idx_orders_date) */ * FROM orders WHERE created_at > '2024-01-01';

-- Merge or materialize derived tables
SELECT /*+ MERGE(sub) */ * FROM (SELECT * FROM orders WHERE total > 100) sub;
SELECT /*+ NO_MERGE(sub) */ * FROM (SELECT * FROM orders WHERE total > 100) sub;

-- Semijoin strategies
SELECT /*+ SEMIJOIN(@subq MATERIALIZATION) */ *
FROM customers c
WHERE c.id IN (SELECT /*+ QB_NAME(subq) */ customer_id FROM orders);

-- Set a statement-level resource limit
SELECT /*+ MAX_EXECUTION_TIME(5000) */ * FROM large_table WHERE condition;

-- STRAIGHT_JOIN: force join order to match the FROM clause order
SELECT STRAIGHT_JOIN o.*, c.name
FROM orders o JOIN customers c ON o.customer_id = c.id;
```

---

## 10. Partitioning in MySQL

### RANGE Partitioning

```sql
CREATE TABLE orders (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    customer_id INT NOT NULL,
    total DECIMAL(12,2),
    created_at DATETIME NOT NULL,
    PRIMARY KEY (id, created_at)  -- partition key must be part of every unique key
) ENGINE=InnoDB
PARTITION BY RANGE (YEAR(created_at)) (
    PARTITION p2022 VALUES LESS THAN (2023),
    PARTITION p2023 VALUES LESS THAN (2024),
    PARTITION p2024 VALUES LESS THAN (2025),
    PARTITION p2025 VALUES LESS THAN (2026),
    PARTITION pmax  VALUES LESS THAN MAXVALUE
);
```

### LIST Partitioning

```sql
CREATE TABLE regional_sales (
    id BIGINT AUTO_INCREMENT,
    region VARCHAR(10) NOT NULL,
    amount DECIMAL(12,2),
    PRIMARY KEY (id, region)
) ENGINE=InnoDB
PARTITION BY LIST COLUMNS (region) (
    PARTITION p_americas VALUES IN ('NA', 'SA'),
    PARTITION p_emea     VALUES IN ('EU', 'ME', 'AF'),
    PARTITION p_apac     VALUES IN ('AS', 'OC')
);
```

### HASH Partitioning

```sql
CREATE TABLE sessions (
    id BIGINT AUTO_INCREMENT,
    user_id INT NOT NULL,
    data JSON,
    PRIMARY KEY (id, user_id)
) ENGINE=InnoDB
PARTITION BY HASH (user_id) PARTITIONS 8;
```

### KEY Partitioning

```sql
-- KEY partitioning uses MySQL's internal hash function
-- Can partition on columns that are not integers
CREATE TABLE logs (
    id BIGINT AUTO_INCREMENT,
    hostname VARCHAR(255) NOT NULL,
    message TEXT,
    PRIMARY KEY (id, hostname)
) ENGINE=InnoDB
PARTITION BY KEY (hostname) PARTITIONS 16;
```

### Partition Pruning and Management

```sql
-- Verify partition pruning in EXPLAIN
EXPLAIN SELECT * FROM orders WHERE created_at BETWEEN '2024-01-01' AND '2024-12-31';
-- Should show "partitions: p2024" in the output

-- Add a new partition (before MAXVALUE exists, use REORGANIZE)
ALTER TABLE orders REORGANIZE PARTITION pmax INTO (
    PARTITION p2026 VALUES LESS THAN (2027),
    PARTITION pmax  VALUES LESS THAN MAXVALUE
);

-- Drop old partitions (instant, much faster than DELETE)
ALTER TABLE orders DROP PARTITION p2022;

-- Truncate a partition
ALTER TABLE orders TRUNCATE PARTITION p2023;
```

---

## 11. InnoDB Deadlock Detection and Handling

### How InnoDB Handles Deadlocks

InnoDB has automatic deadlock detection. When a deadlock cycle is found, the transaction with the fewest undo log records is rolled back.

```sql
-- View the most recent deadlock
SHOW ENGINE INNODB STATUS\G
-- Look for the "LATEST DETECTED DEADLOCK" section

-- Enable logging of all deadlocks to the error log
SET GLOBAL innodb_print_all_deadlocks = ON;

-- Deadlock detection can be expensive with many concurrent transactions
-- In very high concurrency, you may disable it and rely on lock wait timeout instead
SET GLOBAL innodb_deadlock_detect = OFF;  -- use with caution
SET GLOBAL innodb_lock_wait_timeout = 5;  -- seconds
```

### Preventing Deadlocks

```sql
-- 1. Access tables/rows in a consistent order across all transactions
-- BAD: Transaction A locks orders then customers; Transaction B locks customers then orders
-- GOOD: Always lock in alphabetical order (customers, then orders)

-- 2. Keep transactions short
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE id = 1;
UPDATE accounts SET balance = balance + 100 WHERE id = 2;
COMMIT;  -- commit as soon as possible

-- 3. Use SELECT ... FOR UPDATE with ORDER BY to lock rows in a consistent order
SELECT * FROM inventory WHERE product_id IN (10, 20, 30)
ORDER BY product_id
FOR UPDATE;

-- 4. Add appropriate indexes so locks are row-level, not gap/table-level
-- Without an index on customer_id, InnoDB may lock the entire table
CREATE INDEX idx_orders_customer ON orders (customer_id);
```

### Monitoring Lock Waits

```sql
-- Current lock waits (MySQL 8.0)
SELECT
    r.trx_id AS waiting_trx_id,
    r.trx_mysql_thread_id AS waiting_thread,
    r.trx_query AS waiting_query,
    b.trx_id AS blocking_trx_id,
    b.trx_mysql_thread_id AS blocking_thread,
    b.trx_query AS blocking_query
FROM performance_schema.data_lock_waits w
JOIN information_schema.innodb_trx r ON r.trx_id = w.REQUESTING_ENGINE_TRANSACTION_ID
JOIN information_schema.innodb_trx b ON b.trx_id = w.BLOCKING_ENGINE_TRANSACTION_ID;

-- Using sys schema
SELECT * FROM sys.innodb_lock_waits\G
```

---

## 12. Character Set and Collation Performance Impact

### utf8mb4 vs utf8mb3 (utf8)

MySQL's `utf8` is actually `utf8mb3` (3 bytes, does not support full Unicode). Always use `utf8mb4` for proper Unicode support.

```sql
-- Set defaults for new tables
ALTER DATABASE mydb CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

-- Check current settings
SELECT @@character_set_database, @@collation_database;
```

### Performance Implications

```sql
-- Collation affects index size and comparison speed
-- utf8mb4_0900_ai_ci: accent-insensitive, case-insensitive, uses UCA 9.0 (MySQL 8.0 default)
-- utf8mb4_bin: binary comparison, fastest but case-sensitive
-- utf8mb4_general_ci: older, simpler, slightly faster than 0900_ai_ci but less correct

-- For case-sensitive lookups on case-insensitive columns, use a generated column:
ALTER TABLE users ADD COLUMN email_lower VARCHAR(255) GENERATED ALWAYS AS (LOWER(email)) STORED;
CREATE INDEX idx_users_email_lower ON users (email_lower);

-- IMPORTANT: Join columns must have the same charset and collation
-- Mismatched collations prevent index usage and cause implicit conversions
SELECT o.* FROM orders o
JOIN customers c ON o.customer_name = c.name;
-- If orders uses utf8mb4_general_ci and customers uses utf8mb4_0900_ai_ci,
-- MySQL may not use indexes on the join column!

-- Check for mismatched collations
SELECT TABLE_NAME, COLUMN_NAME, CHARACTER_SET_NAME, COLLATION_NAME
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'mydb' AND DATA_TYPE IN ('varchar', 'char', 'text')
ORDER BY COLLATION_NAME, TABLE_NAME;
```

---

## 13. Thread Pool vs One-Thread-Per-Connection

### Default: One-Thread-Per-Connection

MySQL creates a new OS thread for each client connection. This works well up to a few hundred connections.

### Thread Pool (MySQL Enterprise / MariaDB / Percona)

```ini
# MySQL Enterprise Edition
[mysqld]
plugin-load-add = thread_pool.so
thread_handling = pool-of-threads
thread_pool_size = 16                 # typically = number of CPU cores
thread_pool_max_threads = 200
thread_pool_stall_limit = 500         # ms before a query is considered stalled

# MariaDB (built-in)
[mysqld]
thread_handling = pool-of-threads
thread_pool_size = 16
thread_pool_max_threads = 500

# Percona Server
[mysqld]
thread_handling = pool-of-threads
thread_pool_size = 16
```

### When Thread Pool Helps

- High connection count (thousands of connections)
- Mixed workload with many idle connections
- Short, frequent queries (OLTP)

### Alternative: ProxySQL for Connection Multiplexing

```sql
-- ProxySQL admin: set max backend connections
UPDATE mysql_servers SET max_connections = 100 WHERE hostname = 'db-primary';
LOAD MYSQL SERVERS TO RUNTIME;
```

---

## 14. Group Replication and Read Scaling

### Single-Primary Mode (Recommended for most use cases)

```sql
-- Check Group Replication status
SELECT MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE
FROM performance_schema.replication_group_members;

-- Route reads to secondaries using ProxySQL
-- ProxySQL hostgroup 10 = writer, hostgroup 20 = readers
INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_connections)
VALUES
    (10, 'db-primary', 3306, 100),
    (20, 'db-secondary-1', 3306, 200),
    (20, 'db-secondary-2', 3306, 200);

-- Route SELECT to readers, everything else to writer
INSERT INTO mysql_query_rules (rule_id, match_pattern, destination_hostgroup, apply)
VALUES
    (1, '^SELECT .* FOR UPDATE', 10, 1),
    (2, '^SELECT', 20, 1);

LOAD MYSQL SERVERS TO RUNTIME;
LOAD MYSQL QUERY RULES TO RUNTIME;
```

### Read Scaling Best Practices

```sql
-- 1. Verify replication lag before reading from secondary
SELECT
    MEMBER_HOST,
    COUNT_TRANSACTIONS_IN_QUEUE AS trx_in_queue,
    LAST_CONFLICT_FREE_TRANSACTION
FROM performance_schema.replication_group_member_stats;

-- 2. For read-after-write consistency, use:
-- AFTER consistency level (MySQL 8.0.14+)
SET @@SESSION.group_replication_consistency = 'AFTER';
INSERT INTO orders (...) VALUES (...);
-- Subsequent reads on ANY member will see this insert

-- Or BEFORE consistency level for fresh reads
SET @@SESSION.group_replication_consistency = 'BEFORE';
SELECT * FROM orders WHERE id = 12345;
-- Waits for all pending transactions to apply before reading
```
