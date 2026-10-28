# PostgreSQL — Dialect Reference

## Version Features

Feature availability below is a floor: assume unstated behavior needs verifying against your actual server version (`SELECT version();`), especially for anything not listed here.

### PostgreSQL 10
- **Declarative partitioning**: `PARTITION BY RANGE (...)` / `PARTITION BY LIST (...)` — native partitioning without the old trigger-and-inheritance workaround. HASH partitioning was not yet available (11+).
- **Identity columns**: `GENERATED ALWAYS/BY DEFAULT AS IDENTITY` — the SQL-standard alternative to `SERIAL` (see Identity and Sequences below)
- **Logical replication**: built-in `PUBLICATION`/`SUBSCRIPTION`

### PostgreSQL 11
- **Hash partitioning**: `PARTITION BY HASH (...)` added alongside RANGE/LIST
- **Partitioned tables gain**: `PRIMARY KEY`/`FOREIGN KEY` constraints, default partitions (`PARTITION ... DEFAULT`), `UPDATE` that moves a row between partitions
- **Covering indexes**: `CREATE INDEX ... INCLUDE (col1, col2)` (see Indexing below)
- **Stored procedures**: `CREATE PROCEDURE` / `CALL`, which can manage their own transactions (`COMMIT`/`ROLLBACK`) — functions still cannot
- **Parallel hash join** and parallel `CREATE INDEX` for B-tree indexes

### PostgreSQL 12
- **Generated columns**: `GENERATED ALWAYS AS (expression) STORED` (see Generated Columns below). PostgreSQL only supports `STORED`, not `VIRTUAL`, generated columns.
- **`REINDEX CONCURRENTLY`**: rebuild an index without holding an exclusive lock for the whole duration (see Indexing below)
- **Partition pruning at execution time**: prepared statements and partitioned tables referenced via parameters now prune correctly at runtime, not just at plan time

### PostgreSQL 13
- **Incremental sorting**: Leverages existing sort order for multi-column sorts
- **Parallel vacuum**: VACUUM can use multiple workers for index cleanup
- **B-tree deduplication**: Reduces index size for columns with many duplicates
- **Partitioning improvements**: Row-level BEFORE triggers on partitioned tables

### PostgreSQL 14
- **Multirange types**: `int4multirange`, `tsmultirange` for discontinuous ranges
- **JSON subscripting**: `jsonb_col['key']` instead of `jsonb_col->'key'`
- **DISTINCT in GROUP BY aggregates**: `SELECT array_agg(DISTINCT col) ...`
- **Connection pipeline mode**: Batch multiple queries to reduce round trips (libpq)

### PostgreSQL 15
- **MERGE statement**: Standard SQL MERGE with MATCHED/NOT MATCHED clauses
- **JSON_TABLE** (limited): Extract JSON into relational rows
- **Public schema permissions revoked by default**: Must explicitly `GRANT CREATE ON SCHEMA public`
- **Security invoker views**: Views execute with caller's permissions

### PostgreSQL 16
- **Logical replication from standby**: Replicate from read replicas
- **Parallel FULL OUTER JOIN**: Improved parallel query support
- **SQL/JSON path improvements**: Enhanced JSON querying
- **pg_stat_io**: New view for I/O statistics

## Function and Procedure Templates

### Function (Returns Result Set)
```sql
CREATE OR REPLACE FUNCTION app.get_customer_orders(
    p_customer_id INTEGER,
    p_status TEXT DEFAULT 'active'
) RETURNS TABLE (
    order_id INTEGER,
    order_date TIMESTAMPTZ,
    total_amount NUMERIC(12,2)
) AS $$
BEGIN
    RETURN QUERY
    SELECT o.order_id, o.order_date, o.total_amount
    FROM app.orders o
    WHERE o.customer_id = p_customer_id
      AND o.status = p_status
    ORDER BY o.order_date DESC;

    -- Check if any rows were returned
    IF NOT FOUND THEN
        RAISE NOTICE 'No orders found for customer %', p_customer_id;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;  -- STABLE = does not modify database
```

### Function (Returns Scalar)
```sql
CREATE OR REPLACE FUNCTION app.calculate_order_total(
    p_order_id INTEGER
) RETURNS NUMERIC(12,2) AS $$
DECLARE
    v_total NUMERIC(12,2);
BEGIN
    SELECT SUM(quantity * unit_price)
    INTO STRICT v_total
    FROM app.order_items
    WHERE order_id = p_order_id;

    RETURN v_total;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 0.00;
    WHEN TOO_MANY_ROWS THEN
        RAISE EXCEPTION 'Unexpected multiple totals for order %', p_order_id;
END;
$$ LANGUAGE plpgsql STABLE;
```

### Procedure (PG 11+, Can Manage Transactions)
```sql
CREATE OR REPLACE PROCEDURE app.process_batch_orders(
    p_batch_size INTEGER DEFAULT 100
) LANGUAGE plpgsql AS $$
DECLARE
    v_processed INTEGER := 0;
    v_order RECORD;
BEGIN
    FOR v_order IN
        SELECT order_id FROM app.pending_orders
        ORDER BY created_at
        LIMIT p_batch_size
        FOR UPDATE SKIP LOCKED
    LOOP
        UPDATE app.orders SET status = 'processing' WHERE order_id = v_order.order_id;
        v_processed := v_processed + 1;

        -- Commit every 10 rows to avoid long-running transactions
        IF v_processed % 10 = 0 THEN
            COMMIT;
        END IF;
    END LOOP;

    COMMIT;
    RAISE NOTICE 'Processed % orders', v_processed;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END;
$$;

-- Call: CALL app.process_batch_orders(500);
```

## Parameter Syntax

### PL/pgSQL Positional
```sql
-- $1, $2 positional (older style, still valid in SQL functions)
CREATE FUNCTION app.get_user(INTEGER) RETURNS TEXT AS $$
    SELECT name FROM app.users WHERE user_id = $1;
$$ LANGUAGE sql;
```

### psycopg2 (Python)
```python
# Positional with %s (NEVER use f-strings or string formatting)
cursor.execute(
    "SELECT user_id, name FROM users WHERE user_id = %s AND status = %s",
    (user_id, 'active')
)

# Named with %(name)s
cursor.execute(
    "SELECT * FROM users WHERE user_id = %(id)s AND status = %(status)s",
    {'id': user_id, 'status': 'active'}
)
```

### psycopg3 (Python)
```python
# Positional with %s (client-side binding)
cursor.execute("SELECT * FROM users WHERE user_id = %s", (user_id,))

# Server-side binding with $1 (preferred for performance)
cursor.execute("SELECT * FROM users WHERE user_id = $1", (user_id,))
```

### node-postgres (pg)
```javascript
// Positional with $1, $2
const result = await pool.query(
    'SELECT user_id, name FROM users WHERE user_id = $1 AND status = $2',
    [userId, 'active']
);
```

### SQLAlchemy
```python
from sqlalchemy import text
with engine.connect() as conn:
    result = conn.execute(
        text("SELECT * FROM users WHERE user_id = :id AND status = :status"),
        {"id": user_id, "status": "active"}
    )
```

### Npgsql (.NET)
```csharp
using var cmd = new NpgsqlCommand("SELECT * FROM users WHERE user_id = @id", conn);
cmd.Parameters.AddWithValue("@id", userId);
```

## Identity and Sequences

### GENERATED AS IDENTITY (Preferred, SQL Standard)
```sql
CREATE TABLE app.orders (
    order_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id INTEGER NOT NULL,
    order_date TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- GENERATED ALWAYS prevents manual ID insertion (use OVERRIDING SYSTEM VALUE to override)
-- GENERATED BY DEFAULT allows manual ID insertion
```

### SERIAL (Legacy, Still Common)
```sql
-- SERIAL is syntactic sugar for creating a sequence + setting default
CREATE TABLE app.legacy_orders (
    order_id SERIAL PRIMARY KEY,  -- Creates sequence: legacy_orders_order_id_seq
    customer_id INTEGER NOT NULL
);
-- Avoid SERIAL in new code — IDENTITY is standard and simpler to manage
```

### RETURNING Clause (No SCOPE_IDENTITY Needed)
```sql
-- Get generated ID immediately after INSERT
INSERT INTO app.orders (customer_id, order_date)
VALUES (42, NOW())
RETURNING order_id;

-- Return multiple columns
INSERT INTO app.orders (customer_id, order_date)
VALUES (42, NOW())
RETURNING order_id, order_date, created_at;

-- Use in CTEs
WITH new_order AS (
    INSERT INTO app.orders (customer_id) VALUES (42)
    RETURNING order_id
)
INSERT INTO app.order_items (order_id, product_id, quantity)
SELECT order_id, 101, 5 FROM new_order;
```

### Sequences
```sql
CREATE SEQUENCE app.invoice_number_seq
    START WITH 10000
    INCREMENT BY 1
    NO CYCLE
    CACHE 20;

-- Use in INSERT
INSERT INTO app.invoices (invoice_number, order_id)
VALUES (nextval('app.invoice_number_seq'), 42);

-- Check current value (only after nextval in same session)
SELECT currval('app.invoice_number_seq');
```

### Generated Columns (12+)
```sql
-- STORED generated columns require PostgreSQL 12+. PostgreSQL has no VIRTUAL
-- generated column option (unlike MySQL/Oracle/SQLite) -- STORED is the only kind.
CREATE TABLE app.order_items (
    order_item_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    quantity INTEGER NOT NULL,
    unit_price NUMERIC(12,2) NOT NULL,
    line_total NUMERIC(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED
);

-- Generated columns can be indexed like any other stored column
CREATE INDEX idx_order_items_line_total ON app.order_items (line_total);

-- Cannot reference another generated column, a subquery, or a non-immutable function
-- BAD: NOW() is not immutable
-- expires_at TIMESTAMPTZ GENERATED ALWAYS AS (created_at + NOW()) STORED
```

## MERGE (15+)
```sql
-- MERGE requires PostgreSQL 15+. On 14 and earlier, use INSERT ... ON CONFLICT
-- DO UPDATE (single-table upsert) or an explicit PL/pgSQL UPDATE-then-INSERT for
-- multi-condition merges -- there is no MERGE statement before 15.
MERGE INTO app.inventory AS tgt
USING (SELECT 42 AS product_id, 100 AS quantity) AS src
ON tgt.product_id = src.product_id
WHEN MATCHED AND src.quantity = 0 THEN
    DELETE
WHEN MATCHED THEN
    UPDATE SET quantity = src.quantity
WHEN NOT MATCHED THEN
    INSERT (product_id, quantity) VALUES (src.product_id, src.quantity);

-- Pre-15 equivalent for the common MATCHED/NOT MATCHED case (no conditional DELETE branch):
INSERT INTO app.inventory (product_id, quantity) VALUES (42, 100)
ON CONFLICT (product_id) DO UPDATE SET quantity = EXCLUDED.quantity;
```

## Error Handling

### EXCEPTION Block
```sql
CREATE OR REPLACE FUNCTION app.safe_insert_user(
    p_email TEXT,
    p_name TEXT
) RETURNS INTEGER AS $$
DECLARE
    v_user_id INTEGER;
BEGIN
    INSERT INTO app.users (email, name)
    VALUES (p_email, p_name)
    RETURNING user_id INTO v_user_id;

    RETURN v_user_id;
EXCEPTION
    WHEN unique_violation THEN
        -- Email already exists, return existing user ID
        SELECT user_id INTO v_user_id FROM app.users WHERE email = p_email;
        RETURN v_user_id;
    WHEN check_violation THEN
        RAISE EXCEPTION 'Invalid data: %', SQLERRM;
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'Referenced entity does not exist';
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Unexpected error in safe_insert_user: % (SQLSTATE: %)', SQLERRM, SQLSTATE;
END;
$$ LANGUAGE plpgsql;
```

### GET STACKED DIAGNOSTICS
```sql
EXCEPTION
    WHEN OTHERS THEN
        DECLARE
            v_message TEXT;
            v_detail TEXT;
            v_hint TEXT;
            v_context TEXT;
        BEGIN
            GET STACKED DIAGNOSTICS
                v_message = MESSAGE_TEXT,
                v_detail = PG_EXCEPTION_DETAIL,
                v_hint = PG_EXCEPTION_HINT,
                v_context = PG_EXCEPTION_CONTEXT;

            RAISE WARNING 'Error: %, Detail: %, Hint: %, Context: %',
                v_message, v_detail, v_hint, v_context;
            RAISE;  -- Re-throw
        END;
```

### RAISE Levels
```sql
RAISE DEBUG 'Debugging info: %', v_var;       -- Only shows with client_min_messages=debug
RAISE NOTICE 'Info: processing row %', v_id;  -- Informational
RAISE WARNING 'Possible issue: %', v_msg;      -- Warning
RAISE EXCEPTION 'Fatal: %', v_msg;             -- Aborts current transaction
```

## Transaction Handling

### Standard Transaction
```sql
BEGIN;

INSERT INTO app.orders (customer_id) VALUES (42);
INSERT INTO app.order_items (order_id, product_id, quantity) VALUES (currval('orders_order_id_seq'), 101, 5);

COMMIT;
-- If any statement fails, entire transaction is aborted (no partial state)
```

### Savepoints
```sql
BEGIN;

INSERT INTO app.orders (customer_id) VALUES (42);

SAVEPOINT before_items;

INSERT INTO app.order_items (order_id, product_id, quantity) VALUES (1, 101, 5);
-- If this fails:
ROLLBACK TO SAVEPOINT before_items;
-- Order header is preserved, can retry items

COMMIT;
```

### Procedures vs Functions Transaction Behavior
```sql
-- PROCEDURES (PG 11+): CAN commit/rollback within
CREATE PROCEDURE app.batch_process() LANGUAGE plpgsql AS $$
BEGIN
    -- ... work ...
    COMMIT;  -- This is valid in a procedure
    -- ... more work ...
    COMMIT;
END;
$$;

-- FUNCTIONS: CANNOT commit/rollback (run within caller's transaction)
-- Any COMMIT/ROLLBACK in a function raises an error
```

### Advisory Locks (Application-Level Locking)
```sql
-- Acquire advisory lock (blocks if held by another session)
SELECT pg_advisory_lock(hashtext('process_orders'));

-- ... do work ...

-- Release
SELECT pg_advisory_unlock(hashtext('process_orders'));

-- Try without blocking (returns true/false)
SELECT pg_try_advisory_lock(hashtext('process_orders'));
```

## Indexing

### B-tree (Default)
```sql
-- Standard index
CREATE INDEX idx_orders_customer_id ON app.orders (customer_id);

-- Covering index with INCLUDE (PG 11+)
CREATE INDEX idx_orders_customer_date ON app.orders (customer_id)
    INCLUDE (order_date, total_amount);

-- Multi-column with sort order
CREATE INDEX idx_orders_date_amount ON app.orders (order_date DESC, total_amount ASC);
```

### Partial Index (Filtered)
```sql
-- Only index active orders — much smaller and faster
CREATE INDEX idx_orders_active ON app.orders (customer_id, order_date)
    WHERE status = 'active';

-- Only index non-null emails
CREATE INDEX idx_users_email ON app.users (email)
    WHERE email IS NOT NULL;
```

### NULLS NOT DISTINCT (15+)
```sql
-- Before PostgreSQL 15: a UNIQUE index/constraint treats NULL as distinct from
-- every other NULL, so multiple NULL values are always allowed -- there was no
-- way to say "at most one NULL" through the constraint itself.

-- PostgreSQL 15+: opt in to SQL-standard NULLS NOT DISTINCT behavior
CREATE UNIQUE INDEX idx_users_backup_email ON app.users (backup_email) NULLS NOT DISTINCT;
-- Now a second row with backup_email IS NULL violates uniqueness (only one NULL allowed)

-- Also works on UNIQUE table constraints (15+):
ALTER TABLE app.users ADD CONSTRAINT uq_users_backup_email UNIQUE NULLS NOT DISTINCT (backup_email);

-- Pre-15 workaround: a partial unique index that only indexes the NULL case
CREATE UNIQUE INDEX idx_users_backup_email_null ON app.users ((backup_email IS NULL)) WHERE backup_email IS NULL;
```

### Expression Index
```sql
-- Index on lowercase email for case-insensitive lookups
CREATE INDEX idx_users_email_lower ON app.users (LOWER(email));

-- Query must match the expression:
SELECT * FROM app.users WHERE LOWER(email) = LOWER('User@Example.com');
```

### GIN Index (Full-Text, JSONB, Arrays)
```sql
-- Full-text search
CREATE INDEX idx_articles_search ON app.articles USING GIN (to_tsvector('english', title || ' ' || body));

-- JSONB containment queries
CREATE INDEX idx_products_attrs ON app.products USING GIN (attributes jsonb_path_ops);
-- Query: SELECT * FROM app.products WHERE attributes @> '{"color": "red"}';

-- Array overlap/containment
CREATE INDEX idx_posts_tags ON app.posts USING GIN (tags);
-- Query: SELECT * FROM app.posts WHERE tags @> ARRAY['postgresql'];
```

### GiST Index (Geometry, Ranges)
```sql
-- Range types (e.g., booking periods)
CREATE INDEX idx_bookings_period ON app.bookings USING GiST (tstzrange(check_in, check_out));

-- PostGIS geometry
CREATE INDEX idx_locations_geom ON app.locations USING GiST (geom);
```

### BRIN Index (Large Sequential Tables)
```sql
-- Very small index for naturally ordered large tables (e.g., time-series)
CREATE INDEX idx_events_time ON app.events USING BRIN (event_time);
-- Only useful when physical row order correlates with column values
```

### Concurrent Index Creation (No Locks)
```sql
-- Does not block reads or writes (but takes longer and more resources)
CREATE INDEX CONCURRENTLY idx_orders_status ON app.orders (status);

-- CONCURRENTLY cannot run inside a transaction block
-- If it fails, it leaves an INVALID index that must be dropped and recreated
```
Caveats:
- `CREATE INDEX CONCURRENTLY` has been available since PostgreSQL 8.2 — it is not a recent addition, but its failure mode still catches people: on failure it leaves an `INVALID` index rather than rolling back. Check `pg_index.indisvalid` and `DROP INDEX` + retry rather than assuming the failed run cleaned up after itself.
- `REINDEX CONCURRENTLY` (rebuild an existing index without the exclusive lock `REINDEX` normally takes) requires **PostgreSQL 12+**. Before 12, the only lock-free rebuild path was `CREATE INDEX CONCURRENTLY` under a new name, swap, then `DROP INDEX CONCURRENTLY` (13+ for the drop variant — see below) or a plain `DROP INDEX` on the old one.
- `DROP INDEX CONCURRENTLY` requires **PostgreSQL 9.6+**.
- On a partitioned table (10+), neither `CREATE INDEX CONCURRENTLY` nor `REINDEX CONCURRENTLY` can be run directly on the parent in one step in most versions — build/rebuild the index on each partition individually (or via `CREATE INDEX ... ON ONLY` on the parent followed by per-partition `CREATE INDEX CONCURRENTLY` and `ATTACH PARTITION`). Verify the exact supported syntax for your version before scripting this.

## Declarative Partitioning (10+)

### Minimum Version by Capability
| Capability | Minimum Version |
|------------|-----------------|
| `PARTITION BY RANGE` / `PARTITION BY LIST` | 10 |
| `PARTITION BY HASH` | 11 |
| `PRIMARY KEY` / `FOREIGN KEY` on a partitioned table | 11 |
| Default partition (`PARTITION ... DEFAULT`) | 11 |
| `UPDATE` that moves a row across partitions | 11 |
| Runtime partition pruning for parameterized/prepared queries | 12 |
| Row-level `BEFORE` triggers on partitioned tables | 13 |
| Logical replication targeting a partitioned table on the subscriber | 13 |

If you are not sure which version introduced a specific partitioning behavior beyond what's listed here, verify against your target version's release notes rather than assuming — partitioning was one of the most actively developed areas of PostgreSQL across the 10-13 release cycle.

### Basic Range Partitioning
```sql
-- PostgreSQL 10+
CREATE TABLE app.events (
    event_id BIGINT GENERATED ALWAYS AS IDENTITY,
    event_time TIMESTAMPTZ NOT NULL,
    payload JSONB,
    PRIMARY KEY (event_id, event_time)   -- the partition key column(s) must be included in any PRIMARY KEY/UNIQUE constraint on a partitioned table
) PARTITION BY RANGE (event_time);

CREATE TABLE app.events_2026_01 PARTITION OF app.events
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');

CREATE TABLE app.events_2026_02 PARTITION OF app.events
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');

-- BAD (pre-11 mental model): assuming a global PRIMARY KEY on just event_id works
-- GOOD: partition key is part of the key, or use a UNIQUE index per partition instead
```

### Default Partition (11+)
```sql
-- Catches rows that don't match any explicit partition -- prevents silent INSERT failures
CREATE TABLE app.events_default PARTITION OF app.events DEFAULT;
```
```sql
-- Full analysis with buffer information
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT o.order_id, o.order_date, c.name
FROM app.orders o
JOIN app.customers c ON o.customer_id = c.customer_id
WHERE o.order_date > NOW() - INTERVAL '30 days';
```

### pg_stat_statements (Top Queries)
```sql
-- Enable in postgresql.conf: shared_preload_libraries = 'pg_stat_statements'
-- (requires a server restart -- this cannot be set with a simple reload)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Top queries by total time (PostgreSQL 13+ column names)
SELECT
    calls,
    round(total_exec_time::numeric, 2) AS total_ms,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 2) AS pct,
    left(query, 100) AS query_preview
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```
Version note: `pg_stat_statements` itself has been bundled as a contrib extension for a very long time and is available on every currently-supported PostgreSQL version. What changed is its column names: **PostgreSQL 13** split `total_time`/`mean_time` into separate planning and execution figures — `total_exec_time`/`mean_exec_time` (execution only) plus new `total_plan_time`/`mean_plan_time`. On PostgreSQL 12 and earlier, use `total_time` and `mean_time` instead — the query above will fail with "column does not exist" on those versions. If you don't know which version you're targeting, check `\d pg_stat_statements` first rather than guessing the column set.

### auto_explain (Log Slow Query Plans)
```sql
-- In postgresql.conf:
-- shared_preload_libraries = 'auto_explain'
-- auto_explain.log_min_duration = '1s'
-- auto_explain.log_analyze = true
-- auto_explain.log_buffers = true
-- auto_explain.log_format = 'json'
```

### Table Statistics
```sql
-- Tables with high sequential scan counts (may need indexes)
SELECT
    schemaname, relname,
    seq_scan, idx_scan,
    n_live_tup, n_dead_tup,
    round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
    last_vacuum, last_autovacuum, last_analyze
FROM pg_stat_user_tables
WHERE seq_scan > 100
ORDER BY seq_scan DESC;
```

### Vacuum and Analyze
```sql
-- Manual vacuum + analyze for a specific table
VACUUM ANALYZE app.orders;

-- Full vacuum (rewrites table, requires exclusive lock — use sparingly)
VACUUM FULL app.orders;

-- Autovacuum tuning for high-churn tables
ALTER TABLE app.orders SET (
    autovacuum_vacuum_scale_factor = 0.05,   -- vacuum at 5% dead tuples (default 20%)
    autovacuum_analyze_scale_factor = 0.02    -- analyze at 2% changed (default 10%)
);
```

## Configuration

### Memory Settings
```sql
-- shared_buffers: 25% of total RAM (e.g., 4GB for 16GB system)
-- effective_cache_size: 50-75% of total RAM (hint to planner, not allocation)
-- work_mem: per-operation sort/hash memory (careful: multiplied by parallel workers)
--   Start at 16-64MB, increase for analytics workloads
-- maintenance_work_mem: for VACUUM, CREATE INDEX (512MB-1GB)

-- Check current settings
SHOW shared_buffers;
SHOW work_mem;
SHOW effective_cache_size;
```

### Parallelism
```sql
-- max_parallel_workers_per_gather: 2-4 for OLTP, more for analytics
-- parallel_tuple_cost / parallel_setup_cost: lower to encourage parallelism
SHOW max_parallel_workers_per_gather;
```
What a given plan node can actually parallelize is version-dependent -- if `EXPLAIN` isn't showing a `Gather`/`Gather Merge` node where you expect one, confirm the operation is supported as parallel on your version before tuning cost parameters further:
- Parallel sequential scan and parallel aggregate: PostgreSQL 9.6+ (the baseline for parallel query existing at all)
- Parallel index scan, parallel index-only scan, parallel bitmap heap scan, parallel merge join: 10+
- Parallel hash join, parallel `CREATE INDEX` for B-tree: 11+
- Parallel `VACUUM` (index cleanup phase): 13+
- Parallel `FULL OUTER JOIN`: 16+
- Plain `INSERT`/`UPDATE`/`DELETE`: the write itself is never parallelized (only the leader process writes) -- `CREATE TABLE AS`/`SELECT INTO` can still parallelize the underlying `SELECT`'s scan/join/aggregate work, it's the row-writing step that stays single-process

### Storage / I/O
```sql
-- random_page_cost: 1.1 for SSD (default 4.0 is for HDD)
-- effective_io_concurrency: 200 for SSD (default 1)
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;
SELECT pg_reload_conf();
```

## Security Features

### Row-Level Security (RLS)
```sql
-- Enable RLS on table
ALTER TABLE app.orders ENABLE ROW LEVEL SECURITY;

-- Policy: users can only see their own orders
CREATE POLICY orders_tenant_isolation ON app.orders
    USING (tenant_id = current_setting('app.current_tenant')::INTEGER);

-- Policy: admins can see all
CREATE POLICY orders_admin_access ON app.orders
    TO admin_role
    USING (true);

-- Set tenant context in application
SET app.current_tenant = '42';

-- Force RLS even for table owner (default: owner bypasses)
ALTER TABLE app.orders FORCE ROW LEVEL SECURITY;
```

### Column Encryption (pgcrypto)
```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Encrypt on insert
INSERT INTO app.sensitive_data (user_id, ssn_encrypted)
VALUES (42, pgp_sym_encrypt('123-45-6789', 'encryption-key'));

-- Decrypt on select
SELECT user_id, pgp_sym_decrypt(ssn_encrypted, 'encryption-key') AS ssn
FROM app.sensitive_data WHERE user_id = 42;
```

### SSL/TLS Configuration
```python
# psycopg2 with SSL
conn = psycopg2.connect(
    host="db.example.com",
    dbname="mydb",
    user="appuser",
    password="secret",
    sslmode="verify-full",
    sslrootcert="/path/to/ca.crt"
)
```

### Roles and Permissions
```sql
-- Create role hierarchy
CREATE ROLE app_readonly;
CREATE ROLE app_readwrite;
CREATE ROLE app_admin;

GRANT USAGE ON SCHEMA app TO app_readonly, app_readwrite, app_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO app_readonly;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app TO app_readwrite;
GRANT ALL PRIVILEGES ON SCHEMA app TO app_admin;

-- Apply to future tables too
ALTER DEFAULT PRIVILEGES IN SCHEMA app
    GRANT SELECT ON TABLES TO app_readonly;

-- Create login user with role
CREATE USER appuser WITH PASSWORD 'secret' LOGIN;
GRANT app_readwrite TO appuser;
```

## Monitoring

### Active Queries
```sql
SELECT
    pid, usename, datname, state,
    now() - query_start AS duration,
    wait_event_type, wait_event,
    left(query, 100) AS query_preview
FROM pg_stat_activity
WHERE state != 'idle'
  AND pid != pg_backend_pid()
ORDER BY duration DESC;
```

### Lock Analysis
```sql
SELECT
    blocked_locks.pid AS blocked_pid,
    blocked_activity.usename AS blocked_user,
    blocking_locks.pid AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    blocked_activity.query AS blocked_query,
    blocking_activity.query AS blocking_query
FROM pg_catalog.pg_locks blocked_locks
JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_locks.pid = blocked_activity.pid
JOIN pg_catalog.pg_locks blocking_locks ON blocked_locks.locktype = blocking_locks.locktype
    AND blocked_locks.relation = blocking_locks.relation
    AND blocked_locks.pid != blocking_locks.pid
JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_locks.pid = blocking_activity.pid
WHERE NOT blocked_locks.granted;
```

### Index Usage
```sql
SELECT
    schemaname, relname AS table_name,
    indexrelname AS index_name,
    idx_scan, idx_tup_read, idx_tup_fetch,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC;  -- Least used indexes first (candidates for removal)
```

### Slow Query Logging
```sql
-- In postgresql.conf:
-- log_min_duration_statement = 1000   -- Log queries taking > 1 second
-- log_statement = 'none'              -- Don't log all statements (noisy)
-- log_line_prefix = '%m [%p] %u@%d '
```

## Detection Markers

| Marker Type | Pattern |
|-------------|---------|
| **Dollar quoting** | `$$ ... $$`, `$func$ ... $func$`, `DO $$ ... $$` |
| **Type casting** | `::integer`, `::text`, `::timestamptz`, `::jsonb` |
| **RETURNING clause** | `INSERT ... RETURNING id`, `UPDATE ... RETURNING *` |
| **Case-insensitive match** | `ILIKE`, `~*` (regex, case-insensitive) |
| **Regex operators** | `~`, `~*`, `!~`, `!~*` |
| **Array syntax** | `ARRAY[1,2,3]`, `'{1,2,3}'::int[]`, `ANY(ARRAY[...])` |
| **JSONB operators** | `->>`, `->`, `@>`, `?`, `#>`, `jsonb_path_query()` |
| **System catalog** | `pg_catalog.*`, `pg_stat_*`, `pg_` prefix on system tables |
| **Function language** | `LANGUAGE plpgsql`, `LANGUAGE sql` |
| **Identity** | `SERIAL`, `GENERATED ALWAYS AS IDENTITY` |
| **Data types** | `TEXT` (no length limit), `JSONB`, `UUID`, `TIMESTAMPTZ`, `BOOLEAN` |
| **Connection drivers** | psycopg2, asyncpg, pg (node), Npgsql (.NET) |
| **Utilities** | `psql`, `pg_dump`, `pg_restore` |
| **String concat** | `||` operator (not `+`) |
| **Boolean literals** | `TRUE` / `FALSE` (not 1/0) |
