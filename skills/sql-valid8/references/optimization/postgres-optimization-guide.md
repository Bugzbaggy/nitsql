# PostgreSQL Optimization Guide

A comprehensive reference for PostgreSQL-specific performance tuning, covering query analysis, indexing, storage internals, and server configuration.

---

## 1. EXPLAIN ANALYZE Output Interpretation

### Basic Usage

```sql
-- Estimated plan only (does NOT execute the query)
EXPLAIN SELECT * FROM orders WHERE customer_id = 42;

-- Actual execution with timing and row counts
EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = 42;

-- Full diagnostic output: timing, buffers, WAL, and JSON format
EXPLAIN (ANALYZE, BUFFERS, TIMING, FORMAT JSON)
SELECT * FROM orders WHERE customer_id = 42;

-- Include WAL generation stats (useful for write queries in a transaction you ROLLBACK)
BEGIN;
EXPLAIN (ANALYZE, BUFFERS, WAL)
UPDATE orders SET status = 'shipped' WHERE id = 100;
ROLLBACK;
```

### Key Fields in EXPLAIN ANALYZE Output

| Field | Meaning |
|---|---|
| `cost=0.42..8.44` | Startup cost .. total cost (in arbitrary planner units) |
| `rows=1` | Estimated number of rows returned by this node |
| `actual time=0.019..0.021` | Actual wall-clock time in milliseconds (startup..total) |
| `actual rows=1` | Actual number of rows returned |
| `loops=1` | Number of times this node was executed |
| `Buffers: shared hit=4` | Pages found in buffer cache (no disk I/O) |
| `Buffers: shared read=12` | Pages read from disk (or OS cache) |
| `Buffers: shared dirtied=2` | Pages modified in this operation |
| `Buffers: shared written=0` | Pages flushed to disk during this operation |

### Diagnosing Cardinality Estimation Errors

When `rows` (estimated) differs significantly from `actual rows`, the planner may choose a suboptimal plan.

```sql
-- Compare estimated vs actual
EXPLAIN ANALYZE
SELECT * FROM orders
WHERE status = 'pending' AND region = 'APAC';
```

If you see `rows=10` but `actual rows=50000`, the planner underestimates selectivity. Fixes:

```sql
-- Update table statistics
ANALYZE orders;

-- Create multi-column statistics for correlated columns
CREATE STATISTICS orders_status_region (dependencies, ndistinct, mcv)
ON status, region FROM orders;
ANALYZE orders;

-- Increase statistics target for specific columns
ALTER TABLE orders ALTER COLUMN status SET STATISTICS 1000;
ALTER TABLE orders ALTER COLUMN region SET STATISTICS 1000;
ANALYZE orders;
```

---

## 2. PostgreSQL Index Types

### B-tree (Default)

Best for: equality (`=`), range (`<`, `>`, `BETWEEN`), sorting (`ORDER BY`), and `IS NULL` checks.

```sql
CREATE INDEX idx_orders_created_at ON orders (created_at);

-- Multi-column B-tree (leftmost prefix rule applies)
CREATE INDEX idx_orders_cust_date ON orders (customer_id, created_at DESC);

-- Covering index with INCLUDE (avoids heap fetches for index-only scans)
CREATE INDEX idx_orders_cust_covering ON orders (customer_id)
INCLUDE (status, total_amount);
```

### Hash

Best for: exact equality (`=`) only. Smaller than B-tree for high-cardinality equality lookups. WAL-logged since PostgreSQL 10.

```sql
CREATE INDEX idx_sessions_token ON sessions USING HASH (session_token);
```

**Limitations:** No range queries, no sorting, no multi-column support.

### GIN (Generalized Inverted Index)

Best for: full-text search, arrays, JSONB containment, trigram similarity.

```sql
-- Full-text search
CREATE INDEX idx_articles_fts ON articles
USING GIN (to_tsvector('english', title || ' ' || body));

-- JSONB containment (@>, ?, ?|, ?&)
CREATE INDEX idx_events_meta ON events USING GIN (metadata);

-- JSONB path ops (only supports @>, smaller index)
CREATE INDEX idx_events_meta_pathops ON events
USING GIN (metadata jsonb_path_ops);

-- Array containment
CREATE INDEX idx_tags ON posts USING GIN (tags);

-- Trigram similarity (requires pg_trgm extension)
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_users_name_trgm ON users USING GIN (name gin_trgm_ops);
```

**Trade-off:** Slower to build and update than B-tree; excellent for read-heavy workloads with multi-valued columns.

### GiST (Generalized Search Tree)

Best for: geometric data, range types, full-text search (with ranking), nearest-neighbor queries.

```sql
-- Geometric / PostGIS
CREATE INDEX idx_locations_geom ON locations USING GIST (geom);

-- Range type (e.g., date ranges for availability)
CREATE INDEX idx_reservations_during ON reservations USING GIST (during);

-- Exclusion constraint using GiST
ALTER TABLE reservations ADD CONSTRAINT no_overlap
EXCLUDE USING GIST (room_id WITH =, during WITH &&);

-- Full-text search (supports ranking, unlike GIN)
CREATE INDEX idx_docs_fts_gist ON documents USING GIST (tsv);
```

### BRIN (Block Range Index)

Best for: very large tables where the indexed column is naturally correlated with physical row order (e.g., timestamps on append-only tables). Extremely small index size.

```sql
-- Ideal for time-series or log tables
CREATE INDEX idx_logs_created_brin ON logs USING BRIN (created_at)
WITH (pages_per_range = 32);

-- Check correlation (should be close to 1.0 or -1.0 for BRIN to help)
SELECT attname, correlation
FROM pg_stats
WHERE tablename = 'logs' AND attname = 'created_at';
```

**Trade-off:** BRIN indexes are tiny but less precise -- they eliminate block ranges, not individual rows. Best when correlation > 0.9.

### SP-GiST (Space-Partitioned GiST)

Best for: data that can be partitioned into non-overlapping regions -- IP addresses, phone numbers, quadtrees, k-d trees.

```sql
-- IP address range lookups
CREATE INDEX idx_ip_blocks ON ip_blocks USING SPGIST (ip_range);

-- Text prefix matching (e.g., phone number prefix routing)
CREATE INDEX idx_phones_prefix ON phone_numbers USING SPGIST (number text_ops);
```

---

## 3. HOT Updates and Fillfactor Tuning

### Heap-Only Tuples (HOT)

PostgreSQL's HOT optimization avoids creating new index entries when an UPDATE modifies only non-indexed columns **and** the new tuple fits on the same page.

```sql
-- Check HOT update ratio for a table
SELECT relname,
       n_tup_upd,
       n_tup_hot_upd,
       CASE WHEN n_tup_upd > 0
            THEN round(100.0 * n_tup_hot_upd / n_tup_upd, 1)
            ELSE 0
       END AS hot_update_pct
FROM pg_stat_user_tables
WHERE relname = 'orders';
```

### Fillfactor

Lowering fillfactor reserves space on each page for future HOT updates.

```sql
-- Set fillfactor to 80% (20% reserved for updates)
ALTER TABLE orders SET (fillfactor = 80);

-- Rewrite the table to apply the new fillfactor
VACUUM FULL orders;
-- Or use pg_repack for online rewrite:
-- pg_repack --table orders --no-superuser-check -d mydb

-- Recommended fillfactor values:
--   100 (default): append-only / read-heavy tables
--   80-90: tables with frequent updates to non-indexed columns
--   70-80: tables with very frequent updates
```

---

## 4. TOAST Storage and Large Values

TOAST (The Oversized-Attribute Storage Technique) handles values larger than about 2 KB by compressing and/or moving them out-of-line.

### Storage Strategies

| Strategy | Behavior |
|---|---|
| `PLAIN` | No compression, no out-of-line storage (fixed-length types) |
| `EXTENDED` | Compress first, then move out-of-line if still too large (default for variable-length) |
| `EXTERNAL` | Move out-of-line without compression (fast access to large values) |
| `MAIN` | Compress but try to keep in-line (out-of-line only as last resort) |

```sql
-- Check current TOAST strategy for columns
SELECT attname, attstorage
FROM pg_attribute
WHERE attrelid = 'documents'::regclass AND attnum > 0;

-- Change strategy (e.g., skip compression for already-compressed data like images)
ALTER TABLE documents ALTER COLUMN pdf_data SET STORAGE EXTERNAL;

-- Check TOAST table size
SELECT pg_size_pretty(pg_total_relation_size('documents')) AS total,
       pg_size_pretty(pg_relation_size('documents')) AS main,
       pg_size_pretty(
           pg_total_relation_size('documents') - pg_relation_size('documents')
       ) AS toast_and_indexes;
```

### Performance Implications

- Accessing TOAST-ed values requires extra I/O; avoid `SELECT *` on tables with large columns.
- If you rarely read a large column, it being in TOAST is beneficial -- queries that skip that column never touch TOAST pages.
- For full-text search on large text, store the `tsvector` separately and index it rather than repeatedly de-TOASTing the source text.

---

## 5. Parallel Query Configuration

### Key Parameters

```sql
-- Maximum workers that can be assigned to a single Gather node
SET max_parallel_workers_per_gather = 4;  -- default: 2

-- Total parallel workers available system-wide
-- (should not exceed max_worker_processes)
ALTER SYSTEM SET max_parallel_workers = 8;

-- Planner cost thresholds for parallel plans
SET parallel_setup_cost = 1000;        -- default: 1000
SET parallel_tuple_cost = 0.1;         -- default: 0.1

-- Minimum table size before considering parallel seq scan
SET min_parallel_table_scan_size = '8MB';   -- default: 8MB

-- Minimum index size before considering parallel index scan
SET min_parallel_index_scan_size = '512kB'; -- default: 512kB
```

### Operations That Support Parallelism

- Sequential scans
- Index scans and bitmap heap scans (PostgreSQL 12+)
- Hash joins, nested loop joins, merge joins
- Aggregates (partial aggregate + finalize aggregate)
- Append (for partitioned tables)
- `CREATE INDEX` (with `max_parallel_maintenance_workers`)

### When Parallel Queries Do NOT Help

- Very small tables (overhead exceeds benefit)
- Queries that return very large result sets (tuple transfer cost)
- Write operations (INSERT/UPDATE/DELETE) -- only the SELECT portion can be parallel
- Functions marked `PARALLEL UNSAFE`
- Queries inside serializable transactions (depending on version)

```sql
-- Force a specific table to use more parallel workers
ALTER TABLE large_events SET (parallel_workers = 8);

-- Speed up index creation with parallel workers
SET max_parallel_maintenance_workers = 4;
CREATE INDEX CONCURRENTLY idx_events_ts ON events (created_at);
```

---

## 6. JIT Compilation

PostgreSQL 11+ includes LLVM-based JIT compilation for expression evaluation, tuple deforming, and aggregation.

```sql
-- Enable/disable JIT
SET jit = on;  -- default: on (PostgreSQL 12+)

-- Cost thresholds (JIT is only used if query cost exceeds these)
SET jit_above_cost = 100000;              -- enable JIT
SET jit_inline_above_cost = 500000;       -- enable function inlining
SET jit_optimize_above_cost = 500000;     -- enable LLVM optimization passes

-- Check if a query uses JIT
EXPLAIN (ANALYZE, VERBOSE)
SELECT sum(amount) FROM large_transactions WHERE created_at > '2024-01-01';
-- Look for "JIT:" section in output
```

**When JIT helps:** Long-running analytical queries scanning millions of rows.
**When JIT hurts:** Short OLTP queries -- the compilation overhead exceeds the execution time savings. Lower `jit_above_cost` only for analytical workloads.

---

## 7. Autovacuum Tuning for High-Write Tables

### Why Autovacuum Matters

- Reclaims dead tuples from UPDATE/DELETE operations
- Updates the visibility map (required for index-only scans)
- Prevents transaction ID wraparound (critical!)
- Updates planner statistics

### Global Settings

```sql
-- In postgresql.conf or ALTER SYSTEM
ALTER SYSTEM SET autovacuum_vacuum_cost_delay = '2ms';     -- default: 2ms (PG12+) / 20ms (older)
ALTER SYSTEM SET autovacuum_vacuum_cost_limit = 400;       -- default: -1 (uses vacuum_cost_limit = 200)
ALTER SYSTEM SET autovacuum_max_workers = 5;               -- default: 3
ALTER SYSTEM SET autovacuum_naptime = '30s';               -- default: 1min
```

### Per-Table Overrides for High-Write Tables

```sql
-- For a very active table: trigger vacuum sooner and be more aggressive
ALTER TABLE events SET (
    autovacuum_vacuum_scale_factor = 0.01,       -- default: 0.2 (20% dead tuples)
    autovacuum_vacuum_threshold = 1000,           -- default: 50
    autovacuum_analyze_scale_factor = 0.005,      -- default: 0.1
    autovacuum_analyze_threshold = 500,           -- default: 50
    autovacuum_vacuum_cost_delay = '0ms',         -- no throttling for this table
    autovacuum_vacuum_cost_limit = 1000           -- higher budget
);

-- For tables that should rarely be vacuumed (static lookup tables)
ALTER TABLE country_codes SET (
    autovacuum_vacuum_scale_factor = 0.5,
    autovacuum_analyze_scale_factor = 0.5
);
```

### Monitoring Autovacuum

```sql
-- Tables most in need of vacuuming
SELECT schemaname, relname,
       n_dead_tup,
       n_live_tup,
       CASE WHEN n_live_tup > 0
            THEN round(100.0 * n_dead_tup / n_live_tup, 1)
            ELSE 0
       END AS dead_pct,
       last_autovacuum,
       last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 20;

-- Currently running autovacuum processes
SELECT pid, datname, relid::regclass, phase, heap_blks_total, heap_blks_scanned, heap_blks_vacuumed
FROM pg_stat_progress_vacuum;

-- Check for transaction ID wraparound risk
SELECT datname,
       age(datfrozenxid) AS xid_age,
       current_setting('autovacuum_freeze_max_age')::bigint AS freeze_max_age,
       round(100.0 * age(datfrozenxid) /
             current_setting('autovacuum_freeze_max_age')::bigint, 1) AS pct_toward_wraparound
FROM pg_database
WHERE datallowconn
ORDER BY xid_age DESC;
```

---

## 8. Connection Pooling with PgBouncer

### Why Connection Pooling Is Essential

Each PostgreSQL connection consumes ~5-10 MB of RAM and a backend process. Beyond a few hundred connections, performance degrades due to context switching and lock contention. PgBouncer sits between the application and PostgreSQL, multiplexing many client connections onto fewer server connections.

### Pool Modes

| Mode | Behavior | Best For |
|---|---|---|
| **Transaction** | Connection returned to pool after each transaction | Most web applications (recommended default) |
| **Session** | Connection held for the entire client session | Apps using session-level features (LISTEN/NOTIFY, temp tables, prepared statements with named portals) |
| **Statement** | Connection returned after each statement | Simple autocommit workloads (rare) |

### Example PgBouncer Configuration

```ini
; pgbouncer.ini
[databases]
mydb = host=127.0.0.1 port=5432 dbname=mydb

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt

; Pool sizing
pool_mode = transaction
default_pool_size = 25           ; server connections per user/database pair
min_pool_size = 5                ; keep at least this many connections open
reserve_pool_size = 5            ; extra connections for burst traffic
reserve_pool_timeout = 3         ; seconds before using reserve pool

; Timeouts
server_idle_timeout = 300        ; close idle server connections after 5 min
client_idle_timeout = 0          ; 0 = no timeout for idle clients
query_timeout = 120              ; kill queries running longer than 2 min
client_login_timeout = 60

; Limits
max_client_conn = 1000           ; max simultaneous client connections
max_db_connections = 50          ; max server connections per database
```

### Prepared Statements in Transaction Mode

Transaction mode does not support named prepared statements natively. Solutions:

```ini
; Option 1: Use PgBouncer's prepared statement support (1.21+)
max_prepared_statements = 100

; Option 2: Use protocol-level prepared statements in your driver
; (e.g., prepareThreshold in JDBC, statement_cache_size in pgx)
```

### Monitoring PgBouncer

```sql
-- Connect to PgBouncer admin console
-- psql -p 6432 -U pgbouncer pgbouncer

SHOW POOLS;       -- active, waiting, and server connections per pool
SHOW CLIENTS;     -- all client connections
SHOW SERVERS;     -- all server connections
SHOW STATS;       -- request count, bytes, timing
SHOW DATABASES;   -- configured databases with pool sizes
```

---

## 9. pg_stat_statements: Identifying Slow Queries

### Setup

```sql
-- Add to postgresql.conf (requires restart)
-- shared_preload_libraries = 'pg_stat_statements'

-- Or create the extension (library must already be preloaded)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Configuration
ALTER SYSTEM SET pg_stat_statements.max = 10000;        -- max tracked statements
ALTER SYSTEM SET pg_stat_statements.track = 'top';      -- top | all | none
ALTER SYSTEM SET pg_stat_statements.track_utility = on;  -- track non-DML too
ALTER SYSTEM SET pg_stat_statements.track_planning = on; -- include planning time (PG13+)
```

### Top-N Slow Query Queries

```sql
-- Top 10 by average execution time
SELECT
    queryid,
    substr(query, 1, 100) AS query_preview,
    calls,
    round(mean_exec_time::numeric, 2) AS avg_ms,
    round(total_exec_time::numeric, 0) AS total_ms,
    rows,
    round((100.0 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 2) AS pct_of_total
FROM pg_stat_statements
WHERE calls > 10
ORDER BY mean_exec_time DESC
LIMIT 10;

-- Top 10 by total time consumed (highest overall resource usage)
SELECT
    queryid,
    substr(query, 1, 100) AS query_preview,
    calls,
    round(total_exec_time::numeric, 0) AS total_ms,
    round(mean_exec_time::numeric, 2) AS avg_ms,
    round(stddev_exec_time::numeric, 2) AS stddev_ms,
    rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- Queries with highest buffer usage (I/O intensive)
SELECT
    queryid,
    substr(query, 1, 100) AS query_preview,
    calls,
    shared_blks_hit + shared_blks_read AS total_buffers,
    round(
        100.0 * shared_blks_hit /
        NULLIF(shared_blks_hit + shared_blks_read, 0), 1
    ) AS cache_hit_pct,
    shared_blks_read AS disk_reads
FROM pg_stat_statements
WHERE shared_blks_read > 1000
ORDER BY shared_blks_read DESC
LIMIT 10;

-- Reset statistics periodically (e.g., after deployment)
SELECT pg_stat_statements_reset();
```

---

## 10. Partitioning Strategies

### Range Partitioning

Best for: time-series data, log tables, anything with a naturally ordered column.

```sql
CREATE TABLE events (
    id          bigint GENERATED ALWAYS AS IDENTITY,
    event_type  text NOT NULL,
    payload     jsonb,
    created_at  timestamptz NOT NULL
) PARTITION BY RANGE (created_at);

-- Create monthly partitions
CREATE TABLE events_2024_01 PARTITION OF events
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
CREATE TABLE events_2024_02 PARTITION OF events
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

-- Default partition catches everything else
CREATE TABLE events_default PARTITION OF events DEFAULT;

-- Automate partition creation with pg_partman
CREATE EXTENSION IF NOT EXISTS pg_partman;
SELECT partman.create_parent('public.events', 'created_at', 'native', 'monthly');
```

### List Partitioning

Best for: categorical data (region, status, tenant).

```sql
CREATE TABLE orders (
    id          bigint GENERATED ALWAYS AS IDENTITY,
    region      text NOT NULL,
    total       numeric(12,2),
    created_at  timestamptz NOT NULL
) PARTITION BY LIST (region);

CREATE TABLE orders_americas PARTITION OF orders FOR VALUES IN ('NA', 'SA');
CREATE TABLE orders_emea     PARTITION OF orders FOR VALUES IN ('EU', 'ME', 'AF');
CREATE TABLE orders_apac     PARTITION OF orders FOR VALUES IN ('AS', 'OC');
```

### Hash Partitioning

Best for: even distribution when there is no natural range or list key (e.g., partitioning by tenant_id for uniform load).

```sql
CREATE TABLE sessions (
    id          uuid PRIMARY KEY,
    user_id     bigint NOT NULL,
    data        jsonb,
    created_at  timestamptz
) PARTITION BY HASH (user_id);

CREATE TABLE sessions_p0 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE sessions_p1 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE sessions_p2 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE sessions_p3 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 3);
```

### Partition Pruning

```sql
-- Ensure partition pruning is enabled (it is by default)
SET enable_partition_pruning = on;

-- This query only scans events_2024_01
EXPLAIN ANALYZE
SELECT * FROM events WHERE created_at = '2024-01-15'::timestamptz;

-- Dynamic pruning works with parameters too (PG11+)
PREPARE q(timestamptz) AS SELECT * FROM events WHERE created_at = $1;
EXPLAIN ANALYZE EXECUTE q('2024-01-15');
```

---

## 11. Advisory Locks for Application-Level Concurrency

Advisory locks are cooperative locks that applications explicitly acquire and release. They do not lock any table or row -- they lock an arbitrary integer key.

### Session-Level Advisory Locks

```sql
-- Acquire (blocks until available)
SELECT pg_advisory_lock(12345);

-- Try to acquire (non-blocking, returns true/false)
SELECT pg_try_advisory_lock(12345);

-- Release
SELECT pg_advisory_unlock(12345);

-- Two-key variant (e.g., table OID + row ID)
SELECT pg_advisory_lock(42, 100);  -- lock "table 42, row 100"
```

### Transaction-Level Advisory Locks

Released automatically at end of transaction.

```sql
BEGIN;
SELECT pg_advisory_xact_lock(hashtext('process_order_' || '12345'));
-- ... do work ...
COMMIT;  -- lock released automatically
```

### Common Use Cases

```sql
-- 1. Prevent duplicate cron job execution
SELECT pg_try_advisory_lock(hashtext('daily_report_job'));
-- Returns false if another instance is already running

-- 2. Rate limiting per user
SELECT pg_try_advisory_lock(hashtext('rate_limit'), user_id);

-- 3. Ensuring exactly-once processing
SELECT pg_advisory_xact_lock(hashtext('process_event_' || event_id::text));

-- Check currently held advisory locks
SELECT * FROM pg_locks WHERE locktype = 'advisory';
```

---

## 12. CTE Materialization Control

PostgreSQL 12+ allows explicit control over whether a CTE is materialized (computed once) or inlined (folded into the outer query for optimization).

### MATERIALIZED

Forces the CTE to be computed once and stored in a temporary buffer. Useful as an optimization fence when you do NOT want the planner to push predicates into the CTE.

```sql
-- Force materialization: the CTE runs once regardless of outer filters
WITH active_users AS MATERIALIZED (
    SELECT id, name, email
    FROM users
    WHERE status = 'active'
)
SELECT * FROM active_users WHERE email LIKE '%@example.com';
```

### NOT MATERIALIZED

Allows the planner to inline the CTE, pushing down predicates and potentially choosing better join strategies.

```sql
-- Allow inlining: the planner can push the email filter into the CTE scan
WITH active_users AS NOT MATERIALIZED (
    SELECT id, name, email
    FROM users
    WHERE status = 'active'
)
SELECT * FROM active_users WHERE email LIKE '%@example.com';
-- The planner may combine both WHERE conditions into a single index scan
```

### When to Use Each

| Scenario | Recommendation |
|---|---|
| CTE referenced once | `NOT MATERIALIZED` (default in PG12+, allows inlining) |
| CTE referenced multiple times | `MATERIALIZED` (avoids recomputation) |
| CTE acts as an optimization fence (e.g., force a specific join order) | `MATERIALIZED` |
| CTE is simple and benefits from predicate pushdown | `NOT MATERIALIZED` |
| Recursive CTEs | Always materialized (cannot be inlined) |

```sql
-- Example: CTE referenced twice, materialize to avoid double computation
WITH monthly_totals AS MATERIALIZED (
    SELECT date_trunc('month', created_at) AS month,
           sum(amount) AS total
    FROM transactions
    WHERE created_at >= '2024-01-01'
    GROUP BY 1
)
SELECT m.month, m.total, m.total - lag(m.total) OVER (ORDER BY m.month) AS delta
FROM monthly_totals m
ORDER BY m.month;
```
