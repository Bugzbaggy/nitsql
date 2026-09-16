-- ==========================================================================
-- nitsql (example) - MySQL Index Health Check
-- Dialect: MySQL
-- Minimum version: MySQL 8.0+ (performance_schema required)
-- ==========================================================================
-- Run against your MySQL 8.0+ database.
-- Requires: SELECT privilege on information_schema, performance_schema, sys.
-- Note: performance_schema must be enabled (ON by default in MySQL 8.0+).
-- For other dialects, see:
--   check-indexes-mssql.sql
--   check-indexes-postgresql.sql
--   check-indexes-oracle.sql
-- ==========================================================================

-- ============================================================================
-- 1. TABLES WITHOUT PRIMARY KEYS
-- ============================================================================
-- What: InnoDB tables without a primary key use a hidden row ID as the
--       clustered index, which is suboptimal for performance and replication.
-- Look for: Any BASE TABLE results indicate tables needing a PK.
-- Remediation: ALTER TABLE <table> ADD PRIMARY KEY (<column>);
-- Note: Critical for InnoDB row-based replication (binlog_format=ROW).
-- ============================================================================

SELECT t.table_schema,
       t.table_name,
       t.engine,
       t.table_rows
FROM information_schema.tables t
LEFT JOIN information_schema.table_constraints tc
    ON t.table_schema = tc.table_schema
    AND t.table_name = tc.table_name
    AND tc.constraint_type = 'PRIMARY KEY'
WHERE t.table_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  AND t.table_type = 'BASE TABLE'
  AND tc.constraint_name IS NULL
ORDER BY t.table_rows DESC;

-- ============================================================================
-- 2. UNUSED INDEXES (Read count = 0 from performance_schema)
-- ============================================================================
-- What: Indexes that have never been used for reads but incur write overhead.
--       Based on performance_schema counters since last server restart.
-- Look for: Indexes with count_read = 0 but count_write > 0.
-- Remediation: Validate over a full business cycle, then:
--   ALTER TABLE <table> DROP INDEX <index>;
-- Note: Counters reset on server restart. Check uptime first:
--   SHOW GLOBAL STATUS LIKE 'Uptime';
-- ============================================================================

SELECT object_schema,
       object_name,
       index_name,
       count_star AS total_ops,
       count_read,
       count_write,
       count_fetch,
       count_insert,
       count_update,
       count_delete
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE index_name IS NOT NULL
  AND count_read = 0
  AND object_schema NOT IN ('mysql', 'performance_schema', 'sys')
ORDER BY count_write DESC;

-- ============================================================================
-- 3. REDUNDANT / DUPLICATE INDEXES (via sys schema)
-- ============================================================================
-- What: Identifies indexes that are fully redundant (left-prefix duplicates).
--       For example, INDEX(a,b) makes INDEX(a) redundant.
-- Look for: Any rows mean wasted space and write overhead.
-- Remediation: DROP INDEX <redundant_index> ON <table>;
-- Alternative: Use pt-duplicate-key-checker from Percona Toolkit.
-- Note: sys.schema_redundant_indexes requires the sys schema (MySQL 5.7+/8.0+).
-- ============================================================================

SELECT table_schema,
       table_name,
       redundant_index_name,
       redundant_index_columns,
       redundant_index_non_unique,
       dominant_index_name,
       dominant_index_columns,
       subpart_exists,
       sql_drop_index
FROM sys.schema_redundant_indexes
WHERE table_schema NOT IN ('mysql', 'performance_schema', 'sys')
ORDER BY table_schema, table_name;

-- ============================================================================
-- 4. FULL TABLE SCANS (Tables accessed without indexes)
-- ============================================================================
-- What: Tables being read entirely without any index. This is expensive for
--       large tables and indicates missing indexes on query predicates.
-- Look for: High count_read values on tables with many rows.
-- Remediation: Identify the queries with EXPLAIN and add appropriate indexes.
-- ============================================================================

SELECT object_schema,
       object_name,
       count_read AS full_scans,
       count_write,
       count_fetch,
       count_insert + count_update + count_delete AS total_dml
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE index_name IS NULL
  AND count_read > 100
  AND object_schema NOT IN ('mysql', 'performance_schema', 'sys')
ORDER BY count_read DESC;

-- ============================================================================
-- 5. INNODB BUFFER POOL HIT RATIO
-- ============================================================================
-- What: Measures how effectively InnoDB caches data pages. A low hit ratio
--       means frequent disk reads, often caused by missing or poor indexes.
-- Look for: hit_ratio_pct should be > 99% for OLTP workloads.
-- Remediation: Increase innodb_buffer_pool_size or optimize indexes.
-- ============================================================================

SELECT
    FORMAT(
        (1 - (
            CAST((SELECT VARIABLE_VALUE FROM performance_schema.global_status
                  WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') AS DECIMAL(20,4))
            /
            GREATEST(CAST((SELECT VARIABLE_VALUE FROM performance_schema.global_status
                  WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests') AS DECIMAL(20,4)), 1)
        )) * 100,
        2
    ) AS hit_ratio_pct,
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status
     WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') AS physical_reads,
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status
     WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests') AS logical_reads,
    CASE
        WHEN (1 - (
            CAST((SELECT VARIABLE_VALUE FROM performance_schema.global_status
                  WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') AS DECIMAL(20,4))
            /
            GREATEST(CAST((SELECT VARIABLE_VALUE FROM performance_schema.global_status
                  WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests') AS DECIMAL(20,4)), 1)
        )) * 100 < 99 THEN 'WARNING: Consider increasing innodb_buffer_pool_size'
        ELSE 'OK: Buffer pool hit ratio is healthy'
    END AS recommendation;

-- ============================================================================
-- 6. TABLE FRAGMENTATION (InnoDB data_free)
-- ============================================================================
-- What: InnoDB tables accumulate free space internally over time from
--       DELETE and UPDATE operations. Excessive fragmentation wastes disk
--       and can degrade full table scans.
-- Look for: frag_pct > 20% on tables with data_free > 1MB.
-- Remediation: ALTER TABLE <table> ENGINE=InnoDB;  (online rebuild in 8.0)
--              or OPTIMIZE TABLE <table>;
-- ============================================================================

SELECT table_schema,
       table_name,
       engine,
       FORMAT(data_length / 1048576, 2) AS data_size_mb,
       FORMAT(index_length / 1048576, 2) AS index_size_mb,
       FORMAT(data_free / 1048576, 2) AS free_space_mb,
       ROUND(data_free * 100 / GREATEST(data_length, 1), 1) AS frag_pct,
       table_rows,
       CASE
           WHEN data_free * 100 / GREATEST(data_length, 1) > 30 THEN 'HIGH: Run OPTIMIZE TABLE'
           WHEN data_free * 100 / GREATEST(data_length, 1) > 20 THEN 'MODERATE: Consider OPTIMIZE TABLE'
           ELSE 'OK'
       END AS recommendation
FROM information_schema.tables
WHERE table_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  AND table_type = 'BASE TABLE'
  AND data_free > 1048576
ORDER BY data_free DESC;

-- ============================================================================
-- 7. INDEX CARDINALITY CHECK (Low selectivity indexes)
-- ============================================================================
-- What: Indexes with very low cardinality (few distinct values relative to
--       row count) provide little benefit and may not be used by the optimizer.
-- Look for: selectivity_pct < 1% on non-boolean columns.
-- Remediation: Review if the index is needed; low-cardinality columns are
--              often better handled by full scans or composite indexes.
-- ============================================================================

SELECT s.table_schema,
       s.table_name,
       s.index_name,
       s.column_name,
       s.cardinality,
       t.table_rows,
       CASE WHEN t.table_rows > 0
            THEN ROUND(s.cardinality * 100 / t.table_rows, 2)
            ELSE 0 END AS selectivity_pct,
       CASE
           WHEN t.table_rows > 10000 AND s.cardinality * 100 / GREATEST(t.table_rows, 1) < 1
               THEN 'LOW SELECTIVITY: Index may not be useful'
           ELSE 'OK'
       END AS recommendation
FROM information_schema.statistics s
JOIN information_schema.tables t
    ON s.table_schema = t.table_schema AND s.table_name = t.table_name
WHERE s.table_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  AND s.seq_in_index = 1  -- Leading column only
  AND t.table_rows > 10000
  AND s.cardinality > 0
  AND (s.cardinality * 100 / GREATEST(t.table_rows, 1)) < 1
ORDER BY t.table_rows DESC;

-- ============================================================================
-- 8. INDEX SIZE OVERVIEW
-- ============================================================================
-- What: Provides an overview of index sizes per table to identify tables
--       with disproportionately large indexes (index > data).
-- Look for: Tables where index_size_mb > data_size_mb.
-- Remediation: Review indexes on these tables for redundancy.
-- ============================================================================

SELECT table_schema,
       table_name,
       engine,
       table_rows,
       FORMAT(data_length / 1048576, 2) AS data_size_mb,
       FORMAT(index_length / 1048576, 2) AS index_size_mb,
       CASE WHEN data_length > 0
            THEN ROUND(index_length * 100 / data_length, 1)
            ELSE 0 END AS index_to_data_pct,
       CASE
           WHEN index_length > data_length * 2 THEN 'WARNING: Index size > 2x data size'
           WHEN index_length > data_length THEN 'REVIEW: Index size exceeds data size'
           ELSE 'OK'
       END AS recommendation
FROM information_schema.tables
WHERE table_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  AND table_type = 'BASE TABLE'
  AND data_length > 1048576
ORDER BY index_length DESC
LIMIT 30;

-- ==========================================================================
-- End of MySQL Index Health Check
-- ==========================================================================
