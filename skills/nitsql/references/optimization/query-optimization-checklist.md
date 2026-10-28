# Query Optimization Checklist

A step-by-step guide for systematically optimizing SQL queries. Work through each phase in order; stop when performance meets requirements.

---

## Phase 1: Measure and Understand

Before changing anything, establish a baseline.

### 1.1 Capture Current Performance

- [ ] Record the query text exactly as it runs in production
- [ ] Measure execution time (multiple runs to account for cache effects)
- [ ] Note the data volume: how many rows in each involved table?
- [ ] Identify how often the query runs (once/day vs 1000/sec makes a big difference)

### 1.2 Read the Execution Plan

- [ ] Run `EXPLAIN ANALYZE` (PostgreSQL), `EXPLAIN ANALYZE` (MySQL 8.0.18+), or enable Actual Execution Plan (SQL Server)

- [ ] Identify the most expensive node/operator:
  - Which step takes the longest wall-clock time?
  - Which step processes the most rows?
  - Which step has the highest I/O?

- [ ] Check for cardinality estimation errors:
  - Compare estimated rows vs actual rows at each step
  - A 10x+ difference indicates stale statistics or correlated columns

- [ ] Look for these red flags:
  - [ ] Full table scan on a large table
  - [ ] `Using filesort` or `Sort` on large data sets
  - [ ] `Using temporary` or disk-based temp tables
  - [ ] Nested loop joins on large inputs
  - [ ] Key lookups / bookmark lookups with high row counts
  - [ ] Hash join spills to disk (temp read/write in buffers output)

### 1.3 Check Table and Index Statistics

- [ ] Ensure statistics are up to date:
  ```sql
  -- PostgreSQL
  ANALYZE table_name;
  -- MySQL
  ANALYZE TABLE table_name;
  -- SQL Server
  UPDATE STATISTICS table_name WITH FULLSCAN;
  ```
- [ ] Re-run the EXPLAIN after updating statistics (the plan may improve on its own)

---

## Phase 2: Query Rewriting

Fix the SQL itself before reaching for indexes or configuration changes.

### 2.1 Select Only Needed Columns

- [ ] Replace `SELECT *` with explicit column names
- [ ] This enables covering indexes and reduces I/O, memory, and network transfer

```sql
-- Before
SELECT * FROM orders WHERE customer_id = 42;

-- After
SELECT id, status, total, created_at FROM orders WHERE customer_id = 42;
```

### 2.2 Filter Early, Filter Precisely

- [ ] Push filters as close to the base tables as possible
- [ ] Avoid filtering in the application when the database can do it
- [ ] Use the most selective conditions first

```sql
-- Before: filter after join
SELECT o.id, c.name
FROM orders o
JOIN customers c ON o.customer_id = c.id
WHERE YEAR(o.created_at) = 2024;

-- After: sargable filter, filter before join in subquery if helpful
SELECT o.id, c.name
FROM orders o
JOIN customers c ON o.customer_id = c.id
WHERE o.created_at >= '2024-01-01' AND o.created_at < '2025-01-01';
```

### 2.3 Make Predicates Sargable

A predicate is **sargable** (Search ARGument ABLE) if the optimizer can use an index to satisfy it. Non-sargable predicates prevent index usage.

- [ ] Remove functions from the left side of WHERE comparisons:

```sql
-- Non-sargable (index on created_at is useless)
WHERE YEAR(created_at) = 2024
WHERE DATE(created_at) = '2024-06-15'
WHERE LOWER(email) = 'user@example.com'
WHERE amount + tax > 100

-- Sargable equivalents
WHERE created_at >= '2024-01-01' AND created_at < '2025-01-01'
WHERE created_at >= '2024-06-15' AND created_at < '2024-06-16'
WHERE email = 'user@example.com'  -- (normalize data at write time)
WHERE amount > 100 - tax           -- (or redesign schema)
```

### 2.4 Optimize JOINs

- [ ] Ensure join columns have matching data types (no implicit conversions)
- [ ] Ensure join columns are indexed
- [ ] Replace correlated subqueries with JOINs where possible:

```sql
-- Before: correlated subquery (executes once per outer row)
SELECT u.name,
       (SELECT COUNT(*) FROM orders o WHERE o.user_id = u.id) AS order_count
FROM users u;

-- After: LEFT JOIN with GROUP BY
SELECT u.name, COUNT(o.id) AS order_count
FROM users u
LEFT JOIN orders o ON o.user_id = u.id
GROUP BY u.id, u.name;
```

### 2.5 Optimize Subqueries

- [ ] Replace `IN (SELECT ...)` with `EXISTS (SELECT 1 ...)` for large subqueries
- [ ] Replace `NOT IN (SELECT ...)` with `NOT EXISTS` (also avoids NULL pitfalls)

```sql
-- Before (may materialize full subquery result)
SELECT * FROM customers
WHERE id IN (SELECT customer_id FROM orders WHERE total > 1000);

-- After (semi-join, stops at first match per row)
SELECT * FROM customers c
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id AND o.total > 1000);
```

### 2.6 Optimize Pagination

- [ ] Replace large OFFSET with cursor-based (keyset) pagination:

```sql
-- Before: OFFSET grows linearly worse
SELECT * FROM products ORDER BY id LIMIT 20 OFFSET 100000;

-- After: keyset pagination (instant regardless of page depth)
SELECT * FROM products WHERE id > 100000 ORDER BY id LIMIT 20;

-- For multi-column sorts:
SELECT * FROM products
WHERE (created_at, id) < ('2024-06-15 10:30:00', 50000)
ORDER BY created_at DESC, id DESC
LIMIT 20;
```

### 2.7 Optimize Aggregations

- [ ] Use approximate counts when exact counts are not needed:

```sql
-- PostgreSQL: fast approximate row count
SELECT reltuples::bigint FROM pg_class WHERE relname = 'orders';

-- HyperLogLog extensions for approximate distinct counts
```

- [ ] Pre-aggregate with materialized views or summary tables for dashboards
- [ ] Filter before grouping (WHERE before GROUP BY, not HAVING for non-aggregate filters)

### 2.8 Eliminate N+1 Query Patterns

- [ ] Identify loops that execute a query per iteration
- [ ] Replace with batch queries using `IN (...)` or JOINs

```sql
-- N+1 pattern (in application code):
-- for each user: SELECT * FROM orders WHERE user_id = ?

-- Batch replacement:
SELECT * FROM orders WHERE user_id IN (1, 2, 3, 4, 5, ...);
```

---

## Phase 3: Indexing

Add or modify indexes to support the optimized query.

### 3.1 Add Missing Indexes

- [ ] Identify unindexed columns used in WHERE, JOIN ON, and ORDER BY
- [ ] Create indexes following the column order rules:
  1. Equality columns first
  2. Range columns next
  3. ORDER BY columns last
- [ ] Consider covering indexes to eliminate table lookups

### 3.2 Review Existing Indexes

- [ ] Check if existing indexes are being used
- [ ] Remove unused or duplicate indexes to reduce write overhead
- [ ] Consolidate overlapping indexes where possible

### 3.3 Re-run EXPLAIN After Indexing

- [ ] Verify the new index is used in the execution plan
- [ ] Measure the new execution time
- [ ] Confirm write performance has not degraded unacceptably

---

## Phase 4: Schema and Architecture

If query rewriting and indexing are not enough, consider structural changes.

### 4.1 Denormalization

- [ ] Add redundant columns to avoid expensive JOINs (trade write complexity for read speed)
- [ ] Use materialized views for pre-computed aggregations
- [ ] Add summary/cache tables for dashboard queries

### 4.2 Partitioning

- [ ] Partition large tables by date range (most common) or other natural key
- [ ] Verify partition pruning is working in EXPLAIN output
- [ ] Benefits: faster queries on recent data, faster partition drops vs DELETE, parallel scans

### 4.3 Data Type Optimization

- [ ] Use the smallest data type that fits the data:
  - `SMALLINT` (2 bytes) vs `INT` (4 bytes) vs `BIGINT` (8 bytes)
  - `VARCHAR(100)` instead of `VARCHAR(MAX)` / `TEXT` for short strings
  - `DATE` instead of `TIMESTAMP` if time is not needed
  - `NUMERIC(10,2)` instead of `FLOAT` for money
- [ ] Smaller data types = more rows per page = fewer I/O operations = faster

### 4.4 Vertical Partitioning (Table Splitting)

- [ ] Split wide tables: keep hot, frequently-accessed columns in one table and rarely-accessed large columns (BLOB, TEXT) in another
- [ ] Join on the primary key when the large columns are needed

---

## Phase 5: Server Configuration

Tune the database engine for the workload.

### 5.1 Memory

- [ ] **PostgreSQL:** `shared_buffers` = 25% of RAM; `effective_cache_size` = 75% of RAM; `work_mem` = tune per query complexity
- [ ] **MySQL:** `innodb_buffer_pool_size` = 70-80% of RAM on dedicated server
- [ ] **SQL Server:** `max server memory` = total RAM minus OS needs (2-4 GB)

### 5.2 Parallelism

- [ ] **PostgreSQL:** `max_parallel_workers_per_gather` (default 2, increase for analytical workloads)
- [ ] **SQL Server:** `max degree of parallelism` and `cost threshold for parallelism`
- [ ] **MySQL:** `innodb_parallel_read_threads` (MySQL 8.0.14+)

### 5.3 Connection Pooling

- [ ] Use PgBouncer (PostgreSQL), ProxySQL (MySQL), or built-in pooling (SQL Server, Oracle)
- [ ] Set pool sizes appropriately: too few = queuing, too many = resource contention

### 5.4 Caching

- [ ] Application-level caching (Redis, Memcached) for frequently-read, rarely-changed data
- [ ] HTTP caching for API responses backed by slow queries
- [ ] Result-set caching in Oracle (server-side result cache)

---

## Phase 6: Ongoing Monitoring

Performance optimization is not a one-time event.

### 6.1 Set Up Slow Query Monitoring

- [ ] **PostgreSQL:** Install `pg_stat_statements` and query it regularly
- [ ] **MySQL:** Enable slow query log (`long_query_time = 0.5`)
- [ ] **SQL Server:** Enable Query Store
- [ ] **Oracle:** AWR reports, `V$SQL`

### 6.2 Establish Performance Baselines

- [ ] Record P50, P95, P99 query latencies
- [ ] Track total query time consumed per query pattern
- [ ] Set alerts for queries exceeding thresholds

### 6.3 Review After Data Growth

- [ ] Re-evaluate indexes and partitioning when table sizes double
- [ ] Re-run EXPLAIN on critical queries quarterly
- [ ] Check for new slow queries after application changes

### 6.4 Automation

- [ ] Schedule automatic statistics updates (autovacuum in PostgreSQL, auto stats in SQL Server)
- [ ] Schedule index maintenance (reorganize/rebuild) during off-peak hours
- [ ] Automate partition creation for time-based partitions
- [ ] Set up alerts for unused indexes, missing indexes, and high fragmentation

---

## Quick Reference: Optimization Priority Order

For most queries, this is the order of highest-impact to lowest-impact optimization actions:

1. **Fix the query** (sargable predicates, proper JOINs, remove N+1)
2. **Add/fix indexes** (the right index can change a query from minutes to milliseconds)
3. **Update statistics** (stale stats cause bad plans)
4. **Increase memory** (larger buffer pool, more work_mem)
5. **Schema changes** (partitioning, denormalization)
6. **Application caching** (avoid hitting the database at all)
7. **Hardware / scaling** (last resort)
