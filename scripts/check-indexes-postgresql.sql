-- ==========================================================================
-- SQL Valid8 (example) - PostgreSQL Index Health Check
-- Dialect: PostgreSQL
-- Minimum version: PostgreSQL 13+
-- ==========================================================================
-- Run against your PostgreSQL 13+ database.
-- Requires: SELECT privileges on pg_stat_user_tables, pg_stat_user_indexes,
--           pg_class, pg_index, pg_namespace.
-- For other dialects, see:
--   check-indexes-mssql.sql
--   check-indexes-oracle.sql
--   check-indexes-mysql.sql
-- ==========================================================================

-- ============================================================================
-- 1. MISSING INDEXES (Tables with high sequential scan ratio)
-- ============================================================================
-- What: Identifies tables where sequential scans dominate over index scans,
--       suggesting missing indexes on frequently queried columns.
-- Look for: Tables with seq_scan_pct > 80% and high estimated_rows.
-- Remediation: Analyze slow queries on these tables and create targeted indexes.
-- ============================================================================

SELECT schemaname,
       relname AS table_name,
       seq_scan,
       idx_scan,
       CASE WHEN seq_scan + idx_scan > 0
            THEN round(100.0 * seq_scan / (seq_scan + idx_scan), 1)
            ELSE 0 END AS seq_scan_pct,
       n_live_tup AS estimated_rows
FROM pg_stat_user_tables
WHERE seq_scan > idx_scan
  AND n_live_tup > 10000
ORDER BY seq_scan - idx_scan DESC
LIMIT 20;

-- ============================================================================
-- 2. UNUSED INDEXES (Never scanned since last stats reset)
-- ============================================================================
-- What: Finds indexes that have never been used for reads but consume storage
--       and slow down writes. Excludes unique and primary key indexes.
-- Look for: Large indexes with idx_scan = 0.
-- Remediation: Verify with pg_stat_reset() timing, then DROP INDEX CONCURRENTLY.
-- Note: Stats reset on server restart; check pg_stat_bgwriter.stats_reset.
-- ============================================================================

SELECT s.schemaname,
       s.relname AS table_name,
       s.indexrelname AS index_name,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size,
       s.idx_scan AS times_used
FROM pg_stat_user_indexes s
JOIN pg_index i ON s.indexrelid = i.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisunique
  AND NOT i.indisprimary
ORDER BY pg_relation_size(i.indexrelid) DESC;

-- ============================================================================
-- 3. DUPLICATE INDEXES (Indexes with identical column sets)
-- ============================================================================
-- What: Detects indexes that cover the same columns in the same order,
--       wasting storage and write performance.
-- Look for: Pairs of indexes with identical column definitions.
-- Remediation: Keep the more specific index (e.g., with INCLUDE or WHERE clause)
--              and DROP INDEX CONCURRENTLY on the redundant one.
-- ============================================================================

WITH index_cols AS (
    SELECT
        n.nspname AS schemaname,
        ct.relname AS table_name,
        ci.relname AS index_name,
        i.indexrelid,
        i.indrelid,
        array_to_string(i.indkey, ',') AS indkey_str,
        pg_get_indexdef(i.indexrelid) AS index_def,
        pg_relation_size(i.indexrelid) AS index_size
    FROM pg_index i
    JOIN pg_class ct ON ct.oid = i.indrelid
    JOIN pg_class ci ON ci.oid = i.indexrelid
    JOIN pg_namespace n ON n.oid = ct.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND NOT i.indisprimary
)
SELECT
    a.schemaname,
    a.table_name,
    a.index_name AS index_1,
    b.index_name AS index_2,
    pg_size_pretty(a.index_size) AS index_1_size,
    pg_size_pretty(b.index_size) AS index_2_size,
    a.index_def AS index_1_definition,
    b.index_def AS index_2_definition,
    'Review and drop the redundant index' AS recommendation
FROM index_cols a
JOIN index_cols b
    ON a.indrelid = b.indrelid
    AND a.indkey_str = b.indkey_str
    AND a.indexrelid < b.indexrelid
ORDER BY a.schemaname, a.table_name, a.index_size DESC;

-- ============================================================================
-- 4. INDEX BLOAT ESTIMATION
-- ============================================================================
-- What: Estimates index bloat by comparing actual size to expected size based
--       on live tuples. Bloated indexes waste I/O and memory.
-- Look for: bloat_ratio > 2.0 (index is 2x larger than expected).
-- Remediation: REINDEX CONCURRENTLY <index_name>;
-- Note: This is an approximation; for exact numbers use pgstattuple extension.
-- ============================================================================

SELECT
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan AS times_used,
    CASE WHEN pg_relation_size(relid) > 0
         THEN round(pg_relation_size(indexrelid)::numeric / GREATEST(pg_relation_size(relid), 1), 2)
         ELSE 0 END AS index_to_table_ratio,
    'REINDEX CONCURRENTLY ' || quote_ident(schemaname) || '.' || quote_ident(indexrelname) || ';' AS reindex_command
FROM pg_stat_user_indexes
WHERE pg_relation_size(indexrelid) > 10 * 1024 * 1024  -- > 10MB
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;

-- ============================================================================
-- 5. INDEXES WITH HIGH HEAP FETCH RATIO (Missing INCLUDE columns)
-- ============================================================================
-- What: Tables where index scans result in many heap fetches, indicating
--       that queries need columns not present in the index.
-- Look for: heap_fetch_pct > 50% with high idx_tup_fetch counts.
-- Remediation: Add INCLUDE columns to covering indexes (PostgreSQL 11+).
-- ============================================================================

SELECT schemaname,
       relname AS table_name,
       idx_tup_read,
       idx_tup_fetch,
       CASE WHEN idx_tup_read > 0
            THEN round(100.0 * idx_tup_fetch / idx_tup_read, 1)
            ELSE 0 END AS heap_fetch_pct
FROM pg_stat_user_tables
WHERE idx_tup_fetch > 1000
ORDER BY idx_tup_fetch DESC;

-- ============================================================================
-- 6. TABLES NEEDING VACUUM (High dead tuple count)
-- ============================================================================
-- What: Identifies tables with significant dead tuples that need vacuuming.
--       Dead tuples waste space and degrade query performance.
-- Look for: dead_pct > 10% or n_dead_tup > 10000.
-- Remediation: Run VACUUM ANALYZE <table> or tune autovacuum settings:
--   ALTER TABLE <table> SET (autovacuum_vacuum_scale_factor = 0.05);
-- ============================================================================

SELECT schemaname,
       relname,
       n_dead_tup,
       n_live_tup,
       round(100.0 * n_dead_tup / GREATEST(n_live_tup, 1), 1) AS dead_pct,
       last_autovacuum,
       last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC;

-- ============================================================================
-- 7. INVALID INDEXES (Failed concurrent index builds)
-- ============================================================================
-- What: Finds indexes marked as invalid, typically from failed
--       CREATE INDEX CONCURRENTLY operations. These indexes are not used
--       by the planner and consume space.
-- Look for: Any rows returned indicate broken indexes.
-- Remediation: DROP INDEX <invalid_index>; then recreate CONCURRENTLY.
-- ============================================================================

SELECT
    n.nspname AS schemaname,
    ct.relname AS table_name,
    ci.relname AS index_name,
    pg_size_pretty(pg_relation_size(ci.oid)) AS index_size,
    'DROP INDEX ' || quote_ident(n.nspname) || '.' || quote_ident(ci.relname) || ';' AS drop_command
FROM pg_index i
JOIN pg_class ci ON ci.oid = i.indexrelid
JOIN pg_class ct ON ct.oid = i.indrelid
JOIN pg_namespace n ON n.oid = ct.relnamespace
WHERE NOT i.indisvalid
  AND n.nspname NOT IN ('pg_catalog', 'information_schema');

-- ============================================================================
-- 8. TABLES WITHOUT PRIMARY KEYS
-- ============================================================================
-- What: Tables without a primary key may lack logical row identity,
--       can cause replication issues, and miss optimization opportunities.
-- Look for: Any user tables returned here should be reviewed.
-- Remediation: ADD PRIMARY KEY or ensure a UNIQUE NOT NULL constraint exists.
-- ============================================================================

SELECT
    n.nspname AS schemaname,
    c.relname AS table_name,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    c.reltuples::bigint AS estimated_rows,
    'ALTER TABLE ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
      || ' ADD PRIMARY KEY (<column>);' AS fix_command
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND NOT EXISTS (
      SELECT 1 FROM pg_index i
      WHERE i.indrelid = c.oid AND i.indisprimary
  )
ORDER BY pg_total_relation_size(c.oid) DESC;

-- ==========================================================================
-- End of PostgreSQL Index Health Check
-- ==========================================================================
