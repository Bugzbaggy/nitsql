# Index Strategy Checklist

A practical checklist for deciding when and how to create indexes. Use this before adding any index to your database.

---

## Before Creating an Index

### 1. Identify the Problem Query

- [ ] Run `EXPLAIN` / `EXPLAIN ANALYZE` on the slow query
- [ ] Note the current access method (full table scan, index scan, etc.)
- [ ] Record the estimated vs actual row counts
- [ ] Measure current execution time (baseline)
- [ ] Check if the query runs frequently (high-impact) or rarely (low-impact)

### 2. Evaluate Whether an Index Will Help

- [ ] Is the WHERE clause filtering on specific columns? (Index likely helps)
- [ ] Is the filtered column highly selective? (> 5% selectivity is the general threshold, but depends on data size)
- [ ] Is the query retrieving a small fraction of the table? (Index helps for < 10-15% of rows)
- [ ] Is the query a full aggregation or full table report? (Index may not help; a full scan might be optimal)
- [ ] Are there functions or casts on the column in WHERE? (Standard index will not help; expression index needed)

### 3. Check Existing Indexes

- [ ] List all current indexes on the table
- [ ] Check if an existing index already covers the needed columns
- [ ] Check if a composite index could be extended instead of creating a new one
- [ ] Verify that you are not creating a duplicate or overlapping index

---

## Choosing the Right Index Type

### Single-Column Index

Use when:
- Queries filter on a single column
- The column has moderate to high cardinality (many distinct values)

```sql
CREATE INDEX idx_users_email ON users (email);
```

### Composite (Multi-Column) Index

Use when:
- Queries filter on multiple columns together
- Queries filter on one column and sort by another

**Column order rules:**
1. Equality columns first (`WHERE status = 'active'`)
2. Range columns next (`WHERE created_at > '2024-01-01'`)
3. ORDER BY columns last (if compatible)

```sql
-- For: WHERE status = 'active' AND created_at > '2024-01-01' ORDER BY created_at
CREATE INDEX idx_orders_status_date ON orders (status, created_at);
```

- [ ] Verify the leftmost prefix rule: the index is useful for queries that filter on the first N columns (from left to right)
- [ ] Place the most selective column first among equality predicates

### Covering Index

Use when:
- The query needs only a few columns beyond the indexed columns
- Eliminating table/heap lookups would significantly reduce I/O

```sql
-- PostgreSQL / SQL Server: INCLUDE clause
CREATE INDEX idx_orders_cust ON orders (customer_id) INCLUDE (status, total);

-- MySQL: add extra columns to the composite index
CREATE INDEX idx_orders_cust ON orders (customer_id, status, total);
```

### Partial / Filtered Index

Use when:
- Queries always include the same fixed filter condition
- Only a subset of rows are frequently queried

```sql
-- PostgreSQL
CREATE INDEX idx_active_orders ON orders (customer_id, created_at)
WHERE status = 'active';

-- SQL Server
CREATE NONCLUSTERED INDEX idx_active_orders ON orders (customer_id, created_at)
WHERE status = 'active';
```

### Expression / Function-Based Index

Use when:
- Queries apply a function to a column in WHERE (e.g., `LOWER()`, `DATE()`)

```sql
-- PostgreSQL
CREATE INDEX idx_users_email_lower ON users (LOWER(email));

-- Oracle
CREATE INDEX idx_users_email_lower ON users (LOWER(email));

-- MySQL (use generated column)
ALTER TABLE users ADD COLUMN email_lower VARCHAR(255)
    GENERATED ALWAYS AS (LOWER(email)) STORED;
CREATE INDEX idx_users_email_lower ON users (email_lower);
```

### Specialized Index Types

| Type | When to Use | Platform |
|---|---|---|
| **GIN** | Full-text search, JSONB, arrays, trigram | PostgreSQL |
| **GiST** | Geometric data, range types, exclusion constraints | PostgreSQL |
| **BRIN** | Very large, naturally ordered tables (e.g., time-series) | PostgreSQL |
| **FULLTEXT** | Full-text search | MySQL, SQL Server |
| **Columnstore** | Analytical queries on large tables | SQL Server, Oracle |
| **Bitmap** | Low-cardinality columns in data warehouses | Oracle |
| **Hash** | Equality-only lookups (no range) | PostgreSQL |

---

## After Creating an Index

### Verify Effectiveness

- [ ] Re-run `EXPLAIN` / `EXPLAIN ANALYZE` on the target query
- [ ] Confirm the new index is being used (check `key` in MySQL, plan nodes in PostgreSQL, etc.)
- [ ] Measure new execution time and compare against baseline
- [ ] Check that other queries on the same table are not negatively affected

### Monitor Ongoing Usage

- [ ] Schedule a review of index usage statistics after 1-2 weeks:
  - PostgreSQL: `pg_stat_user_indexes.idx_scan`
  - MySQL: `sys.schema_unused_indexes`
  - SQL Server: `sys.dm_db_index_usage_stats`
  - Oracle: `DBA_INDEX_USAGE`
- [ ] If the index has zero scans after sufficient time, consider dropping it

### Assess Write Performance Impact

- [ ] Every index adds overhead to INSERT, UPDATE, and DELETE operations
- [ ] Monitor write latency after index creation
- [ ] Rule of thumb: 3-5 indexes per OLTP table is reasonable; more than 7-8 may hurt write performance
- [ ] For write-heavy tables, be especially conservative with indexing

---

## Index Maintenance

### Regular Tasks

- [ ] **Update statistics** regularly (or ensure autovacuum/auto-stats are configured):
  ```sql
  -- PostgreSQL
  ANALYZE table_name;
  -- MySQL
  ANALYZE TABLE table_name;
  -- SQL Server
  UPDATE STATISTICS table_name;
  -- Oracle
  EXEC DBMS_STATS.GATHER_TABLE_STATS('SCHEMA', 'TABLE_NAME');
  ```

- [ ] **Check for fragmentation** on a weekly/monthly basis:
  ```sql
  -- SQL Server
  SELECT avg_fragmentation_in_percent
  FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('table_name'), NULL, NULL, 'LIMITED');
  -- Reorganize if 10-30%, rebuild if > 30%

  -- Oracle
  ANALYZE INDEX idx_name VALIDATE STRUCTURE;
  SELECT height, lf_rows, del_lf_rows,
         ROUND(100 * del_lf_rows / NULLIF(lf_rows, 0), 1) AS pct_deleted
  FROM index_stats;
  ```

- [ ] **Review unused indexes** quarterly and drop them
- [ ] **Review duplicate/overlapping indexes** and consolidate

### When NOT to Create an Index

- The table is very small (< 1000 rows) -- a full scan is faster
- The column has very low cardinality (e.g., boolean, status with 2-3 values) on a non-partitioned table
- The table is write-heavy with infrequent reads
- The query retrieves a large percentage (> 15-20%) of the table rows
- An existing composite index already covers the needed columns
- The system is already I/O bound on writes

---

## Quick Decision Matrix

| Scenario | Recommended Action |
|---|---|
| `WHERE col = value` on high-cardinality column | Single-column B-tree index |
| `WHERE col1 = val AND col2 > val` | Composite index `(col1, col2)` |
| `WHERE col = val ORDER BY other_col LIMIT N` | Composite index `(col, other_col)` |
| `WHERE LOWER(col) = value` | Expression index on `LOWER(col)` |
| `WHERE col = val` but only for a common subset | Partial/filtered index |
| Query selects few columns from wide table | Covering index with INCLUDE |
| Full-text search | GIN (PostgreSQL), FULLTEXT (MySQL/SQL Server) |
| Large table, time-ordered, range queries | BRIN (PostgreSQL) or partitioning |
| Analytical aggregations on millions of rows | Columnstore (SQL Server/Oracle) |
| JSONB containment queries | GIN with `jsonb_path_ops` (PostgreSQL) |
