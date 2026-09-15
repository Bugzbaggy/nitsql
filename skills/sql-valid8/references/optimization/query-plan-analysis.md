# Cross-Platform Query Plan Analysis

A comprehensive guide to reading and interpreting EXPLAIN plans across PostgreSQL, MySQL, SQL Server, Oracle, and SQLite. Includes common anti-patterns, cost estimation, join ordering, and cardinality troubleshooting.

---

## 1. PostgreSQL: EXPLAIN

### Syntax

```sql
-- Estimated plan only
EXPLAIN SELECT * FROM orders WHERE customer_id = 42;

-- Actual execution with timing
EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = 42;

-- Full diagnostic output
EXPLAIN (ANALYZE, BUFFERS, TIMING, VERBOSE)
SELECT * FROM orders WHERE customer_id = 42;

-- JSON format (best for programmatic parsing)
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT * FROM orders WHERE customer_id = 42;

-- Text, XML, YAML also available
EXPLAIN (FORMAT YAML) SELECT 1;
```

### Common Node Types

| Node | Description | Performance Notes |
|---|---|---|
| **Seq Scan** | Reads every row in the table | Acceptable for small tables; bad for large ones |
| **Index Scan** | Traverses a B-tree and fetches rows from the heap | Good for selective queries |
| **Index Only Scan** | Reads from the index only (no heap fetch) | Best -- requires visibility map to be up to date (run VACUUM) |
| **Bitmap Index Scan + Bitmap Heap Scan** | Builds a bitmap of matching pages, then fetches | Good for medium selectivity; combines multiple indexes |
| **Nested Loop** | For each row in outer, scan inner | Good when outer is small or inner has a fast index lookup |
| **Hash Join** | Builds hash table from one input, probes with the other | Good for large equi-joins; watch for work_mem spills |
| **Merge Join** | Merges two sorted inputs | Efficient when both inputs are pre-sorted (e.g., index scans) |
| **Sort** | Sorts rows (may spill to disk) | Check if an index can avoid the sort |
| **Aggregate** | Computes aggregates (SUM, COUNT, etc.) | HashAggregate vs GroupAggregate |
| **Gather / Gather Merge** | Collects results from parallel workers | Indicates parallel execution |

### Reading Costs and Timing

```
Seq Scan on orders  (cost=0.00..1523.00 rows=5000 width=72)
                     (actual time=0.015..12.345 rows=4872 loops=1)
  Buffers: shared hit=523 read=100
  Filter: (status = 'pending')
  Rows Removed by Filter: 45128
```

- **cost=0.00..1523.00**: startup cost (0.00) to total cost (1523.00) in planner cost units
- **rows=5000**: planner's estimate of rows returned
- **actual time=0.015..12.345**: wall clock in ms (first row .. last row)
- **rows=4872**: actual rows returned (compare with estimated 5000)
- **loops=1**: this node executed once
- **Buffers: shared hit=523 read=100**: 523 pages from cache, 100 from disk
- **Rows Removed by Filter: 45128**: rows read but discarded (indicates low selectivity)

---

## 2. MySQL: EXPLAIN

### Traditional Format

```sql
EXPLAIN SELECT * FROM orders WHERE customer_id = 42;
```

Key columns:

| Column | What to Check |
|---|---|
| `id` | Query block identifier; same id = same SELECT |
| `select_type` | SIMPLE, PRIMARY, SUBQUERY, DERIVED, UNION |
| `table` | Table being accessed |
| `type` | Access method: ALL < index < range < ref < eq_ref < const < system |
| `possible_keys` | Indexes the optimizer considered |
| `key` | Index actually chosen (NULL = no index) |
| `key_len` | Bytes of key used (helps verify composite index column usage) |
| `ref` | What is compared against the key |
| `rows` | Estimated rows to examine |
| `filtered` | Estimated % of rows remaining after WHERE |
| `Extra` | Flags: Using index, Using filesort, Using temporary, etc. |

### Tree Format (MySQL 8.0.16+)

```sql
EXPLAIN FORMAT=TREE
SELECT o.*, c.name
FROM orders o JOIN customers c ON o.customer_id = c.id
WHERE o.created_at > '2024-01-01';
```

Output shows a tree of iterators with estimated costs and rows:

```
-> Nested loop inner join  (cost=45.2 rows=100)
    -> Filter: (o.created_at > '2024-01-01')  (cost=23.1 rows=100)
        -> Index range scan on o using idx_orders_date  (cost=23.1 rows=100)
    -> Single-row index lookup on c using PRIMARY (id=o.customer_id)  (cost=0.22 rows=1)
```

### EXPLAIN ANALYZE (MySQL 8.0.18+)

```sql
EXPLAIN ANALYZE
SELECT o.*, c.name
FROM orders o JOIN customers c ON o.customer_id = c.id
WHERE o.created_at > '2024-01-01';
```

Shows actual execution time and actual rows alongside estimates:

```
-> Nested loop inner join  (cost=45.2 rows=100) (actual time=0.5..3.2 rows=87 loops=1)
    -> Filter: (o.created_at > '2024-01-01')  (cost=23.1 rows=100) (actual time=0.3..1.8 rows=87 loops=1)
        -> Index range scan on o using idx_orders_date  (cost=23.1 rows=100) (actual time=0.2..1.5 rows=87 loops=1)
    -> Single-row index lookup on c using PRIMARY (id=o.customer_id)  (cost=0.22 rows=1) (actual time=0.01..0.01 rows=1 loops=87)
```

### Visual Explain

MySQL Workbench provides a graphical query plan viewer that color-codes operations by cost (green = low, red = high). Access it via Query > Explain Current Statement.

---

## 3. SQL Server: Execution Plans

### SET STATISTICS IO and TIME

```sql
-- Show I/O statistics per table
SET STATISTICS IO ON;

-- Show CPU and elapsed time
SET STATISTICS TIME ON;

SELECT o.*, c.CompanyName
FROM Orders o JOIN Customers c ON o.CustomerID = c.CustomerID
WHERE o.OrderDate > '2024-01-01';

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
```

Output:
```
Table 'Orders'. Scan count 1, logical reads 12, physical reads 0, read-ahead reads 0
Table 'Customers'. Scan count 0, logical reads 174, physical reads 0

SQL Server Execution Times:
   CPU time = 2 ms, elapsed time = 5 ms.
```

**Key metrics:**
- **logical reads**: pages read from buffer cache (the primary metric to minimize)
- **physical reads**: pages read from disk (should be 0 on warm cache)
- **scan count**: number of times the table/index was accessed

### Actual Execution Plans

```sql
-- Enable actual execution plan in SSMS: Ctrl+M or Query > Include Actual Execution Plan
-- Or via T-SQL:
SET STATISTICS PROFILE ON;
-- Run your query
SET STATISTICS PROFILE OFF;

-- XML plan (for programmatic analysis)
SET STATISTICS XML ON;
-- Run your query
SET STATISTICS XML OFF;
```

### Query Store (SQL Server 2016+)

```sql
-- Enable Query Store
ALTER DATABASE MyDB SET QUERY_STORE = ON;
ALTER DATABASE MyDB SET QUERY_STORE (
    OPERATION_MODE = READ_WRITE,
    DATA_FLUSH_INTERVAL_SECONDS = 900,
    INTERVAL_LENGTH_MINUTES = 60,
    MAX_STORAGE_SIZE_MB = 1000,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30),
    SIZE_BASED_CLEANUP_MODE = AUTO,
    QUERY_CAPTURE_MODE = AUTO
);

-- Top resource-consuming queries
SELECT TOP 20
    qt.query_sql_text,
    q.query_id,
    rs.count_executions,
    rs.avg_duration / 1000.0 AS avg_duration_ms,
    rs.avg_cpu_time / 1000.0 AS avg_cpu_ms,
    rs.avg_logical_io_reads,
    rs.avg_rowcount
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_plan p ON rs.plan_id = p.plan_id
JOIN sys.query_store_query q ON p.query_id = q.query_id
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
WHERE rs.last_execution_time > DATEADD(hour, -24, GETUTCDATE())
ORDER BY rs.avg_duration DESC;

-- Find regressed queries (plan changed, performance degraded)
SELECT
    qt.query_sql_text,
    q.query_id,
    p.plan_id,
    rs1.avg_duration / 1000.0 AS old_avg_ms,
    rs2.avg_duration / 1000.0 AS new_avg_ms
FROM sys.query_store_runtime_stats rs1
JOIN sys.query_store_runtime_stats rs2 ON rs1.plan_id != rs2.plan_id
JOIN sys.query_store_plan p ON rs2.plan_id = p.plan_id
JOIN sys.query_store_query q ON p.query_id = q.query_id
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
WHERE rs2.avg_duration > rs1.avg_duration * 2
  AND rs2.last_execution_time > rs1.last_execution_time;

-- Force a known-good plan
EXEC sp_query_store_force_plan @query_id = 42, @plan_id = 7;
```

---

## 4. Oracle: EXPLAIN PLAN and DBMS_XPLAN

### EXPLAIN PLAN FOR

```sql
-- Generate the plan (does NOT execute the query)
EXPLAIN PLAN FOR
SELECT o.*, c.customer_name
FROM orders o JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date > DATE '2024-01-01';

-- Display the plan
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- With more detail
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(format => 'ALL'));
```

### Display Actual Plan from Cursor

```sql
-- Execute the query first, then show its actual plan
SELECT /*+ GATHER_PLAN_STATISTICS */ o.*, c.customer_name
FROM orders o JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date > DATE '2024-01-01';

-- Display with actual row counts
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(format => 'ALLSTATS LAST'));
```

### V$SQL_PLAN (Cached Plans)

```sql
-- Find the SQL_ID for a known query
SELECT sql_id, sql_text, executions, elapsed_time/1e6 AS elapsed_sec
FROM v$sql
WHERE sql_text LIKE '%orders%customers%'
  AND sql_text NOT LIKE '%v$sql%';

-- Display the plan for a cached SQL statement
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR('abc123def', NULL, 'ALLSTATS'));
```

### AWR Reports

```sql
-- Generate an AWR report (requires Diagnostics Pack license)
-- Find snap_ids
SELECT snap_id, begin_interval_time FROM dba_hist_snapshot
ORDER BY snap_id DESC FETCH FIRST 10 ROWS ONLY;

-- Generate HTML AWR report
SELECT output FROM TABLE(DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_HTML(
    l_dbid    => (SELECT dbid FROM v$database),
    l_inst_num => 1,
    l_bid     => 100,   -- begin snap_id
    l_eid     => 110    -- end snap_id
));

-- SQL-level AWR report for a specific statement
SELECT output FROM TABLE(DBMS_WORKLOAD_REPOSITORY.AWR_SQL_REPORT_HTML(
    l_dbid     => (SELECT dbid FROM v$database),
    l_inst_num => 1,
    l_bid      => 100,
    l_eid      => 110,
    l_sqlid    => 'abc123def'
));
```

### Oracle Key Plan Operations

| Operation | Description |
|---|---|
| TABLE ACCESS FULL | Full table scan |
| TABLE ACCESS BY INDEX ROWID | Fetches row via ROWID from index |
| TABLE ACCESS BY INDEX ROWID BATCHED | Batched ROWID fetches (12c+) |
| INDEX UNIQUE SCAN | Single-row index lookup |
| INDEX RANGE SCAN | Multi-row index lookup |
| INDEX FAST FULL SCAN | Reads entire index like a table (multiblock I/O) |
| INDEX SKIP SCAN | Skips leading column of composite index |
| NESTED LOOPS | Nested loop join |
| HASH JOIN | Hash join |
| MERGE JOIN | Sort-merge join |
| SORT ORDER BY | Explicit sort for ORDER BY |
| HASH GROUP BY | Hashing for GROUP BY |
| PARTITION RANGE (SINGLE/ITERATOR/ALL) | Partition pruning indicator |

---

## 5. Common Plan Anti-Patterns Across All Platforms

### Full Table Scans on Large Tables

**Symptoms:**
- PostgreSQL: `Seq Scan` on a table with millions of rows
- MySQL: `type = ALL` in EXPLAIN
- SQL Server: `Table Scan` or `Clustered Index Scan` with high logical reads
- Oracle: `TABLE ACCESS FULL` with high consistent gets

**Fixes:**
```sql
-- Add an index on the filtered column(s)
CREATE INDEX idx_orders_customer ON orders (customer_id);

-- For function-based filters, create an expression index
-- PostgreSQL:
CREATE INDEX idx_orders_year ON orders (EXTRACT(YEAR FROM created_at));
-- MySQL:
ALTER TABLE orders ADD COLUMN created_year SMALLINT GENERATED ALWAYS AS (YEAR(created_at)) STORED;
CREATE INDEX idx_orders_year ON orders (created_year);
-- Oracle:
CREATE INDEX idx_orders_year ON orders (EXTRACT(YEAR FROM order_date));
```

### Nested Loops on Large Datasets

**Symptoms:** Nested loop join with millions of rows in the outer input; each iteration does an index lookup on the inner table, resulting in millions of random I/O operations.

**Fixes:**
```sql
-- Ensure join columns are indexed
CREATE INDEX idx_order_items_order ON order_items (order_id);

-- If both tables are large, a hash join or merge join is usually better
-- PostgreSQL: increase work_mem to avoid hash spills
SET work_mem = '256MB';

-- MySQL: ensure optimizer considers hash join (8.0.18+)
SELECT /*+ HASH_JOIN(oi) */ o.*, oi.product_id
FROM orders o JOIN order_items oi ON o.id = oi.order_id;

-- SQL Server: use a hash join hint if optimizer chooses wrong
SELECT o.*, oi.product_id
FROM orders o INNER HASH JOIN order_items oi ON o.id = oi.order_id;
```

### Sort Operations Without Supporting Indexes

**Symptoms:** `Sort` node in PostgreSQL, `Using filesort` in MySQL, `Sort` operator in SQL Server, `SORT ORDER BY` in Oracle. Especially expensive when the data spills to disk (temp files).

**Fixes:**
```sql
-- Create an index that matches the ORDER BY clause
CREATE INDEX idx_orders_date_desc ON orders (created_at DESC);

-- For composite ORDER BY:
CREATE INDEX idx_orders_cust_date ON orders (customer_id, created_at DESC);

-- Then queries like this avoid a sort entirely:
SELECT * FROM orders WHERE customer_id = 42 ORDER BY created_at DESC LIMIT 20;
```

### Hash Joins with Memory Spills to Disk

**Symptoms:**
- PostgreSQL: `Buffers: temp read=NNN temp written=NNN` in EXPLAIN BUFFERS output
- MySQL: disk-based temporary tables in Performance Schema
- SQL Server: Sort/Hash warnings in execution plan XML
- Oracle: `TEMP SPACE USED` in V$SQL_PLAN_STATISTICS_ALL

**Fixes:**
```sql
-- PostgreSQL: increase work_mem for the session
SET work_mem = '512MB';

-- SQL Server: increase max memory grant per query
-- Or use Resource Governor to manage memory grants

-- All platforms: reduce the data volume entering the join
-- Filter earlier, project fewer columns, use covering indexes
SELECT o.id, o.total, c.name    -- not SELECT *
FROM orders o
JOIN customers c ON o.customer_id = c.id
WHERE o.created_at > '2024-01-01';  -- filter narrows the hash table
```

### Key Lookups / Table Access by ROWID After Index Scan

**Symptoms:**
- SQL Server: `Key Lookup (Clustered)` or `RID Lookup`
- Oracle: `TABLE ACCESS BY INDEX ROWID`
- PostgreSQL: `Index Scan` followed by heap fetches (not `Index Only Scan`)
- MySQL: No `Using index` in Extra (needs to go back to clustered index)

Each key lookup is a random I/O operation. When the index scan returns many rows, the cost of lookups may exceed a full table scan.

**Fixes:**
```sql
-- Create a covering index that includes all needed columns

-- SQL Server: use INCLUDE
CREATE NONCLUSTERED INDEX idx_orders_covering
ON orders (customer_id) INCLUDE (status, total, created_at);

-- PostgreSQL: use INCLUDE
CREATE INDEX idx_orders_covering ON orders (customer_id)
INCLUDE (status, total, created_at);

-- MySQL: add extra columns to the index (no INCLUDE syntax)
CREATE INDEX idx_orders_covering ON orders (customer_id, status, total, created_at);

-- Oracle: create a composite index or use invisible columns for testing
CREATE INDEX idx_orders_covering ON orders (customer_id, status, total, order_date);
```

---

## 6. Cost Estimates vs Actual Execution

### How the Optimizer Estimates Cost

All databases use a **cost-based optimizer (CBO)** that estimates the cost of different execution plans and picks the cheapest one. Cost is a weighted combination of:

- **I/O cost**: Pages/blocks that must be read
- **CPU cost**: Rows to process, comparisons, hashing, sorting
- **Memory cost**: Work area for sorts, hash tables
- **Network cost**: (for distributed queries) data transfer between nodes

### When Estimates Go Wrong

1. **Stale statistics**: The optimizer uses statistics (histograms, cardinality estimates) that no longer reflect the actual data distribution.
2. **Correlated columns**: Two columns are statistically correlated but the optimizer assumes independence.
3. **Skewed data**: A single value accounts for most rows, but the histogram does not capture this.
4. **Complex predicates**: Functions, OR conditions, LIKE with wildcards, and parameterized queries can confuse the optimizer.

---

## 7. Join Order Optimization

The optimizer decides which table to access first and which join algorithm to use. For N tables, there are N! possible join orders.

### How Each Database Handles Join Ordering

| Database | Strategy | Limit |
|---|---|---|
| PostgreSQL | Dynamic programming for <= `join_collapse_limit` tables (default: 8); GEQO above that | Configurable |
| MySQL | Greedy search + exhaustive for small queries (`optimizer_search_depth`) | Default depth = 62 |
| SQL Server | Transformation-based optimizer; uses memo structure | Automatic; falls back to heuristics for complex queries |
| Oracle | Cost-based with cardinality feedback; adaptive plans (12c+) | Automatic |

### Influencing Join Order

```sql
-- PostgreSQL: set join_collapse_limit to control optimizer behavior
SET join_collapse_limit = 1;  -- forces join order as written in FROM clause

-- MySQL: STRAIGHT_JOIN
SELECT STRAIGHT_JOIN o.*, c.name
FROM small_table s
JOIN large_table l ON s.id = l.small_id;

-- SQL Server: OPTION (FORCE ORDER)
SELECT o.*, c.CompanyName
FROM Orders o JOIN Customers c ON o.CustomerID = c.CustomerID
OPTION (FORCE ORDER);

-- Oracle: LEADING hint
SELECT /*+ LEADING(o c) */ o.*, c.customer_name
FROM orders o JOIN customers c ON o.customer_id = c.customer_id;
```

---

## 8. Cardinality Estimation Errors and How to Fix Them

Cardinality estimation errors are the #1 cause of bad query plans. When the optimizer thinks a step will return 10 rows but it actually returns 100,000, it may choose a nested loop join instead of a hash join.

### Detecting Cardinality Errors

In any EXPLAIN ANALYZE output, compare estimated rows vs actual rows at each node. A ratio > 10x is a red flag.

### Fixing Stale Statistics

```sql
-- PostgreSQL
ANALYZE orders;                            -- update stats for one table
ANALYZE;                                   -- update stats for all tables
ALTER TABLE orders ALTER COLUMN status SET STATISTICS 1000;  -- increase sample size
ANALYZE orders;

-- MySQL
ANALYZE TABLE orders;                      -- update InnoDB stats
SET GLOBAL innodb_stats_persistent_sample_pages = 200;  -- increase sample

-- SQL Server
UPDATE STATISTICS orders WITH FULLSCAN;    -- exact stats (slower)
UPDATE STATISTICS orders WITH SAMPLE 50 PERCENT;

-- Oracle
EXEC DBMS_STATS.GATHER_TABLE_STATS('SCHEMA', 'ORDERS', estimate_percent => 100);
```

### Creating Histograms

Histograms help the optimizer understand data distribution for skewed columns.

```sql
-- PostgreSQL: histograms are created automatically by ANALYZE
-- Increase resolution:
ALTER TABLE orders ALTER COLUMN status SET STATISTICS 1000;
ANALYZE orders;

-- MySQL 8.0: explicit histogram creation
ANALYZE TABLE orders UPDATE HISTOGRAM ON status WITH 100 BUCKETS;
ANALYZE TABLE orders UPDATE HISTOGRAM ON region, customer_type WITH 50 BUCKETS;
-- Drop a histogram
ANALYZE TABLE orders DROP HISTOGRAM ON status;

-- SQL Server: filtered statistics or full-scan statistics
CREATE STATISTICS stat_orders_status ON orders (status) WITH FULLSCAN;

-- Oracle: histograms via DBMS_STATS
EXEC DBMS_STATS.GATHER_TABLE_STATS('SCHEMA', 'ORDERS',
    method_opt => 'FOR COLUMNS SIZE 254 status region');
```

### Multi-Column Statistics (for Correlated Columns)

```sql
-- PostgreSQL 10+: extended statistics
CREATE STATISTICS orders_status_region (dependencies, ndistinct, mcv)
ON status, region FROM orders;
ANALYZE orders;

-- SQL Server: multi-column statistics
CREATE STATISTICS stat_orders_status_region ON orders (status, region) WITH FULLSCAN;

-- Oracle: column group statistics
SELECT DBMS_STATS.CREATE_EXTENDED_STATS('SCHEMA', 'ORDERS', '(STATUS, REGION)') FROM DUAL;
EXEC DBMS_STATS.GATHER_TABLE_STATS('SCHEMA', 'ORDERS');

-- MySQL: no multi-column histogram support as of 8.0; use composite indexes
-- or restructure queries to help the optimizer.
```

### Adaptive Query Execution

Some databases can adjust the plan during execution based on actual cardinalities:

- **Oracle 12c+ Adaptive Plans**: The optimizer builds multiple sub-plans and chooses at runtime based on actual cardinalities.
- **SQL Server Adaptive Joins (2017+)**: Switches between nested loops and hash join at runtime.
- **SQL Server Interleaved Execution (2017+)**: Materializes multi-statement TVFs first to get accurate row counts.
- **PostgreSQL**: No adaptive execution yet, but `pg_hint_plan` extension and parameterized path support help.
- **MySQL**: Limited; histogram improvements in 8.0 reduce misestimates.

---

## SQLite: EXPLAIN QUERY PLAN

SQLite uses a simpler query planner but provides `EXPLAIN QUERY PLAN` for understanding scan strategy:

```sql
-- Basic query plan
EXPLAIN QUERY PLAN
SELECT * FROM users WHERE email = 'user@example.com';

-- Join query plan
EXPLAIN QUERY PLAN
SELECT u.name, o.total
FROM users u
JOIN orders o ON u.id = o.user_id
WHERE u.status = 'active';
```

### Key Output Terms

| Term | Meaning |
|------|---------|
| `SCAN table` | Full table scan (no index used) |
| `SEARCH table USING INDEX idx` | Index lookup (good) |
| `SEARCH table USING COVERING INDEX idx` | Index-only scan, no table access (best) |
| `SEARCH table USING INTEGER PRIMARY KEY` | Rowid lookup (fastest single-row access) |
| `USE TEMP B-TREE FOR ORDER BY` | Sort required (no index covers the ORDER BY) |
| `USE TEMP B-TREE FOR DISTINCT` | Dedup via temp sort |
| `USE TEMP B-TREE FOR GROUP BY` | Grouping via temp sort |
| `COMPOUND SUBQUERIES` | UNION/INTERSECT/EXCEPT processing |

### Optimization Targets

```sql
-- Bad: Full table scan
-- EXPLAIN output: SCAN users
SELECT * FROM users WHERE LOWER(email) = 'test@example.com';

-- Good: Index scan
-- EXPLAIN output: SEARCH users USING INDEX idx_users_email (email=?)
CREATE INDEX idx_users_email ON users(email);
SELECT * FROM users WHERE email = 'test@example.com';

-- Best: Covering index (no table access)
-- EXPLAIN output: SEARCH users USING COVERING INDEX idx_users_email_name (email=?)
CREATE INDEX idx_users_email_name ON users(email, name);
SELECT name FROM users WHERE email = 'test@example.com';
```

### SQLite-Specific Notes

- SQLite has **no parallel query execution** -- all queries run single-threaded
- The query planner makes decisions at **prepare time** (not execution time) -- no adaptive execution
- Use `ANALYZE` to update statistics: `ANALYZE;` or `ANALYZE table_name;`
- Statistics are stored in `sqlite_stat1` and `sqlite_stat4` tables
- SQLite automatically chooses between index scan and table scan based on estimated selectivity
- For complex queries, SQLite may use **automatic indexes** (temp indexes created for a single query) -- visible as `AUTOMATIC COVERING INDEX` in EXPLAIN output
